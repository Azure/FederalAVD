<#
.SYNOPSIS
    Reviews or updates supported Session Host Replacer operational settings.

.DESCRIPTION
    Reads the current Function App settings, presents them with Session Host Replacer terminology,
    validates supported changes, shows a before-and-after diff, and preserves every unrelated app
    setting when an update is submitted.

    Replacement mode, timer schedule, identities, networking, device-cleanup permissions, template
    references, and infrastructure settings remain deployment concerns and must be changed through
    the Session Host Replacer Template Spec or Bicep deployment.

.PARAMETER FunctionAppName
    Name of the Session Host Replacer Function App.

.PARAMETER ResourceGroupName
    Resource group containing the Function App.

.PARAMETER SubscriptionId
    Subscription containing the Function App. Defaults to the active Az context subscription.

.PARAMETER MinimumDrainMinutes
    Minimum time an idle host remains in drain mode before removal.

.PARAMETER DrainGracePeriodHours
    Grace period for a draining host that still has active sessions.

.PARAMETER TargetSessionHostCount
    Explicit target host count, or 0 to detect the count at the start of each replacement cycle.

.PARAMETER MinimumCapacityPercentage
    DeleteFirst static safety floor used when no scaling-plan schedule is evaluable.

.PARAMETER MaxDeletionsPerCycle
    DeleteFirst absolute deletion ceiling per function invocation.

.PARAMETER MaxDeploymentBatchSize
    SideBySide deployment ceiling per function invocation.

.PARAMETER EnableShutdownRetention
    Enables SideBySide shutdown retention.

.PARAMETER ShutdownRetentionDays
    Number of days SideBySide shutdown-retention VMs are retained.

.PARAMETER EnableProgressiveScaleUp
    Enables percentage-based progressive replacement batches.

.PARAMETER InitialDeploymentPercentage
    Initial percentage of remaining hosts selected when progressive scale-up is enabled.

.PARAMETER ScaleUpIncrementPercentage
    Percentage added after the configured number of successful runs.

.PARAMETER SuccessfulRunsBeforeScaleUp
    Successful deployment and registration runs required before increasing the percentage.

.PARAMETER ReplaceSessionHostOnNewImageVersionDelayDays
    Delay before a newly published image version becomes eligible for replacement.

.PARAMETER AllowImageVersionRollback
    Allows replacement with an image version older than the currently deployed version.

.PARAMETER PassThru
    Returns the interpreted configuration object after review or update.

.EXAMPLE
    .\Set-SessionHostReplacerConfiguration.ps1 `
        -FunctionAppName func-shr-prod-use2 `
        -ResourceGroupName rg-avd-operations-use2

