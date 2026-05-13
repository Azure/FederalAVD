param(
    [string]$BuildDir = ''
)

$ErrorActionPreference = 'Stop'
$LogFile = "$env:SystemRoot\Logs\Invoke-DiskCleanup.log"

function Write-Log {
    param([string]$Message)
    $Entry = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')] $Message"
    Add-Content -Path $LogFile -Value $Entry -ErrorAction SilentlyContinue
    Write-Output $Entry
}

try {
    If (-not [string]::IsNullOrEmpty($BuildDir) -and (Test-Path -Path $BuildDir)) {
        Write-Log "Removing build directory: $BuildDir"
        Remove-Item -Path $BuildDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Log "Clearing temp folders"
    Remove-Item -Path $env:SystemRoot\Temp\* -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $env:TEMP\* -Recurse -Force -ErrorAction SilentlyContinue

    Write-Log "Removing temp/log files from common locations"
    $scanPaths = @(
        "$env:SystemRoot\Prefetch",
        "$env:SystemRoot\SoftwareDistribution\Download",
        'C:\Windows\Logs\CBS',
        'C:\Windows\Logs\DISM',
        'C:\ProgramData\USOShared\Logs'
    )
    foreach ($scanPath in $scanPaths) {
        if (Test-Path -Path $scanPath) {
            Get-ChildItem -Path $scanPath -Include *.tmp, *.dmp, *.etl, *.log -File -Recurse -Force -ErrorAction SilentlyContinue |
                ForEach-Object {
                    try { Remove-Item $_.FullName -Force -ErrorAction Stop }
                    catch { Write-Log "  Skipped (locked/in-use): $($_.FullName)" }
                }
        }
    }

    Write-Log "Clearing WER folders"
    Remove-Item -Path $env:ProgramData\Microsoft\Windows\WER\Temp\* -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $env:ProgramData\Microsoft\Windows\WER\ReportArchive\* -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $env:ProgramData\Microsoft\Windows\WER\ReportQueue\* -Recurse -Force -ErrorAction SilentlyContinue

    Write-Log "Clearing BranchCache"
    Clear-BCCache -Force -ErrorAction SilentlyContinue

    Write-Log "Clearing Delivery Optimization cache"
    Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue

    Write-Log "Clearing recycle bin"
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue

    Write-Log "Clearing event logs"
    Get-WinEvent -ListLog * -ErrorAction SilentlyContinue |
        Where-Object { $_.RecordCount -gt 0 } |
        ForEach-Object {
            Write-Log "  Clearing event log '$($_.LogName)' with $($_.RecordCount) record(s)"
            try {
                wevtutil cl $_.LogName 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { Write-Log "  Failed to clear event log '$($_.LogName)' - Exit Code [$LASTEXITCODE]" }
                else { Write-Log "  Cleared event log '$($_.LogName)'" }
            }
            catch { Write-Log "  Failed to clear event log '$($_.LogName)' with Exception '$($_.Exception.Message)'" }
        }

    Write-Log "Disk cleanup complete."
}
catch {
    Write-Log "FATAL: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    If ($_.Exception.InnerException) { Write-Log "Inner exception: $($_.Exception.InnerException.Message)" }
    Write-Log $_.ScriptStackTrace
    Exit 1
}