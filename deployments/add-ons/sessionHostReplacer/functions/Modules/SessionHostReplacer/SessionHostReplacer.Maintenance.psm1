# SessionHostReplacer Maintenance Module
# Contains one-time maintenance request validation and scheduling decisions.

function ConvertFrom-MaintenanceRequest {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $RequestJson
    )

    if ([string]::IsNullOrWhiteSpace($RequestJson)) {
        return $null
    }

    try {
        $request = $RequestJson | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "MaintenanceRequest is not valid JSON: $($_.Exception.Message)"
    }

    $requiredProperties = @(
        'requestId'
        'approvedImageVersion'
        'scheduledDateTimeUtc'
        'windowDurationMinutes'
        'maxVmsRemoved'
        'logOffDelayMinutes'
        'logOffMessage'
        'forceSignOut'
        'allowFullPoolOutage'
    )
    foreach ($propertyName in $requiredProperties) {
        if ($null -eq $request.PSObject.Properties[$propertyName]) {
            throw "MaintenanceRequest is missing required property '$propertyName'."
        }
    }

    $requestId = [guid]::Empty
    if (-not [guid]::TryParse([string]$request.requestId, [ref]$requestId) -or
        $requestId -eq [guid]::Empty) {
        throw 'MaintenanceRequest requestId must be a non-empty GUID.'
    }

    if ([string]::IsNullOrWhiteSpace([string]$request.approvedImageVersion)) {
        throw 'MaintenanceRequest approvedImageVersion must not be empty.'
    }

    $scheduledDateTimeUtc = [datetime]::MinValue
    if (-not [datetime]::TryParse(
        [string]$request.scheduledDateTimeUtc,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal -bor
            [System.Globalization.DateTimeStyles]::AdjustToUniversal,
        [ref]$scheduledDateTimeUtc
    )) {
        throw 'MaintenanceRequest scheduledDateTimeUtc must be an ISO 8601 timestamp.'
    }

    $windowDurationMinutes = [int]$request.windowDurationMinutes
    if ($windowDurationMinutes -lt 30 -or $windowDurationMinutes -gt 1440) {
        throw 'MaintenanceRequest windowDurationMinutes must be between 30 and 1440.'
    }

    $maxVmsRemoved = [int]$request.maxVmsRemoved
    if ($maxVmsRemoved -lt 1 -or $maxVmsRemoved -gt 1000) {
        throw 'MaintenanceRequest maxVmsRemoved must be between 1 and 1000.'
    }

    $logOffDelayMinutes = [int]$request.logOffDelayMinutes
    if ($logOffDelayMinutes -lt 0 -or $logOffDelayMinutes -gt 60) {
        throw 'MaintenanceRequest logOffDelayMinutes must be between 0 and 60.'
    }

    $logOffMessage = [string]$request.logOffMessage
    if ([string]::IsNullOrWhiteSpace($logOffMessage) -or $logOffMessage.Length -gt 260) {
        throw 'MaintenanceRequest logOffMessage must contain 1 to 260 characters.'
    }

    if ($request.forceSignOut -isnot [bool] -or -not $request.forceSignOut) {
        throw 'MaintenanceRequest forceSignOut must be true.'
    }
    if ($request.allowFullPoolOutage -isnot [bool]) {
        throw 'MaintenanceRequest allowFullPoolOutage must be a JSON boolean.'
    }

    return [PSCustomObject]@{
        RequestId = $requestId.ToString()
        ApprovedImageVersion = [string]$request.approvedImageVersion
        ScheduledDateTimeUtc = $scheduledDateTimeUtc.ToUniversalTime()
        WindowDurationMinutes = $windowDurationMinutes
        WindowEndUtc = $scheduledDateTimeUtc.ToUniversalTime().AddMinutes($windowDurationMinutes)
        MaxVmsRemoved = $maxVmsRemoved
        LogOffDelayMinutes = $logOffDelayMinutes
        LogOffMessage = $logOffMessage
        ForceSignOut = $true
        AllowFullPoolOutage = [bool]$request.allowFullPoolOutage
    }
}

