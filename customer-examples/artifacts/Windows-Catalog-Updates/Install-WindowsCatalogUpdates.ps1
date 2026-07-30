#region Initialization
$Script:Name = 'Install-WindowsCatalogUpdates'
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

    $proc = Start-Process -FilePath 'wusa.exe' -ArgumentList "`"$Path`" /quiet /norestart" -PassThru
    if (-not $proc.WaitForExit($TimeoutMs)) {
        $proc.Kill()
        Write-Log -Category Warning -Message "'$fileName' MSU installer timed out after $($TimeoutMs / 60000) minutes and was terminated."
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

    $proc = Start-Process -FilePath 'dism.exe' `
        -ArgumentList "/Online /Add-Package /PackagePath:`"$Path`" /Quiet /NoRestart" `
        -PassThru
    if (-not $proc.WaitForExit($TimeoutMs)) {
        $proc.Kill()
        Write-Log -Category Warning -Message "'$fileName' DISM installer timed out after $($TimeoutMs / 60000) minutes and was terminated."
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

New-Log (Join-Path -Path $Env:SystemRoot -ChildPath 'Logs')
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

if ($failures -gt 0) {
    Write-Log -Category Warning -Message "Completed with $failures failure(s). Review the log for details."
}
else {
    Write-Log -Category Info -Message "All Windows Catalog updates installed successfully."
}

Write-Log -Category Info -Message "Completed '$PSCommandPath'."
