$ErrorActionPreference = 'Stop'
$LogFile = "$env:SystemRoot\Logs\Check-CbsState-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

# instanceView.output keeps the first 4096 bytes and truncates the rest.
# To guarantee the RESTART_REQUIRED signal is never cut off, stdout is buffered
# during execution. At the end the signal is written first, then the full log
# follows. The log file is written in real time and has no size constraint.
# The outputBlobUri receives the same stdout so it also gets the signal first,
# followed by the full detail - making both readable and correct.
$script:OutputBuffer = [System.Collections.Generic.List[string]]@()

function Write-Log {
    param([string]$Message)
    $Entry = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')] $Message"
    Add-Content -Path $LogFile -Value $Entry -ErrorAction SilentlyContinue
    $null = $script:OutputBuffer.Add($Entry)
}

Write-Log "Checking CBS (Component Based Servicing) state."

# --- Wait for active CBS worker processes -----------------------------------
# TiWorker.exe (Windows Module Installer Worker) and TrustedInstaller.exe
# (Windows Modules Installer service host) actively mutate the component store.
# Reading the pending-reboot registry keys while either is running can give a
# false-negative: the keys may not be written until the process finishes.
# Wait up to 10 minutes for both to exit before inspecting the registry.
$CbsProcesses  = @('TiWorker', 'TrustedInstaller')
$WaitTimeout   = (Get-Date).AddMinutes(10)
$WaitedForAny  = $false

Write-Log "Waiting for CBS worker processes to finish (timeout 10 min)..."
do {
    $Running = @()
    foreach ($Name in $CbsProcesses) {
        $Procs = Get-Process -Name $Name -ErrorAction SilentlyContinue
        if ($Procs) { $Running += $Name }
    }

    if ($Running.Count -eq 0) { break }

    if (-not $WaitedForAny) {
        Write-Log "  Active CBS processes detected: $($Running -join ', '). Waiting for completion..."
        $WaitedForAny = $true
    } else {
        Write-Log "  Still running: $($Running -join ', '). Elapsed: $([int]((Get-Date) - ($WaitTimeout.AddMinutes(-10))).TotalSeconds)s"
    }

    if ((Get-Date) -ge $WaitTimeout) {
        Write-Log "  [WARN] CBS processes still running after 10 minutes: $($Running -join ', '). Proceeding with registry check anyway."
        break
    }

    Start-Sleep -Seconds 15
} while ($true)

if ($WaitedForAny) {
    Write-Log "CBS worker processes have exited. Proceeding with registry check."
} else {
    Write-Log "No active CBS worker processes found. Proceeding with registry check."
}

# --- Registry checks --------------------------------------------------------
$RebootPendingPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress'
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
)

$RebootRequired = $false
foreach ($Path in $RebootPendingPaths) {
    if (Test-Path $Path) {
        Write-Log "  [HIT]  $Path"
        $RebootRequired = $true
        break
    } else {
        Write-Log "  [OK]   $Path"
    }
}

if (-not $RebootRequired) {
    $SessionsPendingPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\SessionsPending'
    if (Test-Path $SessionsPendingPath) {
        $SessionsPending = Get-ItemProperty $SessionsPendingPath -ErrorAction SilentlyContinue
        $Exclusive = $SessionsPending.Exclusive
        Write-Log "  [CHK]  $SessionsPendingPath"
        Write-Log "         Exclusive=$Exclusive"
        if ($Exclusive -gt 0) {
            Write-Log "  [HIT]  CBS has $Exclusive pending exclusive session(s). Restart required to settle."
            $RebootRequired = $true
        } else {
            Write-Log "  [OK]   CBS SessionsPending.Exclusive is 0 or absent."
        }
    } else {
        Write-Log "  [OK]   CBS SessionsPending key not present."
    }
}

if ($RebootRequired) {
    Write-Log "Result: restart required - pending CBS operations must settle before customization."
} else {
    Write-Log "Result: no pending CBS state. Component store is settled."
}

# --- stdout output -----------------------------------------------------------
# The signal line is written first to guarantee it falls within the first 4096
# bytes of instanceView.output (which truncates from the bottom). The full
# timestamped log follows for diagnostic purposes.
if ($RebootRequired) { Write-Output "RESTART_REQUIRED=true" } else { Write-Output "RESTART_REQUIRED=false" }
Write-Output "--- timestamped execution log follows ---"
foreach ($Line in $script:OutputBuffer) { Write-Output $Line }
