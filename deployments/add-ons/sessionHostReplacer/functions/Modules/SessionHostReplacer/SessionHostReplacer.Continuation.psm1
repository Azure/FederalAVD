$script:WorkerContext = $null

function Invoke-ShrStorageRequest {
    [CmdletBinding()]
    param(
        [ValidateSet('Table')] [string] $Service,
        [string] $Path,
        [string] $Method = 'GET',
        [string] $Body,
        [string] $ETag,
        [int[]] $ExpectedStatus = @()
    )

    $endpoint = $env:AzureWebJobsStorage__tableServiceUri
    if ([string]::IsNullOrWhiteSpace($endpoint)) {
        throw "SHR continuation requires the $Service service URI in AzureWebJobsStorage."
    }
    $token = Get-AccessToken -ResourceUri $endpoint.TrimEnd('/') -ClientId (Read-FunctionAppSetting UserAssignedIdentityClientId)
    $headers = @{
        Authorization = "Bearer $token"
        'x-ms-version' = '2019-02-02'
        'x-ms-date' = [DateTime]::UtcNow.ToString('R')
        Accept = 'application/json;odata=nometadata'
    }
    if ($ETag) { $headers['If-Match'] = $ETag }
    $parameters = @{
        Uri = "$($endpoint.TrimEnd('/'))/$Path"
        Method = $Method
        Headers = $headers
        ContentType = 'application/json'
        ErrorAction = 'Stop'
        TimeoutSec = 60
        SkipHttpErrorCheck = $true
    }
    if ($PSBoundParameters.ContainsKey('Body')) { $parameters.Body = $Body }
    $response = Invoke-WebRequest @parameters
    $status = [int]$response.StatusCode
    if (($status -lt 200 -or $status -ge 300) -and $status -notin $ExpectedStatus) {
        $exception = [InvalidOperationException]::new("SHR $Service $Method request to '$Path' failed with HTTP $status.")
        $exception.Data['StatusCode'] = $status
        throw $exception
    }
    return $response
}

function Get-ShrOperationKey {
    param([System.Collections.IDictionary] $Settings)

    $parts = @(foreach ($name in @('HostPoolSubscriptionId', 'HostPoolResourceGroupName', 'HostPoolName')) {
        if ($PSBoundParameters.ContainsKey('Settings')) { $Settings[$name] }
        else { Read-FunctionAppSetting $name }
    })
    if (@($parts | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        throw 'SHR continuation requires a complete host pool identity.'
    }
    $identity = $parts -join '/'
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($identity.ToLowerInvariant())
    )).ToLowerInvariant()
}

function ConvertTo-ShrCanonicalValue {
    param($Value)
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($name in @($Value.Keys | Sort-Object -CaseSensitive)) {
            $result[$name] = ConvertTo-ShrCanonicalValue -Value $Value[$name]
        }
        return $result
    }
    if ($Value -is [array]) {
        return ,@($Value | ForEach-Object { ConvertTo-ShrCanonicalValue -Value $_ })
    }
    return $Value
}

function Get-ShrConfigurationHash {
    param(
        [System.Collections.IDictionary] $Settings,
        [hashtable] $OperationState,
        [switch] $CaptureTarget
    )

    $values = [ordered]@{}
    foreach ($key in @(
        'SessionHostParameters', 'ReplacementMode', 'MaintenanceRequest',
        'HostPoolSubscriptionId', 'HostPoolResourceGroupName', 'HostPoolName',
        'VirtualMachinesSubscriptionId', 'VirtualMachinesResourceGroupName',
        'TargetSessionHostCount', 'SessionHostTemplate', 'SessionHostNamePrefix',
        'SessionHostNameIndexLength', 'MinimumHostIndex', 'Tag_IncludeInAutomation',
        'Tag_ScalingPlanExclusionTag', 'Tag_ValidatedImage', 'Tag_ShutdownTimestamp',
        'EnableShutdownRetention', 'AllowImageVersionRollback', 'IncludeExcludedImageVersions',
        'RemoveEntraDevice', 'RemoveIntuneDevice', 'UserAssignedIdentityClientId'
    )) {
        $values[$key] = if ($PSBoundParameters.ContainsKey('Settings')) { $Settings[$key] }
        else { [Environment]::GetEnvironmentVariable($key) }
    }
    if ($OperationState -and -not [string]::IsNullOrEmpty($values.TargetSessionHostCount)) {
        $targetCount = 0
        if (-not [int]::TryParse([string]$values.TargetSessionHostCount, [ref]$targetCount) -or
            $targetCount -lt 0 -or $targetCount -gt 1000) {
            throw 'TargetSessionHostCount must be an integer between 0 and 1000.'
        }
    }
    $calculateHash = {
        [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes(($values | ConvertTo-Json -Compress))
        )).ToLowerInvariant()
    }
    if ($OperationState -and $OperationState.ContainsKey('ConfigurationTargetCount')) {
        $values.TargetSessionHostCount = $OperationState.ConfigurationTargetCount
    }
    $currentHash = & $calculateHash
    if (-not $OperationState) { return $currentHash }
    if ($CaptureTarget -or $OperationState.ConfigurationFieldHashes) {
        $fieldHashes = @{}
        foreach ($key in $values.Keys) {
            $value = $values[$key]
            if ($key -in @('SessionHostParameters', 'MaintenanceRequest') -and $value) {
                $value = ConvertTo-ShrCanonicalValue -Value ($value | ConvertFrom-Json -AsHashtable -ErrorAction Stop)
            }
            $json = ConvertTo-Json -InputObject $value -Depth 40 -Compress
            $fieldHashes[$key] = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData(
                [Text.Encoding]::UTF8.GetBytes($json))).ToLowerInvariant()
        }
        if ($OperationState.ConfigurationFieldHashes) {
            $changed = @($fieldHashes.Keys | Where-Object {
                $fieldHashes[$_] -ne $OperationState.ConfigurationFieldHashes[$_]
            })
            if ($changed.Count -eq 0) { return $OperationState.ConfigurationHash }
            Write-LogEntry -Message "CONTINUATION | Protected configuration changed: $($changed -join ', ')." -Level Warning
        } elseif ($currentHash -eq $OperationState.ConfigurationHash -and $CaptureTarget) {
            $OperationState.ConfigurationFieldHashes = $fieldHashes
        }
    }
    if ($currentHash -eq $OperationState.ConfigurationHash) {
        if ($CaptureTarget) { $OperationState.ConfigurationTargetCount = $values.TargetSessionHostCount }
        return $currentHash
    }
    # Legacy operations recorded the effective target, not the configured auto-detect value.
    $priorTargets = @('0', $null)
    if ($OperationState.TargetCount -gt 0) {
        $priorTargets += [string]$OperationState.TargetCount
    }
    foreach ($target in $priorTargets) {
        $values.TargetSessionHostCount = $target
        $hash = & $calculateHash
        if ($hash -eq $OperationState.ConfigurationHash) {
            if ($CaptureTarget) { $OperationState.ConfigurationTargetCount = $target }
            return $hash
        }
    }
    return $currentHash
}

