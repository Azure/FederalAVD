BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $shrRoot = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer'
}

Describe 'SHR correlated cycle telemetry' {
    BeforeAll {
        Import-Module (Join-Path $shrRoot 'functions\Modules\SessionHostReplacer\SessionHostReplacer.psd1') -Force
    }
    BeforeEach {
        Clear-ShrLogContext
        $global:shrTelemetryMessages = @()
        $global:shrTelemetryState = @{
            Id = ('a' * 32); BatchNumber = 2; Status = 'Running'; TargetCount = 10
            CreatedUtc = [DateTimeOffset]::UtcNow.AddMinutes(-5).ToString('o'); DeadlineUtc = [DateTimeOffset]::UtcNow.AddDays(3).ToString('o')
            LockOwner = 'owner'; LockExpiresUtc = [DateTimeOffset]::UtcNow.AddMinutes(30).ToString('o')
            Image = @{ Version = '2.0.0'; Definition = '/gallery/images/avd' }
            DeploymentIntent = @{
                Name = 'shr_cycle_b2'
                Uri = 'https://management.azure.com/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Resources/deployments/shr_cycle_b2?api-version=2025-04-01&sig=SECRET-SHOULD-NOT-APPEAR'
                Body = '{"password":"SECRET-SHOULD-NOT-APPEAR"}'
                HostNames = @('avd-new')
            }
            LastError = 'SECRET-SHOULD-NOT-APPEAR'
            ConfigurationHash = 'SECRET-SHOULD-NOT-APPEAR'
        }
        Mock Read-FunctionAppSetting -ModuleName SessionHostReplacer.Core {
            param($SettingKey)
            if ($SettingKey -eq 'HostPoolName') { 'pool' } else { $true }
        }
        Mock Write-Host -ModuleName SessionHostReplacer.Core {
            param($Object)
            $global:shrTelemetryMessages += [string]$Object
        }
    }
    AfterEach { Clear-ShrLogContext }
    AfterAll {
        Remove-Variable shrTelemetryMessages,shrTelemetryState -Scope Global
        Remove-Module SessionHostReplacer -Force
    }

    It 'adds correlation before the original message without breaking legacy suffix parsers' {
        Set-ShrLogContext -Trigger Reconciliation -Operation $global:shrTelemetryState
        Write-LogEntry -Message 'ACTION | Deployed:2'
        $text = $global:shrTelemetryMessages[-1]
        $text | Should -Match '^\[pool\] \[Cycle:a{32}\] \[Batch:2\] \[Trigger:Reconciliation\]'
        [regex]::Match($text, 'ACTION \| (.+)$').Groups[1].Value | Should -Be 'Deployed:2'
        [regex]::Match($text, '\[([^\]]+)\]').Groups[1].Value | Should -Be 'pool'
    }

    It 'emits only safe scalar metadata and strips queries from deployment links' {
        Set-ShrLogContext -Trigger Reconciliation
        Write-ShrEvent -Event Waiting -State $global:shrTelemetryState
        $text = $global:shrTelemetryMessages[-1]
        $text | Should -Not -Match 'SECRET-SHOULD-NOT-APPEAR|HostNames|ConfigurationHash|LastError'
        $data = [regex]::Match($text, 'SHR_EVENT \| (\{.*\})$').Groups[1].Value | ConvertFrom-Json
        $data.SchemaVersion | Should -Be 1
        $data.CycleId | Should -Be ('a' * 32)
        $data.Batch | Should -Be 2
        $data.Target | Should -Be 10
        $data.ImageVersion | Should -Be '2.0.0'
        $data.ImageDefinition | Should -Be '/gallery/images/avd'
        $data.DeploymentResourceId | Should -Be '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Resources/deployments/shr_cycle_b2'
    }

    It 'accepts -<ParameterName> without overwriting a read-only automatic Event variable' -TestCases @(
        @{ ParameterName = 'EventName' }
        @{ ParameterName = 'Event' }
    ) {
        param($ParameterName)
        & (Get-Module SessionHostReplacer.Core -All) {
            param($Name, $State)
            Set-Variable -Name Event -Value 'automatic-event-probe' -Option ReadOnly,AllScope -Scope Script
            try {
                $parameters = @{ $Name = 'Waiting'; State = $State }
                Write-ShrEvent @parameters
                (Get-Variable -Name Event -Scope Script).Value | Should -Be 'automatic-event-probe'
            } finally {
                Remove-Variable -Name Event -Scope Script -Force
            }
        } $ParameterName $global:shrTelemetryState
        $global:shrTelemetryMessages.Count | Should -Be 1
        $data = [regex]::Match($global:shrTelemetryMessages[0], 'SHR_EVENT \| (\{.*\})$').Groups[1].Value | ConvertFrom-Json
        $data.Event | Should -Be 'Waiting'
        $data.SchemaVersion | Should -Be 1
        $data.PSObject.Properties.Name | Should -Not -Contain 'EventName'
    }

    It 'never produces a portal URL for non-resource deployment URIs' {
        $global:shrTelemetryState.DeploymentIntent.Uri = 'https://example.test/invalid?secret=value'
        Write-ShrEvent -Event Waiting -State $global:shrTelemetryState
        $data = [regex]::Match($global:shrTelemetryMessages[-1], 'SHR_EVENT \| (\{.*\})$').Groups[1].Value | ConvertFrom-Json
        $data.DeploymentResourceId | Should -Be ''
    }

    It 'identifies <Phase> rather than treating no action as cycle completion' -TestCases @(
        @{ Phase = 'WaitingForCleanup'; Kind = 'Cleanup' }
        @{ Phase = 'WaitingForDeployment'; Kind = 'Deployment' }
        @{ Phase = 'WaitingForHealth'; Kind = 'Health' }
        @{ Phase = 'WaitingForScheduledAuthorization'; Kind = 'Authorization' }
        @{ Phase = 'Draining'; Kind = 'Drain' }
        @{ Phase = 'WaitingForProgress'; Kind = 'Unknown' }
    ) {
        param($Phase, $Kind)
        $metrics = @{}
        switch ($Kind) {
            Cleanup { $global:shrTelemetryState.CleanupIntent = @{ Hosts = @('old') } }
            Deployment { $metrics.RunningDeployments = 1 }
            Health { $metrics.NewHostsTotal = 2; $metrics.NewHostsAvailable = 1; $metrics.NewHostsSafeToProceed = $false }
            Authorization {
                $global:shrTelemetryState.DeploymentBatchReady = $true
                $global:shrTelemetryState.MoreDeploymentsAllowed = $true
            }
            Drain { $metrics.InDrain = 3 }
        }
        Write-ShrEvent -Event Progress -State $global:shrTelemetryState -Metrics $metrics
        Write-ShrEvent -Event Waiting -State $global:shrTelemetryState
        $data = [regex]::Match($global:shrTelemetryMessages[-1], 'SHR_EVENT \| (\{.*\})$').Groups[1].Value | ConvertFrom-Json
        $data.Phase | Should -Be $Phase
        $data.Status | Should -Be 'Running'
    }

    It 'retains terminal status even when old counts still indicate work' -TestCases @(
        @{ Status = 'Completed' }
        @{ Status = 'NeedsAttention' }
        @{ Status = 'Superseded' }
    ) {
        param($Status)
        $global:shrTelemetryState.Status = $Status
        Write-ShrEvent -Event Waiting -State $global:shrTelemetryState -Metrics @{ InDrain = 3 }
        $data = [regex]::Match($global:shrTelemetryMessages[-1], 'SHR_EVENT \| (\{.*\})$').Groups[1].Value | ConvertFrom-Json
        $data.Phase | Should -Be $Status
    }

    It 'does not claim health is blocking when the configured threshold permits progress' {
        Write-ShrEvent -Event Progress -State $global:shrTelemetryState -Metrics @{
            NewHostsTotal = 10; NewHostsAvailable = 9; NewHostsSafeToProceed = $true; InDrain = 3
        }
        Write-ShrEvent -Event Waiting -State $global:shrTelemetryState
        $data = [regex]::Match($global:shrTelemetryMessages[-1], 'SHR_EVENT \| (\{.*\})$').Groups[1].Value | ConvertFrom-Json
        $data.Phase | Should -Be 'Draining'
    }

    It 'keeps repeated internal snapshots diagnostic while emitting one final cycle observation' {
        Mock Write-Verbose -ModuleName SessionHostReplacer.Core {}
        foreach ($eventName in @('Reconciling', 'Checkpoint', 'Progress', 'DeploymentObserved')) {
            Write-ShrEvent -Event $eventName -State $global:shrTelemetryState -Metrics @{ InDrain = 3 }
        }
        $global:shrTelemetryMessages.Count | Should -Be 0
        Assert-MockCalled Write-Verbose -ModuleName SessionHostReplacer.Core -Times 4 -Exactly -Scope It
        Write-ShrEvent -Event Waiting -State $global:shrTelemetryState
        $global:shrTelemetryMessages.Count | Should -Be 1
        $data = [regex]::Match($global:shrTelemetryMessages[0], 'SHR_EVENT \| (\{.*\})$').Groups[1].Value | ConvertFrom-Json
        $data.Phase | Should -Be 'Draining'
        $data.InDrain | Should -Be 3
    }

    It 'distinguishes an authorization that expired before work started from a completed batch' {
        $global:shrTelemetryState.Status = 'Completed'
        Write-ShrEvent -Event AuthorizationExpired -State $global:shrTelemetryState
        $global:shrTelemetryMessages[-1] | Should -Match '"Phase":"AuthorizationExpired"'
    }

    It 'describes a deadline stop without copying its potentially sensitive saved error' {
        $global:shrTelemetryState.Status = 'NeedsAttention'
        $global:shrTelemetryState.LastError = 'SHR operation deadline expired SECRET-SHOULD-NOT-APPEAR'
        Write-ShrEvent -Event NeedsAttention -State $global:shrTelemetryState
        $global:shrTelemetryMessages[-1] | Should -Not -Match 'SECRET-SHOULD-NOT-APPEAR'
        $global:shrTelemetryMessages[-1] | Should -Match 'Operation deadline expired; checked recovery is required'
    }

    It 'does not carry one operation metrics into another operation' {
        Write-ShrEvent -Event Progress -State $global:shrTelemetryState -Metrics @{ InDrain = 3 }
        $global:shrTelemetryState.Id = 'b' * 32
        Write-ShrEvent -Event Waiting -State $global:shrTelemetryState
        $global:shrTelemetryMessages[-1] | Should -Match '"Phase":"WaitingForProgress"'
    }

    It 'shares correlation with logging invoked from another nested module' {
        Set-ShrLogContext -Trigger Reconciliation -Operation $global:shrTelemetryState
        & (Get-Module SessionHostReplacer.Deployment -All) { Write-LogEntry -Message 'Deployment probe' }
        $global:shrTelemetryMessages[-1] | Should -Match '\[Cycle:a{32}\].*Deployment probe$'
    }

    It 'emits timer outcomes and clears context after a successful invocation' {
        Mock Start-ShrContinuation -ModuleName SessionHostReplacer.Continuation {
            Write-ShrEvent -Event Initiated -State $global:shrTelemetryState
        }
        Invoke-ShrTimer -Trigger Initiation
        ($global:shrTelemetryMessages -join "`n") | Should -Match 'SHR_TIMER.*"Event":"Started"'
        ($global:shrTelemetryMessages -join "`n") | Should -Match 'SHR_TIMER.*"Event":"Succeeded"'
        Write-LogEntry -Message 'Outside invocation'
        $global:shrTelemetryMessages[-1] | Should -Be '[pool] Outside invocation'
    }

    It 'records a failed timer without swallowing its exception or leaking context' {
        Mock Start-ShrContinuation -ModuleName SessionHostReplacer.Continuation { throw 'probe failure' }
        { Invoke-ShrTimer -Trigger Initiation } | Should -Throw -ExpectedMessage '*probe failure*'
        ($global:shrTelemetryMessages -join "`n") | Should -Match 'SHR_TIMER.*"Event":"Failed"'
        Write-LogEntry -Message 'Outside failed invocation'
        $global:shrTelemetryMessages[-1] | Should -Be '[pool] Outside failed invocation'
    }

    It 'emits no application logs for idle reconciliation with an old <Status> operation' -TestCases @(
        @{ Status = 'Completed' }
        @{ Status = 'Superseded' }
        @{ Status = 'Absent' }
    ) {
        param($Status)
        if ($Status -eq 'Absent') { $global:shrTelemetryState = $null }
        else { $global:shrTelemetryState.Status = $Status }
        Mock Get-ShrOperation -ModuleName SessionHostReplacer.Continuation {
            if ($global:shrTelemetryState) { @{ State = $global:shrTelemetryState } }
        }
        Mock Save-ShrOperation -ModuleName SessionHostReplacer.Continuation {}
        Invoke-ShrTimer -Trigger Reconciliation -CyclePath 'must-not-run'
        $global:shrTelemetryMessages.Count | Should -Be 0
        Assert-MockCalled Get-ShrOperation -ModuleName SessionHostReplacer.Continuation -Times 1 -Exactly -Scope It
        Assert-MockCalled Save-ShrOperation -ModuleName SessionHostReplacer.Continuation -Times 0 -Exactly -Scope It
        Write-LogEntry -Message 'Outside idle invocation'
        $global:shrTelemetryMessages[-1] | Should -Be '[pool] Outside idle invocation'
    }

    It 'reports state-lookup failures even before reconciliation activity can be determined' {
        Mock Get-ShrOperation -ModuleName SessionHostReplacer.Continuation { throw 'State lookup failed' }
        { Invoke-ShrTimer -Trigger Reconciliation -CyclePath 'must-not-run' } | Should -Throw -ExpectedMessage '*State lookup failed*'
        $global:shrTelemetryMessages.Count | Should -Be 1
        $global:shrTelemetryMessages[0] | Should -Match 'SHR_TIMER.*"Event":"Failed"'
        $global:shrTelemetryMessages[0] | Should -Not -Match '"Event":"Succeeded"'
        Write-LogEntry -Message 'Outside failed lookup'
        $global:shrTelemetryMessages[-1] | Should -Be '[pool] Outside failed lookup'
    }

    It 'keeps active lease waits visible without writing state or running the lifecycle engine' {
        Mock Get-ShrOperation -ModuleName SessionHostReplacer.Continuation { @{ State = $global:shrTelemetryState } }
        Mock Save-ShrOperation -ModuleName SessionHostReplacer.Continuation {}
        Invoke-ShrTimer -Trigger Reconciliation -CyclePath 'must-not-run'
        $global:shrTelemetryMessages.Count | Should -Be 3
        ($global:shrTelemetryMessages -join "`n") | Should -Match '"Event":"Started"'
        ($global:shrTelemetryMessages -join "`n") | Should -Match '"Event":"WaitingForLease"'
        ($global:shrTelemetryMessages -join "`n") | Should -Match '"Event":"Succeeded"'
        Assert-MockCalled Save-ShrOperation -ModuleName SessionHostReplacer.Continuation -Times 0 -Exactly -Scope It
    }

    It 'reports a stopped cycle without replaying the saved exception as a new error every minute' {
        $global:shrTelemetryState.Status = 'NeedsAttention'
        Mock Get-ShrOperation -ModuleName SessionHostReplacer.Continuation { @{ State = $global:shrTelemetryState } }
        Mock Save-ShrOperation -ModuleName SessionHostReplacer.Continuation {}
        Mock Write-Error -ModuleName SessionHostReplacer.Core {}
        Mock Write-Verbose -ModuleName SessionHostReplacer.Core {}
        Invoke-ShrTimer -Trigger Reconciliation -CyclePath 'must-not-run'
        $global:shrTelemetryMessages.Count | Should -Be 3
        @($global:shrTelemetryMessages | Where-Object { $_ -match '"Event":"NeedsAttention"' }).Count | Should -Be 1
        ($global:shrTelemetryMessages -join "`n") | Should -Not -Match 'SECRET-SHOULD-NOT-APPEAR'
        Assert-MockCalled Write-Error -ModuleName SessionHostReplacer.Core -Times 0 -Exactly -Scope It
        Assert-MockCalled Save-ShrOperation -ModuleName SessionHostReplacer.Continuation -Times 0 -Exactly -Scope It
    }

    It 'emits one persisted failure snapshot and still surfaces the original invocation failure' {
        $global:shrTelemetryState.LockOwner = ''
        $global:shrTelemetryState.BatchHostNames = @('host01')
        Mock Get-ShrOperation -ModuleName SessionHostReplacer.Continuation { @{ State = $global:shrTelemetryState } }
        Mock Save-ShrOperation -ModuleName SessionHostReplacer.Continuation { $true }
        Mock Get-ShrConfigurationHash -ModuleName SessionHostReplacer.Continuation { 'SECRET-SHOULD-NOT-APPEAR' }
        Mock Write-Error -ModuleName SessionHostReplacer.Core {}
        $path = Join-Path $TestDrive 'failed-cycle.ps1'
        Set-Content -LiteralPath $path -Value "param(`$Timer,`$ContinuationContext,`$CycleResult); throw 'probe cycle failure'"
        { Invoke-ShrTimer -Trigger Reconciliation -CyclePath $path } | Should -Throw -ExpectedMessage '*probe cycle failure*'
        $events = @($global:shrTelemetryMessages | Where-Object { $_ -match '"Event":"NeedsAttention"' })
        $events.Count | Should -Be 1
        $events[0] | Should -Match '"LeaseHeld":false'
        ($global:shrTelemetryMessages -join "`n") | Should -Match 'SHR_TIMER.*"Event":"Failed"'
        ($global:shrTelemetryMessages -join "`n") | Should -Not -Match 'SHR_TIMER.*"Event":"Succeeded"'
        Assert-MockCalled Write-Error -ModuleName SessionHostReplacer.Core -Times 1 -Exactly -Scope It
        Assert-MockCalled Save-ShrOperation -ModuleName SessionHostReplacer.Continuation -Times 2 -Exactly -Scope It
    }

    It 'does not overwrite expired authorization with a second generic completed event' {
        $global:shrTelemetryState.LockOwner = ''
        $global:shrTelemetryState.InitiationExpiresUtc = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')
        Mock Get-ShrOperation -ModuleName SessionHostReplacer.Continuation { @{ State = $global:shrTelemetryState } }
        Mock Save-ShrOperation -ModuleName SessionHostReplacer.Continuation { $true }
        Mock Get-ShrConfigurationHash -ModuleName SessionHostReplacer.Continuation { 'SECRET-SHOULD-NOT-APPEAR' }
        Invoke-ShrTimer -Trigger Reconciliation -CyclePath 'must-not-run'
        $events = @($global:shrTelemetryMessages | Where-Object { $_ -match 'SHR_EVENT' })
        $events.Count | Should -Be 1
        $events[0] | Should -Match '"Phase":"AuthorizationExpired"'
        $events[0] | Should -Match '"LeaseHeld":false'
        $global:shrTelemetryState.Status | Should -Be 'Completed'
    }

    It 'does not produce normal-level per-host chatter for 50 safely waiting hosts with <Sessions> sessions each' -TestCases @(
        @{ Sessions = 0 }
        @{ Sessions = 1 }
    ) {
        param($Sessions)
        Mock Write-Verbose -ModuleName SessionHostReplacer.Core {}
        Mock Invoke-AzureRestMethod -ModuleName SessionHostReplacer.Lifecycle { throw 'Unexpected Azure request while waiting.' }
        $hosts = @(1..50 | ForEach-Object {
            [pscustomobject]@{
                SessionHostName = "host$_"; FQDN = "host$_"; Sessions = $Sessions
                Tags = @{ scaling = 'SessionHostReplacer' }
                AllowNewSession = $false; PoweredOff = $false
                PendingDrainTimeStamp = [datetime]::UtcNow.AddMinutes(-1)
            }
        })
        $result = Remove-SessionHosts -ARMToken token -SessionHostsPendingDelete $hosts `
            -ResourceManagerUri 'https://management.azure.com' -HostPoolSubscriptionId sub `
            -ResourceGroupName rg -HostPoolName pool -ReplacementMode DeleteFirst `
            -MinimumDrainMinutes 60 -DrainGracePeriodHours 4 -EnableShutdownRetention $false `
            -TagPendingDrainTimeStamp drain -TagShutdownTimestamp shutdown -TagScalingPlanExclusionTag scaling -ClientId client
        $global:shrTelemetryMessages.Count | Should -Be 0
        $result.SuccessfulDeletions.Count | Should -Be 0
        $result.SuccessfulShutdowns.Count | Should -Be 0
        $result.FailedDeletions.Count | Should -Be 0
        Assert-MockCalled Write-Verbose -ModuleName SessionHostReplacer.Core -Times 250 -Scope It
        Assert-MockCalled Invoke-AzureRestMethod -ModuleName SessionHostReplacer.Lifecycle -Times 0 -Exactly -Scope It
    }
}

