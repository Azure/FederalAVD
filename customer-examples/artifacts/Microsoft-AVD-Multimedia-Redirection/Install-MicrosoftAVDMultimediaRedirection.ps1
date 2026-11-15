[CmdletBinding()]
param (
    [Parameter()]
    [bool]$InstallEdgeExtension = $true,

    [Parameter()]
    [bool]$InstallChromeExtension = $true,

    [Parameter()]
    [int[]]$SuccessExitCodes = @(0, 3010)
)

$SoftwareName = 'Microsoft Multimedia Redirection Service'
$Script:Name = 'Install-MicrosoftAVDMultimediaRedirection'
$DownloadUrl = 'https://aka.ms/avdmmr/msi'
$InstallerFileName = 'MsMMRHostInstaller_x64.msi'
$EdgeExtension = 'joeclbldhdmoijbaagobkhlpfjglcihd;https://edge.microsoft.com/extensionwebstorebase/v1/crx'
$ChromeExtension = 'lfmemoeeciijgkjkgbgikoonlkabmlno;https://clients2.google.com/service/update2/crx'

function Invoke-ApplicationProcess {
    param (
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$Action,
        [int[]]$SuccessExitCodes = @(0, 3010),
        [int]$TimeoutMs = 600000
    )
    $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru -ErrorAction Stop
    # Windows PowerShell needs a retained handle to read ExitCode after WaitForExit.
    $null = $process.Handle
    if (-not $process.WaitForExit($TimeoutMs)) { $process.Kill(); throw "$Action timed out." }
    if ($null -eq $process.ExitCode) { throw "$Action did not report an exit code." }
    if ($SuccessExitCodes.Count -gt 0 -and $process.ExitCode -notin $SuccessExitCodes) {
        throw "$Action failed with exit code $($process.ExitCode)."
    }
    return $process
}

function Write-Log {
    param (
        [Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')][string]$Category = 'Info'
    )
    $content = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')]`t$Category`t`t$Message"
    if ($env:SUPPRESS_FILELOG -ne '1') {
        Add-Content -LiteralPath $script:Log -Value $content -ErrorAction Stop
    }
    switch ($Category) {
        'Info' { Write-Host $content }
        'Warning' { Write-Warning $content }
        'Error' { Write-Error $content -ErrorAction Continue }
    }
}

function New-Log {
    param (
        [Parameter(Position = 0)][string]$Path,
        [string]$Name = 'Artifact',
        [string]$FilePath
    )
    if ($env:SUPPRESS_FILELOG -eq '1') { return }
    if ($FilePath) {
        $script:Log = $FilePath
        $Path = Split-Path $FilePath -Parent
    }
    else {
        if ([string]::IsNullOrWhiteSpace($Path)) { throw 'A log directory or FilePath is required.' }
        $script:Log = Join-Path $Path "$Name-$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').log"
    }
    New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop | Out-Null
    Add-Content -LiteralPath $script:Log -Value "Date`t`t`tCategory`t`tDetails" -ErrorAction Stop
}

function Invoke-MsiProcess {
    param (
        [Parameter(Mandatory = $true)][string]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$Action,
        [int]$TimeoutMs = 600000,
        [int]$MaxAttempts = 11,
        [int]$RetryDelaySeconds = 30
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $process = Invoke-ApplicationProcess -FilePath 'msiexec.exe' -ArgumentList $ArgumentList `
            -Action $Action -TimeoutMs $TimeoutMs -SuccessExitCodes @()
        if ($process.ExitCode -ne 1618) { return $process }
        if ($attempt -eq $MaxAttempts) {
            throw "$Action failed after $MaxAttempts attempts with exit code 1618 (another installation is already in progress)."
        }
        Write-Log -Category Warning -Message "$Action returned exit code 1618. Retrying in $RetryDelaySeconds seconds (attempt $attempt of $MaxAttempts)."
        Start-Sleep -Seconds $RetryDelaySeconds
    }
}

function Assert-MicrosoftSignature {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        throw "The installer at '$Path' does not have a valid Microsoft signature."
    }
}

function Add-ExtensionInstallPolicy {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Extension
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        $null = New-Item -Path $Path -Force
    }

    $properties = Get-ItemProperty -LiteralPath $Path
    $existingNames = @($properties.PSObject.Properties.Name | Where-Object { $_ -match '^\d+$' })
    foreach ($name in $existingNames) {
        if ($properties.$name -eq $Extension) {
            Write-Log -Message "Browser extension policy '$Extension' is already configured at '$Path'."
            return
        }
    }

    $nextName = if ($existingNames.Count -eq 0) {
        1
    }
    else {
        [int](($existingNames | ForEach-Object { [int]$_ } | Measure-Object -Maximum).Maximum) + 1
    }

    $null = New-ItemProperty -LiteralPath $Path -Name $nextName -PropertyType String -Value $Extension -Force
    Write-Log -Message "Configured browser extension policy '$Extension' at '$Path'."
}

$ErrorActionPreference = 'Stop'
New-Log -Path (Join-Path $env:SystemRoot 'Logs') -Name 'Install-MicrosoftAVDMultimediaRedirection'
Write-Log -Message "Starting '$PSCommandPath'."

$installerPath = Join-Path $PSScriptRoot $InstallerFileName
if (Test-Path -LiteralPath $installerPath -PathType Leaf) {
    Write-Log -Message "Using pre-staged installer '$installerPath'."
}
else {
    $installerPath = Join-Path $env:TEMP $InstallerFileName
    Write-Log -Message "Downloading '$SoftwareName' from '$DownloadUrl'."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $installerPath -UseBasicParsing
}

Assert-MicrosoftSignature -Path $installerPath

$runningBrowsers = @(Get-Process -Name 'msedge', 'chrome' -ErrorAction SilentlyContinue)
if ($runningBrowsers.Count -gt 0) {
    throw 'Microsoft Edge and Google Chrome must be closed before installing multimedia redirection.'
}

$msiLogPath = Join-Path $env:SystemRoot "Logs\$Script:Name-msiexec.log"
$arguments = "/i `"$installerPath`" /quiet /norestart /L*v `"$msiLogPath`""
Write-Log -Message "Installing '$SoftwareName'."
$installer = Invoke-MsiProcess -ArgumentList $arguments -Action "'$SoftwareName' installation"

if ($installer.ExitCode -notin $SuccessExitCodes) {
    throw "'$SoftwareName' installation failed with exit code $($installer.ExitCode). Review '$msiLogPath'."
}

if ($InstallEdgeExtension) {
    Add-ExtensionInstallPolicy -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist' -Extension $EdgeExtension
}

if ($InstallChromeExtension) {
    Add-ExtensionInstallPolicy -Path 'HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist' -Extension $ChromeExtension
}

if ($installer.ExitCode -eq 3010) {
    Write-Log -Message "'$SoftwareName' installed successfully. A restart is required."
}
else {
    Write-Log -Message "'$SoftwareName' installed successfully."
}

Write-Log -Message "Completed '$SoftwareName' installation."