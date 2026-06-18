$ErrorActionPreference = 'Stop'
$LogFile = "$env:SystemRoot\Logs\Update-UwpApps.log"

function Write-Log {
    param(
        [parameter(ValueFromPipeline = $True, Mandatory = $True, Position = 0)]
        [AllowEmptyString()]
        [string]$Message
    )
    $Entry = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')] $Message"
    Add-Content -Path $LogFile -Value $Entry -ErrorAction SilentlyContinue
    Write-Output $Entry
}

function Get-ProvisionedPackageVersionMap {
    $map = @{}
    Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | ForEach-Object {
        $map[$_.DisplayName] = $_.Version
    }
    return $map
}

try {
    Write-Log "Updating Built-In UWP Apps via InstallService"

    # --- Pre-flight: DISM readiness checks ---

    # Check whether Windows Modules Installer (TrustedInstaller / TiWorker) is actively running.
    # An active CBS/servicing pass holds the DISM session lock -- any concurrent DISM call will hang
    # until it releases. Wait up to 3 minutes for it to finish; warn and continue if it does not.
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

    # Check for a pending reboot from Component Based Servicing (informational -- does not abort).
    # A pending CBS reboot means component state is not fully committed; AppX operations that touch
    # those components can queue behind the pending pass and appear to hang.
    $pendingReboot = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                     (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
                     ($null -ne (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue))
    if ($pendingReboot) {
        Write-Log "WARNING: A pending reboot was detected. AppX operations may behave unexpectedly."
    }
    else {
        Write-Log "Pre-flight: no pending reboot detected."
    }

    $TaskPath = '\Microsoft\Windows\InstallService\'
    $TaskName = 'ScanForUpdates'

    $Task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    If (-not $Task) {
        Write-Log "Scheduled task '$TaskPath$TaskName' not found. Skipping Store app updates."
        Exit 0
    }

    # Snapshot versions before triggering the scan so we can detect and report actual changes.
    Write-Log "Snapshotting current provisioned package versions..."
    $VersionsBefore = Get-ProvisionedPackageVersionMap
    Write-Log "Found $($VersionsBefore.Count) provisioned package(s)."

    # Snapshot the task's LastRunTime before triggering so we can confirm this invocation
    # actually executed (vs. reading a stale result from a previous run).
    $TaskInfoBefore = Get-ScheduledTaskInfo -TaskPath $TaskPath -TaskName $TaskName
    $LastRunTimeBefore = $TaskInfoBefore.LastRunTime
    Write-Log "Task LastRunTime before trigger: $LastRunTimeBefore"

    # Trigger the scan, then wait until the task enters Running state (or give up after
    # a startup window). This is more reliable than a blind sleep on a loaded build VM.
    Write-Log "Starting scheduled task '$TaskName'..."
    Start-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName

    $StartupTimeoutSeconds = 60
    $StartupElapsed        = 0
    $StartupPollInterval   = 2
    do {
        Start-Sleep -Seconds $StartupPollInterval
        $StartupElapsed += $StartupPollInterval
        $StartupState = (Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName).State
    } while ($StartupState -ne 'Running' -and $StartupElapsed -lt $StartupTimeoutSeconds)

    if ($StartupState -eq 'Running') {
        Write-Log "Task entered Running state after $($StartupElapsed) seconds."
    } else {
        Write-Log "Task did not enter Running state within $($StartupTimeoutSeconds) seconds. (current state: $($StartupState)). It may have started and completed very quickly."
    }

    # Wait for the task itself to finish. The task orchestrates the scan and kicks off
    # downloads/installs in the background - it does not block until they complete.
    $TaskTimeoutSeconds = 300
    $TaskPollInterval = 10
    $TaskElapsed = 0

    Write-Log "Waiting for task to complete (timeout: $($TaskTimeoutSeconds) seconds)..."
    do {
        Start-Sleep -Seconds $TaskPollInterval
        $TaskElapsed += $TaskPollInterval
        $TaskState = (Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName).State
        Write-Log "Task state: ($($TaskState) $($TaskElapsed)/$($TaskTimeoutSeconds) seconds elapsed)"
    } while ($TaskState -eq 'Running' -and $TaskElapsed -lt $TaskTimeoutSeconds)

    $TaskInfoAfter = Get-ScheduledTaskInfo -TaskPath $TaskPath -TaskName $TaskName
    $LastRunTimeAfter = $TaskInfoAfter.LastRunTime
    $LastTaskResult = $TaskInfoAfter.LastTaskResult

    $TaskActuallyRan = $LastRunTimeAfter -gt $LastRunTimeBefore
    if ($TaskActuallyRan) {
        Write-Log "Task completed. LastRunTime: $LastRunTimeAfter | LastTaskResult: $LastTaskResult (0x0 = success)"
    }
    else {
        Write-Log "WARNING: Task LastRunTime ($LastRunTimeAfter) did not advance beyond pre-trigger value ($LastRunTimeBefore). The task did not execute this run. Skipping stability polling."
    }

    # Poll provisioned package versions until they stop changing across two consecutive
    # checks. The task orchestrates the scan and kicks off downloads/installs in the
    # background; polling is the most reliable signal that all async installs have settled.
    if ($TaskActuallyRan) {
        $StabilityTimeoutSeconds = 600
        $StabilityPollInterval = 30
        $StableChecksRequired = 2
        $StableCount = 0
        $StabilityElapsed = 0
        $LastVersionMap = Get-ProvisionedPackageVersionMap

        Write-Log "Polling for version stability (interval: $StabilityPollInterval, timeout: $StabilityTimeoutSeconds)..."

        while ($StabilityElapsed -lt $StabilityTimeoutSeconds) {
            Start-Sleep -Seconds $StabilityPollInterval
            $StabilityElapsed += $StabilityPollInterval

            $CurrentVersionMap = Get-ProvisionedPackageVersionMap
            $Changed = $CurrentVersionMap.Keys | Where-Object {
                $LastVersionMap.ContainsKey($_) -and $LastVersionMap[$_] -ne $CurrentVersionMap[$_]
            }

            if ($Changed) {
                $StableCount = 0
                foreach ($pkg in $Changed) {
                    Write-Log "  [updating] $pkg : $($LastVersionMap[$pkg]) -> $($CurrentVersionMap[$pkg])"
                }
                Write-Log "$(@($Changed).Count) package(s) changed this interval. Resetting stability counter. $($StabilityElapsed)/$($StabilityTimeoutSeconds) elapsed"
            }
            else {
                $StableCount++
                Write-Log "No version changes detected (stable check $($StableCount)/$($StableChecksRequired)). $($StabilityElapsed)/$($StabilityTimeoutSeconds) elapsed"
            }

            $LastVersionMap = $CurrentVersionMap

            if ($StableCount -ge $StableChecksRequired) {
                Write-Log "Version map stable for $StableChecksRequired consecutive checks. Updates complete."
                break
            }
        }

        if ($StabilityElapsed -ge $StabilityTimeoutSeconds -and $StableCount -lt $StableChecksRequired) {
            Write-Log "Timed out after $StabilityTimeoutSeconds seconds before versions fully stabilized. Some packages may still be updating."
        }
    } # end if ($TaskActuallyRan)

    # Final summary — report everything that changed relative to the pre-scan snapshot.
    Write-Log "*********************************"
    Write-Log "Update Summary"
    Write-Log "*********************************"
    $FinalVersionMap = Get-ProvisionedPackageVersionMap
    $Updated = $FinalVersionMap.Keys | Where-Object {
        $VersionsBefore.ContainsKey($_) -and $VersionsBefore[$_] -ne $FinalVersionMap[$_]
    }
    $NewPackages = $FinalVersionMap.Keys | Where-Object { -not $VersionsBefore.ContainsKey($_) }

    if ($Updated) {
        Write-Log "Packages updated ($(@($Updated).Count)):"
        foreach ($pkg in ($Updated | Sort-Object)) {
            Write-Log "  $pkg : $($VersionsBefore[$pkg]) -> $($FinalVersionMap[$pkg])"
        }
    }
    else {
        Write-Log "No provisioned package versions changed. The image may already be up to date."
    }
    if ($NewPackages) {
        Write-Log "New packages added ($(@($NewPackages).Count)):"
        foreach ($pkg in ($NewPackages | Sort-Object)) {
            Write-Log "  $pkg : $($FinalVersionMap[$pkg])"
        }
    }
}
catch {
    Write-Log "FATAL: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    If ($_.Exception.InnerException) { Write-Log "Inner exception: $($_.Exception.InnerException.Message)" }
    Write-Log $_.ScriptStackTrace
    Exit 1
}