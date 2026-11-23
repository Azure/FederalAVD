<#
.SYNOPSIS
    Restores retained hosts, pins this pool to their image, and resumes SHR.
.DESCRIPTION
    Preflights the entire plan, asks for one confirmation, stops SHR, starts retained VMs
    with bounded concurrency, validates AVD health, drains and excludes the bad generation,
    pins this pool to the restored image, and restarts SHR. No VMs or sessions are deleted.
    Incomplete deletion/recovery work blocks automatic resume; -RestoreOnly provides
    emergency host restoration while leaving SHR stopped.
.PARAMETER ImageVersion
    Selects a retained numeric gallery version when more than one generation is available.
.PARAMETER ResumeLatest
    Removes this command's pool-local pin and resumes gallery-definition selection.
    Refuses to select a known bad version recorded by the rollback.
.PARAMETER RestoreOnly
    Starts retained hosts and enables sessions, but leaves them opted out and SHR stopped.
    Does not pin the image, drain other hosts, or modify durable operation state.
.PARAMETER StopFunctionApp
    Retained for compatibility. The command now stops SHR automatically after confirmation.
.PARAMETER PassThru
    Returns one operation summary with RestoredHosts, DrainedHosts, Image, and FunctionAppState.
.EXAMPLE
    .\Invoke-SessionHostRollback.ps1 -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations
.EXAMPLE
    .\Invoke-SessionHostRollback.ps1 -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -WhatIf
.EXAMPLE
    .\Invoke-SessionHostRollback.ps1 -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -ResumeLatest
.NOTES
    Requires Az.Accounts sign-in, Function App config/stop/start, VM start/tag and AVD update
    permissions. Guided rollback and ResumeLatest also require Storage Table Data Contributor
    and private-network access to SHR's Table endpoint. On failure SHR is left stopped;
    rerun the same command after resolving the reported problem. No live changes occur with WhatIf.
