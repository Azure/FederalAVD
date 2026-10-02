<#
.SYNOPSIS
    Updates the image in an automated host pool's Session Host Configuration and schedules a
    native Session Host Update.

.DESCRIPTION
    Use this script after a new image version is built or published. It performs these steps:

    1. Verifies the host pool uses the Automated management type and that no session host update
       is already scheduled or running.
    2. Resolves the target image:
       - Compute Gallery images: the newest version of the configured image definition that is
         published, not excluded from latest (globally or in the session-host region), and fully
         replicated to the session-host region. ImageVersionResourceId selects an exact version and
         ImageDefinitionResourceId selects a different definition.
       - Marketplace images: the newest version available in the session-host region for the
         configured publisher, offer, and SKU.
    3. Sends a partial (PATCH) update containing only imageInfo. Availability zones, credentials,
       and every other Session Host Configuration property are left untouched, so the update does
       not fail on properties that cannot change while session hosts exist.
    4. Disables every scaling plan assignment for the host pool. Microsoft requires autoscale to be
       disabled for the duration of a session host update.
    5. Initiates the session host update immediately or at ScheduledDateTime. Update batch settings
       not supplied on the command line use the host pool's Session Host Management values.
    6. Optionally waits for completion and re-enables the scaling plan assignments it disabled.

    When WaitForCompletion is not used, the scaling plan assignments remain disabled. Run the script
    with -EnableScalingPlans after the update finishes.

    The script uses Invoke-AzRestMethod, so it works in every Azure cloud supported by the current
    Az context, including Azure Government Secret and Top Secret.

.PARAMETER HostPoolName
    Name of the automated host pool.

.PARAMETER HostPoolResourceGroupName
    Resource group that contains the host pool (the control-plane resource group).

.PARAMETER SubscriptionId
    Subscription that contains the host pool. Defaults to the current Az context subscription.

.PARAMETER ImageVersionResourceId
    Exact Compute Gallery image version resource ID to deploy. Skips automatic version discovery.

.PARAMETER ImageDefinitionResourceId
    Compute Gallery image definition resource ID to search for the newest version. Defaults to the
    image definition currently referenced by the Session Host Configuration.

.PARAMETER ScheduledDateTime
    Local wall-clock date and time, in TimeZone, at which the update starts. Must be in the future
    and no more than 14 days away. When omitted, the update starts immediately.

.PARAMETER TimeZone
    Windows time zone ID used to interpret ScheduledDateTime, for example 'Eastern Standard Time'.
    Defaults to the Session Host Management scheduledDateTimeZone, then the local time zone.

.PARAMETER MaxVmsRemoved
    Batch size: maximum session hosts replaced concurrently. Defaults to the Session Host
    Management value.

.PARAMETER LogOffDelayMinutes
    Minutes users have to sign out before a host is replaced. Defaults to the Session Host
    Management value. Must be between 0 and 60 minutes.

.PARAMETER LogOffMessage
    Message sent to signed-in users before a host is replaced. Defaults to the Session Host
    Management value.

.PARAMETER DeleteOriginalVm
    Whether to delete each original VM after it is replaced. Defaults to the Session Host
    Management value.

.PARAMETER Force
    Initiates an update even when the Session Host Configuration already uses the resolved image.

.PARAMETER WaitForCompletion
    Waits until the update reaches a final state. On success, re-enables the scaling plan
    assignments that this run disabled.

.PARAMETER PollIntervalSeconds
    Status polling interval used with WaitForCompletion.

.PARAMETER TimeoutMinutes
    Maximum minutes to wait after the update start time when WaitForCompletion is used.

.PARAMETER EnableScalingPlans
    Re-enables every scaling plan assignment for the host pool and exits. Refuses to run while an
    update is scheduled or in progress.

.EXAMPLE
    # Deploy the newest replicated version of the current gallery image definition at 10 PM Eastern.
    .\Update-AutomatedHostPoolImage.ps1 -HostPoolName vdpool-avd-prod-use2 `
        -HostPoolResourceGroupName rg-avd-control-plane-use2 `
        -ScheduledDateTime '2026-10-03 22:00' -TimeZone 'Eastern Standard Time'

