$script:WorkerContext = $null

function Invoke-ShrStorageRequest {
    [CmdletBinding()]
    param(
        [ValidateSet('Table', 'Queue')] [string] $Service,
        [string] $Path,
        [string] $Method = 'GET',
        [string] $Body,
        [string] $ETag,
        [int[]] $ExpectedStatus = @()
    )

    $endpoint = if ($Service -eq 'Table') {
        $env:AzureWebJobsStorage__tableServiceUri
    } else {
        $env:AzureWebJobsStorage__queueServiceUri
    }
    if ([string]::IsNullOrWhiteSpace($endpoint)) {
        throw "SHR continuation requires the $Service service URI in AzureWebJobsStorage."
    }
    $token = Get-AccessToken -ResourceUri $endpoint.TrimEnd('/') -ClientId (Read-FunctionAppSetting UserAssignedIdentityClientId)
    $headers = @{
        Authorization = "Bearer $token"
        'x-ms-version' = '2019-02-02'
        'x-ms-date' = [DateTime]::UtcNow.ToString('R')
        Accept = $(if ($Service -eq 'Table') { 'application/json;odata=nometadata' } else { 'application/xml' })
    }
    if ($ETag) { $headers['If-Match'] = $ETag }
    $parameters = @{
        Uri = "$($endpoint.TrimEnd('/'))/$Path"
        Method = $Method
        Headers = $headers
        ContentType = $(if ($Service -eq 'Table') { 'application/json' } else { 'application/xml' })
        ErrorAction = 'Stop'
        TimeoutSec = 60
        SkipHttpErrorCheck = $true
    }
    if ($PSBoundParameters.ContainsKey('Body')) { $parameters.Body = $Body }
    $response = Invoke-WebRequest @parameters
    $status = [int]$response.StatusCode
    if (($status -lt 200 -or $status -ge 300) -and $status -notin $ExpectedStatus) {
        throw "SHR $Service $Method request to '$Path' failed with HTTP $status. $($response.Content)"
    }
    return $response
}

function Get-ShrOperationKey {
    $parts = @((Read-FunctionAppSetting HostPoolSubscriptionId),
        (Read-FunctionAppSetting HostPoolResourceGroupName), (Read-FunctionAppSetting HostPoolName))
    if (@($parts | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        throw 'SHR continuation requires a complete host pool identity.'
    }
    $identity = $parts -join '/'
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($identity.ToLowerInvariant())
    )).ToLowerInvariant()
}

function Get-ShrConfigurationHash {
    $settings = [ordered]@{}
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
        $settings[$key] = [Environment]::GetEnvironmentVariable($key)
    }
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes(($settings | ConvertTo-Json -Compress))
    )).ToLowerInvariant()
}