.EXAMPLE
    .\Set-SessionHostReplacerConfiguration.ps1 `
        -FunctionAppName func-shr-prod-use2 `
        -ResourceGroupName rg-avd-operations-use2 `
        -MinimumCapacityPercentage 90 `
        -MaxDeletionsPerCycle 2 `
        -WhatIf

.NOTES
    Requires Az.Accounts and an authenticated Az context. Reading requires
    Microsoft.Web/sites/config/list/action. Updating requires Microsoft.Web/sites/config/write.
    App-setting changes restart the Function App and can be overwritten by a later Template Spec
    redeployment if its parameters are not updated to match.
#>

#Requires -Modules Az.Accounts

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$FunctionAppName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [string]$SubscriptionId,

    [ValidateRange(0, 120)]
    [Nullable[int]]$MinimumDrainMinutes,

    [ValidateRange(1, 168)]
    [Nullable[int]]$DrainGracePeriodHours,

    [ValidateRange(0, 1000)]
    [Nullable[int]]$TargetSessionHostCount,

    [ValidateRange(20, 100)]
    [Nullable[int]]$MinimumCapacityPercentage,

    [ValidateRange(1, 100)]
    [Nullable[int]]$MaxDeletionsPerCycle,

    [ValidateRange(1, 1000)]
    [Nullable[int]]$MaxDeploymentBatchSize,

    [Nullable[bool]]$EnableShutdownRetention,

    [ValidateRange(1, 7)]
    [Nullable[int]]$ShutdownRetentionDays,

    [Nullable[bool]]$EnableProgressiveScaleUp,

    [ValidateRange(1, 100)]
    [Nullable[int]]$InitialDeploymentPercentage,

    [ValidateRange(5, 50)]
    [Nullable[int]]$ScaleUpIncrementPercentage,

    [ValidateRange(1, 5)]
    [Nullable[int]]$SuccessfulRunsBeforeScaleUp,

    [ValidateRange(0, 30)]
    [Nullable[int]]$ReplaceSessionHostOnNewImageVersionDelayDays,

    [Nullable[bool]]$AllowImageVersionRollback,

    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
$webApiVersion = '2024-11-01'

function Invoke-ArmRequest {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GET', 'POST', 'PUT')]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Path,

        [object]$Body
    )

    $request = @{
        Method = $Method
        Path = $Path
    }
    if ($null -ne $Body) {
        $request.Payload = $Body | ConvertTo-Json -Depth 20 -Compress
    }

    $response = Invoke-AzRestMethod @request
    if ($response.StatusCode -ge 400) {
        throw "$Method $Path failed with HTTP $($response.StatusCode): $($response.Content)"
    }

    if ([string]::IsNullOrWhiteSpace($response.Content)) {
        return $null
    }

    return $response.Content | ConvertFrom-Json
}

function ConvertTo-AppSettingValue {
    param([Parameter(Mandatory)][object]$Value)

    if ($Value -is [bool]) {
        return $Value.ToString().ToLowerInvariant()
    }

    return [string]$Value
}

function Get-SettingValue {
    param(
        [Parameter(Mandatory)][object]$Settings,
        [Parameter(Mandatory)][string]$Name,
        [string]$Default = ''
    )

    $property = $Settings.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }

    return [string]$property.Value
}

function Get-InterpretedConfiguration {
    param([Parameter(Mandatory)][object]$Settings)

    $mode = Get-SettingValue -Settings $Settings -Name 'ReplacementMode'
    $target = Get-SettingValue -Settings $Settings -Name 'TargetSessionHostCount' -Default '0'
    $progressive = [bool]::Parse((Get-SettingValue -Settings $Settings -Name 'EnableProgressiveScaleUp' -Default 'false'))
    $retention = $mode -eq 'SideBySide' -and
        [bool]::Parse((Get-SettingValue -Settings $Settings -Name 'EnableShutdownRetention' -Default 'false'))

    $activeHoursBehavior = if ($mode -eq 'DeleteFirst') {
        'New delete/deploy batches freeze 60 minutes before RampUp through Peak; recovery continues.'
    }
    else {
        'Deployment, validation, and capacity-safe removal continue during every scaling phase.'
    }

    return [PSCustomObject][ordered]@{
        FunctionApp = $FunctionAppName
        HostPool = Get-SettingValue -Settings $Settings -Name 'HostPoolName'
        ReplacementMode = $mode
        ActiveHoursBehavior = $activeHoursBehavior
        TargetSessionHosts = if ($target -eq '0') { 'Auto-detect each replacement cycle' } else { $target }
        MinimumDrainMinutes = Get-SettingValue -Settings $Settings -Name 'MinimumDrainMinutes'
        DrainGracePeriodHours = Get-SettingValue -Settings $Settings -Name 'DrainGracePeriodHours'
        MinimumCapacityPercentage = if ($mode -eq 'DeleteFirst') {
            Get-SettingValue -Settings $Settings -Name 'MinimumCapacityPercentage'
        } else { 'N/A' }
        MaxDeletionsPerCycle = if ($mode -eq 'DeleteFirst') {
            Get-SettingValue -Settings $Settings -Name 'MaxDeletionsPerCycle'
        } else { 'N/A' }
        MaxDeploymentBatchSize = if ($mode -eq 'SideBySide') {
            Get-SettingValue -Settings $Settings -Name 'MaxDeploymentBatchSize'
        } else { 'N/A' }
        ShutdownRetention = if ($mode -eq 'SideBySide') {
            if ($retention) {
                "$(Get-SettingValue -Settings $Settings -Name 'ShutdownRetentionDays') day(s)"
            }
            else {
                'Disabled'
            }
        } else { 'N/A' }
        ProgressiveScaleUp = if ($progressive) {
            "Starts at $(Get-SettingValue -Settings $Settings -Name 'InitialDeploymentPercentage')%; increases by $(Get-SettingValue -Settings $Settings -Name 'ScaleUpIncrementPercentage')% after $(Get-SettingValue -Settings $Settings -Name 'SuccessfulRunsBeforeScaleUp') successful run(s)"
        } else {
            'Disabled'
        }
        NewImageDelayDays = Get-SettingValue -Settings $Settings -Name 'ReplaceSessionHostOnNewImageVersionDelayDays'
        AllowImageVersionRollback = Get-SettingValue -Settings $Settings -Name 'AllowImageVersionRollback' -Default 'false'
    }
}

$context = Get-AzContext
if ($null -eq $context -or $null -eq $context.Subscription) {
    throw 'No active Azure context was found. Run Connect-AzAccount first.'
}

if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
    $SubscriptionId = $context.Subscription.Id
}

$functionAppResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName"
$functionApp = Invoke-ArmRequest -Method GET -Path "$functionAppResourceId`?api-version=$webApiVersion"
if ($functionApp.type -ne 'Microsoft.Web/sites' -or $functionApp.kind -notmatch 'functionapp') {
    throw "Resource $functionAppResourceId is not a Function App."
}

$settingsResponse = Invoke-ArmRequest -Method POST -Path "$functionAppResourceId/config/appsettings/list?api-version=$webApiVersion" -Body @{}
$settings = $settingsResponse.properties
if ($null -eq $settings -or
    [string]::IsNullOrWhiteSpace((Get-SettingValue -Settings $settings -Name 'HostPoolName')) -or
    (Get-SettingValue -Settings $settings -Name 'ReplacementMode') -notin @('DeleteFirst', 'SideBySide')) {
    throw "$FunctionAppName does not contain a recognizable Session Host Replacer configuration."
}