.EXAMPLE
    # Deploy an exact image version now, two hosts at a time, and restore autoscale when done.
    .\Update-AutomatedHostPoolImage.ps1 -HostPoolName vdpool-avd-prod-use2 `
        -HostPoolResourceGroupName rg-avd-control-plane-use2 `
        -ImageVersionResourceId '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Compute/galleries/<gallery>/images/<definition>/versions/2026.1001.1200' `
        -MaxVmsRemoved 2 -WaitForCompletion

.EXAMPLE
    # Preview the image that would be selected without changing anything.
    .\Update-AutomatedHostPoolImage.ps1 -HostPoolName vdpool-avd-prod-use2 `
        -HostPoolResourceGroupName rg-avd-control-plane-use2 -WhatIf

.EXAMPLE
    # Re-enable autoscale after a scheduled update has finished.
    .\Update-AutomatedHostPoolImage.ps1 -HostPoolName vdpool-avd-prod-use2 `
        -HostPoolResourceGroupName rg-avd-control-plane-use2 -EnableScalingPlans

.NOTES
    Requires the Az.Accounts module and a signed-in Az context (Connect-AzAccount).
    Required permissions: Desktop Virtualization Host Pool Contributor (or equivalent write access
    to the host pool and its child resources), write access to scaling plans that reference the
    host pool, and read access to the image gallery. The image must be in the same subscription
    as the host pool.
#>

#Requires -Modules Az.Accounts

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Update')]
param(
    [Parameter(Mandatory)]
    [string]$HostPoolName,

    [Parameter(Mandatory)]
    [string]$HostPoolResourceGroupName,

    [string]$SubscriptionId,

    [Parameter(ParameterSetName = 'Update')]
    [ValidatePattern('(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Compute/galleries/[^/]+/images/[^/]+/versions/[^/]+$')]
    [string]$ImageVersionResourceId,

    [Parameter(ParameterSetName = 'Update')]
    [ValidatePattern('(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Compute/galleries/[^/]+/images/[^/]+$')]
    [string]$ImageDefinitionResourceId,

    [Parameter(ParameterSetName = 'Update')]
    [datetime]$ScheduledDateTime,

    [Parameter(ParameterSetName = 'Update')]
    [string]$TimeZone,

    [Parameter(ParameterSetName = 'Update')]
    [ValidateRange(1, 1000)]
    [int]$MaxVmsRemoved,

    [Parameter(ParameterSetName = 'Update')]
    [ValidateRange(0, 60)]
    [int]$LogOffDelayMinutes,

    [Parameter(ParameterSetName = 'Update')]
    [ValidateLength(0, 260)]
    [string]$LogOffMessage,

    [Parameter(ParameterSetName = 'Update')]
    [bool]$DeleteOriginalVm,

    [Parameter(ParameterSetName = 'Update')]
    [switch]$Force,

    [Parameter(ParameterSetName = 'Update')]
    [switch]$WaitForCompletion,

    [Parameter(ParameterSetName = 'Update')]
    [ValidateRange(30, 3600)]
    [int]$PollIntervalSeconds = 120,

    [Parameter(ParameterSetName = 'Update')]
    [ValidateRange(1, 20160)]
    [int]$TimeoutMinutes = 1440,

    [Parameter(Mandatory, ParameterSetName = 'EnableScalingPlans')]
    [switch]$EnableScalingPlans
)

$ErrorActionPreference = 'Stop'

$avdApiVersion = '2025-11-01-preview'
$galleryApiVersion = '2024-03-03'
$computeApiVersion = '2024-07-01'
$activeUpdateStates = @('Scheduled', 'ValidatingSessionHostUpdate', 'UpdatingSessionHosts', 'Pausing', 'Paused', 'Cancelling', 'Error')

function Write-Step {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message"
}

function Invoke-ArmRequest {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GET', 'PATCH', 'POST')]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Path,

        [object]$Body,

        [switch]$AllowNotFound
    )

    $request = @{ Method = $Method; Path = $Path }
    if ($null -ne $Body) {
        $request['Payload'] = $Body | ConvertTo-Json -Depth 20 -Compress
    }

    $response = Invoke-AzRestMethod @request
    if ($AllowNotFound -and $response.StatusCode -eq 404) {
        return $null
    }

    if ($response.StatusCode -ge 400) {
        throw "$Method $Path failed with HTTP $($response.StatusCode): $($response.Content)"
    }

    if ([string]::IsNullOrWhiteSpace($response.Content)) {
        return $null
    }

    return $response.Content | ConvertFrom-Json
}

function Get-ArmCollection {
    param([Parameter(Mandatory)][string]$Path)

    $items = [System.Collections.Generic.List[object]]::new()
    $nextPath = $Path
    while ($nextPath) {
        $page = Invoke-ArmRequest -Method GET -Path $nextPath
        if ($null -eq $page) { break }
        if ($page.PSObject.Properties.Name -contains 'value') {
            foreach ($item in $page.value) { $items.Add($item) }
            $nextPath = $null
            if ($page.nextLink) {
                $nextPath = ([uri]$page.nextLink).PathAndQuery
            }
        }
        else {
            foreach ($item in @($page)) { $items.Add($item) }
            $nextPath = $null
        }
    }

    return $items.ToArray()
}

function Get-NormalizedRegion {
    param([string]$Region)
    return ($Region -replace '\s', '').ToLowerInvariant()
}

function Get-UpdateStatus {
    return Invoke-ArmRequest -Method GET -AllowNotFound -Path "$hostPoolPath/sessionHostManagements/default/sessionHostUpdateStatuses/default?api-version=$avdApiVersion"
}

function Assert-NoActiveUpdate {
    $status = Get-UpdateStatus
    if ($status -and $status.status -in $activeUpdateStates) {
        throw "A session host update is already '$($status.status)' for host pool '$HostPoolName'. Wait for it to finish, or cancel or retry it, before running this script."
    }

    return $status
}

function Get-ScalingPlanReferences {
    $plans = Get-ArmCollection -Path "$hostPoolPath/scalingPlans?api-version=$avdApiVersion"
    foreach ($plan in $plans) {
        $reference = $plan.properties.hostPoolReferences |
            Where-Object { $_.hostPoolArmPath -ieq $hostPoolId }
        if ($reference) {
            [pscustomobject]@{
                Id      = $plan.id
                Name    = $plan.name
                Plan    = $plan
                Enabled = [bool]$reference.scalingPlanEnabled
            }
        }
    }
}

function Set-ScalingPlanReference {
    param(
        [Parameter(Mandatory)][object]$PlanReference,
        [Parameter(Mandatory)][bool]$Enabled
    )

    # PATCH replaces the complete hostPoolReferences array, so resend every reference.
    $references = @(
        foreach ($reference in $PlanReference.Plan.properties.hostPoolReferences) {
            $isTarget = $reference.hostPoolArmPath -ieq $hostPoolId
            @{
                hostPoolArmPath    = $reference.hostPoolArmPath
                scalingPlanEnabled = if ($isTarget) { $Enabled } else { [bool]$reference.scalingPlanEnabled }
            }
        }
    )

    $action = if ($Enabled) { 'Enable' } else { 'Disable' }
    if ($PSCmdlet.ShouldProcess($PlanReference.Id, "$action scaling plan assignment for host pool '$HostPoolName'")) {
        Invoke-ArmRequest -Method PATCH -Path "$($PlanReference.Id)?api-version=$avdApiVersion" -Body @{
            properties = @{ hostPoolReferences = $references }
        } | Out-Null
        Write-Step "$($action)d scaling plan '$($PlanReference.Name)' for host pool '$HostPoolName'."
    }
}

function Get-LatestGalleryImageVersion {
    param(
        [Parameter(Mandatory)][string]$DefinitionId,
        [Parameter(Mandatory)][string]$Region
    )

    $normalizedRegion = Get-NormalizedRegion -Region $Region
    $versions = Get-ArmCollection -Path "$DefinitionId/versions?api-version=$galleryApiVersion"
    if (-not $versions) {
        throw "No image versions were found in '$DefinitionId'."
    }

    $candidates = $versions | Where-Object {
        $publishingProfile = $_.properties.publishingProfile
        $regional = $publishingProfile.targetRegions |
            Where-Object { (Get-NormalizedRegion -Region $_.name) -eq $normalizedRegion }
        $_.properties.provisioningState -eq 'Succeeded' -and
        $publishingProfile.publishedDate -and
        -not $publishingProfile.excludeFromLatest -and
        $regional -and
        -not $regional.excludeFromLatest
    } | Sort-Object -Property { [datetime]$_.properties.publishingProfile.publishedDate } -Descending

    if (-not $candidates) {
        throw "No image version in '$DefinitionId' targets region '$Region' without being excluded from latest."
    }

    foreach ($candidate in $candidates) {
        $details = Invoke-ArmRequest -Method GET -Path "$($candidate.id)?`$expand=ReplicationStatus&api-version=$galleryApiVersion"
        $replication = $details.properties.replicationStatus.summary |
            Where-Object { (Get-NormalizedRegion -Region $_.region) -eq $normalizedRegion }
        if ($replication.state -eq 'Completed') {
            return $details
        }

        Write-Warning "Skipping image version '$($candidate.name)': replication to '$Region' is '$($replication.state)'."
    }

    throw "No image version in '$DefinitionId' has completed replication to region '$Region'."
}

