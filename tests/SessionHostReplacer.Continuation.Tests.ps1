$repoRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\functions\Modules\SessionHostReplacer\SessionHostReplacer.psd1'

Describe 'SHR continuation coordination' {
    BeforeAll {
        Import-Module $modulePath -Force
        $cyclePath = Join-Path $TestDrive 'cycle.ps1'
        @'
param($Timer, $ContinuationContext, $CycleResult)
$global:shrContinuationTest.Cycles++
$global:shrContinuationTest.Order += 'cycle'
if ($global:shrContinuationTest.Action) {
    & $global:shrContinuationTest.Action $ContinuationContext $CycleResult
}
'@ | Set-Content -LiteralPath $cyclePath -Encoding ascii
    }

    BeforeEach {
        $global:shrContinuationTest = @{
            Cycles = 0
            Order = @()
            Messages = @()
            Saves = @()
            Logs = @()
            Conflict = $false
            FailDelay = -1
            Action = $null
            FailCheckpointOnce = $false
            Settings = @{
                EnableQueueContinuation = $true
                InitiationEnabled = $true
                HostPoolSubscriptionId = 'test'
                HostPoolResourceGroupName = 'hosts'
                HostPoolName = 'hp'
            }
            Operation = @{
                Key = 'key'
                ETag = 'version-1'
                State = @{
                    Id = ('a' * 32)
                    Status = 'Running'
                    DeadlineUtc = [DateTimeOffset]::UtcNow.AddHours(72).ToString('o')
                    InitiationExpiresUtc = [DateTimeOffset]::UtcNow.AddMinutes(5).ToString('o')
                    LockOwner = ''
                    LockExpiresUtc = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')
                    ConfigurationHash = 'configuration'
                    LastError = ''
                    Image = $null
                    BatchHostNames = $null
                    DeploymentIntent = $null
                    CleanupIntent = $null
                    Generation = 0
                }
            }
        }
        Mock Read-FunctionAppSetting -ModuleName SessionHostReplacer.Continuation {
            param($SettingKey)
            $global:shrContinuationTest.Settings[$SettingKey]
        }
        Mock Get-ShrConfigurationHash -ModuleName SessionHostReplacer.Continuation { 'configuration' }
        Mock Get-ShrInitiationImage -ModuleName SessionHostReplacer.Continuation {
            @{ Definition = '/gallery/images/avd'; Version = '2.0.0'; Date = '2026-01-01T00:00:00Z' }
        }
        Mock Write-LogEntry -ModuleName SessionHostReplacer.Continuation {
            param($Message)
            $global:shrContinuationTest.Logs += $Message
        }
        Mock Get-ShrOperation -ModuleName SessionHostReplacer.Continuation {
            if ($global:shrContinuationTest.Operation) {
                $global:shrContinuationTest.Operation | ConvertTo-Json -Depth 40 |
                    ConvertFrom-Json -AsHashtable
            }
        }
        Mock Save-ShrOperation -ModuleName SessionHostReplacer.Continuation {
            param($Operation)
            if ($global:shrContinuationTest.Conflict) { return $false }
            if ($global:shrContinuationTest.FailCheckpointOnce -and $global:shrContinuationTest.Saves.Count -gt 0) {
                $global:shrContinuationTest.FailCheckpointOnce = $false
                throw 'cleanup checkpoint unavailable'
            }
            $Operation.ETag = [guid]::NewGuid().ToString()
            $global:shrContinuationTest.Operation = $Operation | ConvertTo-Json -Depth 40 |
                ConvertFrom-Json -AsHashtable
            $global:shrContinuationTest.Saves += $global:shrContinuationTest.Operation
            $global:shrContinuationTest.Order += 'save'
            return $true
        }
        Mock Get-AccessToken -ModuleName SessionHostReplacer.Continuation { 'token' }
        Mock Get-ResourceManagerUri -ModuleName SessionHostReplacer.Continuation { 'https://management.azure.com' }
        Mock Send-ShrWorkItem -ModuleName SessionHostReplacer.Continuation {
            param($OperationId, $DelaySeconds, $Generation)
            $global:shrContinuationTest.Messages += @{ Id = $OperationId; Delay = $DelaySeconds; Generation = $Generation }
            $global:shrContinuationTest.Order += "send:$DelaySeconds"
            if ($global:shrContinuationTest.FailDelay -eq $DelaySeconds) { throw 'queue unavailable' }
        }
        $workItem = @{ SchemaVersion = 1; OperationId = ('a' * 32); Generation = 0 }
    }

    AfterAll {
        Remove-Variable shrContinuationTest -Scope Global -ErrorAction SilentlyContinue
        Remove-Module SessionHostReplacer -Force
    }

    It 'continues a waiting operation without throwing or completing it' {
        Invoke-ShrContinuation -WorkItem $workItem -CyclePath $cyclePath
        $global:shrContinuationTest.Cycles | Should Be 1
        $global:shrContinuationTest.Operation.State.Status | Should Be 'Running'
        $global:shrContinuationTest.Operation.State.LockOwner | Should Be ''
        @($global:shrContinuationTest.Messages | Where-Object Delay -eq 120).Count | Should Be 1
    }

    It 'checkpoints an intentional cleanup yield and resumes exact cleanup before the next engine run' {
        $global:shrContinuationTest.Action = {
            param($State, $Result)
            $State.CleanupIntent = @{
                Hosts = @(@{ SessionHostName = 'avd-03'; ResourceId = '/subscriptions/test/resourceGroups/hosts/providers/Microsoft.Compute/virtualMachines/vm-avd-03' })
                WaitForVMDeletion = $true; RemoveEntraDevice = $true; RemoveIntuneDevice = $false
            }
            Request-ShrWorkerYield -Message 'cleanup is pending'
        }
        Invoke-ShrContinuation -WorkItem $workItem -CyclePath $cyclePath
        $global:shrContinuationTest.Operation.State.Status | Should Be 'Running'
        $global:shrContinuationTest.Operation.State.Generation | Should Be 1
        $global:shrContinuationTest.Operation.State.CleanupIntent.Hosts[0].SessionHostName | Should Be 'avd-03'
        Mock Assert-SessionHostNamesAvailable -ModuleName SessionHostReplacer.Continuation {
            param($SessionHosts, $WaitForVMDeletion, $RemoveEntraDevice, $RemoveIntuneDevice)
            $SessionHosts[0].SessionHostName | Should Be 'avd-03'
            $SessionHosts[0].ResourceId | Should Be '/subscriptions/test/resourceGroups/hosts/providers/Microsoft.Compute/virtualMachines/vm-avd-03'
            [bool]$WaitForVMDeletion | Should Be $true
            $RemoveEntraDevice | Should Be $true
            $RemoveIntuneDevice | Should Be $false
            $global:shrContinuationTest.Order += 'cleanup'
            (Get-ShrWorkerState).CleanupIntent = $null
            Save-ShrContinuationCheckpoint
        }
        $global:shrContinuationTest.Action = {
            param($State, $Result)
            $State.CleanupIntent | Should BeNullOrEmpty
            $Result.Completed = $true
        }
        $global:shrContinuationTest.Order = @()
        $workItem.Generation = 1
        Invoke-ShrContinuation -WorkItem $workItem -CyclePath $cyclePath
        $global:shrContinuationTest.Order.IndexOf('send:600') |
            Should BeLessThan $global:shrContinuationTest.Order.IndexOf('cleanup')
        $global:shrContinuationTest.Order.IndexOf('cleanup') |
            Should BeLessThan $global:shrContinuationTest.Order.IndexOf('cycle')
        $global:shrContinuationTest.Operation.State.Status | Should Be 'Completed'
    }

    It 'does not mask a failed cleanup checkpoint as a normal yield' {
        $global:shrContinuationTest.FailCheckpointOnce = $true
        $global:shrContinuationTest.Action = {
            param($State, $Result)
            $State.CleanupIntent = @{ Hosts = @(@{ SessionHostName = 'avd-01'; ResourceId = '/vm/avd-01' }) }
            Request-ShrWorkerYield -Message 'cleanup is pending'
        }
        { Invoke-ShrContinuation -WorkItem $workItem -CyclePath $cyclePath } | Should Throw 'cleanup checkpoint unavailable'
        $global:shrContinuationTest.Operation.State.Status | Should Be 'NeedsAttention'
        @($global:shrContinuationTest.Messages | Where-Object Delay -eq 120).Count | Should Be 0
        $global:shrContinuationTest.Operation.State.CleanupIntent.Hosts[0].SessionHostName | Should Be 'avd-01'
    }

    It 'finishes checkpointed cleanup after initiation expiry without authorizing a new batch' {
        $global:shrContinuationTest.Operation.State.InitiationExpiresUtc = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')
        $global:shrContinuationTest.Operation.State.CleanupIntent = @{ Hosts = @(@{ SessionHostName = 'avd-01'; ResourceId = '/vm/avd-01' }) }
        Mock Assert-SessionHostNamesAvailable -ModuleName SessionHostReplacer.Continuation {
            $global:shrContinuationTest.Order += 'cleanup'
            (Get-ShrWorkerState).CleanupIntent = $null
            Save-ShrContinuationCheckpoint
        }
        Invoke-ShrContinuation -WorkItem $workItem -CyclePath $cyclePath
        $global:shrContinuationTest.Order | Should Contain 'cleanup'
        $global:shrContinuationTest.Cycles | Should Be 0
        $global:shrContinuationTest.Operation.State.Status | Should Be 'Completed'
    }

    It 'keeps a replayed cleanup wait running instead of invoking the engine or completing the operation' {
        $global:shrContinuationTest.Operation.State.CleanupIntent = @{ Hosts = @(@{ SessionHostName = 'avd-01'; ResourceId = '/vm/avd-01' }) }
        Mock Assert-SessionHostNamesAvailable -ModuleName SessionHostReplacer.Continuation {
            Request-ShrWorkerYield -Message 'cleanup is still pending'
        }
        Invoke-ShrContinuation -WorkItem $workItem -CyclePath $cyclePath
        $global:shrContinuationTest.Cycles | Should Be 0
        $global:shrContinuationTest.Operation.State.Status | Should Be 'Running'
        $global:shrContinuationTest.Operation.State.CleanupIntent | Should Not BeNullOrEmpty
        $global:shrContinuationTest.Operation.State.Generation | Should Be 1
    }

    It 'persists a crash watchdog before running the lifecycle engine' {
        Invoke-ShrContinuation -WorkItem $workItem -CyclePath $cyclePath
        $global:shrContinuationTest.Order.IndexOf('send:600') |
            Should BeLessThan $global:shrContinuationTest.Order.IndexOf('cycle')
        $global:shrContinuationTest.Saves[0].State.LockOwner | Should Not BeNullOrEmpty
        ([DateTimeOffset]$global:shrContinuationTest.Saves[0].State.LockExpiresUtc -
            [DateTimeOffset]::UtcNow).TotalMinutes | Should BeGreaterThan 29
    }

    It 'does not run the engine when the watchdog cannot be queued' {
        $global:shrContinuationTest.FailDelay = 600
        { Invoke-ShrContinuation -WorkItem $workItem -CyclePath $cyclePath } | Should Throw 'queue unavailable'
        $global:shrContinuationTest.Cycles | Should Be 0
        $global:shrContinuationTest.Operation.State.Status | Should Be 'NeedsAttention'
    }

    It 'completes only when the lifecycle engine explicitly reports readiness and cleanup complete' {
        $global:shrContinuationTest.Action = { param($State, $Result) $Result.Completed = $true }
        Invoke-ShrContinuation -WorkItem $workItem -CyclePath $cyclePath
        $global:shrContinuationTest.Operation.State.Status | Should Be 'Completed'
        @($global:shrContinuationTest.Messages | Where-Object Delay -eq 120).Count | Should Be 0
    }

    It 'ignores duplicate messages after completion' {
        $global:shrContinuationTest.Operation.State.Status = 'Completed'
        Invoke-ShrContinuation -WorkItem $workItem -CyclePath $cyclePath
        $global:shrContinuationTest.Cycles | Should Be 0
        $global:shrContinuationTest.Messages.Count | Should Be 0
        $global:shrContinuationTest.Saves.Count | Should Be 0
    }

    It 'discards a prior generation watchdog without producing more continuation chains' {
        $global:shrContinuationTest.Operation.State.Generation = 1
        Invoke-ShrContinuation -WorkItem $workItem -CyclePath $cyclePath
        $global:shrContinuationTest.Cycles | Should Be 0
        $global:shrContinuationTest.Messages.Count | Should Be 0
        $global:shrContinuationTest.Saves.Count | Should Be 0
    }

    It 'defers a next-generation message that arrives before its checkpoint commits' {
        $workItem.Generation = 1
        Invoke-ShrContinuation -WorkItem $workItem -CyclePath $cyclePath
        $global:shrContinuationTest.Cycles | Should Be 0
        $global:shrContinuationTest.Messages[0].Generation | Should Be 1
        $global:shrContinuationTest.Messages[0].Delay | Should Be 120
    }

    It 'advances one generation only after successfully queuing the successor' {
        Invoke-ShrContinuation -WorkItem $workItem -CyclePath $cyclePath
        $global:shrContinuationTest.Messages[0].Generation | Should Be 0
        $global:shrContinuationTest.Messages[-1].Generation | Should Be 1
        $global:shrContinuationTest.Operation.State.Generation | Should Be 1
    }

    It 'ignores messages for an earlier operation' {
        $workItem.OperationId = 'b' * 32
        Invoke-ShrContinuation -WorkItem $workItem -CyclePath $cyclePath
        $global:shrContinuationTest.Cycles | Should Be 0
        $global:shrContinuationTest.Saves.Count | Should Be 0
    }

    It 'defers duplicates while another worker owns the lease' {
        $global:shrContinuationTest.Operation.State.LockOwner = 'another-worker'
        $global:shrContinuationTest.Operation.State.LockExpiresUtc = [DateTimeOffset]::UtcNow.AddMinutes(20).ToString('o')
        Invoke-ShrContinuation -WorkItem $workItem -CyclePath $cyclePath
        $global:shrContinuationTest.Cycles | Should Be 0
        $global:shrContinuationTest.Messages[0].Delay | Should Be 120
        $global:shrContinuationTest.Saves.Count | Should Be 0
    }

    It 'defers an ETag acquisition loser without invoking the engine' {
        $global:shrContinuationTest.Conflict = $true
        Invoke-ShrContinuation -WorkItem $workItem -CyclePath $cyclePath
        $global:shrContinuationTest.Cycles | Should Be 0
        $global:shrContinuationTest.Messages[0].Delay | Should Be 120
    }

    It 'reacquires an expired crash lease' {
        $global:shrContinuationTest.Operation.State.LockOwner = 'crashed-worker'
        Invoke-ShrContinuation -WorkItem $workItem -CyclePath $cyclePath
        $global:shrContinuationTest.Cycles | Should Be 1
    }

    It 'stops an expired operation without changing its deadline or calling the engine' {
        $deadline = [DateTimeOffset]::UtcNow.AddHours(-1).ToString('o')
        $global:shrContinuationTest.Operation.State.DeadlineUtc = $deadline
        { Invoke-ShrContinuation -WorkItem $workItem -CyclePath $cyclePath } | Should Throw 'deadline expired'
        $global:shrContinuationTest.Cycles | Should Be 0
        $global:shrContinuationTest.Operation.State.Status | Should Be 'NeedsAttention'
        ([DateTimeOffset]$global:shrContinuationTest.Operation.State.DeadlineUtc) |
            Should Be ([DateTimeOffset]$deadline)
    }

    It 'stops when immutable configuration changes' {
        $global:shrContinuationTest.Operation.State.ConfigurationHash = 'old-configuration'
        { Invoke-ShrContinuation -WorkItem $workItem -CyclePath $cyclePath } | Should Throw 'configuration changed'
        $global:shrContinuationTest.Cycles | Should Be 0
    }

    It 'treats a bounded invocation timeout as continuation rather than operation failure' {
        $global:shrContinuationTest.Action = { throw [TimeoutException]::new('bounded wait') }
        Invoke-ShrContinuation -WorkItem $workItem -CyclePath $cyclePath
        $global:shrContinuationTest.Operation.State.Status | Should Be 'Running'
        $global:shrContinuationTest.Messages[-1].Delay | Should Be 120
    }

    It 'persists and surfaces unexpected lifecycle failures' {
        $global:shrContinuationTest.Action = { throw 'unsafe lifecycle state' }
        { Invoke-ShrContinuation -WorkItem $workItem -CyclePath $cyclePath } | Should Throw 'unsafe lifecycle state'
        $global:shrContinuationTest.Operation.State.Status | Should Be 'NeedsAttention'
        $global:shrContinuationTest.Operation.State.LastError | Should Be 'unsafe lifecycle state'
        $global:shrContinuationTest.Operation.State.LockOwner | Should Be ''
    }

    It 'does not initiate a replacement from an authorization delayed beyond its initiation window' {
        $global:shrContinuationTest.Operation.State.InitiationExpiresUtc = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')
        Invoke-ShrContinuation -WorkItem $workItem -CyclePath $cyclePath
        $global:shrContinuationTest.Cycles | Should Be 0
        $global:shrContinuationTest.Operation.State.Status | Should Be 'Completed'
    }

    It 'does not initiate new work while held' {
        $global:shrContinuationTest.Settings.InitiationEnabled = $false
        $global:shrContinuationTest.Operation.State.Status = 'Completed'
        Start-ShrContinuation
        $global:shrContinuationTest.Messages.Count | Should Be 0
        $global:shrContinuationTest.Saves.Count | Should Be 0
    }

    It 'still resumes existing work while initiation is held' {
        $global:shrContinuationTest.Settings.InitiationEnabled = $false
        Start-ShrContinuation
        $global:shrContinuationTest.Messages[0].Id | Should Be ('a' * 32)
        $global:shrContinuationTest.Saves.Count | Should Be 0
    }

    It 'does not silently restart an operation that needs attention' {
        $global:shrContinuationTest.Operation.State.Status = 'NeedsAttention'
        $global:shrContinuationTest.Operation.State.LastError = 'inspect capacity'
        { Start-ShrContinuation } | Should Throw 'requires operator recovery'
        $global:shrContinuationTest.Messages.Count | Should Be 0
    }

    It 'persists a fresh operation before queuing its first message' {
        $global:shrContinuationTest.Operation = $null
        Start-ShrContinuation
        $global:shrContinuationTest.Operation.State.Id | Should Match '^[a-f0-9]{32}$'
        $global:shrContinuationTest.Operation.State.Status | Should Be 'Running'
        $global:shrContinuationTest.Order[0] | Should Be 'save'
        $global:shrContinuationTest.Messages.Count | Should Be 1
    }

    It 'rejects invalid queue message schemas before accessing state' {
        $workItem.SchemaVersion = 2
        { Invoke-ShrContinuation -WorkItem $workItem -CyclePath $cyclePath } | Should Throw 'Invalid SHR'
        Assert-MockCalled Get-ShrOperation -ModuleName SessionHostReplacer.Continuation -Times 0 -Exactly -Scope It
    }
}

