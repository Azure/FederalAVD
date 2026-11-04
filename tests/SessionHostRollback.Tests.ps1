$repoRoot = Split-Path -Parent $PSScriptRoot
$rollbackScriptPath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\Invoke-SessionHostRollback.ps1'

function New-RollbackResponse {
    param([object]$Content, [int]$StatusCode = 200, [string]$ETag = 'record-1')
    [PSCustomObject]@{
        StatusCode = $StatusCode
        Headers = @{ ETag = $ETag }
        Content = if ($null -eq $Content) { '' } else { $Content | ConvertTo-Json -Depth 60 -Compress }
    }
}

function Add-RollbackVM {
    param([string]$Name, [string]$Version, [switch]$Retained, [switch]$Foreign)
    $data = $global:rollbackSimulation
    $id = "/subscriptions/vm-sub/resourceGroups/rg-hosts/providers/Microsoft.Compute/virtualMachines/$Name"
    $tags = @{ IncludeInAutoReplace = 'true' }
    if ($Retained) {
        $tags.AutoReplaceShutdownTimestamp = '2026-10-05T10:00:00Z'
        $tags.ScalingPlanExclusion = 'SessionHostReplacer'
        $tags.PendingDrain = '2026-10-05T09:00:00Z'
    }
    $data.VMs += @{
        id = $id; name = $Name; tags = $tags
        properties = @{
            provisioningState = 'Succeeded'
            storageProfile = @{ imageReference = @{ id = "$($data.Definition)/versions/$Version" } }
        }
    }
    if (-not $Foreign) {
        $data.Hosts += @{
            id = "/subscriptions/hp-sub/resourceGroups/rg-pool/providers/Microsoft.DesktopVirtualization/hostPools/hp-prod/sessionHosts/$Name.contoso.test"
            name = "$Name.contoso.test"
            properties = @{
                resourceId = $id
                status = if ($Retained) { 'Shutdown' } else { 'Available' }
                allowNewSession = -not $Retained
                healthCheckResults = @(@{ healthCheckResult = 'HealthCheckSucceeded' })
            }
        }
    }
}