function Assert-GalleryImageVersion {
    param(
        [Parameter(Mandatory)][string]$VersionId,
        [Parameter(Mandatory)][string]$Region
    )

    $normalizedRegion = Get-NormalizedRegion -Region $Region
    $details = Invoke-ArmRequest -Method GET -Path "$($VersionId)?`$expand=ReplicationStatus&api-version=$galleryApiVersion"
    if ($details.properties.provisioningState -ne 'Succeeded') {
        throw "Image version '$VersionId' has provisioning state '$($details.properties.provisioningState)'."
    }

    $replication = $details.properties.replicationStatus.summary |
        Where-Object { (Get-NormalizedRegion -Region $_.region) -eq $normalizedRegion }
    if ($replication.state -ne 'Completed') {
        throw "Image version '$VersionId' is not replicated to region '$Region' (state: '$($replication.state)')."
    }

    return $details
}

# ---------------------------------------------------------------------------
# Context and host pool
# ---------------------------------------------------------------------------
$context = Get-AzContext
if (-not $context) {
    throw 'No Azure context found. Run Connect-AzAccount first.'
}

if (-not $SubscriptionId) {
    $SubscriptionId = $context.Subscription.Id
}

$hostPoolPath = "/subscriptions/$SubscriptionId/resourceGroups/$HostPoolResourceGroupName/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName"
$hostPool = Invoke-ArmRequest -Method GET -Path "$($hostPoolPath)?api-version=$avdApiVersion"
$hostPoolId = $hostPool.id
if ($hostPool.properties.managementType -ne 'Automated') {
    throw "Host pool '$HostPoolName' uses management type '$($hostPool.properties.managementType)'. This script supports only automated host pools."
}

