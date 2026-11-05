#requires -Version 7.4
using namespace System.Security.Cryptography
using namespace System.Security.Cryptography.X509Certificates

[CmdletBinding()]
param([switch]$ValidateConfiguration)

. "$PSScriptRoot\Common.ps1"
. "$PSScriptRoot\Bootstrap.ps1"
$root = Split-Path $PSScriptRoot -Parent
$data = Join-Path $root 'state'
$config = Read-Configuration (Join-Path $root 'configuration.json') Server

function Assert-CaConfiguration {
    $base = 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration'
    $active = (Get-ItemProperty -LiteralPath $base -ErrorAction Stop).Active
    if ($active -cne $config.CaConfig.Split('\')[1]) { throw 'CaConfig does not match the active local CA.' }
    $ca = Get-ItemProperty -LiteralPath "$base\$active" -ErrorAction Stop
    if ($ca.CAType -notin @(3, 4)) { throw 'This gateway requires a Standalone Root or Standalone Subordinate CA.' }
    $policy = Get-ItemProperty -LiteralPath "$base\$active\PolicyModules" -ErrorAction Stop
    if ($policy.Active -ne 'CertificateAuthority_MicrosoftDefault.Policy') {
        throw 'Only the Microsoft default CA policy module is supported.'
    }
    $settings = Get-ItemProperty -LiteralPath "$base\$active\PolicyModules\$($policy.Active)" -ErrorAction Stop
    if (($settings.RequestDisposition -band 0x100) -eq 0) {
        throw 'The CA must hold every incoming request pending (REQDISP_PENDINGFIRST).'
    }
    if (($settings.EditFlags -band 0x40000) -ne 0) {
        throw 'Disable EDITF_ATTRIBUTESUBJECTALTNAME2 on this dedicated CA.'
    }
}

function Get-AuthorizedHost {
    param([X509Certificate2]$Credential)
    if ($null -eq $Credential) { throw [Security.SecurityException]::new('A client enrollment certificate is required.') }
    $automatic = Get-AutomaticIdentity $Credential
    if ($null -ne $automatic) { return $automatic }
    $keyHash = Get-PublicKeyHash $Credential.PublicKey
    $entries = @($config.Hosts | Where-Object { $_.EnrollmentPublicKeySha256 -ceq $keyHash })
    if ($entries.Count -ne 1) { throw [Security.SecurityException]::new('The enrollment public key is not authorized.') }
    Assert-Certificate $Credential $entries[0].DnsName credential $config $keyHash
    return $entries[0]
}

function Get-IssuedCertificate {
    param([string]$Pem, [string]$DnsName, [string]$Profile, [string]$EnrollmentKeyHash, [string]$Scope)
    $Profile = $Profile.ToLowerInvariant()
    Assert-CaConfiguration
    $request = Read-ValidatedRequest $Pem $DnsName $Profile
    $keyHash = Get-PublicKeyHash $request.PublicKey
    if ($Profile -eq 'credential' -and $keyHash -cne $EnrollmentKeyHash) {
        throw [Security.SecurityException]::new('Enrollment renewal cannot change the authorized enrollment key.')
    }
    $requestHash = Get-BytesHash ([Text.Encoding]::UTF8.GetBytes($Pem))
    $path = Get-IssuanceStatePath $DnsName $Profile $Scope
    $state = $null
    if (Test-Path -LiteralPath $path) {
        $state = Read-JsonFile $path
        if ($state.Certificate) {
            $cached = [X509Certificate2]::new([Convert]::FromBase64String($state.Certificate))
            try {
                if ($cached.NotAfter.ToUniversalTime() -gt [DateTime]::UtcNow.AddDays($config.RenewBeforeDays)) {
                    if ($state.RequestSha256 -cne $requestHash) {
                        throw [Security.SecurityException]::new('A certificate was already issued outside the renewal window.')
                    }
                    Assert-Certificate $cached $DnsName $Profile $config $keyHash
                    Save-CertificateInventory $cached $Scope
                    return @{ Certificate = $state.Certificate; RequestSha256 = $requestHash }
                }
            }
            finally { $cached.Dispose() }
            $state = $null
        }
        elseif ($state.RequestSha256 -cne $requestHash) {
            throw [Security.SecurityException]::new('A different request is already pending for this host and profile.')
        }
    }
    $client = New-Object -ComObject CertificateAuthority.Request
    $admin = New-Object -ComObject CertificateAuthority.Admin
    try {
        if ($null -eq $state) {
            $base64 = $Pem -replace '-----BEGIN CERTIFICATE REQUEST-----|-----END CERTIFICATE REQUEST-----|\s', ''
            $disposition = $client.Submit(257, $base64, '', $config.CaConfig)
            if ($disposition -ne 5) { throw "Expected a pending request, received disposition $disposition. Review the CA database." }
            $state = [pscustomobject]@{
                RequestSha256 = $requestHash; RequestId = $client.GetRequestId()
                Certificate = $null
            }
            Write-JsonFile $path $state
            Write-Audit $data 'Pending' "$DnsName $Profile $requestHash RequestId=$($state.RequestId)"
        }
        $disposition = $client.RetrievePending($state.RequestId, $config.CaConfig)
        if ($disposition -eq 5) {
            $disposition = $admin.ResubmitRequest($config.CaConfig, $state.RequestId)
            if ($disposition -ne 3) { throw "CA approval did not issue the certificate: disposition $disposition." }
            $disposition = $client.RetrievePending($state.RequestId, $config.CaConfig)
        }
        if ($disposition -ne 3) { throw "The recorded request is not issued: disposition $disposition." }
        $encoded = $client.GetCertificate(1)
        $certificate = [X509Certificate2]::new([Convert]::FromBase64String($encoded))
        try {
            try { Assert-Certificate $certificate $DnsName $Profile $config $keyHash -NewlyIssued }
            catch {
                $validationFailure = $_.Exception.Message
                $admin.RevokeCertificate($config.CaConfig, $certificate.SerialNumber, 0, [DateTime]::UtcNow)
                Write-Audit $data 'OutOfPolicyCertificateRevoked' "$DnsName $Profile RequestId=$($state.RequestId) $validationFailure"
                throw [Security.SecurityException]::new('The CA issued an out-of-policy certificate; it was revoked. Operator review is required.')
            }
            $state.Certificate = [Convert]::ToBase64String($certificate.RawData)
            Save-CertificateInventory $certificate $Scope
            Write-JsonFile $path $state
            Write-Audit $data 'Issued' "$DnsName $Profile RequestId=$($state.RequestId) $($certificate.Thumbprint)"
            return @{ Certificate = $state.Certificate; RequestSha256 = $requestHash }
        }
        finally { $certificate.Dispose() }
    }
    finally {
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($client)
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($admin)
    }
}

Assert-CaConfiguration
if ($ValidateConfiguration) { return }
$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add($config.Prefix)
$listener.AuthenticationSchemes = [Net.AuthenticationSchemes]::Anonymous
$listener.TimeoutManager.EntityBody = [TimeSpan]::FromSeconds(10)
$listener.TimeoutManager.HeaderWait = [TimeSpan]::FromSeconds(10)
$listener.TimeoutManager.IdleConnection = [TimeSpan]::FromSeconds(15)

try {
    $listener.Start()
    Write-Audit $data 'ServerStarted' $config.Prefix
    $pending = $listener.GetContextAsync()
    $nextMaintenance = [DateTime]::UtcNow
    while ($listener.IsListening) {
        if ([DateTime]::UtcNow -ge $nextMaintenance) {
            Invoke-IdentityRetirement
            $nextMaintenance = [DateTime]::UtcNow.AddSeconds(30)
        }
        if (-not $pending.Wait([TimeSpan]::FromSeconds(1))) { continue }
        $context = $pending.GetAwaiter().GetResult()
        $status = 500
        $result = @{ Error = 'Enrollment failed; consult the CA-side audit log.' }
        try {
            $incoming = $context.Request
            if (-not $incoming.IsSecureConnection -or $incoming.HttpMethod -ne 'POST' -or
                $incoming.Url.DnsSafeHost -ine ([Uri]$config.Prefix).DnsSafeHost -or
                $incoming.Url.Query -or $incoming.Url.AbsolutePath -notin @('/enrollment/rdp', '/enrollment/credential', '/enrollment/bootstrap')) {
                throw [ArgumentException]::new('Only the configured HTTPS POST enrollment routes are supported.')
            }
            if ($incoming.ContentType -notmatch '^application/json(?:;|$)' -or
                $incoming.ContentLength64 -lt 1 -or $incoming.ContentLength64 -gt 16384) {
                throw [ArgumentException]::new('A JSON body with Content-Length 1-16384 is required.')
            }
            $reader = [IO.StreamReader]::new($incoming.InputStream, [Text.Encoding]::UTF8, $false)
            try { $body = $reader.ReadToEnd() }
            finally { $reader.Dispose() }
            if ($body.Length -gt 16384) { throw [ArgumentException]::new('Request body exceeds 16 KiB.') }
            $payload = $body | ConvertFrom-Json
            $properties = @($payload.PSObject.Properties)
            $profile = $incoming.Url.Segments[-1]
            if ($profile -eq 'bootstrap') {
                if ($properties.Count -ne 2 -or
                    @($properties | Where-Object { $_.Name -ceq 'Csr' -and $_.Value -is [string] }).Count -ne 1 -or
                    @($properties | Where-Object { $_.Name -ceq 'VmResourceId' -and $_.Value -is [string] }).Count -ne 1) {
                    throw [ArgumentException]::new('Bootstrap requires only Csr and VmResourceId string properties.')
                }
                $result = Register-BootstrapRequest $payload.VmResourceId $payload.Csr
            }
            else {
                $credential = $incoming.GetClientCertificate()
                if ($incoming.ClientCertificateError -ne 0) { throw [Security.SecurityException]::new('HTTP.sys rejected the client certificate.') }
                $hostEntry = Get-AuthorizedHost $credential
                if ($properties.Count -ne 1 -or $properties[0].Name -cne 'Csr' -or $properties[0].Value -isnot [string]) {
                    throw [ArgumentException]::new('The request must contain only the Csr string property.')
                }
                $scope = Get-OptionalValue $hostEntry VmId
                $result = Get-IssuedCertificate $payload.Csr $hostEntry.DnsName $profile $hostEntry.EnrollmentPublicKeySha256 -Scope $scope
            }
            $status = 200
        }
        catch [Security.SecurityException] {
            $status = 403
            Write-Audit $data 'Rejected' $_.Exception.ToString()
        }
        catch [ArgumentException] {
            $status = 400
            Write-Audit $data 'InvalidRequest' $_.Exception.ToString()
        }
        catch {
            Write-Audit $data 'ServerRequestFailure' $_.Exception.ToString()
        }
        finally {
            $bytes = [Text.Encoding]::UTF8.GetBytes(($result | ConvertTo-Json -Compress))
            $context.Response.StatusCode = $status
            $context.Response.ContentType = 'application/json'
            $context.Response.Headers['Cache-Control'] = 'no-store'
            $context.Response.ContentLength64 = $bytes.Length
            try { $context.Response.OutputStream.Write($bytes, 0, $bytes.Length) }
            finally { $context.Response.Close() }
        }
        $pending = $listener.GetContextAsync()
    }
}
catch {
    Write-Audit $data 'ServerFailure' $_.Exception.ToString()
    Write-Error $_
    exit 1
}
finally { $listener.Close() }
