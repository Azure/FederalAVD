BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $modulePath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\functions\Modules\SessionHostReplacer\SessionHostReplacer.psd1'
}

Describe 'SHR scaling exclusion configuration' {
    BeforeAll { Import-Module $modulePath -Force }
    AfterAll { Remove-Module SessionHostReplacer -Force }
    BeforeEach {
        $global:shrScalingPlan = [pscustomobject]@{
            name = 'shared-plan'
            properties = [pscustomobject]@{
                exclusionTag = 'ScalingPlanExclusion'
                hostPoolReferences = @([pscustomobject]@{
                    hostPoolArmPath = '/subscriptions/test/resourceGroups/hosts/providers/Microsoft.DesktopVirtualization/hostPools/pool'
                    scalingPlanEnabled = $true
                })
            }
        }
        Mock Write-LogEntry -ModuleName SessionHostReplacer.Planning {}
        Mock Invoke-AzureRestMethod -ModuleName SessionHostReplacer.Planning {
            param($Method)
            if ($Method -ne 'Get') { throw 'Scaling plan configuration must be read-only.' }
            @($global:shrScalingPlan)
        }
    }
    AfterEach { Remove-Variable shrScalingPlan -Scope Global }

    It 'blocks an enabled plan with <Reason> even without an evaluable schedule' -TestCases @(
        @{ Reason = 'a missing tag'; Actual = $null; Expected = 'ScalingPlanExclusion' }
        @{ Reason = 'an empty tag'; Actual = ''; Expected = 'ScalingPlanExclusion' }
        @{ Reason = 'a whitespace tag'; Actual = ' '; Expected = 'ScalingPlanExclusion' }
        @{ Reason = 'a different tag'; Actual = 'AdminMaintenance'; Expected = 'ScalingPlanExclusion' }
        @{ Reason = 'a disabled SHR tag'; Actual = 'ScalingPlanExclusion'; Expected = ' ' }
    ) {
        param($Reason, $Actual, $Expected)
        $global:shrScalingPlan.properties.exclusionTag = $Actual
        $target = Get-ScalingPlanCurrentTarget -ARMToken token `
            -HostPoolResourceId $global:shrScalingPlan.properties.hostPoolReferences[0].hostPoolArmPath `
            -ResourceManagerUri 'https://management.azure.com' -TagScalingPlanExclusionTag $Expected
        $target.Source | Should -Be 'InvalidExclusionTag'
        $target.ErrorMessage | Should -Match 'shared-plan'
        $target.ErrorMessage | Should -Match 'same nonempty tag name'
        $global:shrScalingPlan.properties.exclusionTag | Should -Be $Actual
        Assert-MockCalled Invoke-AzureRestMethod -ModuleName SessionHostReplacer.Planning -Times 1 -Exactly -Scope It
    }

    It 'accepts matching <Tag> tag names without requiring matching capitalization' -TestCases @(
        @{ Tag = 'ScalingPlanExclusion' }
        @{ Tag = 'CustomMaintenance' }
    ) {
        param($Tag)
        $global:shrScalingPlan.properties.exclusionTag = $Tag.ToLowerInvariant()
        $target = Get-ScalingPlanCurrentTarget -ARMToken token `
            -HostPoolResourceId $global:shrScalingPlan.properties.hostPoolReferences[0].hostPoolArmPath `
            -ResourceManagerUri 'https://management.azure.com' -TagScalingPlanExclusionTag $Tag
        $target.Source | Should -Be 'NoTimeZone'
    }

    It 'does not require an exclusion tag on a disabled plan' {
        $global:shrScalingPlan.properties.exclusionTag = ''
        $global:shrScalingPlan.properties.hostPoolReferences[0].scalingPlanEnabled = $false
        $target = Get-ScalingPlanCurrentTarget -ARMToken token `
            -HostPoolResourceId $global:shrScalingPlan.properties.hostPoolReferences[0].hostPoolArmPath `
            -ResourceManagerUri 'https://management.azure.com' -TagScalingPlanExclusionTag ''
        $target.Source | Should -Be 'Disabled'
    }

    It 'allows a pool with no scaling plan' {
        Mock Invoke-AzureRestMethod -ModuleName SessionHostReplacer.Planning { @() }
        $target = Get-ScalingPlanCurrentTarget -ARMToken token -HostPoolResourceId '/pool' `
            -ResourceManagerUri 'https://management.azure.com' -TagScalingPlanExclusionTag ''
        $target.Source | Should -BeNullOrEmpty
    }

    It 'reports a failed scaling query without making it look like no plan exists' {
        Mock Invoke-AzureRestMethod -ModuleName SessionHostReplacer.Planning { throw 'Access denied' }
        $target = Get-ScalingPlanCurrentTarget -ARMToken token -HostPoolResourceId '/pool' `
            -ResourceManagerUri 'https://management.azure.com' -TagScalingPlanExclusionTag 'ScalingPlanExclusion'
        $target.Source | Should -Be 'Error'
        $target.ErrorMessage | Should -Match 'Access denied'
    }
}

