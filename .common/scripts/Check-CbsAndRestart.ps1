function Write-OutputWithTimeStamp {
    param([string]$Message)
    $Timestamp = Get-Date -Format 'MM/dd/yyyy HH:mm:ss'
    Write-Output "[$Timestamp] $Message"
}

Write-OutputWithTimeStamp "Checking CBS (Component Based Servicing) state before sysprep."

$RebootPendingPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress'
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
)

$RebootRequired = $false
foreach ($Path in $RebootPendingPaths) {
    if (Test-Path $Path) {
        Write-OutputWithTimeStamp "Pending reboot detected: $Path"
        $RebootRequired = $true
        break
    }
}

if (-not $RebootRequired) {
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\SessionsPending') {
        $Exclusive = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\SessionsPending' -ErrorAction SilentlyContinue).Exclusive
        if ($Exclusive -gt 0) {
            Write-OutputWithTimeStamp "CBS has $Exclusive pending exclusive session(s). Scheduling restart to allow CBS to settle."
            $RebootRequired = $true
        }
    }
}

if ($RebootRequired) {
    # shutdown /r /t N is fire-and-forget - the command returns immediately and the timer runs independently.
    # The script exits and ARM records success before the restart happens. No scheduled task needed.
    Write-OutputWithTimeStamp "Initiating restart in 30 seconds to allow pending CBS operations to complete before sysprep."
    shutdown /r /t 30 /f
} else {
    Write-OutputWithTimeStamp "No restart required. CBS is settled."
}
