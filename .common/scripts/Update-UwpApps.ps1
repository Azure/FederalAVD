function Write-OutputWithTimeStamp {
    param(
        [parameter(ValueFromPipeline=$True, Mandatory=$True, Position=0)]
        [string]$Message
    )
    $Timestamp = Get-Date -Format 'MM/dd/yyyy HH:mm:ss'
    $Entry = '[' + $Timestamp + '] ' + $Message
    Write-Output $Entry
}

function Get-ProvisionedPackageVersionMap {
    $map = @{}
    Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | ForEach-Object {
        $map[$_.DisplayName] = $_.Version
    }
    return $map
}

Start-Transcript -Path "$env:SystemRoot\Logs\Update-UwpApps.log" -Force
Write-Output "*********************************"
Write-Output "Updating Built-In UWP Apps via InstallService"
Write-Output "*********************************"

$TaskPath = '\Microsoft\Windows\InstallService\'
$TaskName = 'ScanForUpdates'

$Task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
If (-not $Task) {
    Write-Warning "Scheduled task '$TaskPath$TaskName' not found. Skipping Store app updates."
    Stop-Transcript
    Exit 0
}

# Snapshot versions before triggering the scan so we can detect and report actual changes.
Write-OutputWithTimeStamp "Snapshotting current provisioned package versions..."
$VersionsBefore = Get-ProvisionedPackageVersionMap
Write-OutputWithTimeStamp "Found $($VersionsBefore.Count) provisioned package(s)."

# Trigger the scan. Brief sleep gives the task scheduler time to transition to Running.
Write-OutputWithTimeStamp "Starting scheduled task '$TaskName'..."
Start-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName
Start-Sleep -Seconds 5

# Wait for the task itself to finish. The task orchestrates the scan and kicks off
# downloads/installs in the background - it does not block until they complete.
$TaskTimeoutSeconds  = 300
$TaskPollInterval    = 10
$TaskElapsed         = 0

Write-OutputWithTimeStamp "Waiting for task to complete (timeout: ${TaskTimeoutSeconds}s)..."
do {
    Start-Sleep -Seconds $TaskPollInterval
    $TaskElapsed += $TaskPollInterval
    $TaskState = (Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName).State
    Write-OutputWithTimeStamp "Task state: $TaskState ($TaskElapsed/${TaskTimeoutSeconds}s elapsed)"
} while ($TaskState -eq 'Running' -and $TaskElapsed -lt $TaskTimeoutSeconds)

$TaskResult = (Get-ScheduledTaskInfo -TaskPath $TaskPath -TaskName $TaskName).LastTaskResult
Write-OutputWithTimeStamp "Task completed. LastTaskResult: $TaskResult (0x0 = success)"

# The task completing means the scan is done and downloads have been queued, but the
# actual MSIX installs continue asynchronously. Wait a minimum time before polling
# so downloads have a chance to start and provisioned package versions begin changing.
$MinWaitSeconds = 60
Write-OutputWithTimeStamp "Waiting $MinWaitSeconds seconds for installs to begin..."
Start-Sleep -Seconds $MinWaitSeconds

# Poll provisioned package versions until they stop changing across two consecutive
# checks. This is the most reliable signal that all async installs have settled.
$StabilityTimeoutSeconds = 600
$StabilityPollInterval   = 30
$StableChecksRequired    = 2
$StableCount             = 0
$StabilityElapsed        = 0
$LastVersionMap          = Get-ProvisionedPackageVersionMap

Write-OutputWithTimeStamp "Polling for version stability (interval: ${StabilityPollInterval}s, timeout: ${StabilityTimeoutSeconds}s)..."

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
            Write-OutputWithTimeStamp "  [updating] $pkg : $($LastVersionMap[$pkg]) -> $($CurrentVersionMap[$pkg])"
        }
        Write-OutputWithTimeStamp "$(@($Changed).Count) package(s) changed this interval. Resetting stability counter. ($StabilityElapsed/${StabilityTimeoutSeconds}s elapsed)"
    } else {
        $StableCount++
        Write-OutputWithTimeStamp "No version changes detected (stable check $StableCount/$StableChecksRequired). ($StabilityElapsed/${StabilityTimeoutSeconds}s elapsed)"
    }

    $LastVersionMap = $CurrentVersionMap

    if ($StableCount -ge $StableChecksRequired) {
        Write-OutputWithTimeStamp "Version map stable for $StableChecksRequired consecutive checks. Updates complete."
        break
    }
}

if ($StabilityElapsed -ge $StabilityTimeoutSeconds -and $StableCount -lt $StableChecksRequired) {
    Write-Warning "Timed out after $StabilityTimeoutSeconds seconds before versions fully stabilized. Some packages may still be updating."
}

# Final summary — report everything that changed relative to the pre-scan snapshot.
Write-Output ""
Write-Output "*********************************"
Write-Output "Update Summary"
Write-Output "*********************************"
$FinalVersionMap = Get-ProvisionedPackageVersionMap
$Updated = $FinalVersionMap.Keys | Where-Object {
    $VersionsBefore.ContainsKey($_) -and $VersionsBefore[$_] -ne $FinalVersionMap[$_]
}
$NewPackages = $FinalVersionMap.Keys | Where-Object { -not $VersionsBefore.ContainsKey($_) }

if ($Updated) {
    Write-OutputWithTimeStamp "Packages updated ($(@($Updated).Count)):"
    foreach ($pkg in ($Updated | Sort-Object)) {
        Write-Output "  $pkg : $($VersionsBefore[$pkg]) -> $($FinalVersionMap[$pkg])"
    }
} else {
    Write-OutputWithTimeStamp "No provisioned package versions changed. The image may already be up to date."
}
if ($NewPackages) {
    Write-OutputWithTimeStamp "New packages added ($(@($NewPackages).Count)):"
    foreach ($pkg in ($NewPackages | Sort-Object)) {
        Write-Output "  $pkg : $($FinalVersionMap[$pkg])"
    }
}

Stop-Transcript