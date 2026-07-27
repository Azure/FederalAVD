# FSLogix Storage Quota Manager - Azure Automation Runbook
# Automatically increases file share quotas on Azure Premium Files storage accounts
# when usage approaches the provisioned capacity limit.
#
# Reads configuration from Automation Account variables and authenticates via the
# system-assigned managed identity on the Automation Account.
#
# Automation Variables required:
#   ResourceGroupName   - Resource group containing the FSLogix storage accounts
#   SubscriptionId      - Subscription ID containing the storage resource group
#   ResourceManagerUri  - Azure Resource Manager URI for this cloud
#
# Quota scaling logic:
#   - Below 500GB provisioned: increase by 100GB when fewer than 50GB remain
#   - At or above 500GB provisioned: increase by 500GB when fewer than 500GB remain

$isAutomation = $null -ne (Get-Command 'Get-AutomationVariable' -ErrorAction SilentlyContinue)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

#region Helpers

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [switch]$Warn,
        [switch]$Err
    )
    $ts   = Get-Date -AsUTC -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] $Message"
    if ($Err)      { Write-Error   $line }
    elseif ($Warn) { Write-Warning $line }
    else           { Write-Output  $line }
}

#endregion Helpers

#region Configuration

if (-not $isAutomation) {
    Write-Log 'Local mode - reading config from environment variables.'
    $ResourceGroupName  = $env:ResourceGroupName
    $SubscriptionId     = $env:SubscriptionId
    $ResourceManagerUri = if ($env:ResourceManagerUri) { $env:ResourceManagerUri } else { 'https://management.azure.com/' }
}
else {
    $ResourceGroupName  = Get-AutomationVariable -Name 'ResourceGroupName'
    $SubscriptionId     = Get-AutomationVariable -Name 'SubscriptionId'
    $ResourceManagerUri = Get-AutomationVariable -Name 'ResourceManagerUri'
}

if ([string]::IsNullOrEmpty($ResourceGroupName)) { throw 'ResourceGroupName automation variable is not set.' }
if ([string]::IsNullOrEmpty($SubscriptionId))    { throw 'SubscriptionId automation variable is not set.' }

# Normalise URI - ARM REST calls require a trailing slash
if (-not $ResourceManagerUri.EndsWith('/')) {
    $ResourceManagerUri = "$ResourceManagerUri/"
}

Write-Log "Starting | Resource Group: $ResourceGroupName | Subscription: $SubscriptionId"

#endregion Configuration

#region ARM Authentication

if (-not $isAutomation) {
    Write-Log 'Local mode - acquiring ARM token via Azure CLI.'
    try {
        $AzTokenJson = & az account get-access-token --resource ($ResourceManagerUri.TrimEnd('/')) 2>&1
        if ($LASTEXITCODE -ne 0) { throw $AzTokenJson }
        $ArmToken = ($AzTokenJson | ConvertFrom-Json).accessToken
        if ([string]::IsNullOrEmpty($ArmToken)) { throw 'Token was null or empty.' }
    }
    catch {
        throw "Failed to acquire ARM token via Azure CLI: $_"
    }
}
else {
    # Authenticate using the Automation Account system-assigned managed identity.
    # Connect-AzAccount -Identity is the correct approach for Automation sandboxes.
    try {
        Connect-AzAccount -Identity | Out-Null
        $tokenObj = Get-AzAccessToken -ResourceUrl ($ResourceManagerUri.TrimEnd('/'))
        # Az module versions differ: Token may be a plain string or a SecureString
        $ArmToken = if ($tokenObj.Token -is [System.Security.SecureString]) {
            [System.Net.NetworkCredential]::new('', $tokenObj.Token).Password
        } else {
            $tokenObj.Token
        }
        if ([string]::IsNullOrEmpty($ArmToken)) {
            throw 'Token was null or empty.'
        }
    }
    catch {
        throw "Failed to acquire ARM access token via managed identity: $_"
    }
}

$Header = @{
    Authorization  = "Bearer $ArmToken"
    'Content-Type' = 'application/json'
}

