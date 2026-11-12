BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $modulePath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\functions\Modules\SessionHostReplacer\SessionHostReplacer.psd1'
}

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
            Saves = @()
            Logs = @()
            Conflict = $false
            Action = $null
            Authorization = $null
            AuthorizationSaves = @()
            FailCheckpointOnce = $false
            Settings = @{
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
        Mock Test-ShrPoolIdle -ModuleName SessionHostReplacer.Continuation { $false }
        Mock Write-LogEntry -ModuleName SessionHostReplacer.Continuation {
            param($Message)
            $global:shrContinuationTest.Logs += $Message
        }
        Mock Get-ShrOperation -ModuleName SessionHostReplacer.Continuation {
            param([switch] $BatchAuthorization)
            if ($BatchAuthorization) { return $global:shrContinuationTest.Authorization }
            if ($global:shrContinuationTest.Operation) {
                $global:shrContinuationTest.Operation | ConvertTo-Json -Depth 40 |
                    ConvertFrom-Json -AsHashtable
            }
        }
        Mock Save-ShrOperation -ModuleName SessionHostReplacer.Continuation {
            param($Operation)
            if ($global:shrContinuationTest.Conflict) { return $false }
            if ($Operation.Key -like '*-initiation') {
                $global:shrContinuationTest.Authorization = $Operation
                $global:shrContinuationTest.AuthorizationSaves += $Operation
                return $true
            }
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

    }

    AfterAll {
        Remove-Variable shrContinuationTest -Scope Global -ErrorAction SilentlyContinue
        Remove-Module SessionHostReplacer -Force
    }

    It 'continues a waiting operation without throwing or completing it' {
        Invoke-ShrContinuation -CyclePath $cyclePath
        $global:shrContinuationTest.Cycles | Should -Be 1
        $global:shrContinuationTest.Operation.State.Status | Should -Be 'Running'
        $global:shrContinuationTest.Operation.State.LockOwner | Should -Be ''

    }

    It 'does only the operation read when no work is active' {
        $global:shrContinuationTest.Operation = $null
        Invoke-ShrContinuation -CyclePath $cyclePath
        $global:shrContinuationTest.Cycles | Should -Be 0
        $global:shrContinuationTest.Saves.Count | Should -Be 0
        Assert-MockCalled Get-ShrOperation -ModuleName SessionHostReplacer.Continuation -Times 1 -Exactly -Scope It
        Assert-MockCalled Get-ShrInitiationImage -ModuleName SessionHostReplacer.Continuation -Times 0 -Exactly -Scope It
        Assert-MockCalled Get-ShrConfigurationHash -ModuleName SessionHostReplacer.Continuation -Times 0 -Exactly -Scope It
    }

    It 'continues authorized work between sparse initiation ticks while initiation is held' {
        $global:shrContinuationTest.Settings.TimerSchedule = '0 0 1 * * 1'
        $global:shrContinuationTest.Settings.InitiationEnabled = $false
        $state = $global:shrContinuationTest.Operation.State
        $state.BatchHostNames = @('avd-old')
        $state.InitiationExpiresUtc = [DateTimeOffset]::UtcNow.AddHours(-2).ToString('o')
        $state.Image = @{ Definition = '/gallery/images/avd'; Version = '1.0.0' }
        $state.Generation = 17
        $deadline = [DateTimeOffset]$state.DeadlineUtc
        Invoke-ShrContinuation -CyclePath $cyclePath
        Invoke-ShrContinuation -CyclePath $cyclePath
        $global:shrContinuationTest.Cycles | Should -Be 2
        $after = $global:shrContinuationTest.Operation.State
        $after.Image.Version | Should -Be '1.0.0'
        $after.Generation | Should -Be 17
        ([DateTimeOffset]$after.DeadlineUtc) | Should -Be $deadline
        $after.NextBatchAuthorization | Should -BeNullOrEmpty
        $global:shrContinuationTest.AuthorizationSaves.Count | Should -Be 0
        Assert-MockCalled Get-ShrInitiationImage -ModuleName SessionHostReplacer.Continuation -Times 0 -Exactly -Scope It
    }

    It 'retries a transient state read on the next timer tick without rewriting the operation' {
        Mock Get-ShrOperation -ModuleName SessionHostReplacer.Continuation { throw 'Table unavailable' }
        { Invoke-ShrContinuation -CyclePath $cyclePath } | Should -Throw -ExpectedMessage '*Table unavailable*'
        $global:shrContinuationTest.Saves.Count | Should -Be 0
        $global:shrContinuationTest.Operation.State.Status | Should -Be 'Running'
        Mock Get-ShrOperation -ModuleName SessionHostReplacer.Continuation {
            $global:shrContinuationTest.Operation | ConvertTo-Json -Depth 40 | ConvertFrom-Json -AsHashtable
        }
        Invoke-ShrContinuation -CyclePath $cyclePath
        $global:shrContinuationTest.Cycles | Should -Be 1
    }

    It 'fails closed on an unrecognized durable status' {
        $global:shrContinuationTest.Operation.State.Status = 'Unknown'
        { Invoke-ShrContinuation -CyclePath $cyclePath } | Should -Throw -ExpectedMessage '*Invalid SHR operation state*'
        $global:shrContinuationTest.Saves.Count | Should -Be 0
        $global:shrContinuationTest.Cycles | Should -Be 0
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
        Invoke-ShrContinuation -CyclePath $cyclePath
        $global:shrContinuationTest.Operation.State.Status | Should -Be 'Running'

        $global:shrContinuationTest.Operation.State.CleanupIntent.Hosts[0].SessionHostName | Should -Be 'avd-03'
        Mock Assert-SessionHostNamesAvailable -ModuleName SessionHostReplacer.Continuation {
            param($SessionHosts, $WaitForVMDeletion, $RemoveEntraDevice, $RemoveIntuneDevice)
            $SessionHosts[0].SessionHostName | Should -Be 'avd-03'
            $SessionHosts[0].ResourceId | Should -Be '/subscriptions/test/resourceGroups/hosts/providers/Microsoft.Compute/virtualMachines/vm-avd-03'
            [bool]$WaitForVMDeletion | Should -Be $true
            $RemoveEntraDevice | Should -Be $true
            $RemoveIntuneDevice | Should -Be $false
            $global:shrContinuationTest.Order += 'cleanup'
            (Get-ShrWorkerState).CleanupIntent = $null
            Save-ShrContinuationCheckpoint
        }
        $global:shrContinuationTest.Action = {
            param($State, $Result)
            $State.CleanupIntent | Should -BeNullOrEmpty
            $Result.Completed = $true
        }
        $global:shrContinuationTest.Order = @()
        Invoke-ShrContinuation -CyclePath $cyclePath

        $global:shrContinuationTest.Order.IndexOf('cleanup') |
            Should -BeLessThan $global:shrContinuationTest.Order.IndexOf('cycle')
        $global:shrContinuationTest.Operation.State.Status | Should -Be 'Completed'
    }

    It 'does not mask a failed cleanup checkpoint as a normal yield' {
        $global:shrContinuationTest.FailCheckpointOnce = $true
        $global:shrContinuationTest.Action = {
            param($State, $Result)
            $State.CleanupIntent = @{ Hosts = @(@{ SessionHostName = 'avd-01'; ResourceId = '/vm/avd-01' }) }
            Request-ShrWorkerYield -Message 'cleanup is pending'
        }
        { Invoke-ShrContinuation -CyclePath $cyclePath } | Should -Throw -ExpectedMessage '*cleanup checkpoint unavailable*'
        $global:shrContinuationTest.Operation.State.Status | Should -Be 'NeedsAttention'

        $global:shrContinuationTest.Operation.State.CleanupIntent.Hosts[0].SessionHostName | Should -Be 'avd-01'
    }

    It 'resumes exact retirement before cleanup and planning when the VM is <VMStatus>' -TestCases @(
        @{ VMStatus = 'Succeeded'; Deletes = 1 }
        @{ VMStatus = 'Deleting'; Deletes = 0 }
        @{ VMStatus = 'Absent'; Deletes = 0 }
    ) {
        param($VMStatus, $Deletes)
        $id = '/subscriptions/test/resourceGroups/hosts/providers/Microsoft.Compute/virtualMachines/vm-avd-01'
        $global:shrContinuationTest.VMStatus = $VMStatus
        $global:shrContinuationTest.Operation.State.CleanupIntent = @{
            Hosts = @(@{ SessionHostName = 'avd-01'; ResourceId = $id })
            VMDeletions = @($id)
            WaitForVMDeletion = $true
        }
        Mock Invoke-AzureRestMethod -ModuleName SessionHostReplacer.Continuation {
            param($Uri, $Method)
            $global:shrContinuationTest.Order += "vm-$Method"
            $Uri | Should -Match '/virtualMachines/vm-avd-01\?'
            if ($Method -eq 'GET') {
                if ($global:shrContinuationTest.VMStatus -eq 'Absent') {
                    $notFoundException = [Exception]::new('VM is absent')
                    $notFoundException | Add-Member Response ([PSCustomObject]@{ StatusCode = 404 })
                    throw $notFoundException
                }
                [PSCustomObject]@{
                    id = '/subscriptions/test/resourceGroups/hosts/providers/Microsoft.Compute/virtualMachines/vm-avd-01'
                    properties = @{ provisioningState = $global:shrContinuationTest.VMStatus }
                }
            }
        }
        Mock Assert-SessionHostNamesAvailable -ModuleName SessionHostReplacer.Continuation {
            $global:shrContinuationTest.Order += 'cleanup'
            (Get-ShrWorkerState).CleanupIntent = $null
        }
        $global:shrContinuationTest.Action = { param($State, $Result) $Result.Completed = $true }
        Invoke-ShrContinuation -CyclePath $cyclePath
        @($global:shrContinuationTest.Order | Where-Object { $_ -eq 'vm-DELETE' }).Count | Should -Be $Deletes
        $global:shrContinuationTest.Order.IndexOf('vm-GET') |
            Should -BeLessThan $global:shrContinuationTest.Order.IndexOf('cleanup')
        $global:shrContinuationTest.Order.IndexOf('cleanup') |
            Should -BeLessThan $global:shrContinuationTest.Order.IndexOf('cycle')
        $global:shrContinuationTest.Operation.State.Status | Should -Be 'Completed'
    }

    It 'does not abandon retirement or invoke planning after a VM deletion is denied' {
        $id = '/subscriptions/test/resourceGroups/hosts/providers/Microsoft.Compute/virtualMachines/vm-avd-01'
        $global:shrContinuationTest.Operation.State.CleanupIntent = @{
            Hosts = @(@{ SessionHostName = 'avd-01'; ResourceId = $id })
            VMDeletions = @($id)
        }
        Mock Invoke-AzureRestMethod -ModuleName SessionHostReplacer.Continuation {
            throw 'Retirement access denied'
        }
        { Invoke-ShrContinuation -CyclePath $cyclePath } | Should -Throw -ExpectedMessage '*Retirement access denied*'
        $global:shrContinuationTest.Cycles | Should -Be 0
        $global:shrContinuationTest.Operation.State.Status | Should -Be 'NeedsAttention'
        $global:shrContinuationTest.Operation.State.CleanupIntent.VMDeletions | Should -Be @($id)
    }
    It 'finishes checkpointed cleanup after initiation expiry without authorizing a new batch' {
        $global:shrContinuationTest.Operation.State.InitiationExpiresUtc = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')
        $global:shrContinuationTest.Operation.State.CleanupIntent = @{ Hosts = @(@{ SessionHostName = 'avd-01'; ResourceId = '/vm/avd-01' }) }
        Mock Assert-SessionHostNamesAvailable -ModuleName SessionHostReplacer.Continuation {
            $global:shrContinuationTest.Order += 'cleanup'
            (Get-ShrWorkerState).CleanupIntent = $null
            Save-ShrContinuationCheckpoint
        }
        Invoke-ShrContinuation -CyclePath $cyclePath
        $global:shrContinuationTest.Order | Should -Contain 'cleanup'
        $global:shrContinuationTest.Cycles | Should -Be 0
        $global:shrContinuationTest.Operation.State.Status | Should -Be 'Completed'
    }

    It 'keeps a replayed cleanup wait running instead of invoking the engine or completing the operation' {
        $global:shrContinuationTest.Operation.State.CleanupIntent = @{ Hosts = @(@{ SessionHostName = 'avd-01'; ResourceId = '/vm/avd-01' }) }
        Mock Assert-SessionHostNamesAvailable -ModuleName SessionHostReplacer.Continuation {
            Request-ShrWorkerYield -Message 'cleanup is still pending'
        }
        Invoke-ShrContinuation -CyclePath $cyclePath
        $global:shrContinuationTest.Cycles | Should -Be 0
        $global:shrContinuationTest.Operation.State.Status | Should -Be 'Running'
        $global:shrContinuationTest.Operation.State.CleanupIntent | Should -Not -BeNullOrEmpty

    }

    It 'persists the operation lease before running the lifecycle engine' {
        Invoke-ShrContinuation -CyclePath $cyclePath

        $global:shrContinuationTest.Saves[0].State.LockOwner | Should -Not -BeNullOrEmpty
        ([DateTimeOffset]$global:shrContinuationTest.Saves[0].State.LockExpiresUtc -
            [DateTimeOffset]::UtcNow).TotalMinutes | Should -BeGreaterThan 29
    }

    It 'completes only when the lifecycle engine explicitly reports readiness and cleanup complete' {
        $global:shrContinuationTest.Action = { param($State, $Result) $Result.Completed = $true }
        Invoke-ShrContinuation -CyclePath $cyclePath
        $global:shrContinuationTest.Operation.State.Status | Should -Be 'Completed'

    }

    It 'exits cheaply on reconciliation ticks after completion' {
        $global:shrContinuationTest.Operation.State.Status = 'Completed'
        Invoke-ShrContinuation -CyclePath $cyclePath
        $global:shrContinuationTest.Cycles | Should -Be 0

        $global:shrContinuationTest.Saves.Count | Should -Be 0
    }

    It 'defers duplicates while another worker owns the lease' {
        $global:shrContinuationTest.Operation.State.LockOwner = 'another-worker'
        $global:shrContinuationTest.Operation.State.LockExpiresUtc = [DateTimeOffset]::UtcNow.AddMinutes(20).ToString('o')
        Invoke-ShrContinuation -CyclePath $cyclePath
        $global:shrContinuationTest.Cycles | Should -Be 0

        $global:shrContinuationTest.Saves.Count | Should -Be 0
    }

    It 'defers an ETag acquisition loser without invoking the engine' {
        $global:shrContinuationTest.Conflict = $true
        Invoke-ShrContinuation -CyclePath $cyclePath
        $global:shrContinuationTest.Cycles | Should -Be 0

    }

    It 'reacquires an expired crash lease' {
        $global:shrContinuationTest.Operation.State.LockOwner = 'crashed-worker'
        Invoke-ShrContinuation -CyclePath $cyclePath
        $global:shrContinuationTest.Cycles | Should -Be 1
    }

    It 'stops an expired operation without changing its deadline or calling the engine' {
        $deadline = [DateTimeOffset]::UtcNow.AddHours(-1).ToString('o')
        $global:shrContinuationTest.Operation.State.DeadlineUtc = $deadline
        { Invoke-ShrContinuation -CyclePath $cyclePath } | Should -Throw -ExpectedMessage '*deadline expired*'
        $global:shrContinuationTest.Cycles | Should -Be 0
        $global:shrContinuationTest.Operation.State.Status | Should -Be 'NeedsAttention'
        ([DateTimeOffset]$global:shrContinuationTest.Operation.State.DeadlineUtc) |
            Should -Be ([DateTimeOffset]$deadline)
    }

    It 'stops when immutable configuration changes' {
        $global:shrContinuationTest.Operation.State.ConfigurationHash = 'old-configuration'
        { Invoke-ShrContinuation -CyclePath $cyclePath } | Should -Throw -ExpectedMessage '*configuration changed*'
        $global:shrContinuationTest.Cycles | Should -Be 0
    }

    It 'treats a bounded invocation timeout as continuation rather than operation failure' {
        $global:shrContinuationTest.Action = { throw [TimeoutException]::new('bounded wait') }
        Invoke-ShrContinuation -CyclePath $cyclePath
        $global:shrContinuationTest.Operation.State.Status | Should -Be 'Running'

    }

    It 'persists and surfaces unexpected lifecycle failures' {
        $global:shrContinuationTest.Action = { throw 'unsafe lifecycle state' }
        { Invoke-ShrContinuation -CyclePath $cyclePath } | Should -Throw -ExpectedMessage '*unsafe lifecycle state*'
        $global:shrContinuationTest.Operation.State.Status | Should -Be 'NeedsAttention'
        $global:shrContinuationTest.Operation.State.LastError | Should -Be 'unsafe lifecycle state'
        $global:shrContinuationTest.Operation.State.LockOwner | Should -Be ''
    }

    It 'does not initiate a replacement from an authorization delayed beyond its initiation window' {
        $global:shrContinuationTest.Operation.State.InitiationExpiresUtc = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')
        Invoke-ShrContinuation -CyclePath $cyclePath
        $global:shrContinuationTest.Cycles | Should -Be 0
        $global:shrContinuationTest.Operation.State.Status | Should -Be 'Completed'
    }

    It 'does not initiate new work while held' {
        $global:shrContinuationTest.Settings.InitiationEnabled = $false
        $global:shrContinuationTest.Operation.State.Status = 'Completed'
        Start-ShrContinuation

        $global:shrContinuationTest.Saves.Count | Should -Be 0
    }

    It 'does not persist an operation when the read-only preflight finds no work' {
        foreach ($previousState in @('Completed', 'Absent')) {
            if ($previousState -eq 'Absent') {
                $global:shrContinuationTest.Operation = $null
            } else {
                $global:shrContinuationTest.Operation.State.Status = 'Completed'
            }
            Mock Test-ShrPoolIdle -ModuleName SessionHostReplacer.Continuation { $true }
            Start-ShrContinuation
        }

        $global:shrContinuationTest.Saves.Count | Should -Be 0
        Assert-MockCalled Get-ShrOperation -ModuleName SessionHostReplacer.Continuation `
            -ParameterFilter { $EnsureTable } -Times 0 -Exactly -Scope It
    }

    It 'creates one durable operation from <PreviousState> when the preflight finds work' -TestCases @(
        @{ PreviousState = 'Completed' }
        @{ PreviousState = 'Absent' }
    ) {
        param($PreviousState)
        if ($PreviousState -eq 'Absent') {
            $global:shrContinuationTest.Operation = $null
        } else {
            $global:shrContinuationTest.Operation.State.Status = 'Completed'
        }
        Start-ShrContinuation
        $global:shrContinuationTest.Saves.Count | Should -Be 1

    }

    It 'does not overwrite an operation created by another timer during the idle check' {
        $global:shrContinuationTest.Operation = $null
        Mock Test-ShrPoolIdle -ModuleName SessionHostReplacer.Continuation {
            $global:shrContinuationTest.Operation = @{
                Key = 'key'; ETag = 'new-version'
                State = @{ Id = ('b' * 32); Status = 'Running' }
            }
            $false
        }
        Start-ShrContinuation
        $global:shrContinuationTest.Operation.State.Id | Should -Be ('b' * 32)

        $global:shrContinuationTest.Saves.Count | Should -Be 0
    }

    It 'surfaces an idle-check failure without recording a successful operation' {
        $global:shrContinuationTest.Operation.State.Status = 'Completed'
        Mock Test-ShrPoolIdle -ModuleName SessionHostReplacer.Continuation { throw 'inventory unavailable' }
        { Start-ShrContinuation } | Should -Throw -ExpectedMessage '*inventory unavailable*'

        $global:shrContinuationTest.Saves.Count | Should -Be 0
    }

    It 'still resumes existing work while initiation is held' {
        $global:shrContinuationTest.Settings.InitiationEnabled = $false
        Start-ShrContinuation

        $global:shrContinuationTest.Saves.Count | Should -Be 0
        Assert-MockCalled Test-ShrPoolIdle -ModuleName SessionHostReplacer.Continuation -Times 0 -Exactly -Scope It
    }

    It 'does not silently restart an operation that needs attention' {
        $global:shrContinuationTest.Operation.State.Status = 'NeedsAttention'
        $global:shrContinuationTest.Operation.State.LastError = 'inspect capacity'
        { Start-ShrContinuation } | Should -Throw -ExpectedMessage '*requires operator recovery*'

    }

    It 'authorizes another scheduled SideBySide deployment without changing a leased operation' {
        $global:shrContinuationTest.Settings.ReplacementMode = 'SideBySide'
        $state = $global:shrContinuationTest.Operation.State
        $state.BatchNumber = 1
        $state.DeploymentBatchReady = $true
        $state.MoreDeploymentsAllowed = $true
        $state.LockOwner = 'active-worker'
        $state.LockExpiresUtc = [DateTimeOffset]::UtcNow.AddMinutes(30).ToString('o')
        Start-ShrContinuation
        $global:shrContinuationTest.Authorization.State.OperationId | Should -Be $state.Id
        $global:shrContinuationTest.Authorization.State.AfterBatchNumber | Should -Be 1
        ([DateTimeOffset]$global:shrContinuationTest.Authorization.State.ExpiresUtc) |
            Should -BeGreaterThan ([DateTimeOffset]::UtcNow)
        $global:shrContinuationTest.Saves.Count | Should -Be 0
        $state.LockOwner | Should -Be 'active-worker'

    }

    It 'does not authorize extra batches while held, unhealthy, fully deployed or in DeleteFirst' {
        $state = $global:shrContinuationTest.Operation.State
        foreach ($scenario in @(
            @{ Mode = 'SideBySide'; Enabled = $false; Ready = $true; More = $true },
            @{ Mode = 'SideBySide'; Enabled = $true; Ready = $false; More = $true },
            @{ Mode = 'SideBySide'; Enabled = $true; Ready = $true; More = $false },
            @{ Mode = 'DeleteFirst'; Enabled = $true; Ready = $true; More = $true }
        )) {
            $global:shrContinuationTest.Settings.ReplacementMode = $scenario.Mode
            $global:shrContinuationTest.Settings.InitiationEnabled = $scenario.Enabled
            $state.DeploymentBatchReady = $scenario.Ready
            $state.MoreDeploymentsAllowed = $scenario.More
            Start-ShrContinuation
        }
        $global:shrContinuationTest.AuthorizationSaves.Count | Should -Be 0
        $global:shrContinuationTest.Saves.Count | Should -Be 0
    }

    It 'delivers a fresh scheduled authorization to the leased worker without resetting its deadline' {
        $global:shrContinuationTest.Settings.ReplacementMode = 'SideBySide'
        $state = $global:shrContinuationTest.Operation.State
        $state.BatchHostNames = @('old-01')
        $state.BatchNumber = 1
        $state.DeploymentBatchReady = $true
        $state.MoreDeploymentsAllowed = $true
        $deadline = $state.DeadlineUtc
        Start-ShrContinuation
        $global:shrContinuationTest.Action = {
            param($State, $Result)
            $State.NextBatchAuthorization.AfterBatchNumber | Should -Be 1
            $State.LastBatchAuthorizationId = $State.NextBatchAuthorization.Id
            $State.NextBatchAuthorization = $null
        }
        Invoke-ShrContinuation -CyclePath $cyclePath
        ([DateTimeOffset]$global:shrContinuationTest.Operation.State.DeadlineUtc).UtcTicks |
            Should -Be ([DateTimeOffset]$deadline).UtcTicks
        $global:shrContinuationTest.Operation.State.Status | Should -Be 'Running'
        $global:shrContinuationTest.Action = {
            param($State, $Result)
            $State.NextBatchAuthorization | Should -BeNullOrEmpty
        }
        Invoke-ShrContinuation -CyclePath $cyclePath
        $global:shrContinuationTest.Cycles | Should -Be 2
        $global:shrContinuationTest.AuthorizationSaves.Count | Should -Be 1
    }

    It 'does not use expired, obsolete-operation or obsolete-batch authorizations' {
        $global:shrContinuationTest.Settings.ReplacementMode = 'SideBySide'
        $state = $global:shrContinuationTest.Operation.State
        $state.BatchHostNames = @('old-01')
        $state.BatchNumber = 2
        $state.DeploymentBatchReady = $true
        $state.MoreDeploymentsAllowed = $true
        $global:shrContinuationTest.Action = {
            param($State, $Result)
            $State.NextBatchAuthorization | Should -BeNullOrEmpty
        }
        foreach ($request in @(
            @{ Id = 'expired'; OperationId = $state.Id; AfterBatchNumber = 2; ExpiresUtc = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o') },
            @{ Id = 'old-operation'; OperationId = ('b' * 32); AfterBatchNumber = 2; ExpiresUtc = [DateTimeOffset]::UtcNow.AddMinutes(5).ToString('o') },
            @{ Id = 'old-batch'; OperationId = $state.Id; AfterBatchNumber = 1; ExpiresUtc = [DateTimeOffset]::UtcNow.AddMinutes(5).ToString('o') }
        )) {
            $global:shrContinuationTest.Authorization = @{ State = $request }
            Invoke-ShrContinuation -CyclePath $cyclePath
        }
        $global:shrContinuationTest.Cycles | Should -Be 3
    }

    It 'revokes an unconsumed SideBySide authorization when initiation is held' {
        $global:shrContinuationTest.Settings.ReplacementMode = 'SideBySide'
        $global:shrContinuationTest.Settings.InitiationEnabled = $false
        $state = $global:shrContinuationTest.Operation.State
        $state.BatchHostNames = @('old')
        $state.DeploymentBatchReady = $true
        $state.MoreDeploymentsAllowed = $true
        $state.NextBatchAuthorization = @{ Id = 'previous'; ExpiresUtc = [DateTimeOffset]::UtcNow.AddMinutes(5).ToString('o') }
        $state.NextBatchAuthorized = $true
        $global:shrContinuationTest.Action = {
            param($State, $Result)
            $State.NextBatchAuthorization | Should -BeNullOrEmpty
            $State.NextBatchAuthorized | Should -Be $false
        }
        Invoke-ShrContinuation -CyclePath $cyclePath
        $global:shrContinuationTest.Cycles | Should -Be 1
        $global:shrContinuationTest.Operation.State.Status | Should -Be 'Running'
    }

    It 'surfaces an authorization storage failure without modifying the active operation' {
        $global:shrContinuationTest.Settings.ReplacementMode = 'SideBySide'
        $state = $global:shrContinuationTest.Operation.State
        $state.DeploymentBatchReady = $true
        $state.MoreDeploymentsAllowed = $true
        Mock Save-ShrOperation -ModuleName SessionHostReplacer.Continuation { throw 'authorization storage unavailable' }
        { Start-ShrContinuation } | Should -Throw -ExpectedMessage '*authorization storage unavailable*'
        $global:shrContinuationTest.Operation.State.Status | Should -Be 'Running'

    }

    It 'persists a fresh operation for the reconciliation timer' {
        $global:shrContinuationTest.Operation = $null
        Start-ShrContinuation
        $global:shrContinuationTest.Operation.State.Id | Should -Match '^[a-f0-9]{32}$'
        $global:shrContinuationTest.Operation.State.Status | Should -Be 'Running'
        $global:shrContinuationTest.Order[0] | Should -Be 'save'

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
            Save-ShrOperation -Operation $operation | Should -Be $true
            $global:shrStorageRequests[0].Method | Should -Be 'PUT'
            $global:shrStorageRequests[0].ETag | Should -Be 'version-1'
            $operation.ETag | Should -Be 'version-2'
        }
    }

    It 'reads scheduled batch authorization from a distinct pool-scoped table entity' {
        Mock Get-ShrOperationKey -ModuleName SessionHostReplacer.Continuation { 'pool-key' }
        Mock Invoke-ShrStorageRequest -ModuleName SessionHostReplacer.Continuation {
            param($Path)
            $Path | Should -Be "shrContinuation(PartitionKey='SHR',RowKey='pool-key-initiation')"
            @{ StatusCode = 200; Headers = @{ ETag = @('auth-version') }; Content = '{"State":"{\"Id\":\"request\"}"}' }
        }
        InModuleScope SessionHostReplacer.Continuation {
            $authorization = Get-ShrOperation -BatchAuthorization
            $authorization.Key | Should -Be 'pool-key-initiation'
            $authorization.ETag | Should -Be 'auth-version'
            $authorization.State.Id | Should -Be 'request'
        }
    }

    It 'reports compare-and-swap conflicts without unconditional overwrites' {
        InModuleScope SessionHostReplacer.Continuation {
            $global:shrStorageStatus = 412
            $operation = @{ Key = 'key'; ETag = 'version-1'; State = @{ Id = 'operation' } }
            Save-ShrOperation -Operation $operation -AllowConflict | Should -Be $false
            { Save-ShrOperation -Operation $operation } | Should -Throw -ExpectedMessage '*ownership changed*'
        }
    }

    It 'rejects oversized UTF-16 table properties before sending them' {
        InModuleScope SessionHostReplacer.Continuation {
            $operation = @{ Key = 'key'; ETag = 'version-1'; State = @{ Payload = ('x' * 31000) } }
            { Save-ShrOperation -Operation $operation } | Should -Throw -ExpectedMessage '*safe Table entity size*'
            $global:shrStorageRequests.Count | Should -Be 0
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
            $result.DeploymentName | Should -Be 'shr_operation'
            $result.SessionHostCount | Should -Be 1
            $global:shrReplayState.Submitted.Count | Should -Be 0
        }

        It 'replays the exact persisted URI and body after interruption before ARM submission' {
            $global:shrReplayState.Status = 'Absent'
            Invoke-ShrDeploymentIntent -ARMToken token | Out-Null
            $global:shrReplayState.Submitted.Count | Should -Be 1
            $global:shrReplayState.Submitted[0].Uri | Should -Be $global:shrReplayState.DeploymentIntent.Uri
            $global:shrReplayState.Submitted[0].Body | Should -Be $global:shrReplayState.DeploymentIntent.Body
        }

        It 'retries a failed deployment with the same operation name and host names' {
            $global:shrReplayState.Status = 'Failed'
            $result = Invoke-ShrDeploymentIntent -ARMToken token
            $result.SessionHostNames[0] | Should -Be 'avd-new'
            $global:shrReplayState.Submitted[0].Uri | Should -Match '/shr_operation$'
        }

        It 'blocks an oversized persisted retry without splitting or submitting its body' {
            $global:shrReplayState.Status = 'Absent'
            $global:shrReplayState.DeploymentIntent.HostNames = @(1..21 | ForEach-Object { "avd-$_" })
            $global:shrReplayState.DeploymentIntent.Body = @{
                properties = @{
                    parameters = @{
                        sessionHostNames = @{ value = $global:shrReplayState.DeploymentIntent.HostNames }
                    }
                }
            } | ConvertTo-Json -Depth 10 -Compress
            $originalBody = $global:shrReplayState.DeploymentIntent.Body
            { Invoke-ShrDeploymentIntent -ARMToken token -ImageReplicaDeploymentLimit 20 } |
                Should -Throw -ExpectedMessage '*exceeding the live image replica ceiling*'
            $global:shrReplayState.Submitted.Count | Should -Be 0
            $global:shrReplayState.DeploymentIntent.Body | Should -Be $originalBody
            Assert-MockCalled Save-ShrContinuationCheckpoint -ModuleName SessionHostReplacer.Continuation -Times 0 -Exactly -Scope It
        }

        It 'observes an already accepted deployment even when the current replica count is lower' {
            $global:shrReplayState.DeploymentIntent.HostNames = @(1..21 | ForEach-Object { "avd-$_" })
            $result = Invoke-ShrDeploymentIntent -ARMToken token -ImageReplicaDeploymentLimit 20
            $result.SessionHostCount | Should -Be 21
            $global:shrReplayState.Submitted.Count | Should -Be 0
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
            $result.DeploymentName | Should -Be 'shr_operation_r1'
            $result.SessionHostCount | Should -Be 1
            $body = $global:shrReplayState.Submitted[0].Body | ConvertFrom-Json
            @($body.properties.parameters.sessionHostNames.value).Count | Should -Be 1
            $body.properties.parameters.sessionHostNames.value[0] | Should -Be 'avd-two'
            $body.properties.parameters.dedicatedHostResourceIds.value[0] | Should -Be 'host-two'
            $body.properties.parameters.preferredZones.value.Count | Should -Be 1
            $body.properties.parameters.preferredZones.value[0].Count | Should -Be 2
            Assert-MockCalled Save-ShrContinuationCheckpoint -ModuleName SessionHostReplacer.Continuation -Times 1 -Exactly -Scope It

            Invoke-ShrDeploymentIntent -ARMToken token -RegisteredSessionHostNames @('avd-one') | Out-Null
            $global:shrReplayState.Submitted[1].Uri | Should -Be $global:shrReplayState.Submitted[0].Uri
            $global:shrReplayState.Submitted[1].Body | Should -Be $global:shrReplayState.Submitted[0].Body
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
            -TagValidatedImage Validated -TagShutdownTimestamp Retained | Should -Be $true
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
            -TagValidatedImage Validated -TagShutdownTimestamp Retained | Should -Be $false
    }

    It 'rejects a failed health check despite Available status' {
        $hostInfo.SessionHostHealthCheckResults[0].healthCheckResult = 'HealthCheckFailed'
        Test-SessionHostScalingRelease -SessionHost $hostInfo -LatestImageVersion $image `
            -TagValidatedImage Validated -TagShutdownTimestamp Retained | Should -Be $false
    }

    It 'preserves retention identified only by VM tag' {
        $hostInfo.Tags.Retained = '2026-01-01T00:00:00Z'
        Test-SessionHostScalingRelease -SessionHost $hostInfo -LatestImageVersion $image `
            -TagValidatedImage Validated -TagShutdownTimestamp Retained | Should -Be $false
    }

    It 'rejects missing or stale exact-image evidence' {
        $hostInfo.Tags.Validated = 'stale'
        Test-SessionHostScalingRelease -SessionHost $hostInfo -LatestImageVersion $image `
            -TagValidatedImage Validated -TagShutdownTimestamp Retained | Should -Be $false
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
        (Get-ShrWorkerState).Id | Should -Be 'guard-test'
        { Assert-ShrWorkerLease } | Should -Throw -ExpectedMessage '*deadline expired*'
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
        } | Should -Throw -ExpectedMessage '*invocation budget reached*'
        Assert-MockCalled Invoke-AzureRestMethod -ModuleName SessionHostReplacer.DeviceCleanup -Times 0 -Exactly -Scope It
    }

    It 'blocks an ARM mutation before sending an HTTP request after the operation deadline' {
        { Invoke-AzureRestMethod -ARMToken token -Method DELETE -Uri 'http://127.0.0.1:1/guard-test' } |
            Should -Throw -ExpectedMessage '*deadline expired*'
    }

    It 'blocks Graph mutation before sending an HTTP request after the operation deadline' {
        { Invoke-GraphRestMethod -GraphToken token -Method DELETE -Uri 'http://127.0.0.1:1/guard-test' } |
            Should -Throw -ExpectedMessage '*deadline expired*'
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
            function script:Read-FunctionAppSetting { return $true }
            function script:Get-ShrConfigurationHash { return 'probe' }
            function script:Write-LogEntry {}
            Invoke-ShrContinuation -CyclePath $Path
            return $script:ProbeOperation.State.Status
        } $probePath
        $status | Should -Be 'Completed'
    }
}
