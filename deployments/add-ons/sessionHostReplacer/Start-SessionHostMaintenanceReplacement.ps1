<#
.SYNOPSIS
    Schedules a one-time Session Host Replacer maintenance replacement.

.DESCRIPTION
    Writes a guarded, non-secret maintenance request to the Session Host Replacer Function App.
    The request approves one image version and one UTC maintenance window. The Function App
    temporarily overrides its configured DeleteFirst behavior, consumes the request once, records
    its identity in durable deployment state, and then resumes continuous DeleteFirst operation.

    This command requires explicit authorization to sign out remaining users. A one-host pool or
    any other operation that can intentionally reduce available capacity to zero also requires
    AllowFullPoolOutage.

.PARAMETER FunctionAppName
    Name of the Session Host Replacer Function App.

.PARAMETER ResourceGroupName
    Resource group containing the Function App.

.PARAMETER SubscriptionId
    Subscription containing the Function App. Defaults to the active Az context subscription.

.PARAMETER ApprovedImageVersion
    Exact Compute Gallery image version approved for this operation.

.PARAMETER ScheduledDateTime
    Date and time at which the maintenance window starts.

.PARAMETER TimeZoneId
    Windows time zone identifier for ScheduledDateTime. Defaults to UTC.

.PARAMETER WindowDurationMinutes
    Length of the maintenance window. New destructive batches do not start after it closes.

.PARAMETER MaxVmsRemoved
    Maximum number of hosts drained and replaced in one maintenance batch.

.PARAMETER LogOffDelayMinutes
    Time users have to sign out after notification before the Function App signs them out.
    Actual processing occurs on the next timer invocation after the delay has elapsed.

.PARAMETER LogOffMessage
    Message sent to active AVD user sessions before forced sign-out.

.PARAMETER ForceSignOut
    Explicitly authorizes the Function App to sign out remaining users during the window.

.PARAMETER AllowFullPoolOutage
    Explicitly authorizes a batch that can reduce available session-host capacity to zero.

.PARAMETER ReplaceExistingRequest
    Replaces a populated MaintenanceRequest setting. Use only after the workbook and deployment
    state show that the previous request completed or expired with no recovery in progress.

.PARAMETER PassThru
    Returns the scheduled request after it is submitted.

.EXAMPLE
    .\Start-SessionHostMaintenanceReplacement.ps1 `
        -FunctionAppName func-shr-prod-use2 `
        -ResourceGroupName rg-avd-operations-use2 `
        -ApprovedImageVersion 1.2.3 `
        -ScheduledDateTime '2026-04-18 22:00' `
        -TimeZoneId 'Eastern Standard Time' `
        -WindowDurationMinutes 240 `
        -MaxVmsRemoved 5 `
        -LogOffDelayMinutes 15 `
        -ForceSignOut `
        -WhatIf

.NOTES
    Requires Az.Accounts and an authenticated Az context. Reading requires
    Microsoft.Web/sites/config/list/action. Scheduling requires Microsoft.Web/sites/config/write.
    Updating app settings restarts the Function App before the scheduled window.
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

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ApprovedImageVersion,

    [Parameter(Mandatory)]
    [datetime]$ScheduledDateTime,

    [ValidateNotNullOrEmpty()]
    [string]$TimeZoneId = 'UTC',

    [ValidateRange(30, 1440)]
    [int]$WindowDurationMinutes = 240,

    [ValidateRange(1, 1000)]
    [int]$MaxVmsRemoved = 1,

    [ValidateRange(0, 60)]
    [int]$LogOffDelayMinutes = 15,

    [ValidateLength(1, 260)]
    [string]$LogOffMessage = 'Scheduled maintenance is replacing this session host. Save your work and sign out before the maintenance countdown ends.',

    [switch]$ForceSignOut,

    [switch]$AllowFullPoolOutage,

    [switch]$ReplaceExistingRequest,

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

