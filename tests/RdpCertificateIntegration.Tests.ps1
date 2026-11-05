$repoRoot = Split-Path $PSScriptRoot -Parent
$artifact = Join-Path $repoRoot 'customer-examples\artifacts\Configure-RdpCertificate'
. (Join-Path $artifact 'scripts\Common.ps1')
. (Join-Path $artifact 'scripts\Bootstrap.ps1')
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $artifact 'scripts\Server.ps1'), [ref]$null, [ref]$null)
$functions = $ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -in @('Assert-CaConfiguration', 'Get-AuthorizedHost', 'Get-IssuedCertificate')
}, $true)
. ([scriptblock]::Create("using namespace System.Security.Cryptography.X509Certificates`n" +
    (($functions | ForEach-Object { $_.Extent.Text }) -join "`n")))

function Test-EnrollmentRejected {
    param([scriptblock]$Action, [string]$Pattern = '.')
    try { & $Action | Out-Null; return $false }
    catch { return $_.Exception.Message -match $Pattern }
}

Describe 'Provisioning-attested RDP credential bootstrap' {
    BeforeEach {
        $data = Join-Path $TestDrive ([Guid]::NewGuid().ToString())
        [void](New-Item -ItemType Directory -Path $data)
        $rsa = [Security.Cryptography.RSA]::Create(3072)
        $dns = 'avd001.example.internal'
        $pem = (New-ProfileRequest $dns $rsa credential).CreateSigningRequestPem()
        $vmId = '11111111-2222-3333-4444-555555555555'
        $group = '/subscriptions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/resourceGroups/hosts'
        $resourceId = "$group/providers/Microsoft.Compute/virtualMachines/avd001"
        $wrapper = "Write-Output 'approved wrapper'`n"
        $config = [pscustomobject]@{
            Hosts = @(); RenewBeforeDays = 30
            Bootstrap = [pscustomobject]@{
                Enabled = $true; VirtualMachinesResourceGroupId = $group
                HostPoolResourceId = '/subscriptions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/resourceGroups/avd/providers/Microsoft.DesktopVirtualization/hostPools/pool'
                DnsSuffix = 'example.internal'; PrepareScriptSha256 = (Get-ProvisioningScriptHash $wrapper)
                ArtifactUri = 'https://storage.example.internal/artifacts/Configure-RdpCertificate-v1.zip'
                MaximumProofAgeMinutes = 120; RetirementGraceMinutes = 60
            }
        }
        $vm = [pscustomobject]@{
            id = $resourceId; tags = @{ 'cm-resource-parent' = $config.Bootstrap.HostPoolResourceId }
            properties = [pscustomobject]@{ vmId = $vmId; osProfile = @{ computerName = 'avd001' } }
        }
        $proof = [pscustomobject]@{
            Version = 1; VmId = $vmId; VmResourceId = $resourceId; DnsName = $dns
            EnrollmentPublicKeySha256 = (Get-PublicKeyHash (Read-ValidatedRequest $pem $dns credential).PublicKey)
            RequestSha256 = (Get-BytesHash ([Text.Encoding]::UTF8.GetBytes($pem)))
        }
        $command = [pscustomobject]@{
            id = "$resourceId/runCommands/RdpCertificate-Prepare"
            properties = [pscustomobject]@{
                provisioningState = 'Succeeded'; source = @{ script = $wrapper }
                parameters = @(
                    @{ name = 'Name'; value = 'RdpCertificate-Prepare' },
                    @{ name = 'Uri'; value = $config.Bootstrap.ArtifactUri },
                    @{ name = 'Arguments'; value = '-Mode PrepareHost' }
                )
                instanceView = [pscustomobject]@{
                    executionState = 'Succeeded'; exitCode = 0
                    startTime = [DateTimeOffset]::UtcNow.AddMinutes(-2).ToString('o')
                    endTime = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')
                    output = "FEDERALAVD_RDP_BOOTSTRAP:$($proof | ConvertTo-Json -Compress)`ncustomization complete."
                }
            }
        }
        Mock Write-Audit {}
    }
    AfterEach { $rsa.Dispose() }

    It 'binds a signed credential request to the current VM and trusted provisioning output' {
        $identity = Assert-BootstrapEvidence $vm $command $resourceId $pem
        $identity.VmId | Should Be $vmId
        $identity.EnrollmentPublicKeySha256 | Should Be $proof.EnrollmentPublicKeySha256
    }

    It 'normalizes BOM and Windows line endings for the approved source pin' {
        (Get-ProvisioningScriptHash "$([char]0xFEFF)line1`r`nline2`r`n") |
            Should Be (Get-ProvisioningScriptHash "line1`nline2`n")
    }

    It 'rejects another CSR even if its requested DNS name is correct' {
        $other = [Security.Cryptography.RSA]::Create(3072)
        try {
            $otherPem = (New-ProfileRequest $dns $other credential).CreateSigningRequestPem()
            (Test-EnrollmentRejected { Assert-BootstrapEvidence $vm $command $resourceId $otherPem } 'not the key authorized') | Should Be $true
        }
        finally { $other.Dispose() }
    }

    It 'rejects stale VM-incarnation proof after hostname reuse' {
        $vm.properties.vmId = [Guid]::NewGuid().ToString()
        (Test-EnrollmentRejected { Assert-BootstrapEvidence $vm $command $resourceId $pem } 'not the key authorized') | Should Be $true
    }

    It 'rejects a host-pool ownership tag mismatch' {
        $vm.tags['cm-resource-parent'] = "$($config.Bootstrap.HostPoolResourceId)-other"
        (Test-EnrollmentRejected { Assert-BootstrapEvidence $vm $command $resourceId $pem } 'approved resource group') | Should Be $true
    }

    It 'rejects an outside resource group before performing any authenticated ARM read' {
        Mock Invoke-EnrollmentArmRead { throw 'must not be called' }
        (Test-EnrollmentRejected { Register-BootstrapRequest ($resourceId.Replace('/hosts/', '/other/')) $pem } 'outside') | Should Be $true
        Assert-MockCalled Invoke-EnrollmentArmRead -Times 0 -Exactly -Scope It
    }

    It 'rejects a completed command with an unapproved source' {
        $command.properties.source.script = "Write-Output 'forged'"
        (Test-EnrollmentRejected { Assert-BootstrapEvidence $vm $command $resourceId $pem } 'approved provisioning source') | Should Be $true
    }

    It 'rejects a differently configured artifact URI' {
        $command.properties.parameters[1].value += '.unapproved'
        (Test-EnrollmentRejected { Assert-BootstrapEvidence $vm $command $resourceId $pem } 'not approved') | Should Be $true
    }

    It 'rejects changed preparation arguments' {
        $command.properties.parameters[2].value += ' -ConfigurationPath attacker.json'
        (Test-EnrollmentRejected { Assert-BootstrapEvidence $vm $command $resourceId $pem } 'not approved') | Should Be $true
    }

    It 'rejects duplicate wrapper parameters' {
        $command.properties.parameters += @{ name = 'Arguments'; value = '-Mode PrepareHost' }
        (Test-EnrollmentRejected { Assert-BootstrapEvidence $vm $command $resourceId $pem } 'Duplicate') | Should Be $true
    }

    It 'rejects an unfinished command even if its output already contains a proof' {
        $command.properties.instanceView.executionState = 'Running'
        (Test-EnrollmentRejected { Assert-BootstrapEvidence $vm $command $resourceId $pem } 'not finished propagating') | Should Be $true
    }

    It 'rejects a nonzero preparation exit code' {
        $command.properties.instanceView.exitCode = 1
        (Test-EnrollmentRejected { Assert-BootstrapEvidence $vm $command $resourceId $pem } 'completed SYSTEM') | Should Be $true
    }

    It 'rejects user-context execution' {
        $command.properties | Add-Member -NotePropertyName runAsUser -NotePropertyValue 'ordinary-user'
        (Test-EnrollmentRejected { Assert-BootstrapEvidence $vm $command $resourceId $pem } 'SYSTEM') | Should Be $true
    }

    It 'rejects expired provisioning evidence' {
        $command.properties.instanceView.startTime = [DateTimeOffset]::UtcNow.AddDays(-1).ToString('o')
        (Test-EnrollmentRejected { Assert-BootstrapEvidence $vm $command $resourceId $pem } 'stale') | Should Be $true
    }

    It 'rejects duplicate proof markers' {
        $command.properties.instanceView.output += "`nFEDERALAVD_RDP_BOOTSTRAP:$($proof | ConvertTo-Json -Compress)"
        (Test-EnrollmentRejected { Assert-BootstrapEvidence $vm $command $resourceId $pem } 'exactly one') | Should Be $true
    }

    It 'never accepts a guest identity token as bootstrap proof' {
        $hostCode = (Get-Content -LiteralPath (Join-Path $artifact 'scripts\Host.ps1') -Raw) +
            (Get-Content -LiteralPath (Join-Path $artifact 'scripts\Common.ps1') -Raw)
        $hostCode | Should Not Match 'identity/oauth2/token|Authorization\s*='
        $gatewayCode = Get-Content -LiteralPath (Join-Path $artifact 'scripts\Bootstrap.ps1') -Raw
        $gatewayCode | Should Match 'identity/oauth2/token'
        $gatewayCode | Should Match 'MaximumRedirection 0'
    }

    It 'is retry-safe for the same key and VM without manually editing an allowlist' {
        Mock Invoke-EnrollmentArmRead { if ($ResourceId -like '*/runCommands/*') { $command } else { $vm } }
        Mock Get-IssuedCertificate { @{ Certificate = 'public-certificate'; RequestSha256 = 'request-hash' } }
        (Register-BootstrapRequest $resourceId $pem).Certificate | Should Be 'public-certificate'
        (Register-BootstrapRequest $resourceId $pem).Certificate | Should Be 'public-certificate'
        $identity = Read-JsonFile (Get-IdentityPath $vmId)
        $identity.Status | Should Be Active
        $identity.VmId | Should Be $vmId
        @(Get-ChildItem -LiteralPath $data -Filter 'identity-*.json').Count | Should Be 1
        Assert-MockCalled Get-IssuedCertificate -Times 2 -Exactly -Scope It -ParameterFilter { $Scope -eq $vmId }
    }

    It 'never reactivates a retired VM identity from replayed provisioning evidence' {
        $identity = Assert-BootstrapEvidence $vm $command $resourceId $pem
        $identity | Add-Member -NotePropertyName Status -NotePropertyValue Retired
        Write-JsonFile (Get-IdentityPath $vmId) $identity
        Mock Invoke-EnrollmentArmRead { if ($ResourceId -like '*/runCommands/*') { $command } else { $vm } }
        Mock Get-IssuedCertificate {}
        (Test-EnrollmentRejected { Register-BootstrapRequest $resourceId $pem } 'retired') | Should Be $true
        Assert-MockCalled Get-IssuedCertificate -Times 0 -Exactly -Scope It
    }

    It 'defers retirement and logs the error on a transient ARM failure' {
        Write-JsonFile (Get-IdentityPath $vmId) @{
            VmId = $vmId; VmResourceId = $resourceId; Status = 'Active'; MissingSinceUtc = $null
        }
        Mock Invoke-EnrollmentArmRead { throw 'ARM 503 unavailable' }
        Mock Revoke-RetiredIdentity {}
        Invoke-IdentityRetirement
        $identity = Read-JsonFile (Get-IdentityPath $vmId)
        $identity.Status | Should Be Active
        $identity.MissingSinceUtc | Should BeNullOrEmpty
        Assert-MockCalled Revoke-RetiredIdentity -Times 0 -Exactly -Scope It
        Assert-MockCalled Write-Audit -Times 1 -Scope It -ParameterFilter { $Event -eq 'RetirementDeferred' }
    }

    It 'retains a rollback VM that still exists with the same immutable identity' {
        Write-JsonFile (Get-IdentityPath $vmId) @{
            VmId = $vmId; VmResourceId = $resourceId; Status = 'Active'
            MissingSinceUtc = [DateTimeOffset]::UtcNow.AddDays(-1).ToString('o')
        }
        Mock Invoke-EnrollmentArmRead { $vm }
        Mock Revoke-RetiredIdentity {}
        Invoke-IdentityRetirement
        (Read-JsonFile (Get-IdentityPath $vmId)).MissingSinceUtc | Should BeNullOrEmpty
        Assert-MockCalled Revoke-RetiredIdentity -Times 0 -Exactly -Scope It
    }

    It 'waits the configured grace period after an authoritative missing result' {
        Write-JsonFile (Get-IdentityPath $vmId) @{
            VmId = $vmId; VmResourceId = $resourceId; Status = 'Active'; MissingSinceUtc = $null
        }
        Mock Invoke-EnrollmentArmRead { $null }
        Mock Revoke-RetiredIdentity {}
        Invoke-IdentityRetirement
        (Read-JsonFile (Get-IdentityPath $vmId)).MissingSinceUtc | Should Not BeNullOrEmpty
        Assert-MockCalled Revoke-RetiredIdentity -Times 0 -Exactly -Scope It
    }

    It 'retires deleted VM credentials after the grace period' {
        Write-JsonFile (Get-IdentityPath $vmId) @{
            VmId = $vmId; VmResourceId = $resourceId; Status = 'Active'
            MissingSinceUtc = [DateTimeOffset]::UtcNow.AddHours(-2).ToString('o')
        }
        Mock Invoke-EnrollmentArmRead { $null }
        Mock Revoke-RetiredIdentity {}
        Invoke-IdentityRetirement
        Assert-MockCalled Revoke-RetiredIdentity -Times 1 -Exactly -Scope It -ParameterFilter { $Identity.VmId -eq $vmId }
    }

    It 'does not interpret an empty GUID in a malformed VM response as a replacement' {
        Write-JsonFile (Get-IdentityPath $vmId) @{
            VmId = $vmId; VmResourceId = $resourceId; Status = 'Active'; MissingSinceUtc = $null
        }
        $vm.properties.vmId = [Guid]::Empty.ToString()
        Mock Invoke-EnrollmentArmRead { $vm }
        Mock Revoke-RetiredIdentity {}
        Invoke-IdentityRetirement
        (Read-JsonFile (Get-IdentityPath $vmId)).MissingSinceUtc | Should BeNullOrEmpty
        Assert-MockCalled Revoke-RetiredIdentity -Times 0 -Exactly -Scope It
        Assert-MockCalled Write-Audit -Times 1 -Scope It -ParameterFilter { $Event -eq 'RetirementDeferred' }
    }

    It 'retires an old incarnation even when the VM resource name was reused' {
        Write-JsonFile (Get-IdentityPath $vmId) @{
            VmId = $vmId; VmResourceId = $resourceId; Status = 'Active'
            MissingSinceUtc = [DateTimeOffset]::UtcNow.AddHours(-2).ToString('o')
        }
        $vm.properties.vmId = [Guid]::NewGuid().ToString()
        Mock Invoke-EnrollmentArmRead { $vm }
        Mock Revoke-RetiredIdentity {}
        Invoke-IdentityRetirement
        Assert-MockCalled Revoke-RetiredIdentity -Times 1 -Exactly -Scope It
    }

    It 'preserves inventory across credential and RDP certificate generations' {
        $request = New-ProfileRequest $dns $rsa rdp
        $first = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-1), [DateTimeOffset]::UtcNow.AddDays(90))
        $second = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-1), [DateTimeOffset]::UtcNow.AddDays(120))
        try {
            Save-CertificateInventory $first $vmId
            Save-CertificateInventory $first $vmId
            Save-CertificateInventory $second $vmId
            @(Get-ChildItem -LiteralPath $data -Filter 'issued-*.json').Count | Should Be 2
        }
        finally { $first.Dispose(); $second.Dispose() }
    }

    It 'separates cached issuance for different VM incarnations reusing the same DNS name' {
        $request = New-ProfileRequest $dns $rsa rdp
        $rdpPem = $request.CreateSigningRequestPem()
        $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-1), [DateTimeOffset]::UtcNow.AddDays(90))
        try {
            $oldPath = Join-Path $data ((Get-BytesHash ([Text.Encoding]::UTF8.GetBytes("$vmId|$dns|rdp"))) + '.json')
            Write-JsonFile $oldPath @{
                RequestSha256 = '0' * 64; RequestId = 42; Certificate = [Convert]::ToBase64String($certificate.RawData)
            }
            Mock Assert-CaConfiguration {}
            Mock New-Object { throw 'Fresh VM namespace reached CA submission.' } -ParameterFilter { $ComObject -eq 'CertificateAuthority.Request' }
            $issuer = @($functions | Where-Object { $_.Name -eq 'Get-IssuedCertificate' })[0].Body.GetScriptBlock()
            $failure = $null
            try { & $issuer $rdpPem $dns rdp $proof.EnrollmentPublicKeySha256 -Scope ([Guid]::NewGuid().ToString()) | Out-Null }
            catch { $failure = $_.Exception.Message }
            $failure | Should Match 'Fresh VM namespace'
        }
        finally { $certificate.Dispose() }
    }

    It 'recovers an issued request missing its inventory after an interrupted approval' {
        $config | Add-Member -NotePropertyName CaConfig -NotePropertyValue 'CA01\Test CA'
        $identity = [pscustomobject]@{ VmId = $vmId; DnsName = $dns }
        Write-JsonFile (Get-IssuanceStatePath $dns credential $vmId) @{ RequestId = 42; Certificate = $null }
        $request = New-ProfileRequest $dns $rsa credential
        $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-1), [DateTimeOffset]::UtcNow.AddDays(90))
        try {
            $client = [pscustomobject]@{ Encoded = [Convert]::ToBase64String($certificate.RawData) }
            $client | Add-Member -MemberType ScriptMethod -Name RetrievePending -Value { return 3 }
            $client | Add-Member -MemberType ScriptMethod -Name GetCertificate -Value { return $this.Encoded }
            Sync-RetiringIssuanceInventory $identity $client $null
            $records = @(Get-ChildItem -LiteralPath $data -Filter 'issued-*.json')
            $records.Count | Should Be 1
            (Read-JsonFile $records[0].FullName).Scope | Should Be $vmId
            (Read-JsonFile $records[0].FullName).SerialNumber | Should Be $certificate.SerialNumber
        }
        finally { $certificate.Dispose() }
    }

    It 'denies its recorded still-pending request during retirement without approving it' {
        $config | Add-Member -NotePropertyName CaConfig -NotePropertyValue 'CA01\Test CA'
        $identity = [pscustomobject]@{ VmId = $vmId; DnsName = $dns }
        Write-JsonFile (Get-IssuanceStatePath $dns credential $vmId) @{ RequestId = 42; Certificate = $null }
        $client = [pscustomobject]@{}
        $client | Add-Member -MemberType ScriptMethod -Name RetrievePending -Value { return 5 }
        $admin = [pscustomobject]@{ Denied = @() }
        $admin | Add-Member -MemberType ScriptMethod -Name DenyRequest -Value { param($ca, $requestId) $this.Denied += $requestId }
        Sync-RetiringIssuanceInventory $identity $client $admin
        $admin.Denied.Count | Should Be 1
        $admin.Denied[0] | Should Be 42
        @(Get-ChildItem -LiteralPath $data -Filter 'issued-*.json').Count | Should Be 0
    }
}

