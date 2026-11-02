$repoRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\functions\Modules\SessionHostReplacer\SessionHostReplacer.psd1'

Describe 'SHR read-only timer idle assessment' {
    BeforeAll {
        Import-Module $modulePath -Force
        function Invoke-IdleAssessment {
            & (Get-Module SessionHostReplacer.Continuation -All) {
                param($Image)
                Test-ShrPoolIdle -LatestImageVersion $Image
            } $global:shrIdleTest.Image
        }
    }

    BeforeEach {
        $definition = '/gallery/images/avd'
        $token = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes("$definition|2.0.0")
        )).ToLowerInvariant()
        $vmId = '/subscriptions/test/resourceGroups/hosts/providers/Microsoft.Compute/virtualMachines/avd-01'
        $global:shrIdleTest = @{
            Image = @{ Definition = $definition; Version = '2.0.0'; Date = [DateTimeOffset]::UtcNow.AddDays(-2).ToString('o') }
            State = [PSCustomObject]@{
                LastStatus = 'Success'; LastDeploymentName = ''; LastTotalToReplace = 0
                TargetSessionHostCount = 0; PendingHostMappings = '{}'; ActiveMaintenanceRequestId = ''
            }
            Settings = @{
                VirtualMachinesSubscriptionId = 'test'; VirtualMachinesResourceGroupName = 'hosts'
                HostPoolSubscriptionId = 'test'; HostPoolResourceGroupName = 'control'; HostPoolName = 'hp'
                ReplacementMode = 'SideBySide'; TargetSessionHostCount = 1; MaxDeploymentBatchSize = 10
                MinimumCapacityPercentage = 80; MaxDeletionsPerCycle = 10; DrainGracePeriodHours = 24
                ReplaceSessionHostOnNewImageVersionDelayDays = 0; AllowImageVersionRollback = $false
                EnableProgressiveScaleUp = $false; IncludePreExistingSessionHosts = $true
                FixSessionHostTags = $true; Tag_DeployTimestamp = 'DeployTimestamp'
                Tag_IncludeInAutomation = 'IncludeInAutomation'; Tag_PendingDrainTimestamp = 'PendingDrain'
                Tag_ShutdownTimestamp = 'ShutdownTimestamp'; Tag_ScalingPlanExclusionTag = 'ScalingPlanExclusion'
                Tag_ValidatedImage = 'AutoReplaceValidatedImage'
            }
            VMs = @([PSCustomObject]@{
                id = $vmId; name = 'avd-01'
                properties = [PSCustomObject]@{
                    timeCreated = [datetime]::UtcNow.AddDays(-2)
                    storageProfile = [PSCustomObject]@{
                        imageReference = [PSCustomObject]@{ id = "$definition/versions/2.0.0"; exactVersion = '2.0.0' }
                    }
                }
                tags = [PSCustomObject]@{
                    DeployTimestamp = [datetime]::UtcNow.AddDays(-2).ToString('o')
                    IncludeInAutomation = 'True'; AutoReplaceValidatedImage = $token
                }
            })
            Registrations = @([PSCustomObject]@{
                name = 'hp/avd-01.example.test'
                properties = [PSCustomObject]@{
                    resourceId = $vmId; sessions = 0; allowNewSession = $true; status = 'Available'
                    sessionHostHealthCheckResults = @([PSCustomObject]@{ healthCheckResult = 'HealthCheckSucceeded' })
                }
            })
            Deployments = @{ RunningDeployments = @(); FailedDeployments = @() }
            ScalingTarget = [PSCustomObject]@{ Source = 'Disabled'; CapacityPercentage = $null }
            PowerStates = @{}
        }
        foreach ($moduleName in @('SessionHostReplacer.Continuation', 'SessionHostReplacer.Planning', 'SessionHostReplacer.Lifecycle')) {
            Mock Read-FunctionAppSetting -ModuleName $moduleName {
                param($SettingKey, [switch] $AsBoolean)
                if ($AsBoolean) { return [bool]$global:shrIdleTest.Settings[$SettingKey] }
                $global:shrIdleTest.Settings[$SettingKey]
            }
            Mock Write-LogEntry -ModuleName $moduleName {}
            Mock Get-ResourceManagerUri -ModuleName $moduleName { 'https://management.azure.com' }
        }
        foreach ($moduleName in @('SessionHostReplacer.Continuation', 'SessionHostReplacer.Planning')) {
            Mock Get-DeploymentState -ModuleName $moduleName { $global:shrIdleTest.State }
            Mock Save-DeploymentState -ModuleName $moduleName { throw 'Preflight must not persist state.' }
        }
        Mock Get-AccessToken -ModuleName SessionHostReplacer.Continuation { 'token' }
        Mock Invoke-AzureRestMethod -ModuleName SessionHostReplacer.Continuation {
            param($Method, $RequireCollection)
            if ($Method -ne 'Get' -or -not $RequireCollection) { throw 'Expected a read-only VM collection query.' }
            $global:shrIdleTest.VMs
        }
        Mock Invoke-AzureRestMethod -ModuleName SessionHostReplacer.Planning {
            param($Method, $Uri, $RequireCollection)
            if ($Method -ne 'Get' -or $Uri -notlike '*/sessionHosts?*' -or -not $RequireCollection) {
                throw 'Expected a read-only registration collection query.'
            }
            $global:shrIdleTest.Registrations
        }
        Mock Invoke-AzureRestMethod -ModuleName SessionHostReplacer.Lifecycle { throw 'Preflight must not modify tags.' }
        Mock Get-Deployments -ModuleName SessionHostReplacer.Continuation { $global:shrIdleTest.Deployments }
        Mock Get-ScalingPlanCurrentTarget -ModuleName SessionHostReplacer.Continuation {
            param($HostPoolResourceId)
            if ($HostPoolResourceId -ne '/subscriptions/test/resourceGroups/control/providers/Microsoft.DesktopVirtualization/hostPools/hp') {
                throw 'Incorrect host pool scope.'
            }
            $global:shrIdleTest.ScalingTarget
        }
        Mock Get-VMPowerStates -ModuleName SessionHostReplacer.Planning { $global:shrIdleTest.PowerStates }
        Mock Get-VMPowerStates -ModuleName SessionHostReplacer.Lifecycle { $global:shrIdleTest.PowerStates }
        Mock Get-ShrWorkerState -ModuleName SessionHostReplacer.Planning { $null }
    }

    AfterAll {
        Remove-Variable shrIdleTest -Scope Global -ErrorAction SilentlyContinue
        Remove-Module SessionHostReplacer -Force
    }

    It 'recognizes an idle <Mode> pool using the real planner and readiness gates' -TestCases @(
        @{ Mode = 'SideBySide' }
        @{ Mode = 'DeleteFirst' }
    ) {
        param($Mode)
        $global:shrIdleTest.Settings.ReplacementMode = $Mode
        Invoke-IdleAssessment | Should Be $true
        Assert-MockCalled Save-DeploymentState -ModuleName SessionHostReplacer.Planning -Times 0 -Exactly -Scope It
        Assert-MockCalled Invoke-AzureRestMethod -ModuleName SessionHostReplacer.Lifecycle -Times 0 -Exactly -Scope It
    }

    It 'does not initialize or clear auto-target state during a read-only plan' {
        $global:shrIdleTest.Settings.TargetSessionHostCount = 0
        Invoke-IdleAssessment | Should Be $true
        Assert-MockCalled Save-DeploymentState -ModuleName SessionHostReplacer.Planning -Times 0 -Exactly -Scope It
        Assert-MockCalled Get-DeploymentState -ModuleName SessionHostReplacer.Planning -ParameterFilter { $ReadOnly } -Times 1 -Exactly -Scope It
    }

    It 'hands off <Kind> recovery or maintenance work' -TestCases @(
        @{ Kind = 'deployment'; Field = 'LastDeploymentName'; Value = 'shr_pending' }
        @{ Kind = 'stored target'; Field = 'TargetSessionHostCount'; Value = 2 }
        @{ Kind = 'unfinished replacement'; Field = 'LastTotalToReplace'; Value = 1 }
        @{ Kind = 'recovery mappings'; Field = 'PendingHostMappings'; Value = '{"avd-02":{}}' }
        @{ Kind = 'active maintenance'; Field = 'ActiveMaintenanceRequestId'; Value = 'request-1' }
    ) {
        param($Kind, $Field, $Value)
        $global:shrIdleTest.State.$Field = $Value
        Invoke-IdleAssessment | Should Be $false
    }

    It 'hands off a configured maintenance request without bypassing its engine checks' {
        $global:shrIdleTest.Settings.MaintenanceRequest = '{"RequestId":"request-1"}'
        Invoke-IdleAssessment | Should Be $false
    }

    It 'surfaces unreadable recovery state' {
        $global:shrIdleTest.State.LastStatus = 'Error'
        { Invoke-IdleAssessment } | Should Throw 'readable deployment recovery state'
    }

    It 'surfaces malformed pending mappings' {
        $global:shrIdleTest.State.PendingHostMappings = '[]'
        { Invoke-IdleAssessment } | Should Throw 'PendingHostMappings must be a JSON object'
    }

    It 'surfaces inventory failure rather than declaring the pool idle' {
        Mock Invoke-AzureRestMethod -ModuleName SessionHostReplacer.Continuation { throw 'inventory unavailable' }
        { Invoke-IdleAssessment } | Should Throw 'inventory unavailable'
    }

    It 'surfaces scaling query failures rather than declaring the pool idle' {
        $global:shrIdleTest.ScalingTarget.Source = 'Error'
        { Invoke-IdleAssessment } | Should Throw 'scaling plan query failed'
    }

    It 'hands off retained inventory even when it is no longer registered' {
        $global:shrIdleTest.VMs[0].tags | Add-Member ShutdownTimestamp '2026-01-01T00:00:00Z'
        $global:shrIdleTest.Registrations = @()
        Invoke-IdleAssessment | Should Be $false
    }

    It 'hands off empty pools instead of inferring successful auto-capacity' {
        $global:shrIdleTest.Registrations = @()
        Invoke-IdleAssessment | Should Be $false
    }

    It 'hands off missing registrations or failed health checks' {
        $global:shrIdleTest.Registrations[0].properties.sessionHostHealthCheckResults[0].healthCheckResult = 'HealthCheckFailed'
        Invoke-IdleAssessment | Should Be $false
    }

    It 'hands off draining hosts' {
        $global:shrIdleTest.Registrations[0].properties.allowNewSession = $false
        Invoke-IdleAssessment | Should Be $false
    }

    It 'hands off missing validation evidence without writing it in the timer' {
        $global:shrIdleTest.VMs[0].tags.AutoReplaceValidatedImage = ''
        Invoke-IdleAssessment | Should Be $false
    }

    It 'hands off SHR-owned scaling exclusions' {
        $global:shrIdleTest.VMs[0].tags | Add-Member ScalingPlanExclusion 'SessionHostReplacer'
        Invoke-IdleAssessment | Should Be $false
    }

    It 'hands off configured VM tag repairs' {
        $global:shrIdleTest.VMs[0].tags.IncludeInAutomation = ''
        Invoke-IdleAssessment | Should Be $false
    }

    It 'hands off <Kind> deployments' -TestCases @(
        @{ Kind = 'running'; Field = 'RunningDeployments' }
        @{ Kind = 'failed'; Field = 'FailedDeployments' }
    ) {
        param($Kind, $Field)
        $global:shrIdleTest.Deployments[$Field] = @([PSCustomObject]@{ DeploymentName = 'pending' })
        Invoke-IdleAssessment | Should Be $false
    }

    It 'handles null deployment collections as empty rather than as one deployment' {
        $global:shrIdleTest.Deployments = @{ RunningDeployments = $null; FailedDeployments = $null }
        Invoke-IdleAssessment | Should Be $true
    }

    It 'hands off capacity deficits' {
        $global:shrIdleTest.Settings.TargetSessionHostCount = 2
        Invoke-IdleAssessment | Should Be $false
    }

    It 'hands off a newer eligible image through the shared image policy' {
        $global:shrIdleTest.Image.Version = '3.0.0'
        Invoke-IdleAssessment | Should Be $false
    }

    It 'does not count a stopped host as ready when its scaling plan is disabled' {
        $global:shrIdleTest.Registrations[0].properties.status = 'Shutdown'
        $global:shrIdleTest.PowerStates[$global:shrIdleTest.VMs[0].id] = $true
        Invoke-IdleAssessment | Should Be $false
    }

    It 'accepts validated scalable standby only while the shared online floor is met' {
        $standbyVM = $global:shrIdleTest.VMs[0] | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $standbyVM.name = 'avd-02'
        $standbyVM.id = $standbyVM.id.Replace('avd-01', 'avd-02')
        $standbyHost = $global:shrIdleTest.Registrations[0] | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $standbyHost.name = 'hp/avd-02.example.test'
        $standbyHost.properties.resourceId = $standbyVM.id
        $standbyHost.properties.status = 'Shutdown'
        $global:shrIdleTest.VMs += $standbyVM
        $global:shrIdleTest.Registrations += $standbyHost
        $global:shrIdleTest.Settings.TargetSessionHostCount = 2
        $global:shrIdleTest.ScalingTarget = [PSCustomObject]@{ Source = 'ScalingPlan'; CapacityPercentage = 50 }
        $global:shrIdleTest.PowerStates[$standbyVM.id] = $true
        Invoke-IdleAssessment | Should Be $true
        $global:shrIdleTest.ScalingTarget.CapacityPercentage = 100
        Invoke-IdleAssessment | Should Be $false
    }
}