function Get-SettingValue {
    param(
        [Parameter(Mandatory)]
        [object]$Settings,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $property = $Settings.PSObject.Properties[$Name]
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        throw "Required Function App setting '$Name' is missing or empty."
    }

    return [string]$property.Value
}

if (-not $ForceSignOut) {
    throw 'ForceSignOut is required because MaintenanceWindow replacement can forcibly terminate user sessions.'
}

try {
    $timeZone = [System.TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneId)
}
catch {
    throw "TimeZoneId '$TimeZoneId' is not available on this system."
}

$unspecifiedScheduledDateTime = [datetime]::SpecifyKind($ScheduledDateTime, [DateTimeKind]::Unspecified)
if ($timeZone.IsInvalidTime($unspecifiedScheduledDateTime)) {
    throw "ScheduledDateTime '$ScheduledDateTime' does not exist in time zone '$TimeZoneId' because of a daylight-saving transition."
}
if ($timeZone.IsAmbiguousTime($unspecifiedScheduledDateTime)) {
    throw "ScheduledDateTime '$ScheduledDateTime' is ambiguous in time zone '$TimeZoneId'. Choose an unambiguous time."
}

$scheduledDateTimeUtc = [System.TimeZoneInfo]::ConvertTimeToUtc(
    $unspecifiedScheduledDateTime,
    $timeZone
)
if ($scheduledDateTimeUtc -le [DateTime]::UtcNow) {
    throw 'ScheduledDateTime must be in the future.'
}

$context = Get-AzContext
if ($null -eq $context -or $null -eq $context.Subscription) {
    throw 'No authenticated Az context is available. Run Connect-AzAccount first.'
}
if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
    $SubscriptionId = $context.Subscription.Id
}

$functionAppResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName"
$functionApp = Invoke-ArmRequest -Method GET -Path "$functionAppResourceId`?api-version=$webApiVersion"
if ($functionApp.type -ne 'Microsoft.Web/sites' -or $functionApp.kind -notmatch 'functionapp') {
    throw "Resource $functionAppResourceId is not a Function App."
}