Describe 'SHR continuation deployment contract' {
    BeforeAll {
        $shrRoot = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer'
        $arm = Get-Content (Join-Path $shrRoot 'main.json') -Raw | ConvertFrom-Json
        $form = Get-Content (Join-Path $shrRoot 'uiFormDefinition.json') -Raw | ConvertFrom-Json
        $worker = $arm.resources.workerCode
        $factory = $worker.properties.template
        $appParameters = $arm.resources.functionApp.properties.parameters
        function Get-CompiledScriptText {
            param([string] $Reference)
            $match = [regex]::Match($Reference, "variables\('([^']+)'\)")
            if (-not $match.Success) { throw "Expected a compiled text variable: $Reference" }
            return $arm.variables.PSObject.Properties[$match.Groups[1].Value].Value
        }
    }

    It 'keeps continuation opt-in and persists initiation and operation deadline parameters' {
        $arm.parameters.enableQueueContinuation.defaultValue | Should Be $false
        $arm.parameters.initiationEnabled.defaultValue | Should Be $true
        $arm.parameters.continuationTimeoutHours.defaultValue | Should Be 72
        $arm.parameters.continuationTimeoutHours.minValue | Should Be 1
        $arm.parameters.continuationTimeoutHours.maxValue | Should Be 720
    }

    It 'deploys the queue worker only when enabled and after the shared code upload' {
        $worker.condition | Should Be "[parameters('enableQueueContinuation')]"
        $worker.dependsOn | Should Contain 'functionCode'
        $worker.properties.parameters.functionName.value | Should Be 'session-host-replacer-worker'
        $worker.properties.parameters.triggerType.value | Should Be 'queueTrigger'
        $worker.properties.parameters.queueName.value | Should Be 'shr-continuation'
        $worker.properties.parameters.connection.value | Should Be 'AzureWebJobsStorage'
    }

    It 'enables queue identity/networking while retaining the optional existing DNS-zone contract' {
        $appParameters.enableQueueStorage.value | Should Be "[parameters('enableQueueContinuation')]"
        $appParameters.azureQueuePrivateDnsZoneResourceId.value |
            Should Be "[parameters('azureQueuePrivateDnsZoneResourceId')]"
        $form.view.outputs.parameters.azureQueuePrivateDnsZoneResourceId | Should Match 'enableQueueContinuation'
        $form.view.outputs.parameters.azureQueuePrivateDnsZoneResourceId | Should Match 'enablePrivateDNSIntegration'
    }

    It 'disables a previously deployed worker on opt-out and keeps controls bound to deployment parameters' {
        $settings = $appParameters.functionAppAppSettings.value
        $settings | Should Match "'EnableQueueContinuation', 'value', string\(parameters\('enableQueueContinuation'\)\)"
        $settings | Should Match "'InitiationEnabled', 'value', string\(parameters\('initiationEnabled'\)\)"
        $settings | Should Match "'ContinuationTimeoutHours', 'value', string\(parameters\('continuationTimeoutHours'\)\)"
        $settings | Should Match "'AzureWebJobs\.session-host-replacer-worker\.Disabled', 'value', string\(not\(parameters\('enableQueueContinuation'\)\)\)"
    }

    It 'wires both delivery paths to the schedule app setting without changing the parameter default' {
        $arm.parameters.timerSchedule.defaultValue | Should Be '0 0,30 * * * *'
        $arm.resources.functionCode.properties.parameters.schedule.value | Should Be '%TimerSchedule%'
        $appParameters.functionAppAppSettings.value | Should Match "'TimerSchedule', 'value',"
        $appParameters.functionAppAppSettings.value | Should Match "trim\(parameters\('timerSchedule'\)\)"
        $appParameters.functionAppAppSettings.value | Should Match 'A timerTrigger requires a nonempty schedule'
        $form.view.outputs.parameters.timerSchedule | Should Not BeNullOrEmpty
    }

    It 'does not invalidate an approved operation when only its initiation schedule changes' {
        Import-Module $modulePath -Force
        try {
            InModuleScope SessionHostReplacer.Continuation {
                $previousSchedule = [Environment]::GetEnvironmentVariable('TimerSchedule')
                try {
                    [Environment]::SetEnvironmentVariable('TimerSchedule', '0 0,30 * * * *')
                    $originalHash = Get-ShrConfigurationHash
                    $originalHash | Should Match '^[A-Fa-f0-9]{64}$'
                    [Environment]::SetEnvironmentVariable('TimerSchedule', '0 0,30 17,19,21,1,4 * * *')
                    Get-ShrConfigurationHash | Should Be $originalHash
                } finally {
                    [Environment]::SetEnvironmentVariable('TimerSchedule', $previousSchedule)
                }
            }
        } finally { Remove-Module SessionHostReplacer -Force }
    }

    It 'preserves timer defaults while requiring valid timer or queue trigger inputs' {
        $factory.parameters.triggerType.defaultValue | Should Be 'timerTrigger'
        $factory.parameters.triggerType.allowedValues | Should Contain 'queueTrigger'
        $factory.variables.triggerBinding | Should Match "'name', 'Timer'"
        $factory.variables.triggerBinding | Should Match "'name', 'WorkItem'"
        $factory.variables.triggerBinding | Should Match 'fail\('
        $factory.variables.triggerBinding | Should Match "trim\(parameters\('schedule'\)\)"
        $factory.variables.triggerBinding | Should Match "trim\(parameters\('queueName'\)\)"
    }

    It 'embeds the exact thin worker, shared engine and conditional legacy timer code' {
        $timerFiles = $arm.resources.functionCode.properties.parameters.files.value
        $match = [regex]::Match($timerFiles,
            "if\(parameters\('enableQueueContinuation'\), variables\('([^']+)'\), variables\('([^']+)'\)\)")
        $match.Success | Should Be $true
        $arm.variables.PSObject.Properties[$match.Groups[1].Value].Value |
            Should Be (Get-Content (Join-Path $shrRoot 'functions\scheduler.ps1') -Raw)
        $arm.variables.PSObject.Properties[$match.Groups[2].Value].Value |
            Should Be (Get-Content (Join-Path $shrRoot 'functions\run.ps1') -Raw)
        Get-CompiledScriptText $worker.properties.parameters.files.value.'run.ps1' |
            Should Be (Get-Content (Join-Path $shrRoot 'functions\worker.ps1') -Raw)
        Get-CompiledScriptText $arm.variables.sharedFunctionFiles.'../shr-cycle.ps1' |
            Should Be (Get-Content (Join-Path $shrRoot 'functions\run.ps1') -Raw)
    }

    It 'stages the queue extension-bundle host configuration only in the continuation shared-file branch' {
        $arm.variables.sharedFunctionFiles.'../host.json' | Should Match 'Microsoft.Azure.Functions.ExtensionBundle'
        $arm.resources.functionCode.properties.parameters.files.value |
            Should Match "if\(parameters\('enableQueueContinuation'\), variables\('sharedFunctionFiles'\), createObject\(\)\)"
    }
}

