[CmdletBinding()]
param (
    [Parameter()]
    [ValidateSet('x64', 'x86', 'Both')]
    [string]$Architecture = 'x64',
    [int[]]$SuccessExitCodes = @(0, 3010, 1638)
)

#region Initialization
$SoftwareName = 'Microsoft Visual C++ Redistributable'
$Script:Name  = 'Install-MicrosoftVCRedistributable'

# aka.ms permanent redirect URLs always resolve to the latest Visual Studio 2015-2022 release.
$DownloadUrls = @{
    'x64' = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
    'x86' = 'https://aka.ms/vs/17/release/vc_redist.x86.exe'
}
#endregion

#region Supporting Functions
Function Write-Log {
    Param (
        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateSet("Info", "Warning", "Error")]
        $Category = 'Info',
        [Parameter(Mandatory = $true, Position = 1)]
        $Message
    )

    $Content = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')]`t$Category`t`t$Message"
    if (-not $env:SUPPRESS_FILELOG) {
        Add-Content $Script:Log $Content -ErrorAction SilentlyContinue
    }
    Switch ($Category) {
        'Info'    { Write-Host $Content }
        'Error'   { Write-Error $Content -ErrorAction Continue }
        'Warning' { Write-Warning $Content }
    }
}

function New-Log {
    Param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $Path
    )

    if ($env:SUPPRESS_FILELOG -eq '1') { return }
    $date = Get-Date -UFormat "%Y-%m-%d %H-%M-%S"
    Set-Variable logFile -Scope Script
    $script:logFile = "$Script:Name-$date.log"

    if ((Test-Path $path) -eq $false) {
        $null = New-Item -Path $path -type directory
    }

    $script:Log = Join-Path $path $logfile
    Add-Content $script:Log "Date`t`t`tCategory`t`tDetails"
}

function Install-VCRedist {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Arch
    )

    $FileName    = "vc_redist.$Arch.exe"
    $DisplayName = "$SoftwareName ($Arch)"

    # Use a pre-staged installer if present (supports air-gapped image builds).
    # If none is found, download the latest release from Microsoft via aka.ms.
    $PathExe = (Get-ChildItem -Path $PSScriptRoot -Filter $FileName | Select-Object -First 1).FullName

    if ($PathExe) {
        Write-Log -Category Info -Message "Using pre-staged installer: '$PathExe'."
    }
    else {
        $DownloadUrl  = $DownloadUrls[$Arch]
        $DownloadPath = Join-Path $env:TEMP $FileName
        Write-Log -Category Info -Message "No local '$FileName' found in '$PSScriptRoot'. Downloading from '$DownloadUrl'..."
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($DownloadUrl, $DownloadPath)
        Write-Log -Category Info -Message "Downloaded to '$DownloadPath' ($('{0:N1}' -f ((Get-Item $DownloadPath).Length / 1MB)) MB)."
        $PathExe = $DownloadPath
    }

    $InstallerTimeoutMs = 600000 # 10 minutes
    Write-Log -Category Info -Message "Installing '$DisplayName': '$PathExe /install /quiet /norestart'."
    $Installer = Start-Process -FilePath $PathExe -ArgumentList '/install /quiet /norestart' -PassThru
    if (-not $Installer.WaitForExit($InstallerTimeoutMs)) {
        $Installer.Kill()
        Write-Log -Category Error -Message "'$DisplayName' installer timed out after $($InstallerTimeoutMs / 60000) minutes and was terminated."
        return $false
    }

    if ($Installer.ExitCode -in $SuccessExitCodes) {
        switch ($Installer.ExitCode) {
            3010    { Write-Log -Category Info -Message "'$DisplayName' installed successfully. A reboot is required." }
            1638    { Write-Log -Category Info -Message "'$DisplayName': a higher or equal version is already installed. Skipped." }
            default { Write-Log -Category Info -Message "'$DisplayName' installed successfully." }
        }
        return $true
    }
    else {
        Write-Log -Category Error -Message "'$DisplayName' installer failed with exit code $($Installer.ExitCode)."
        return $false
    }
}
#endregion

## MAIN

#region Initialization
New-Log (Join-Path -Path $Env:SystemRoot -ChildPath 'Logs')
$ErrorActionPreference = 'Stop'
Write-Log -Category Info -Message "Starting '$PSCommandPath'."
#endregion

#region Install

$Architectures = if ($Architecture -eq 'Both') { @('x64', 'x86') } else { @($Architecture) }
$Failed = @()

foreach ($Arch in $Architectures) {
    if (-not (Install-VCRedist -Arch $Arch)) {
        $Failed += $Arch
    }
}

if ($Failed.Count -gt 0) {
    Write-Log -Category Error -Message "Installation failed for: $($Failed -join ', '). Review the log for details."
    exit 1
}

Write-Log -Category Info -Message "Completed '$SoftwareName' installation."
#endregion