Describe 'SHR unshared scaling plan repair' {
    BeforeAll { Import-Module $modulePath -Force }
    AfterAll { Remove-Module SessionHostReplacer -Force }
    BeforeEach {
        $poolId = '/subscriptions/test/resourceGroups/hosts/providers/Microsoft.DesktopVirtualization/hostPools/pool'
        $planId = '/subscriptions/test/resourceGroups/scaling/providers/Microsoft.DesktopVirtualization/scalingPlans/plan'
        $global:shrPlanRepair = @{
            Plan = [pscustomobject]@{
                id = $planId; name = 'plan'; etag = '"v1"'
                properties = [pscustomobject]@{
                    exclusionTag = ''
                    hostPoolReferences = @([pscustomobject]@{ hostPoolArmPath = $poolId; scalingPlanEnabled = $true })
                }
            }
            Requests = @(); Registrations = @(); DirectReads = 0
            ShareAtRead = 0; DenyPlanWrite = $false; IgnorePlanWrite = $false
            DenyVmWrite = $false; IgnoreVmWrite = $false
            Vm = [pscustomobject]@{
                id = '/subscriptions/test/resourceGroups/hosts/providers/Microsoft.Compute/virtualMachines/host1'
                tags = @{}
            }
        }
        $global:shrPlanRepair.ListPlan = $global:shrPlanRepair.Plan | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $repairParameters = @{
            ARMToken = 'token'; HostPoolResourceId = $poolId
            ResourceManagerUri = 'https://management.azure.com'
            TagScalingPlanExclusionTag = 'ScalingPlanExclusion'; RepairExclusionTag = $true
        }
        Mock Write-LogEntry -ModuleName SessionHostReplacer.Planning {}
        Mock Invoke-AzureRestMethod -ModuleName SessionHostReplacer.Planning {
            param($Method, $Uri, $Body, $AdditionalHeaders, $RequireCollection)
            $state = $global:shrPlanRepair
            $parsed = if ($Body) { $Body | ConvertFrom-Json }
            $state.Requests += [pscustomobject]@{
                Method = $Method; Uri = $Uri; Body = $parsed; Headers = $AdditionalHeaders
            }
            if ($Method -eq 'Get' -and $Uri -like '*/hostPools/pool/scalingPlans?*') {
                if (-not $RequireCollection) { throw 'Discovery requires a validated collection.' }
                return @($state.ListPlan)
            }
            if ($Method -eq 'Get' -and $Uri -like '*/hostPools/pool/sessionHosts?*') {
                if (-not $RequireCollection) { throw 'Migration requires a validated registration collection.' }
                return @($state.Registrations)
            }
            if ($Uri -like '*/scalingPlans/plan?*') {
                if ($Method -eq 'Get') {
                    $state.DirectReads++
                    if ($state.DirectReads -eq $state.ShareAtRead) {
                        $state.Plan.properties.hostPoolReferences += [pscustomobject]@{
                            hostPoolArmPath = '/another/pool'; scalingPlanEnabled = $false
                        }
                    }
                    return ($state.Plan | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
                }
                if ($Method -eq 'Patch') {
                    if ($state.DenyPlanWrite) { throw 'Scaling plan write denied' }
                    if (-not $state.IgnorePlanWrite) {
                        $state.Plan.properties.exclusionTag = $parsed.properties.exclusionTag
                    }
                    return
                }
            }
            if ($Method -eq 'Get' -and $Uri -like '*/virtualMachines/host1?*') {
                return ($state.Vm | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
            }
            if ($Method -eq 'Patch' -and $Uri -like '*/virtualMachines/host1/providers/Microsoft.Resources/tags/default?*') {
                if ($state.DenyVmWrite) { throw 'VM tag write denied' }
                if (-not $state.IgnoreVmWrite) {
                    foreach ($tag in $parsed.properties.tags.PSObject.Properties) {
                        $state.Vm.tags[$tag.Name] = $tag.Value
                    }
                }
                return
            }
            throw "Unexpected request: $Method $Uri"
        }
    }
    AfterEach { Remove-Variable shrPlanRepair -Scope Global }

    It 'repairs and verifies an unshared plan with exclusion "<Previous>"' -TestCases @(
        @{ Previous = '' }
        @{ Previous = ' ' }
        @{ Previous = 'LegacyMaintenance' }
    ) {
        param($Previous)
        $global:shrPlanRepair.Plan.properties.exclusionTag = $Previous
        $target = Get-ScalingPlanCurrentTarget @repairParameters
        $target.Source | Should -Be 'NoTimeZone'
        $global:shrPlanRepair.Plan.properties.exclusionTag | Should -Be 'ScalingPlanExclusion'
        $writes = @($global:shrPlanRepair.Requests | Where-Object Method -eq 'Patch')
        $writes.Count | Should -Be 1
        $writes[0].Body.properties.PSObject.Properties.Name | Should -Be @('exclusionTag')
        $writes[0].Headers['If-Match'] | Should -Be '"v1"'
        $global:shrPlanRepair.DirectReads | Should -Be 3
    }

    It 'leaves discovery read-only and marks unshared mismatches for worker repair' {
        $repairParameters.RepairExclusionTag = $false
        $target = Get-ScalingPlanCurrentTarget @repairParameters
        $target.Source | Should -Be 'InvalidExclusionTag'
        $target.CanRepairExclusionTag | Should -Be $true
        @($global:shrPlanRepair.Requests | Where-Object Method -ne 'Get').Count | Should -Be 0
    }

    It 'rejects a shared mismatch even when the other assignment is enabled=<Enabled>' -TestCases @(
        @{ Enabled = $true }
        @{ Enabled = $false }
    ) {
        param($Enabled)
        $global:shrPlanRepair.Plan.properties.hostPoolReferences += [pscustomobject]@{
            hostPoolArmPath = '/another/pool'; scalingPlanEnabled = $Enabled
        }
        $target = Get-ScalingPlanCurrentTarget @repairParameters
        $target.Source | Should -Be 'InvalidExclusionTag'
        $target.CanRepairExclusionTag | Should -Be $false
        @($global:shrPlanRepair.Requests | Where-Object Method -ne 'Get').Count | Should -Be 0
    }

    It 'accepts an already-matching shared plan without updating it' {
        $global:shrPlanRepair.Plan.properties.exclusionTag = 'ScalingPlanExclusion'
        $global:shrPlanRepair.Plan.properties.hostPoolReferences += [pscustomobject]@{
            hostPoolArmPath = '/another/pool'; scalingPlanEnabled = $true
        }
        $target = Get-ScalingPlanCurrentTarget @repairParameters
        $target.Source | Should -Be 'NoTimeZone'
        @($global:shrPlanRepair.Requests | Where-Object Method -ne 'Get').Count | Should -Be 0
    }

    It 'blocks a plan that becomes shared before the update' {
        $global:shrPlanRepair.ShareAtRead = 2
        $target = Get-ScalingPlanCurrentTarget @repairParameters
        $target.Source | Should -Be 'Error'
        $target.ErrorMessage | Should -Match 'shared'
        @($global:shrPlanRepair.Requests | Where-Object Method -eq 'Patch').Count | Should -Be 0
    }

    It 'blocks unknown or changed full-plan membership' {
        $global:shrPlanRepair.Plan.properties.hostPoolReferences = @()
        $target = Get-ScalingPlanCurrentTarget @repairParameters
        $target.Source | Should -Be 'Error'
        @($global:shrPlanRepair.Requests | Where-Object Method -eq 'Patch').Count | Should -Be 0
    }

    It 'surfaces permission failures and unsuccessful read-back verification' -TestCases @(
        @{ Failure = 'DenyPlanWrite' }
        @{ Failure = 'IgnorePlanWrite' }
    ) {
        param($Failure)
        $global:shrPlanRepair[$Failure] = $true
        $target = Get-ScalingPlanCurrentTarget @repairParameters
        $target.Source | Should -Be 'Error'
        $global:shrPlanRepair.Plan.properties.exclusionTag | Should -Be ''
    }

    It 'preserves existing VM exclusion value "<Value>" before changing a nonblank plan tag' -TestCases @(
        @{ Value = 'Administrator' }
        @{ Value = '' }
        @{ Value = 'SessionHostReplacer' }
    ) {
        param($Value)
        $global:shrPlanRepair.Plan.properties.exclusionTag = 'LegacyMaintenance'
        $global:shrPlanRepair.Vm.tags.LegacyMaintenance = $Value
        $global:shrPlanRepair.Registrations = @([pscustomobject]@{
            properties = @{ resourceId = $global:shrPlanRepair.Vm.id }
        })
        $target = Get-ScalingPlanCurrentTarget @repairParameters
        $target.Source | Should -Be 'NoTimeZone'
        $global:shrPlanRepair.Vm.tags.LegacyMaintenance | Should -Be $Value
        $global:shrPlanRepair.Vm.tags.ScalingPlanExclusion | Should -Be $Value
        $writes = @($global:shrPlanRepair.Requests | Where-Object Method -eq 'Patch')
        $writes.Count | Should -Be 2
        $writes[0].Uri | Should -Match '/tags/default'
        $writes[1].Uri | Should -Match '/scalingPlans/plan'
    }

    It 'preserves existing administrator ownership under the new tag name' {
        $global:shrPlanRepair.Plan.properties.exclusionTag = 'LegacyMaintenance'
        $global:shrPlanRepair.Vm.tags = @{ LegacyMaintenance = 'SessionHostReplacer'; ScalingPlanExclusion = 'Administrator' }
        $global:shrPlanRepair.Registrations = @([pscustomobject]@{ properties = @{ resourceId = $global:shrPlanRepair.Vm.id } })
        $target = Get-ScalingPlanCurrentTarget @repairParameters
        $target.Source | Should -Be 'NoTimeZone'
        $global:shrPlanRepair.Vm.tags.ScalingPlanExclusion | Should -Be 'Administrator'
        @($global:shrPlanRepair.Requests | Where-Object Method -eq 'Patch').Count | Should -Be 1
    }

    It 'does not turn a legacy administrator exclusion into a releasable SHR exclusion' {
        $global:shrPlanRepair.Plan.properties.exclusionTag = 'LegacyMaintenance'
        $global:shrPlanRepair.Vm.tags = @{ LegacyMaintenance = ''; ScalingPlanExclusion = 'SessionHostReplacer' }
        $global:shrPlanRepair.Registrations = @([pscustomobject]@{ properties = @{ resourceId = $global:shrPlanRepair.Vm.id } })
        $target = Get-ScalingPlanCurrentTarget @repairParameters
        $target.Source | Should -Be 'NoTimeZone'
        $global:shrPlanRepair.Vm.tags.ScalingPlanExclusion | Should -Be ''
    }

    It 'does not update the plan if VM exclusion migration fails or cannot be verified' -TestCases @(
        @{ Failure = 'DenyVmWrite' }
        @{ Failure = 'IgnoreVmWrite' }
    ) {
        param($Failure)
        $global:shrPlanRepair.Plan.properties.exclusionTag = 'LegacyMaintenance'
        $global:shrPlanRepair.Vm.tags.LegacyMaintenance = 'Administrator'
        $global:shrPlanRepair.Registrations = @([pscustomobject]@{ properties = @{ resourceId = $global:shrPlanRepair.Vm.id } })
        $global:shrPlanRepair[$Failure] = $true
        $target = Get-ScalingPlanCurrentTarget @repairParameters
        $target.Source | Should -Be 'Error'
        @($global:shrPlanRepair.Requests | Where-Object {
            $_.Method -eq 'Patch' -and $_.Uri -like '*/scalingPlans/plan?*'
        }).Count | Should -Be 0
    }
}

Describe 'SHR retirement scaling protection' {
    BeforeAll { Import-Module $modulePath -Force }
    AfterAll { Remove-Module SessionHostReplacer -Force }
    BeforeEach {
        $global:shrRetirement = @{
            Requests = @()
            FailProtection = $false
            Host = [pscustomobject]@{
                SessionHostName = 'old-08'; VMName = 'old-08'; FQDN = 'old-08.example.test'
                ResourceId = '/subscriptions/test/resourceGroups/hosts/providers/Microsoft.Compute/virtualMachines/old-08'
                Sessions = 2; AllowNewSession = $true; PoweredOff = $false
                PendingDrainTimeStamp = $null; Tags = @{}
            }
        }
        Mock Write-LogEntry -ModuleName SessionHostReplacer.Lifecycle {}
        Mock Read-FunctionAppSetting -ModuleName SessionHostReplacer.Lifecycle { '3' }
        Mock Get-ShrWorkerState -ModuleName SessionHostReplacer.Lifecycle { $null }
        Mock Send-DrainNotification -ModuleName SessionHostReplacer.Lifecycle {}
        Mock Remove-VirtualMachine -ModuleName SessionHostReplacer.Lifecycle { throw 'Unexpected deletion' }
        Mock Remove-SessionHostUserSessions -ModuleName SessionHostReplacer.Lifecycle { throw 'Unexpected logoff' }
        Mock Assert-SessionHostNamesAvailable -ModuleName SessionHostReplacer.Lifecycle {}
        Mock Invoke-AzureRestMethod -ModuleName SessionHostReplacer.Lifecycle {
            param($Method, $Uri, $Body)
            $parsed = if ($Body) { $Body | ConvertFrom-Json }
            if ($global:shrRetirement.FailProtection -and $parsed.properties.tags.ScalingPlanExclusion) {
                throw 'Exclusion tag write denied'
            }
            $global:shrRetirement.Requests += [pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $parsed }
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ statuses = @([pscustomobject]@{ code = 'PowerState/deallocated' }) }
            }
        }
        $retirementParameters = @{
            ARMToken = 'token'; GraphToken = ''; ResourceManagerUri = 'https://management.azure.com'
            SessionHostsPendingDelete = @($global:shrRetirement.Host)
            HostPoolSubscriptionId = 'test'; ResourceGroupName = 'hosts'; HostPoolName = 'pool'
            DrainGracePeriodHours = 24; MinimumDrainMinutes = 60; ReplacementMode = 'SideBySide'
            TagPendingDrainTimeStamp = 'Drain'; TagShutdownTimestamp = 'Retained'
            TagScalingPlanExclusionTag = 'ScalingPlanExclusion'; EnableShutdownRetention = $false
            RemoveEntraDevice = $false; RemoveIntuneDevice = $false; ClientId = 'test'
            MaintenanceLogOffDelayMinutes = 15
        }
    }
    AfterEach { Remove-Variable shrRetirement -Scope Global }

    It 'protects an occupied host before drain mode and does not delete it in <Mode>' -TestCases @(
        @{ Mode = 'SideBySide' }
        @{ Mode = 'DeleteFirst' }
        @{ Mode = 'MaintenanceWindow' }
    ) {
        param($Mode)
        $retirementParameters.ReplacementMode = $Mode
        $result = Remove-SessionHosts @retirementParameters
        $requests = $global:shrRetirement.Requests
        $requests.Count | Should -Be 3
        $requests[0].Body.properties.tags.ScalingPlanExclusion | Should -Be 'SessionHostReplacer'
        $requests[1].Body.properties.allowNewSession | Should -Be $false
        $requests[2].Body.properties.tags.Drain | Should -Not -BeNullOrEmpty
        $result.SuccessfulDeletions.Count | Should -Be 0
    }

    It 'repairs missing protection during an existing drain without resetting the grace period in <Mode>' -TestCases @(
        @{ Mode = 'SideBySide' }
        @{ Mode = 'DeleteFirst' }
        @{ Mode = 'MaintenanceWindow' }
    ) {
        param($Mode)
        $retirementParameters.ReplacementMode = $Mode
        $hostInfo = $global:shrRetirement.Host
        $hostInfo.AllowNewSession = $false
        $hostInfo.PendingDrainTimeStamp = [datetime]::UtcNow.AddMinutes(-1)
        $originalTimestamp = $hostInfo.PendingDrainTimeStamp
        Remove-SessionHosts @retirementParameters | Out-Null
        $global:shrRetirement.Requests.Count | Should -Be 1
        $hostInfo.PendingDrainTimeStamp | Should -Be $originalTimestamp
        $hostInfo.Tags.ScalingPlanExclusion | Should -Be 'SessionHostReplacer'
        Remove-SessionHosts @retirementParameters | Out-Null
        $global:shrRetirement.Requests.Count | Should -Be 1
        Assert-MockCalled Send-DrainNotification -ModuleName SessionHostReplacer.Lifecycle -Times 0 -Exactly -Scope It
    }

    It 'preserves existing exclusion ownership value "<Value>"' -TestCases @(
        @{ Value = 'Administrator' }
        @{ Value = '' }
        @{ Value = 'SessionHostReplacer' }
    ) {
        param($Value)
        $global:shrRetirement.Host.Tags.ScalingPlanExclusion = $Value
        Remove-SessionHosts @retirementParameters | Out-Null
        $global:shrRetirement.Host.Tags.ScalingPlanExclusion | Should -Be $Value
        $global:shrRetirement.Requests.Count | Should -Be 2
        @($global:shrRetirement.Requests | Where-Object { $_.Body.properties.tags.ScalingPlanExclusion }).Count | Should -Be 0
    }

    It 'preserves the original timestamp when reasserting drain after external interference' {
        $originalTimestamp = [datetime]::UtcNow.AddHours(-2)
        $global:shrRetirement.Host.PendingDrainTimeStamp = $originalTimestamp
        Remove-SessionHosts @retirementParameters | Out-Null
        $global:shrRetirement.Host.PendingDrainTimeStamp | Should -Be $originalTimestamp
        ([datetime]$global:shrRetirement.Requests[2].Body.properties.tags.Drain).ToUniversalTime() | Should -Be $originalTimestamp
    }

    It 'stops before drain, notification or deletion when protection cannot be written' {
        $global:shrRetirement.FailProtection = $true
        { Remove-SessionHosts @retirementParameters } | Should -Throw -ExpectedMessage '*Exclusion tag write denied*'
        $global:shrRetirement.Requests.Count | Should -Be 0
        Assert-MockCalled Send-DrainNotification -ModuleName SessionHostReplacer.Lifecycle -Times 0 -Exactly -Scope It
        Assert-MockCalled Remove-VirtualMachine -ModuleName SessionHostReplacer.Lifecycle -Times 0 -Exactly -Scope It
    }

    It 'completes cleanup for an earlier accepted deletion before surfacing a later protection failure' {
        $deletedHost = $global:shrRetirement.Host.PSObject.Copy()
        $deletedHost.Tags = @{ ScalingPlanExclusion = 'SessionHostReplacer' }
        $deletedHost.PoweredOff = $true
        $deletedHost.Sessions = 0
        $retirementParameters.SessionHostsPendingDelete = @($deletedHost, $global:shrRetirement.Host)
        Mock Remove-VirtualMachine -ModuleName SessionHostReplacer.Lifecycle { @{ SessionHostName = 'old-08' } }
        $global:shrRetirement.FailProtection = $true
        { Remove-SessionHosts @retirementParameters } | Should -Throw -ExpectedMessage '*Exclusion tag write denied*'
        Assert-MockCalled Assert-SessionHostNamesAvailable -ModuleName SessionHostReplacer.Lifecycle -Times 1 -Exactly -Scope It
    }

    It 'retires seven idle old hosts while keeping the occupied eighth host drained and protected' {
        $hosts = @(1..7 | ForEach-Object {
            $idleHost = $global:shrRetirement.Host.PSObject.Copy()
            $idleHost.SessionHostName = "idle-$_"
            $idleHost.FQDN = "idle-$_.example.test"
            $idleHost.ResourceId = "/subscriptions/test/resourceGroups/hosts/providers/Microsoft.Compute/virtualMachines/idle-$_"
            $idleHost.Sessions = 0
            $idleHost.Tags = @{}
            $idleHost
        }) + @($global:shrRetirement.Host)
        $retirementParameters.SessionHostsPendingDelete = $hosts
        Mock Remove-VirtualMachine -ModuleName SessionHostReplacer.Lifecycle {
            param($VMName)
            @{ SessionHostName = $VMName }
        }
        $result = Remove-SessionHosts @retirementParameters
        $result.SuccessfulDeletions.Count | Should -Be 7
        $result.SuccessfulDeletions | Should -Not -Contain 'old-08'
        $global:shrRetirement.Host.Tags.ScalingPlanExclusion | Should -Be 'SessionHostReplacer'
        @($global:shrRetirement.Requests | Where-Object {
            $_.Uri -like '*/sessionHosts/old-08.example.test?*' -and
            $_.Body.properties.allowNewSession -eq $false
        }).Count | Should -Be 1
    }

    It 'preserves administrator exclusion "<Value>" when placing a host into shutdown retention' -TestCases @(
        @{ Value = 'Administrator' }
        @{ Value = '' }
    ) {
        param($Value)
        $global:shrRetirement.Host.Sessions = 0
        $global:shrRetirement.Host.PoweredOff = $true
        $global:shrRetirement.Host.Tags.ScalingPlanExclusion = $Value
        $retirementParameters.EnableShutdownRetention = $true
        $result = Remove-SessionHosts @retirementParameters
        $result.SuccessfulShutdowns.Count | Should -Be 1
        $global:shrRetirement.Host.Tags.ScalingPlanExclusion | Should -Be $Value
        $tagWrites = @($global:shrRetirement.Requests | Where-Object { $_.Method -eq 'PATCH' })
        $tagWrites.Count | Should -Be 1
        $tagWrites[0].Body.properties.tags.Retained | Should -Not -BeNullOrEmpty
        @($tagWrites[0].Body.properties.tags.PSObject.Properties.Name) | Should -Not -Contain 'ScalingPlanExclusion'
    }
}