Describe 'Guided Session Host Replacer shutdown-retention rollback' {
    BeforeAll {
        Import-Module (Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\functions\Modules\SessionHostReplacer\SessionHostReplacer.psd1') -Force
    }
    AfterAll { Remove-Module SessionHostReplacer -Force }
    BeforeEach {
        $definition = '/subscriptions/img-sub/resourceGroups/rg-images/providers/Microsoft.Compute/galleries/gallery/images/desktop'
        $global:rollbackSimulation = @{
            Definition = $definition
            FunctionState = 'Running'
            VMs = @(); Hosts = @(); Calls = @(); Archives = @(); Warnings = @()
            OperationETag = 'operation-1'; DeploymentETag = 'deployment-1'
            Operation = @{
                Id = ('a' * 32); Status = 'Completed'; DeploymentHostNames = @('bad-01', 'bad-02')
                CleanupIntent = $null; DeploymentIntent = $null; ConfigurationHash = 'old-hash'
            }
            Deployment = @{
                PartitionKey = 'hp-prod'; RowKey = 'DeploymentState'; PendingHostMappings = '{}'
                LastDeploymentName = 'old-deployment'; TargetSessionHostCount = 2; LastTotalToReplace = 0
            }
            Settings = @{
                ReplacementMode = 'SideBySide'; EnableShutdownRetention = 'true'
                HostPoolSubscriptionId = 'hp-sub'; HostPoolResourceGroupName = 'rg-pool'; HostPoolName = 'hp-prod'
                VirtualMachinesSubscriptionId = 'vm-sub'; VirtualMachinesResourceGroupName = 'rg-hosts'
                Tag_ShutdownTimestamp = 'AutoReplaceShutdownTimestamp'; Tag_IncludeInAutomation = 'IncludeInAutoReplace'
                Tag_ScalingPlanExclusionTag = 'ScalingPlanExclusion'; Tag_PendingDrainTimestamp = 'PendingDrain'
                AzureWebJobsStorage__tableServiceUri = 'https://shrstorage.table.core.windows.net'
                TargetSessionHostCount = '2'; IncludeExcludedImageVersions = 'false'; AllowImageVersionRollback = 'false'
                SessionHostParameters = (@{ Location = 'eastus2'; ImageReference = @{ id = $definition }; adminPassword = 'test-secret-not-to-log' } | ConvertTo-Json -Compress)
                UnrelatedSetting = 'preserve-me'
            }
            ActiveDeployment = $false; ReplicaState = 'Completed'; NextVersion = '3.0.0'
            FailHostRead = $false; FailStartApp = $false; TableConflict = $false
            ChangeStateOnStop = $false; ChangeHostOnStop = $false; Paginate = $false
            FailBadDrainOnce = $false; RestartDuringHostStart = $false; ArmFailure = $false; TableFailure = $false
            UnhealthyReadsRemaining = 0
        }
        Add-RollbackVM old-01 1.0.0 -Retained
        Add-RollbackVM old-02 1.0.0 -Retained
        Add-RollbackVM bad-01 2.0.0
        Add-RollbackVM bad-02 2.0.0
        Mock Get-AzContext {
            $context = [Microsoft.Azure.Commands.Profile.Models.Core.PSAzureContext]::new()
            $context.Subscription = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureSubscription]::new()
            $context.Subscription.Id = 'app-sub'
            $context.Environment = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureEnvironment]::new()
            $context.Environment.Name = 'AzureCloud'
            $context
        }
        Mock Get-AzEnvironment { [PSCustomObject]@{ ResourceManagerUrl = 'https://management.azure.com/'; StorageEndpointSuffix = 'core.windows.net' } }
        Mock Get-AzAccessToken { [PSCustomObject]@{ Token = 'test-token' } }
        Mock Start-Sleep {}
        Mock Write-Progress {}
        Mock Write-Host {}
        Mock Out-Host {}
        Mock Write-Warning { param($Message) $global:rollbackSimulation.Warnings += $Message }
        Mock Invoke-AzRestMethod {
            param($Method, $Path, $Payload)
            $data = $global:rollbackSimulation
            $data.Calls += @{ Method = $Method; Path = $Path; Payload = $Payload }
            if ($Path -like '*/config/appsettings/list?api-version=*') { return New-RollbackResponse @{ properties = $data.Settings } }
            if ($Path -like '*/config/appsettings?api-version=*' -and $Method -eq 'PUT') {
                $data.Settings = ($Payload | ConvertFrom-Json -AsHashtable).properties
                return New-RollbackResponse $null
            }
            if ($Path -like '*/sites/func-shr?api-version=*') {
                return New-RollbackResponse @{ type = 'Microsoft.Web/sites'; kind = 'functionapp'; properties = @{ state = $data.FunctionState } }
            }
            if ($Path -like '*/sites/func-shr/stop?api-version=*') {
                $data.FunctionState = 'Stopped'
                if ($data.ChangeStateOnStop) { $data.OperationETag = 'concurrent-update' }
                if ($data.ChangeHostOnStop) { $data.VMs[0].tags.IncludeInAutoReplace = 'false' }
                return New-RollbackResponse $null -StatusCode 202
            }
            if ($Path -like '*/sites/func-shr/start?api-version=*') {
                if ($data.FailStartApp) { return New-RollbackResponse $null -StatusCode 500 }
                $data.FunctionState = 'Running'
                return New-RollbackResponse $null -StatusCode 202
            }
            if ($Path -like '*/providers/Microsoft.Compute/virtualMachines?api-version=*') {
                if ($data.Paginate) {
                    return New-RollbackResponse @{ value = @($data.VMs[0]); nextLink = 'https://management.azure.com/nextVMPage' }
                }
                return New-RollbackResponse @{ value = @($data.VMs) }
            }
            if ($Path -eq '/nextVMPage') { return New-RollbackResponse @{ value = @($data.VMs | Select-Object -Skip 1) } }
            if ($Path -like '*/hostPools/hp-prod/sessionHosts?api-version=*') { return New-RollbackResponse @{ value = @($data.Hosts) } }
            if ($Path -like '*/providers/Microsoft.Resources/deployments?api-version=*') {
                if ($data.ArmFailure) { return New-RollbackResponse $null -StatusCode 403 }
                return New-RollbackResponse @{ value = @(@{ properties = @{ provisioningState = if ($data.ActiveDeployment) { 'Running' } else { 'Succeeded' } } }) }
            }
            if ($Path -like '*/versions/*?api-version=*') {
                return New-RollbackResponse @{ properties = @{ replicationStatus = @{ summary = @(@{ region = 'East US 2'; state = $data.ReplicaState }) } } }
            }
            if ($Path -like '*/providers/Microsoft.Compute/virtualMachines/*/start?api-version=*') {
                $vmId = $Path.Split('?')[0] -replace '/start$', ''
                ($data.Hosts | Where-Object { $_.properties.resourceId -eq $vmId }).properties.status = 'Available'
                if ($data.RestartDuringHostStart) { $data.FunctionState = 'Running' }
                return New-RollbackResponse $null -StatusCode 202
            }
            if ($Path -like '*/providers/Microsoft.Resources/tags/default?api-version=*') {
                $vmId = $Path.Split('/providers/Microsoft.Resources/tags/')[0]
                $vm = $data.VMs | Where-Object id -eq $vmId
                $body = $Payload | ConvertFrom-Json -AsHashtable
                foreach ($name in $body.properties.tags.Keys) {
                    if ($body.operation -eq 'Merge') { $vm.tags[$name] = $body.properties.tags[$name] }
                    else { $vm.tags.Remove($name) }
                }
                return New-RollbackResponse $null
            }
            if ($Path -like '*/sessionHosts/*.contoso.test?api-version=*') {
                $hostEntry = $data.Hosts | Where-Object { $_.id -eq $Path.Split('?')[0] }
                if ($Method -eq 'GET') {
                    if ($data.FailHostRead) { return New-RollbackResponse $null -StatusCode 503 }
                    if ($data.UnhealthyReadsRemaining -gt 0) {
                        $data.UnhealthyReadsRemaining--
                        $unhealthy = $hostEntry | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
                        $unhealthy.properties.healthCheckResults = @(@{ healthCheckResult = 'HealthCheckFailed' })
                        return New-RollbackResponse $unhealthy
                    }
                    return New-RollbackResponse $hostEntry
                }
                if ($data.FailBadDrainOnce -and $hostEntry.name -like 'bad-*') {
                    $data.FailBadDrainOnce = $false
                    return New-RollbackResponse $null -StatusCode 409
                }
                $hostEntry.properties.allowNewSession = ($Payload | ConvertFrom-Json -AsHashtable).properties.allowNewSession
                return New-RollbackResponse $null
            }
            throw "Unexpected ARM request: $Method $Path"
        }
        Mock Invoke-WebRequest {
            param($Uri, $Method, $Headers, $Body)
            $data = $global:rollbackSimulation
            $data.Calls += @{ Method = $Method; Path = $Uri; Payload = $Body; ETag = $Headers['If-Match'] }
            if ($data.TableFailure) { return New-RollbackResponse $null -StatusCode 403 }
            if ($Uri -like '*/shrContinuation' -and $Method -eq 'POST') {
                $data.Archives += ($Body | ConvertFrom-Json -AsHashtable)
                return New-RollbackResponse $null -StatusCode 201
            }
            if ($Uri -like '*/shrContinuation(*') {
                if (-not $data.Operation) { return New-RollbackResponse $null -StatusCode 404 }
                if ($Method -eq 'GET') {
                    return New-RollbackResponse @{ State = ($data.Operation | ConvertTo-Json -Depth 40 -Compress) } -ETag $data.OperationETag
                }
                if ($data.TableConflict) { return New-RollbackResponse $null -StatusCode 412 }
                $data.Operation = ($Body | ConvertFrom-Json -AsHashtable).State | ConvertFrom-Json -AsHashtable
                $data.OperationETag = 'operation-2'
                return New-RollbackResponse $null -StatusCode 204
            }
            if ($Uri -like '*/sessionHostDeploymentState(*') {
                if (-not $data.Deployment) { return New-RollbackResponse $null -StatusCode 404 }
                if ($Method -eq 'GET') { return New-RollbackResponse $data.Deployment -ETag $data.DeploymentETag }
                if ($data.TableConflict) { return New-RollbackResponse $null -StatusCode 412 }
                $updates = $Body | ConvertFrom-Json -AsHashtable
                foreach ($key in $updates.Keys) { $data.Deployment[$key] = $updates[$key] }
                return New-RollbackResponse $null -StatusCode 204
            }
            throw "Unexpected Table request: $Method $Uri"
        }
        Mock Invoke-AzureRestMethod -ModuleName SessionHostReplacer.ImageManagement {
            param($Uri)
            $data = $global:rollbackSimulation
            $version = @{
                name = $data.NextVersion
                properties = @{
                    publishingProfile = @{ publishedDate = '2026-10-01T00:00:00Z'; excludeFromLatest = $false }
                    replicationStatus = @{ summary = @(@{ region = 'eastus2'; state = 'Completed' }) }
                }
            }
            if ($Uri -like '*/versions?api-version=*') { return @($version) }
            return $version
        }
    }
    AfterEach { Remove-Variable rollbackSimulation -Scope Global }

    It 'restores the pool with one confirmation boundary, concurrent starts, a local pin and SHR running' {
        $result = & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -Confirm:$false -PassThru
        $result.Status | Should Be 'Restored'
        $result.RestoredHosts.Count | Should Be 2
        $result.DrainedHosts.Count | Should Be 2
        $result.AutomationEnabled | Should Be $true
        $global:rollbackSimulation.FunctionState | Should Be 'Running'
        $parameters = $global:rollbackSimulation.Settings.SessionHostParameters | ConvertFrom-Json
        $parameters.ImageReference.id | Should Be "$($global:rollbackSimulation.Definition)/versions/1.0.0"
        $parameters.adminPassword | Should Be 'test-secret-not-to-log'
        $global:rollbackSimulation.Settings.UnrelatedSetting | Should Be 'preserve-me'
        $calls = $global:rollbackSimulation.Calls
        $startIndexes = @(for ($i = 0; $i -lt $calls.Count; $i++) {
            if ($calls[$i].Path -like '*/virtualMachines/old-*/start?*') { $i }
        })
        $firstHealthRead = @(for ($i = 0; $i -lt $calls.Count; $i++) {
            if ($calls[$i].Method -eq 'GET' -and $calls[$i].Path -like '*/sessionHosts/old-*.contoso.test?*') { $i }
        })[0]
        $startIndexes.Count | Should Be 2
        $startIndexes[1] | Should BeLessThan $firstHealthRead
        foreach ($vm in @($global:rollbackSimulation.VMs | Where-Object name -like 'old-*')) {
            $vm.tags.IncludeInAutoReplace | Should Be 'true'
            $vm.tags.Contains('AutoReplaceShutdownTimestamp') | Should Be $false
            $vm.tags.Contains('PendingDrain') | Should Be $false
            $vm.tags.Contains('ScalingPlanExclusion') | Should Be $false
        }
        foreach ($vm in @($global:rollbackSimulation.VMs | Where-Object name -like 'bad-*')) {
            $vm.tags.IncludeInAutoReplace | Should Be 'false'
            $vm.tags.ScalingPlanExclusion | Should Be 'ShutdownRetentionRollback'
        }
        @($global:rollbackSimulation.Hosts | Where-Object { $_.name -like 'bad-*' -and $_.properties.allowNewSession }).Count | Should Be 0
        @($calls | Where-Object { $_.Method -eq 'DELETE' -or $_.Path -match 'userSessions|/signOut|/logoff' }).Count | Should Be 0
        $global:rollbackSimulation.Archives.Count | Should Be 1
        $archive = $global:rollbackSimulation.Archives[0].State | ConvertFrom-Json
        $archive.DeploymentRecoveryRecord.LastDeploymentName | Should Be 'old-deployment'
    }

    It 'performs no writes with WhatIf, including when the app is running' {
        & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -WhatIf
        @($global:rollbackSimulation.Calls | Where-Object {
            $_.Method -ne 'GET' -and $_.Path -notlike '*/config/appsettings/list?*'
        }).Count | Should Be 0
        $global:rollbackSimulation.FunctionState | Should Be 'Running'
    }

    It 'rejects ambiguous retained generations before stopping SHR' {
        Add-RollbackVM older-01 0.9.0 -Retained
        { & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -Confirm:$false } |
            Should Throw 'Select one retained generation'
        $global:rollbackSimulation.FunctionState | Should Be 'Running'
    }

    It 'selects a generation explicitly and ignores retention-tagged VMs outside this host pool' {
        Add-RollbackVM older-01 0.9.0 -Retained
        Add-RollbackVM foreign-01 0.8.0 -Retained -Foreign
        $result = & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -ImageVersion 1.0.0 -Confirm:$false -PassThru
        $result.RestoredHosts.Count | Should Be 2
        @($global:rollbackSimulation.Calls | Where-Object { $_.Path -match '/(older|foreign)-01/start' }).Count | Should Be 0
    }

    It 'supports paginated VM inventory' {
        $global:rollbackSimulation.Paginate = $true
        $result = & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -Confirm:$false -PassThru
        $result.RestoredHosts.Count | Should Be 2
    }

    It 'waits for health failures to clear before enabling sessions or draining other hosts' {
        $global:rollbackSimulation.UnhealthyReadsRemaining = 1
        & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -Confirm:$false
        Assert-MockCalled Start-Sleep -Scope It -Times 1 -Exactly
        $global:rollbackSimulation.UnhealthyReadsRemaining | Should Be 0
    }

    It 'starts no more than the configured batch size before awaiting health' {
        & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -StartBatchSize 1 -Confirm:$false
        $calls = $global:rollbackSimulation.Calls
        $starts = @(for ($i = 0; $i -lt $calls.Count; $i++) {
            if ($calls[$i].Path -like '*/virtualMachines/old-*/start?*') { $i }
        })
        @($calls[($starts[0] + 1)..($starts[1] - 1)] | Where-Object {
            $_.Method -eq 'GET' -and $_.Path -like '*/sessionHosts/old-01.contoso.test?*'
        }).Count | Should BeGreaterThan 0
    }

    It 'preserves administrator-owned autoscale exclusions' {
        $global:rollbackSimulation.VMs[0].tags.ScalingPlanExclusion = 'Administrator'
        $global:rollbackSimulation.VMs[2].tags.ScalingPlanExclusion = 'Administrator'
        & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -Confirm:$false
        $global:rollbackSimulation.VMs[0].tags.ScalingPlanExclusion | Should Be 'Administrator'
        $global:rollbackSimulation.VMs[2].tags.ScalingPlanExclusion | Should Be 'Administrator'
    }

    It 'blocks insufficient recovery capacity before stopping SHR' {
        { & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -SessionHostName old-01 -Confirm:$false } |
            Should Throw 'below target'
        $global:rollbackSimulation.FunctionState | Should Be 'Running'
    }

    It 'rejects colliding tag controls before stopping SHR' {
        $global:rollbackSimulation.Settings.Tag_ShutdownTimestamp = 'IncludeInAutoReplace'
        { & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -Confirm:$false } | Should Throw 'must be distinct'
        $global:rollbackSimulation.FunctionState | Should Be 'Running'
    }

    It 'uses the actual resolved version when a VM image reference used latest' {
        $global:rollbackSimulation.VMs[0].properties.storageProfile.imageReference = @{
            id = "$($global:rollbackSimulation.Definition)/versions/latest"; exactVersion = '1.0.0'
        }
        $result = & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -Confirm:$false -PassThru
        $result.Image | Should Be "$($global:rollbackSimulation.Definition)/versions/1.0.0"
    }

    It 'provides emergency RestoreOnly without changing image, durable state or the bad hosts' {
        $global:rollbackSimulation.Operation.CleanupIntent = @{ Phase = 'Deleting' }
        $result = & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -RestoreOnly `
            -SessionHostName old-01 -StopFunctionApp -Confirm:$false -PassThru
        $result.FunctionAppState | Should Be 'Stopped'
        $result.RestoredHosts.Count | Should Be 1
        $result.AutomationEnabled | Should Be $false
        $result.DrainedHosts.Count | Should Be 0
        ($result.DrainedHosts -is [array]) | Should Be $true
        $global:rollbackSimulation.VMs[0].tags.IncludeInAutoReplace | Should Be 'false'
        $global:rollbackSimulation.VMs[2].tags.IncludeInAutoReplace | Should Be 'true'
        ($global:rollbackSimulation.Settings.SessionHostParameters | ConvertFrom-Json).ImageReference.id | Should Be $global:rollbackSimulation.Definition
        @($global:rollbackSimulation.Calls | Where-Object Path -like 'https://*.table.*').Count | Should Be 0
    }

    It 'blocks an unfinished cleanup before stopping SHR' {
        $global:rollbackSimulation.Operation.CleanupIntent = @{ Phase = 'Deleting' }
        { & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -Confirm:$false } | Should Throw 'unfinished'
        $global:rollbackSimulation.FunctionState | Should Be 'Running'
    }

    It 'blocks pending recovery mappings before stopping SHR' {
        $global:rollbackSimulation.Deployment.PendingHostMappings = '{"old-01":{"State":"Deleting"}}'
        { & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -Confirm:$false } | Should Throw 'Pending recovery'
        $global:rollbackSimulation.FunctionState | Should Be 'Running'
    }

    It 'does not interpret failed ARM or Table reads as absence' -TestCases @(
        @{ Surface = 'ArmFailure' }
        @{ Surface = 'TableFailure' }
    ) {
        param($Surface)
        $global:rollbackSimulation[$Surface] = $true
        { & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -Confirm:$false } | Should Throw 'HTTP 403'
        $global:rollbackSimulation.FunctionState | Should Be 'Running'
    }

    It 'handles absent state records without inventing or overwriting recovery state' {
        $global:rollbackSimulation.Operation = $null
        $global:rollbackSimulation.Deployment = $null
        & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -Confirm:$false
        $global:rollbackSimulation.FunctionState | Should Be 'Running'
        $global:rollbackSimulation.Archives.Count | Should Be 0
        @($global:rollbackSimulation.Calls | Where-Object Method -eq 'MERGE').Count | Should Be 0
    }

    It 'blocks active ARM deployments before stopping SHR' {
        $global:rollbackSimulation.ActiveDeployment = $true
        { & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -Confirm:$false } | Should Throw 'still active'
        $global:rollbackSimulation.FunctionState | Should Be 'Running'
    }

    It 'requires confirmed regional replication before resuming on the restored image' {
        $global:rollbackSimulation.ReplicaState = 'InProgress'
        { & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -Confirm:$false } | Should Throw 'not confirmed replicated'
        $global:rollbackSimulation.FunctionState | Should Be 'Running'
    }

    It 'archives and supersedes a started operation without replaying its pinned bad image' {
        $global:rollbackSimulation.Operation.Status = 'Running'
        $global:rollbackSimulation.Deployment.LastStatus = 'Error'
        & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -Confirm:$false
        $global:rollbackSimulation.Operation.Status | Should Be 'Superseded'
        $global:rollbackSimulation.Operation.DeploymentHostNames.Count | Should Be 2
        $archive = $global:rollbackSimulation.Archives[0].State | ConvertFrom-Json
        $archive.PreviousState.Status | Should Be 'Running'
        $archive.PreviousState.ConfigurationHash | Should Be 'old-hash'
        $merge = @($global:rollbackSimulation.Calls | Where-Object { $_.Method -eq 'MERGE' -and $_.Path -like '*/shrContinuation(*' })
        $merge.Count | Should Be 1
        $merge[0].ETag | Should Be 'operation-1'
        $global:rollbackSimulation.Deployment.LastStatus | Should Be 'RollbackRestored'
    }

    It 'blocks unresolved checkpointed deployment targets' {
        $global:rollbackSimulation.Operation.Status = 'NeedsAttention'
        $global:rollbackSimulation.Operation.DeploymentHostNames = @('missing-01')
        { & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -Confirm:$false } | Should Throw 'not fully provisioned'
        $global:rollbackSimulation.FunctionState | Should Be 'Running'
    }

    It 'leaves SHR stopped and starts no hosts when durable state changes after preview' {
        $global:rollbackSimulation.ChangeStateOnStop = $true
        { & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -Confirm:$false } | Should Throw 'state changed'
        $global:rollbackSimulation.FunctionState | Should Be 'Stopped'
        @($global:rollbackSimulation.Calls | Where-Object Path -like '*/virtualMachines/*/start?*').Count | Should Be 0
    }

    It 'detects host changes after preview' {
        $global:rollbackSimulation.ChangeHostOnStop = $true
        { & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -Confirm:$false } | Should Throw 'tags changed'
        $global:rollbackSimulation.FunctionState | Should Be 'Stopped'
    }

    It 'stops again if another operator restarts SHR during host startup' {
        $global:rollbackSimulation.RestartDuringHostStart = $true
        { & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -Confirm:$false } | Should Throw 'restarted during rollback'
        $global:rollbackSimulation.FunctionState | Should Be 'Stopped'
        $global:rollbackSimulation.VMs[0].tags.Contains('AutoReplaceShutdownTimestamp') | Should Be $true
    }

    It 'uses conditional writes and leaves SHR stopped on a Table conflict' {
        $global:rollbackSimulation.Operation.Status = 'Running'
        $global:rollbackSimulation.TableConflict = $true
        { & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -Confirm:$false } | Should Throw 'HTTP 412'
        $global:rollbackSimulation.FunctionState | Should Be 'Stopped'
        @($global:rollbackSimulation.Calls | Where-Object Path -like '*/virtualMachines/*/start?*').Count | Should Be 0
    }

    It 'preserves retention/drain controls on readiness failure and permits a checkpointed retry' {
        $global:rollbackSimulation.FailHostRead = $true
        { & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -Confirm:$false } | Should Throw 'HTTP 503'
        $global:rollbackSimulation.FunctionState | Should Be 'Stopped'
        $global:rollbackSimulation.VMs[0].tags.Contains('AutoReplaceShutdownTimestamp') | Should Be $true
        ($global:rollbackSimulation.Settings.ShutdownRetentionRollback | ConvertFrom-Json).Status | Should Be 'Restoring'
        $global:rollbackSimulation.Warnings -join "`n" | Should Match 'VM starts requested: old-01, old-02'
        $global:rollbackSimulation.FailHostRead = $false
        $result = & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -ImageVersion 1.0.0 -Confirm:$false -PassThru
        $result.FunctionAppState | Should Be 'Running'
    }

    It 'can retry after restoration completed but the Function App could not restart' {
        $global:rollbackSimulation.FailStartApp = $true
        { & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -Confirm:$false } | Should Throw 'HTTP 500'
        $global:rollbackSimulation.FunctionState | Should Be 'Stopped'
        $global:rollbackSimulation.FailStartApp = $false
        $result = & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -ImageVersion 1.0.0 -Confirm:$false -PassThru
        $result.FunctionAppState | Should Be 'Running'
    }

    It 'can retry a partially applied drain after restored hosts have lost their retention tags' {
        $global:rollbackSimulation.FailBadDrainOnce = $true
        { & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -Confirm:$false } | Should Throw 'HTTP 409'
        $global:rollbackSimulation.FunctionState | Should Be 'Stopped'
        $global:rollbackSimulation.VMs[0].tags.Contains('AutoReplaceShutdownTimestamp') | Should Be $false
        ($global:rollbackSimulation.Settings.ShutdownRetentionRollback | ConvertFrom-Json).Status | Should Be 'Restoring'
        $result = & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -ImageVersion 1.0.0 -Confirm:$false -PassThru
        $result.FunctionAppState | Should Be 'Running'
        $result.DrainedHosts.Count | Should Be 2
    }

    It 'removes the pin with ResumeLatest while preserving other parameters and bad-host exclusions' {
        & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -Confirm:$false
        $result = & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -ResumeLatest -Confirm:$false -PassThru
        $result.Status | Should Be 'FollowingLatest'
        $result.FunctionAppState | Should Be 'Running'
        ($global:rollbackSimulation.Settings.ShutdownRetentionRollback | ConvertFrom-Json).Status | Should Be 'FollowingLatest'
        $parameters = $global:rollbackSimulation.Settings.SessionHostParameters | ConvertFrom-Json
        $parameters.ImageReference.id | Should Be $global:rollbackSimulation.Definition
        $parameters.adminPassword | Should Be 'test-secret-not-to-log'
        $global:rollbackSimulation.VMs[2].tags.IncludeInAutoReplace | Should Be 'false'
    }

    It 'refuses to unpin if normal selection would redeploy the known bad version' {
        & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -Confirm:$false
        $global:rollbackSimulation.NextVersion = '2.0.0'
        { & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -ResumeLatest -Confirm:$false } | Should Throw 'known bad image'
        $global:rollbackSimulation.FunctionState | Should Be 'Running'
        ($global:rollbackSimulation.Settings.SessionHostParameters | ConvertFrom-Json).ImageReference.id |
            Should Be "$($global:rollbackSimulation.Definition)/versions/1.0.0"
    }

    It 'can remove the pin after shutdown retention has been disabled' {
        & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -Confirm:$false
        $global:rollbackSimulation.Settings.EnableShutdownRetention = 'false'
        $result = & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -ResumeLatest -Confirm:$false -PassThru
        $result.Status | Should Be 'FollowingLatest'
        $global:rollbackSimulation.Settings.EnableShutdownRetention | Should Be 'false'
    }

    It 'does not remove an image pin that was changed independently' {
        & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -Confirm:$false
        $parameters = $global:rollbackSimulation.Settings.SessionHostParameters | ConvertFrom-Json -AsHashtable
        $parameters.ImageReference.id = "$($global:rollbackSimulation.Definition)/versions/4.0.0"
        $global:rollbackSimulation.Settings.SessionHostParameters = $parameters | ConvertTo-Json -Compress
        { & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -ResumeLatest -Confirm:$false } | Should Throw 'matching rollback pin'
    }

    It 'can retry unpinning after a restart failure without losing the rollback checkpoint' {
        & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -Confirm:$false
        $global:rollbackSimulation.FailStartApp = $true
        { & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -ResumeLatest -Confirm:$false } | Should Throw 'HTTP 500'
        ($global:rollbackSimulation.Settings.ShutdownRetentionRollback | ConvertFrom-Json).Status | Should Be 'FollowingLatest'
        $global:rollbackSimulation.FailStartApp = $false
        $result = & $rollbackScriptPath -FunctionAppName func-shr -FunctionAppResourceGroupName rg-operations -ResumeLatest -Confirm:$false -PassThru
        $result.Status | Should Be 'FollowingLatest'
    }
}