$previousStatus = Assert-NoActiveUpdate

if ($PSCmdlet.ParameterSetName -eq 'EnableScalingPlans') {
    $planReferences = @(Get-ScalingPlanReferences)
    if (-not $planReferences) {
        Write-Step "No scaling plan is assigned to host pool '$HostPoolName'."
        return
    }

    foreach ($planReference in $planReferences | Where-Object { -not $_.Enabled }) {
        Set-ScalingPlanReference -PlanReference $planReference -Enabled $true
    }

    $planReferences | Where-Object Enabled | ForEach-Object {
        Write-Step "Scaling plan '$($_.Name)' is already enabled for host pool '$HostPoolName'."
    }
    return
}

if ($ImageVersionResourceId -and $ImageDefinitionResourceId) {
    throw 'Specify either ImageVersionResourceId or ImageDefinitionResourceId, not both.'
}

# ---------------------------------------------------------------------------
# Resolve the target image
# ---------------------------------------------------------------------------
$configurationPath = "$hostPoolPath/sessionHostConfigurations/default?api-version=$avdApiVersion"
$configuration = Invoke-ArmRequest -Method GET -Path $configurationPath
$region = $configuration.properties.vmLocation
$currentImage = $configuration.properties.imageInfo
$currentImageDescription = if ($currentImage.type -eq 'Custom') {
    $currentImage.customInfo.resourceId
}
else {
    $currentImage.marketplaceInfo | ConvertTo-Json -Compress
}