Write-Log 'ARM token acquired.'

#endregion ARM Authentication

#region Storage Quota Management

$ApiVersion         = '2023-05-01'
$StorageAccountsUri = "${ResourceManagerUri}subscriptions/${SubscriptionId}/resourceGroups/${ResourceGroupName}/providers/Microsoft.Storage/storageAccounts?api-version=${ApiVersion}"

$StorageAccountNames = (Invoke-RestMethod -Headers $Header -Method 'GET' -Uri $StorageAccountsUri).value.name

if ($null -eq $StorageAccountNames -or @($StorageAccountNames).Count -eq 0) {
    Write-Log "No storage accounts found in resource group $ResourceGroupName. Exiting."
}

foreach ($StorageAccountName in $StorageAccountNames) {
    $SharesUri       = "${ResourceManagerUri}subscriptions/${SubscriptionId}/resourceGroups/${ResourceGroupName}/providers/Microsoft.Storage/storageAccounts/${StorageAccountName}/fileServices/default/shares?api-version=${ApiVersion}"
    $ShareNames      = (Invoke-RestMethod -Headers $Header -Method 'GET' -Uri $SharesUri).value.name

    foreach ($ShareName in $ShareNames) {
        $ShareBaseUri   = "${ResourceManagerUri}subscriptions/${SubscriptionId}/resourceGroups/${ResourceGroupName}/providers/Microsoft.Storage/storageAccounts/${StorageAccountName}/fileServices/default/shares/${ShareName}"
        $ShareGetUri    = "${ShareBaseUri}?api-version=${ApiVersion}&`$expand=stats"
        $ShareUpdateUri = "${ShareBaseUri}?api-version=${ApiVersion}"

        $PFS                 = (Invoke-RestMethod -Headers $Header -Method 'GET' -Uri $ShareGetUri).properties
        $ProvisionedCapacity = $PFS.shareQuota
        $UsedCapacity        = $PFS.ShareUsageBytes
        $UsedGB              = [math]::Round($UsedCapacity / 1GB, 0)

        Write-Log "${StorageAccountName}/${ShareName} - Provisioned: ${ProvisionedCapacity}GB | Used: ${UsedGB}GB"

        if ($UsedCapacity -eq 0) {
            Write-Log "${StorageAccountName}/${ShareName} - Share usage is 0GB. No changes."
        }
        elseif ($ProvisionedCapacity -lt 500) {
            # Slow scaling up to 500GB: increase by 100GB if fewer than 50GB remain
            if (($ProvisionedCapacity - ($UsedCapacity / ([Math]::Pow(2, 30)))) -lt 50) {
                $Quota = $ProvisionedCapacity + 100
                Write-Log "${StorageAccountName}/${ShareName} - Less than 50GB remaining. Increasing quota by 100GB to ${Quota}GB."
                Invoke-RestMethod -Body (@{properties = @{shareQuota = $Quota}} | ConvertTo-Json) -Headers $Header -Method 'PATCH' -Uri $ShareUpdateUri | Out-Null
            }
            else {
                Write-Log "${StorageAccountName}/${ShareName} - More than 50GB remaining. No changes."
            }
        }
        else {
            # Aggressive scaling at or above 500GB: increase by 500GB if fewer than 500GB remain
            if (($ProvisionedCapacity - ($UsedCapacity / ([Math]::Pow(2, 30)))) -lt 500) {
                $Quota = $ProvisionedCapacity + 500
                Write-Log "${StorageAccountName}/${ShareName} - Less than 500GB remaining. Increasing quota by 500GB to ${Quota}GB."
                Invoke-RestMethod -Body (@{properties = @{shareQuota = $Quota}} | ConvertTo-Json) -Headers $Header -Method 'PATCH' -Uri $ShareUpdateUri | Out-Null
            }
            else {
                Write-Log "${StorageAccountName}/${ShareName} - More than 500GB remaining. No changes."
            }
        }
    }
}

Write-Log 'Storage quota check complete.'

#endregion Storage Quota Management