Describe 'SHR continuation storage protocol' {
    BeforeAll { Import-Module $modulePath -Force }
    AfterAll { Remove-Module SessionHostReplacer -Force }

    BeforeEach {
        $global:shrStorageRequests = @()
        $global:shrStorageStatus = 204
        Mock Invoke-ShrStorageRequest -ModuleName SessionHostReplacer.Continuation {
            param($Service, $Path, $Method, $Body, $ETag)
            $global:shrStorageRequests += @{
                Service = $Service; Path = $Path; Method = $Method; Body = $Body; ETag = $ETag
            }
            return @{ StatusCode = $global:shrStorageStatus; Headers = @{ ETag = @('version-2') } }
        }
    }

    AfterEach {
        Remove-Variable shrStorageRequests,shrStorageStatus -Scope Global -ErrorAction SilentlyContinue
    }

    It 'uses conditional replacement rather than wildcard table updates' {
        InModuleScope SessionHostReplacer.Continuation {
            $operation = @{ Key = 'key'; ETag = 'version-1'; State = @{ Id = 'operation' } }
            Save-ShrOperation -Operation $operation | Should Be $true
            $global:shrStorageRequests[0].Method | Should Be 'PUT'
            $global:shrStorageRequests[0].ETag | Should Be 'version-1'
            $operation.ETag | Should Be 'version-2'
        }
    }

    It 'reports compare-and-swap conflicts without unconditional overwrites' {
        InModuleScope SessionHostReplacer.Continuation {
            $global:shrStorageStatus = 412
            $operation = @{ Key = 'key'; ETag = 'version-1'; State = @{ Id = 'operation' } }
            Save-ShrOperation -Operation $operation -AllowConflict | Should Be $false
            { Save-ShrOperation -Operation $operation } | Should Throw 'ownership changed'
        }
    }

    It 'rejects oversized UTF-16 table properties before sending them' {
        InModuleScope SessionHostReplacer.Continuation {
            $operation = @{ Key = 'key'; ETag = 'version-1'; State = @{ Payload = ('x' * 31000) } }
            { Save-ShrOperation -Operation $operation } | Should Throw 'safe Table entity size'
            $global:shrStorageRequests.Count | Should Be 0
        }
    }

    It 'encodes queue messages as base64 JSON and schedules expected waits explicitly' {
        InModuleScope SessionHostReplacer.Continuation {
            Send-ShrWorkItem -OperationId ('a' * 32) -DelaySeconds 120
            $request = $global:shrStorageRequests[-1]
            $request.Path | Should Match 'visibilitytimeout=120&messagettl=604800'
            $xml = [xml]$request.Body
            $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($xml.QueueMessage.MessageText))
            $message = $json | ConvertFrom-Json
            $message.SchemaVersion | Should Be 1
            $message.OperationId | Should Be ('a' * 32)
        }
    }
}

    Describe 'SHR deterministic deployment replay' {
        BeforeAll { Import-Module $modulePath -Force }
        AfterAll { Remove-Module SessionHostReplacer -Force }
        BeforeEach {
            $global:shrReplayState = @{
                DeploymentIntent = @{
                    Name = 'shr_operation'
                    Uri = 'https://management.example.test/deployments/shr_operation'
                    Body = '{"properties":{"parameters":{"sessionHostNames":{"value":["avd-new"]}}}}'
                    HostNames = @('avd-new')
                    Timestamp = '20260101000000'
                }
                Status = 'Succeeded'
                Submitted = @()
            }
            Mock Get-ShrWorkerState -ModuleName SessionHostReplacer.Continuation { $global:shrReplayState }
            Mock Assert-ShrWorkerLease -ModuleName SessionHostReplacer.Continuation {}
            Mock Save-ShrContinuationCheckpoint -ModuleName SessionHostReplacer.Continuation {}
            Mock Invoke-AzureRestMethod -ModuleName SessionHostReplacer.Continuation {
                param($Method, $Uri, $Body)
                if ($Method -eq 'GET') {
                    if ($global:shrReplayState.Status -eq 'Absent') {
                        $exception = [Exception]::new('deployment absent')
                        $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([PSCustomObject]@{ StatusCode = 404 })
                        throw $exception
                    }
                    return [PSCustomObject]@{ properties = [PSCustomObject]@{
                        provisioningState = $global:shrReplayState.Status
                    } }
                }
                $global:shrReplayState.Submitted += @{ Uri = $Uri; Body = $Body }
            }
        }
        AfterEach { Remove-Variable shrReplayState -Scope Global -ErrorAction SilentlyContinue }

        It 'does not resubmit an accepted <Status> deployment after a lost response' -TestCases @(
            @{ Status = 'Succeeded' }
            @{ Status = 'Running' }
            @{ Status = 'Accepted' }
        ) {
            param($Status)
            $global:shrReplayState.Status = $Status
            $result = Invoke-ShrDeploymentIntent -ARMToken token
            $result.DeploymentName | Should Be 'shr_operation'
            $result.SessionHostCount | Should Be 1
            $global:shrReplayState.Submitted.Count | Should Be 0
        }

        It 'replays the exact persisted URI and body after interruption before ARM submission' {
            $global:shrReplayState.Status = 'Absent'
            Invoke-ShrDeploymentIntent -ARMToken token | Out-Null
            $global:shrReplayState.Submitted.Count | Should Be 1
            $global:shrReplayState.Submitted[0].Uri | Should Be $global:shrReplayState.DeploymentIntent.Uri
            $global:shrReplayState.Submitted[0].Body | Should Be $global:shrReplayState.DeploymentIntent.Body
        }

        It 'retries a failed deployment with the same operation name and host names' {
            $global:shrReplayState.Status = 'Failed'
            $result = Invoke-ShrDeploymentIntent -ARMToken token
            $result.SessionHostNames[0] | Should Be 'avd-new'
            $global:shrReplayState.Submitted[0].Uri | Should Match '/shr_operation$'
        }

        It 'checkpoints a deterministic retry of only unresolved names and aligned placement arrays' {
            $global:shrReplayState.Status = 'Absent'
            $intent = $global:shrReplayState.DeploymentIntent
            $intent.HostNames = @('avd-one', 'avd-two')
            $intent.Body = @{
                properties = @{
                    parameters = @{
                        sessionHostNames = @{ value = @('avd-one', 'avd-two') }
                        dedicatedHostResourceIds = @{ value = @('host-one', 'host-two') }
                        preferredZones = @{ value = @(@('1'), @('2', '3')) }
                    }
                }
            } | ConvertTo-Json -Depth 20 -Compress
            $result = Invoke-ShrDeploymentIntent -ARMToken token -RegisteredSessionHostNames @('avd-one')
            $result.DeploymentName | Should Be 'shr_operation_r1'
            $result.SessionHostCount | Should Be 1
            $body = $global:shrReplayState.Submitted[0].Body | ConvertFrom-Json
            @($body.properties.parameters.sessionHostNames.value).Count | Should Be 1
            $body.properties.parameters.sessionHostNames.value[0] | Should Be 'avd-two'
            $body.properties.parameters.dedicatedHostResourceIds.value[0] | Should Be 'host-two'
            $body.properties.parameters.preferredZones.value.Count | Should Be 1
            $body.properties.parameters.preferredZones.value[0].Count | Should Be 2
            Assert-MockCalled Save-ShrContinuationCheckpoint -ModuleName SessionHostReplacer.Continuation -Times 1 -Exactly -Scope It

            Invoke-ShrDeploymentIntent -ARMToken token -RegisteredSessionHostNames @('avd-one') | Out-Null
            $global:shrReplayState.Submitted[1].Uri | Should Be $global:shrReplayState.Submitted[0].Uri
            $global:shrReplayState.Submitted[1].Body | Should Be $global:shrReplayState.Submitted[0].Body
        }
    }