Write-Step "Current image: $currentImageDescription"
Write-Step "Session host region: $region"

$definitionId = $ImageDefinitionResourceId
if (-not $ImageVersionResourceId -and -not $definitionId -and $currentImage.type -eq 'Custom') {
    $currentId = $currentImage.customInfo.resourceId
    if ($currentId -match '(?i)^(/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Compute/galleries/[^/]+/images/[^/]+)(/versions/[^/]+)?$') {
        $definitionId = $Matches[1]
    }
    else {
        throw "The current custom image '$currentId' is not a Compute Gallery image. Supply ImageVersionResourceId or ImageDefinitionResourceId."
    }
}

if ($ImageVersionResourceId -or $definitionId) {
    if ($ImageVersionResourceId) {
        $selectedVersion = Assert-GalleryImageVersion -VersionId $ImageVersionResourceId -Region $region
    }
    else {
        $selectedVersion = Get-LatestGalleryImageVersion -DefinitionId $definitionId -Region $region
    }

    $imageSubscriptionId = ($selectedVersion.id -split '/')[2]
    if ($imageSubscriptionId -ne ($hostPoolId -split '/')[2]) {
        throw "Image version '$($selectedVersion.id)' is in subscription '$imageSubscriptionId'. Session host update requires the image in the host pool subscription."
    }

    $newImageInfo = @{
        type       = 'Custom'
        customInfo = @{ resourceId = $selectedVersion.id }
    }
    $newImageDescription = $selectedVersion.id
    $isCurrentImage = $currentImage.type -eq 'Custom' -and $currentImage.customInfo.resourceId -ieq $selectedVersion.id
}
else {
    $marketplace = $currentImage.marketplaceInfo
    $versionsPath = "/subscriptions/$SubscriptionId/providers/Microsoft.Compute/locations/$region/publishers/$($marketplace.publisher)/artifacttypes/vmimage/offers/$($marketplace.offer)/skus/$($marketplace.sku)/versions?api-version=$computeApiVersion"
    $latestVersion = Get-ArmCollection -Path $versionsPath |
        Sort-Object -Property { try { [version]$_.name } catch { [version]'0.0' } } -Descending |
        Select-Object -First 1
    if (-not $latestVersion) {
        throw "No marketplace versions were found for $($marketplace.publisher)/$($marketplace.offer)/$($marketplace.sku) in '$region'."
    }

    $newImageInfo = @{
        type            = 'Marketplace'
        marketplaceInfo = @{
            publisher    = $marketplace.publisher
            offer        = $marketplace.offer
            sku          = $marketplace.sku
            exactVersion = $latestVersion.name
        }
    }
    $newImageDescription = "$($marketplace.publisher)/$($marketplace.offer)/$($marketplace.sku)/$($latestVersion.name)"
    $isCurrentImage = $marketplace.exactVersion -eq $latestVersion.name
}

Write-Step "Target image: $newImageDescription"

if ($isCurrentImage -and -not $Force) {
    Write-Step 'The Session Host Configuration already uses the target image. No update was started. Use -Force to start an update anyway.'
    return [pscustomobject]@{
        HostPool     = $HostPoolName
        Image        = $newImageDescription
        UpdateStatus = 'NotStarted'
    }
}

