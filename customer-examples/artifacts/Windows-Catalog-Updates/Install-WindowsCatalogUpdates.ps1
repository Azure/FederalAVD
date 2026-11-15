#region Initialization
$Script:Name = 'Install-WindowsCatalogUpdates'
#endregion

#region Supporting Functions
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

function Wait-WusaIdle {
    [CmdletBinding()]
    param (
        [int]$WaitSeconds = 300
    )
    $elapsed = 0
    Write-Log -Category Info -Message 'Pre-flight: checking for active wusa processes...'
    while ($elapsed -lt $WaitSeconds) {
        if (-not (Get-Process -Name 'wusa' -ErrorAction SilentlyContinue | Where-Object { -not $_.HasExited })) { break }
        Write-Log -Category Info -Message "Pre-flight: wusa is active. Waiting 10 s... ($elapsed / $WaitSeconds s elapsed)"
        Start-Sleep -Seconds 10
        $elapsed += 10
    }
    if ($elapsed -ge $WaitSeconds) {
        Write-Log -Category Warning -Message "Pre-flight: wusa was still active after $WaitSeconds seconds. Install may fail."
    }
    else {
        Write-Log -Category Info -Message 'Pre-flight: wusa serialization lock is free.'
    }
}

function Install-MsuPackage {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [int]$TimeoutMs = 600000
    )

    $fileName = Split-Path $Path -Leaf
    Write-Log -Category Info -Message "Installing MSU: '$fileName' via 'wusa.exe `"$Path`" /quiet /norestart'."
    Wait-WusaIdle

    try {
        $proc = Invoke-ApplicationProcess -FilePath 'wusa.exe' -ArgumentList "`"$Path`" /quiet /norestart" `
            -Action "'$fileName' MSU installer" -TimeoutMs $TimeoutMs -SuccessExitCodes @()
    }
    catch {
        Write-Log -Category Warning -Message $_
        return $false
    }

    switch ($proc.ExitCode) {
        0          { Write-Log -Category Info -Message "'$fileName' installed successfully."; return $true }
        3010       { Write-Log -Category Info -Message "'$fileName' installed successfully. A reboot is required."; return $true }
        2359302    { Write-Log -Category Info -Message "'$fileName' is already installed. Skipping."; return $true }
        2359303    { Write-Log -Category Warning -Message "'$fileName' is not applicable to this OS version or architecture. Skipping."; return $true }
        default    { Write-Log -Category Warning -Message "'$fileName' wusa.exe exited with code $($proc.ExitCode)."; return $false }
    }
}

function Install-CabPackage {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [int]$TimeoutMs = 600000
    )

    $fileName = Split-Path $Path -Leaf
    Write-Log -Category Info -Message "Installing CAB: '$fileName' via 'dism.exe /Online /Add-Package'."

    try {
        $proc = Invoke-ApplicationProcess -FilePath 'dism.exe' `
            -ArgumentList "/Online /Add-Package /PackagePath:`"$Path`" /Quiet /NoRestart" `
            -Action "'$fileName' DISM installer" -TimeoutMs $TimeoutMs -SuccessExitCodes @()
    }
    catch {
        Write-Log -Category Warning -Message $_
        return $false
    }

    switch ($proc.ExitCode) {
        0           { Write-Log -Category Info -Message "'$fileName' installed successfully."; return $true }
        3010        { Write-Log -Category Info -Message "'$fileName' installed successfully. A reboot is required."; return $true }
        # 0x800f081e - package not applicable to this image
        -2146498530 { Write-Log -Category Warning -Message "'$fileName' is not applicable to this OS version or architecture. Skipping."; return $true }
        # 0x800f0805 - package already installed
        -2146498555 { Write-Log -Category Info -Message "'$fileName' is already installed. Skipping."; return $true }
        default     { Write-Log -Category Warning -Message "'$fileName' dism.exe exited with code $($proc.ExitCode)."; return $false }
    }
}

#endregion

## MAIN

#region Initialization

New-Log (Join-Path -Path $Env:SystemRoot -ChildPath 'Logs') -Name 'Install-WindowsCatalogUpdates'
$ErrorActionPreference = 'Stop'
Write-Log -Category Info -Message "Starting '$PSCommandPath'."

$InstallerTimeoutMs = 600000 # 10 minutes

# Collect packages. Sort by name so prerequisite updates (e.g. servicing stack)
# installed first when filenames are prefixed with a sequence number (01-, 02-, ...).
$MsuFiles = @(Get-ChildItem -Path $PSScriptRoot -Filter '*.msu' | Sort-Object Name)
$CabFiles = @(Get-ChildItem -Path $PSScriptRoot -Filter '*.cab' | Sort-Object Name)

if ($MsuFiles.Count -eq 0 -and $CabFiles.Count -eq 0) {
    Write-Log -Category Error -Message "No .msu or .cab files found in '$PSScriptRoot'."
    throw "No Windows Update packages found in '$PSScriptRoot'."
}

Write-Log -Category Info -Message "Found $($MsuFiles.Count) MSU file(s) and $($CabFiles.Count) CAB file(s) to install."

#endregion

#region Install MSU Packages

$failures = 0

foreach ($msu in $MsuFiles) {
    if (-not (Install-MsuPackage -Path $msu.FullName -TimeoutMs $InstallerTimeoutMs)) {
        $failures++
    }
}

#endregion

#region Install CAB Packages

foreach ($cab in $CabFiles) {
    if (-not (Install-CabPackage -Path $cab.FullName -TimeoutMs $InstallerTimeoutMs)) {
        $failures++
    }
}

#endregion

Write-Log -Category Info -Message "Completed '$PSCommandPath'."
if ($failures -gt 0) {
    Write-Log -Category Error -Message "$failures update(s) failed to install. Review the log for details."
    exit 1
}
else {
    Write-Log -Category Info -Message "All Windows Catalog updates installed successfully."
}