function Set-MaintenanceApprovedImageVersion {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [hashtable] $SessionHostParameters,

        [Parameter(Mandatory = $true)]
        [string] $ApprovedImageVersion
    )

    $imageReference = $SessionHostParameters.ImageReference
    if ($null -eq $imageReference) {
        throw 'SessionHostParameters does not contain ImageReference.'
    }

    if ($imageReference.publisher) {
        $imageReference.version = $ApprovedImageVersion
        return $SessionHostParameters
    }

    if ([string]::IsNullOrWhiteSpace([string]$imageReference.id)) {
        throw 'ImageReference must contain either publisher details or a Compute Gallery image resource ID.'
    }

    $imageReference.id = if ($imageReference.id -match '/versions/[^/]+$') {
        $imageReference.id -replace '/versions/[^/]+$', "/versions/$ApprovedImageVersion"
    }
    else {
        "$($imageReference.id.TrimEnd('/'))/versions/$ApprovedImageVersion"
    }

    return $SessionHostParameters
}

function Get-MaintenanceExecutionDecision {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        $Request,

        [Parameter(Mandatory = $true)]
        $DeploymentState,

        [Parameter()]
        [datetime] $CurrentDateTime = [datetime]::UtcNow,

        [Parameter()]
        [string] $LatestImageVersion
    )

    $currentUtc = $CurrentDateTime.ToUniversalTime()
    if ($DeploymentState.CompletedMaintenanceRequestId -eq $Request.RequestId) {
        return [PSCustomObject]@{
            Status = 'Completed'
            CanStartNewBatch = $false
            MustContinueRecovery = $false
            Reason = 'The maintenance request was already completed.'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($DeploymentState.ActiveMaintenanceRequestId) -and
        $DeploymentState.ActiveMaintenanceRequestId -ne $Request.RequestId) {
        throw "Maintenance request '$($Request.RequestId)' conflicts with active request '$($DeploymentState.ActiveMaintenanceRequestId)'."
    }

    $isActiveRequest = $DeploymentState.ActiveMaintenanceRequestId -eq $Request.RequestId
    if (-not $isActiveRequest -and $currentUtc -lt $Request.ScheduledDateTimeUtc) {
        return [PSCustomObject]@{
            Status = 'Scheduled'
            CanStartNewBatch = $false
            MustContinueRecovery = $false
            Reason = "The maintenance window starts at $($Request.ScheduledDateTimeUtc.ToString('o'))."
        }
    }

    if (-not $isActiveRequest -and $currentUtc -ge $Request.WindowEndUtc) {
        return [PSCustomObject]@{
            Status = 'Expired'
            CanStartNewBatch = $false
            MustContinueRecovery = $false
            Reason = "The maintenance request expired at $($Request.WindowEndUtc.ToString('o')) before it started."
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($LatestImageVersion) -and
        $LatestImageVersion -ne $Request.ApprovedImageVersion) {
        return [PSCustomObject]@{
            Status = 'ImageMismatch'
            CanStartNewBatch = $false
            MustContinueRecovery = $isActiveRequest
            Reason = "Approved image version '$($Request.ApprovedImageVersion)' does not match latest version '$LatestImageVersion'."
        }
    }

    $windowOpen = $currentUtc -ge $Request.ScheduledDateTimeUtc -and
        $currentUtc -lt $Request.WindowEndUtc
    return [PSCustomObject]@{
        Status = if ($windowOpen) { 'Active' } else { 'RecoveryOnly' }
        CanStartNewBatch = $windowOpen
        MustContinueRecovery = $isActiveRequest
        Reason = if ($windowOpen) {
            "The maintenance window is active until $($Request.WindowEndUtc.ToString('o'))."
        }
        else {
            'The maintenance window is closed; only recovery of an already deleted batch is allowed.'
        }
    }
}

Export-ModuleMember -Function ConvertFrom-MaintenanceRequest, Get-MaintenanceExecutionDecision, Set-MaintenanceApprovedImageVersion
