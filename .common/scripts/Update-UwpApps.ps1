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
    # Returns a hashtable of Name -> Version for all provisioned AppX packages.
    # Provisioned packages are the per-image packages that apply to all users,
    # which is what the Store update scan targets.
    $map = @{}
    Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | ForEach-Object {
        $map[$_.DisplayName] = $_.Version
    }
    return $map
}

Start-Transcript -Path "$env:SystemRoot\Logs\Update-UwpApps.log" -Force
Write-Output "*********************************"
Write-Output "Updating Built-In UWP Apps"
Write-Output "*********************************"

$Namespace = "root\cimv2\mdm\dmmap"
$ClassName = "MDM_EnterpriseModernAppManagement_AppManagement01"

# Timings:
#   MinWaitSeconds   - mandatory pause after triggering the scan. The MDM call is
#                      fire-and-forget; the Store service needs time to evaluate
#                      what needs updating and begin downloads before any version
#                      changes will be visible. 60 seconds is a conservative floor.
#   PollIntervalSeconds - how often to re-check versions once the min wait has elapsed.
#   StableChecksRequired - how many consecutive polls with no version change must
#                          pass before we consider updates complete. Two checks
#                          (= 2 * PollInterval apart) guards against a brief lull
#                          between packages finishing.
#   TimeoutSeconds   - hard ceiling for the entire wait, including the min wait.
$MinWaitSeconds       = 60
$PollIntervalSeconds  = 30
$StableChecksRequired = 2
$TimeoutSeconds       = 900

try {
    # Snapshot versions before the scan so we can detect and report actual changes.
    Write-OutputWithTimeStamp "Snapshotting current provisioned package versions..."
    $VersionsBefore = Get-ProvisionedPackageVersionMap
    Write-OutputWithTimeStamp "Found $($VersionsBefore.Count) provisioned package(s)."

    Write-OutputWithTimeStamp "Triggering Microsoft Store app update scan..."
    $Instance = Get-CimInstance -Namespace $Namespace -ClassName $ClassName -ErrorAction Stop
    $Result = $Instance | Invoke-CimMethod -MethodName "UpdateScanMethod" -ErrorAction Stop

    if ($Result.ReturnValue -eq 0) {
        Write-OutputWithTimeStamp "Store update scan triggered successfully (return value: 0)."
    } else {
        Write-Warning "Store update scan returned unexpected value: $($Result.ReturnValue). Continuing anyway."
    }

    # Mandatory minimum wait: the scan is async and downloads won't begin immediately.
    # Polling before this elapses would see all packages still at their old versions
    # and incorrectly conclude there is nothing to update.
    Write-OutputWithTimeStamp "Waiting $MinWaitSeconds seconds for the scan to complete and downloads to begin..."
    Start-Sleep -Seconds $MinWaitSeconds
    $Elapsed = $MinWaitSeconds

    $StableCount     = 0
    $LastVersionMap  = Get-ProvisionedPackageVersionMap

    Write-OutputWithTimeStamp "Beginning version-stability poll (interval: ${PollIntervalSeconds}s, timeout: ${TimeoutSeconds}s)..."

    while ($Elapsed -lt $TimeoutSeconds) {
        Start-Sleep -Seconds $PollIntervalSeconds
        $Elapsed += $PollIntervalSeconds

        $CurrentVersionMap = Get-ProvisionedPackageVersionMap

        # Find packages whose version changed since the last poll.
        $Changed = $CurrentVersionMap.Keys | Where-Object {
            $LastVersionMap.ContainsKey($_) -and $LastVersionMap[$_] -ne $CurrentVersionMap[$_]
        }

        if ($Changed) {
            # Versions are still moving — reset the stability counter.
            $StableCount = 0
            foreach ($pkg in $Changed) {
                Write-OutputWithTimeStamp "  [updating] $pkg : $($LastVersionMap[$pkg]) -> $($CurrentVersionMap[$pkg])"
            }
            Write-OutputWithTimeStamp "$(@($Changed).Count) package(s) changed version this interval. Resetting stability counter. ($Elapsed/$TimeoutSeconds seconds elapsed)"
        } else {
            $StableCount++
            Write-OutputWithTimeStamp "No version changes detected (stable check $StableCount/$StableChecksRequired). ($Elapsed/$TimeoutSeconds seconds elapsed)"
        }

        $LastVersionMap = $CurrentVersionMap

        if ($StableCount -ge $StableChecksRequired) {
            Write-OutputWithTimeStamp "Version map stable for $StableChecksRequired consecutive checks. Considering updates complete."
            break
        }
    }

    if ($Elapsed -ge $TimeoutSeconds -and $StableCount -lt $StableChecksRequired) {
        Write-Warning "Timed out after $TimeoutSeconds seconds before versions fully stabilized. Some packages may still be updating."
    }

    # Final diff: report everything that changed relative to the pre-scan snapshot.
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

} catch {
    Write-Warning "Failed to update UWP apps via Microsoft Store MDM interface: $_"
    Write-OutputWithTimeStamp "This may be expected in air-gapped or restricted network environments."
}

Stop-Transcript
