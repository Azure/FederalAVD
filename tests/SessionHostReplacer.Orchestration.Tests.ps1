$repoRoot = Split-Path -Parent $PSScriptRoot
$functionRoot = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\functions'
$runPath = Join-Path $functionRoot 'run.ps1'
$modulePath = Join-Path $functionRoot 'Modules\SessionHostReplacer\SessionHostReplacer.psd1'

function New-OrchestrationTestHost {
    param (
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [string] $ImageVersion = '1.0.0',
        [string] $Status = 'Available',
        [bool] $AllowNewSession = $true
    )

    [PSCustomObject]@{
        SessionHostName = $Name
        VMName = $Name
        FQDN = "$Name.contoso.test"
        ResourceId = "/subscriptions/test/resourceGroups/hosts/providers/Microsoft.Compute/virtualMachines/$Name"
        ImageDefinition = '/subscriptions/test/resourceGroups/images/providers/Microsoft.Compute/galleries/gallery/images/avd'
        ImageVersion = $ImageVersion
        Status = $Status
        AllowNewSession = $AllowNewSession
        Sessions = 0
        IncludeInAutomation = $true
        ShutdownTimestamp = $null
        PendingDrainTimeStamp = $null
        IsUnavailable = $false
        HostId = $null
        HostGroupId = $null
        Zones = @('1')
        Tags = @{}
        SessionHostHealthCheckResults = @(
            [PSCustomObject]@{ healthCheckResult = 'HealthCheckSucceeded' }
        )
    }
}

function New-OrchestrationDeploymentState {
    [PSCustomObject]@{
        LastDeploymentName = ''
        LastDeploymentCount = 0
        LastDeploymentNeeded = 0
        LastDeploymentPercentage = 0
        LastStatus = 'None'
        LastTimestamp = '2026-09-20T00:00:00Z'
        ConsecutiveSuccesses = 0
        CurrentPercentage = 20
        TargetSessionHostCount = 10
        LastImageVersion = '1.0.0'
        LastTotalToReplace = 10
        PendingHostMappings = '{}'
    }
}

function Copy-OrchestrationValue {
    param ($Value)

    $Value | ConvertTo-Json -Depth 20 | ConvertFrom-Json
}

function Invoke-OrchestrationCycle {
    param ([int] $RunNumber)

    $global:shrSimulation.RunNumber = $RunNumber
    & $runPath -Timer ([PSCustomObject]@{ IsPastDue = $false })
}

