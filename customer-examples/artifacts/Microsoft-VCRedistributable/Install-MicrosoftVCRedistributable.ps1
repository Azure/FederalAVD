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

function Get-InstallerFile {
    param (
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string]$DownloadUrl,
        [Parameter(Mandatory = $true)][string]$DownloadDirectory
    )
    $installer = Get-ChildItem -LiteralPath $Directory -Filter $FileName -File -ErrorAction Stop | Select-Object -First 1
    if ($installer) {
        Write-Log -Message "Using pre-staged installer: '$($installer.FullName)'."
        return $installer.FullName
    }
    $downloadPath = Join-Path $DownloadDirectory $FileName
    Write-Log -Message "No local '$FileName' found in '$Directory'. Downloading from '$DownloadUrl'..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $client = New-Object System.Net.WebClient
    try { $client.DownloadFile($DownloadUrl, $downloadPath) }
    finally { $client.Dispose() }
    Write-Log -Message "Downloaded to '$downloadPath' ($('{0:N1}' -f ((Get-Item $downloadPath).Length / 1MB)) MB)."
    return $downloadPath
}

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
#endregion

## MAIN

#region Initialization
New-Log (Join-Path -Path $Env:SystemRoot -ChildPath 'Logs') -Name 'Install-MicrosoftVCRedistributable'
$ErrorActionPreference = 'Stop'
Write-Log -Category Info -Message "Starting '$PSCommandPath'."
#endregion

#region Install

$Architectures = if ($Architecture -eq 'Both') { @('x64', 'x86') } else { @($Architecture) }
$Failed = @()

foreach ($Arch in $Architectures) {
    $displayName = "$SoftwareName ($Arch)"
    $pathExe = Get-InstallerFile -Directory $PSScriptRoot -FileName "vc_redist.$Arch.exe" `
        -DownloadUrl $DownloadUrls[$Arch] -DownloadDirectory $env:TEMP
    Write-Log -Message "Installing '$displayName': '$pathExe /install /quiet /norestart'."
    try {
        $installer = Invoke-ApplicationProcess -FilePath $pathExe -ArgumentList '/install /quiet /norestart' `
            -Action "'$displayName' installer" -SuccessExitCodes $SuccessExitCodes
    }
    catch {
        Write-Log -Category Error -Message $_
        $Failed += $Arch
        continue
    }
    switch ($installer.ExitCode) {
        3010    { Write-Log -Message "'$displayName' installed successfully. A reboot is required." }
        1638    { Write-Log -Message "'$displayName': a higher or equal version is already installed. Skipped." }
        default { Write-Log -Message "'$displayName' installed successfully." }
    }
}

if ($Failed.Count -gt 0) {
    Write-Log -Category Error -Message "Installation failed for: $($Failed -join ', '). Review the log for details."
    exit 1
}

Write-Log -Category Info -Message "Completed '$SoftwareName' installation."
#endregion
