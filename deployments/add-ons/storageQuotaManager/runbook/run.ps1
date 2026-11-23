# FSLogix Storage Quota Manager - Azure Automation PowerShell 7 runbook.
# Capacity only: provisioned v2 IOPS and bandwidth are never recalculated.
# Small shares (<500 GiB): +100 when free <50, -100 when free >200.
# Large shares: +500 when free <500, -500 when free >1000.
# Empty shares are unchanged. Decreases retain a 24h local cooldown in
# sqmLastDecreased metadata, in addition to the service's downgrade deadline.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

function Write-Log {
    param([string]$Message, [switch]$Warn)
    $line = "[$(Get-Date -AsUTC -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    if ($Warn) { Write-Warning $line } else { Write-Output $line }
}

function Invoke-StorageRequest {
    param([string]$Uri, [string]$Method = 'GET', [string]$Body)
    try {
        $arguments = @{ Uri = $Uri; Method = $Method; Headers = $Header; ErrorAction = 'Stop' }
        if ($Body) { $arguments.Body = $Body }
        Invoke-RestMethod @arguments
    }
    catch {
        throw "Storage API $Method failed for $Uri. No fallback or API downgrade attempted. Service error: $_"
    }
}

function Get-StorageList {
    param([string]$Uri)
    do {
        $page = Invoke-StorageRequest -Uri $Uri
        if ($null -eq $page.value -or $page.value -is [string] -or
            $page.value -isnot [Collections.IEnumerable]) {
            throw "Invalid list response from ${Uri}: missing/invalid value array."
        }
        $page.value
        $Uri = $page.nextLink
        if ($Uri -and -not $Uri.StartsWith($ResourceManagerUri, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Invalid list response: nextLink is outside the configured ARM endpoint.'
        }
    } while ($Uri)
}

function Get-WholeNumber {
    param([AllowNull()][object]$Value, [string]$Field, [decimal]$Minimum = 0)
    $number = [decimal]0
    if ($null -eq $Value -or $Value -is [bool] -or
        -not [decimal]::TryParse([string]$Value, [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or
        $number -lt $Minimum -or $number -ne [math]::Truncate($number)) {
        throw "Invalid response: $Field must be a whole number >= $Minimum."
    }
    return $number
}

function Get-UtcDeadline {
    param([string]$Value, [string]$Field)
    $deadline = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$deadline)) {
        throw "Invalid response: $Field timestamp '$Value'. No unsafe decrease attempted."
    }
    return $deadline.UtcDateTime
}

$ResourceGroupName = Get-AutomationVariable -Name 'ResourceGroupName'
$SubscriptionId = Get-AutomationVariable -Name 'SubscriptionId'
$ResourceManagerUri = Get-AutomationVariable -Name 'ResourceManagerUri'
foreach ($variableName in @('ResourceGroupName', 'SubscriptionId', 'ResourceManagerUri')) {
    if ([string]::IsNullOrWhiteSpace((Get-Variable -Name $variableName -ValueOnly))) {
        throw "$variableName automation variable is not set."
    }
}
if (-not $ResourceManagerUri.EndsWith('/')) { $ResourceManagerUri += '/' }

Write-Log "Starting | Resource Group: $ResourceGroupName | Subscription: $SubscriptionId"
try {
    Connect-AzAccount -Identity | Out-Null
    $tokenObj = Get-AzAccessToken -ResourceUrl ($ResourceManagerUri.TrimEnd('/'))
    $ArmToken = if ($tokenObj.Token -is [System.Security.SecureString]) {
        [Net.NetworkCredential]::new('', $tokenObj.Token).Password
    } else { $tokenObj.Token }
    if ([string]::IsNullOrEmpty($ArmToken)) { throw 'Token was null or empty.' }
}
catch { throw "Failed to acquire ARM access token via managed identity: $_" }
$Header = @{ Authorization = "Bearer $ArmToken"; 'Content-Type' = 'application/json' }

# Earliest stable Microsoft.Storage schema with v2 SKUs, independent performance,
# service usage limits, and nextAllowedQuotaDowngradeTime. No cloud API fallback.
$ApiVersion = '2024-01-01'
$accountsUri = "${ResourceManagerUri}subscriptions/${SubscriptionId}/resourceGroups/${ResourceGroupName}/providers/Microsoft.Storage/storageAccounts?api-version=${ApiVersion}"
$accounts = @(Get-StorageList -Uri $accountsUri)
if ($accounts.Count -eq 0) { Write-Log 'No storage accounts found.' }

foreach ($account in $accounts) {
    $accountName = $account.name
    $sku = $account.sku.name
    if ([string]::IsNullOrWhiteSpace($accountName) -or
        [string]::IsNullOrWhiteSpace($account.kind) -or [string]::IsNullOrWhiteSpace($sku)) {
        throw 'Invalid account response: name, kind, and SKU are required.'
    }
    $isV2 = $account.kind -eq 'FileStorage' -and $sku -in @(
        'StandardV2_LRS', 'StandardV2_ZRS', 'PremiumV2_LRS', 'PremiumV2_ZRS')
    $isV1 = $account.kind -eq 'FileStorage' -and $sku -in @('Premium_LRS', 'Premium_ZRS')
    $isPayGo = $account.kind -eq 'StorageV2' -and $sku -in @(
        'Standard_LRS', 'Standard_ZRS', 'Standard_GRS', 'Standard_RAGRS', 'Standard_GZRS', 'Standard_RAGZRS')
    if (-not ($isV2 -or $isV1 -or $isPayGo)) {
        Write-Log "$accountName - Unsupported account kind/SKU '$($account.kind)/$sku'; skipped." -Warn
        continue
    }
    $accountUri = "${ResourceManagerUri}subscriptions/${SubscriptionId}/resourceGroups/${ResourceGroupName}/providers/Microsoft.Storage/storageAccounts/${accountName}"
    $serviceUri = "$accountUri/fileServices/default"
    $shares = @(Get-StorageList -Uri "${serviceUri}/shares?api-version=${ApiVersion}")
    $accountProvisioned = [decimal]0
    if ($isV1) {
        foreach ($listedShare in $shares) {
            $accountProvisioned += Get-WholeNumber $listedShare.properties.shareQuota "$accountName listed shareQuota" 1
        }
    }

    foreach ($share in $shares) {
        $shareName = $share.name
        if ([string]::IsNullOrWhiteSpace($shareName)) { throw "Invalid share response for ${accountName}: missing name." }
        $label = "$accountName/$shareName"
        $shareUri = "$serviceUri/shares/$shareName"
        $properties = (Invoke-StorageRequest -Uri "${shareUri}?api-version=${ApiVersion}&`$expand=stats").properties
        if ($null -eq $properties) { throw "Invalid response for ${label}: missing share properties." }
        # SMB is the service default when enabledProtocols is omitted.
        if ($properties.enabledProtocols -and $properties.enabledProtocols -ne 'SMB') {
            Write-Log "$label - Unsupported protocol '$($properties.enabledProtocols)'; skipped." -Warn
            continue
        }
        $capacity = Get-WholeNumber $properties.shareQuota "$label shareQuota" 1
        $usedBytes = Get-WholeNumber $properties.shareUsageBytes "$label shareUsageBytes"
        $minimum = if ($isV2) { 32 } elseif ($isV1) { 100 } else { 1 }
        $maximum = if ($isV2) { 262144 } elseif ($isV1 -or $account.properties.largeFileSharesState -eq 'Enabled') { 102400 } else { 5120 }
        $accountMaximum = if ($isV1) { 102400 } else { $null }
        if ($isV2) {
            $iops = Get-WholeNumber $properties.provisionedIops "$label provisionedIops" 1
            $bandwidth = Get-WholeNumber $properties.provisionedBandwidthMibps "$label provisionedBandwidthMibps" 1
            $usage = (Invoke-StorageRequest -Uri "${serviceUri}/usages/default?api-version=${ApiVersion}").properties
            $serviceMinimum = Get-WholeNumber $usage.fileShareLimits.minProvisionedStorageGiB "$label service minimum" 1
            $serviceMaximum = Get-WholeNumber $usage.fileShareLimits.maxProvisionedStorageGiB "$label service maximum" 1
            if ($serviceMinimum -gt $serviceMaximum) { throw "Invalid response for ${label}: inverted service limits." }
            $minimum = [math]::Max($minimum, $serviceMinimum)
            $maximum = [math]::Min($maximum, $serviceMaximum)
            $accountMaximum = Get-WholeNumber $usage.storageAccountLimits.maxProvisionedStorageGiB "$label account maximum" 1
            $mediaAccountMaximum = if ($sku -like 'PremiumV2_*') { 262144 } else { 4194304 }
            $accountMaximum = [math]::Min($accountMaximum, $mediaAccountMaximum)
            $accountProvisioned = Get-WholeNumber $usage.storageAccountUsage.liveShares.provisionedStorageGiB "$label live account capacity"
            if ($accountProvisioned -lt $capacity) { throw "Invalid response for ${label}: account capacity is below share quota." }
        }
        if ($minimum -gt $maximum -or $capacity -lt $minimum -or $capacity -gt $maximum) {
            throw "Invalid response/limits for ${label}: quota ${capacity}GiB outside ${minimum}-${maximum}GiB."
        }
        $usedGiB = $usedBytes / 1GB
        $remaining = $capacity - $usedGiB
        Write-Log "$label ($sku) - Provisioned: ${capacity}GiB | Used: $([math]::Round($usedGiB, 1))GiB | Remaining: $([math]::Round($remaining, 1))GiB | Limits: ${minimum}-${maximum}GiB"
        if ($usedBytes -eq 0) { Write-Log "$label - Zero usage; no changes."; continue }

        $step = if ($capacity -lt 500) { 100 } else { 500 }
        $growBelow = if ($capacity -lt 500) { 50 } else { 500 }
        $shrinkAbove = if ($capacity -lt 500) { 200 } else { 1000 }
        $now = [DateTime]::UtcNow
        $decreasing = $false
        if ($remaining -lt $growBelow) {
            $target = [math]::Min($capacity + $step, $maximum)
            if ($null -ne $accountMaximum) {
                $available = [math]::Max(0, $accountMaximum - $accountProvisioned)
                $target = [math]::Min($target, $capacity + $available)
                Write-Log "$label - Account capacity: ${accountProvisioned}/${accountMaximum}GiB; headroom: ${available}GiB."
            }
            if ($target -lt ($capacity + $step)) {
                Write-Log "$label - Growth limited by share/account capacity limits to ${target}GiB." -Warn
            }
        }
        elseif ($remaining -gt $shrinkAbove) {
            $canDecrease = $true
            if (-not [string]::IsNullOrEmpty($properties.nextAllowedQuotaDowngradeTime)) {
                $deadline = Get-UtcDeadline $properties.nextAllowedQuotaDowngradeTime "$label nextAllowedQuotaDowngradeTime"
                if ($now -lt $deadline) {
                    Write-Log "$label - Service quota decrease cooldown until $($deadline.ToString('o')) (including after increases)."
                    $canDecrease = $false
                }
            }
            if (-not [string]::IsNullOrEmpty($properties.metadata.sqmLastDecreased)) {
                $lastDecrease = Get-UtcDeadline $properties.metadata.sqmLastDecreased "$label sqmLastDecreased"
                if ($now -lt $lastDecrease.AddHours(24)) {
                    Write-Log "$label - Local decrease cooldown until $($lastDecrease.AddHours(24).ToString('o'))."
                    $canDecrease = $false
                }
            }
            if (-not $canDecrease) { continue }
            $floor = [math]::Max($minimum, [math]::Ceiling($usedGiB) + 1)
            $target = [math]::Max($capacity - $step, $floor)
            $decreasing = $true
            if ($target -gt ($capacity - $step)) {
                Write-Log "$label - Decrease limited by minimum capacity/used-size floor to ${target}GiB."
            }
        }
        else { Write-Log "$label - Within normal range; no changes."; continue }
        if ($target -eq $capacity) { Write-Log "$label - At capacity limit; no quota change possible." -Warn; continue }

        $update = @{ shareQuota = [int]$target }
        if ($decreasing) {
            $metadata = @{}
            if ($properties.metadata) {
                foreach ($entry in $properties.metadata.PSObject.Properties) { $metadata[$entry.Name] = $entry.Value }
            }
            $metadata.sqmLastDecreased = $now.ToString('o')
            $update.metadata = $metadata
        }
        # Omitted PATCH properties are unchanged: never send recommended/default
        # IOPS or bandwidth, nor echo unrelated read-only share properties.
        Write-Log "$label - Updating quota ${capacity} -> ${target}GiB; independently provisioned performance unchanged."
        $result = Invoke-StorageRequest -Uri "${shareUri}?api-version=${ApiVersion}" -Method 'PATCH' -Body (
            @{ properties = $update } | ConvertTo-Json -Depth 6)
        $actualQuota = Get-WholeNumber $result.properties.shareQuota "$label PATCH shareQuota" 1
        if ($actualQuota -ne $target) { throw "Invalid PATCH response for ${label}: expected quota $target, got $actualQuota." }
        if ($isV2 -and (
            (Get-WholeNumber $result.properties.provisionedIops "$label PATCH provisionedIops" 1) -ne $iops -or
            (Get-WholeNumber $result.properties.provisionedBandwidthMibps "$label PATCH provisionedBandwidthMibps" 1) -ne $bandwidth)) {
            throw "Unexpected performance change for ${label}: capacity-only PATCH did not preserve IOPS/bandwidth."
        }
        if ($isV1) { $accountProvisioned += $target - $capacity }
        Write-Log "$label - Quota update confirmed: ${target}GiB."
    }
}
Write-Log 'Storage quota check complete.'