Describe 'Gateway ARM deletion evidence handling' {
    BeforeEach {
        $config = [pscustomobject]@{
            Bootstrap = [pscustomobject]@{ ArmEndpoint = 'https://management.example.internal/'; ArmAudience = 'https://management.example.internal/' }
        }
        $resourceId = '/subscriptions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/resourceGroups/hosts/providers/Microsoft.Compute/virtualMachines/avd001'
        $httpResponse = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::NotFound)
        $httpResponse.Content = [Net.Http.StringContent]::new('{"error":{"code":"ResourceNotFound"}}')
        Mock Invoke-RestMethod {
            if ($Uri -like 'http://169.254.169.254/*') { return [pscustomobject]@{ access_token = 'opaque-unit-test-token' } }
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('ARM error', $httpResponse)
        }
    }
    AfterEach { $httpResponse.Dispose() }

    It 'allows only an explicit ARM resource-not-found response to establish absence' {
        (Invoke-EnrollmentArmRead $resourceId -AllowMissing) | Should BeNullOrEmpty
    }

    It 'does not treat access-denied as deleted' {
        $httpResponse.StatusCode = [Net.HttpStatusCode]::Forbidden
        (Test-EnrollmentRejected { Invoke-EnrollmentArmRead $resourceId -AllowMissing } 'ARM error') | Should Be $true
    }

    It 'does not treat an unrecognized 404 as deleted' {
        $httpResponse.Content = [Net.Http.StringContent]::new('{"error":{"code":"InvalidResourceType"}}')
        (Test-EnrollmentRejected { Invoke-EnrollmentArmRead $resourceId -AllowMissing } 'ARM error') | Should Be $true
    }

    It 'rejects an empty success response instead of reporting deletion' {
        Mock Invoke-RestMethod {
            if ($Uri -like 'http://169.254.169.254/*') { return [pscustomobject]@{ access_token = 'opaque-unit-test-token' } }
            return $null
        }
        (Test-EnrollmentRejected { Invoke-EnrollmentArmRead $resourceId -AllowMissing } 'empty success') | Should Be $true
    }

    It 'rejects caller-supplied query strings before requesting an identity token' {
        (Test-EnrollmentRejected { Invoke-EnrollmentArmRead "$resourceId`?redirect=other" } 'Invalid VM') | Should Be $true
        Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It
    }

    It 'requires the literal Microsoft.Compute namespace' {
        (Test-EnrollmentRejected { Invoke-EnrollmentArmRead ($resourceId.Replace('Microsoft.Compute', 'MicrosoftXCompute')) } 'Invalid VM') | Should Be $true
        Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It
    }
}