Describe 'SHR workbook cycle tracing contract' {
    BeforeAll {
        $book = Get-Content (Join-Path $shrRoot 'modules\workBook\workbookTemplate.json') -Raw | ConvertFrom-Json
        $operations = $book.items | Where-Object name -eq 'operations-page'
        function Get-WorkbookItem {
            param([string] $Name, $Items = $book.items)
            foreach ($item in $Items) {
                if ($item.name -eq $Name) { $item }
                if ($item.content.items) { Get-WorkbookItem -Name $Name -Items $item.content.items }
            }
        }
        $parameters = @(
            ($book.items | Where-Object name -eq 'parameters').content.parameters
            (Get-WorkbookItem 'cycle-selection').content.parameters
        )
    }

    It 'shows only host pool and time range as global workload controls' {
        $globalParameters = ($book.items | Where-Object name -eq 'parameters').content.parameters
        (@($globalParameters | Where-Object { -not $_.isHiddenWhenLocked }).name -join ',') |
            Should -Be 'HostPool,TimeRange'
        foreach ($parameter in $globalParameters) {
            ($parameter.PSObject.Properties.Name -contains 'isHidden') | Should -Be $false
        }
        @($parameters | Where-Object name -eq 'ApplicationInsights').Count | Should -Be 0
        $cycleSelection = Get-WorkbookItem 'cycle-selection'
        @($book.items | Where-Object name -eq 'cycle-selection').Count | Should -Be 0
        $cycleGroup = Get-WorkbookItem 'cycle-investigation'
        $cycleGroup.conditionalVisibility.parameterName | Should -Be 'InvestigationView'
        $cycleGroup.conditionalVisibility.value | Should -Be 'cycles'
        ($cycleSelection.content.parameters.name -join ',') | Should -Be 'Cycle,Invocation'
    }

    It 'discovers host pools and telemetry sources by workspace and resource identity' {
        $hostPool = $parameters | Where-Object name -eq 'HostPool'
        $hostPool.query | Should -Match 'properties.WorkspaceResourceId'
        $hostPool.query | Should -Match "tags\['cm-resource-parent'\]"
        $hostPool.query | Should -Match "value = PoolId"
        $hostPool.value | Should -Be '*'
        $sources = $parameters | Where-Object name -eq 'HostPoolSources'
        $sources.isHiddenWhenLocked | Should -Be $true
        $sources.multiSelect | Should -Be $false
        $sources.query | Should -Match "properties.WorkspaceResourceId"
        $sources.query | Should -Match "ParentResourceId =~ '\{HostPool\}'"
        $sources.query | Should -Match "Source = tolower\(id\)"
        $sources.query | Should -Match "make_list\(pack\('Source', Source, 'HostPoolName', HostPoolName\)\)"
        $sources.query | Should -Match 'value = tostring\(Sources\)'
        $sources.query | Should -Match 'selected = true'
        $sources.query | Should -Not -Match 'sessionhostreplacer|endswith|AppTraces|TimeRange'
        $warning = $book.items | Where-Object name -eq 'source-discovery-warning'
        $warning.conditionalVisibility.parameterName | Should -Be 'HostPoolSources'
        $warning.conditionalVisibility.value | Should -Be '[]'
        $warning.content.json | Should -Match 'Resource Graph access'
    }

    It 'opens Operations with KPIs consistency compact status and timer health without diagnostic logs' {
        $navigation = ($book.items | Where-Object name -eq 'page-navigation').content.parameters |
            Where-Object name -eq 'DashboardPage'
        $navigation.value | Should -Be 'operations'
        $expectedOrder = @(
            'kpi-header', 'kpi-tiles', 'inventory-freshness', 'consistency-header',
            'image-table', 'consistency-table', 'cycle-status', 'schedule-header', 'schedule-table'
        )
        ($operations.content.items.name | Select-Object -First $expectedOrder.Count) -join ',' |
            Should -Be ($expectedOrder -join ',')
        foreach ($name in @('cycle-summary', 'cycle-timeline', 'cycle-logs', 'run-history-table', 'errors-table')) {
            ($operations.content.items.name -contains $name) | Should -Be $false
        }
        (Get-WorkbookItem 'operations-trends').content.loadType | Should -Be 'explicit'
    }

    It 'separates investigation views while retaining the existing page navigation value' {
        $pageNavigation = ($book.items | Where-Object name -eq 'page-navigation').content.parameters[0]
        $pageNavigation.query | Should -Match '"invocations", "Investigation", false'
        $navigation = (Get-WorkbookItem 'investigation-navigation').content.parameters[0]
        $navigation.value | Should -Be 'invocations'
        foreach ($pair in @(
            @{ Name = 'invocation-investigation'; View = 'invocations' }
            @{ Name = 'cycle-investigation'; View = 'cycles' }
            @{ Name = 'error-investigation'; View = 'errors' }
        )) {
            $group = Get-WorkbookItem $pair.Name
            $group.conditionalVisibility.parameterName | Should -Be 'InvestigationView'
            $group.conditionalVisibility.value | Should -Be $pair.View
        }
        ((Get-WorkbookItem 'error-investigation').content.items.name -contains 'errors-table') | Should -Be $true
    }

    It 'keeps Operations status independent of hidden cycle filters and removes technical columns' {
        $status = (Get-WorkbookItem 'cycle-status').content.query
        $status | Should -Not -Match '\{Cycle\}|\{Invocation\}'
        $status | Should -Match 'arg_max\(timestamp, \*\) by HostPoolName, FunctionApp'
        $projection = [regex]::Match($status, '(?s)\| project \[''Host Pool''\] = HostPoolName,.*$').Value
        $projection | Should -Match 'Status|Activity|Reason|Last Observed'
        $projection | Should -Not -Match 'CycleId|Lease|Deadline|FunctionApp|Deployment'
        $timerProjection = [regex]::Match((Get-WorkbookItem 'schedule-table').content.query, '(?s)\| project \[''Host Pool''\] = HostPoolName,.*$').Value
        $timerProjection | Should -Match 'Last Completed|Role|Outcome'
        $timerProjection | Should -Not -Match 'FunctionApp|Last Started|Last Failure'
    }

    It 'aggregates observed KPI snapshots and labels image alignment and action counts honestly' {
        $kpi = (Get-WorkbookItem 'kpi-tiles').content.query
        $kpi | Should -Match 'summarize Total = sum\(Total\)'
        $kpi | Should -Match 'Observations = count\(\)'
        $kpi | Should -Match 'where Observations > 0'
        $consistency = (Get-WorkbookItem 'consistency-table').content
        $consistency.query | Should -Match 'iff\(ActiveHosts > 0'
        $consistency.query | Should -Match '% On Latest Image'
        $consistency.query | Should -Match 'Last Observed'
        (Get-WorkbookItem 'consistency-header').content.json | Should -Match 'does \*\*not\*\* establish host health'
        $mix = (Get-WorkbookItem 'consistency-pie').content
        $mix.title | Should -Match 'Engine Action Mix'
        $mix.query | Should -Not -Match '"Up to Date"'
    }

    It 'offers cycle and invocation selection with bounded queries and explicit all selections' {
        foreach ($name in @('Cycle', 'Invocation')) {
            $parameter = $parameters | Where-Object name -eq $name
            $parameter.value | Should -Be '*'
            $parameter.query | Should -Match 'timestamp \{TimeRange\}'
            ($parameter.crossComponentResources -contains '{WorkloadWorkspace}') | Should -Be $true
            $parameter.query | Should -Match "datatable\(value:string, label:string, selected:bool\)"
        }
        ($parameters | Where-Object name -eq 'Cycle').query | Should -Match '^[\s\S]*matches regex'
    }

    It 'scopes summaries and chronological timelines by the durable cycle rather than native operation ID' {
        foreach ($name in @('cycle-summary', 'cycle-timeline')) {
            $query = (Get-WorkbookItem $name).content.query
            $query | Should -Match "CycleId == '\{Cycle\}'"
            $query | Should -Not -Match "operation_Id == '\{Cycle\}'"
            $query | Should -Match 'Data.SchemaVersion'
        }
        (Get-WorkbookItem 'cycle-timeline').content.query |
            Should -Match 'order by Timestamp asc'
    }

    It 'can follow native invocation logs and exceptions without joining on an empty identity' {
        $query = (Get-WorkbookItem 'cycle-logs').content.query
        $query | Should -Match 'union traces, exceptions'
        $query | Should -Match "InvocationId == '\{Invocation\}'"
        $query | Should -Match "NativeKey !in \('inv:', 'op:'\)"
        $query | Should -Match 'Source, NativeKey'
        $query | Should -Match 'take 500'
    }

    It 'queries one deployed workspace rather than the resource-scoped Application Insights view' {
        $workspace = $parameters | Where-Object name -eq 'WorkloadWorkspace'
        $workspace.value | Should -Be '__SHR_WORKSPACE_RESOURCE_ID__'
        $workspace.isHiddenWhenLocked | Should -Be $true
        $workspace.multiSelect | Should -Be $false
        $picker = $parameters | Where-Object name -eq 'HostPoolSources'
        $picker.query | Should -Match 'properties.WorkspaceResourceId'
        $module = Get-Content (Join-Path $shrRoot 'modules\workBook\workbook.bicep') -Raw
        $module | Should -Match "replace\(string\(workbookTemplateWithFallback\), '__SHR_WORKSPACE_RESOURCE_ID__', logAnalyticsWorkspaceResourceId\)"
        $module | Should -Not -Match 'param applicationInsightsResourceId'
    }

    It 'scopes every telemetry query and nested selector to the workspace with component filtering' {
        function Assert-WorkspaceQuery {
            param($Node)
            if ($null -eq $Node) { return }
            if ($Node -is [array]) {
                foreach ($child in $Node) { Assert-WorkspaceQuery $child }
            } elseif ($Node -is [pscustomobject]) {
                $Node.resourceType | Should -Not -Be 'microsoft.insights/components'
                if ($Node.queryType -eq 0 -and $Node.query) {
                    $Node.resourceType | Should -Be 'microsoft.operationalinsights/workspaces'
                    ($Node.crossComponentResources -contains '{WorkloadWorkspace}') | Should -Be $true
                    @($Node.crossComponentResources).Count | Should -Be 1
                    $Node.query | Should -Not -Match '\b(FunctionAppLogs|AzureDiagnostics)\b|\b(app|workspace)\s*\('
                    if ($Node.query -match '\b(traces|requests|exceptions)\b') {
                        $Node.query | Should -Match '_ResourceId in~ \(poolSources\)'
                        $Node.query | Should -Match 'dynamic\(\{HostPoolSources\}\)'
                        $Node.query | Should -Match 'let poolSources = poolNames \| project Source'
                        $Node.query | Should -Match "split\('\{HostPool\}', '/'\)\[-1\]"
                        $Node.query | Should -Not -Match '\{ApplicationInsights\}'
                        $Node.query | Should -Match 'TimeGenerated \{TimeRange\}'
                        $Node.query | Should -Not -Match '\b(app|workspace)\('
                    }
                }
                foreach ($property in $Node.PSObject.Properties) {
                    if ($property.Value -is [array] -or $property.Value -is [pscustomobject]) {
                        Assert-WorkspaceQuery $property.Value
                    }
                }
            }
        }
        Assert-WorkspaceQuery $book
    }

    It 'normalizes workspace schemas without changing request duration units or resource identity' {
        $page = $book.items | Where-Object name -eq 'invocations-page'
        $history = (Get-WorkbookItem 'invocation-history').content.query
        $history | Should -Match 'let requests = AppRequests'
        $history | Should -Match 'duration = DurationMs'
        $history | Should -Match 'customDimensions = Properties'
        $history | Should -Match 'timestamp \+ \(duration \* 1ms\)'
        $history | Should -Match 'Source = tolower\(tostring\(_ResourceId\)\)'
    }

    It 'lists only current initiator and worker invocations including idle ticks' {
        $page = $book.items | Where-Object name -eq 'invocations-page'
        $page.conditionalVisibility.value | Should -Be 'invocations'
        $query = (Get-WorkbookItem 'invocation-history').content.query
        $query | Should -Match "FunctionName in \('session-host-replacer-initiator', 'session-host-replacer-worker'\)"
        $query | Should -Not -Match "'session-host-replacer'"
        $query | Should -Match 'arg_max\(timestamp, \*\) by Source, FunctionApp, FunctionName, InvocationKey'
        $query | Should -Match 'top 200'
        $query | Should -Match 'Outcome, DurationMs = duration'
        $query | Should -Not -Match 'SHR_TIMER|SHR_EVENT|\{Cycle\}|\{Invocation\}'
        $query | Should -Match "'Unavailable'"
    }

    It 'excludes the retired single-timer function from timer health and frequency views' {
        foreach ($name in @('schedule-table', 'frequency-chart')) {
            $query = (Get-WorkbookItem $name).content.query
            $query | Should -Match "FunctionName in \('session-host-replacer-initiator', 'session-host-replacer-worker'\)"
            $query | Should -Not -Match "'session-host-replacer'"
        }
    }

    It 'keeps native invocation and request identities distinct in the troubleshooting selector' {
        $page = $book.items | Where-Object name -eq 'invocations-page'
        $selector = (Get-WorkbookItem 'invocation-selection').content.parameters[0]
        $selector.name | Should -Be 'TroubleshootingInvocation'
        $selector.value | Should -Be '*'
        $selector.query | Should -Match "strcat\('inv:', InvocationId\)"
        $selector.query | Should -Match "strcat\('req:', id\)"
        $selector.query | Should -Match "strcat\(Source, '\|', InvocationKey\)"
        ($selector.crossComponentResources -contains '{WorkloadWorkspace}') | Should -Be $true
    }

    It 'drills into traces and exceptions with guarded correlation and bounded chronological output' {
        $page = $book.items | Where-Object name -eq 'invocations-page'
        $query = (Get-WorkbookItem 'invocation-logs').content.query
        $query | Should -Match 'let exceptions = AppExceptions'
        $query | Should -Match 'union withsource=RecordType traces, exceptions'
        $query | Should -Match "SelectionKey == '\{TroubleshootingInvocation\}'"
        $query | Should -Match 'join kind=inner selectedRun on Source'
        $query | Should -Match 'isnotempty\(SelectedInvocationId\)'
        $query | Should -Match 'isnotempty\(operation_Id\) and operation_Id == SelectedOperationId'
        $query | Should -Match 'take 500'
        $query | Should -Match 'order by Timestamp asc'
        $technical = Get-WorkbookItem 'invocation-technical-details'
        ($technical.content.items | Where-Object name -eq 'invocation-log-details').content.query |
            Should -Match 'Details = details'
    }

    It 'keeps invocation history and selection labels focused on the run rather than correlation IDs' {
        $page = $book.items | Where-Object name -eq 'invocations-page'
        $history = (Get-WorkbookItem 'invocation-history').content.query
        $projection = [regex]::Match($history, '(?s)\| project Timestamp = timestamp,.*$').Value
        $projection | Should -Match "\['Host Pool'\] = HostPoolName"
        $projection | Should -Match "Role = iff\(FunctionName == 'session-host-replacer-worker', 'Worker', 'Initiator'\)"
        $projection | Should -Match 'Outcome, DurationMs = duration'
        $projection | Should -Not -Match 'FunctionApp|InvocationId|RequestId|NativeOperationId|RoleInstance|ResultCode|CompletedUtc'
        $selector = (Get-WorkbookItem 'invocation-selection').content.parameters[0]
        $label = [regex]::Match($selector.query, '(?s)label = strcat\(format_datetime.*?, selected = false').Value
        $label | Should -Not -Match 'FunctionApp|InvocationKey|InvocationId|RequestId|NativeOperationId'
        $label | Should -Match "'Worker', 'Initiator'"
        $label | Should -Match 'tostring\(duration\)'
    }

    It 'shows only Timestamp Level and Message in both normal log views' {
        $page = $book.items | Where-Object name -eq 'invocations-page'
        $logItems = @(
            Get-WorkbookItem 'cycle-logs'
            Get-WorkbookItem 'invocation-logs'
        )
        foreach ($item in $logItems) {
            $projection = [regex]::Match($item.content.query, '(?s)\| project Timestamp = timestamp,.*?\| order by Timestamp desc').Value
            $projection | Should -Match 'Level = case\(severityLevel == 0'
            $projection | Should -Match "severityLevel == 2, 'Warning', severityLevel == 3, 'Error'"
            $projection | Should -Match "severityLevel == 4, 'Critical', 'Unknown'"
            $projection | Should -Match 'Message = coalesce\(message, outerMessage, innermostMessage\)'
            $projection | Should -Not -Match 'InvocationId|operation_Id|CycleId|HostPoolName|RecordType|Details|RoleInstance'
            $item.content.query | Should -Match 'take 500'
            $item.content.query | Should -Match 'order by Timestamp asc'
            $formatter = $item.content.gridSettings.formatters | Where-Object columnMatch -eq 'Message'
            $formatter.formatOptions.linkTarget | Should -Be 'GenericDetails'
        }
    }

    It 'keeps full request and exception details in explicit-load groups with the same correlation inputs' {
        $page = $book.items | Where-Object name -eq 'invocations-page'
        $technical = Get-WorkbookItem 'invocation-technical-details'
        $cycleTechnical = Get-WorkbookItem 'cycle-technical-details'
        foreach ($group in @($technical, $cycleTechnical)) {
            $group.content.loadType | Should -Be 'explicit'
            $group.content.loadButtonText | Should -Match '^Show technical'
        }
        $details = ($technical.content.items | Where-Object name -eq 'invocation-details').content.query
        $details | Should -Match 'InvocationId, RequestId = id, NativeOperationId = operation_Id'
        $details | Should -Match 'ResultCode = resultCode'
        $queries = @(
            @{ Normal = (Get-WorkbookItem 'invocation-logs').content.query; Technical = ($technical.content.items | Where-Object name -eq 'invocation-log-details').content.query }
            @{ Normal = (Get-WorkbookItem 'cycle-logs').content.query; Technical = ($cycleTechnical.content.items | Where-Object name -eq 'cycle-log-details').content.query }
        )
        foreach ($pair in $queries) {
            $normalInput = [regex]::Split($pair.Normal, '\| project Timestamp = timestamp,')[0]
            $technicalInput = [regex]::Split($pair.Technical, '\| project Timestamp = timestamp,')[0]
            $normalInput | Should -Be $technicalInput
            $pair.Technical | Should -Match 'Details = details'
            $pair.Technical | Should -Match 'take 500'
        }
    }

    It 'shows lease, deadline, observation age and cross-cycle recovery without reading saved state' {
        $summary = (Get-WorkbookItem 'cycle-summary').content
        $summary.query | Should -Match 'Lease Expires'
        $summary.query | Should -Match 'Observation Age'
        $summary.query | Should -Match 'SupersedesCycleId'
        $summary.query | Should -Match 'Data.Reason'
        $summary.query | Should -Match 'Data.ImageDefinition'
        $summary.gridSettings.formatters[0].formatOptions.linkTarget | Should -Be 'ResourceOverview'
        $summary.query | Should -Not -Match 'DeploymentIntent|LastError|ConfigurationHash'
    }

    It 'separates timer roles without applying fixed thresholds to a sparse initiation schedule' {
        $health = (Get-WorkbookItem 'schedule-table').content.query
        $health | Should -Match "dynamic\(\['Initiation', 'Reconciliation'\]\)"
        $health | Should -Match 'No completed invocation observed in selected range'
        $health | Should -Match 'let invocations = requests'
        $health | Should -Match 'CompletedUtc = timestamp \+ \(duration \* 1ms\)'
        $health | Should -Not -Match '35|45|On Schedule|Due Soon'
        $frequency = (Get-WorkbookItem 'frequency-chart').content.query
        $frequency | Should -Match '\r\nrequests\r\n'
        $frequency | Should -Match 'bin\(timestamp, 1h\), Trigger'
        foreach ($query in @($health, $frequency)) {
            $query | Should -Match 'session-host-replacer-worker'
            $query | Should -Match 'isnotempty\(InvocationKey\)'
            $query | Should -Match 'by Source, FunctionApp, Trigger, InvocationKey'
            $query | Should -Match 'lookup kind=leftouter poolNames on Source'
            $query | Should -Not -Match 'poolNames on Source, FunctionApp|let poolNames = traces'
            $query | Should -Match "HostPoolName =~ hostPoolFilter"
            $query | Should -Not -Match "Data.Event\) == 'Started'"
        }
    }

    It 'maps all native invocation views without needing application traces in the time range' {
        $page = $book.items | Where-Object name -eq 'invocations-page'
        $technical = Get-WorkbookItem 'invocation-technical-details'
        $queries = @(
            (Get-WorkbookItem 'schedule-table').content.query
            (Get-WorkbookItem 'frequency-chart').content.query
            (Get-WorkbookItem 'invocation-history').content.query
            (Get-WorkbookItem 'invocation-logs').content.query
            (Get-WorkbookItem 'timer-health-details').content.query
            ($technical.content.items | Where-Object name -in @('invocation-details', 'invocation-log-details')).content.query
            (Get-WorkbookItem 'invocation-selection').content.parameters[0].query
        )
        @($queries | Where-Object { $_ -match 'lookup kind=leftouter poolNames on Source' }).Count |
            Should -Be 8
        foreach ($query in $queries) {
            $query | Should -Match 'let poolNames = print Sources = dynamic\(\{HostPoolSources\}\)'
            $query | Should -Not -Match 'let poolNames = traces'
        }
    }

    It 'labels inventory and action records as observations, not live cycle completion' {
        (Get-WorkbookItem 'kpi-tiles').content.title |
            Should -Be 'Last Reported Inventory'
        (Get-WorkbookItem 'inventory-freshness').content.query |
            Should -Match 'Last Inventory Observation'
        (Get-WorkbookItem 'run-history-table').content.title |
            Should -Match 'Not Cycle Completion'
        (Get-WorkbookItem 'cycle-tracing-help').content.json |
            Should -Match 'not a live Table read'
    }

    It 'uses native invocation outcomes for idle-aware timer alert examples' {
        $guide = Get-Content (Join-Path $shrRoot 'alerts\alerts-guide.md') -Raw
        $timerSections = [regex]::Match($guide, '(?s)## 2\. Timer Failures(.*?)## Avoid Alerting').Groups[1].Value
        $timerSections | Should -Match 'requests'
        $timerSections | Should -Match 'session-host-replacer-worker'
        $timerSections | Should -Match 'InvocationKey'
        $timerSections | Should -Match 'duration \* 1ms'
        $timerSections | Should -Not -Match 'message contains "SHR_TIMER'
        $timerSections | Should -Match 'successful idle'
    }

    It 'retains the legacy dashboard snapshots at Information despite quieter diagnostics' {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $shrRoot 'functions\run.ps1'), [ref]$tokens, [ref]$errors)
        $commands = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Write-LogEntry'
        }, $true))
        foreach ($prefix in @('SETTINGS \|', 'IMAGE_INFO \|', 'METRICS \|', 'ACTION \|')) {
            $snapshots = @($commands | Where-Object { $_.Extent.Text -match $prefix })
            $snapshots.Count | Should -BeGreaterThan 0
            foreach ($snapshot in $snapshots) {
                $snapshot.Extent.Text | Should -Not -Match '-Level (Trace|Debug|Warning|Error)'
            }
        }
    }
}
