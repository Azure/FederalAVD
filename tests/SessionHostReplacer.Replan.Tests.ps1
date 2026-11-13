BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $modulePath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\functions\Modules\SessionHostReplacer\SessionHostReplacer.psd1'
    function Copy-ReplanValue {
        param($Value)
        $Value | ConvertTo-Json -Depth 50 -Compress | ConvertFrom-Json -AsHashtable
    }
    function New-ReplanHttpError {
        param([int] $Status)
        $httpException = [Exception]::new("HTTP $Status")
        $httpException | Add-Member -NotePropertyName Response -NotePropertyValue ([PSCustomObject]@{ StatusCode = $Status })
        return $httpException
    }
}

Describe 'SHR timer reconciliation of rejected batches' {
    BeforeAll {
        Import-Module $modulePath -Force
        $global:shrReplanCopy = ${function:Copy-ReplanValue}
        $global:shrReplanHttpError = ${function:New-ReplanHttpError}
    }
    BeforeEach {
        $script:replanCoordinator = Get-Module SessionHostReplacer.Continuation -All | Select-Object -First 1
        $settings = @{
            InitiationEnabled = 'True'; ReplacementMode = 'SideBySide'
            HostPoolSubscriptionId = 'subscription'; HostPoolResourceGroupName = 'rg-control'; HostPoolName = 'pool'
            VirtualMachinesSubscriptionId = 'subscription'; VirtualMachinesResourceGroupName = 'rg-hosts'
            TargetSessionHostCount = '10'
            SessionHostTemplate = '/subscriptions/subscription/resourceGroups/rg-ops/providers/Microsoft.Resources/templateSpecs/session-hosts'
            SessionHostParameters = '{"virtualMachineNameConv":"vm-SHNAME"}'
            Tag_PendingDrainTimestamp = 'Drain'; Tag_ShutdownTimestamp = 'Retained'; Tag_ScalingPlanExclusionTag = 'Scaling'
        }
        $script:originalReplanEnvironment = @{}
        foreach ($name in $settings.Keys) {
            $script:originalReplanEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $settings[$name])
        }
        $oldSettings = [Environment]::GetEnvironmentVariables()
        $oldRoot = '/subscriptions/subscription/resourceGroups/rg-ops/providers/Microsoft.Resources/templateSpecs/replacer'
        $oldSettings['SessionHostTemplate'] = $oldRoot
        $oldHash = & $script:replanCoordinator { param($Values) Get-ShrConfigurationHash -Settings $Values } $oldSettings
        $id = 'a' * 32
        $vmScope = '/subscriptions/subscription/resourceGroups/rg-hosts/providers/Microsoft.Compute/virtualMachines'
        $state = @{
            Id = $id; Status = 'NeedsAttention'; ConfigurationHash = $oldHash
            CreatedUtc = [DateTimeOffset]::UtcNow.AddHours(-1).ToString('o')
            DeadlineUtc = [DateTimeOffset]::UtcNow.AddHours(24).ToString('o')
            InitiationExpiresUtc = [DateTimeOffset]::UtcNow.AddHours(-1).ToString('o')
            LockOwner = ''; LockExpiresUtc = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')
            Image = @{ Definition = '/gallery/images/avd'; Version = '1.0.0' }
            BatchNumber = 1; BatchHostNames = @(); DeploymentHostNames = @('avd04', 'avd05')
            DeploymentBatchReady = $false; MoreDeploymentsAllowed = $false
            CleanupIntent = $null; Generation = 0
            LastError = 'Response status code does not indicate success: 400 (Bad Request).'
            DeploymentIntent = @{
                Name = "shr_$id"
                Uri = "https://management.azure.com/subscriptions/subscription/resourceGroups/rg-hosts/providers/Microsoft.Resources/deployments/shr_${id}?api-version=2021-04-01"
                HostNames = @('avd04', 'avd05'); Timestamp = '20261102130100'
                Body = (@{
                    properties = @{
                        mode = 'Incremental'; templateLink = @{ id = "$oldRoot/versions/15.0.0" }
                        parameters = @{
                            sessionHostNames = @{ value = @('avd04', 'avd05') }
                            virtualMachineNameConv = @{ value = 'vm-SHNAME' }
                            subnetResourceId = @{ value = '/subnet' }
                        }
                    }
                } | ConvertTo-Json -Depth 20 -Compress)
            }
        }
        $global:shrReplanTest = @{
            Settings = $settings
            Operation = @{ Key = 'pool-key'; ETag = 'version-1'; State = $state }
            Archives = @{}; Writes = @(); Logs = @(); Reads = @()
            Conflict = ''; ArchiveFailure = $false; ImageFailure = $false; Idle = $false
            DeploymentResponse = 'Missing'; ReadFailure = ''; ReadStatus = 403
            OriginalSpec = @{
                id = "$oldRoot/versions/15.0.0"
                systemData = @{ lastModifiedAt = [DateTimeOffset]::UtcNow.AddDays(-1).ToString('o') }
                properties = @{ mainTemplate = @{ parameters = @{ functionAppName = @{ type = 'string' } } } }
            }
            Deployments = @(); Hosts = @()
            Vms = @(@{ id = "$vmScope/vm-avd01"; name = 'vm-avd01'; tags = @{} })
            Recovery = @{
                LastStatus = 'Failed'; LastDeploymentName = ''; ActiveMaintenanceRequestId = ''
                PendingHostMappings = (@{
                    avd04 = @{ VMName = 'vm-avd04'; ResourceId = "$vmScope/vm-avd04" }
                    avd05 = @{ VMName = 'vm-avd05'; ResourceId = "$vmScope/vm-avd05" }
                } | ConvertTo-Json -Depth 10 -Compress)
            }
        }
        Mock Read-FunctionAppSetting -ModuleName SessionHostReplacer.Continuation {
            param($SettingKey, [switch] $AsBoolean)
            $value = $global:shrReplanTest.Settings[$SettingKey]
            if ($AsBoolean) { return $value -eq 'True' }
            return $value
        }
        Mock Get-ShrOperation -ModuleName SessionHostReplacer.Continuation {
            param($SupersededOperationId)
            if ($SupersededOperationId) { return (& $global:shrReplanCopy $global:shrReplanTest.Archives[$SupersededOperationId]) }
            & $global:shrReplanCopy $global:shrReplanTest.Operation
        }
        Mock Save-ShrOperation -ModuleName SessionHostReplacer.Continuation {
            param($Operation, [switch] $Insert)
            $sim = $global:shrReplanTest
            if ($Operation.Key -like '*-superseded-*') {
                if ($sim.ArchiveFailure) { throw 'Archive unavailable' }
                if ($sim.Archives.ContainsKey($Operation.State.Id)) { return $false }
                $sim.Archives[$Operation.State.Id] = & $global:shrReplanCopy $Operation
                $sim.Writes += 'archive'
                return $true
            }
            $step = if ($Operation.State.Status -eq 'Superseded') { 'supersede' } else { 'new-operation' }
            if ($sim.Conflict -eq $step) { return $false }
            $Operation.ETag = [guid]::NewGuid().ToString()
            $sim.Operation = & $global:shrReplanCopy $Operation
            $sim.Writes += $step
            return $true
        }
        Mock Get-DeploymentState -ModuleName SessionHostReplacer.Continuation {
            param([switch] $ReadOnly)
            if (-not $ReadOnly) { throw 'Reconciliation must read recovery state without mutations.' }
            if ($global:shrReplanTest.ReadFailure -eq 'Table') { throw 'Table unavailable' }
            & $global:shrReplanCopy $global:shrReplanTest.Recovery
        }
        Mock Save-DeploymentState -ModuleName SessionHostReplacer.Continuation { throw 'Reconciliation cannot rewrite recovery mappings.' }
        Mock Get-AccessToken -ModuleName SessionHostReplacer.Continuation { 'test-token' }
        Mock Get-ResourceManagerUri -ModuleName SessionHostReplacer.Continuation { 'https://management.azure.com' }
        Mock Invoke-AzureRestMethod -ModuleName SessionHostReplacer.Continuation {
            param($Uri, $Method, [switch] $RequireCollection)
            $sim = $global:shrReplanTest
            if ($Method -ne 'Get') { throw 'Reconciliation must not mutate ARM resources.' }
            $sim.Reads += $Uri
            if ($Uri -like '*/templateSpecs/replacer/versions/*') { return (& $global:shrReplanCopy $sim.OriginalSpec) }
            if ($Uri -like '*/deployments/shr_*') {
                switch ($sim.DeploymentResponse) {
                    Missing { throw (& $global:shrReplanHttpError 404) }
                    Empty { return $null }
                    Forbidden { throw (& $global:shrReplanHttpError 403) }
                    Exists { return [PSCustomObject]@{ properties = @{ provisioningState = 'Failed' } } }
                }
            }
            if (-not $RequireCollection) { throw 'Inventory reads must require a collection envelope.' }
            $kind = if ($Uri -like '*/deployments?api-version=*') { 'Deployments' }
                elseif ($Uri -like '*/virtualMachines?api-version=*') { 'Vms' }
                elseif ($Uri -like '*/sessionHosts?api-version=*') { 'Hosts' }
                else { throw "Unexpected URI: $Uri" }
            if ($sim.ReadFailure -eq $kind) { throw (& $global:shrReplanHttpError $sim.ReadStatus) }
            $sim[$kind] | ForEach-Object { [PSCustomObject]$_ }
        }
        Mock Test-ShrPoolIdle -ModuleName SessionHostReplacer.Continuation { $global:shrReplanTest.Idle }
        Mock Get-ShrInitiationImage -ModuleName SessionHostReplacer.Continuation {
            if ($global:shrReplanTest.ImageFailure) { throw 'Image lookup unavailable' }
            @{ Definition = '/gallery/images/avd'; Version = '2.0.0'; Date = '2026-11-02T00:00:00Z' }
        }

        Mock Write-LogEntry -ModuleName SessionHostReplacer.Continuation {
            param($Message)
            $global:shrReplanTest.Logs += $Message
        }
    }
    AfterEach {
        foreach ($name in $script:originalReplanEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $script:originalReplanEnvironment[$name])
        }
        Remove-Variable shrReplanTest -Scope Global -ErrorAction SilentlyContinue
    }
    AfterAll {
        Remove-Module SessionHostReplacer -Force
        Remove-Variable shrReplanCopy,shrReplanHttpError -Scope Global
    }

    It 'automatically replaces the legacy rejected attempt using corrected settings and a fresh image' {
        $before = Copy-ReplanValue $global:shrReplanTest.Operation
        $recoveryBefore = $global:shrReplanTest.Recovery.PendingHostMappings
        Start-ShrContinuation
        $after = $global:shrReplanTest.Operation.State
        $after.Id | Should -Not -Be $before.State.Id
        $after.Status | Should -Be 'Running'
        $after.Image.Version | Should -Be '2.0.0'
        $after.SupersedesOperationId | Should -Be $before.State.Id

        $after.DeploymentIntent | Should -BeNullOrEmpty
        $global:shrReplanTest.Recovery.PendingHostMappings | Should -Be $recoveryBefore
        ($global:shrReplanTest.Writes -join ',') | Should -Be 'archive,supersede,new-operation'

        $archive = $global:shrReplanTest.Archives[$before.State.Id].State
        $archive.Status | Should -Be 'Superseded'
        $archive.PreviousState.Status | Should -Be 'NeedsAttention'
        $archive.PreviousState.DeploymentIntent.Body | Should -Be $before.State.DeploymentIntent.Body
        Assert-MockCalled Save-DeploymentState -ModuleName SessionHostReplacer.Continuation -Times 0 -Exactly -Scope It
    }

    It 'does not resume a superseded operation while fresh planning finds no work' {
        $global:shrReplanTest.Idle = $true
        Start-ShrContinuation
        $global:shrReplanTest.Operation.State.Status | Should -Be 'Superseded'
        $writes = $global:shrReplanTest.Writes.Count
        Invoke-ShrContinuation -CyclePath 'must-not-run'
        $global:shrReplanTest.Writes.Count | Should -Be $writes
    }

    It 'does not let the reconciliation timer supersede a stopped operation' {
        Invoke-ShrContinuation -CyclePath 'must-not-run'
        $global:shrReplanTest.Writes.Count | Should -Be 0
        $global:shrReplanTest.Reads.Count | Should -Be 0
        $global:shrReplanTest.Operation.State.Status | Should -Be 'NeedsAttention'
    }

    It 'can replan with old hosts only if they remain present, available and accepting sessions' {
        $global:shrReplanTest.Operation.State.BatchHostNames = @('avd01')
        $global:shrReplanTest.Hosts = @(@{
            name = 'pool/avd01.contoso.test'
            properties = @{ resourceId = $global:shrReplanTest.Vms[0].id; status = 'Available'; allowNewSession = $true }
        })
        Start-ShrContinuation
        $global:shrReplanTest.Operation.State.Status | Should -Be 'Running'
    }

    It 'remains idle when fresh planning finds no work' {
        $global:shrReplanTest.Idle = $true
        Start-ShrContinuation
        $global:shrReplanTest.Operation.State.Status | Should -Be 'Superseded'

    }

    It 'supports a failed configuration that pinned a Template Spec version directly' {
        $settings = [Environment]::GetEnvironmentVariables()
        $settings['SessionHostTemplate'] = '/subscriptions/subscription/resourceGroups/rg-ops/providers/Microsoft.Resources/templateSpecs/replacer/versions/15.0.0'
        $global:shrReplanTest.Operation.State.ConfigurationHash =
            & $script:replanCoordinator { param($Values) Get-ShrConfigurationHash -Settings $Values } $settings
        Start-ShrContinuation
        $global:shrReplanTest.Operation.State.Status | Should -Be 'Running'
    }

    It 'accepts inventory VMs without optional tags' {
        $global:shrReplanTest.Vms[0].tags = $null
        Start-ShrContinuation
        $global:shrReplanTest.Operation.State.Status | Should -Be 'Running'
    }

    It 'recovers a crash after archival but before superseding the active row' {
        $global:shrReplanTest.Conflict = 'supersede'
        Start-ShrContinuation
        $global:shrReplanTest.Operation.State.Status | Should -Be 'NeedsAttention'

        $global:shrReplanTest.Conflict = ''
        Start-ShrContinuation
        $global:shrReplanTest.Operation.State.Status | Should -Be 'Running'
        $global:shrReplanTest.Archives.Count | Should -Be 1
    }

    It 'recovers a crash after supersession without resuming the superseded operation' {
        $global:shrReplanTest.ImageFailure = $true
        { Start-ShrContinuation } | Should -Throw -ExpectedMessage '*Image lookup unavailable*'
        $global:shrReplanTest.Operation.State.Status | Should -Be 'Superseded'
        Invoke-ShrContinuation -CyclePath 'must-not-run'

        $global:shrReplanTest.ImageFailure = $false
        Start-ShrContinuation
        $global:shrReplanTest.Operation.State.Status | Should -Be 'Running'
    }

    It 'does not overwrite a concurrent new operation after supersession' {
        $global:shrReplanTest.Conflict = 'new-operation'
        Start-ShrContinuation
        $global:shrReplanTest.Operation.State.Status | Should -Be 'Superseded'

    }

    It 'fails closed if the audit cannot be saved' {
        $global:shrReplanTest.ArchiveFailure = $true
        { Start-ShrContinuation } | Should -Throw -ExpectedMessage '*Archive unavailable*'
        $global:shrReplanTest.Operation.State.Status | Should -Be 'NeedsAttention'

    }

    It 'refuses a conflicting archived snapshot rather than overwriting evidence' {
        $global:shrReplanTest.Archives['a' * 32] = @{ State = @{ SourceStateHash = 'different' } }
        { Start-ShrContinuation } | Should -Throw -ExpectedMessage '*archive differs*'
        $global:shrReplanTest.Operation.State.Status | Should -Be 'NeedsAttention'
    }

    It 'blocks <Name> without changing operation or recovery state' -TestCases @(
        @{ Name = 'held initiation'; Change = { $global:shrReplanTest.Settings.InitiationEnabled = 'False' } }
        @{ Name = 'DeleteFirst mode'; Change = { $global:shrReplanTest.Settings.ReplacementMode = 'DeleteFirst' } }
        @{ Name = 'a live worker lease'; Change = { $global:shrReplanTest.Operation.State.LockExpiresUtc = [DateTimeOffset]::UtcNow.AddMinutes(10).ToString('o') } }
        @{ Name = 'later batches'; Change = { $global:shrReplanTest.Operation.State.BatchNumber = 2 } }
        @{ Name = 'cleanup intent'; Change = { $global:shrReplanTest.Operation.State.CleanupIntent = @{ Hosts = @('old') } } }
        @{ Name = 'an uncheckpointed batch'; Change = { $global:shrReplanTest.Operation.State.BatchHostNames = $null } }
        @{ Name = 'completed deployment readiness'; Change = { $global:shrReplanTest.Operation.State.DeploymentBatchReady = $true } }
        @{ Name = 'another error type'; Change = { $global:shrReplanTest.Operation.State.LastError = 'HTTP 403' } }
        @{ Name = 'unchanged bad configuration'; Change = {
            $global:shrReplanTest.Operation.State.ConfigurationHash = & $script:replanCoordinator { Get-ShrConfigurationHash }
        } }
        @{ Name = 'other protected setting changes'; Change = {
            $global:shrReplanTest.Settings.TargetSessionHostCount = '11'
            [Environment]::SetEnvironmentVariable('TargetSessionHostCount', '11')
        } }
        @{ Name = 'a different deployment URI'; Change = { $global:shrReplanTest.Operation.State.DeploymentIntent.Uri = 'https://untrusted.example/deployment' } }
        @{ Name = 'a deployment record even when failed'; Change = { $global:shrReplanTest.DeploymentResponse = 'Exists' } }
        @{ Name = 'a related ARM deployment'; Change = { $global:shrReplanTest.Deployments = @(@{ name = "shr_$('a' * 32)_r1" }) } }
        @{ Name = 'an original template changed after the attempt'; Change = {
            $global:shrReplanTest.OriginalSpec.systemData.lastModifiedAt = [DateTimeOffset]::UtcNow.ToString('o')
        } }
        @{ Name = 'a possible non-submission HTTP 400'; Change = {
            $global:shrReplanTest.OriginalSpec.properties.mainTemplate.parameters = @{
                sessionHostNames = @{}; virtualMachineNameConv = @{}; subnetResourceId = @{}
            }
        } }
        @{ Name = 'other deployment recovery'; Change = { $global:shrReplanTest.Recovery.LastDeploymentName = 'older-deployment' } }
        @{ Name = 'an unmatched reservation'; Change = { $global:shrReplanTest.Recovery.PendingHostMappings = '{"avd99":{"VMName":"vm-avd99","ResourceId":"/other"}}' } }
        @{ Name = 'an existing VM with a naming convention'; Change = { $global:shrReplanTest.Vms += @{ id = '/subscriptions/subscription/resourceGroups/rg-hosts/providers/Microsoft.Compute/virtualMachines/vm-avd04'; name = 'vm-avd04' } } }
        @{ Name = 'an existing target registration'; Change = { $global:shrReplanTest.Hosts = @(@{ name = 'pool/avd04.contoso.test'; properties = @{ resourceId = '/some-vm' } }) } }
        @{ Name = 'a missing old batch host'; Change = { $global:shrReplanTest.Operation.State.BatchHostNames = @('old') } }
        @{ Name = 'drain tags'; Change = { $global:shrReplanTest.Vms[0].tags.Drain = '2026-11-02T00:00:00Z' } }
        @{ Name = 'retention tags'; Change = { $global:shrReplanTest.Vms[0].tags.Retained = '2026-11-02T00:00:00Z' } }
        @{ Name = 'SHR-owned exclusions'; Change = { $global:shrReplanTest.Vms[0].tags.Scaling = 'SessionHostReplacer' } }
    ) {
        param($Name, $Change)
        & $Change
        { Start-ShrContinuation } | Should -Throw -ExpectedMessage '*requires operator recovery*'
        $global:shrReplanTest.Writes.Count | Should -Be 0

    }

    It 'surfaces <Kind> read failures without interpreting them as absence' -TestCases @(
        @{ Kind = 'Table'; Status = 403 }
        @{ Kind = 'Deployments'; Status = 403 }
        @{ Kind = 'Vms'; Status = 500 }
        @{ Kind = 'Hosts'; Status = 404 }
    ) {
        param($Kind, $Status)
        $global:shrReplanTest.ReadFailure = $Kind
        $global:shrReplanTest.ReadStatus = $Status
        { Start-ShrContinuation } | Should -Throw
        $global:shrReplanTest.Writes.Count | Should -Be 0
    }

    It 'does not infer deployment absence from an empty successful response' {
        $global:shrReplanTest.DeploymentResponse = 'Empty'
        { Start-ShrContinuation } | Should -Throw -ExpectedMessage '*absence cannot be established*'
        $global:shrReplanTest.Writes.Count | Should -Be 0
    }

    It 'does not infer deployment absence from denied access' {
        $global:shrReplanTest.DeploymentResponse = 'Forbidden'
        { Start-ShrContinuation } | Should -Throw -ExpectedMessage '*HTTP 403*'
        $global:shrReplanTest.Writes.Count | Should -Be 0
    }

    It 'rejects malformed mapping JSON rather than resetting it' {
        $global:shrReplanTest.Recovery.PendingHostMappings = '[]'
        { Start-ShrContinuation } | Should -Throw -ExpectedMessage '*must be a JSON object*'
        $global:shrReplanTest.Writes.Count | Should -Be 0
    }

    It 'rejects malformed <Kind> inventory instead of proving absence' -TestCases @(
        @{ Kind = 'Deployments'; Value = @{ properties = @{} } }
        @{ Kind = 'Vms'; Value = @{ name = 'avd04' } }
        @{ Kind = 'Hosts'; Value = @{ name = 'pool/avd04.contoso.test'; properties = @{} } }
    ) {
        param($Kind, $Value)
        $global:shrReplanTest[$Kind] = @($Value)
        { Start-ShrContinuation } | Should -Throw -ExpectedMessage '*absence cannot be established*'
        $global:shrReplanTest.Writes.Count | Should -Be 0
    }

    It 'keeps <Status> old batch hosts with AllowNewSession=<AllowSessions> blocked' -TestCases @(
        @{ Status = 'Available'; AllowSessions = $false; VmExists = $true }
        @{ Status = 'Shutdown'; AllowSessions = $true; VmExists = $true }
        @{ Status = 'Available'; AllowSessions = $true; VmExists = $false }
    ) {
        param($Status, $AllowSessions, $VmExists)
        $global:shrReplanTest.Operation.State.BatchHostNames = @('avd01')
        $global:shrReplanTest.Hosts = @(@{
            name = 'pool/avd01.contoso.test'
            properties = @{ resourceId = $global:shrReplanTest.Vms[0].id; status = $Status; allowNewSession = $AllowSessions }
        })
        if (-not $VmExists) { $global:shrReplanTest.Vms = @() }
        { Start-ShrContinuation } | Should -Throw -ExpectedMessage '*requires operator recovery*'
        $global:shrReplanTest.Writes.Count | Should -Be 0
    }
}