Describe 'SHR scaling handoff health gate' {
    BeforeAll {
        Import-Module $modulePath -Force
        $image = [PSCustomObject]@{ Definition = '/gallery/images/avd'; Version = '2.0.0' }
        $token = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes('/gallery/images/avd|2.0.0')
        )).ToLowerInvariant()
    }
    AfterAll { Remove-Module SessionHostReplacer -Force }
    BeforeEach {
        $hostInfo = [PSCustomObject]@{
            Status = 'Available'
            AllowNewSession = $true
            ImageDefinition = $image.Definition
            ImageVersion = $image.Version
            IncludeInAutomation = $true
            ShutdownTimestamp = $null
            Tags = @{ Validated = $token }
            SessionHostHealthCheckResults = @(
                [PSCustomObject]@{ healthCheckResult = 'HealthCheckSucceeded' }
            )
        }
    }

    It 'permits an online healthy exact-image host with persisted validation' {
        Test-SessionHostScalingRelease -SessionHost $hostInfo -LatestImageVersion $image `
            -TagValidatedImage Validated -TagShutdownTimestamp Retained | Should Be $true
    }

    It 'rejects <Condition> even when a cached validation marker exists' -TestCases @(
        @{ Condition = 'unhealthy status'; Field = 'Status'; Value = 'Unavailable' }
        @{ Condition = 'draining'; Field = 'AllowNewSession'; Value = $false }
        @{ Condition = 'different version'; Field = 'ImageVersion'; Value = '1.0.0' }
        @{ Condition = 'different definition'; Field = 'ImageDefinition'; Value = '/other/image' }
        @{ Condition = 'automation opt-out'; Field = 'IncludeInAutomation'; Value = $false }
        @{ Condition = 'shutdown retention'; Field = 'ShutdownTimestamp'; Value = '2026-01-01T00:00:00Z' }
    ) {
        param($Condition, $Field, $Value)
        $hostInfo.$Field = $Value
        Test-SessionHostScalingRelease -SessionHost $hostInfo -LatestImageVersion $image `
            -TagValidatedImage Validated -TagShutdownTimestamp Retained | Should Be $false
    }

    It 'rejects a failed health check despite Available status' {
        $hostInfo.SessionHostHealthCheckResults[0].healthCheckResult = 'HealthCheckFailed'
        Test-SessionHostScalingRelease -SessionHost $hostInfo -LatestImageVersion $image `
            -TagValidatedImage Validated -TagShutdownTimestamp Retained | Should Be $false
    }

    It 'preserves retention identified only by VM tag' {
        $hostInfo.Tags.Retained = '2026-01-01T00:00:00Z'
        Test-SessionHostScalingRelease -SessionHost $hostInfo -LatestImageVersion $image `
            -TagValidatedImage Validated -TagShutdownTimestamp Retained | Should Be $false
    }

    It 'rejects missing or stale exact-image evidence' {
        $hostInfo.Tags.Validated = 'stale'
        Test-SessionHostScalingRelease -SessionHost $hostInfo -LatestImageVersion $image `
            -TagValidatedImage Validated -TagShutdownTimestamp Retained | Should Be $false
    }
}

Describe 'SHR cross-module mutation guards' {
    BeforeAll { Import-Module $modulePath -Force }
    BeforeEach {
        $continuationModule = Get-Module SessionHostReplacer.Continuation -All
        & $continuationModule {
            $script:WorkerContext = @{
                Operation = @{ State = @{
                    Id = 'guard-test'
                    DeadlineUtc = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')
                } }
                InvocationDeadline = [DateTimeOffset]::UtcNow.AddMinutes(8)
            }
        }
    }
    AfterEach {
        & (Get-Module SessionHostReplacer.Continuation -All) { $script:WorkerContext = $null }
    }
    AfterAll { Remove-Module SessionHostReplacer -Force }

    It 'shares the worker context with exported lifecycle helpers' {
        (Get-ShrWorkerState).Id | Should Be 'guard-test'
        { Assert-ShrWorkerLease } | Should Throw 'deadline expired'
    }

    It 'interrupts an actual VM deletion wait at the invocation budget before issuing a resource read' {
        & (Get-Module SessionHostReplacer.Continuation -All) {
            $script:WorkerContext.Operation.State.DeadlineUtc = [DateTimeOffset]::UtcNow.AddHours(1).ToString('o')
            $script:WorkerContext.InvocationDeadline = [DateTimeOffset]::UtcNow.AddSeconds(-1)
        }
        Mock Invoke-AzureRestMethod -ModuleName SessionHostReplacer.DeviceCleanup { throw 'Unexpected resource read after the budget' }
        {
            Wait-SessionHostVMDeletions -ARMToken token -ResourceManagerUri 'http://127.0.0.1:1' `
                -SessionHosts @([PSCustomObject]@{ SessionHostName = 'avd-01'; ResourceId = '/vm/avd-01' })
        } | Should Throw 'invocation budget reached'
        Assert-MockCalled Invoke-AzureRestMethod -ModuleName SessionHostReplacer.DeviceCleanup -Times 0 -Exactly -Scope It
    }

    It 'blocks an ARM mutation before sending an HTTP request after the operation deadline' {
        { Invoke-AzureRestMethod -ARMToken token -Method DELETE -Uri 'http://127.0.0.1:1/guard-test' } |
            Should Throw 'deadline expired'
    }

    It 'blocks Graph mutation before sending an HTTP request after the operation deadline' {
        { Invoke-GraphRestMethod -GraphToken token -Method DELETE -Uri 'http://127.0.0.1:1/guard-test' } |
            Should Throw 'deadline expired'
    }

    It 'shares operation state with a real child script without mock-module scope rewriting' {
        $probePath = Join-Path $TestDrive 'worker-context.ps1'
        @'
param($Timer, $ContinuationContext, $CycleResult)
if (-not [Object]::ReferenceEquals($ContinuationContext, (Get-ShrWorkerState))) {
    throw 'The lifecycle engine cannot see the worker operation context.'
}
Save-ShrContinuationCheckpoint
$CycleResult.Completed = $true
'@ | Set-Content -LiteralPath $probePath -Encoding ascii
        $continuationModule = Get-Module SessionHostReplacer.Continuation -All
        $status = & $continuationModule {
            param($Path)
            $script:ProbeOperation = @{
                Key = 'key'; ETag = 'version'
                State = @{
                    Id = ('a' * 32); Status = 'Running'; ConfigurationHash = 'probe'
                    DeadlineUtc = [DateTimeOffset]::UtcNow.AddHours(1).ToString('o')
                    LockOwner = ''; LockExpiresUtc = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')
                    BatchHostNames = @('old'); Generation = 0
                }
            }
            function script:Get-ShrOperation { $script:ProbeOperation }
            function script:Save-ShrOperation { param($Operation) $script:ProbeOperation = $Operation; return $true }
            function script:Send-ShrWorkItem {}
            function script:Read-FunctionAppSetting { return $true }
            function script:Get-ShrConfigurationHash { return 'probe' }
            function script:Write-LogEntry {}
            Invoke-ShrContinuation -WorkItem @{ SchemaVersion = 1; OperationId = ('a' * 32); Generation = 0 } -CyclePath $Path
            return $script:ProbeOperation.State.Status
        } $probePath
        $status | Should Be 'Completed'
    }
}