# ---------------------------------------------------------------------------
# Build the update request before changing anything
# ---------------------------------------------------------------------------
$management = Invoke-ArmRequest -Method GET -Path "$hostPoolPath/sessionHostManagements/default?api-version=$avdApiVersion"
$updateBody = @{}
$scheduledUtc = $null
if ($PSBoundParameters.ContainsKey('ScheduledDateTime')) {
    if (-not $TimeZone) {
        $TimeZone = if ($management.properties.scheduledDateTimeZone) { $management.properties.scheduledDateTimeZone } else { [TimeZoneInfo]::Local.Id }
    }

    $timeZoneInfo = [TimeZoneInfo]::FindSystemTimeZoneById($TimeZone)
    $wallClock = [datetime]::SpecifyKind($ScheduledDateTime, [DateTimeKind]::Unspecified)
    $scheduledUtc = [TimeZoneInfo]::ConvertTimeToUtc($wallClock, $timeZoneInfo)
    $nowUtc = [datetime]::UtcNow
    if ($scheduledUtc -le $nowUtc.AddMinutes(1)) {
        throw "ScheduledDateTime '$ScheduledDateTime' ($TimeZone) is not in the future."
    }

    if ($scheduledUtc -gt $nowUtc.AddDays(14)) {
        throw "ScheduledDateTime '$ScheduledDateTime' ($TimeZone) is more than 14 days away."
    }

    $updateBody['scheduledDateTime'] = $scheduledUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $updateBody['scheduledDateTimeZone'] = $TimeZone
    Write-Step "Update scheduled for $($wallClock.ToString('yyyy-MM-dd HH:mm')) $TimeZone ($($updateBody['scheduledDateTime']))."
}
else {
    Write-Step 'Update will start immediately.'
}

$updateSettings = @{}
if ($PSBoundParameters.ContainsKey('MaxVmsRemoved')) { $updateSettings['maxVmsRemoved'] = $MaxVmsRemoved }
if ($PSBoundParameters.ContainsKey('LogOffDelayMinutes')) { $updateSettings['logOffDelayMinutes'] = $LogOffDelayMinutes }
if ($PSBoundParameters.ContainsKey('LogOffMessage')) { $updateSettings['logOffMessage'] = $LogOffMessage }
if ($PSBoundParameters.ContainsKey('DeleteOriginalVm')) { $updateSettings['deleteOriginalVm'] = $DeleteOriginalVm }
if ($updateSettings.Count -gt 0) {
    $updateBody['update'] = $updateSettings
}

$effectiveSettings = $management.properties.update
$effectiveLogOffDelayMinutes = if ($updateSettings.ContainsKey('logOffDelayMinutes')) {
    $updateSettings.logOffDelayMinutes
}
else {
    $effectiveSettings.logOffDelayMinutes
}
if ($effectiveLogOffDelayMinutes -lt 0 -or $effectiveLogOffDelayMinutes -gt 60) {
    throw "The effective logoff delay must be between 0 and 60 minutes. Redeploy the host pool or pass -LogOffDelayMinutes with a supported value."
}

