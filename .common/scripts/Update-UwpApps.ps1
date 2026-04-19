function Write-OutputWithTimeStamp {
    param(
        [parameter(ValueFromPipeline=$True, Mandatory=$True, Position=0)]
        [string]$Message
    )
    $Timestamp = Get-Date -Format 'MM/dd/yyyy HH:mm:ss'
    $Entry = '[' + $Timestamp + '] ' + $Message
    Write-Output $Entry
}

Start-Transcript -Path "$env:SystemRoot\Logs\Update-UwpApps.log" -Force
Write-Output "*********************************"
Write-Output "Updating Built-In UWP Apps"
Write-Output "*********************************"

$Namespace = "root\cimv2\mdm\dmmap"
$ClassName = "MDM_EnterpriseModernAppManagement_AppManagement01"

try {
    Write-OutputWithTimeStamp "Triggering Microsoft Store app update scan..."
    $Instance = Get-CimInstance -Namespace $Namespace -ClassName $ClassName -ErrorAction Stop
    $Result = $Instance | Invoke-CimMethod -MethodName "UpdateScanMethod" -ErrorAction Stop

    if ($Result.ReturnValue -eq 0) {
        Write-OutputWithTimeStamp "Store update scan triggered successfully."
    } else {
        Write-Warning "Store update scan returned: $($Result.ReturnValue)"
    }

    # Poll for completion, waiting for all AppX packages to reach an 'Ok' state
    $TimeoutSeconds  = 600
    $PollIntervalSeconds = 15
    $Elapsed = 0

    Write-OutputWithTimeStamp "Waiting up to $TimeoutSeconds seconds for UWP updates to complete..."

    do {
        Start-Sleep -Seconds $PollIntervalSeconds
        $Elapsed += $PollIntervalSeconds

        $PendingPackages = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -ne 'Ok' }

        if (-not $PendingPackages) {
            Write-OutputWithTimeStamp "No pending package operations detected."
            break
        }

        Write-OutputWithTimeStamp "$(@($PendingPackages).Count) package(s) still updating... ($Elapsed/$TimeoutSeconds seconds elapsed)"

    } while ($Elapsed -lt $TimeoutSeconds)

    if ($Elapsed -ge $TimeoutSeconds) {
        Write-Warning "Timed out waiting for UWP app updates after $TimeoutSeconds seconds. Some apps may not be fully updated."
    } else {
        Write-OutputWithTimeStamp "UWP app update process completed successfully."
    }

} catch {
    Write-Warning "Failed to update UWP apps via Microsoft Store MDM interface: $_"
    Write-OutputWithTimeStamp "This may be expected in air-gapped or restricted network environments."
}

Stop-Transcript
