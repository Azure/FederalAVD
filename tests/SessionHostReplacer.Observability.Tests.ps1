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
        $parameters = ($book.items | Where-Object name -eq 'parameters').content.parameters
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
            $query = ($operations.content.items | Where-Object name -eq $name).content.query
            $query | Should -Match "CycleId == '\{Cycle\}'"
            $query | Should -Not -Match "operation_Id == '\{Cycle\}'"
            $query | Should -Match 'Data.SchemaVersion'
        }
        ($operations.content.items | Where-Object name -eq 'cycle-timeline').content.query |
            Should -Match 'order by Timestamp asc'
    }

    It 'can follow native invocation logs and exceptions without joining on an empty identity' {
        $query = ($operations.content.items | Where-Object name -eq 'cycle-logs').content.query
        $query | Should -Match 'union traces, exceptions'
        $query | Should -Match "InvocationId == '\{Invocation\}'"
        $query | Should -Match "NativeKey !in \('inv:', 'op:'\)"
        $query | Should -Match 'Source, NativeKey'
        $query | Should -Match 'take 500'
    }

    It 'queries one deployed workspace rather than the resource-scoped Application Insights view' {
        $workspace = $parameters | Where-Object name -eq 'WorkloadWorkspace'
        $workspace.value | Should -Be '__SHR_WORKSPACE_RESOURCE_ID__'
        $workspace.isHidden | Should -Be $true
        $workspace.multiSelect | Should -Be $false
        $picker = $parameters | Where-Object name -eq 'ApplicationInsights'
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
                        $Node.query | Should -Match '_ResourceId in~ \(\{ApplicationInsights\}\)'
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
        $history = ($page.content.items | Where-Object name -eq 'invocation-history').content.query
        $history | Should -Match 'let requests = AppRequests'
        $history | Should -Match 'duration = DurationMs'
        $history | Should -Match 'customDimensions = Properties'
        $history | Should -Match 'timestamp \+ \(duration \* 1ms\)'
        $history | Should -Match 'Source = tostring\(_ResourceId\)'
    }

    It 'lists only current initiator and worker invocations including idle ticks' {
        $page = $book.items | Where-Object name -eq 'invocations-page'
        $page.conditionalVisibility.value | Should -Be 'invocations'
        $query = ($page.content.items | Where-Object name -eq 'invocation-history').content.query
        $query | Should -Match "FunctionName in \('session-host-replacer-initiator', 'session-host-replacer-worker'\)"
        $query | Should -Not -Match "'session-host-replacer'"
        $query | Should -Match 'arg_max\(timestamp, \*\) by Source, FunctionApp, FunctionName, InvocationKey'
        $query | Should -Match 'top 200'
        $query | Should -Match 'ResultCode = resultCode'
        $query | Should -Not -Match 'SHR_TIMER|SHR_EVENT|\{Cycle\}|\{Invocation\}'
        $query | Should -Match "'Unavailable'"
    }

    It 'excludes the retired single-timer function from timer health and frequency views' {
        foreach ($name in @('schedule-table', 'frequency-chart')) {
            $query = ($operations.content.items | Where-Object name -eq $name).content.query
            $query | Should -Match "FunctionName in \('session-host-replacer-initiator', 'session-host-replacer-worker'\)"
            $query | Should -Not -Match "'session-host-replacer'"
        }
    }

    It 'keeps native invocation and request identities distinct in the troubleshooting selector' {
        $page = $book.items | Where-Object name -eq 'invocations-page'
        $selector = ($page.content.items | Where-Object name -eq 'invocation-selection').content.parameters[0]
        $selector.name | Should -Be 'TroubleshootingInvocation'
        $selector.value | Should -Be '*'
        $selector.query | Should -Match "strcat\('inv:', InvocationId\)"
        $selector.query | Should -Match "strcat\('req:', id\)"
        $selector.query | Should -Match "strcat\(Source, '\|', InvocationKey\)"
        ($selector.crossComponentResources -contains '{WorkloadWorkspace}') | Should -Be $true
    }

    It 'drills into traces and exceptions with guarded correlation and bounded chronological output' {
        $page = $book.items | Where-Object name -eq 'invocations-page'
        $query = ($page.content.items | Where-Object name -eq 'invocation-logs').content.query
        $query | Should -Match 'let exceptions = AppExceptions'
        $query | Should -Match 'union withsource=RecordType traces, exceptions'
        $query | Should -Match "SelectionKey == '\{TroubleshootingInvocation\}'"
        $query | Should -Match 'join kind=inner selectedRun on Source'
        $query | Should -Match 'isnotempty\(SelectedInvocationId\)'
        $query | Should -Match 'isnotempty\(operation_Id\) and operation_Id == SelectedOperationId'
        $query | Should -Match 'take 500'
        $query | Should -Match 'order by Timestamp asc'
        $query | Should -Match 'Details = details'
    }

    It 'shows lease, deadline, observation age and cross-cycle recovery without reading saved state' {
        $summary = ($operations.content.items | Where-Object name -eq 'cycle-summary').content
        $summary.query | Should -Match 'Lease Expires'
        $summary.query | Should -Match 'Observation Age'
        $summary.query | Should -Match 'SupersedesCycleId'
        $summary.query | Should -Match 'Data.Reason'
        $summary.query | Should -Match 'Data.ImageDefinition'
        $summary.gridSettings.formatters[0].formatOptions.linkTarget | Should -Be 'ResourceOverview'
        $summary.query | Should -Not -Match 'DeploymentIntent|LastError|ConfigurationHash'
    }

    It 'separates timer roles without applying fixed thresholds to a sparse initiation schedule' {
        $health = ($operations.content.items | Where-Object name -eq 'schedule-table').content.query
        $health | Should -Match "dynamic\(\['Initiation', 'Reconciliation'\]\)"
        $health | Should -Match 'No completed invocation observed in selected range'
        $health | Should -Match 'let invocations = requests'
        $health | Should -Match 'CompletedUtc = timestamp \+ \(duration \* 1ms\)'
        $health | Should -Not -Match '35|45|On Schedule|Due Soon'
        $frequency = ($operations.content.items | Where-Object name -eq 'frequency-chart').content.query
        $frequency | Should -Match '\r\nrequests\r\n'
        $frequency | Should -Match 'bin\(timestamp, 1h\), Trigger'
        foreach ($query in @($health, $frequency)) {
            $query | Should -Match 'session-host-replacer-worker'
            $query | Should -Match 'isnotempty\(InvocationKey\)'
            $query | Should -Match 'by Source, FunctionApp, Trigger, InvocationKey'
            $query | Should -Match 'lookup kind=leftouter poolNames on Source, FunctionApp'
            $query | Should -Match "HostPoolName == hostPoolFilter"
            $query | Should -Not -Match "Data.Event\) == 'Started'"
        }
    }

    It 'labels inventory and action records as observations, not live cycle completion' {
        ($operations.content.items | Where-Object name -eq 'kpi-tiles').content.title |
            Should -Be 'Last Reported Inventory'
        ($operations.content.items | Where-Object name -eq 'inventory-freshness').content.query |
            Should -Match 'Last Inventory Observation'
        ($operations.content.items | Where-Object name -eq 'run-history-table').content.title |
            Should -Match 'Not Cycle Completion'
        ($operations.content.items | Where-Object name -eq 'cycle-tracing-help').content.json |
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