$settingParameters = [ordered]@{
    MinimumDrainMinutes = 'MinimumDrainMinutes'
    DrainGracePeriodHours = 'DrainGracePeriodHours'
    TargetSessionHostCount = 'TargetSessionHostCount'
    MinimumCapacityPercentage = 'MinimumCapacityPercentage'
    MaxDeletionsPerCycle = 'MaxDeletionsPerCycle'
    MaxDeploymentBatchSize = 'MaxDeploymentBatchSize'
    EnableShutdownRetention = 'EnableShutdownRetention'
    ShutdownRetentionDays = 'ShutdownRetentionDays'
    EnableProgressiveScaleUp = 'EnableProgressiveScaleUp'
    InitialDeploymentPercentage = 'InitialDeploymentPercentage'
    ScaleUpIncrementPercentage = 'ScaleUpIncrementPercentage'
    SuccessfulRunsBeforeScaleUp = 'SuccessfulRunsBeforeScaleUp'
    ReplaceSessionHostOnNewImageVersionDelayDays = 'ReplaceSessionHostOnNewImageVersionDelayDays'
    AllowImageVersionRollback = 'AllowImageVersionRollback'
}

$requestedChanges = [ordered]@{}
foreach ($parameterName in $settingParameters.Keys) {
    if ($PSBoundParameters.ContainsKey($parameterName)) {
        $requestedChanges[$settingParameters[$parameterName]] = ConvertTo-AppSettingValue -Value $PSBoundParameters[$parameterName]
    }
}

$replacementMode = Get-SettingValue -Settings $settings -Name 'ReplacementMode'
if ($replacementMode -ne 'DeleteFirst' -and
    ($requestedChanges.Contains('MinimumCapacityPercentage') -or $requestedChanges.Contains('MaxDeletionsPerCycle'))) {
    throw 'MinimumCapacityPercentage and MaxDeletionsPerCycle apply only to DeleteFirst mode.'
}
if ($replacementMode -ne 'SideBySide' -and
    ($requestedChanges.Contains('MaxDeploymentBatchSize') -or
        $requestedChanges.Contains('EnableShutdownRetention') -or
        $requestedChanges.Contains('ShutdownRetentionDays'))) {
    throw 'MaxDeploymentBatchSize and shutdown retention settings apply only to SideBySide mode.'
}
if ($replacementMode -eq 'DeleteFirst' -and
    $requestedChanges.Contains('TargetSessionHostCount') -and
    $requestedChanges.TargetSessionHostCount -eq '1') {
    throw 'DeleteFirst cannot replace a one-host target while retaining one usable host. Use SideBySide or a target of at least two.'
}

Write-Host ''
Write-Host 'Current Session Host Replacer configuration'
Write-Host '-------------------------------------------'
Get-InterpretedConfiguration -Settings $settings | Format-List | Out-Host

if ($requestedChanges.Count -eq 0) {
    Write-Host 'No changes requested. Supply one or more supported setting parameters to update the Function App.'
    if ($PassThru) {
        Get-InterpretedConfiguration -Settings $settings
    }
    return
}

$changeRows = foreach ($settingName in $requestedChanges.Keys) {
    $currentValue = Get-SettingValue -Settings $settings -Name $settingName
    $newValue = $requestedChanges[$settingName]
    if ($currentValue -ne $newValue) {
        [PSCustomObject]@{
            Setting = $settingName
            Current = $currentValue
            Proposed = $newValue
        }
    }
}

if (@($changeRows).Count -eq 0) {
    Write-Host 'The requested values already match the Function App configuration. No update is required.'
    if ($PassThru) {
        Get-InterpretedConfiguration -Settings $settings
    }
    return
}

Write-Host ''
Write-Host 'Proposed changes'
Write-Host '----------------'
$changeRows | Format-Table -AutoSize | Out-Host
Write-Warning 'A future Template Spec redeployment can overwrite these values unless its parameters are updated to match.'

if ($PSCmdlet.ShouldProcess($functionAppResourceId, "Update $(@($changeRows).Count) Session Host Replacer app setting(s)")) {
    foreach ($change in $changeRows) {
        $property = $settings.PSObject.Properties[$change.Setting]
        if ($null -eq $property) {
            $settings | Add-Member -NotePropertyName $change.Setting -NotePropertyValue $change.Proposed
        }
        else {
            $property.Value = $change.Proposed
        }
    }

    Invoke-ArmRequest `
        -Method PUT `
        -Path "$functionAppResourceId/config/appsettings?api-version=$webApiVersion" `
        -Body @{ properties = $settings } | Out-Null

    Write-Host "Updated $(@($changeRows).Count) setting(s). Azure will restart the Function App to apply the changes."
}

if ($PassThru) {
    Get-InterpretedConfiguration -Settings $settings
}
