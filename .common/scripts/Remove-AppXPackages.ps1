param(
    [Parameter(Mandatory=$true)]
    [string]$AppsToRemove
)

$ErrorActionPreference = 'Stop'
$LogFile = "$env:SystemRoot\Logs\Remove-Apps.log"

function Write-Log {
    param(
        [parameter(ValueFromPipeline=$True, Mandatory=$True, Position=0)]
        [AllowEmptyString()]
        [string]$Message
    )
    $Entry = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')] $Message"
    Add-Content -Path $LogFile -Value $Entry -ErrorAction SilentlyContinue
    Write-Output $Entry
}

try {
    Write-Log "Starting Remove-Apps script with the following parameters:"
    Write-Log ($PSBoundParameters | Format-Table -AutoSize | Out-String)
    [array]$apps = $AppsToRemove.replace('\"', '"') | ConvertFrom-Json

    # Image build context: no user profiles exist, so only provisioned package removal is relevant.
    # Get-AppxPackage -AllUsers is intentionally omitted -- it is unnecessary on a fresh image and
    # can hang in environments where the AppX deployment stack is held by a concurrently-provisioned
    # extension (e.g. Defender for Endpoint, Guest Configuration).

    # --- Pre-flight: AppX/DISM readiness checks ---

    # 1. Check whether Windows Modules Installer (TrustedInstaller / TiWorker) is actively running.
    #    An active CBS/servicing pass holds the DISM session lock -- any concurrent DISM call will hang
    #    until it releases. Wait up to 3 minutes for it to finish; warn and continue if it does not.
    Write-Log "Pre-flight: checking for active CBS/DISM operations (TiWorker / TrustedInstaller)..."
    $dismWaitSeconds = 180
    $dismPollInterval = 10
    $dismElapsed = 0
    while ($dismElapsed -lt $dismWaitSeconds) {
        $cbsActive = Get-Process -Name 'TiWorker', 'TrustedInstaller' -ErrorAction SilentlyContinue |
                     Where-Object { -not $_.HasExited }
        if (-not $cbsActive) { break }
        Write-Log "Pre-flight: CBS/DISM in use ($($cbsActive.Name -join ', ')). Waiting $dismPollInterval s... ($dismElapsed / $dismWaitSeconds s elapsed)"
        Start-Sleep -Seconds $dismPollInterval
        $dismElapsed += $dismPollInterval
    }
    if ($dismElapsed -ge $dismWaitSeconds) {
        Write-Log "WARNING: CBS/DISM was still active after $dismWaitSeconds seconds. AppX operations may hang or fail."
    }
    else {
        Write-Log "Pre-flight: no active CBS/DISM operations detected."
    }

    # 2. Check for a pending reboot from Component Based Servicing (informational -- does not abort).
    #    A pending CBS reboot means component state is not fully committed; AppX operations that touch
    #    those components can queue behind the pending pass and appear to hang.
    $pendingReboot = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                     (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
                     ($null -ne (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue))
    if ($pendingReboot) {
        Write-Log "WARNING: A pending reboot was detected. AppX operations may behave unexpectedly. Consider restarting the VM before running this script."
    }
    else {
        Write-Log "Pre-flight: no pending reboot detected."
    }

    # --- AppX provisioned package removal ---

    Write-Log "Enumerating provisioned AppX packages..."
    $ProvisionedApps = Get-AppxProvisionedPackage -Online

    foreach ($app in $apps) {
        $match = $ProvisionedApps | Where-Object { $_.DisplayName -eq $app }
        if ($match) {
            Write-Log "Removing provisioned AppX package [$app]"
            try {
                $match | Remove-AppxProvisionedPackage -Online -ErrorAction Stop
                Write-Log "Successfully removed provisioned AppX package [$app]."
            }
            catch {
                Write-Log "WARNING: Failed to remove provisioned package [$app]: $($_.Exception.Message)"
            }
        }
        else {
            Write-Log "Provisioned AppX package [$app] not found -- skipping."
        }
    }

    # If new Outlook was in the removal list, block the Windows Update Orchestrator from
    # reinstalling it. Two mechanisms exist depending on OS version:
    #
    # Windows 11 23H2+: Windows Update uses an Orchestrator subkey to schedule the push-install.
    #   Removing that subkey prevents reinstallation. On devices with the March 2024 non-security
    #   preview CU (or later) for Windows 11 23H2, Remove-AppxProvisionedPackage alone is enough;
    #   the key deletion is belt-and-suspenders for older 23H2 builds.
    #   Ref: https://learn.microsoft.com/en-us/microsoft-365-apps/outlook/get-started/control-install
    #
    # Windows 10: A REG_SZ value BlockedOobeUpdaters in the parent Orchestrator key prevents the
    #   January/February 2025 Windows 10 update from installing the app.
    if ($apps -contains 'Microsoft.OutlookForWindows') {
        Write-Log "Microsoft.OutlookForWindows in removal list -- blocking Windows Update Orchestrator reinstall."
        $oobeKey = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe'

        # Windows 11: remove the OutlookUpdate orchestrator subkey
        $outlookOrchestratorKey = Join-Path $oobeKey 'OutlookUpdate'
        if (Test-Path $outlookOrchestratorKey) {
            Remove-Item -Path $outlookOrchestratorKey -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Removed Orchestrator subkey: $outlookOrchestratorKey"
        }
        else {
            Write-Log "Orchestrator subkey not present (already clean or not applicable): $outlookOrchestratorKey"
        }

    }
}
catch {
    Write-Log "FATAL: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    if ($_.Exception.InnerException) { Write-Log "Inner exception: $($_.Exception.InnerException.Message)" }
    Write-Log $_.ScriptStackTrace
    Exit 1
}