Describe 'Session Host Replacer deterministic orchestration failures' {
    BeforeAll {
        Import-Module $modulePath -Force
    }

    BeforeEach {
        $global:shrSimulation = @{
            RunNumber = 0
            Mode = 'SideBySide'
            'LatestImage' = [PSCustomObject]@{
                Definition = '/subscriptions/test/resourceGroups/images/providers/Microsoft.Compute/galleries/gallery/images/avd'
                Version = '2.0.0'
                Date = [datetime]'2026-09-01T00:00:00Z'
            }
            Hosts = @(1..2 | ForEach-Object { New-OrchestrationTestHost -Name "avd-0$_" })
            DeploymentState = New-OrchestrationDeploymentState
            Plan = $null
            Readiness = [PSCustomObject]@{
                TotalNewHosts = 0
                AvailableCount = 0
                AvailablePercentage = 0
                SafeToProceed = $true
                Message = 'No new hosts to verify'
            }
            FailDeploymentRuns = @()
            AcceptedButThrowRuns = @()
            InterruptAfterDeletionRuns = @()
            DeploymentStatuses = @{}
            RunningDeployments = @{}
            FailedDeployments = @{}
            FailRequiredSave = $false
            FailPostDeploymentSaveRuns = @()
            FailCleanupRuns = @()
            VerificationResults = @{}
            DeploymentCalls = @()
            DeletionCalls = @()
            CleanupCalls = @()
            DirectoryCleanupCalls = @()
            VerificationCalls = @()
            SaveCalls = @()
            Logs = @()
        }

        $global:shrSettings = @{
            ReplacementMode = 'SideBySide'
            EnableShutdownRetention = $false
            MinimumDrainMinutes = 0
            DrainGracePeriodHours = 24
            MinimumCapacityPercentage = 80
            MaxDeletionsPerCycle = 2
            EnableProgressiveScaleUp = $false
            InitialDeploymentPercentage = 20
            ScaleUpIncrementPercentage = 20
            SuccessfulRunsBeforeScaleUp = 1
            MaxDeploymentBatchSize = 2
            MinimumHostIndex = 1
            ShutdownRetentionDays = 3
            TargetSessionHostCount = 2
            RemoveEntraDevice = $false
            RemoveIntuneDevice = $false
            VirtualMachinesSubscriptionId = 'test'
            VirtualMachinesResourceGroupName = 'hosts'
            HostPoolSubscriptionId = 'test'
            HostPoolResourceGroupName = 'hosts'
            HostPoolName = 'hp-test'
            ReplaceSessionHostOnNewImageVersionDelayDays = 0
            AllowImageVersionRollback = $false
            Tag_ScalingPlanExclusionTag = 'ScalingPlanExclusion'
            Tag_ShutdownTimestamp = 'AutoReplaceShutdownTimestamp'
            SessionHostParameters = @{
                ImageReference = @{
                    id = '/subscriptions/test/resourceGroups/images/providers/Microsoft.Compute/galleries/gallery/images/avd'
                }
                Location = 'eastus'
            }
        }

        Mock Write-LogEntry {
            param ($Message, $StringValues)
            $global:shrSimulation.Logs += $Message
        }
        Mock Read-FunctionAppSetting {
            param ($SettingKey, [switch] $NoCache, [switch] $AsBoolean)
            $value = $global:shrSettings[$SettingKey]
            if ($AsBoolean) { return [bool]$value }
            return $value
        }
        Mock Get-ResourceManagerUri { 'https://management.azure.com' }
        Mock Get-GraphEndpoint { 'https://graph.microsoft.com' }
        Mock Get-AccessToken { 'test-token' }
        Mock Invoke-AzureRestMethod {
            @($global:shrSimulation.Hosts | ForEach-Object {
                [PSCustomObject]@{ name = $_.VMName; id = $_.ResourceId; tags = [PSCustomObject]@{} }
            })
        }
        Mock Get-SessionHosts { @($global:shrSimulation.Hosts) }
        Mock Get-DeploymentState { Copy-OrchestrationValue $global:shrSimulation.DeploymentState }
        Mock Save-DeploymentState {
            param ($DeploymentState, [switch] $RequireSuccess)
            $global:shrSimulation.SaveCalls += [PSCustomObject]@{
                Run = $global:shrSimulation.RunNumber
                Required = [bool]$RequireSuccess
                PendingHostMappings = $DeploymentState.PendingHostMappings
                LastDeploymentName = $DeploymentState.LastDeploymentName
            }
            if ($RequireSuccess -and $global:shrSimulation.FailRequiredSave) {
                throw 'simulated deployment-state write failure'
            }
            if ($RequireSuccess -and
                $global:shrSimulation.RunNumber -in $global:shrSimulation.FailPostDeploymentSaveRuns -and
                -not [string]::IsNullOrEmpty($DeploymentState.LastDeploymentName)) {
                throw 'simulated post-deployment state write failure'
            }
            $global:shrSimulation.DeploymentState = Copy-OrchestrationValue $DeploymentState
        }
        Mock Get-Deployments {
            @{
                RunningDeployments = @($global:shrSimulation.RunningDeployments[$global:shrSimulation.RunNumber] | Where-Object { $null -ne $_ })
                FailedDeployments = @($global:shrSimulation.FailedDeployments[$global:shrSimulation.RunNumber] | Where-Object { $null -ne $_ })
            }
        }
        Mock Get-LastDeploymentStatus {
            param ($DeploymentName)
            $status = $global:shrSimulation.DeploymentStatuses[$global:shrSimulation.RunNumber]
            if (-not $status) { return $null }
            [PSCustomObject]@{
                Succeeded = $status -eq 'Succeeded'
                Failed = $status -eq 'Failed'
                Running = $status -eq 'Running'
            }
        }
        Mock Get-LatestImageVersion { $global:shrSimulation.LatestImage }
        Mock Compare-ImageVersion { -1 }
        Mock Get-ScalingPlanCurrentTarget {
            [PSCustomObject]@{
                CapacityPercentage = $null
                ScalingPlanName = $null
                ScheduleName = $null
                Phase = $null
                Source = $null
            }
        }
        Mock Get-SessionHostReplacementPlan { $global:shrSimulation.Plan }
        Mock Test-NewSessionHostsAvailable { $global:shrSimulation.Readiness }
        Mock Deploy-SessionHosts {
            param (
                $NewSessionHostsCount,
                $ExistingSessionHostNames,
                $PreferredSessionHostNames,
                $PreferredHostProperties
            )
            $global:shrSimulation.DeploymentCalls += [PSCustomObject]@{
                Run = $global:shrSimulation.RunNumber
                Count = $NewSessionHostsCount
                PreferredNames = @($PreferredSessionHostNames)
            }
            if ($global:shrSimulation.RunNumber -in $global:shrSimulation.FailDeploymentRuns) {
                throw 'simulated deployment submission failure'
            }
            if ($global:shrSimulation.RunNumber -in $global:shrSimulation.AcceptedButThrowRuns) {
                throw 'simulated timeout after ARM accepted the deployment'
            }
            [PSCustomObject]@{
                DeploymentName = "deployment-$($global:shrSimulation.RunNumber)"
                SessionHostNames = if ($PreferredSessionHostNames) { @($PreferredSessionHostNames) } else { @('avd-new-01', 'avd-new-02') }
                SessionHostCount = $NewSessionHostsCount
            }
        }
        Mock Remove-SessionHosts {
            param ($SessionHostsPendingDelete)
            $names = @($SessionHostsPendingDelete.SessionHostName)
            $global:shrSimulation.DeletionCalls += [PSCustomObject]@{
                Run = $global:shrSimulation.RunNumber
                Names = $names
            }
            $global:shrSimulation.Hosts = @($global:shrSimulation.Hosts | Where-Object {
                $_.SessionHostName -notin $names
            })
            if ($global:shrSimulation.RunNumber -in $global:shrSimulation.InterruptAfterDeletionRuns) {
                throw 'simulated function interruption after host removal'
            }
            [PSCustomObject]@{
                SuccessfulDeletions = $names
                SuccessfulShutdowns = @()
                FailedDeletions = @()
            }
        }
        Mock Remove-DeviceFromDirectories {
            param ($DeviceName)
            $global:shrSimulation.DirectoryCleanupCalls += [PSCustomObject]@{
                Run = $global:shrSimulation.RunNumber
                Name = $DeviceName
            }
        }
        Mock Confirm-SessionHostDeletions {
            param ($DeletedHostNames)
            $global:shrSimulation.VerificationCalls += [PSCustomObject]@{
                Run = $global:shrSimulation.RunNumber
                Names = @($DeletedHostNames)
            }
            $configuredResult = $global:shrSimulation.VerificationResults[$global:shrSimulation.RunNumber]
            if ($configuredResult) { return $configuredResult }
            [PSCustomObject]@{
                TotalHosts = @($DeletedHostNames).Count
                VMsConfirmed = @($DeletedHostNames).Count
                EntraIDConfirmed = @($DeletedHostNames).Count
                IntuneConfirmed = @($DeletedHostNames).Count
                IncompleteHosts = @()
            }
        }
        Mock Remove-FailedDeploymentArtifacts {
            param ($FailedDeployments)
            $global:shrSimulation.CleanupCalls += [PSCustomObject]@{
                Run = $global:shrSimulation.RunNumber
                DeploymentName = $FailedDeployments[0].DeploymentName
                SessionHostNames = @($FailedDeployments[0].SessionHostNames)
            }
            if ($global:shrSimulation.RunNumber -in $global:shrSimulation.FailCleanupRuns) {
                throw 'simulated failed-deployment cleanup failure'
            }
        }
        Mock Update-HostPoolStatus {}
    }

    AfterAll {
        Remove-Variable shrSimulation -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable shrSettings -Scope Global -ErrorAction SilentlyContinue
        Remove-Module SessionHostReplacer -Force
    }

    It 'SideBySide retries a failed deployment and never removes old hosts before replacements are ready' {
        $oldHosts = @($global:shrSimulation.Hosts)
        $global:shrSimulation.FailDeploymentRuns = @(1)
        $global:shrSimulation.Plan = [PSCustomObject]@{
            PossibleDeploymentsCount = 2
            PossibleSessionHostDeleteCount = 0
            SessionHostsPendingDelete = @()
            ExistingSessionHostNames = @($oldHosts.SessionHostName)
            TargetSessionHostCount = 2
            TotalSessionHostsToReplace = 2
        }

        $caughtError = $null
        try { Invoke-OrchestrationCycle -RunNumber 1 } catch { $caughtError = $_ }
        if ($global:shrSimulation.DeploymentCalls.Count -eq 0) {
            throw "Deployment boundary was not reached. Error: $caughtError Logs: $($global:shrSimulation.Logs -join ' | ')"
        }
        $global:shrSimulation.DeploymentCalls.Count | Should Be 1
        $caughtError | Should Not BeNullOrEmpty
        $global:shrSimulation.DeletionCalls.Count | Should Be 0

        Invoke-OrchestrationCycle -RunNumber 2
        $global:shrSimulation.DeploymentCalls.Count | Should Be 2
        $global:shrSimulation.DeletionCalls.Count | Should Be 0

        $global:shrSimulation.Plan = [PSCustomObject]@{
            PossibleDeploymentsCount = 0
            PossibleSessionHostDeleteCount = 2
            SessionHostsPendingDelete = $oldHosts
            ExistingSessionHostNames = @($oldHosts.SessionHostName)
            TargetSessionHostCount = 2
            TotalSessionHostsToReplace = 2
        }
        $global:shrSimulation.Readiness = [PSCustomObject]@{
            TotalNewHosts = 2
            AvailableCount = 1
            AvailablePercentage = 50
            SafeToProceed = $false
            Message = 'Only one replacement is ready'
        }

        Invoke-OrchestrationCycle -RunNumber 3
        $global:shrSimulation.DeletionCalls.Count | Should Be 0

        $global:shrSimulation.Readiness = [PSCustomObject]@{
            TotalNewHosts = 2
            AvailableCount = 2
            AvailablePercentage = 100
            SafeToProceed = $true
            Message = 'All replacements are ready'
        }

        Invoke-OrchestrationCycle -RunNumber 4
        $global:shrSimulation.DeletionCalls.Count | Should Be 1
        $global:shrSimulation.DeletionCalls[0].Names | Should Be @('avd-01', 'avd-02')
    }

    It 'DeleteFirst recovers an empty pool, retries only unresolved names, and performs no further deletion' {
        $global:shrSimulation.Mode = 'DeleteFirst'
        $global:shrSettings.ReplacementMode = 'DeleteFirst'
        $global:shrSimulation.FailDeploymentRuns = @(1)
        $initialHosts = @($global:shrSimulation.Hosts)
        $global:shrSimulation.Plan = [PSCustomObject]@{
            PossibleDeploymentsCount = 2
            PossibleSessionHostDeleteCount = 2
            SessionHostsPendingDelete = $initialHosts
            ExistingSessionHostNames = @($initialHosts.SessionHostName)
            TargetSessionHostCount = 2
            TotalSessionHostsToReplace = 2
        }

        $caughtError = $null
        try { Invoke-OrchestrationCycle -RunNumber 1 } catch { $caughtError = $_ }
        if ($global:shrSimulation.DeploymentCalls.Count -eq 0) {
            throw "Deployment boundary was not reached. Error: $caughtError Logs: $($global:shrSimulation.Logs -join ' | ')"
        }
        $global:shrSimulation.DeploymentCalls.Count | Should Be 1
        $caughtError | Should Not BeNullOrEmpty
        $global:shrSimulation.DeletionCalls.Count | Should Be 1
        $global:shrSimulation.Hosts.Count | Should Be 0
        ($global:shrSimulation.DeploymentState.PendingHostMappings | ConvertFrom-Json).PSObject.Properties.Name.Count | Should Be 2

        $global:shrSimulation.Plan = [PSCustomObject]@{
            PossibleDeploymentsCount = 2
            PossibleSessionHostDeleteCount = 0
            SessionHostsPendingDelete = @()
            ExistingSessionHostNames = @()
            TargetSessionHostCount = 2
            TotalSessionHostsToReplace = 2
        }
        Invoke-OrchestrationCycle -RunNumber 2
        $global:shrSimulation.DeletionCalls.Count | Should Be 1
        $global:shrSimulation.DeploymentCalls[-1].PreferredNames | Should Be @('avd-01', 'avd-02')

        $global:shrSimulation.Hosts += New-OrchestrationTestHost -Name 'avd-01' -ImageVersion '2.0.0'
        $global:shrSimulation.Plan.PossibleDeploymentsCount = 1
        Invoke-OrchestrationCycle -RunNumber 3
        $global:shrSimulation.DeletionCalls.Count | Should Be 1
        $global:shrSimulation.DeploymentCalls[-1].PreferredNames | Should Be @('avd-02')

        $global:shrSimulation.Hosts += New-OrchestrationTestHost -Name 'avd-02' -ImageVersion '2.0.0'
        $global:shrSimulation.Plan = [PSCustomObject]@{
            PossibleDeploymentsCount = 0
            PossibleSessionHostDeleteCount = 0
            SessionHostsPendingDelete = @()
            ExistingSessionHostNames = @('avd-01', 'avd-02')
            TargetSessionHostCount = 2
            TotalSessionHostsToReplace = 0
        }
        Invoke-OrchestrationCycle -RunNumber 4
        $global:shrSimulation.DeploymentState.PendingHostMappings | Should Be '{}'
        $global:shrSimulation.DeletionCalls.Count | Should Be 1
    }

    It 'DeleteFirst cleans up an asynchronously failed deployment and retries the exact unresolved hosts without deleting again' {
        $global:shrSimulation.Mode = 'DeleteFirst'
        $global:shrSettings.ReplacementMode = 'DeleteFirst'
        $global:shrSettings.EnableProgressiveScaleUp = $true
        $initialHosts = @($global:shrSimulation.Hosts)
        $global:shrSimulation.Plan = [PSCustomObject]@{
            PossibleDeploymentsCount = 2
            PossibleSessionHostDeleteCount = 2
            SessionHostsPendingDelete = $initialHosts
            ExistingSessionHostNames = @($initialHosts.SessionHostName)
            TargetSessionHostCount = 2
            TotalSessionHostsToReplace = 2
        }

        Invoke-OrchestrationCycle -RunNumber 1
        $global:shrSimulation.DeploymentState.LastDeploymentName | Should Be 'deployment-1'
        $global:shrSimulation.DeletionCalls.Count | Should Be 1

        $global:shrSimulation.DeploymentStatuses[2] = 'Failed'
        $global:shrSimulation.Plan = [PSCustomObject]@{
            PossibleDeploymentsCount = 2
            PossibleSessionHostDeleteCount = 0
            SessionHostsPendingDelete = @()
            ExistingSessionHostNames = @()
            TargetSessionHostCount = 2
            TotalSessionHostsToReplace = 2
        }

        Invoke-OrchestrationCycle -RunNumber 2
        $global:shrSimulation.CleanupCalls.Count | Should Be 1
        $global:shrSimulation.CleanupCalls[0].DeploymentName | Should Be 'deployment-1'
        $global:shrSimulation.CleanupCalls[0].SessionHostNames | Should Be @('avd-01', 'avd-02')
        $global:shrSimulation.DeletionCalls.Count | Should Be 1
        $global:shrSimulation.DeploymentCalls.Count | Should Be 2
        $global:shrSimulation.DeploymentCalls[-1].PreferredNames | Should Be @('avd-01', 'avd-02')
        $global:shrSimulation.DeploymentState.PendingHostMappings | Should Not Be '{}'
    }

    It 'DeleteFirst does not redeploy after asynchronous failure until orphan cleanup succeeds' {
        $global:shrSimulation.Mode = 'DeleteFirst'
        $global:shrSettings.ReplacementMode = 'DeleteFirst'
        $global:shrSettings.EnableProgressiveScaleUp = $true
        $initialHosts = @($global:shrSimulation.Hosts)
        $global:shrSimulation.Plan = [PSCustomObject]@{
            PossibleDeploymentsCount = 2
            PossibleSessionHostDeleteCount = 2
            SessionHostsPendingDelete = $initialHosts
            ExistingSessionHostNames = @($initialHosts.SessionHostName)
            TargetSessionHostCount = 2
            TotalSessionHostsToReplace = 2
        }

        Invoke-OrchestrationCycle -RunNumber 1
        $global:shrSimulation.DeploymentStatuses[2] = 'Failed'
        $global:shrSimulation.FailCleanupRuns = @(2)
        $global:shrSimulation.Plan = [PSCustomObject]@{
            PossibleDeploymentsCount = 2
            PossibleSessionHostDeleteCount = 0
            SessionHostsPendingDelete = @()
            ExistingSessionHostNames = @()
            TargetSessionHostCount = 2
            TotalSessionHostsToReplace = 2
        }

        $cleanupError = $null
        try { Invoke-OrchestrationCycle -RunNumber 2 } catch { $cleanupError = $_ }
        $cleanupError | Should Not BeNullOrEmpty
        $global:shrSimulation.CleanupCalls.Count | Should Be 1
        $global:shrSimulation.DeploymentCalls.Count | Should Be 1
        $global:shrSimulation.DeploymentState.LastDeploymentName | Should Be 'deployment-1'

        $global:shrSimulation.DeploymentStatuses[3] = 'Failed'
        Invoke-OrchestrationCycle -RunNumber 3
        $global:shrSimulation.CleanupCalls.Count | Should Be 2
        $global:shrSimulation.DeploymentCalls.Count | Should Be 2
        $global:shrSimulation.DeletionCalls.Count | Should Be 1
    }

    It 'DeleteFirst does not submit or delete again while the previous deployment remains running' {
        $global:shrSimulation.Mode = 'DeleteFirst'
        $global:shrSettings.ReplacementMode = 'DeleteFirst'
        $global:shrSettings.EnableProgressiveScaleUp = $true
        $initialHosts = @($global:shrSimulation.Hosts)
        $global:shrSimulation.Plan = [PSCustomObject]@{
            PossibleDeploymentsCount = 2
            PossibleSessionHostDeleteCount = 2
            SessionHostsPendingDelete = $initialHosts
            ExistingSessionHostNames = @($initialHosts.SessionHostName)
            TargetSessionHostCount = 2
            TotalSessionHostsToReplace = 2
        }

        Invoke-OrchestrationCycle -RunNumber 1
        $global:shrSimulation.DeploymentState.LastDeploymentName | Should Be 'deployment-1'

        $global:shrSimulation.Plan = [PSCustomObject]@{
            PossibleDeploymentsCount = 2
            PossibleSessionHostDeleteCount = 0
            SessionHostsPendingDelete = @()
            ExistingSessionHostNames = @()
            TargetSessionHostCount = 2
            TotalSessionHostsToReplace = 2
        }
        $global:shrSimulation.DeploymentStatuses[2] = 'Running'
        $global:shrSimulation.DeploymentStatuses[3] = 'Running'

        Invoke-OrchestrationCycle -RunNumber 2
        Invoke-OrchestrationCycle -RunNumber 3

        $global:shrSimulation.DeletionCalls.Count | Should Be 1
        $global:shrSimulation.DeploymentCalls.Count | Should Be 1
        $global:shrSimulation.DeploymentState.LastDeploymentName | Should Be 'deployment-1'
    }

    It 'DeleteFirst does not clean up or redeploy hosts after ARM succeeds while AVD registration is pending' {
        $global:shrSimulation.Mode = 'DeleteFirst'
        $global:shrSettings.ReplacementMode = 'DeleteFirst'
        $global:shrSettings.EnableProgressiveScaleUp = $true
        $global:shrSettings.RemoveEntraDevice = $true
        $global:shrSettings.RemoveIntuneDevice = $true
        $initialHosts = @($global:shrSimulation.Hosts)
        $global:shrSimulation.Plan = [PSCustomObject]@{
            PossibleDeploymentsCount = 2
            PossibleSessionHostDeleteCount = 2
            SessionHostsPendingDelete = $initialHosts
            ExistingSessionHostNames = @($initialHosts.SessionHostName)
            TargetSessionHostCount = 2
            TotalSessionHostsToReplace = 2
        }

        Invoke-OrchestrationCycle -RunNumber 1
        $global:shrSimulation.DeploymentStatuses[2] = 'Succeeded'
        $global:shrSimulation.Plan = [PSCustomObject]@{
            PossibleDeploymentsCount = 2
            PossibleSessionHostDeleteCount = 0
            SessionHostsPendingDelete = @()
            ExistingSessionHostNames = @()
            TargetSessionHostCount = 2
            TotalSessionHostsToReplace = 2
        }

        Invoke-OrchestrationCycle -RunNumber 2

        $global:shrSimulation.DeploymentCalls.Count | Should Be 1
        @($global:shrSimulation.DirectoryCleanupCalls | Where-Object Run -eq 2).Count | Should Be 0
        $global:shrSimulation.DeletionCalls.Count | Should Be 1
    }

    It 'DeleteFirst discovers an accepted deployment after caller interruption and does not submit or delete again' {
        $global:shrSimulation.Mode = 'DeleteFirst'
        $global:shrSettings.ReplacementMode = 'DeleteFirst'
        $global:shrSimulation.AcceptedButThrowRuns = @(1)
        $initialHosts = @($global:shrSimulation.Hosts)
        $global:shrSimulation.Plan = [PSCustomObject]@{
            PossibleDeploymentsCount = 2
            PossibleSessionHostDeleteCount = 2
            SessionHostsPendingDelete = $initialHosts
            ExistingSessionHostNames = @($initialHosts.SessionHostName)
            TargetSessionHostCount = 2
            TotalSessionHostsToReplace = 2
        }

        $submissionError = $null
        try { Invoke-OrchestrationCycle -RunNumber 1 } catch { $submissionError = $_ }
        $submissionError | Should Not BeNullOrEmpty
        $global:shrSimulation.DeletionCalls.Count | Should Be 1
        $global:shrSimulation.DeploymentCalls.Count | Should Be 1
        $global:shrSimulation.DeploymentState.LastDeploymentName | Should Be ''

        $global:shrSimulation.RunningDeployments[2] = @(
            [PSCustomObject]@{
                DeploymentName = 'deployment-accepted'
                SessionHostNames = @('avd-01', 'avd-02')
                Timestamp = [datetime]'2026-09-20T00:00:00Z'
                Status = 'Running'
            }
        )
        $global:shrSimulation.Plan = [PSCustomObject]@{
            PossibleDeploymentsCount = 2
            PossibleSessionHostDeleteCount = 0
            SessionHostsPendingDelete = @()
            ExistingSessionHostNames = @()
            TargetSessionHostCount = 2
            TotalSessionHostsToReplace = 2
        }

        Invoke-OrchestrationCycle -RunNumber 2
        $global:shrSimulation.DeletionCalls.Count | Should Be 1
        $global:shrSimulation.DeploymentCalls.Count | Should Be 1
        $global:shrSimulation.DeploymentState.PendingHostMappings | Should Not Be '{}'
    }

    It 'DeleteFirst recovers when the function is interrupted after host removal and before deployment submission' {
        $global:shrSimulation.Mode = 'DeleteFirst'
        $global:shrSettings.ReplacementMode = 'DeleteFirst'
        $global:shrSimulation.InterruptAfterDeletionRuns = @(1)
        $initialHosts = @($global:shrSimulation.Hosts)
        $global:shrSimulation.Plan = [PSCustomObject]@{
            PossibleDeploymentsCount = 2
            PossibleSessionHostDeleteCount = 2
            SessionHostsPendingDelete = $initialHosts
            ExistingSessionHostNames = @($initialHosts.SessionHostName)
            TargetSessionHostCount = 2
            TotalSessionHostsToReplace = 2
        }

        $interruptionError = $null
        try { Invoke-OrchestrationCycle -RunNumber 1 } catch { $interruptionError = $_ }
        $interruptionError | Should Not BeNullOrEmpty
        $global:shrSimulation.DeletionCalls.Count | Should Be 1
        $global:shrSimulation.DeploymentCalls.Count | Should Be 0
        $global:shrSimulation.Hosts.Count | Should Be 0
        $global:shrSimulation.DeploymentState.PendingHostMappings | Should Not Be '{}'

        $global:shrSimulation.Plan = [PSCustomObject]@{
            PossibleDeploymentsCount = 2
            PossibleSessionHostDeleteCount = 0
            SessionHostsPendingDelete = @()
            ExistingSessionHostNames = @()
            TargetSessionHostCount = 2
            TotalSessionHostsToReplace = 2
        }
        Invoke-OrchestrationCycle -RunNumber 2

        $global:shrSimulation.DeletionCalls.Count | Should Be 1
        $global:shrSimulation.DeploymentCalls.Count | Should Be 1
        $global:shrSimulation.DeploymentCalls[0].PreferredNames | Should Be @('avd-01', 'avd-02')
    }

    It 'DeleteFirst blocks hostname reuse when host registration is removed but the old VM still exists' {
        $global:shrSimulation.Mode = 'DeleteFirst'
        $global:shrSettings.ReplacementMode = 'DeleteFirst'
        $global:shrSimulation.InterruptAfterDeletionRuns = @(1)
        $initialHosts = @($global:shrSimulation.Hosts)
        $global:shrSimulation.VerificationResults[2] = [PSCustomObject]@{
            TotalHosts = 2
            VMsConfirmed = 1
            EntraIDConfirmed = 2
            IntuneConfirmed = 2
            IncompleteHosts = @(
                [PSCustomObject]@{
                    Name = 'avd-02'
                    VMConfirmed = $false
                    EntraIDConfirmed = $true
                    IntuneConfirmed = $true
                }
            )
        }
        $global:shrSimulation.Plan = [PSCustomObject]@{
            PossibleDeploymentsCount = 2
            PossibleSessionHostDeleteCount = 2
            SessionHostsPendingDelete = $initialHosts
            ExistingSessionHostNames = @($initialHosts.SessionHostName)
            TargetSessionHostCount = 2
            TotalSessionHostsToReplace = 2
        }

        try { Invoke-OrchestrationCycle -RunNumber 1 } catch {}
        $global:shrSimulation.Plan = [PSCustomObject]@{
            PossibleDeploymentsCount = 2
            PossibleSessionHostDeleteCount = 0
            SessionHostsPendingDelete = @()
            ExistingSessionHostNames = @()
            TargetSessionHostCount = 2
            TotalSessionHostsToReplace = 2
        }

        $recoveryError = $null
        try { Invoke-OrchestrationCycle -RunNumber 2 } catch { $recoveryError = $_ }

        $recoveryError | Should Not BeNullOrEmpty
        $global:shrSimulation.VerificationCalls.Count | Should Be 1
        $global:shrSimulation.DeletionCalls.Count | Should Be 1
        $global:shrSimulation.DeploymentCalls.Count | Should Be 0
    }

    It 'DeleteFirst does not duplicate an accepted deployment when its state save fails and replacement VMs exist' {
        $global:shrSimulation.Mode = 'DeleteFirst'
        $global:shrSettings.ReplacementMode = 'DeleteFirst'
        $global:shrSettings.EnableProgressiveScaleUp = $true
        $global:shrSimulation.FailPostDeploymentSaveRuns = @(1)
        $initialHosts = @($global:shrSimulation.Hosts)
        $global:shrSimulation.Plan = [PSCustomObject]@{
            PossibleDeploymentsCount = 2
            PossibleSessionHostDeleteCount = 2
            SessionHostsPendingDelete = $initialHosts
            ExistingSessionHostNames = @($initialHosts.SessionHostName)
            TargetSessionHostCount = 2
            TotalSessionHostsToReplace = 2
        }

        $stateSaveError = $null
        try { Invoke-OrchestrationCycle -RunNumber 1 } catch { $stateSaveError = $_ }
        $stateSaveError | Should Not BeNullOrEmpty
        $global:shrSimulation.DeploymentCalls.Count | Should Be 1
        $global:shrSimulation.DeploymentState.LastDeploymentName | Should Be ''
        $global:shrSimulation.DeploymentState.PendingHostMappings | Should Not Be '{}'

        $global:shrSimulation.VerificationResults[2] = [PSCustomObject]@{
            TotalHosts = 2
            VMsConfirmed = 0
            EntraIDConfirmed = 2
            IntuneConfirmed = 2
            IncompleteHosts = @(
                [PSCustomObject]@{ Name = 'avd-01'; VMConfirmed = $false; EntraIDConfirmed = $true; IntuneConfirmed = $true }
                [PSCustomObject]@{ Name = 'avd-02'; VMConfirmed = $false; EntraIDConfirmed = $true; IntuneConfirmed = $true }
            )
        }
        $global:shrSimulation.Plan = [PSCustomObject]@{
            PossibleDeploymentsCount = 2
            PossibleSessionHostDeleteCount = 0
            SessionHostsPendingDelete = @()
            ExistingSessionHostNames = @()
            TargetSessionHostCount = 2
            TotalSessionHostsToReplace = 2
        }

        $recoveryError = $null
        try { Invoke-OrchestrationCycle -RunNumber 2 } catch { $recoveryError = $_ }
        $recoveryError | Should Not BeNullOrEmpty
        $global:shrSimulation.DeploymentCalls.Count | Should Be 1
        $global:shrSimulation.DeletionCalls.Count | Should Be 1
    }

    It 'DeleteFirst rechecks partial directory cleanup and blocks hostname reuse until all systems confirm deletion' {
        $global:shrSimulation.Mode = 'DeleteFirst'
        $global:shrSettings.ReplacementMode = 'DeleteFirst'
        $global:shrSettings.RemoveEntraDevice = $true
        $global:shrSettings.RemoveIntuneDevice = $true
        $initialHosts = @($global:shrSimulation.Hosts)
        $partialResult = [PSCustomObject]@{
            TotalHosts = 2
            VMsConfirmed = 2
            EntraIDConfirmed = 2
            IntuneConfirmed = 1
            IncompleteHosts = @(
                [PSCustomObject]@{
                    Name = 'avd-02'
                    VMConfirmed = $true
                    EntraIDConfirmed = $true
                    IntuneConfirmed = $false
                }
            )
        }
        $global:shrSimulation.VerificationResults[1] = $partialResult
        $global:shrSimulation.VerificationResults[2] = $partialResult
        $global:shrSimulation.VerificationResults[3] = [PSCustomObject]@{
            TotalHosts = 2
            VMsConfirmed = 2
            EntraIDConfirmed = 2
            IntuneConfirmed = 2
            IncompleteHosts = @()
        }
        $global:shrSimulation.Plan = [PSCustomObject]@{
            PossibleDeploymentsCount = 2
            PossibleSessionHostDeleteCount = 2
            SessionHostsPendingDelete = $initialHosts
            ExistingSessionHostNames = @($initialHosts.SessionHostName)
            TargetSessionHostCount = 2
            TotalSessionHostsToReplace = 2
        }

        $firstError = $null
        try { Invoke-OrchestrationCycle -RunNumber 1 } catch { $firstError = $_ }
        $firstError | Should Not BeNullOrEmpty
        $global:shrSimulation.DeletionCalls.Count | Should Be 1
        $global:shrSimulation.DeploymentCalls.Count | Should Be 0

        $global:shrSimulation.Plan = [PSCustomObject]@{
            PossibleDeploymentsCount = 2
            PossibleSessionHostDeleteCount = 0
            SessionHostsPendingDelete = @()
            ExistingSessionHostNames = @()
            TargetSessionHostCount = 2
            TotalSessionHostsToReplace = 2
        }
        $secondError = $null
        try { Invoke-OrchestrationCycle -RunNumber 2 } catch { $secondError = $_ }
        $secondError | Should Not BeNullOrEmpty
        $global:shrSimulation.VerificationCalls.Count | Should Be 2
        @($global:shrSimulation.DirectoryCleanupCalls | Where-Object Run -eq 2).Count | Should Be 2
        $global:shrSimulation.DeploymentCalls.Count | Should Be 0

        Invoke-OrchestrationCycle -RunNumber 3
        $global:shrSimulation.VerificationCalls.Count | Should Be 3
        $global:shrSimulation.DeletionCalls.Count | Should Be 1
        $global:shrSimulation.DeploymentCalls.Count | Should Be 1
        $global:shrSimulation.DeploymentCalls[0].PreferredNames | Should Be @('avd-01', 'avd-02')
    }

    It 'DeleteFirst performs no destructive operation when the recovery checkpoint cannot be saved' {
        $global:shrSimulation.Mode = 'DeleteFirst'
        $global:shrSettings.ReplacementMode = 'DeleteFirst'
        $global:shrSimulation.FailRequiredSave = $true
        $hosts = @($global:shrSimulation.Hosts)
        $global:shrSimulation.Plan = [PSCustomObject]@{
            PossibleDeploymentsCount = 2
            PossibleSessionHostDeleteCount = 2
            SessionHostsPendingDelete = $hosts
            ExistingSessionHostNames = @($hosts.SessionHostName)
            TargetSessionHostCount = 2
            TotalSessionHostsToReplace = 2
        }

        $caughtError = $null
        try { Invoke-OrchestrationCycle -RunNumber 1 } catch { $caughtError = $_ }
        if (@($global:shrSimulation.SaveCalls | Where-Object Required).Count -eq 0) {
            throw "Required save boundary was not reached. Error: $caughtError Logs: $($global:shrSimulation.Logs -join ' | ')"
        }
        @($global:shrSimulation.SaveCalls | Where-Object Required).Count | Should Be 1
        $caughtError | Should Not BeNullOrEmpty
        $global:shrSimulation.DeletionCalls.Count | Should Be 0
        $global:shrSimulation.DeploymentCalls.Count | Should Be 0
    }

    It 'DeleteFirst fails closed when pending recovery mappings are invalid: <Value>' -TestCases @(
        @{ Value = '{invalid-json' }
        @{ Value = '[]' }
    ) {
        param ($Value)

        $global:shrSimulation.Mode = 'DeleteFirst'
        $global:shrSettings.ReplacementMode = 'DeleteFirst'
        $global:shrSimulation.DeploymentState.PendingHostMappings = $Value
        $global:shrSimulation.Plan = [PSCustomObject]@{
            PossibleDeploymentsCount = 2
            PossibleSessionHostDeleteCount = 2
            SessionHostsPendingDelete = @($global:shrSimulation.Hosts)
            ExistingSessionHostNames = @($global:shrSimulation.Hosts.SessionHostName)
            TargetSessionHostCount = 2
            TotalSessionHostsToReplace = 2
        }

        $caughtError = $null
        try { Invoke-OrchestrationCycle -RunNumber 1 } catch { $caughtError = $_ }
        if (-not $caughtError) {
            throw "Malformed recovery state did not fail closed. Mode: $($global:shrSettings.ReplacementMode) State: $($global:shrSimulation.DeploymentState.PendingHostMappings) Logs: $($global:shrSimulation.Logs -join ' | ')"
        }
        $global:shrSimulation.DeletionCalls.Count | Should Be 0
        $global:shrSimulation.DeploymentCalls.Count | Should Be 0
    }
}