Describe 'SHR read-only deployment state retrieval' {
    BeforeAll {
        Import-Module $modulePath -Force
        $originalBlobUri = $env:AzureWebJobsStorage__blobServiceUri
        $originalStorageSuffix = $env:StorageSuffix
        $env:AzureWebJobsStorage__blobServiceUri = 'https://teststorage.blob.core.windows.net'
        $env:StorageSuffix = 'core.windows.net'
    }
    BeforeEach {
        Mock Write-LogEntry -ModuleName SessionHostReplacer.Deployment {}
        Mock Get-AccessToken -ModuleName SessionHostReplacer.Deployment { 'token' }
        Mock Invoke-RestMethod -ModuleName SessionHostReplacer.Deployment {
            param($Method, $Uri)
            if ($Method -ne 'Get' -or $Uri -like '*/Tables') { throw 'Unexpected storage initialization.' }
            [PSCustomObject]@{ LastStatus = 'Success'; PendingHostMappings = '{}' }
        }
    }
    AfterAll {
        $env:AzureWebJobsStorage__blobServiceUri = $originalBlobUri
        $env:StorageSuffix = $originalStorageSuffix
        Remove-Module SessionHostReplacer -Force
    }
    It 'only reads the state entity and does not create its table' {
        $state = Get-DeploymentState -HostPoolName 'hp' -ClientId 'identity' -ReadOnly
        $state.LastStatus | Should Be 'Success'
        Assert-MockCalled Invoke-RestMethod -ModuleName SessionHostReplacer.Deployment -Times 1 -Exactly -Scope It
    }
    It 'throws storage failures instead of returning default success-shaped state' {
        Mock Invoke-RestMethod -ModuleName SessionHostReplacer.Deployment { throw 'storage unavailable' }
        { Get-DeploymentState -HostPoolName 'hp' -ClientId 'identity' -ReadOnly } | Should Throw 'storage unavailable'
    }
}