Describe 'Session Host Replacer certificate readiness integration' {
    BeforeAll {
        Import-Module (Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\functions\Modules\SessionHostReplacer\SessionHostReplacer.psd1') -Force
    }
    BeforeEach {
        $image = [pscustomobject]@{ Definition = '/gallery/images/avd'; Version = '1.2.3' }
        $imageToken = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes("$($image.Definition)|$($image.Version)")
        )).ToLowerInvariant()
        $entry = [pscustomobject]@{
            SessionHostName = 'avd001'; ResourceId = '/subscriptions/test/resourceGroups/hosts/providers/Microsoft.Compute/virtualMachines/avd001'
            ImageDefinition = $image.Definition; ImageVersion = $image.Version
            Status = 'Available'; AllowNewSession = $true
            Tags = @{ AutoReplaceValidatedImage = $imageToken; ScalingPlanExclusion = 'SessionHostReplacer' }
            SessionHostHealthCheckResults = @()
        }
        $global:rdpTestParameters = @{
            sessionHostCustomizations = @(
                @{ name = 'RdpCertificate-Prepare'; arguments = '-Mode PrepareHost'; blobNameOrUri = 'https://storage.example.internal/artifact.zip' },
                @{ name = 'RdpCertificate-Enroll'; arguments = '-Mode EnrollHost'; blobNameOrUri = 'https://storage.example.internal/artifact.zip' }
            )
        }
        $vmId = '11111111-2222-3333-4444-555555555555'
        $global:rdpTestVm = [pscustomobject]@{ id = $entry.ResourceId; properties = @{ vmId = $vmId } }
        $ready = @{ Version = 1; VmId = $vmId; VmResourceId = $entry.ResourceId; Thumbprint = ('A' * 40) }
        $global:rdpTestCommand = [pscustomobject]@{
            id = "$($entry.ResourceId)/runCommands/RdpCertificate-Enroll"
            properties = [pscustomobject]@{
                provisioningState = 'Succeeded'
                parameters = @(
                    @{ name = 'Arguments'; value = '-Mode EnrollHost' },
                    @{ name = 'Uri'; value = 'https://storage.example.internal/artifact.zip' }
                )
                instanceView = [pscustomobject]@{
                    executionState = 'Succeeded'; exitCode = 0
                    output = "FEDERALAVD_RDP_READY:$($ready | ConvertTo-Json -Compress)"
                }
            }
        }
        $readinessArguments = @{
            ARMToken = 'test-token'; SessionHosts = @($entry); LatestImageVersion = $image
            TagScalingPlanExclusionTag = 'ScalingPlanExclusion'; TagValidatedImage = 'AutoReplaceValidatedImage'
            ResourceManagerUri = 'https://management.example.internal'; ReadOnly = $true
        }
        Mock Write-LogEntry -ModuleName SessionHostReplacer.Lifecycle {}
        Mock Read-FunctionAppSetting -ModuleName SessionHostReplacer.Lifecycle {
            if ($SettingKey -eq 'SessionHostParameters') { $global:rdpTestParameters }
        }
        Mock Get-VMPowerStates -ModuleName SessionHostReplacer.Lifecycle { @{} }
        Mock Invoke-AzureRestMethod -ModuleName SessionHostReplacer.Lifecycle {
            if ($Uri -like '*/runCommands/*') { return $global:rdpTestCommand }
            return $global:rdpTestVm
        }
    }
    AfterAll {
        Remove-Variable rdpTestParameters, rdpTestVm, rdpTestCommand -Scope Global -ErrorAction SilentlyContinue
        Remove-Module SessionHostReplacer -Force
    }

    It 'preserves non-opted-in readiness without additional ARM reads' {
        $global:rdpTestParameters = @{}
        (Test-NewSessionHostsAvailable @readinessArguments).SafeToProceed | Should Be $true
        Assert-MockCalled Invoke-AzureRestMethod -ModuleName SessionHostReplacer.Lifecycle -Times 0 -Exactly -Scope It
    }

    It 'accepts successful listener evidence bound to the current VM' {
        (Test-NewSessionHostsAvailable @readinessArguments).SafeToProceed | Should Be $true
        Assert-MockCalled Invoke-AzureRestMethod -ModuleName SessionHostReplacer.Lifecycle -Times 2 -Exactly -Scope It
    }

    It 'resolves a relative blob name using the existing artifacts container parameter' {
        $global:rdpTestParameters.artifactsContainerUri = 'https://storage.example.internal'
        foreach ($customization in $global:rdpTestParameters.sessionHostCustomizations) { $customization.blobNameOrUri = 'artifact.zip' }
        (Test-NewSessionHostsAvailable @readinessArguments).SafeToProceed | Should Be $true
    }

    It 'blocks a healthy registered host whose certificate customization failed' {
        $global:rdpTestCommand.properties.instanceView.exitCode = 1
        (Test-NewSessionHostsAvailable @readinessArguments).SafeToProceed | Should Be $false
    }

    It 'does not tag a host as validated when listener evidence is absent' {
        $entry.Tags.Clear()
        $global:rdpTestCommand.properties.instanceView.output = 'script started'
        $readinessArguments.ReadOnly = $false
        $result = Test-NewSessionHostsAvailable @readinessArguments
        $result.SafeToProceed | Should Be $false
        $entry.Tags.ContainsKey('AutoReplaceValidatedImage') | Should Be $false
        Assert-MockCalled Invoke-AzureRestMethod -ModuleName SessionHostReplacer.Lifecycle -Times 0 -Exactly -Scope It -ParameterFilter { $Method -eq 'PATCH' }
    }

    It 'rejects old ready evidence after VM-name reuse' {
        $global:rdpTestVm.properties.vmId = [Guid]::NewGuid().ToString()
        (Test-NewSessionHostsAvailable @readinessArguments).SafeToProceed | Should Be $false
    }

    It 'fails closed on ARM errors instead of counting host availability alone' {
        Mock Invoke-AzureRestMethod -ModuleName SessionHostReplacer.Lifecycle { throw 'ARM unavailable' }
        (Test-NewSessionHostsAvailable @readinessArguments).SafeToProceed | Should Be $false
        Assert-MockCalled Write-LogEntry -ModuleName SessionHostReplacer.Lifecycle -Times 1 -Scope It -ParameterFilter { $Message -like 'RDP certificate readiness blocked*' }
    }

    It 'does not count stopped hosts with old image tags but no certificate evidence as standby' {
        $entry.Status = 'Shutdown'
        $entry.AllowNewSession = $false
        $entry.Tags.Remove('ScalingPlanExclusion')
        $global:rdpTestCommand.properties.instanceView.output = ''
        Mock Get-VMPowerStates -ModuleName SessionHostReplacer.Lifecycle { @{ $global:rdpTestVm.id = $true } }
        $readinessArguments.ScalingPlanTarget = [pscustomobject]@{ Source = 'ScalingPlan'; CapacityPercentage = 0 }
        $result = Test-NewSessionHostsAvailable @readinessArguments
        $result.ScalableStandbyCount | Should Be 0
        $result.SafeToProceed | Should Be $false
    }

    It 'keeps scaling exclusions in the direct release path when certificate enrollment failed' {
        $global:rdpTestCommand.properties.instanceView.exitCode = 1
        (Test-SessionHostScalingRelease -SessionHost $entry -LatestImageVersion $image `
            -TagValidatedImage AutoReplaceValidatedImage -ARMToken test-token `
            -ResourceManagerUri 'https://management.example.internal') | Should Be $false
        $entry.Tags.ScalingPlanExclusion | Should Be SessionHostReplacer
    }

    It 'rejects misordered preparation and enrollment configuration' {
        [array]::Reverse($global:rdpTestParameters.sessionHostCustomizations)
        (Test-EnrollmentRejected { Test-NewSessionHostsAvailable @readinessArguments } 'ordered') | Should Be $true
    }
}
