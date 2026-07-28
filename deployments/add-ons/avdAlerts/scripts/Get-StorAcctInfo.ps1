# AVD Alert Solution - Storage Account Information Collector
# Runbook for Azure Automation Account.
# Queries FSLogix Azure Files shares and writes comma-delimited usage data to the
# Automation Account job stream (which flows to Log Analytics via diagnostic settings).
#
# Output format per file share (comma-separated, 9 fields, indices 0-8):
#   [0] StorageType       (AzFiles)
#   [1] StorageAccount
#   [2] ResourceGroup
#   [3] ShareName
#   [4] QuotaGiB
#   [5] UsedGiB
#   [6] PercentAvailable
#   [7] ResourceId        (share resource ID)
#
# This output format is consumed by Log Analytics Kusto queries in the AVD alert rules.
#
# Configuration is read from Automation Account variables:
#   StorageAccountResourceIDs - JSON array of storage account resource IDs
#   ResourceManagerUri        - ARM endpoint URI for this cloud

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

#region Configuration

$ResourceManagerUri       = Get-AutomationVariable -Name 'ResourceManagerUri'
$StorageAccountResourceIDsJson = Get-AutomationVariable -Name 'StorageAccountResourceIDs'

if ([string]::IsNullOrEmpty($ResourceManagerUri)) { throw 'ResourceManagerUri automation variable is not set.' }
if ([string]::IsNullOrEmpty($StorageAccountResourceIDsJson)) { throw 'StorageAccountResourceIDs automation variable is not set.' }
if (-not $ResourceManagerUri.EndsWith('/')) { $ResourceManagerUri = "$ResourceManagerUri/" }

$StorageAccountResourceIDs = $StorageAccountResourceIDsJson | ConvertFrom-Json
if ($null -eq $StorageAccountResourceIDs -or @($StorageAccountResourceIDs).Count -eq 0) {
    Write-Output 'No storage account resource IDs configured. Exiting.'
    return
}

#endregion Configuration

#region Authentication

try {
    Connect-AzAccount -Identity | Out-Null
    $tokenObj = Get-AzAccessToken -ResourceUrl ($ResourceManagerUri.TrimEnd('/'))
    $ArmToken = if ($tokenObj.Token -is [System.Security.SecureString]) {
        [System.Net.NetworkCredential]::new('', $tokenObj.Token).Password
    } else {
        $tokenObj.Token
    }
    if ([string]::IsNullOrEmpty($ArmToken)) { throw 'Token was null or empty.' }
}
catch {
    throw "Failed to acquire ARM access token via managed identity: $_"
}

$Header = @{
    Authorization  = "Bearer $ArmToken"
    'Content-Type' = 'application/json'
}

#endregion Authentication

#region Collect Storage Data

$StorageApiVersion = '2023-05-01'

foreach ($StorageAccountResourceId in @($StorageAccountResourceIDs)) {
    $StorageAccountResourceId = $StorageAccountResourceId.Trim()
    if ([string]::IsNullOrEmpty($StorageAccountResourceId)) { continue }

    $IdParts        = $StorageAccountResourceId -split '/'
    $SubId          = $IdParts[2]
    $ResourceGroup  = $IdParts[4]
    $StorageAccount = $IdParts[8]

    if ([string]::IsNullOrEmpty($StorageAccount)) {
        Write-Warning "Could not parse storage account name from resource ID: $StorageAccountResourceId"
        continue
    }

    # List all file shares with usage statistics
    $SharesUri = "${ResourceManagerUri}subscriptions/${SubId}/resourceGroups/${ResourceGroup}/providers/Microsoft.Storage/storageAccounts/${StorageAccount}/fileServices/default/shares?api-version=${StorageApiVersion}&`$expand=stats"

    try {
        $Shares = (Invoke-RestMethod -Headers $Header -Method 'GET' -Uri $SharesUri).value
    }
    catch {
        Write-Warning "Failed to list shares for ${StorageAccount}: $_"
        continue
    }

    if ($null -eq $Shares -or @($Shares).Count -eq 0) {
        Write-Warning "No file shares found in storage account: $StorageAccount"
        continue
    }

    foreach ($Share in @($Shares)) {
        $ShareName    = $Share.name
        $ShareProps   = $Share.properties
        $QuotaGiB     = $ShareProps.shareQuota
        $UsedBytes    = $ShareProps.shareUsageBytes
        $UsedGiB      = if ($null -ne $UsedBytes) { [math]::Round($UsedBytes / 1GB, 2) } else { 0 }
        $PercentAvail = if ($QuotaGiB -gt 0 -and $null -ne $UsedBytes) {
            [math]::Round(100 - ($UsedGiB / $QuotaGiB * 100), 1)
        } else {
            100
        }

        # Build share resource ID from storage account resource ID and share name
        $ShareResourceId = "${StorageAccountResourceId}/fileServices/default/shares/${ShareName}"

        # Write output in comma-delimited format matching the Log Analytics KQL queries
        Write-Output ('AzFiles,' + $StorageAccount + ',' + $ResourceGroup + ',' + $ShareName + ',' +
            $QuotaGiB + ',' + $UsedGiB + ',' + $PercentAvail + ',' + $ShareResourceId)
    }
}

#endregion Collect Storage Data
