#requires -Version 7.4
using namespace System.Security.Cryptography
using namespace System.Security.Cryptography.X509Certificates

[CmdletBinding()]
param(
    [ValidateSet('Prepare', 'Enroll', 'InstallCredential', 'Run')][string]$Operation = 'Run',
    [string]$CertificatePath
)

. "$PSScriptRoot\Common.ps1"
$root = Split-Path $PSScriptRoot -Parent
$data = Join-Path $root 'state'
$statePath = Join-Path $data 'host.json'
$mutex = [Threading.Mutex]::new($false, 'Global\FederalAVD-RdpCertificate-Host')
$locked = $false

function Get-StoreCertificate {
    param([string]$Thumbprint)
    if ($Thumbprint -cnotmatch '^[A-F0-9]{40}$') { throw 'Invalid certificate thumbprint in local state.' }
    Get-Item -LiteralPath "Cert:\LocalMachine\My\$Thumbprint" -ErrorAction Stop
}

function Get-Listener {
    Get-CimInstance -Namespace root\cimv2\TerminalServices -ClassName Win32_TSGeneralSetting `
        -Filter "TerminalName='RDP-tcp'" -ErrorAction Stop
}

function Read-Exact {
    param([IO.Stream]$Stream, [int]$Length)
    $bytes = [byte[]]::new($Length)
    $offset = 0
    while ($offset -lt $Length) {
        $count = $Stream.Read($bytes, $offset, $Length - $offset)
        if ($count -eq 0) { throw 'The RDP listener closed the negotiation connection.' }
        $offset += $count
    }
    return ,$bytes
}

function Assert-ListenerCertificate {
    param([string]$DnsName, [int]$Port, [string]$Thumbprint)
    $tcp = [Net.Sockets.TcpClient]::new()
    $tls = $null
    try {
        $tcp.ConnectAsync('127.0.0.1', $Port).WaitAsync([TimeSpan]::FromSeconds(10)).GetAwaiter().GetResult()
        $stream = $tcp.GetStream()
        $stream.ReadTimeout = 10000
        $stream.WriteTimeout = 10000
        # TPKT/X.224 requests TLS, CredSSP, or CredSSP with early user authorization.
        $request = [byte[]](3, 0, 0, 19, 14, 224, 0, 0, 0, 0, 0, 1, 0, 8, 0, 11, 0, 0, 0)
        $stream.Write($request, 0, $request.Length)
        $header = Read-Exact $stream 4
        $length = ([int]$header[2] * 256) + $header[3]
        if ($header[0] -ne 3 -or $length -ne 19) { throw 'Unexpected RDP negotiation response.' }
        $response = Read-Exact $stream ($length - 4)
        if ($response[7] -ne 2 -or [BitConverter]::ToUInt32($response, 11) -notin @(1, 2, 8)) {
            throw 'The RDP listener did not negotiate a supported TLS protocol.'
        }
        $tls = [Net.Security.SslStream]::new($stream, $false)
        $tls.ReadTimeout = 10000
        $tls.WriteTimeout = 10000
        $options = [Net.Security.SslClientAuthenticationOptions]::new()
        $options.TargetHost = $DnsName
        $options.EnabledSslProtocols = [Security.Authentication.SslProtocols]::Tls12 -bor [Security.Authentication.SslProtocols]::Tls13
        $options.CertificateRevocationCheckMode = [X509RevocationMode]::Online
        $tls.AuthenticateAsClient($options)
        $presented = [X509Certificate2]::new($tls.RemoteCertificate)
        try {
            if ($presented.Thumbprint -cne $Thumbprint) {
                throw 'RDP is not presenting the configured certificate. An approved service restart or reboot may be needed.'
            }
        }
        finally { $presented.Dispose() }
    }
    finally {
        if ($null -ne $tls) { $tls.Dispose() }
        $tcp.Dispose()
    }
}

function Request-Certificate {
    param($Configuration, [X509Certificate2]$Credential, [string]$Pem, [string]$Profile, [string]$VmResourceId)
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $handler.UseProxy = $false
    $handler.CheckCertificateRevocationList = $true
    $handler.SslProtocols = [Security.Authentication.SslProtocols]::Tls12 -bor [Security.Authentication.SslProtocols]::Tls13
    if ($null -ne $Credential) { [void]$handler.ClientCertificates.Add($Credential) }
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(90)
    $client.MaxResponseContentBufferSize = 16384
    $payload = @{ Csr = $Pem }
    if ($Profile -eq 'bootstrap') { $payload.VmResourceId = $VmResourceId }
    $content = [Net.Http.StringContent]::new(($payload | ConvertTo-Json -Compress), [Text.Encoding]::UTF8, 'application/json')
    $response = $null
    try {
        $response = $client.PostAsync("$($Configuration.EnrollmentUrl)$Profile", $content).GetAwaiter().GetResult()
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            throw [Net.Http.HttpRequestException]::new("Enrollment failed: HTTP $([int]$response.StatusCode). $body", $null, $response.StatusCode)
        }
        if ($body.Length -gt 16384) { throw 'The enrollment response exceeds 16 KiB.' }
        $result = $body | ConvertFrom-Json
        if ($result.RequestSha256 -cne (Get-BytesHash ([Text.Encoding]::UTF8.GetBytes($Pem)))) {
            throw 'The response is not bound to the submitted request.'
        }
        return [X509Certificate2]::new([Convert]::FromBase64String($result.Certificate))
    }
    finally {
        if ($null -ne $response) { $response.Dispose() }
        $content.Dispose()
        $client.Dispose()
    }
}

try {
    if (-not [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
        throw 'Run host operations as SYSTEM, using trusted provisioning or Azure Run Command.'
    }
    $locked = $mutex.WaitOne(0)
    if (-not $locked) { throw 'Another host certificate operation is already running.' }
    $config = Read-Configuration (Join-Path $root 'configuration.json') Host
    $vm = Get-AzureVmIdentity
    if ($Operation -eq 'Prepare') {
        if (Test-Path -LiteralPath $statePath) {
            $state = Read-JsonFile $statePath
            if ($state.VmId -ine $vm.VmId -or $state.VmResourceId -ine $vm.VmResourceId -or $state.DnsName -cne $config.DnsName) {
                throw 'Host state belongs to another VM incarnation or DNS name. Never capture enrollment state in an image.'
            }
        }
        else {
            $state = [pscustomobject]@{
                EnrollmentKey = (New-MachineKey); EnrollmentThumbprint = $null
                RdpKey = $null; RdpPem = $null; RdpThumbprint = $null
                OriginalThumbprint = $null; VmId = $vm.VmId; VmResourceId = $vm.VmResourceId; DnsName = $config.DnsName
            }
            Write-JsonFile $statePath $state
        }
        $key = Open-MachineRsa $state.EnrollmentKey
        try {
            $request = New-ProfileRequest $config.DnsName $key credential
            $pem = $request.CreateSigningRequestPem()
            [IO.File]::WriteAllText((Join-Path $data 'enrollment.req'), $pem, [Text.Encoding]::ASCII)
            Write-Output "Enrollment CSR: $(Join-Path $data 'enrollment.req')"
            Write-Output "EnrollmentPublicKeySha256: $(Get-PublicKeyHash $request.PublicKey)"
            $proof = @{
                Version = 1; VmId = $vm.VmId; VmResourceId = $vm.VmResourceId; DnsName = $config.DnsName
                EnrollmentPublicKeySha256 = (Get-PublicKeyHash $request.PublicKey)
                RequestSha256 = (Get-BytesHash ([Text.Encoding]::UTF8.GetBytes($pem)))
            }
            Write-Output "FEDERALAVD_RDP_BOOTSTRAP:$($proof | ConvertTo-Json -Compress)"
        }
        finally { $key.Dispose() }
        return
    }
    $state = Read-JsonFile $statePath
    if ($state.VmId -ine $vm.VmId -or $state.VmResourceId -ine $vm.VmResourceId -or $state.DnsName -cne $config.DnsName) {
        throw 'Enrollment state is not bound to this VM incarnation and DNS name.'
    }
    $credentialKey = Open-MachineRsa $state.EnrollmentKey
    try {
        $credentialRequest = New-ProfileRequest $config.DnsName $credentialKey credential
        if ($Operation -eq 'Enroll' -and -not $state.EnrollmentThumbprint) {
            $pem = $credentialRequest.CreateSigningRequestPem()
            $certificate = $null
            for ($attempt = 0; $attempt -lt 3; $attempt++) {
                try {
                    $certificate = Request-Certificate $config $null $pem bootstrap $vm.VmResourceId
                    break
                }
                catch [Net.Http.HttpRequestException] {
                    if ($attempt -eq 2 -or $null -eq $_.Exception.StatusCode -or
                        ([int]$_.Exception.StatusCode -lt 500 -and [int]$_.Exception.StatusCode -ne 429)) { throw }
                    Write-Audit $data 'BootstrapRetry' $_.Exception.Message
                    Start-Sleep -Seconds 10
                }
            }
            try {
                Assert-Certificate $certificate $config.DnsName credential $config (Get-PublicKeyHash $credentialRequest.PublicKey) -NewlyIssued
                Add-MachineCertificate $certificate $credentialKey
                $state.EnrollmentThumbprint = $certificate.Thumbprint
                Write-JsonFile $statePath $state
                Write-Audit $data 'AutomaticBootstrapInstalled' $certificate.Thumbprint
            }
            finally { $certificate.Dispose() }
        }
        if ($Operation -eq 'InstallCredential') {
            $certificate = [X509Certificate2]::new([IO.File]::ReadAllBytes($CertificatePath))
            try {
                Assert-Certificate $certificate $config.DnsName credential $config (Get-PublicKeyHash $credentialRequest.PublicKey) -NewlyIssued
                Add-MachineCertificate $certificate $credentialKey
                $state.EnrollmentThumbprint = $certificate.Thumbprint
                Write-JsonFile $statePath $state
                Write-Audit $data 'CredentialInstalled' $certificate.Thumbprint
            }
            finally { $certificate.Dispose() }
            return
        }
        $credential = Get-StoreCertificate $state.EnrollmentThumbprint
        Assert-Certificate $credential $config.DnsName credential $config (Get-PublicKeyHash $credentialRequest.PublicKey)
        if (-not $credential.HasPrivateKey) { throw 'The enrollment credential has no accessible private key.' }
        if ($credential.NotAfter.ToUniversalTime() -lt [DateTime]::UtcNow.AddDays($config.RenewBeforeDays)) {
            $pem = $credentialRequest.CreateSigningRequestPem()
            $renewed = Request-Certificate $config $credential $pem credential
            try {
                Assert-Certificate $renewed $config.DnsName credential $config (Get-PublicKeyHash $credentialRequest.PublicKey) -NewlyIssued
                Add-MachineCertificate $renewed $credentialKey
                $state.EnrollmentThumbprint = $renewed.Thumbprint
                Write-JsonFile $statePath $state
                Write-Audit $data 'CredentialRenewed' $renewed.Thumbprint
            }
            finally { $renewed.Dispose() }
            $credential = Get-StoreCertificate $state.EnrollmentThumbprint
        }
        $needsCertificate = $true
        if ($state.RdpThumbprint) {
            $current = Get-StoreCertificate $state.RdpThumbprint
            $needsCertificate = $current.NotAfter.ToUniversalTime() -lt [DateTime]::UtcNow.AddDays($config.RenewBeforeDays)
        }
        if ($needsCertificate) {
            if (-not $state.RdpPem) {
                $state.RdpKey = New-MachineKey
                $key = Open-MachineRsa $state.RdpKey
                try { $state.RdpPem = (New-ProfileRequest $config.DnsName $key rdp).CreateSigningRequestPem() }
                finally { $key.Dispose() }
                Write-JsonFile $statePath $state
            }
            $request = Read-ValidatedRequest $state.RdpPem $config.DnsName rdp
            $certificate = Request-Certificate $config $credential $state.RdpPem rdp
            $key = Open-MachineRsa $state.RdpKey
            try {
                Assert-Certificate $certificate $config.DnsName rdp $config (Get-PublicKeyHash $request.PublicKey) -NewlyIssued
                Add-MachineCertificate $certificate $key
                $state.RdpThumbprint = $certificate.Thumbprint
                $state.RdpPem = $null
                Write-JsonFile $statePath $state
                Write-Audit $data 'RdpCertificateInstalled' $certificate.Thumbprint
            }
            finally { $certificate.Dispose(); $key.Dispose() }
        }
        $current = Get-StoreCertificate $state.RdpThumbprint
        $key = Open-MachineRsa $state.RdpKey
        try {
            $request = New-ProfileRequest $config.DnsName $key rdp
            Assert-Certificate $current $config.DnsName rdp $config (Get-PublicKeyHash $request.PublicKey)
        }
        finally { $key.Dispose() }
        Set-KeyPermissions $state.EnrollmentKey
        Set-KeyPermissions $state.RdpKey -Rdp
        $listener = Get-Listener
        if ($listener.SSLCertificateSHA1Hash -ine $current.Thumbprint) {
            if (-not $state.OriginalThumbprint) {
                if ([string]::IsNullOrWhiteSpace($listener.SSLCertificateSHA1Hash)) {
                    throw 'Cannot identify the former listener certificate. Resolve its thumbprint before changing the binding.'
                }
                $state.OriginalThumbprint = $listener.SSLCertificateSHA1Hash.ToUpperInvariant()
                Write-JsonFile $statePath $state
            }
            $oldHash = $listener.SSLCertificateSHA1Hash
            try {
                $listener | Set-CimInstance -Property @{ SSLCertificateSHA1Hash = $current.Thumbprint } -ErrorAction Stop | Out-Null
                if ((Get-Listener).SSLCertificateSHA1Hash -ine $current.Thumbprint) { throw 'RDP binding read-back failed.' }
            }
            catch {
                $listener | Set-CimInstance -Property @{ SSLCertificateSHA1Hash = $oldHash } -ErrorAction Stop | Out-Null
                throw
            }
        }
        Assert-ListenerCertificate $config.DnsName $config.RdpPort $current.Thumbprint
        # Delete only the recorded former listener certificate, not arbitrary self-signed certificates.
        if ($state.OriginalThumbprint -cmatch '^[A-F0-9]{40}$' -and $state.OriginalThumbprint -cne $current.Thumbprint) {
            $oldPath = "Cert:\LocalMachine\Remote Desktop\$($state.OriginalThumbprint)"
            if (Test-Path -LiteralPath $oldPath) {
                $old = Get-Item -LiteralPath $oldPath
                if ($old.Subject -ceq $old.Issuer -and $old.Subject -in @("CN=$env:COMPUTERNAME", "CN=$($config.DnsName)")) {
                    Remove-Item -LiteralPath $oldPath -ErrorAction Stop
                    Write-Audit $data 'OriginalSelfSignedCertificateRemoved' $state.OriginalThumbprint
                }
                else { throw 'The former listener certificate is not an identifiable host self-signed certificate; review it manually.' }
            }
        }
        Write-Audit $data 'ListenerVerified' $current.Thumbprint
        $bootstrap = @(Get-ScheduledTask -ErrorAction Stop | Where-Object {
            $_.TaskPath -eq '\FederalAVD\' -and $_.TaskName -eq 'RdpCertificate-Bootstrap'
        })
        if ($bootstrap.Count -gt 0) {
            Unregister-ScheduledTask -TaskPath '\FederalAVD\' -TaskName 'RdpCertificate-Bootstrap' -Confirm:$false -ErrorAction Stop
        }
        $ready = @{ Version = 1; VmId = $vm.VmId; VmResourceId = $vm.VmResourceId; DnsName = $config.DnsName; Thumbprint = $current.Thumbprint }
        Write-Output "FEDERALAVD_RDP_READY:$($ready | ConvertTo-Json -Compress)"
    }
    finally { $credentialKey.Dispose() }
}
catch {
    Write-Audit $data 'HostFailure' $_.Exception.ToString()
    Write-Error $_
    exit 1
}
finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