$settingsResponse = Invoke-ArmRequest `
    -Method POST `
    -Path "$functionAppResourceId/config/appsettings/list?api-version=$webApiVersion" `
    -Body @{}
$settings = $settingsResponse.properties
if ($null -eq $settings -or
    [string]::IsNullOrWhiteSpace((Get-SettingValue -Settings $settings -Name 'HostPoolName'))) {
    throw 'The Function App is not a recognizable Session Host Replacer deployment.'
}
$replacementMode = Get-SettingValue -Settings $settings -Name 'ReplacementMode'
if ($replacementMode -ne 'DeleteFirst') {
    throw "The Function App ReplacementMode must be DeleteFirst. Found '$replacementMode'."
}

try {
    $sessionHostParameters = Get-SettingValue -Settings $settings -Name 'SessionHostParameters' |
        ConvertFrom-Json -ErrorAction Stop
}
catch {
    throw "SessionHostParameters is missing or invalid: $($_.Exception.Message)"
}

$isEntraJoined = [string]$sessionHostParameters.IdentitySolution -in @(
    'EntraId'
    'EntraKerberos-Hybrid'
    'EntraKerberos-CloudOnly'
)
$removeEntraDevice = $false
if (-not [bool]::TryParse(
    (Get-SettingValue -Settings $settings -Name 'RemoveEntraDevice'),
    [ref]$removeEntraDevice
)) {
    throw 'RemoveEntraDevice must be a Boolean Function App setting.'
}
if ($isEntraJoined -and -not $removeEntraDevice) {
    throw 'Maintenance replacement requires RemoveEntraDevice=true for Microsoft Entra joined hosts because hostnames are reused. Configure device cleanup and Graph permissions before scheduling the request.'
}

$virtualMachinesSubscriptionId = Get-SettingValue -Settings $settings -Name 'VirtualMachinesSubscriptionId'
$virtualMachinesResourceGroupName = Get-SettingValue -Settings $settings -Name 'VirtualMachinesResourceGroupName'
$shutdownRetentionTag = Get-SettingValue -Settings $settings -Name 'Tag_ShutdownTimestamp'
$virtualMachinesResponse = Invoke-ArmRequest `
    -Method GET `
    -Path "/subscriptions/$virtualMachinesSubscriptionId/resourceGroups/$virtualMachinesResourceGroupName/providers/Microsoft.Compute/virtualMachines?api-version=2024-07-01"
$retainedVMs = @(
    $virtualMachinesResponse.value |
        Where-Object {
            $_.tags -and
            $_.tags.PSObject.Properties.Name -contains $shutdownRetentionTag -and
            -not [string]::IsNullOrWhiteSpace([string]$_.tags.$shutdownRetentionTag)
        }
)
if ($retainedVMs.Count -gt 0) {
    throw "Maintenance replacement cannot be scheduled while shutdown-retention VMs exist: $($retainedVMs.name -join ', '). Restore or remove them through the approved rollback or cleanup process first."
}

$existingRequestProperty = $settings.PSObject.Properties['MaintenanceRequest']
if ($null -ne $existingRequestProperty -and
    -not [string]::IsNullOrWhiteSpace([string]$existingRequestProperty.Value) -and
    -not $ReplaceExistingRequest) {
    throw 'MaintenanceRequest is already populated. After confirming that the previous request completed and no recovery is in progress, rerun with ReplaceExistingRequest.'
}
if ($ReplaceExistingRequest -and
    ($null -eq $existingRequestProperty -or
        [string]::IsNullOrWhiteSpace([string]$existingRequestProperty.Value))) {
    throw 'ReplaceExistingRequest was specified, but no existing request is populated.'
}

$request = [ordered]@{
    requestId = [guid]::NewGuid().ToString()
    approvedImageVersion = $ApprovedImageVersion
    scheduledDateTimeUtc = $scheduledDateTimeUtc.ToString('o')
    windowDurationMinutes = $WindowDurationMinutes
    maxVmsRemoved = $MaxVmsRemoved
    logOffDelayMinutes = $LogOffDelayMinutes
    logOffMessage = $LogOffMessage
    forceSignOut = $true
    allowFullPoolOutage = [bool]$AllowFullPoolOutage
}
$requestJson = $request | ConvertTo-Json -Compress

$summary = [PSCustomObject][ordered]@{
    RequestId = $request.requestId
    ConfiguredReplacementMode = $replacementMode
    ApprovedImageVersion = $ApprovedImageVersion
    ScheduledDateTimeUtc = $scheduledDateTimeUtc
    WindowEndUtc = $scheduledDateTimeUtc.AddMinutes($WindowDurationMinutes)
    MaxVmsRemoved = $MaxVmsRemoved
    LogOffDelayMinutes = $LogOffDelayMinutes
    ForceSignOut = $true
    AllowFullPoolOutage = [bool]$AllowFullPoolOutage
}
$summary | Format-List | Out-Host

$operation = "Schedule one-time maintenance replacement request $($request.requestId)"
if ($PSCmdlet.ShouldProcess($functionAppResourceId, $operation)) {
    if ($null -eq $existingRequestProperty) {
        $settings | Add-Member -NotePropertyName MaintenanceRequest -NotePropertyValue $requestJson
    }
    else {
        $existingRequestProperty.Value = $requestJson
    }

    Invoke-ArmRequest `
        -Method PUT `
        -Path "$functionAppResourceId/config/appsettings?api-version=$webApiVersion" `
        -Body @{ properties = $settings } | Out-Null

    Write-Host 'Maintenance replacement scheduled. Azure will restart the Function App to apply the request.'
}

if ($PassThru) {
    $summary
}