#>
#Requires -Version 7.4
#Requires -Modules Az.Accounts

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Restore')]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$FunctionAppName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$FunctionAppResourceGroupName,
    [string]$FunctionAppSubscriptionId,
    [Parameter(ParameterSetName = 'Restore')][string[]]$SessionHostName,
    [Parameter(ParameterSetName = 'Restore')][ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')][string]$ImageVersion,
    [Parameter(ParameterSetName = 'Restore')][switch]$RestoreOnly,
    [Parameter(Mandatory, ParameterSetName = 'ResumeLatest')][switch]$ResumeLatest,
    [switch]$StopFunctionApp,
    [ValidateRange(1, 120)][int]$HealthTimeoutMinutes = 20,
    [ValidateRange(5, 300)][int]$PollIntervalSeconds = 15,
    [ValidateRange(1, 100)][int]$StartBatchSize = 10,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
$webApiVersion = '2024-11-01'
$computeApiVersion = '2024-07-01'
$desktopVirtualizationApiVersion = '2024-04-03'
$tagsApiVersion = '2021-04-01'
$pinSetting = 'ShutdownRetentionRollback'
$context = Get-AzContext
if (-not $context -or -not $context.Subscription) { throw 'Sign in using Connect-AzAccount first.' }
if (-not $FunctionAppSubscriptionId) { $FunctionAppSubscriptionId = $context.Subscription.Id }
$environment = Get-AzEnvironment -Name $context.Environment.Name
$armRoot = $environment.ResourceManagerUrl.TrimEnd('/')
$functionAppResourceId = "/subscriptions/$FunctionAppSubscriptionId/resourceGroups/$FunctionAppResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName"
$baseCommand = "& '$($PSCommandPath.Replace("'", "''"))' -FunctionAppName '$($FunctionAppName.Replace("'", "''"))' -FunctionAppResourceGroupName '$($FunctionAppResourceGroupName.Replace("'", "''"))' -FunctionAppSubscriptionId '$($FunctionAppSubscriptionId.Replace("'", "''"))'"
$retryCommand = $baseCommand
if ($SessionHostName) { $retryCommand += ' -SessionHostName ' + (($SessionHostName | ForEach-Object { "'$($_.Replace("'", "''"))'" }) -join ',') }

function Invoke-ArmRequest {
    param([ValidateSet('GET', 'POST', 'PATCH', 'PUT')][string]$Method, [string]$Path, [object]$Body)
    $request = @{ Method = $Method; Path = $Path; DefaultProfile = $context }
    if ($null -ne $Body) { $request.Payload = $Body | ConvertTo-Json -Depth 40 -Compress }
    $response = Invoke-AzRestMethod @request
    if ([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300) {
        throw "ARM $Method '$Path' failed with HTTP $($response.StatusCode)."
    }
    if ($response.Content) { return $response.Content | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    if ($Method -eq 'GET') { throw "ARM GET '$Path' returned no content." }
}

function Get-ArmCollection {
    param([string]$Path)
    do {
        $page = Invoke-ArmRequest -Method GET -Path $Path
        if (-not $page.Contains('value') -or $page.value -isnot [array]) { throw "Invalid collection response for '$Path'." }
        $page.value
        $Path = $page.nextLink
        if ($Path) {
            if (-not $Path.StartsWith("$armRoot/", [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected ARM pagination endpoint.' }
            $Path = $Path.Substring($armRoot.Length)
        }
    } while ($Path)
}

function Get-Settings {
    $values = (Invoke-ArmRequest -Method POST -Path "$functionAppResourceId/config/appsettings/list?api-version=$webApiVersion").properties
    if ($values -isnot [System.Collections.IDictionary]) { throw 'Function App settings are missing.' }
    return $values
}

function Assert-UnchangedSettings {
    param([hashtable]$Expected, [hashtable]$Actual, [string]$Description = 'App settings')
    if ($Expected.Count -ne $Actual.Count) { throw "$Description changed; run a new preview." }
    foreach ($key in $Expected.Keys) {
        if (-not $Actual.ContainsKey($key) -or $Expected[$key] -cne $Actual[$key]) { throw "$Description changed; run a new preview." }
    }
}

function Get-SettingValue {
    param([string]$Name, [string]$Default)
    if (-not [string]::IsNullOrWhiteSpace($settings[$Name])) { return [string]$settings[$Name] }
    if ($PSBoundParameters.ContainsKey('Default')) { return $Default }
    throw "Required Function App setting '$Name' is missing."
}

function Get-FunctionApp {
    Invoke-ArmRequest -Method GET -Path "${functionAppResourceId}?api-version=$webApiVersion"
}

function Assert-FunctionAppStopped {
    if ((Get-FunctionApp).properties.state -ne 'Stopped') { throw 'SHR was restarted during rollback. Stop it and rerun the command.' }
}

function Wait-FunctionAppState {
    param([string]$State)
    $deadline = [DateTimeOffset]::UtcNow.AddMinutes(5)
    do {
        if ((Get-FunctionApp).properties.state -eq $State) { return }
        if ([DateTimeOffset]::UtcNow -ge $deadline) { throw "Function App did not reach '$State' within five minutes." }
        Start-Sleep -Seconds $PollIntervalSeconds
    } while ($true)
}

function Get-VMImage {
    param([hashtable]$VM)
    $reference = $VM.properties.storageProfile.imageReference
    $id = [string]$reference.id
    if ($id -match '^(?<definition>/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Compute/galleries/[^/]+/images/[^/]+)(?:/versions/(?<version>[^/]+))?$') {
        $definition = $Matches.definition
        $version = $Matches.version
        if (-not $version -or $version -eq 'latest') { $version = $reference.exactVersion }
        if ($version -match '^[0-9]+\.[0-9]+\.[0-9]+$') { return "$definition/versions/$version" }
    }
    throw "Cannot establish the actual Compute Gallery image for VM '$($VM.name)'."
}

function Test-ManagedVM {
    param([hashtable]$VM)
    $value = if ($VM.tags) { $VM.tags[$includeTag] }
    if ($null -eq $value) { return [bool]::Parse((Get-SettingValue IncludePreExistingSessionHosts -Default 'false')) }
    if ($value -notin @('true', 'false')) { throw "VM '$($VM.name)' has an invalid automation opt-in tag." }
    return $value -eq 'true'
}

function Set-VMTags {
    param([hashtable]$VM, [string]$Operation, [hashtable]$Tags)
    if ($Tags.Count -eq 0) { return }
    Invoke-ArmRequest -Method PATCH -Path "$($VM.id)/providers/Microsoft.Resources/tags/default?api-version=$tagsApiVersion" `
        -Body @{ operation = $Operation; properties = @{ tags = $Tags } } | Out-Null
}

function Set-SessionAcceptance {
    param([hashtable]$HostEntry, [bool]$Enabled)
    Invoke-ArmRequest -Method PATCH -Path "$($HostEntry.id)?api-version=$desktopVirtualizationApiVersion" `
        -Body @{ properties = @{ allowNewSession = $Enabled } } | Out-Null
}

function Invoke-RollbackTable {
    param([string]$Path, [string]$Method = 'GET', [hashtable]$Body, [string]$ETag, [switch]$AllowMissing)
    $token = (Get-AzAccessToken -ResourceUrl $tableEndpoint -DefaultProfile $context).Token
    if ($token -is [securestring]) { $token = [Net.NetworkCredential]::new('', $token).Password }
    if ([string]::IsNullOrWhiteSpace($token)) { throw 'No Storage access token was returned.' }
    $headers = @{
        Authorization = "Bearer $token"; Accept = 'application/json;odata=nometadata'
        'x-ms-version' = '2019-02-02'; 'x-ms-date' = [DateTime]::UtcNow.ToString('R')
    }
    if ($ETag) { $headers['If-Match'] = $ETag }
    $request = @{
        Uri = "$tableEndpoint/$Path"; Method = $Method; Headers = $headers
        ContentType = 'application/json'; SkipHttpErrorCheck = $true
        TimeoutSec = 60; MaximumRedirection = 0
    }
    if ($Body) { $request.Body = $Body | ConvertTo-Json -Depth 50 -Compress }
    $response = Invoke-WebRequest @request
    if ($AllowMissing -and [int]$response.StatusCode -eq 404) { return $null }
    if ([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300) {
        throw "Table $Method '$Path' failed with HTTP $($response.StatusCode). Check Table RBAC, network access, and concurrent updates."
    }
    if ($Method -ne 'GET') { return }
    $etagValue = [string](@($response.Headers['ETag'])[0])
    if (-not $etagValue -or $etagValue -eq '*') { throw 'Table record has no usable ETag.' }
    return @{ Entity = ($response.Content | ConvertFrom-Json -AsHashtable -ErrorAction Stop); ETag = $etagValue }
}

function Get-RecoverySnapshot {
    $operation = Invoke-RollbackTable -Path $operationPath -AllowMissing
    $deployment = Invoke-RollbackTable -Path $deploymentPath -AllowMissing
    $state = if ($operation) { $operation.Entity.State | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    if ($operation -and ($state -isnot [System.Collections.IDictionary] -or
        $state.Status -notin @('Running', 'NeedsAttention', 'Completed', 'Superseded') -or
        $state.Id -notmatch '^[a-f0-9]{32}$')) { throw 'Invalid SHR operation identity or status.' }
    if ($state.CleanupIntent) { throw "An unfinished directory/VM cleanup blocks automatic resume. Use $retryCommand -RestoreOnly for emergency restoration with SHR stopped." }
    if ($deployment) {
        $record = $deployment.Entity
        $mappings = if ($record.PendingHostMappings) { $record.PendingHostMappings | ConvertFrom-Json -AsHashtable -ErrorAction Stop } else { @{} }
        if ($mappings -isnot [System.Collections.IDictionary] -or $mappings.Count -gt 0 -or $record.ActiveMaintenanceRequestId) {
            throw "Pending recovery or maintenance blocks automatic resume. Use $retryCommand -RestoreOnly for emergency restoration with SHR stopped."
        }
    }
    if ($state -and $state.Status -notin @('Completed', 'Superseded')) {
        $checkpointedNames = @(@($state.DeploymentHostNames) + @($state.DeploymentIntent.HostNames) | Where-Object { $_ } | Sort-Object -Unique)
        foreach ($name in $checkpointedNames) {
            if (-not $poolVMsByName.ContainsKey($name) -or $poolVMsByName[$name].properties.provisioningState -ne 'Succeeded') {
                throw "Checkpointed replacement '$name' is not fully provisioned and registered. Automatic resume is blocked; use -RestoreOnly to restore service first."
            }
        }
        if ($state.DeploymentIntent -and @($state.DeploymentHostNames | Where-Object { $_ }).Count -eq 0) {
            throw 'An unresolved deployment intent blocks automatic resume; use -RestoreOnly to restore service first.'
        }
    }
    $snapshot = @{ Operation = $operation; Deployment = $deployment; State = $state }
    if ($operation -or $deployment) {
        $snapshot.ArchiveJson = @{
            Id = $state.Id; Status = 'Superseded'; Reason = 'Operator shutdown-retention rollback'
            PreviousState = $state; DeploymentRecoveryRecord = $deployment.Entity
        } | ConvertTo-Json -Depth 45 -Compress
        if ([Text.Encoding]::Unicode.GetByteCount($snapshot.ArchiveJson) -gt 60000) { throw 'SHR operation is too large to archive safely.' }
    }
    return $snapshot
}

function Complete-PreviousOperation {
    param([hashtable]$Snapshot)
    Assert-FunctionAppStopped
    if ($Snapshot.Operation -or $Snapshot.Deployment) {
        $archiveKey = "$operationKey-rollback-$([guid]::NewGuid().ToString('N'))"
        Invoke-RollbackTable -Path shrContinuation -Method POST -Body @{
            PartitionKey = 'SHR'; RowKey = $archiveKey; State = $Snapshot.ArchiveJson
        }
        if ($Snapshot.Operation -and $Snapshot.State.Status -notin @('Completed', 'Superseded')) {
            $Snapshot.State.Status = 'Superseded'
            $Snapshot.State.RollbackArchiveKey = $archiveKey
            $Snapshot.State.RollbackImage = $selectedImage
            $supersededJson = $Snapshot.State | ConvertTo-Json -Depth 40 -Compress
            Invoke-RollbackTable -Path $operationPath -Method MERGE -ETag $Snapshot.Operation.ETag -Body @{ State = $supersededJson }
            $verified = Invoke-RollbackTable -Path $operationPath
            if ($verified.Entity.State -cne $supersededJson) { throw 'Could not verify superseded SHR operation.' }
        }
    }
    if ($Snapshot.Deployment) {
        # Preserve name reservations/history; clear only the completed cycle's capacity baseline.
        Invoke-RollbackTable -Path $deploymentPath -Method MERGE -ETag $Snapshot.Deployment.ETag -Body @{
            LastDeploymentName = ''; TargetSessionHostCount = 0; LastTotalToReplace = 0
            LastStatus = 'RollbackRestored'; LastTimestamp = [DateTimeOffset]::UtcNow.ToString('o')
        }
    }
}

function Wait-RestoredHosts {
    param([hashtable[]]$VMs)
    $pending = @($VMs)
    $deadline = [DateTimeOffset]::UtcNow.AddMinutes($HealthTimeoutMinutes)
    while ($pending.Count -gt 0) {
        $notReady = @()
        foreach ($vm in $pending) {
            $hostEntry = Invoke-ArmRequest -Method GET -Path "$($hostsByVMId[$vm.id].id)?api-version=$desktopVirtualizationApiVersion"
            $failed = @($hostEntry.properties.healthCheckResults | Where-Object { $_.healthCheckResult -eq 'HealthCheckFailed' })
            if ($hostEntry.properties.status -ne 'Available' -or $failed.Count -gt 0) { $notReady += $vm }
        }
        $pending = $notReady
        Write-Progress -Activity 'Restoring session hosts' -Status "$($VMs.Count - $pending.Count)/$($VMs.Count) healthy" `
            -PercentComplete (100 * ($VMs.Count - $pending.Count) / $VMs.Count)
        if ($pending.Count -eq 0) { break }
        if ([DateTimeOffset]::UtcNow -ge $deadline) { throw "Hosts did not become healthy: $($pending.name -join ', '). Retention tags and drain mode were preserved." }
        Start-Sleep -Seconds $PollIntervalSeconds
    }
    Write-Progress -Activity 'Restoring session hosts' -Completed
}

$functionApp = Get-FunctionApp
if ($functionApp.type -ne 'Microsoft.Web/sites' -or $functionApp.kind -notmatch 'functionapp') { throw 'The selected resource is not a Function App.' }
$settings = Get-Settings
if ((Get-SettingValue ReplacementMode) -notin @('SideBySide', 'DeleteFirst')) { throw 'Unrecognized SHR replacement mode.' }
if (-not $ResumeLatest -and ((Get-SettingValue ReplacementMode) -ne 'SideBySide' -or
    -not [bool]::Parse((Get-SettingValue EnableShutdownRetention -Default 'false')))) {
    throw 'Rollback requires SideBySide mode with shutdown retention enabled.'
}
$includeTag = Get-SettingValue Tag_IncludeInAutomation
$shutdownTag = Get-SettingValue Tag_ShutdownTimestamp
$scalingTag = Get-SettingValue Tag_ScalingPlanExclusionTag -Default ''
$drainTag = Get-SettingValue Tag_PendingDrainTimestamp
$tagNames = @($includeTag, $shutdownTag, $drainTag, $scalingTag | Where-Object { $_ })
if (@($tagNames | Sort-Object -Unique).Count -ne $tagNames.Count) { throw 'Automation, retention, drain and scaling tag names must be distinct.' }
$vmRoot = "/subscriptions/$(Get-SettingValue VirtualMachinesSubscriptionId)/resourceGroups/$(Get-SettingValue VirtualMachinesResourceGroupName)"
$poolRoot = "/subscriptions/$(Get-SettingValue HostPoolSubscriptionId)/resourceGroups/$(Get-SettingValue HostPoolResourceGroupName)/providers/Microsoft.DesktopVirtualization/hostPools/$(Get-SettingValue HostPoolName)"
$parameters = (Get-SettingValue SessionHostParameters) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
if ($parameters.ImageReference.id -notmatch '^(?<definition>/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Compute/galleries/[^/]+/images/[^/]+)(?:/versions/[^/]+)?$') {
    throw 'Guided rollback requires a Compute Gallery image reference.'
}
$definitionId = $Matches.definition
$pin = if ($settings[$pinSetting]) { $settings[$pinSetting] | ConvertFrom-Json -AsHashtable -ErrorAction Stop }

$hostsByVMId = @{}
foreach ($hostEntry in @(Get-ArmCollection "$poolRoot/sessionHosts?api-version=$desktopVirtualizationApiVersion")) {
    if (-not $hostEntry.properties.resourceId) { throw 'A session host has no VM resource identity; resolve it before rollback.' }
    if ($hostsByVMId.ContainsKey($hostEntry.properties.resourceId)) { throw 'Multiple AVD registrations reference the same VM; resolve them before rollback.' }
    $hostsByVMId[$hostEntry.properties.resourceId] = $hostEntry
}
$poolVMs = @(Get-ArmCollection "$vmRoot/providers/Microsoft.Compute/virtualMachines?api-version=$computeApiVersion" |
    Where-Object { $hostsByVMId.ContainsKey($_.id) })
$poolVMsByName = @{}
foreach ($vm in $poolVMs) {
    if (-not $vm.tags) { $vm.tags = @{} }
    $poolVMsByName[$vm.name] = $vm
}

if (-not $RestoreOnly) {
    if (@($hostsByVMId.Keys | Where-Object { $_ -notin $poolVMs.id }).Count) {
        throw 'A registered host has no VM in the configured hosts resource group. Resolve missing-VM recovery, or use -RestoreOnly for emergency restoration.'
    }
    if (Get-SettingValue MaintenanceRequest -Default '') { throw 'Clear the maintenance request before guided rollback or ResumeLatest.' }
    Import-Module (Join-Path $PSScriptRoot 'functions\Modules\SessionHostReplacer\SessionHostReplacer.psd1') -Scope Local
    $coordinator = Get-Module SessionHostReplacer.Continuation -All | Where-Object {
        $_.Path -eq (Join-Path $PSScriptRoot 'functions\Modules\SessionHostReplacer\SessionHostReplacer.Continuation.psm1')
    } | Select-Object -First 1
    if (-not $coordinator) { throw 'Cannot load the SHR continuation module.' }
    $endpoint = [uri](Get-SettingValue AzureWebJobsStorage__tableServiceUri)
    if ($endpoint.Scheme -ne 'https' -or $endpoint.Host -notmatch "^[a-z0-9]{3,24}\.table\.$([regex]::Escape($environment.StorageEndpointSuffix))$" -or
        $endpoint.AbsolutePath -ne '/' -or $endpoint.Query -or $endpoint.UserInfo -or -not $endpoint.IsDefaultPort) {
        throw 'The Table endpoint does not match the active Azure cloud.'
    }
    $tableEndpoint = $endpoint.GetLeftPart([UriPartial]::Authority)
    $operationKey = & $coordinator { param($Values) Get-ShrOperationKey -Settings $Values } $settings
    $operationPath = "shrContinuation(PartitionKey='SHR',RowKey='$operationKey')"
    $partition = (Get-SettingValue HostPoolName).Replace("'", "''")
    $deploymentPath = "sessionHostDeploymentState(PartitionKey='$partition',RowKey='DeploymentState')"
    $snapshot = Get-RecoverySnapshot
    $deployments = @(Get-ArmCollection "$vmRoot/providers/Microsoft.Resources/deployments?api-version=2022-09-01")
    if (@($deployments | Where-Object { $_.properties.provisioningState -notin @('Succeeded', 'Failed', 'Canceled') }).Count -gt 0) {
        throw 'ARM deployments are still active. Wait for them to finish, or use -RestoreOnly to restore service without resuming SHR.'
    }
}

if ($ResumeLatest) {
    if (-not $pin -or $pin.Status -eq 'Restoring' -or
        ($parameters.ImageReference.id -ne $pin.Image -and
            -not ($pin.Status -in @('ResumingLatest', 'FollowingLatest') -and $parameters.ImageReference.id -eq $pin.Definition))) {
        throw 'No completed matching rollback pin exists; finish the rollback before removing its pin.'
    }
    $retryCommand += ' -ResumeLatest'
    $token = (Get-AzAccessToken -ResourceUrl $armRoot -DefaultProfile $context).Token
    if ($token -is [securestring]) { $token = [Net.NetworkCredential]::new('', $token).Password }
    $latest = Get-LatestImageVersion -ARMToken $token -ResourceManagerUri $armRoot -ImageReference @{ id = $pin.Definition } `
        -Location $parameters.Location -IncludeExcludedImageVersions ([bool]::Parse((Get-SettingValue IncludeExcludedImageVersions -Default 'false')))
    $selectedImage = "$($latest.Definition)/versions/$($latest.Version)"
    if ($selectedImage -in $pin.BadImages) { throw "Normal selection still chooses known bad image '$($latest.Version)'. Publish a corrected higher version or exclude the bad version, then rerun: $retryCommand" }
    $parameters.ImageReference = @{ id = $pin.Definition }
    $action = "Remove this pool's rollback pin; normal image selection currently chooses $($latest.Version); resume SHR"
    $selectedVMs = @()
    $badVMs = @()
} else {
    $retainedVMs = @($poolVMs | Where-Object { $_.tags[$shutdownTag] })
    $resumeCheckpoint = $pin -and ($pin.Status -eq 'Restoring' -or
        ($pin.Status -eq 'Restored' -and $ImageVersion -and $pin.Image -eq "$definitionId/versions/$ImageVersion"))
    # Include hosts restored by an interrupted invocation so rerunning completes the same plan.
    if ($resumeCheckpoint) {
        if ($parameters.ImageReference.id -ne $pin.Image) { throw 'The rollback image reference changed independently.' }
        $retainedVMs = @($poolVMs | Where-Object { $_.name -in $pin.HostNames })
        if ($retainedVMs.Count -ne @($pin.HostNames).Count) { throw 'A checkpointed rollback host is no longer registered.' }
        if ($SessionHostName -and (@($SessionHostName | Sort-Object -Unique) -join ',') -ne (@($pin.HostNames | Sort-Object -Unique) -join ',')) {
            throw 'Finish the checkpointed rollback with the same host selection before starting another.'
        }
        if ($ImageVersion -and $pin.Image -ne "$definitionId/versions/$ImageVersion") { throw 'Finish the checkpointed rollback before selecting another image.' }
    }
    if ($SessionHostName) {
        $retainedVMs = @($retainedVMs | Where-Object { $_.name -in $SessionHostName })
        $missing = @($SessionHostName | Where-Object { $_ -notin $retainedVMs.name })
        if ($missing.Count) { throw "Requested host(s) are not retained in this pool: $($missing -join ', ')." }
    }
    $generations = @($retainedVMs | ForEach-Object { Get-VMImage $_ } | Sort-Object -Unique)
    $availableGenerations = $generations -join ', '
    if ($ImageVersion) { $generations = @($generations | Where-Object { $_ -eq "$definitionId/versions/$ImageVersion" }) }
    if ($generations.Count -ne 1) {
        throw "Select one retained generation. Available: $availableGenerations. Rerun: $retryCommand -ImageVersion '<major.minor.patch>'"
    }
    $selectedImage = $generations[0]
    if (-not $selectedImage.StartsWith("$definitionId/versions/", [StringComparison]::OrdinalIgnoreCase)) { throw 'The retained image is from a different definition than this pool.' }
    $selectedVMs = @($retainedVMs | Where-Object { (Get-VMImage $_) -eq $selectedImage })
    if (@($selectedVMs | Where-Object { $_.properties.provisioningState -ne 'Succeeded' }).Count) { throw 'A selected retained VM is not fully provisioned.' }
    $badVMs = @($poolVMs | Where-Object {
        $_.name -notin $selectedVMs.name -and -not $_.tags[$shutdownTag] -and (Test-ManagedVM $_) -and (Get-VMImage $_) -ne $selectedImage
    })
    if ($resumeCheckpoint) {
        $badVMs = @($poolVMs | Where-Object { $_.name -in $pin.BadHostNames })
    }
    if (-not $RestoreOnly) {
        $image = Invoke-ArmRequest -Method GET -Path "${selectedImage}?api-version=2024-03-03&`$expand=ReplicationStatus"
        $region = $parameters.Location -replace '\s', ''
        if (-not @($image.properties.replicationStatus.summary | Where-Object { ($_.region -replace '\s', '') -eq $region -and $_.state -eq 'Completed' }).Count) {
            throw 'The retained image is not confirmed replicated to the host region; SHR cannot safely resume on it.'
        }
        $active = @($poolVMs | Where-Object { -not $_.tags[$shutdownTag] -and (Test-ManagedVM $_) })
        $target = [int](Get-SettingValue TargetSessionHostCount -Default '0')
        if ($target -eq 0) {
            $target = if ([int]$snapshot.Deployment.Entity.TargetSessionHostCount -gt 0) {
                [int]$snapshot.Deployment.Entity.TargetSessionHostCount
            } else { $active.Count }
        }
        if ($resumeCheckpoint) { $target = [int]$pin.Target }
        $existingGood = @($active | Where-Object {
            $_.name -notin $selectedVMs.name -and (Get-VMImage $_) -eq $selectedImage -and
            $hostsByVMId[$_.id].properties.status -eq 'Available' -and $hostsByVMId[$_.id].properties.allowNewSession -and
            @($hostsByVMId[$_.id].properties.healthCheckResults | Where-Object { $_.healthCheckResult -eq 'HealthCheckFailed' }).Count -eq 0
        })
        if ($selectedVMs.Count + $existingGood.Count -lt $target) {
            throw "Restored capacity would be below target $target. Use -RestoreOnly for emergency restoration without draining the current generation or restarting SHR."
        }
        $parameters.ImageReference = @{ id = $selectedImage }
    }
    $action = "Restore $($selectedVMs.Count) host(s) on $selectedImage"
    $action += if ($RestoreOnly) { '; leave SHR stopped and restored hosts excluded' } else { "; drain/exclude $($badVMs.Count) bad-image host(s), pin this pool, and resume SHR" }
    $retryCommand += " -ImageVersion '$($selectedImage.Split('/')[-1])'"
    if ($RestoreOnly) { $retryCommand += ' -RestoreOnly' }
}

Write-Host "Host pool: $(Get-SettingValue HostPoolName)"
Write-Host $action
if ($selectedVMs.Count) { Write-Host "Restore: $($selectedVMs.name -join ', ')" }
if ($badVMs.Count -and -not $RestoreOnly) { Write-Host "Drain and exclude (existing sessions preserved): $($badVMs.name -join ', ')" }
Write-Host 'No hosts will be deleted and no existing sessions will be signed out.'
if (-not $PSCmdlet.ShouldProcess($FunctionAppName, $action)) { return }

$restored = @()
$started = @()
$phase = 'Stopping SHR'
try {
    Invoke-ArmRequest -Method POST -Path "$functionAppResourceId/stop?api-version=$webApiVersion" | Out-Null
    Wait-FunctionAppState Stopped
    $freshSettings = Get-Settings
    Assert-UnchangedSettings -Expected $settings -Actual $freshSettings
    if (-not $RestoreOnly) {
        $phase = 'Checking durable recovery state'
        $freshHosts = @(Get-ArmCollection "$poolRoot/sessionHosts?api-version=$desktopVirtualizationApiVersion")
        $freshVMs = @(Get-ArmCollection "$vmRoot/providers/Microsoft.Compute/virtualMachines?api-version=$computeApiVersion")
        if ((($freshHosts.properties.resourceId | Sort-Object) -join ',') -ne (($hostsByVMId.Keys | Sort-Object) -join ',')) {
            throw 'Host pool membership changed after preflight; rerun the command.'
        }
        $poolVMsByName = @{}
        foreach ($vm in $freshVMs) {
            if ($vm.id -in $freshHosts.properties.resourceId) { $poolVMsByName[$vm.name] = $vm }
        }
        foreach ($vm in @($selectedVMs) + @($badVMs)) {
            $currentVM = @($freshVMs | Where-Object id -eq $vm.id)
            if ($currentVM.Count -ne 1 -or $vm.id -notin $freshHosts.properties.resourceId -or
                (Get-VMImage $currentVM[0]) -ne (Get-VMImage $vm) -or
                $currentVM[0].properties.provisioningState -ne 'Succeeded') {
                throw "Host '$($vm.name)' changed after preflight; rerun the command."
            }
            if (-not $currentVM[0].tags) { $currentVM[0].tags = @{} }
            Assert-UnchangedSettings -Expected $vm.tags -Actual $currentVM[0].tags -Description "VM '$($vm.name)' tags"
        }
        $fresh = Get-RecoverySnapshot
        foreach ($record in @('Operation', 'Deployment')) {
            if ($fresh[$record].ETag -ne $snapshot[$record].ETag) { throw 'SHR state changed after preflight; rerun the command.' }
        }
        $activeDeployments = @(Get-ArmCollection "$vmRoot/providers/Microsoft.Resources/deployments?api-version=2022-09-01" |
            Where-Object { $_.properties.provisioningState -notin @('Succeeded', 'Failed', 'Canceled') })
        if ($activeDeployments.Count) { throw 'An ARM deployment started after preflight; wait for it to finish.' }
        $phase = 'Pinning pool image'
        if (-not $ResumeLatest) {
            $pin = @{
                Image = $selectedImage; Definition = $definitionId; Status = 'Restoring'
                HostNames = @($selectedVMs.name); BadHostNames = @($badVMs.name)
                Target = $target
                BadImages = @(@($pin.BadImages) + @($badVMs | ForEach-Object { Get-VMImage $_ }) | Where-Object { $_ } | Sort-Object -Unique)
            }
            $freshSettings[$pinSetting] = $pin | ConvertTo-Json -Depth 10 -Compress
        } else {
            $pin.Status = 'ResumingLatest'
            $freshSettings[$pinSetting] = $pin | ConvertTo-Json -Depth 10 -Compress
        }
        $freshSettings.SessionHostParameters = $parameters | ConvertTo-Json -Depth 40 -Compress
        Invoke-ArmRequest -Method PUT -Path "$functionAppResourceId/config/appsettings?api-version=$webApiVersion" -Body @{ properties = $freshSettings } | Out-Null
        Wait-FunctionAppState Stopped
        $phase = 'Preserving previous SHR operation'
        Complete-PreviousOperation -Snapshot $fresh
    }

    $phase = 'Starting retained hosts'
    for ($offset = 0; $offset -lt $selectedVMs.Count; $offset += $StartBatchSize) {
        $batch = @($selectedVMs | Select-Object -Skip $offset -First $StartBatchSize)
        Assert-FunctionAppStopped
        foreach ($vm in $batch) {
            Write-Host "Starting $($vm.name)"
            Invoke-ArmRequest -Method POST -Path "$($vm.id)/start?api-version=$computeApiVersion" | Out-Null
            $started += $vm.name
        }
        Wait-RestoredHosts -VMs $batch
    }
    $phase = 'Returning healthy hosts to service'
    Assert-FunctionAppStopped
    foreach ($vm in $selectedVMs) {
        Set-VMTags $vm Merge @{ $includeTag = 'false' }
        Set-SessionAcceptance $hostsByVMId[$vm.id] $true
        $remove = @{ $shutdownTag = '' }
        if ($drainTag) { $remove[$drainTag] = '' }
        if ($scalingTag -and $vm.tags[$scalingTag] -eq 'SessionHostReplacer') { $remove[$scalingTag] = '' }
        Set-VMTags $vm Delete $remove
        $restored += $vm.name
    }
    if (-not $RestoreOnly) {
        $phase = 'Draining the bad-image generation'
        Assert-FunctionAppStopped
        if ($selectedVMs.Count -gt 0) { Wait-RestoredHosts -VMs @($selectedVMs + $existingGood) }
        foreach ($vm in $badVMs) {
            $badTags = @{ $includeTag = 'false' }
            if ($scalingTag -and (-not $vm.tags[$scalingTag] -or $vm.tags[$scalingTag] -eq 'SessionHostReplacer')) {
                $badTags[$scalingTag] = $pinSetting
            }
            Set-VMTags $vm Merge $badTags
            Set-SessionAcceptance $hostsByVMId[$vm.id] $false
        }
        foreach ($vm in $selectedVMs) { Set-VMTags $vm Merge @{ $includeTag = 'true' } }
        $phase = 'Verifying image configuration'
        $verifiedSettings = Get-Settings
        Assert-UnchangedSettings -Expected $freshSettings -Actual $verifiedSettings
        $pin.Status = if ($ResumeLatest) { 'FollowingLatest' } else { 'Restored' }
        $verifiedSettings[$pinSetting] = $pin | ConvertTo-Json -Depth 10 -Compress
        Invoke-ArmRequest -Method PUT -Path "$functionAppResourceId/config/appsettings?api-version=$webApiVersion" -Body @{ properties = $verifiedSettings } | Out-Null
        Wait-FunctionAppState Stopped
        $phase = 'Restarting SHR'
        Invoke-ArmRequest -Method POST -Path "$functionAppResourceId/start?api-version=$webApiVersion" | Out-Null
        Wait-FunctionAppState Running
    }
    $summary = [PSCustomObject]@{
        Status = if ($ResumeLatest) { 'FollowingLatest' } elseif ($RestoreOnly) { 'RestoredOnly' } else { 'Restored' }
        RestoredHosts = $restored
        DrainedHosts = @($badVMs.name | Where-Object { $_ -and -not $RestoreOnly })
        Image = $selectedImage
        AutomationEnabled = -not $RestoreOnly
        FunctionAppState = if ($RestoreOnly) { 'Stopped' } else { 'Running' }
    }
    $summary | Format-List | Out-Host
    if (-not $RestoreOnly -and -not $ResumeLatest) {
        Write-Host "Pool is pinned. After publishing a corrected image or excluding the bad version, remove the pin with: $baseCommand -ResumeLatest"
        Write-Host 'Bad-image hosts remain drained and excluded. Remove them later through the approved operator process.'
    }
    if ($PassThru) { $summary }
} catch {
    $failure = $_
    try {
        Invoke-ArmRequest -Method POST -Path "$functionAppResourceId/stop?api-version=$webApiVersion" | Out-Null
        Wait-FunctionAppState Stopped
        Write-Warning 'SHR is stopped; it has not been resumed after the failure.'
    } catch { Write-Warning "Could not confirm SHR is stopped: $($_.Exception.Message). Stop it in Azure before continuing." }
    Write-Warning "Rollback failed during '$phase'. VM starts requested: $($started -join ', '). Hosts returned to service: $($restored -join ', '). No hosts or sessions were deleted. Resolve the error, then retry: $retryCommand"
    throw $failure
}
