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

function Write-Log {
    param (
        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Category = 'Info',

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$Message
    )

    $content = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')]`t$Category`t`t$Message"
    if (-not $env:SUPPRESS_FILELOG) {
        Add-Content -LiteralPath $Script:Log -Value $content -ErrorAction SilentlyContinue
    }

    switch ($Category) {
        'Info' { Write-Host $content }
        'Warning' { Write-Warning $content }
        'Error' { Write-Error $content -ErrorAction Continue }
    }
}

function New-Log {
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Path
    )

    if ($env:SUPPRESS_FILELOG -eq '1') {
        return
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        $null = New-Item -Path $Path -ItemType Directory
    }

    $date = Get-Date -UFormat '%Y-%m-%d %H-%M-%S'
    $Script:Log = Join-Path $Path "$Script:Name-$date.log"
    Add-Content -LiteralPath $Script:Log -Value "Date`t`t`tCategory`t`tDetails"
}

function Wait-MsiexecIdle {
    param (
        [int]$WaitSeconds = 300
    )

    $elapsed = 0
    while ($elapsed -lt $WaitSeconds) {
        $activeInstallers = Get-Process -Name 'msiexec' -ErrorAction SilentlyContinue |
            Where-Object { -not $_.HasExited }
        if (-not $activeInstallers) {
            return
        }

        Write-Log -Message "msiexec is active. Waiting 10 seconds ($elapsed of $WaitSeconds seconds elapsed)."
        Start-Sleep -Seconds 10
        $elapsed += 10
    }

    throw "msiexec remained active after $WaitSeconds seconds."
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
New-Log -Path (Join-Path $env:SystemRoot 'Logs')
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
Wait-MsiexecIdle
$installer = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -PassThru
if (-not $installer.WaitForExit(600000)) {
    $installer.Kill()
    throw "'$SoftwareName' installation timed out after 10 minutes."
}

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