Write-Step ("Batch settings: maxVmsRemoved={0}, logOffDelayMinutes={1}, deleteOriginalVm={2}" -f `
    $(if ($updateSettings.ContainsKey('maxVmsRemoved')) { $updateSettings.maxVmsRemoved } else { $effectiveSettings.maxVmsRemoved }),
    $effectiveLogOffDelayMinutes,
    $(if ($updateSettings.ContainsKey('deleteOriginalVm')) { $updateSettings.deleteOriginalVm } else { $effectiveSettings.deleteOriginalVm }))

# ---------------------------------------------------------------------------
# Update the Session Host Configuration image only
# ---------------------------------------------------------------------------
if (-not $isCurrentImage) {
    if ($PSCmdlet.ShouldProcess("$HostPoolName/sessionHostConfigurations/default", "Set image to $newImageDescription")) {
        $previousVersion = $configuration.properties.version
        Invoke-ArmRequest -Method PATCH -Path $configurationPath -Body @{
            properties = @{ imageInfo = $newImageInfo }
        } | Out-Null

        $deadline = (Get-Date).AddMinutes(15)
        do {
            Start-Sleep -Seconds 10
            $configuration = Invoke-ArmRequest -Method GET -Path $configurationPath
            $state = $configuration.properties.provisioningState
            if ($state -eq 'Failed') {
                throw "The Session Host Configuration update failed. Review the host pool activity log."
            }
        } while (($state -ne 'Succeeded' -or $configuration.properties.version -eq $previousVersion) -and (Get-Date) -lt $deadline)

        if ($state -ne 'Succeeded') {
            throw "The Session Host Configuration did not finish updating within 15 minutes (state: '$state')."
        }

        Write-Step "Session Host Configuration updated to version $($configuration.properties.version)."
    }
}

# ---------------------------------------------------------------------------
# Disable autoscale, then initiate the update
# ---------------------------------------------------------------------------
$disabledPlans = @(Get-ScalingPlanReferences | Where-Object Enabled)
foreach ($planReference in $disabledPlans) {
    Set-ScalingPlanReference -PlanReference $planReference -Enabled $false
}

if (-not $PSCmdlet.ShouldProcess($HostPoolName, 'Initiate session host update')) {
    return
}

try {
    Invoke-ArmRequest -Method POST -Path "$hostPoolPath/sessionHostManagements/default/initiateSessionHostUpdate?api-version=$avdApiVersion" -Body $updateBody | Out-Null
}
catch {
    Write-Warning 'Initiating the session host update failed. Restoring scaling plan assignments disabled by this run.'
    foreach ($planReference in $disabledPlans) {
        Set-ScalingPlanReference -PlanReference $planReference -Enabled $true
    }
    throw
}

Write-Step 'Session host update initiated.'

$status = $null
$deadline = (Get-Date).AddMinutes(5)
do {
    Start-Sleep -Seconds 15
    $status = Get-UpdateStatus
} while ((-not $status -or ($previousStatus -and $status.name -eq $previousStatus.name)) -and (Get-Date) -lt $deadline)

if ($status) {
    Write-Step "Update status: $($status.status)"
}

if (-not $WaitForCompletion) {
    if ($disabledPlans) {
        Write-Warning ("Scaling plan assignments remain disabled until the update finishes. Afterwards run: " +
            ".\Update-AutomatedHostPoolImage.ps1 -HostPoolName $HostPoolName -HostPoolResourceGroupName $HostPoolResourceGroupName -EnableScalingPlans")
    }

    return [pscustomobject]@{
        HostPool             = $HostPoolName
        Image                = $newImageDescription
        ScheduledDateTimeUtc = $scheduledUtc
        UpdateStatus         = $status.status
        DisabledScalingPlans = $disabledPlans.Name
    }
}

# ---------------------------------------------------------------------------
# Wait for completion
# ---------------------------------------------------------------------------
$startUtc = if ($scheduledUtc) { $scheduledUtc } else { [datetime]::UtcNow }
$deadlineUtc = $startUtc.AddMinutes($TimeoutMinutes)
while ($status.status -notin @('Succeeded', 'Failed', 'Cancelled', 'Error', 'Paused') -and [datetime]::UtcNow -lt $deadlineUtc) {
    Start-Sleep -Seconds $PollIntervalSeconds
    $status = Get-UpdateStatus
    $progress = $status.properties.progress
    Write-Step ("Update status: {0} ({1}% complete, {2}/{3} hosts done, {4} in progress)" -f `
        $status.status, $status.percentComplete, $progress.sessionHostsCompleted, $progress.totalSessionHosts, $progress.sessionHostsInProgress)
}

$result = [pscustomobject]@{
    HostPool             = $HostPoolName
    Image                = $newImageDescription
    ScheduledDateTimeUtc = $scheduledUtc
    UpdateStatus         = $status.status
    DisabledScalingPlans = $disabledPlans.Name
}

switch ($status.status) {
    'Succeeded' {
        foreach ($planReference in $disabledPlans) {
            Set-ScalingPlanReference -PlanReference $planReference -Enabled $true
        }
        $result.DisabledScalingPlans = @()
        Write-Step 'Session host update succeeded.'
    }
    { $_ -in @('Failed', 'Cancelled', 'Error', 'Paused') } {
        Write-Warning ("Session host update ended in state '$($status.status)'. Scaling plan assignments were left disabled. " +
            "Error: $($status.error.message)")
    }
    default {
        Write-Warning "Stopped waiting after $TimeoutMinutes minutes with update state '$($status.status)'. Scaling plan assignments were left disabled."
    }
}

return $result
