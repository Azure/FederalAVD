$repoRoot = Split-Path -Parent $PSScriptRoot
$formPath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\uiFormDefinition.json'

Describe 'Session Host Replacer App Service Plan resource-group selection' {
    BeforeAll {
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $infrastructure = $form.view.properties.steps | Where-Object { $_.name -eq 'infrastructure' }
        $resourceGroupsApi = $infrastructure.elements | Where-Object { $_.name -eq 'resourceGroupsApi' }
        $resourceGroup = $infrastructure.elements | Where-Object { $_.name -eq 'resourceGroup' }
        $serverFarmsApi = $infrastructure.elements | Where-Object { $_.name -eq 'serverFarmsApi' }
    }

    It 'uses the subscription selected in Basics without another subscription picker' {
        ($infrastructure.elements | Where-Object { $_.name -eq 'appServicePlanSubscription' }) | Should BeNullOrEmpty
        $resourceGroupsApi.condition | Should Be "[not(empty(steps('basics').subscription.id))]"
        $resourceGroupsApi.request.path | Should Be "[concat(steps('basics').subscription.id, '/resourcegroups?api-version=2021-04-01')]"
        $serverFarmsApi.request.path | Should Be "[concat(steps('basics').subscription.id, '/providers/Microsoft.Web/serverfarms?api-version=2024-11-01')]"
    }

    It 'lists only resource groups in the selected Function App region' {
        $resourceGroup.constraints.allowedValues | Should Match "filter\(steps\('infrastructure'\)\.resourceGroupsApi\.value"
        $resourceGroup.constraints.allowedValues | Should Match "equals\(toLower\(rg\.location\), toLower\(steps\('basics'\)\.location\.name\)\)"
    }

    It 'defaults to the first operations resource group in that region' {
        $resourceGroup.defaultValue | Should Match "contains\(toLower\(rg\.name\), 'operations'\)"
        $resourceGroup.defaultValue | Should Match "equals\(toLower\(rg\.location\), toLower\(steps\('basics'\)\.location\.name\)\)"
        $resourceGroup.defaultValue | Should Match "first\(map\(filter\("
        $resourceGroup.defaultValue | Should Match "\(rg\) => rg\.name"
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$formPath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\uiFormDefinition.json'

Describe 'Session Host Replacer shutdown retention form behavior' {
    BeforeAll {
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $configStep = $form.view.properties.steps | Where-Object { $_.name -eq 'replacerConfig' }
        $replacementMode = $configStep.elements | Where-Object { $_.name -eq 'replacementMode' }
        $shutdownRetentionHeader = $configStep.elements | Where-Object { $_.name -eq 'shutdownRetentionHeader' }
        $shutdownRetentionInfoBox = $configStep.elements | Where-Object { $_.name -eq 'shutdownRetentionInfoBox' }
        $enableShutdownRetention = $configStep.elements | Where-Object { $_.name -eq 'enableShutdownRetention' }
        $shutdownRetentionDays = $configStep.elements | Where-Object { $_.name -eq 'shutdownRetentionDays' }
        $tagShutdownTimestamp = $configStep.elements | Where-Object { $_.name -eq 'tagShutdownTimestamp' }
        $outputs = $form.view.outputs.parameters
    }

    It 'uses the Side-by-Side display label as the dropdown default' {
        $replacementMode.defaultValue | Should Be 'Side-by-Side (Add then Delete)'
        ($replacementMode.constraints.allowedValues | Where-Object { $_.label -eq $replacementMode.defaultValue }).value | Should Be 'SideBySide'
    }

    It 'shows shutdown retention controls only in Side-by-Side mode' {
        $sideBySideVisibility = "[equals(steps('replacerConfig').replacementMode, 'SideBySide')]"
        $shutdownRetentionHeader.visible | Should Be $sideBySideVisibility
        $shutdownRetentionInfoBox.visible | Should Be $sideBySideVisibility
        $enableShutdownRetention.visible | Should Be $sideBySideVisibility
        $shutdownRetentionDays.visible | Should Be "[and(equals(steps('replacerConfig').replacementMode, 'SideBySide'), steps('replacerConfig').enableShutdownRetention)]"
        $tagShutdownTimestamp.visible | Should Be "[and(equals(steps('replacerConfig').replacementMode, 'SideBySide'), steps('replacerConfig').enableShutdownRetention)]"
    }

    It 'disables shutdown retention in outputs for Delete-First mode' {
        $outputs.enableShutdownRetention | Should Be "[if(equals(steps('replacerConfig').replacementMode, 'SideBySide'), steps('replacerConfig').enableShutdownRetention, false)]"
        $outputs.shutdownRetentionDays | Should Be "[if(and(equals(steps('replacerConfig').replacementMode, 'SideBySide'), steps('replacerConfig').enableShutdownRetention), steps('replacerConfig').shutdownRetentionDays, 3)]"
        $outputs.tagShutdownTimestamp | Should Be "[if(and(equals(steps('replacerConfig').replacementMode, 'SideBySide'), steps('replacerConfig').enableShutdownRetention), steps('replacerConfig').tagShutdownTimestamp, 'AutoReplaceShutdownTimestamp')]"
    }
}

Describe 'Session Host Replacer shutdown retention scaling protection' {
    BeforeAll {
        $bicepPath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\main.bicep'
        $runPath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\functions\run.ps1'
        $lifecyclePath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\functions\Modules\SessionHostReplacer\SessionHostReplacer.Lifecycle.psm1'
        $bicep = Get-Content -LiteralPath $bicepPath -Raw
        $runScript = Get-Content -LiteralPath $runPath -Raw
        $lifecycleScript = Get-Content -LiteralPath $lifecyclePath -Raw
    }

    It 'enables shutdown retention only for Side-by-Side mode at deployment and runtime' {
        $bicep | Should Match "var effectiveEnableShutdownRetention = replacementMode == 'SideBySide' && enableShutdownRetention"
        $bicep | Should Match "name: 'EnableShutdownRetention'\s+value: string\(effectiveEnableShutdownRetention\)"
        $runScript | Should Match ([regex]::Escape('$enableShutdownRetention = $replacementMode -eq ''SideBySide'' -and (Read-FunctionAppSetting EnableShutdownRetention -AsBoolean)'))
        $lifecycleScript | Should Match ([regex]::Escape('$EnableShutdownRetention = $ReplacementMode -eq ''SideBySide'' -and $EnableShutdownRetention'))
    }

    It 'excludes only retention-tagged hosts confirmed stopped or deallocated' {
        $powerStatePosition = $runScript.IndexOf('$shutdownRetentionPowerStates = Get-VMPowerStates')
        $retentionFilterPosition = $runScript.IndexOf('$hostsInShutdownRetention += $sessionHost')

        $powerStatePosition | Should BeGreaterThan -1
        $retentionFilterPosition | Should BeGreaterThan $powerStatePosition
        $runScript | Should Match 'if \(-not \$shutdownRetentionPowerStates\[\$sessionHost\.ResourceId\]\)[\s\S]+Removed stale shutdown retention tag from active VM'
    }

    It 'deletes expired retained VMs only after confirming they are powered off' {
        $powerStatePosition = $lifecycleScript.IndexOf('$shutdownVMPowerStates = Get-VMPowerStates')
        $deletePosition = $lifecycleScript.IndexOf('has exceeded retention period - deleting')

        $powerStatePosition | Should BeGreaterThan -1
        $deletePosition | Should BeGreaterThan $powerStatePosition
        $lifecycleScript | Should Match 'if \(-not \$shutdownVMPowerStates\[\$vmId\]\)[\s\S]+skipping retention cleanup'
    }

    It 'restores the scaling exclusion tag before retained hosts are filtered out' {
        $retentionFilterPosition = $runScript.IndexOf('$sessionHostsFiltered = $sessionHostsFiltered | Where-Object')
        $restorePosition = $runScript.IndexOf('Restoring scaling plan exclusion tag on shutdown retention VM')

        $restorePosition | Should BeGreaterThan -1
        $retentionFilterPosition | Should BeGreaterThan $restorePosition
        $runScript | Should Match "scalingPlanExclusionValue -ne 'SessionHostReplacer'[\s\S]+operation\s+= 'Merge'"
    }

    It 'protects hosts newly placed into retention from same-run tag cleanup' {
        $runScript | Should Match '\$retainedSessionHostNames = @\(@\(\$hostsInShutdownRetention\.SessionHostName\) \+ @\(\$deletionResults\.SuccessfulShutdowns\) \| Select-Object -Unique\)'
        $runScript | Should Match '\$shutdownRetentionVMs = @\(\$shutdownRetentionVMs \+ @\(\$deletionResults\.SuccessfulShutdowns\) \| Select-Object -Unique\)'
    }
}

Describe 'Session Host Replacer scaling-aware readiness' {
    BeforeAll {
        $modulePath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\functions\Modules\SessionHostReplacer\SessionHostReplacer.psd1'
        Import-Module $modulePath -Force

        $latestImage = [PSCustomObject]@{
            Definition = '/subscriptions/test/resourceGroups/images/providers/Microsoft.Compute/galleries/gallery/images/avd'
            Version = '1.2.3'
        }
        $imageIdentity = "$($latestImage.Definition)|$($latestImage.Version)".ToLowerInvariant()
        $hashAlgorithm = [System.Security.Cryptography.SHA256]::Create()
        try {
            $validatedImageToken = [System.BitConverter]::ToString(
                $hashAlgorithm.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($imageIdentity))
            ).Replace('-', '').ToLowerInvariant()
        }
        finally {
            $hashAlgorithm.Dispose()
        }

        function New-ReadinessHost {
            param (
                [int] $Index,
                [string] $Status = 'Available',
                [bool] $AllowNewSession = $true,
                [hashtable] $Tags = @{},
                [string] $HealthCheckResult = 'HealthCheckSucceeded'
            )

            [PSCustomObject]@{
                SessionHostName = "avd-$Index"
                ResourceId = "/subscriptions/test/resourceGroups/hosts/providers/Microsoft.Compute/virtualMachines/avd-$Index"
                ImageDefinition = $latestImage.Definition
                ImageVersion = $latestImage.Version
                Status = $Status
                AllowNewSession = $AllowNewSession
                Tags = $Tags
                SessionHostHealthCheckResults = @(
                    [PSCustomObject]@{ healthCheckResult = $HealthCheckResult }
                )
            }
        }

        function Invoke-ReadinessCheck {
            param (
                [array] $SessionHosts,
                $ScalingPlanTarget
            )

            Test-NewSessionHostsAvailable `
                -ARMToken 'test-token' `
                -SessionHosts $SessionHosts `
                -LatestImageVersion $latestImage `
                -ScalingPlanTarget $ScalingPlanTarget `
                -TagScalingPlanExclusionTag 'ScalingPlanExclusion' `
                -TagValidatedImage 'AutoReplaceValidatedImage' `
                -ResourceManagerUri 'https://management.azure.com'
        }
    }

    BeforeEach {
        $global:sessionHostReplacerTestPowerStates = @{}
        Mock Write-LogEntry -ModuleName SessionHostReplacer.Lifecycle {}
        Mock Get-VMPowerStates -ModuleName SessionHostReplacer.Lifecycle { $global:sessionHostReplacerTestPowerStates }
        Mock Invoke-AzureRestMethod -ModuleName SessionHostReplacer.Lifecycle {}
    }

    AfterAll {
        Remove-Variable sessionHostReplacerTestPowerStates -Scope Global -ErrorAction SilentlyContinue
        Remove-Module SessionHostReplacer -Force
    }

    It 'counts validated stopped hosts as scalable standby for the shared mode-independent check' {
        $hosts = @(
            1..4 | ForEach-Object { New-ReadinessHost -Index $_ }
            5..10 | ForEach-Object {
                $sessionHost = New-ReadinessHost -Index $_ -Status 'Shutdown' -AllowNewSession $false -Tags @{
                    AutoReplaceValidatedImage = $validatedImageToken
                }
                $global:sessionHostReplacerTestPowerStates[$sessionHost.ResourceId] = $true
                $sessionHost
            }
        )

        $result = Invoke-ReadinessCheck -SessionHosts $hosts -ScalingPlanTarget ([PSCustomObject]@{
            Source = 'ScalingPlan'
            CapacityPercentage = 40
        })

        $result.SafeToProceed | Should Be $true
        $result.AvailableCount | Should Be 4
        $result.ScalableStandbyCount | Should Be 6
        $result.ReadyCount | Should Be 10
    }

    It 'keeps the original all-online requirement when no scaling plan is evaluable' {
        $hosts = @(
            1..4 | ForEach-Object { New-ReadinessHost -Index $_ }
            5..10 | ForEach-Object { New-ReadinessHost -Index $_ -Status 'Shutdown' -AllowNewSession $false }
        )

        $result = Invoke-ReadinessCheck -SessionHosts $hosts -ScalingPlanTarget $null

        $result.SafeToProceed | Should Be $false
        $result.AvailableCount | Should Be 4
        $result.AvailablePercentage | Should Be 40
    }

    It 'records validation evidence when no scaling plan is evaluable' {
        $sessionHost = New-ReadinessHost -Index 1

        $result = Invoke-ReadinessCheck -SessionHosts @($sessionHost) -ScalingPlanTarget $null

        $result.SafeToProceed | Should Be $true
        $sessionHost.Tags.AutoReplaceValidatedImage | Should Be $validatedImageToken
        Assert-MockCalled Invoke-AzureRestMethod -ModuleName SessionHostReplacer.Lifecycle -Times 1 -ParameterFilter {
            $Method -eq 'PATCH' -and $Body -match '"operation":\s*"Merge"'
        }
    }

    It 'does not count stopped hosts without exact-image validation evidence' {
        $onlineHost = New-ReadinessHost -Index 1
        $standbyHost = New-ReadinessHost -Index 2 -Status 'Shutdown' -AllowNewSession $false
        $global:sessionHostReplacerTestPowerStates[$standbyHost.ResourceId] = $true

        $result = Invoke-ReadinessCheck -SessionHosts @($onlineHost, $standbyHost) -ScalingPlanTarget ([PSCustomObject]@{
            Source = 'ScalingPlan'
            CapacityPercentage = 50
        })

        $result.SafeToProceed | Should Be $false
        $result.ScalableStandbyCount | Should Be 0
        $result.UnavailableHosts[0].ValidatedForImage | Should Be $false
    }

    It 'records evidence for an Available drained host without counting it as online ready' {
        $onlineHost = New-ReadinessHost -Index 1
        $drainedHost = New-ReadinessHost -Index 2 -AllowNewSession $false

        $result = Invoke-ReadinessCheck -SessionHosts @($onlineHost, $drainedHost) -ScalingPlanTarget ([PSCustomObject]@{
            Source = 'ScalingPlan'
            CapacityPercentage = 50
        })

        $drainedHost.Tags.AutoReplaceValidatedImage | Should Be $validatedImageToken
        $result.SafeToProceed | Should Be $false
        $result.AvailableCount | Should Be 1
        $result.UnavailableHosts[0].AllowNewSession | Should Be $false
        Assert-MockCalled Invoke-AzureRestMethod -ModuleName SessionHostReplacer.Lifecycle -Times 2 -ParameterFilter {
            $Method -eq 'PATCH' -and $Body -match '"operation":\s*"Merge"'
        }
    }

    It 'preserves administrator scaling exclusions and does not count the host as standby' {
        $onlineHost = New-ReadinessHost -Index 1
        $standbyHost = New-ReadinessHost -Index 2 -Status 'Shutdown' -AllowNewSession $false -Tags @{
            AutoReplaceValidatedImage = $validatedImageToken
            ScalingPlanExclusion = 'Administrator'
        }
        $global:sessionHostReplacerTestPowerStates[$standbyHost.ResourceId] = $true

        $result = Invoke-ReadinessCheck -SessionHosts @($onlineHost, $standbyHost) -ScalingPlanTarget ([PSCustomObject]@{
            Source = 'ScalingPlan'
            CapacityPercentage = 50
        })

        $result.SafeToProceed | Should Be $false
        $standbyHost.Tags.ScalingPlanExclusion | Should Be 'Administrator'
    }

    It 'rejects failed health checks and non-Available online states: <Status>/<Health>' -TestCases @(
        @{ Status = 'Available'; Health = 'HealthCheckFailed' }
        @{ Status = 'NeedsAssistance'; Health = 'HealthCheckSucceeded' }
        @{ Status = 'Upgrading'; Health = 'HealthCheckSucceeded' }
        @{ Status = 'UpgradeFailed'; Health = 'HealthCheckSucceeded' }
    ) {
        param ($Status, $Health)

        $goodHost = New-ReadinessHost -Index 1
        $unhealthyHost = New-ReadinessHost -Index 2 -Status $Status -HealthCheckResult $Health

        $result = Invoke-ReadinessCheck -SessionHosts @($goodHost, $unhealthyHost) -ScalingPlanTarget ([PSCustomObject]@{
            Source = 'ScalingPlan'
            CapacityPercentage = 100
        })

        $result.SafeToProceed | Should Be $false
        $result.AvailableCount | Should Be 1
    }

    It 'allows zero online hosts when the active scaling plan target is zero percent' {
        $hosts = 1..3 | ForEach-Object {
            $sessionHost = New-ReadinessHost -Index $_ -Status 'Shutdown' -AllowNewSession $false -Tags @{
                AutoReplaceValidatedImage = $validatedImageToken
            }
            $global:sessionHostReplacerTestPowerStates[$sessionHost.ResourceId] = $true
            $sessionHost
        }

        $result = Invoke-ReadinessCheck -SessionHosts $hosts -ScalingPlanTarget ([PSCustomObject]@{
            Source = 'ScalingPlan'
            CapacityPercentage = 0
        })

        $result.SafeToProceed | Should Be $true
        $result.ScalableStandbyCount | Should Be 3
        $result.RequiredOnlineCount | Should Be 0
    }

    It 'fails closed when validation evidence cannot be persisted' {
        $sessionHost = New-ReadinessHost -Index 1 -Tags @{ ScalingPlanExclusion = 'SessionHostReplacer' }
        Mock Invoke-AzureRestMethod -ModuleName SessionHostReplacer.Lifecycle { throw 'tag update failed' }

        $result = Invoke-ReadinessCheck -SessionHosts @($sessionHost) -ScalingPlanTarget ([PSCustomObject]@{
            Source = 'ScalingPlan'
            CapacityPercentage = 100
        })

        $result.SafeToProceed | Should Be $false
        $sessionHost.Tags.ContainsKey('AutoReplaceValidatedImage') | Should Be $false
        $sessionHost.Tags.ScalingPlanExclusion | Should Be 'SessionHostReplacer'
    }

    It 'removes only a replacer-owned exclusion after exact-image validation' {
        $sessionHost = New-ReadinessHost -Index 1 -Tags @{
            AutoReplaceValidatedImage = $validatedImageToken
            ScalingPlanExclusion = 'SessionHostReplacer'
        }

        $result = Invoke-ReadinessCheck -SessionHosts @($sessionHost) -ScalingPlanTarget ([PSCustomObject]@{
            Source = 'ScalingPlan'
            CapacityPercentage = 100
        })

        $result.SafeToProceed | Should Be $true
        $sessionHost.Tags.ContainsKey('ScalingPlanExclusion') | Should Be $false
        Assert-MockCalled Invoke-AzureRestMethod -ModuleName SessionHostReplacer.Lifecycle -Times 1 -ParameterFilter {
            $Method -eq 'PATCH' -and $Body -match '"operation":\s*"Delete"'
        }
    }
}

Describe 'Session Host Replacer scaling-aware readiness contracts' {
    BeforeAll {
        $bicepPath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\main.bicep'
        $runPath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\functions\run.ps1'
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $bicep = Get-Content -LiteralPath $bicepPath -Raw
        $runScript = Get-Content -LiteralPath $runPath -Raw
        $configStep = $form.view.properties.steps | Where-Object { $_.name -eq 'replacerConfig' }
        $validatedImageControl = $configStep.elements | Where-Object { $_.name -eq 'tagValidatedImage' }
    }

    It 'queries a scaling plan and applies readiness in both replacement modes' {
        $runScript | Should Match ([regex]::Escape('$replacementMode -in @(''DeleteFirst'', ''SideBySide'')'))
        $runScript | Should Match 'Test-NewSessionHostsAvailable[\s\S]+-ScalingPlanTarget \$scalingPlanTarget'
    }

    It 'validates healthy latest-image hosts before the up-to-date early return' {
        $upToDatePlanPosition = $runScript.IndexOf('if ($isUpToDate)')
        $scalingPlanQueryPosition = $runScript.IndexOf('$scalingPlanTarget = Get-ScalingPlanCurrentTarget')
        $earlyExitPosition = $runScript.IndexOf('# EARLY EXIT: Check if host pool is up to date')
        $upToDateValidationPosition = $runScript.IndexOf('$upToDateHostReadiness = Test-NewSessionHostsAvailable')

        $scalingPlanQueryPosition | Should BeLessThan $upToDatePlanPosition
        $upToDateValidationPosition | Should BeGreaterThan $earlyExitPosition
        $runScript | Should Match '\$upToDateHostReadiness = Test-NewSessionHostsAvailable[\s\S]+-ScalingPlanTarget \$scalingPlanTarget'
    }

    It 'wires the exact-image validation tag through Bicep and Form View' {
        $bicep | Should Match "param tagValidatedImage string = 'AutoReplaceValidatedImage'"
        $bicep | Should Match "name: 'Tag_ValidatedImage'\s+value: tagValidatedImage"
        $validatedImageControl.defaultValue | Should Be 'AutoReplaceValidatedImage'
        $form.view.outputs.parameters.tagValidatedImage | Should Be "[steps('replacerConfig').tagValidatedImage]"
    }
}

Describe 'Session Host Replacer ten-host replacement scenarios' {
    BeforeAll {
        $modulePath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\functions\Modules\SessionHostReplacer\SessionHostReplacer.psd1'
        Import-Module $modulePath -Force

        $latestImage = [PSCustomObject]@{
            Definition = '/subscriptions/test/resourceGroups/images/providers/Microsoft.Compute/galleries/gallery/images/avd'
            Version = '2.0.0'
            Date = (Get-Date).AddDays(-1)
        }
        $oldHosts = 1..10 | ForEach-Object {
            [PSCustomObject]@{
                SessionHostName = "avd-$($_.ToString('00'))"
                VMName = "avd-$($_.ToString('00'))"
                ResourceId = "/subscriptions/test/resourceGroups/hosts/providers/Microsoft.Compute/virtualMachines/avd-$($_.ToString('00'))"
                ImageDefinition = $latestImage.Definition
                ImageVersion = '1.0.0'
                Status = 'Available'
                AllowNewSession = $true
                Sessions = 0
                ShutdownTimestamp = $null
                PendingDrainTimeStamp = $null
                IsUnavailable = $false
            }
        }

        function Invoke-TenHostReplacementPlan {
            param (
                [string] $ReplacementMode,
                $ScalingPlanTarget
            )

            Get-SessionHostReplacementPlan `
                -ARMToken 'test-token' `
                -SessionHosts $oldHosts `
                -RunningDeployments @() `
                -HostPoolName 'hp-test' `
                -TargetSessionHostCount 10 `
                -LatestImageVersion $latestImage `
                -ReplaceSessionHostOnNewImageVersionDelayDays 0 `
                -ReplacementMode $ReplacementMode `
                -DrainGracePeriodHours 24 `
                -MinimumCapacityPercentage 80 `
                -MaxDeletionsPerCycle 50 `
                -EnableProgressiveScaleUp $false `
                -ScalingPlanTarget $ScalingPlanTarget `
                -RemoveEntraDevice $false `
                -RemoveIntuneDevice $false `
                -HostPoolSubscriptionId 'test' `
                -HostPoolResourceGroupName 'hosts' `
                -ResourceManagerUri 'https://management.azure.com'
        }
    }

    BeforeEach {
        Mock Write-LogEntry -ModuleName SessionHostReplacer.Planning {}
        Mock Read-FunctionAppSetting -ModuleName SessionHostReplacer.Planning { 10 }
        Mock Get-VMPowerStates -ModuleName SessionHostReplacer.Planning {
            $states = @{}
            foreach ($resourceId in $VMResourceIds) {
                $states[$resourceId] = $false
            }
            $states
        }
    }

    AfterAll {
        Remove-Module SessionHostReplacer -Force
    }

    It 'SideBySide plans ten deployments and no deletion with a scaling plan' {
        $plan = Invoke-TenHostReplacementPlan -ReplacementMode SideBySide -ScalingPlanTarget ([PSCustomObject]@{
            Source = 'ScalingPlan'
            CapacityPercentage = 20
            Phase = 'RampUp'
            ScalingPlanName = 'weekday'
            ScheduleName = 'weekday'
        })

        $plan.PossibleDeploymentsCount | Should Be 10
        $plan.PossibleSessionHostDeleteCount | Should Be 0
        $plan.TotalSessionHostsToReplace | Should Be 10
    }

    It 'SideBySide plans ten deployments and no deletion without a scaling plan' {
        $plan = Invoke-TenHostReplacementPlan -ReplacementMode SideBySide -ScalingPlanTarget $null

        $plan.PossibleDeploymentsCount | Should Be 10
        $plan.PossibleSessionHostDeleteCount | Should Be 0
        $plan.TotalSessionHostsToReplace | Should Be 10
    }

    It 'SideBySide retires stale hosts when validated replacements are scaled to zero' {
        $newHosts = 11..20 | ForEach-Object {
            [PSCustomObject]@{
                SessionHostName = "avd-$($_.ToString('00'))"
                VMName = "avd-$($_.ToString('00'))"
                ResourceId = "/subscriptions/test/resourceGroups/hosts/providers/Microsoft.Compute/virtualMachines/avd-$($_.ToString('00'))"
                ImageDefinition = $latestImage.Definition
                ImageVersion = $latestImage.Version
                Status = 'Shutdown'
                AllowNewSession = $false
                Sessions = 0
                ShutdownTimestamp = $null
                PendingDrainTimeStamp = $null
                IsUnavailable = $false
            }
        }

        $plan = Get-SessionHostReplacementPlan `
            -ARMToken 'test-token' `
            -SessionHosts @($oldHosts + $newHosts) `
            -RunningDeployments @() `
            -HostPoolName 'hp-test' `
            -TargetSessionHostCount 10 `
            -LatestImageVersion $latestImage `
            -ReplaceSessionHostOnNewImageVersionDelayDays 0 `
            -ReplacementMode SideBySide `
            -DrainGracePeriodHours 24 `
            -MinimumCapacityPercentage 80 `
            -MaxDeletionsPerCycle 50 `
            -EnableProgressiveScaleUp $false `
            -ScalingPlanTarget ([PSCustomObject]@{
                Source = 'ScalingPlan'
                CapacityPercentage = 0
                Phase = 'OffPeak'
                ScalingPlanName = 'weekend'
                ScheduleName = 'weekend'
            }) `
            -RemoveEntraDevice $false `
            -RemoveIntuneDevice $false `
            -HostPoolSubscriptionId 'test' `
            -HostPoolResourceGroupName 'hosts' `
            -ResourceManagerUri 'https://management.azure.com'

        $plan.PossibleDeploymentsCount | Should Be 0
        $plan.PossibleSessionHostDeleteCount | Should Be 10
        $plan.SessionHostsPendingDelete.Count | Should Be 10
        @($plan.SessionHostsPendingDelete | Where-Object { $_.ImageVersion -eq $latestImage.Version }).Count | Should Be 0
    }

    It 'DeleteFirst keeps the configured 80 percent floor during RampUp and Peak' -TestCases @(
        @{ Phase = 'RampUp' }
        @{ Phase = 'Peak' }
    ) {
        param ($Phase)

        $plan = Invoke-TenHostReplacementPlan -ReplacementMode DeleteFirst -ScalingPlanTarget ([PSCustomObject]@{
            Source = 'ScalingPlan'
            CapacityPercentage = 20
            Phase = $Phase
            ScalingPlanName = 'weekday'
            ScheduleName = 'weekday'
        })

        $plan.PossibleDeploymentsCount | Should Be 10
        $plan.PossibleSessionHostDeleteCount | Should Be 2
        $plan.SessionHostsPendingDelete.Count | Should Be 2
    }

    It 'DeleteFirst uses the 10 percent scaling floor during OffPeak' {
        $plan = Invoke-TenHostReplacementPlan -ReplacementMode DeleteFirst -ScalingPlanTarget ([PSCustomObject]@{
            Source = 'ScalingPlan'
            CapacityPercentage = 10
            Phase = 'OffPeak'
            ScalingPlanName = 'weekday'
            ScheduleName = 'weekday'
        })

        $plan.PossibleDeploymentsCount | Should Be 10
        $plan.PossibleSessionHostDeleteCount | Should Be 9
        $plan.SessionHostsPendingDelete.Count | Should Be 9
    }

    It 'DeleteFirst accepts a zero percent scaling floor during OffPeak' {
        $plan = Invoke-TenHostReplacementPlan -ReplacementMode DeleteFirst -ScalingPlanTarget ([PSCustomObject]@{
            Source = 'ScalingPlan'
            CapacityPercentage = 0
            Phase = 'OffPeak'
            ScalingPlanName = 'weekend'
            ScheduleName = 'weekend'
        })

        $plan.PossibleDeploymentsCount | Should Be 10
        $plan.PossibleSessionHostDeleteCount | Should Be 10
        $plan.SessionHostsPendingDelete.Count | Should Be 10
    }

    It 'DeleteFirst uses the configured 80 percent floor without a scaling plan' {
        $plan = Invoke-TenHostReplacementPlan -ReplacementMode DeleteFirst -ScalingPlanTarget $null

        $plan.PossibleDeploymentsCount | Should Be 10
        $plan.PossibleSessionHostDeleteCount | Should Be 2
        $plan.SessionHostsPendingDelete.Count | Should Be 2
    }
}

Describe 'Session Host Replacer zero-percent scaling schedule discovery' {
    BeforeAll {
        $modulePath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\functions\Modules\SessionHostReplacer\SessionHostReplacer.psd1'
        Import-Module $modulePath -Force
    }

    BeforeEach {
        Mock Write-LogEntry -ModuleName SessionHostReplacer.Planning {}
        Mock Invoke-AzureRestMethod -ModuleName SessionHostReplacer.Planning {
            @(
                [PSCustomObject]@{
                    name = 'weekend-plan'
                    properties = [PSCustomObject]@{
                        timeZone = 'UTC'
                        hostPoolReferences = @(
                            [PSCustomObject]@{
                                hostPoolArmPath = '/subscriptions/test/resourceGroups/hosts/providers/Microsoft.DesktopVirtualization/hostPools/hp-test'
                                scalingPlanEnabled = $true
                            }
                        )
                        schedules = @(
                            [PSCustomObject]@{
                                name = 'weekend'
                                daysOfWeek = @('Saturday', 'Sunday')
                                rampUpStartTime = [PSCustomObject]@{ hour = 6; minute = 0 }
                                peakStartTime = [PSCustomObject]@{ hour = 8; minute = 0 }
                                rampDownStartTime = [PSCustomObject]@{ hour = 18; minute = 0 }
                                offPeakStartTime = [PSCustomObject]@{ hour = 20; minute = 0 }
                                rampUpMinimumHostsPct = 20
                                rampDownMinimumHostsPct = 0
                            },
                            [PSCustomObject]@{
                                name = 'weekday'
                                daysOfWeek = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday')
                                rampUpStartTime = [PSCustomObject]@{ hour = 6; minute = 0 }
                                peakStartTime = [PSCustomObject]@{ hour = 8; minute = 0 }
                                rampDownStartTime = [PSCustomObject]@{ hour = 18; minute = 0 }
                                offPeakStartTime = [PSCustomObject]@{ hour = 20; minute = 0 }
                                rampUpMinimumHostsPct = 50
                                rampDownMinimumHostsPct = 25
                            }
                        )
                    }
                }
            )
        }
    }

    AfterAll {
        Remove-Module SessionHostReplacer -Force
    }

    It 'returns an active zero-percent OffPeak target as a usable scaling plan' {
        $currentDateTime = [datetime]::SpecifyKind([datetime]'2026-09-19T23:00:00', [System.DateTimeKind]::Utc)

        $target = Get-ScalingPlanCurrentTarget `
            -ARMToken 'test-token' `
            -HostPoolResourceId '/subscriptions/test/resourceGroups/hosts/providers/Microsoft.DesktopVirtualization/hostPools/hp-test' `
            -CurrentDateTime $currentDateTime `
            -ResourceManagerUri 'https://management.azure.com'

        $target.Source | Should Be 'ScalingPlan'
        $target.Phase | Should Be 'OffPeak'
        $target.CapacityPercentage | Should Be 0
    }

    It 'carries the previous zero-percent OffPeak target across midnight until the next RampUp' {
        $currentDateTime = [datetime]::SpecifyKind([datetime]'2026-09-21T01:00:00', [System.DateTimeKind]::Utc)

        $target = Get-ScalingPlanCurrentTarget `
            -ARMToken 'test-token' `
            -HostPoolResourceId '/subscriptions/test/resourceGroups/hosts/providers/Microsoft.DesktopVirtualization/hostPools/hp-test' `
            -CurrentDateTime $currentDateTime `
            -ResourceManagerUri 'https://management.azure.com'

        $target.Source | Should Be 'ScalingPlan'
        $target.ScheduleName | Should Be 'weekend (fallback)'
        $target.Phase | Should Be 'OffPeak (no schedule)'
        $target.CapacityPercentage | Should Be 0
    }

    It 'raises the carried zero-percent target within 30 minutes of the next RampUp' {
        $currentDateTime = [datetime]::SpecifyKind([datetime]'2026-09-21T05:45:00', [System.DateTimeKind]::Utc)

        $target = Get-ScalingPlanCurrentTarget `
            -ARMToken 'test-token' `
            -HostPoolResourceId '/subscriptions/test/resourceGroups/hosts/providers/Microsoft.DesktopVirtualization/hostPools/hp-test' `
            -CurrentDateTime $currentDateTime `
            -ResourceManagerUri 'https://management.azure.com'

        $target.Source | Should Be 'ScalingPlan'
        $target.Phase | Should Be 'OffPeak->RampUp (look-ahead)'
        $target.CapacityPercentage | Should Be 50
    }
}

Describe 'Session Host Replacer currently deploying metric' {
    BeforeAll {
        $runPath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\functions\run.ps1'
        $workbookPath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\modules\workBook\workbookTemplate.json'
        $runScript = Get-Content -LiteralPath $runPath -Raw
        $workbook = Get-Content -LiteralPath $workbookPath -Raw | ConvertFrom-Json
        $currentStatusQuery = ($workbook.items | Where-Object { $_.name -eq 'kpi-tiles' }).content.query
    }

    It 'counts session hosts in running ARM deployments instead of deployment records' {
        $runScript | Should Match '\$currentlyDeploying = \[int\]\(\(\$runningDeployments \| ForEach-Object \{ @\(\$_.SessionHostNames\)\.Count \} \| Measure-Object -Sum\)\.Sum\)'
    }

    It 'uses RunningDeployments from the latest metrics event' {
        $currentStatusQuery | Should Match 'extend RunningDeployments = toint'
        $currentStatusQuery | Should Match 'RunningDeployments:'
        $currentStatusQuery | Should Match 'Deploying = coalesce\(RunningDeployments, 0\)'
        $currentStatusQuery | Should Not Match 'deployingFromSubmitted|Deployment submitted:'
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$bicepPath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\main.bicep'
$templatePath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\main.json'
$formPath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\uiFormDefinition.json'
$namingPath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\modules\naming.bicep'
$workbookModulePath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\modules\workBook\workbook.bicep'
$functionAppModulePath = Join-Path $repoRoot 'deployments\shared\modules\resourceModules\functionApp\functionApp.bicep'

Describe 'Session Host Replacer storage CMK propagation sequencing' {
    It 'starts CMK provisioning at the entry point before Function App deployment' {
        $bicep = Get-Content -LiteralPath $bicepPath -Raw
        $cmkPosition = $bicep.IndexOf("module storageCmk '../../shared/modules/orchestration/customerManagedKeys/customerManagedKeys.bicep'")
        $functionAppPosition = $bicep.IndexOf("module functionApp '../../shared/modules/resourceModules/functionApp/functionApp.bicep'")

        $cmkPosition | Should BeGreaterThan -1
        $functionAppPosition | Should BeGreaterThan $cmkPosition
        $bicep | Should Match 'module functionApp[\s\S]+dependsOn:\s*\[storageCmk\]'
    }

    It 'keeps CMK resource ownership out of the Function App module' {
        Get-Content -LiteralPath $functionAppModulePath -Raw |
            Should Not Match "module cmk '../../orchestration/customerManagedKeys/customerManagedKeys.bicep'"
    }

    It 'keeps the generated Function App deployment behind the top-level CMK deployment' {
        $template = Get-Content -LiteralPath $templatePath -Raw | ConvertFrom-Json

        $template.resources.storageCmk.type | Should Be 'Microsoft.Resources/deployments'
        ($template.resources.functionApp.dependsOn -contains 'storageCmk') | Should Be $true
        ($template.resources.functionApp.properties.template.resources.PSObject.Properties.Name -contains 'cmk') |
            Should Be $false
    }
}

Describe 'Session Host Replacer centralized workbook placement' {
    It 'derives workbook scope from the selected Log Analytics workspace' {
        Get-Content -LiteralPath $bicepPath -Raw |
            Should Match "var workbookSubscriptionId = !empty\(logAnalyticsWorkspaceResourceId\)"
        Get-Content -LiteralPath $bicepPath -Raw |
            Should Match "split\(logAnalyticsWorkspaceResourceId, '/'\)\[2\]"
        Get-Content -LiteralPath $bicepPath -Raw |
            Should Match "var workbookResourceGroupName = !empty\(logAnalyticsWorkspaceResourceId\)"
        Get-Content -LiteralPath $bicepPath -Raw |
            Should Match "split\(logAnalyticsWorkspaceResourceId, '/'\)\[4\]"
        Get-Content -LiteralPath $bicepPath -Raw |
            Should Match 'scope: resourceGroup\(workbookSubscriptionId, workbookResourceGroupName\)'
    }

    It 'uses one deterministic workbook name per Log Analytics workspace' {
        Get-Content -LiteralPath $bicepPath -Raw |
            Should Match "guid\(toLower\(logAnalyticsWorkspaceResourceId\), 'session-host-replacer-workbook'\)"
    }

    It 'keeps the generated ARM workbook deployment in the monitoring scope' {
        $template = Get-Content -LiteralPath $templatePath -Raw | ConvertFrom-Json
        $template.resources.workbook.subscriptionId | Should Be "[variables('workbookSubscriptionId')]"
        $template.resources.workbook.resourceGroup | Should Be "[variables('workbookResourceGroupName')]"
        $template.variables.workbookName |
            Should Be "[guid(toLower(parameters('logAnalyticsWorkspaceResourceId')), 'session-host-replacer-workbook')]"
    }

    It 'associates the workbook with the shared monitoring resource' {
        Get-Content -LiteralPath $bicepPath -Raw |
            Should Match "'cm-resource-parent': logAnalyticsWorkspaceResourceId"
        Get-Content -LiteralPath $bicepPath -Raw |
            Should Not Match "'cm-resource-parent': hostPoolResourceId"
        Get-Content -LiteralPath $workbookModulePath -Raw |
            Should Match 'sourceId: logAnalyticsWorkspaceResourceId'
        Get-Content -LiteralPath $workbookModulePath -Raw |
            Should Match 'fallbackResourceIds:\s*\[\s*applicationInsightsResourceId'
    }

    It 'explains shared workspace placement in the portal form' {
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $monitoringStep = $form.view.properties.steps | Where-Object { $_.name -eq 'monitoring' }
        $functionMonitoring = $monitoringStep.elements |
            Where-Object { $_.name -eq 'functionAppMonitoringSection' }
        ($functionMonitoring.elements | Where-Object { $_.name -eq 'workbookInfoBox' }).options.text |
            Should Match 'selected Log Analytics workspace subscription and resource group'
        ($functionMonitoring.elements | Where-Object { $_.name -eq 'workbookInfoBox' }).options.text |
            Should Match 'same workspace reuse and update the same workbook'
    }
}

Describe 'Session Host Replacer Application Insights isolation' {
    It 'uses naming-convention parity for standard deployments and follows a custom Function App name' {
        Get-Content -LiteralPath $namingPath -Raw |
            Should Match 'cnv_rtCodes.applicationInsights,\s*hpPurpose'
        Get-Content -LiteralPath $bicepPath -Raw |
            Should Match "var appInsightsName\s*= !empty\(functionAppNameOverride\)\s*\? '\$\{functionAppName\}-insights'\s*: shrNaming.outputs.appInsightsName"
    }

    It 'deploys Application Insights through the Function App resource-group-scoped module' {
        Get-Content -LiteralPath $bicepPath -Raw |
            Should Match "module functionApp '../../shared/modules/resourceModules/functionApp/functionApp.bicep' = \{\s*scope: resourceGroup\(functionAppResourceGroupName\)"
    }

    It 'does not expose an Application Insights name override' {
        Get-Content -LiteralPath $bicepPath -Raw |
            Should Not Match 'applicationInsightsNameOverride'

        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        ($form.view.outputs.parameters.PSObject.Properties.Name -notcontains 'applicationInsightsNameOverride') |
            Should Be $true
        Get-Content -LiteralPath $formPath -Raw |
            Should Not Match 'applicationInsightsNameOverride'
    }
}