function Get-ShrOperation {
    param([switch] $EnsureTable, [switch] $BatchAuthorization, [switch] $ImageChange,
        [ValidatePattern('^[a-f0-9]{32}$')][string] $SupersededOperationId)

    if ($EnsureTable) {
        Invoke-ShrStorageRequest -Service Table -Path Tables -Method POST `
            -Body '{"TableName":"shrContinuation"}' -ExpectedStatus 409 | Out-Null
    }
    $key = Get-ShrOperationKey
    if ($BatchAuthorization) { $key += '-initiation' }
    if ($ImageChange) { $key += '-image-change' }
    if ($SupersededOperationId) { $key += "-superseded-$SupersededOperationId" }
    $response = Invoke-ShrStorageRequest -Service Table `
        -Path "shrContinuation(PartitionKey='SHR',RowKey='$key')" -ExpectedStatus 404
    if ([int]$response.StatusCode -eq 404) { return $null }
    $entity = $response.Content | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    $etag = [string](@($response.Headers['ETag'])[0])
    if (-not $etag) { throw 'SHR operation response has no ETag; refusing an unconditional update.' }
    return @{
        State = ($entity.State | ConvertFrom-Json -AsHashtable -ErrorAction Stop)
        ETag = $etag
        Key = $key
    }
}

function Save-ShrOperation {
    param([hashtable] $Operation, [switch] $Insert, [switch] $AllowConflict)

    $stateJson = $Operation.State | ConvertTo-Json -Depth 40 -Compress
    # Table string properties are limited to 64 KiB of UTF-16 data.
    if ([Text.Encoding]::Unicode.GetByteCount($stateJson) -gt 60000) {
        throw 'SHR operation exceeds its safe Table entity size. Reduce the deployment batch size.'
    }
    $body = @{
        PartitionKey = 'SHR'
        RowKey = $Operation.Key
        State = $stateJson
    } | ConvertTo-Json -Depth 4 -Compress
    $parameters = @{
        Service = 'Table'
        Body = $body
        ExpectedStatus = @(409, 412)
    }
    if ($Insert) {
        $parameters.Path = 'shrContinuation'
        $parameters.Method = 'POST'
    } else {
        if (-not $Operation.ETag) { throw 'SHR operation update requires an ETag.' }
        $parameters.Path = "shrContinuation(PartitionKey='SHR',RowKey='$($Operation.Key)')"
        $parameters.Method = 'PUT'
        $parameters.ETag = $Operation.ETag
    }
    $response = Invoke-ShrStorageRequest @parameters
    if ([int]$response.StatusCode -in @(409, 412)) {
        if ($AllowConflict) { return $false }
        $exception = [InvalidOperationException]::new('SHR operation ownership changed; refusing to overwrite newer state.')
        $exception.Data['ShrOwnershipConflict'] = $true
        throw $exception
    }
    $Operation.ETag = [string](@($response.Headers['ETag'])[0])
    if (-not $Operation.ETag) { throw 'SHR operation save returned no ETag.' }
    return $true
}

function Get-ShrInitiationImage {
    $parameters = Read-FunctionAppSetting SessionHostParameters | ConvertTo-CaseInsensitiveHashtable
    $requestSetting = Read-FunctionAppSetting MaintenanceRequest
    if ($requestSetting) {
        if ((Read-FunctionAppSetting ReplacementMode) -ne 'DeleteFirst') {
            throw 'Maintenance override requires configured ReplacementMode DeleteFirst.'
        }
        $requestJson = if ($requestSetting -is [string]) { $requestSetting } else {
            $requestSetting | ConvertTo-Json -Depth 10 -Compress
        }
        $request = ConvertFrom-MaintenanceRequest -RequestJson $requestJson
        $deploymentState = Get-DeploymentState
        if ($deploymentState.LastStatus -eq 'Error') { throw 'Cannot authorize an operation with unreadable recovery state.' }
        $decision = Get-MaintenanceExecutionDecision -Request $request -DeploymentState $deploymentState
        if ($decision.Status -eq 'Scheduled') {
            Write-LogEntry -Message 'CONTINUATION | Maintenance is scheduled; no new batch is authorized yet.'
            return $null
        }
        if ($decision.Status -notin @('Expired', 'Completed')) {
            $parameters = Set-MaintenanceApprovedImageVersion -SessionHostParameters $parameters `
                -ApprovedImageVersion $request.ApprovedImageVersion
        }
    }
    $armToken = Get-AccessToken -ResourceUri (Get-ResourceManagerUri)
    $image = Get-LatestImageVersion -ARMToken $armToken -ImageReference $parameters.ImageReference `
        -Location $parameters.Location -IncludeExcludedImageVersions (Read-FunctionAppSetting IncludeExcludedImageVersions -AsBoolean)
    return @{
        Definition = $image.Definition
        Version = $image.Version
        Date = ([DateTimeOffset]$image.Date).ToString('o')
    }
}

function Test-ShrPoolIdle {
    param($LatestImageVersion)

    if (Read-FunctionAppSetting MaintenanceRequest) { return $false }
    $state = Get-DeploymentState -ReadOnly
    if (-not $state -or $state.LastStatus -eq 'Error') {
        throw 'Cannot assess SHR idle status without readable deployment recovery state.'
    }
    if ($state.LastDeploymentName -or $state.ActiveMaintenanceRequestId -or
        $state.TargetSessionHostCount -gt 0 -or $state.LastTotalToReplace -gt 0) {
        return $false
    }
    $mappings = $state.PendingHostMappings | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($mappings -isnot [System.Collections.IDictionary]) {
        throw 'PendingHostMappings must be a JSON object.'
    }
    if ($mappings.Count -gt 0) { return $false }

    $armToken = Get-AccessToken -ResourceUri (Get-ResourceManagerUri)
    $subscriptionId = Read-FunctionAppSetting VirtualMachinesSubscriptionId
    $resourceGroupName = Read-FunctionAppSetting VirtualMachinesResourceGroupName
    $uri = "$(Get-ResourceManagerUri)/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Compute/virtualMachines?api-version=2024-07-01"
    $vms = @(Invoke-AzureRestMethod -ARMToken $armToken -Method Get -Uri $uri -RequireCollection)
    $retentionTag = Read-FunctionAppSetting Tag_ShutdownTimestamp
    # Retained VMs can need expiry cleanup or tag/power-state repair, even when unregistered.
    if ($retentionTag -and @($vms | Where-Object {
        $_.tags -and $_.tags.PSObject.Properties.Name -contains $retentionTag
    }).Count -gt 0) { return $false }

    $hosts = @(Get-SessionHosts -ARMToken $armToken -CachedVMs $vms -FixSessionHostTags:$false)
    if (Read-FunctionAppSetting FixSessionHostTags -AsBoolean) {
        $deployTag = Read-FunctionAppSetting Tag_DeployTimestamp
        $includeTag = Read-FunctionAppSetting Tag_IncludeInAutomation
        foreach ($hostEntry in $hosts) {
            $deployTimestamp = [datetime]::MinValue
            if (-not [datetime]::TryParse([string]$hostEntry.Tags[$deployTag], [ref]$deployTimestamp) -or
                $hostEntry.Tags[$includeTag] -notin @('True', 'False')) {
                return $false
            }
        }
    }
    $managedHosts = @($hosts | Where-Object { $_.IncludeInAutomation })
    if ($managedHosts.Count -eq 0 -or @($managedHosts | Where-Object {
        $_.IsUnavailable -or -not $_.AllowNewSession -or $_.PendingDrainTimeStamp -or
        $_.ShutdownTimestamp -or -not $_.ImageVersion -or -not $_.ImageDefinition
    }).Count -gt 0) { return $false }
    $exclusionTag = Read-FunctionAppSetting Tag_ScalingPlanExclusionTag
    if ($exclusionTag -and @($managedHosts | Where-Object {
        $_.Tags[$exclusionTag] -eq 'SessionHostReplacer'
    }).Count -gt 0) { return $false }

    $deployments = Get-Deployments -ARMToken $armToken
    if ($deployments.RunningDeployments -or $deployments.FailedDeployments) { return $false }
    $hostPoolSubscriptionId = Read-FunctionAppSetting HostPoolSubscriptionId
    $hostPoolResourceGroupName = Read-FunctionAppSetting HostPoolResourceGroupName
    $hostPoolName = Read-FunctionAppSetting HostPoolName
    $hostPoolId = "/subscriptions/$hostPoolSubscriptionId/resourceGroups/$hostPoolResourceGroupName/providers/Microsoft.DesktopVirtualization/hostPools/$hostPoolName"
    $scalingTarget = Get-ScalingPlanCurrentTarget -ARMToken $armToken -HostPoolResourceId $hostPoolId
    if ($scalingTarget.Source -eq 'InvalidExclusionTag') {
        if ($scalingTarget.CanRepairExclusionTag) { return $false }
        throw $scalingTarget.ErrorMessage
    }
    if ($scalingTarget.Source -eq 'Error') {
        throw 'Cannot assess SHR idle status because the scaling plan query failed.'
    }
    $plan = Get-SessionHostReplacementPlan -ARMToken $armToken -SessionHosts $managedHosts `
        -RunningDeployments @() -LatestImageVersion ([PSCustomObject]$LatestImageVersion) `
        -AllowImageVersionRollback (Read-FunctionAppSetting AllowImageVersionRollback -AsBoolean) `
        -ScalingPlanTarget $scalingTarget -ReadOnly
    if ($plan.TotalSessionHostsToReplace -gt 0 -or $plan.PossibleDeploymentsCount -gt 0 -or
        $plan.PossibleSessionHostDeleteCount -gt 0) { return $false }
    $readiness = Test-NewSessionHostsAvailable -ARMToken $armToken -SessionHosts $hosts `
        -LatestImageVersion ([PSCustomObject]$LatestImageVersion) -ScalingPlanTarget $scalingTarget -ReadOnly
    return $readiness.SafeToProceed -and -not $readiness.ValidationUpdatesRequired
}

function Test-ShrTemplateReferenceCorrection {
    param([System.Collections.IDictionary] $Settings, [string] $TemplateVersionId,
        [string] $ConfigurationHash, [hashtable] $OperationState)

    $previousSettings = @{}
    foreach ($key in $Settings.Keys) { $previousSettings[$key] = $Settings[$key] }
    foreach ($candidate in @(($TemplateVersionId -replace '/versions/[^/]+$', ''), $TemplateVersionId)) {
        $previousSettings['SessionHostTemplate'] = $candidate
        if ((Get-ShrConfigurationHash -Settings $previousSettings -OperationState $OperationState) -eq $ConfigurationHash) { return $true }
    }
    return $false
}

function Get-ShrRejectedBatchDecision {
    param([hashtable] $Operation)

    $state = $Operation.State
    if (-not (Read-FunctionAppSetting InitiationEnabled -AsBoolean)) {
        return @{ Allowed = $false; Reason = 'Initiation is held.' }
    }
    if ($state.Status -ne 'NeedsAttention' -or
        (Read-FunctionAppSetting ReplacementMode) -ne 'SideBySide' -or
        [int]$state.BatchNumber -ne 1 -or $state.Id -notmatch '^[a-f0-9]{32}$' -or
        $null -eq $state.BatchHostNames -or -not $state.DeploymentIntent -or
        $state.DeploymentBatchReady -or $state.MoreDeploymentsAllowed -or
        $state.CleanupIntent -or (Read-FunctionAppSetting MaintenanceRequest)) {
        return @{ Allowed = $false; Reason = 'Only a rejected first SideBySide deployment can be replanned automatically.' }
    }
    if ($state.LastError -notmatch '\b400\b|InvalidTemplate' -or
        [DateTimeOffset]$state.LockExpiresUtc -gt [DateTimeOffset]::UtcNow) {
        return @{ Allowed = $false; Reason = 'A validation failure and an expired worker lease are required.' }
    }
    $currentHash = Get-ShrConfigurationHash -OperationState $state
    if ($state.ConfigurationHash -eq $currentHash) {
        return @{ Allowed = $false; Reason = 'The rejected configuration has not been corrected.' }
    }
    $intent = $state.DeploymentIntent
    $body = $intent.Body | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    $oldTemplate = [string]$body.properties.templateLink.id
    if ($oldTemplate -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Resources/templateSpecs/[^/]+/versions/[^/]+$') {
        return @{ Allowed = $false; Reason = 'The saved request has no pinned Template Spec version.' }
    }
    if (-not (Test-ShrTemplateReferenceCorrection -Settings ([Environment]::GetEnvironmentVariables()) `
        -TemplateVersionId $oldTemplate -ConfigurationHash $state.ConfigurationHash -OperationState $state)) {
        return @{ Allowed = $false; Reason = 'Protected settings other than the template reference changed.' }
    }
    $armRoot = Get-ResourceManagerUri
    $subscription = Read-FunctionAppSetting VirtualMachinesSubscriptionId
    $group = Read-FunctionAppSetting VirtualMachinesResourceGroupName
    $vmScope = "/subscriptions/$subscription/resourceGroups/$group"
    $deploymentId = "$vmScope/providers/Microsoft.Resources/deployments/shr_$($state.Id)"
    if ($intent.Name -ne "shr_$($state.Id)" -or $intent.Uri -ne "$armRoot${deploymentId}?api-version=2021-04-01") {
        return @{ Allowed = $false; Reason = 'The saved deployment scope or attempt does not match the first batch.' }
    }
    $targets = @($intent.HostNames)
    if ($targets.Count -eq 0 -or @($targets | Where-Object { $_ -notmatch '^[a-zA-Z0-9-]{1,15}$' }).Count -gt 0 -or
        ($targets -join ',') -cne (@($body.properties.parameters.sessionHostNames.value) -join ',') -or
        ($targets -join ',') -cne (@($state.DeploymentHostNames) -join ',')) {
        return @{ Allowed = $false; Reason = 'The saved deployment target lists are invalid or inconsistent.' }
    }
    $recovery = Get-DeploymentState -ReadOnly
    if (-not $recovery -or $recovery.LastStatus -eq 'Error') {
        throw 'Cannot reconcile a rejected SHR batch without readable deployment recovery state.'
    }
    if ($recovery.LastDeploymentName -or $recovery.ActiveMaintenanceRequestId) {
        return @{ Allowed = $false; Reason = 'Deployment or maintenance recovery is still pending.' }
    }
    $mappings = $recovery.PendingHostMappings | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($mappings -isnot [System.Collections.IDictionary]) { throw 'PendingHostMappings must be a JSON object.' }
    $parameters = @{}
    foreach ($name in $body.properties.parameters.Keys) { $parameters[$name] = $body.properties.parameters[$name].value }
    $targetIds = @($targets | ForEach-Object {
        Get-SessionHostVMResourceId -Name $_ -SessionHostParameters $parameters -SubscriptionId $subscription -ResourceGroupName $group
    })
    # Preparation reserves names before ARM submission; keep only matching reservations, never clear them.
    foreach ($name in $mappings.Keys) {
        $expectedId = Get-SessionHostVMResourceId -Name $name -SessionHostParameters $parameters -SubscriptionId $subscription -ResourceGroupName $group
        if ($name -notin $targets -or $mappings[$name].ResourceId -ine $expectedId -or
            $mappings[$name].VMName -ine $expectedId.Split('/')[-1]) {
            return @{ Allowed = $false; Reason = 'Pending mappings contain unresolved or differently scoped recovery work.' }
        }
    }
    $armToken = Get-AccessToken -ResourceUri $armRoot
    $originalSpec = Invoke-AzureRestMethod -ARMToken $armToken -Method Get `
        -Uri "$armRoot${oldTemplate}?api-version=2022-02-01"
    if (-not $originalSpec -or $originalSpec.id -ine $oldTemplate) {
        throw 'Invalid original Template Spec response; rejection cannot be established.'
    }
    if (-not $originalSpec.systemData.lastModifiedAt -or
        [DateTimeOffset]$originalSpec.systemData.lastModifiedAt -gt [DateTimeOffset]$state.CreatedUtc) {
        return @{ Allowed = $false; Reason = 'The original Template Spec content cannot be verified as predating the failed attempt.' }
    }
    $declared = $originalSpec.properties.mainTemplate.parameters | ConvertTo-CaseInsensitiveHashtable
    if ($declared -isnot [System.Collections.IDictionary]) { throw 'Original Template Spec parameters must be an object.' }
    if (@($parameters.Keys | Where-Object { -not $declared.ContainsKey($_) }).Count -eq 0) {
        return @{ Allowed = $false; Reason = 'The original template could accept these parameters; submission rejection is not proven.' }
    }
    $deployments = @(Invoke-AzureRestMethod -ARMToken $armToken -Method Get `
        -Uri "$armRoot$vmScope/providers/Microsoft.Resources/deployments?api-version=2021-04-01" -RequireCollection)
    if (@($deployments | Where-Object { -not $_.name }).Count -gt 0) {
        throw 'Invalid deployment inventory; absence cannot be established.'
    }
    if (@($deployments | Where-Object { $_.name -eq $intent.Name -or $_.name -like "$($intent.Name)_*" }).Count -gt 0) {
        return @{ Allowed = $false; Reason = 'ARM has recorded work for this operation.' }
    }
    $absent = $false
    try {
        $deployment = Invoke-AzureRestMethod -ARMToken $armToken -Method Get -Uri $intent.Uri
        if ($null -eq $deployment) { throw 'Empty deployment response; absence cannot be established.' }
    } catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { $absent = $true }
        else { throw }
    }
    if (-not $absent) { return @{ Allowed = $false; Reason = 'ARM accepted the saved deployment.' } }
    $vms = @(Invoke-AzureRestMethod -ARMToken $armToken -Method Get `
        -Uri "$armRoot$vmScope/providers/Microsoft.Compute/virtualMachines?api-version=2024-07-01" -RequireCollection)
    $poolSubscription = Read-FunctionAppSetting HostPoolSubscriptionId
    $poolGroup = Read-FunctionAppSetting HostPoolResourceGroupName
    $poolName = Read-FunctionAppSetting HostPoolName
    $poolId = "/subscriptions/$poolSubscription/resourceGroups/$poolGroup/providers/Microsoft.DesktopVirtualization/hostPools/$poolName"
    $hosts = @(Invoke-AzureRestMethod -ARMToken $armToken -Method Get `
        -Uri "$armRoot$poolId/sessionHosts?api-version=2024-04-03" -RequireCollection)
    if (@($vms | Where-Object {
        -not $_.name -or $_.id -notlike "$vmScope/providers/Microsoft.Compute/virtualMachines/*" -or
        $_.id.Split('/')[-1] -ine $_.name
    }).Count -gt 0 -or @($hosts | Where-Object { -not $_.name -or -not $_.properties.resourceId }).Count -gt 0) {
        throw 'Invalid VM or AVD inventory; absence cannot be established.'
    }
    if (@($vms | Where-Object { $_.id -in $targetIds }).Count -gt 0 -or
        @($hosts | Where-Object { (($_.name -split '/')[-1] -split '\.')[0] -in $targets }).Count -gt 0) {
        return @{ Allowed = $false; Reason = 'A replacement VM or AVD registration already exists.' }
    }
    foreach ($name in $state.BatchHostNames) {
        $oldHosts = @($hosts | Where-Object { (($_.name -split '/')[-1] -split '\.')[0] -eq $name })
        if ($oldHosts.Count -ne 1 -or $oldHosts[0].properties.allowNewSession -ne $true -or
            $oldHosts[0].properties.status -ne 'Available' -or $oldHosts[0].properties.resourceId -notin @($vms.id)) {
            return @{ Allowed = $false; Reason = 'An old batch host is missing, unhealthy or draining.' }
        }
    }
    $drainTag = Read-FunctionAppSetting Tag_PendingDrainTimestamp
    $retentionTag = Read-FunctionAppSetting Tag_ShutdownTimestamp
    $exclusionTag = Read-FunctionAppSetting Tag_ScalingPlanExclusionTag
    foreach ($vm in $vms) {
        $tags = if ($null -eq $vm.tags) { @{} } else { $vm.tags | ConvertTo-CaseInsensitiveHashtable }
        if ($tags -isnot [System.Collections.IDictionary]) { throw 'VM tags must be an object.' }
        if (($drainTag -and $tags[$drainTag]) -or ($retentionTag -and $tags[$retentionTag]) -or
            ($exclusionTag -and $tags[$exclusionTag] -eq 'SessionHostReplacer')) {
            return @{ Allowed = $false; Reason = 'Drain, retention or SHR-owned scaling handoff work remains.' }
        }
    }
    return @{ Allowed = $true; Reason = 'Corrected template; no replacement work started.' }
}

function Set-ShrRejectedBatchSuperseded {
    param([hashtable] $Operation)

    $sourceJson = $Operation.State | ConvertTo-Json -Depth 40 -Compress
    $sourceHash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($sourceJson))).ToLowerInvariant()
    $archive = @{
        Key = "$($Operation.Key)-superseded-$($Operation.State.Id)"
        ETag = ''
        State = @{
            Id = $Operation.State.Id
            Status = 'Superseded'
            SupersededUtc = [DateTimeOffset]::UtcNow.ToString('o')
            Reason = 'Corrected template; authoritative checks found no started replacement work.'
            SourceStateHash = $sourceHash
            PreviousState = $Operation.State
        }
    }
    if (-not (Save-ShrOperation -Operation $archive -Insert -AllowConflict)) {
        $existing = Get-ShrOperation -SupersededOperationId $Operation.State.Id
        if (-not $existing -or $existing.State.SourceStateHash -ne $sourceHash) {
            throw 'Rejected SHR batch archive differs from the current operation; operator review is required.'
        }
    }
    $Operation.State.Status = 'Superseded'
    $Operation.State.SupersededUtc = $archive.State.SupersededUtc
    if (-not (Save-ShrOperation -Operation $Operation -AllowConflict)) {
        Write-LogEntry -Message 'CONTINUATION | Operation changed during rejected-batch reconciliation; no new work was authorized.' -Level Warning
        return $false
    }
    Write-LogEntry -Message "CONTINUATION | Superseded rejected operation $($Operation.State.Id); preserved its audit and name reservations. Replanning with the corrected configuration." -Level Trace
    Write-ShrEvent -Event Superseded -State $Operation.State
    return $true
}

function Invoke-ShrTimer {
    param([Parameter(Mandatory)][ValidateSet('Initiation', 'Reconciliation')][string] $Trigger,
        $Timer, [string] $CyclePath)

    Set-ShrLogContext -Trigger $Trigger
    $invocationResult = @{ Idle = $false }
    try {
        if ($Trigger -eq 'Initiation') {
            Write-ShrEvent -Category SHR_TIMER -Event Started
            Start-ShrContinuation -Timer $Timer
        } else {
            Invoke-ShrContinuation -CyclePath $CyclePath -InvocationResult $invocationResult
        }
        if (-not $invocationResult.Idle) { Write-ShrEvent -Category SHR_TIMER -Event Succeeded }
    } catch {
        Write-ShrEvent -Category SHR_TIMER -Event Failed
        throw
    } finally {
        Clear-ShrLogContext
    }
}

function Get-ShrAuthorizationMinutes {
    if ((Read-FunctionAppSetting ReplacementMode) -eq 'SideBySide') { return 15 }
    return 5
}

function Get-ShrProgressFingerprint {
    param([hashtable] $State)

    $values = @{
        BatchNumber = [int]$State.BatchNumber
        Deployment = $State.DeploymentIntent.Name
        Cleanup = $State.CleanupIntent
        Image = $State.Image
    }
    return ($values | ConvertTo-Json -Depth 30 -Compress)
}

function Update-ShrProgress {
    param([hashtable] $State, [hashtable] $Result, [string] $Before)

    if ($State.RecoveryPolicyVersion -ne 1) { return }
    $now = [DateTimeOffset]::UtcNow
    $progress = $Before -ne (Get-ShrProgressFingerprint -State $State)
    if (-not $State.ProgressHighWater) { $State.ProgressHighWater = @{} }
    foreach ($key in @('Registered', 'Ready', 'Retired')) {
        if ($Result.Progress -and [int]$Result.Progress[$key] -gt [int]$State.ProgressHighWater[$key]) {
            $State.ProgressHighWater[$key] = [int]$Result.Progress[$key]
            $progress = $true
        }
    }
    if ($progress) {
        $State.LastProgressUtc = $now.ToString('o')
        $State.DeadlineUtc = $now.AddHours([int]$State.ProgressTimeoutHours).ToString('o')
    }
    if ($Result.WaitingForAuthorization) {
        if (-not $State.ScheduleWaitStartedUtc) { $State.ScheduleWaitStartedUtc = $now.ToString('o') }
    } elseif ($State.ScheduleWaitStartedUtc) {
        $wait = $now - [DateTimeOffset]$State.ScheduleWaitStartedUtc
        if (-not $progress) { $State.DeadlineUtc = ([DateTimeOffset]$State.DeadlineUtc).Add($wait).ToString('o') }
        $State.ScheduleWaitStartedUtc = ''
    }
    if (-not $State.AgeWarningUtc -and $State.CreatedUtc -and $now -ge ([DateTimeOffset]$State.CreatedUtc).AddHours([int]$State.ProgressTimeoutHours)) {
        $State.AgeWarningUtc = $now.ToString('o')
        Write-LogEntry -Message "CONTINUATION | Operation $($State.Id) exceeds its total-age warning threshold; progress and scheduled waits determine expansion eligibility." -Level Warning
    }
}

function Test-ShrImageChangeBoundary {
    param([hashtable] $State, [switch] $BatchCompleted)

    if ($State.CleanupIntent -or $null -eq $State.BatchHostNames) { return $false }
    if ((Read-FunctionAppSetting ReplacementMode) -ne 'SideBySide' -and -not $BatchCompleted) { return $false }
    if ((Read-FunctionAppSetting ReplacementMode) -eq 'SideBySide' -and -not $State.DeploymentBatchReady) { return $false }
    $token = Get-AccessToken -ResourceUri (Get-ResourceManagerUri)
    $deploymentState = Get-DeploymentState -ReadOnly
    $mappings = $deploymentState.PendingHostMappings | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($mappings -isnot [System.Collections.IDictionary]) { throw 'Image change requires valid deployment recovery mappings.' }
    if ($mappings.Count -gt 0) { return $false }
    $deployments = Get-Deployments -ARMToken $token
    if ($deployments.RunningDeployments -or $deployments.FailedDeployments) { return $false }
    $hosts = @(Get-SessionHosts -ARMToken $token -FixSessionHostTags:$false)
    $image = if ($State.DeploymentImage) { $State.DeploymentImage } else { $State.Image }
    $names = @($State.DeploymentHostNames | Where-Object { $_ })
    if ($names.Count -eq 0) { $names = @($State.DeploymentIntent.HostNames | Where-Object { $_ }) }
    if ($names.Count -eq 0) { return $false }
    $tag = Read-FunctionAppSetting Tag_ScalingPlanExclusionTag
    foreach ($name in $names) {
        $matches = @($hosts | Where-Object {
            $_.SessionHostName -eq $name -and -not $_.IsUnavailable -and
            $_.ImageDefinition -eq $image.Definition -and $_.ImageVersion -eq $image.Version -and
            (-not $tag -or $_.Tags[$tag] -ne 'SessionHostReplacer')
        })
        if ($matches.Count -ne 1) { return $false }
    }
    $poolId = "/subscriptions/$(Read-FunctionAppSetting HostPoolSubscriptionId)/resourceGroups/$(Read-FunctionAppSetting HostPoolResourceGroupName)/providers/Microsoft.DesktopVirtualization/hostPools/$(Read-FunctionAppSetting HostPoolName)"
    $scaling = Get-ScalingPlanCurrentTarget -ARMToken $token -HostPoolResourceId $poolId
    $readiness = Test-NewSessionHostsAvailable -ARMToken $token -SessionHosts $hosts `
        -LatestImageVersion ([PSCustomObject]$image) -ScalingPlanTarget $scaling -ReadOnly
    return $readiness.SafeToProceed -and -not $readiness.ValidationUpdatesRequired
}

function Set-ShrRequestedImage {
    param([hashtable] $State, [switch] $BatchCompleted)

    $request = Get-ShrOperation -ImageChange
    if (-not $request -or $request.State.OperationId -ne $State.Id -or
        $request.State.Id -eq $State.LastImageChangeRequestId -or
        $request.State.Id -eq $State.LastImageChangeRejectedId) { return $false }
    $State.PendingImageChangeRequestId = $request.State.Id
    if ($request.State.SchemaVersion -ne 1 -or $request.State.Id -notmatch '^[a-f0-9]{32}$' -or
        $request.State.ExpectedImage.Definition -ine $State.Image.Definition -or
        $request.State.ExpectedImage.Version -ne $State.Image.Version -or
        $request.State.Image.Definition -ine $State.Image.Definition -or
        $request.State.Image.Version -notmatch '^\d+\.\d+\.\d+$' -or
        $State.Image.Definition -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Compute/galleries/[^/]+/images/[^/]+$' -or
        (Read-FunctionAppSetting MaintenanceRequest)) {
        throw 'Image-change request conflicts with the active operation or approved maintenance configuration.'
    }
    if ($State.ExpansionBlocked) { return $false }
    if (-not (Test-ShrImageChangeBoundary -State $State -BatchCompleted:$BatchCompleted)) { return $false }
    $token = Get-AccessToken -ResourceUri (Get-ResourceManagerUri)
    $parameters = Read-FunctionAppSetting SessionHostParameters | ConvertTo-CaseInsensitiveHashtable
    $image = [PSCustomObject]$request.State.Image
    $limit = Get-ImageReplicaDeploymentLimit -ARMToken $token -Image $image -Location $parameters.Location
    if (-not $limit -or $limit -le 0) { throw 'Requested image has no verified deployment capacity.' }
    $uri = "$(Get-ResourceManagerUri)$($image.Definition)/versions/$($image.Version)?api-version=2024-03-03"
    $details = Invoke-AzureRestMethod -ARMToken $token -Method Get -Uri $uri
    if ($details.id -ine "$($image.Definition)/versions/$($image.Version)" -or
        -not $details.properties.publishingProfile.publishedDate) {
        throw 'Requested image lookup did not return the exact version and publication date.'
    }
    if ($details.properties.publishingProfile.excludeFromLatest -and
        -not (Read-FunctionAppSetting IncludeExcludedImageVersions -AsBoolean)) {
        throw 'Requested image is excluded from selection by the current policy.'
    }
    if ((Compare-ImageVersion -Version1 $image.Version -Version2 $State.Image.Version) -le 0 -and
        -not (Read-FunctionAppSetting AllowImageVersionRollback -AsBoolean)) {
        throw 'Requested image does not advance the current version; rollback is not enabled.'
    }
    $date = [DateTimeOffset]$details.properties.publishingProfile.publishedDate
    $minimumAge = Read-FunctionAppSetting ReplaceSessionHostOnNewImageVersionDelayDays
    if (([DateTimeOffset]::UtcNow - $date).TotalDays -lt [double]$minimumAge) { return $false }
    $previous = $State.Image
    $retirementNames = @($State.BatchHostNames)
    if ((Read-FunctionAppSetting ReplacementMode) -eq 'SideBySide') {
        $inventory = @(Get-SessionHosts -ARMToken $token -FixSessionHostTags:$false)
        $retirementNames = @(
            foreach ($name in $State.BatchHostNames) {
                $hosts = @($inventory | Where-Object { $_.SessionHostName -eq $name })
                if ($hosts.Count -gt 1) { throw 'Image change found ambiguous retirement host names.' }
                if ($hosts.Count -eq 1 -and ($hosts[0].ImageDefinition -ine $previous.Definition -or
                    $hosts[0].ImageVersion -ne $previous.Version)) { $name }
            }
        )
    }
    $updates = @{
        RetirementImages = @(@($State.RetirementImages) + @($previous) |
            Where-Object { $_ } | Sort-Object -Property Definition, Version -Unique)
        DeploymentImage = if ($State.DeploymentImage) { $State.DeploymentImage } else { $previous }
        Image = @{ Definition = $image.Definition; Version = $image.Version; Date = $date.ToString('o') }
        LastImageChangeRequestId = $request.State.Id
        LastImageChangeUtc = [DateTimeOffset]::UtcNow.ToString('o')
        AwaitingImageBatch = $true
        DeploymentBatchReady = $true
        MoreDeploymentsAllowed = $true
        NextBatchAuthorization = $null
        NextBatchAuthorized = $false
        BatchHostNames = $retirementNames
        ProgressHighWater = @{}
    }
    $candidate = $State.Clone()
    foreach ($key in $updates.Keys) { $candidate[$key] = $updates[$key] }
    if ([Text.Encoding]::Unicode.GetByteCount(($candidate | ConvertTo-Json -Depth 40 -Compress)) -gt 59000) {
        throw 'Image change would exceed the safe operation-state size budget.'
    }
    foreach ($key in $updates.Keys) { $State[$key] = $updates[$key] }
    Save-ShrContinuationCheckpoint
    Write-LogEntry -Message "CONTINUATION | Image target changed from $($previous.Version) to $($image.Version); existing deployment intent is preserved and a fresh scheduled authorization is required."
    Write-ShrEvent -Event ImageTargetChanged -State $State
    return $true
}

function Invoke-ShrImageChange {
    param([hashtable] $State, [switch] $BatchCompleted)

    $previousRequest = $State.LastImageChangeRequestId
    try {
        return Set-ShrRequestedImage -State $State -BatchCompleted:$BatchCompleted
    } catch {
        $cause = $_.Exception
        while ($cause -and -not $cause.Data['ShrOwnershipConflict']) { $cause = $cause.InnerException }
        if ($State.LastImageChangeRequestId -ne $previousRequest -or
            $cause -or (Test-ShrTransientFailure -ErrorRecord $_)) { throw }
        $State.LastImageChangeRejectedId = $State.PendingImageChangeRequestId
        $State.ImageChangeError = $_.Exception.Message
        Write-LogEntry -Message "CONTINUATION | Image-change request rejected; the original rollout is unchanged: $($_.Exception.Message)" -Level Error
        return $false
    }
}

function Start-ShrContinuation {
    param($Timer)

    $operation = Get-ShrOperation
    Set-ShrLogContext -Operation $(if ($operation -and $operation.State.Status -notin @('Completed', 'Superseded')) { $operation.State } else { $null })
    if ($operation -and $operation.State.Status -eq 'NeedsAttention') {
        $decision = Get-ShrRejectedBatchDecision -Operation $operation
        if (-not $decision.Allowed) {
            throw "SHR operation $($operation.State.Id) requires operator recovery: $($decision.Reason) $($operation.State.LastError)"
        }
        if (-not (Set-ShrRejectedBatchSuperseded -Operation $operation)) { return }
    }
    if ($operation -and $operation.State.Status -notin @('Completed', 'Superseded')) {
        if (((Read-FunctionAppSetting ReplacementMode) -eq 'SideBySide' -or $operation.State.AwaitingImageBatch) -and
            (Read-FunctionAppSetting InitiationEnabled -AsBoolean) -and
            -not $operation.State.ExpansionBlocked -and
            $operation.State.DeploymentBatchReady -and $operation.State.MoreDeploymentsAllowed) {
            # A separate entity lets a timer authorize work without invalidating the worker's ETag.
            $authorization = Get-ShrOperation -BatchAuthorization
            $request = @{
                Id = [guid]::NewGuid().ToString('N')
                OperationId = $operation.State.Id
                AfterBatchNumber = [int]$operation.State.BatchNumber
                ImageVersion = $operation.State.Image.Version
                ImageChangeRequestId = $operation.State.LastImageChangeRequestId
                ExpiresUtc = [DateTimeOffset]::UtcNow.AddMinutes((Get-ShrAuthorizationMinutes)).ToString('o')
            }
            if ($authorization) {
                $authorization.State = $request
                $saved = Save-ShrOperation -Operation $authorization -AllowConflict
            } else {
                $authorization = @{ Key = "$($operation.Key)-initiation"; State = $request; ETag = '' }
                $saved = Save-ShrOperation -Operation $authorization -Insert -AllowConflict
            }
            if ($saved) {
                Write-ShrEvent -Event BatchAuthorized -State $operation.State
                Write-LogEntry -Message "CONTINUATION | Authorized the next SideBySide deployment batch for $($operation.State.Id); old-host retirement continues." -Level Trace
            } else {
                Write-LogEntry -Message 'CONTINUATION | Another timer updated the SideBySide authorization; resuming the active operation.' -Level Warning
            }
        }
        Write-LogEntry -Message "CONTINUATION | Active operation $($operation.State.Id) remains owned by the reconciliation timer." -Level Trace
        return
    }
    Set-ShrLogContext -Operation $null
    if (-not (Read-FunctionAppSetting InitiationEnabled -AsBoolean)) {
        Write-LogEntry -Message 'CONTINUATION | Initiation is held. Active operations continue on the reconciliation timer.'
        return
    }
    $hoursSetting = Read-FunctionAppSetting ContinuationTimeoutHours
    $hours = if ([string]::IsNullOrEmpty($hoursSetting)) { 168 } else { [int]$hoursSetting }
    if ($hours -lt 1 -or $hours -gt 720) { throw 'ContinuationTimeoutHours must be between 1 and 720.' }
    $image = Get-ShrInitiationImage
    if (-not $image) { return }
    if (Test-ShrPoolIdle -LatestImageVersion $image) {
        Write-LogEntry -Message 'CONTINUATION | Host pool is idle; no operation is needed.'
        return
    }
    if (-not $operation) {
        $operation = Get-ShrOperation -EnsureTable
        if ($operation) {
            Write-LogEntry -Message 'CONTINUATION | Another timer initiated an operation during the idle check.' -Level Warning
            return
        }
    }
    $now = [DateTimeOffset]::UtcNow
    $state = @{
        Id = [guid]::NewGuid().ToString('N')
        Status = 'Running'
        CreatedUtc = $now.ToString('o')
        DeadlineUtc = $now.AddHours($hours).ToString('o')
        RecoveryPolicyVersion = 1
        ProgressTimeoutHours = $hours
        LastProgressUtc = $now.ToString('o')
        InitiationExpiresUtc = $now.AddMinutes((Get-ShrAuthorizationMinutes)).ToString('o')
        LockOwner = ''
        LockExpiresUtc = $now.ToString('o')
        Image = $image
        BatchHostNames = $null
        BatchNumber = 0
        DeploymentHostNames = @()
        DeploymentBatchReady = $false
        MoreDeploymentsAllowed = $false
        DeploymentIntent = $null
        CleanupIntent = $null
        LastError = ''
        ConfigurationHash = (Get-ShrConfigurationHash)
        ConfigurationTargetCount = [Environment]::GetEnvironmentVariable('TargetSessionHostCount')
    }
    Get-ShrConfigurationHash -OperationState $state -CaptureTarget | Out-Null
    if ($operation -and $operation.State.Status -eq 'Superseded') {
        $state.SupersedesOperationId = $operation.State.Id
    }
    if ($operation) {
        $operation.State = $state
        $saved = Save-ShrOperation -Operation $operation -AllowConflict
    } else {
        $operation = @{ Key = (Get-ShrOperationKey); State = $state; ETag = '' }
        $saved = Save-ShrOperation -Operation $operation -Insert -AllowConflict
    }
    if (-not $saved) {
        Write-LogEntry -Message 'CONTINUATION | Another invocation initiated or advanced the operation.' -Level Warning
        return
    }
    Write-ShrEvent -Event Initiated -State $state
    Write-LogEntry -Message "CONTINUATION | Initiated operation $($state.Id), deadline $($state.DeadlineUtc)." -Level Trace
}

function Get-ShrWorkerState {
    if ($script:WorkerContext) { return $script:WorkerContext.Operation.State }
}

function Assert-ShrWorkerDeadlines {
    param([DateTimeOffset] $Now)

    $state = $script:WorkerContext.Operation.State
    if ($state.RecoveryPolicyVersion -eq 1) {
        if (-not $state.ScheduleWaitStartedUtc -and $Now -ge [DateTimeOffset]$state.DeadlineUtc) {
            $state.ExpansionBlocked = $true
            $state.LastError = 'No-progress threshold reached; expansion is blocked while checkpointed recovery continues.'
        }
    } elseif ($Now -ge [DateTimeOffset]$state.DeadlineUtc) {
        throw 'SHR operation deadline expired; no further mutations are permitted.'
    }
    if ($Now -ge $script:WorkerContext.InvocationDeadline) {
        $script:WorkerContext.YieldRequested = $true
        throw [TimeoutException]::new('SHR invocation budget reached; continuation will resume from persisted state.')
    }
}

function Assert-ShrWorkerLease {
    if (-not $script:WorkerContext) { return }
    Assert-ShrWorkerDeadlines -Now ([DateTimeOffset]::UtcNow)
    $state = $script:WorkerContext.Operation.State
    $current = Get-ShrOperation
    $now = [DateTimeOffset]::UtcNow
    Assert-ShrWorkerDeadlines -Now $now
    if (-not $current -or $current.State.Id -ne $state.Id -or
        $current.State.LockOwner -ne $state.LockOwner -or
        [DateTimeOffset]$current.State.LockExpiresUtc -le $now) {
        $exception = [InvalidOperationException]::new('SHR operation lease is no longer owned by this invocation.')
        $exception.Data['ShrOwnershipConflict'] = $true
        throw $exception
    }
}

function Save-ShrContinuationCheckpoint {
    if (-not $script:WorkerContext) { throw 'SHR checkpoint requires an active worker.' }
    Assert-ShrWorkerLease
    if ($script:WorkerContext.Operation.State.RecoveryPolicyVersion -eq 1) {
        Update-ShrProgress -State $script:WorkerContext.Operation.State -Result @{} `
            -Before $script:WorkerContext.ProgressFingerprint
        $script:WorkerContext.ProgressFingerprint = Get-ShrProgressFingerprint -State $script:WorkerContext.Operation.State
    }
    Save-ShrOperation -Operation $script:WorkerContext.Operation | Out-Null
    Set-ShrLogContext -Operation $script:WorkerContext.Operation.State
    Write-ShrEvent -Event Checkpoint -State $script:WorkerContext.Operation.State
}

function Request-ShrWorkerYield {
    param([Parameter(Mandatory)][string] $Message)

    if (-not $script:WorkerContext) { throw 'SHR cleanup continuation requires an active worker.' }
    Save-ShrContinuationCheckpoint
    $script:WorkerContext.YieldRequested = $true
    throw [TimeoutException]::new($Message)
}

function Invoke-ShrDeploymentIntent {
    param(
        [string] $ARMToken,
        [string[]] $RegisteredSessionHostNames = @(),
        [ValidateRange(1, [int]::MaxValue)]
        [int] $ImageReplicaDeploymentLimit = [int]::MaxValue
    )

    $state = Get-ShrWorkerState
    $intent = $state.DeploymentIntent
    if (-not $intent) { throw 'SHR deployment replay requires a persisted intent.' }
    Assert-ShrWorkerLease
    try {
        $deployment = Invoke-AzureRestMethod -ARMToken $ARMToken -Method GET -Uri $intent.Uri
    } catch {
        if ([int]$_.Exception.Response.StatusCode -ne 404) { throw }
        $deployment = $null
    }
    if (-not $deployment -or $deployment.properties.provisioningState -in @('Failed', 'Canceled')) {
        $registeredTargets = @($intent.HostNames | Where-Object { $_ -in $RegisteredSessionHostNames })
        if ($registeredTargets.Count -gt 0) {
            $remainingIndexes = @(for ($index = 0; $index -lt $intent.HostNames.Count; $index++) {
                if ($intent.HostNames[$index] -notin $registeredTargets) { $index }
            })
            if ($remainingIndexes.Count -eq 0) {
                throw 'All checkpointed deployment targets are registered, but more deployment was requested. Inspect image and capacity state before recovery.'
            }
            $body = $intent.Body | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            $parameters = $body.properties.parameters
            foreach ($name in @('dedicatedHostResourceIds', 'dedicatedHostGroupResourceIds', 'preferredZones')) {
                if ($parameters.ContainsKey($name)) {
                    $values = $parameters[$name].value
                    if ($values.Count -ne $intent.HostNames.Count) {
                        throw "Cannot safely retry a partial deployment with misaligned per-host parameter '$name'."
                    }
                    $parameters[$name].value = @($remainingIndexes | ForEach-Object { ,$values[$_] })
                }
            }
            $remainingNames = @($remainingIndexes | ForEach-Object { $intent.HostNames[$_] })
            $parameters.sessionHostNames.value = $remainingNames
            $retry = [int]$intent.Retry + 1
            $name = ($intent.Name -replace '_r\d+$', '') + "_r$retry"
            if ($parameters.ContainsKey('Tags')) {
                $parameters.Tags.value['Microsoft.Compute/virtualMachines']['AutoReplaceDeploymentName'] = $name
            }
            $state.DeploymentIntent = @{
                Name = $name
                Uri = $intent.Uri.Replace("/deployments/$($intent.Name)", "/deployments/$name")
                Body = ($body | ConvertTo-Json -Depth 20 -Compress)
                HostNames = $remainingNames
                Timestamp = $intent.Timestamp
                Retry = $retry
            }
            Save-ShrContinuationCheckpoint
            $intent = $state.DeploymentIntent
        }
        if (@($intent.HostNames).Count -gt $ImageReplicaDeploymentLimit) {
            throw "Checkpointed deployment has $(@($intent.HostNames).Count) hosts, exceeding the live image replica ceiling of $ImageReplicaDeploymentLimit. Restore replica capacity before retrying; the saved intent has not been split or submitted."
        }
        if ($ImageReplicaDeploymentLimit -lt [int]::MaxValue) {
            Write-LogEntry -Message "IMAGE_REPLICA_SUBMISSION | ReplicaCeiling: {0} | SubmissionBatch: {1} | Replay: True" `
                -StringValues $ImageReplicaDeploymentLimit, @($intent.HostNames).Count
        }
        Invoke-AzureRestMethod -ARMToken $ARMToken -Method PUT -Uri $intent.Uri -Body $intent.Body | Out-Null
        Write-ShrEvent -Event DeploymentSubmitted -State $state
    } else {
        Write-ShrEvent -Event DeploymentObserved -State $state
    }
    return [PSCustomObject]@{
        DeploymentName = $intent.Name
        SessionHostNames = @($intent.HostNames)
        SessionHostCount = @($intent.HostNames).Count
        Succeeded = $null
        Timestamp = $intent.Timestamp
        ErrorMessage = $null
    }
}

function Invoke-ShrContinuation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $CyclePath, [hashtable] $InvocationResult)

    $operation = Get-ShrOperation
    Set-ShrLogContext -Operation $(if ($operation -and $operation.State.Status -notin @('Completed', 'Superseded')) { $operation.State } else { $null })
    if (-not $operation -or
        $operation.State.Status -in @('Completed', 'Superseded')) {
        if ($null -ne $InvocationResult) { $InvocationResult.Idle = $true }
        return
    }
    if ($null -ne $InvocationResult) { Write-ShrEvent -Category SHR_TIMER -Event Started }
    if ($operation.State.Status -eq 'NeedsAttention') {
        Write-ShrEvent -Event NeedsAttention -State $operation.State
        Write-LogEntry -Message "CONTINUATION | Operation $($operation.State.Id) is stopped: $($operation.State.LastError)" -Level Trace
        return
    }
    if ($operation.State.Status -ne 'Running' -or $operation.State.Id -notmatch '^[a-f0-9]{32}$') {
        throw 'Invalid SHR operation state; reconciliation is blocked.'
    }
    $now = [DateTimeOffset]::UtcNow
    if ($operation.State.LockOwner -and [DateTimeOffset]$operation.State.LockExpiresUtc -gt $now) {
        Write-ShrEvent -Event WaitingForLease -State $operation.State
        Write-LogEntry -Message 'CONTINUATION | Operation is owned by another invocation; work deferred.' -Level Trace
        return
    }
    $operation.State.LockOwner = [guid]::NewGuid().ToString('N')
    $operation.State.LockExpiresUtc = $now.AddMinutes(30).ToString('o')
    if (-not (Save-ShrOperation -Operation $operation -AllowConflict)) {
        Write-LogEntry -Message 'CONTINUATION | Concurrent worker won the operation lease; work deferred.' -Level Trace
        return
    }
    $script:WorkerContext = @{
        Operation = $operation
        InvocationDeadline = $now.AddMinutes(8)
        YieldRequested = $false
    }
    $authorizationExpired = $false
    $ownershipLost = $false
    $before = Get-ShrProgressFingerprint -State $operation.State
    $script:WorkerContext.ProgressFingerprint = $before
    $result = @{ Completed = $false }
    try {
        Write-ShrEvent -Event Reconciling -State $operation.State
        if ($operation.State.RecoveryPolicyVersion -ne 1 -and [DateTimeOffset]$operation.State.DeadlineUtc -le $now) {
            throw 'SHR operation deadline expired. Inspect deployment, host health, sessions and capacity before recovery.'
        }
        if ($operation.State.ConfigurationHash -ne (Get-ShrConfigurationHash -OperationState $operation.State -CaptureTarget)) {
            throw 'SHR operation configuration changed. Restore the initiating configuration or perform operator recovery.'
        }
        Assert-ShrWorkerDeadlines -Now $now
        if ($operation.State.ExpansionBlocked) {
            Write-LogEntry -Message "CONTINUATION | $($operation.State.LastError)" -Level Warning
            Write-ShrEvent -Event ProgressStalled -State $operation.State
            if ($null -eq $operation.State.BatchHostNames -and -not $operation.State.CleanupIntent) { return }
        }
        Invoke-ShrImageChange -State $operation.State | Out-Null
        $operation.State.NextBatchAuthorization = $null
        $operation.State.NextBatchAuthorized = $false
        if (((Read-FunctionAppSetting ReplacementMode) -eq 'SideBySide' -or $operation.State.AwaitingImageBatch) -and
            -not $operation.State.ExpansionBlocked -and
            (Read-FunctionAppSetting InitiationEnabled -AsBoolean) -and
            $operation.State.DeploymentBatchReady -and $operation.State.MoreDeploymentsAllowed) {
            $authorization = Get-ShrOperation -BatchAuthorization
            if ($authorization -and $authorization.State.OperationId -eq $operation.State.Id -and
                [int]$authorization.State.AfterBatchNumber -eq [int]$operation.State.BatchNumber -and
                $authorization.State.Id -ne $operation.State.LastBatchAuthorizationId -and
                (-not $operation.State.LastImageChangeRequestId -or
                    ($authorization.State.ImageVersion -eq $operation.State.Image.Version -and
                        $authorization.State.ImageChangeRequestId -eq $operation.State.LastImageChangeRequestId)) -and
                [DateTimeOffset]$authorization.State.ExpiresUtc -gt [DateTimeOffset]::UtcNow) {
                $operation.State.NextBatchAuthorization = $authorization.State
            }
        }
        if ($null -eq $operation.State.BatchHostNames -and -not $operation.State.CleanupIntent -and
            [DateTimeOffset]$operation.State.InitiationExpiresUtc -le $now) {
            $operation.State.Status = if ($operation.State.ExpansionBlocked) { 'NeedsAttention' } else { 'Completed' }
            $authorizationExpired = $true
            Write-LogEntry -Message "CONTINUATION | Initial authorization for $($operation.State.Id) expired before a batch started; waiting for the next initiation schedule." -Level Warning
            return
        }
        try {
            if ($operation.State.CleanupIntent) {
                $cleanup = $operation.State.CleanupIntent
                $armToken = Get-AccessToken -ResourceUri (Get-ResourceManagerUri)
                foreach ($resourceId in @($cleanup.VMDeletions | Where-Object { $_ })) {
                    Assert-ShrWorkerLease
                    if ($resourceId -notin @($cleanup.Hosts.ResourceId)) {
                        throw 'Retirement VM is not included in the checkpointed cleanup hosts.'
                    }
                    $vmUri = "$(Get-ResourceManagerUri)$resourceId`?api-version=2024-07-01"
                    try {
                        $vm = Invoke-AzureRestMethod -ARMToken $armToken -Method GET -Uri $vmUri
                    } catch {
                        if ([int]$_.Exception.Response.StatusCode -ne 404) { throw }
                        continue
                    }
                    if (-not $vm -or $vm.id -ine $resourceId) {
                        throw 'Retirement VM lookup did not return the checkpointed resource.'
                    }
                    if ($vm.properties.provisioningState -ne 'Deleting') {
                        try {
                            Invoke-AzureRestMethod -ARMToken $armToken -Method DELETE `
                                -Uri "$(Get-ResourceManagerUri)$resourceId`?forceDeletion=true&api-version=2024-07-01" | Out-Null
                        } catch {
                            if ([int]$_.Exception.Response.StatusCode -ne 404) { throw }
                        }
                    }
                }
                Assert-SessionHostNamesAvailable -ARMToken $armToken `
                    -SessionHosts @($cleanup.Hosts | ForEach-Object { [PSCustomObject]$_ }) `
                    -WaitForVMDeletion:([bool]$cleanup.WaitForVMDeletion) `
                    -RemoveEntraDevice ([bool]$cleanup.RemoveEntraDevice) `
                    -RemoveIntuneDevice ([bool]$cleanup.RemoveIntuneDevice)
            }
            # A separate script session keeps the child script from shadowing this module's script scope.
            $invokeCycle = {
                param($Path, $State, $Result)
                & $Path -Timer ([PSCustomObject]@{ IsPastDue = $false }) `
                    -ContinuationContext $State -CycleResult $Result
            }.GetNewClosure()
            if ($null -eq $operation.State.BatchHostNames -and
                [DateTimeOffset]$operation.State.InitiationExpiresUtc -le [DateTimeOffset]::UtcNow) {
                $result.Completed = $true
            } else {
                & $invokeCycle $CyclePath $operation.State $result
            }
        } catch {
            if (-not $script:WorkerContext.YieldRequested) { throw }
            Write-LogEntry -Message $_.Exception.Message -Level Trace
        }
        if ($result.Failure) { throw $result.Failure }
        if ($result.Completed -and (Invoke-ShrImageChange -State $operation.State -BatchCompleted)) {
            $result.Completed = $false
        }
        if ($operation.State.AwaitingImageBatch -and -not $operation.State.NextBatchAuthorized -and
            -not $operation.State.ExpansionBlocked) {
            $result.WaitingForAuthorization = $result.Completed
            $result.Completed = $false
        }
        Update-ShrProgress -State $operation.State -Result $result -Before $script:WorkerContext.ProgressFingerprint
        if ($result.Completed) {
            if ($operation.State.CleanupIntent) { throw 'SHR cannot complete with pending cleanup.' }
            $operation.State.Status = if ($operation.State.ExpansionBlocked) { 'NeedsAttention' } else { 'Completed' }
            if ($operation.State.ExpansionBlocked) {
                Write-LogEntry -Message 'CONTINUATION | Checkpointed recovery finished; expansion remains blocked pending checked operator recovery.' -Level Warning
            } else {
                Write-LogEntry -Message "CONTINUATION | Operation $($operation.State.Id) finished; another batch requires timer authorization." -Level Trace
            }
        } else {
            Write-LogEntry -Message "CONTINUATION | Operation $($operation.State.Id) awaits the next reconciliation tick for deployment, readiness or safe cleanup." -Level Trace
        }
    } catch {
        $failure = $_
        $cause = $_.Exception
        while ($cause -and -not $cause.Data['ShrOwnershipConflict']) { $cause = $cause.InnerException }
        $ownershipLost = $null -ne $cause
        $transient = Test-ShrTransientFailure -ErrorRecord $failure
        if ($ownershipLost) {
            Write-LogEntry -Message 'CONTINUATION | Ownership changed; this worker will not overwrite saved state. A later owner will reconcile.' -Level Warning
        } elseif ($transient) {
            $operation.State.Status = 'Running'
            Write-LogEntry -Message "CONTINUATION | Temporary request failure; saved intent will be reconciled on the next timer: $($failure.Exception.Message)" -Level Warning
        } else {
            $operation.State.Status = 'NeedsAttention'
        }
        $operation.State.LastError = $failure.Exception.Message
        if (-not $ownershipLost -and -not $transient) {
            Write-LogEntry -Message "CONTINUATION | Operation $($operation.State.Id) stopped: $($failure.Exception.Message)" -Level Error
        }
        throw
    } finally {
        try {
            if (-not $ownershipLost) {
                $operation.State.LockOwner = ''
                $operation.State.LockExpiresUtc = [DateTimeOffset]::UtcNow.ToString('o')
                Save-ShrOperation -Operation $operation | Out-Null
                Write-ShrEvent -Event $(if ($operation.State.Status -eq 'Running') { 'Waiting' } elseif ($operation.State.Status -eq 'Completed' -and $authorizationExpired) { 'AuthorizationExpired' } else { $operation.State.Status }) -State $operation.State
            }
        } finally {
            $script:WorkerContext = $null
        }
    }
}

Export-ModuleMember -Function Invoke-ShrTimer, Start-ShrContinuation, Invoke-ShrContinuation, Get-ShrWorkerState, Assert-ShrWorkerLease, Save-ShrContinuationCheckpoint, Request-ShrWorkerYield, Invoke-ShrDeploymentIntent
