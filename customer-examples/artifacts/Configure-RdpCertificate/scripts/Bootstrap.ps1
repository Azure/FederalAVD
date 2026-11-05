#requires -Version 7.4
using namespace System.Security.Cryptography.X509Certificates

function Invoke-EnrollmentArmRead {
    param([string]$ResourceId, [string]$Query = 'api-version=2022-03-01', [switch]$AllowMissing)
    if ($ResourceId -notmatch '^/subscriptions/[a-f0-9-]{36}/resourceGroups/[a-z0-9_.()-]+/providers/Microsoft\.Compute/virtualMachines/[a-z0-9_.-]+(?:/runCommands/[a-z0-9_.-]+)?$') {
        throw [ArgumentException]::new('Invalid VM/Run Command resource ID.')
    }
    $bootstrap = $config.Bootstrap
    $resource = [Uri]::EscapeDataString($bootstrap.ArmAudience)
    $tokenUri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$resource"
    if (Get-OptionalValue $bootstrap ManagedIdentityClientId) {
        $tokenUri += "&client_id=$([Guid]::Parse($bootstrap.ManagedIdentityClientId))"
    }
    $token = Invoke-RestMethod -Uri $tokenUri -Headers @{ Metadata = 'true' } -NoProxy -TimeoutSec 15
    if ([string]::IsNullOrWhiteSpace($token.access_token)) { throw 'The gateway identity did not receive an ARM token.' }
    try {
        $result = Invoke-RestMethod -Uri "$($bootstrap.ArmEndpoint.TrimEnd('/'))$ResourceId`?$Query" `
            -Headers @{ Authorization = "Bearer $($token.access_token)" } -Method GET -NoProxy -TimeoutSec 30 -MaximumRedirection 0
        if ($null -eq $result) { throw 'ARM returned an empty success response; it is not evidence of deletion.' }
        return $result
    }
    catch [Microsoft.PowerShell.Commands.HttpResponseException] {
        if ($AllowMissing -and [int]$_.Exception.Response.StatusCode -eq 404) {
            $failure = $_.Exception.Response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
            if ($failure.error.code -in @('ResourceNotFound', 'ResourceGroupNotFound')) { return $null }
        }
        throw
    }
    finally { $token.access_token = $null }
}

function Assert-ProvisionedVm {
    param($Vm, [string]$ResourceId)
    if ($null -eq $Vm -or $Vm.id -ine $ResourceId -or
        $ResourceId -notmatch ('^' + [regex]::Escape($config.Bootstrap.VirtualMachinesResourceGroupId) +
            '/providers/Microsoft\.Compute/virtualMachines/[a-z0-9_.-]+$') -or
        (Get-OptionalValue $Vm.tags 'cm-resource-parent') -ine $config.Bootstrap.HostPoolResourceId) {
        throw [Security.SecurityException]::new('The VM does not belong to the approved resource group and host pool.')
    }
    $vmId = ([Guid]::Parse($Vm.properties.vmId)).ToString('D')
    if ($vmId -eq [Guid]::Empty.ToString()) { throw [Security.SecurityException]::new('Missing VM incarnation ID.') }
    $dns = "$($Vm.properties.osProfile.computerName.ToLowerInvariant()).$($config.Bootstrap.DnsSuffix)"
    Assert-DnsName $dns
    return [pscustomobject]@{ VmId = $vmId; VmResourceId = $ResourceId; DnsName = $dns }
}

function Assert-BootstrapEvidence {
    param($Vm, $Command, [string]$ResourceId, [string]$Pem)
    $identity = Assert-ProvisionedVm $Vm $ResourceId
    $request = Read-ValidatedRequest $Pem $identity.DnsName credential
    $properties = $Command.properties
    if ($properties.provisioningState -in @('Creating', 'Updating') -or
        $properties.instanceView.executionState -in @('Pending', 'Running')) {
        throw [InvalidOperationException]::new('Preparation execution evidence has not finished propagating; retry bootstrap.')
    }
    if ($Command.id -ine "$ResourceId/runCommands/RdpCertificate-Prepare" -or
        $properties.provisioningState -ne 'Succeeded' -or
        $properties.instanceView.executionState -ne 'Succeeded' -or
        $properties.instanceView.exitCode -ne 0 -or
        (Get-OptionalValue $properties runAsUser) -or
        (Get-OptionalValue $properties asyncExecution) -eq $true -or
        (Get-ProvisioningScriptHash $properties.source.script) -cne $config.Bootstrap.PrepareScriptSha256) {
        throw [Security.SecurityException]::new('The completed SYSTEM preparation command does not match the approved provisioning source.')
    }
    $parameters = @{}
    foreach ($parameter in $properties.parameters) {
        if ($parameters.ContainsKey($parameter.name)) { throw [Security.SecurityException]::new('Duplicate preparation parameters.') }
        $parameters[$parameter.name] = $parameter.value
    }
    if ($parameters['Name'] -cne 'RdpCertificate-Prepare' -or
        $parameters['Arguments'] -cne '-Mode PrepareHost' -or
        $parameters['Uri'] -cne $config.Bootstrap.ArtifactUri) {
        throw [Security.SecurityException]::new('The preparation artifact or arguments are not approved.')
    }
    $start = [DateTimeOffset]::Parse($properties.instanceView.startTime)
    $end = [DateTimeOffset]::Parse($properties.instanceView.endTime)
    if ($start -gt $end -or $end -gt [DateTimeOffset]::UtcNow.AddMinutes(5) -or
        $start -lt [DateTimeOffset]::UtcNow.AddMinutes(-$config.Bootstrap.MaximumProofAgeMinutes)) {
        throw [Security.SecurityException]::new('Provisioning evidence is stale or has invalid timestamps.')
    }
    $matches = [regex]::Matches($properties.instanceView.output, '(?m)^FEDERALAVD_RDP_BOOTSTRAP:(\{[^\r\n]+\})\r?$')
    if ($matches.Count -ne 1) { throw [Security.SecurityException]::new('Expected exactly one provisioning proof record.') }
    $proof = $matches[0].Groups[1].Value | ConvertFrom-Json
    $hash = Get-PublicKeyHash $request.PublicKey
    if ($proof.Version -ne 1 -or $proof.VmId -ine $identity.VmId -or
        $proof.VmResourceId -ine $ResourceId -or $proof.DnsName -cne $identity.DnsName -or
        $proof.EnrollmentPublicKeySha256 -cne $hash -or
        $proof.RequestSha256 -cne (Get-BytesHash ([Text.Encoding]::UTF8.GetBytes($Pem)))) {
        throw [Security.SecurityException]::new('The CSR is not the key authorized by this VM incarnation preparation command.')
    }
    $identity | Add-Member -NotePropertyName EnrollmentPublicKeySha256 -NotePropertyValue $hash
    return $identity
}

function Get-IdentityPath {
    param([string]$VmId)
    Join-Path $data "identity-$(([Guid]::Parse($VmId)).ToString('D')).json"
}

function Register-BootstrapRequest {
    param([string]$ResourceId, [string]$Pem)
    if (-not (Test-AutomaticBootstrap $config)) { throw [Security.SecurityException]::new('Automatic bootstrap is disabled.') }
    # Check scope before making an authenticated request for any caller-supplied path.
    if ($ResourceId -notmatch ('^' + [regex]::Escape($config.Bootstrap.VirtualMachinesResourceGroupId) +
        '/providers/Microsoft\.Compute/virtualMachines/[a-z0-9_.-]+$')) {
        throw [Security.SecurityException]::new('The VM is outside the bootstrap scope.')
    }
    $vm = Invoke-EnrollmentArmRead $ResourceId
    $command = Invoke-EnrollmentArmRead "$ResourceId/runCommands/RdpCertificate-Prepare" 'api-version=2023-03-01&$expand=instanceView'
    $identity = Assert-BootstrapEvidence $vm $command $ResourceId $Pem
    $path = Get-IdentityPath $identity.VmId
    if (Test-Path -LiteralPath $path) {
        $identity = Read-JsonFile $path
        $request = Read-ValidatedRequest $Pem $identity.DnsName credential
        if ($identity.Status -notin @('Pending', 'Active') -or $identity.VmResourceId -ine $ResourceId -or
            $identity.EnrollmentPublicKeySha256 -cne (Get-PublicKeyHash $request.PublicKey)) {
            throw [Security.SecurityException]::new('This VM identity was retired or already bound to another enrollment key.')
        }
    }
    else {
        $identity | Add-Member -NotePropertyName Status -NotePropertyValue Pending
        $identity | Add-Member -NotePropertyName MissingSinceUtc -NotePropertyValue $null
        Write-JsonFile $path $identity
    }
    $result = Get-IssuedCertificate $Pem $identity.DnsName credential $identity.EnrollmentPublicKeySha256 -Scope $identity.VmId
    $identity.Status = 'Active'
    Write-JsonFile $path $identity
    Write-Audit $data 'BootstrapAuthorized' "$($identity.VmResourceId) $($identity.VmId) $($identity.EnrollmentPublicKeySha256)"
    return $result
}

function Get-AutomaticIdentity {
    param([X509Certificate2]$Credential)
    if (-not (Test-AutomaticBootstrap $config)) { return $null }
    $hash = Get-PublicKeyHash $Credential.PublicKey
    $entries = @(Get-ChildItem -LiteralPath $data -Filter 'identity-*.json' -File | ForEach-Object {
        $entry = Read-JsonFile $_.FullName
        if ($entry.Status -eq 'Active' -and $entry.EnrollmentPublicKeySha256 -ceq $hash) { $entry }
    })
    if ($entries.Count -eq 0) { return $null }
    if ($entries.Count -ne 1) { throw [Security.SecurityException]::new('Duplicate dynamic enrollment identity.') }
    $entry = $entries[0]
    $vm = Invoke-EnrollmentArmRead $entry.VmResourceId -AllowMissing
    if ($null -eq $vm -or (Assert-ProvisionedVm $vm $entry.VmResourceId).VmId -ine $entry.VmId) {
        throw [Security.SecurityException]::new('The enrollment identity belongs to a deleted or replaced VM.')
    }
    Assert-Certificate $Credential $entry.DnsName credential $config $hash
    return $entry
}

function Save-CertificateInventory {
    param([X509Certificate2]$Certificate, [string]$Scope)
    if (-not $Scope) { return }
    $path = Join-Path $data "issued-$(Get-BytesHash $Certificate.RawData).json"
    if (-not (Test-Path -LiteralPath $path)) {
        Write-JsonFile $path @{
            Scope = $Scope; SerialNumber = $Certificate.SerialNumber
            Thumbprint = $Certificate.Thumbprint; Revoked = $false
        }
    }
}

function Get-IssuanceStatePath {
    param([string]$DnsName, [string]$Profile, [string]$Scope)
    $identity = if ($Scope) { "$Scope|$DnsName|$Profile" } else { "$DnsName|$Profile" }
    Join-Path $data "$(Get-BytesHash ([Text.Encoding]::UTF8.GetBytes($identity))).json"
}

function Sync-RetiringIssuanceInventory {
    param($Identity, $Client, $Admin)
    foreach ($profile in @('credential', 'rdp')) {
        $path = Get-IssuanceStatePath $Identity.DnsName $profile $Identity.VmId
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $state = Read-JsonFile $path
        if ($state.Certificate) { $encoded = $state.Certificate }
        else {
            # Recover a crash after CA approval but before the inventory was committed.
            $disposition = $Client.RetrievePending($state.RequestId, $config.CaConfig)
            if ($disposition -eq 5) {
                [void]$Admin.DenyRequest($config.CaConfig, $state.RequestId)
                Write-Audit $data 'RetiredPendingRequestDenied' "$($Identity.VmId) RequestId=$($state.RequestId)"
                continue
            }
            if ($disposition -eq 2) { continue }
            if ($disposition -ne 3) { throw "Cannot reconcile retiring CA request $($state.RequestId): disposition $disposition." }
            $encoded = $Client.GetCertificate(1)
        }
        $certificate = [X509Certificate2]::new([Convert]::FromBase64String($encoded))
        try { Save-CertificateInventory $certificate $Identity.VmId }
        finally { $certificate.Dispose() }
    }
}

function Revoke-RetiredIdentity {
    param($Identity)
    $path = Get-IdentityPath $Identity.VmId
    $Identity.Status = 'Retiring'
    Write-JsonFile $path $Identity
    $admin = New-Object -ComObject CertificateAuthority.Admin
    try {
        $client = New-Object -ComObject CertificateAuthority.Request
        try { Sync-RetiringIssuanceInventory $Identity $client $admin }
        finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($client) }
        foreach ($file in Get-ChildItem -LiteralPath $data -Filter 'issued-*.json' -File) {
            $certificate = Read-JsonFile $file.FullName
            if ($certificate.Scope -eq $Identity.VmId -and -not $certificate.Revoked) {
                $admin.RevokeCertificate($config.CaConfig, $certificate.SerialNumber, 5, [DateTime]::UtcNow)
                $certificate.Revoked = $true
                Write-JsonFile $file.FullName $certificate
                Write-Audit $data 'RetiredCertificateRevoked' "$($Identity.VmId) $($certificate.SerialNumber)"
            }
        }
        $Identity.Status = 'Retired'
        Write-JsonFile $path $Identity
        Write-Audit $data 'IdentityRetired' "$($Identity.VmResourceId) $($Identity.VmId)"
        Write-Audit $data 'CrlPublicationDue' 'Revocation is recorded in AD CS; the separately configured CA publication/distribution schedule must propagate it.'
    }
    finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($admin) }
}

function Invoke-IdentityRetirement {
    if (-not (Test-AutomaticBootstrap $config)) { return }
    $files = @(Get-ChildItem -LiteralPath $data -Filter 'identity-*.json' -File | Sort-Object Name)
    if ($files.Count -eq 0) { return }
    if (-not (Get-Variable -Name RetirementCursor -Scope Script -ErrorAction SilentlyContinue)) { $script:RetirementCursor = 0 }
    for ($i = 0; $i -lt [Math]::Min(20, $files.Count); $i++) {
        $file = $files[$script:RetirementCursor % $files.Count]
        $script:RetirementCursor++
        try {
            $identity = Read-JsonFile $file.FullName
            if ($identity.Status -eq 'Retired') { continue }
            if ($identity.Status -eq 'Retiring') { Revoke-RetiredIdentity $identity; continue }
            $vm = Invoke-EnrollmentArmRead $identity.VmResourceId -AllowMissing
            $missing = $null -eq $vm
            if ($null -ne $vm) {
                $currentId = [Guid]::Parse($vm.properties.vmId)
                if ($vm.id -ine $identity.VmResourceId -or $currentId -eq [Guid]::Empty) {
                    throw 'Malformed ARM VM response; retirement cannot establish an incarnation change.'
                }
                $missing = $currentId.ToString('D') -ine $identity.VmId
            }
            if (-not $missing) {
                if ($identity.MissingSinceUtc) { $identity.MissingSinceUtc = $null; Write-JsonFile $file.FullName $identity }
                continue
            }
            if (-not $identity.MissingSinceUtc) {
                $identity.MissingSinceUtc = [DateTimeOffset]::UtcNow.ToString('o')
                Write-JsonFile $file.FullName $identity
                Write-Audit $data 'RetirementGraceStarted' $identity.VmId
            }
            elseif ([DateTimeOffset]::Parse($identity.MissingSinceUtc).AddMinutes($config.Bootstrap.RetirementGraceMinutes) -le [DateTimeOffset]::UtcNow) {
                Revoke-RetiredIdentity $identity
            }
        }
        catch {
            Write-Audit $data 'RetirementDeferred' $_.Exception.ToString()
            break
        }
    }
}