function Get-ShrOperation {
    param([switch] $EnsureTable, [switch] $BatchAuthorization)

    if ($EnsureTable) {
        Invoke-ShrStorageRequest -Service Table -Path Tables -Method POST `
            -Body '{"TableName":"shrContinuation"}' -ExpectedStatus 409 | Out-Null
    }
    $key = Get-ShrOperationKey
    if ($BatchAuthorization) { $key += '-initiation' }
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
        throw 'SHR operation ownership changed; refusing to overwrite newer state.'
    }
    $Operation.ETag = [string](@($response.Headers['ETag'])[0])
    if (-not $Operation.ETag) { throw 'SHR operation save returned no ETag.' }
    return $true
}

function Send-ShrWorkItem {
    param([string] $OperationId, [ValidateRange(0, 604800)] [int] $DelaySeconds = 0,
        [ValidateRange(0, 2147483647)] [int] $Generation = 0)

    Invoke-ShrStorageRequest -Service Queue -Path 'shr-continuation' -Method PUT `
        -ExpectedStatus 409 | Out-Null
    $json = @{ SchemaVersion = 1; OperationId = $OperationId; Generation = $Generation } | ConvertTo-Json -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    Invoke-ShrStorageRequest -Service Queue `
        -Path "shr-continuation/messages?visibilitytimeout=$DelaySeconds&messagettl=604800" `
        -Method POST -Body "<QueueMessage><MessageText>$encoded</MessageText></QueueMessage>" | Out-Null
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

function Start-ShrContinuation {
    param($Timer)

    if (-not (Read-FunctionAppSetting EnableQueueContinuation -AsBoolean)) {
        throw 'The continuation scheduler requires EnableQueueContinuation.'
    }
    $operation = Get-ShrOperation -EnsureTable
    if ($operation -and $operation.State.Status -ne 'Completed') {
        if ($operation.State.Status -eq 'NeedsAttention') {
            throw "SHR operation $($operation.State.Id) requires operator recovery: $($operation.State.LastError)"
        }
        if ((Read-FunctionAppSetting ReplacementMode) -eq 'SideBySide' -and
            (Read-FunctionAppSetting InitiationEnabled -AsBoolean) -and
            $operation.State.DeploymentBatchReady -and $operation.State.MoreDeploymentsAllowed) {
            # A separate entity lets a timer authorize work without invalidating the worker's ETag.
            $authorization = Get-ShrOperation -BatchAuthorization
            $request = @{
                Id = [guid]::NewGuid().ToString('N')
                OperationId = $operation.State.Id
                AfterBatchNumber = [int]$operation.State.BatchNumber
                ExpiresUtc = [DateTimeOffset]::UtcNow.AddMinutes(5).ToString('o')
            }
            if ($authorization) {
                $authorization.State = $request
                $saved = Save-ShrOperation -Operation $authorization -AllowConflict
            } else {
                $authorization = @{ Key = "$($operation.Key)-initiation"; State = $request; ETag = '' }
                $saved = Save-ShrOperation -Operation $authorization -Insert -AllowConflict
            }
            if ($saved) {
                Write-LogEntry -Message "CONTINUATION | Authorized the next SideBySide deployment batch for $($operation.State.Id); old-host retirement continues."
            } else {
                Write-LogEntry -Message 'CONTINUATION | Another timer updated the SideBySide authorization; resuming the active operation.' -Level Warning
            }
        }
        Send-ShrWorkItem -OperationId $operation.State.Id -Generation $operation.State.Generation
        Write-LogEntry -Message "CONTINUATION | Rescheduled active operation $($operation.State.Id)."
        return
    }
    if (-not (Read-FunctionAppSetting InitiationEnabled -AsBoolean)) {
        Write-LogEntry -Message 'CONTINUATION | Initiation is held. Active queue operations are not stopped.'
        return
    }
    $hoursSetting = Read-FunctionAppSetting ContinuationTimeoutHours
    $hours = if ([string]::IsNullOrEmpty($hoursSetting)) { 72 } else { [int]$hoursSetting }
    if ($hours -lt 1 -or $hours -gt 720) { throw 'ContinuationTimeoutHours must be between 1 and 720.' }
    $image = Get-ShrInitiationImage
    if (-not $image) { return }
    $now = [DateTimeOffset]::UtcNow
    $state = @{
        Id = [guid]::NewGuid().ToString('N')
        Status = 'Running'
        CreatedUtc = $now.ToString('o')
        DeadlineUtc = $now.AddHours($hours).ToString('o')
        InitiationExpiresUtc = $now.AddMinutes(5).ToString('o')
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
        Generation = 0
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
    Send-ShrWorkItem -OperationId $state.Id
    Write-LogEntry -Message "CONTINUATION | Initiated operation $($state.Id), deadline $($state.DeadlineUtc)."
}

function Get-ShrWorkerState {
    if ($script:WorkerContext) { return $script:WorkerContext.Operation.State }
}

function Assert-ShrWorkerLease {
    if (-not $script:WorkerContext) { return }
    $now = [DateTimeOffset]::UtcNow
    $state = $script:WorkerContext.Operation.State
    if ($now -ge [DateTimeOffset]$state.DeadlineUtc) {
        throw 'SHR operation deadline expired; no further mutations are permitted.'
    }
    if ($now -ge $script:WorkerContext.InvocationDeadline) {
        $script:WorkerContext.YieldRequested = $true
        throw [TimeoutException]::new('SHR invocation budget reached; continuation will resume from persisted state.')
    }
    $current = Get-ShrOperation
    if (-not $current -or $current.State.Id -ne $state.Id -or
        $current.State.LockOwner -ne $state.LockOwner -or
        [DateTimeOffset]$current.State.LockExpiresUtc -le $now) {
        throw 'SHR operation lease is no longer owned by this invocation.'
    }
}

function Save-ShrContinuationCheckpoint {
    if (-not $script:WorkerContext) { throw 'SHR checkpoint requires an active worker.' }
    Assert-ShrWorkerLease
    Save-ShrOperation -Operation $script:WorkerContext.Operation | Out-Null
}

function Request-ShrWorkerYield {
    param([Parameter(Mandatory)][string] $Message)

    if (-not $script:WorkerContext) { throw 'SHR cleanup continuation requires an active worker.' }
    Save-ShrContinuationCheckpoint
    $script:WorkerContext.YieldRequested = $true
    throw [TimeoutException]::new($Message)
}

function Invoke-ShrDeploymentIntent {
    param([string] $ARMToken, [string[]] $RegisteredSessionHostNames = @())

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
        Invoke-AzureRestMethod -ARMToken $ARMToken -Method PUT -Uri $intent.Uri -Body $intent.Body | Out-Null
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
    param($WorkItem, [string] $CyclePath)

    if (-not (Read-FunctionAppSetting EnableQueueContinuation -AsBoolean)) {
        throw 'Queue continuation is disabled; do not process pending work.'
    }
    $message = if ($WorkItem -is [string]) {
        $WorkItem | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    } else { $WorkItem }
    $generation = 0L
    if ($message.SchemaVersion -ne 1 -or [string]$message.OperationId -notmatch '^[a-f0-9]{32}$' -or
        -not [long]::TryParse([string]$message.Generation, [ref]$generation) -or
        $generation -lt 0 -or $generation -gt [int]::MaxValue) {
        throw 'Invalid SHR continuation message.'
    }
    $operation = Get-ShrOperation
    if (-not $operation -or $operation.State.Id -ne $message.OperationId -or
        $operation.State.Status -eq 'Completed') {
        Write-LogEntry -Message "CONTINUATION | Discarded obsolete work item $($message.OperationId)." -Level Trace
        return
    }
    if ($operation.State.Status -eq 'NeedsAttention') {
        Write-LogEntry -Message "CONTINUATION | Operation $($message.OperationId) is stopped: $($operation.State.LastError)" -Level Error
        return
    }
    if ($generation -lt $operation.State.Generation) {
        Write-LogEntry -Message "CONTINUATION | Discarded an already processed generation for $($message.OperationId)." -Level Trace
        return
    }
    if ($generation -gt $operation.State.Generation) {
        Send-ShrWorkItem -OperationId $operation.State.Id -Generation $generation -DelaySeconds 120
        Write-LogEntry -Message 'CONTINUATION | Waiting for the preceding generation checkpoint.' -Level Trace
        return
    }
    $now = [DateTimeOffset]::UtcNow
    if ($operation.State.LockOwner -and [DateTimeOffset]$operation.State.LockExpiresUtc -gt $now) {
        Send-ShrWorkItem -OperationId $operation.State.Id -Generation $generation -DelaySeconds 120
        Write-LogEntry -Message 'CONTINUATION | Operation is owned by another invocation; work deferred.' -Level Trace
        return
    }
    $operation.State.LockOwner = [guid]::NewGuid().ToString('N')
    $operation.State.LockExpiresUtc = $now.AddMinutes(30).ToString('o')
    if (-not (Save-ShrOperation -Operation $operation -AllowConflict)) {
        Send-ShrWorkItem -OperationId $message.OperationId -Generation $generation -DelaySeconds 120
        Write-LogEntry -Message 'CONTINUATION | Concurrent worker won the operation lease; work deferred.' -Level Trace
        return
    }
    $script:WorkerContext = @{
        Operation = $operation
        InvocationDeadline = $now.AddMinutes(8)
        YieldRequested = $false
    }
    try {
        if ([DateTimeOffset]$operation.State.DeadlineUtc -le $now) {
            throw 'SHR operation deadline expired. Inspect deployment, host health, sessions and capacity before recovery.'
        }
        if ($operation.State.ConfigurationHash -ne (Get-ShrConfigurationHash)) {
            throw 'SHR operation configuration changed. Restore the initiating configuration or perform operator recovery.'
        }
        $operation.State.NextBatchAuthorization = $null
        $operation.State.NextBatchAuthorized = $false
        if ((Read-FunctionAppSetting ReplacementMode) -eq 'SideBySide' -and
            (Read-FunctionAppSetting InitiationEnabled -AsBoolean) -and
            $operation.State.DeploymentBatchReady -and $operation.State.MoreDeploymentsAllowed) {
            $authorization = Get-ShrOperation -BatchAuthorization
            if ($authorization -and $authorization.State.OperationId -eq $operation.State.Id -and
                [int]$authorization.State.AfterBatchNumber -eq [int]$operation.State.BatchNumber -and
                $authorization.State.Id -ne $operation.State.LastBatchAuthorizationId -and
                [DateTimeOffset]$authorization.State.ExpiresUtc -gt [DateTimeOffset]::UtcNow) {
                $operation.State.NextBatchAuthorization = $authorization.State
            }
        }
        if ($null -eq $operation.State.BatchHostNames -and -not $operation.State.CleanupIntent -and
            [DateTimeOffset]$operation.State.InitiationExpiresUtc -le $now) {
            $operation.State.Status = 'Completed'
            Write-LogEntry -Message "CONTINUATION | Initial authorization for $($operation.State.Id) expired before a batch started; waiting for the next initiation schedule." -Level Warning
            return
        }
        # A durable watchdog precedes every side effect, including deployment submission.
        Send-ShrWorkItem -OperationId $operation.State.Id -Generation $generation -DelaySeconds 600
        $result = @{ Completed = $false }
        try {
            if ($operation.State.CleanupIntent) {
                $cleanup = $operation.State.CleanupIntent
                $armToken = Get-AccessToken -ResourceUri (Get-ResourceManagerUri)
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
            if (-not $script:WorkerContext.YieldRequested -and $_.Exception -isnot [TimeoutException]) { throw }
            Write-LogEntry -Message $_.Exception.Message -Level Warning
        }
        if ($result.Failure) { throw $result.Failure }
        if ($result.Completed) {
            if ($operation.State.CleanupIntent) { throw 'SHR cannot complete with pending cleanup.' }
            $operation.State.Status = 'Completed'
            Write-LogEntry -Message "CONTINUATION | Operation $($operation.State.Id) finished; another batch requires timer authorization."
        } else {
            Send-ShrWorkItem -OperationId $operation.State.Id -Generation ($generation + 1) -DelaySeconds 120
            $operation.State.Generation = [int]$generation + 1
            Write-LogEntry -Message "CONTINUATION | Operation $($operation.State.Id) is waiting for deployment, readiness or safe cleanup."
        }
    } catch {
        $operation.State.Status = 'NeedsAttention'
        $operation.State.LastError = $_.Exception.Message
        Write-LogEntry -Message "CONTINUATION | Operation $($operation.State.Id) stopped: $($_.Exception.Message)" -Level Error
        throw
    } finally {
        try {
            $operation.State.LockOwner = ''
            $operation.State.LockExpiresUtc = [DateTimeOffset]::UtcNow.ToString('o')
            Save-ShrOperation -Operation $operation | Out-Null
        } finally {
            $script:WorkerContext = $null
        }
    }
}

Export-ModuleMember -Function Start-ShrContinuation, Invoke-ShrContinuation, Get-ShrWorkerState, Assert-ShrWorkerLease, Save-ShrContinuationCheckpoint, Request-ShrWorkerYield, Invoke-ShrDeploymentIntent
