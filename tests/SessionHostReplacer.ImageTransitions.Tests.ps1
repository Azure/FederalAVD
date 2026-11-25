BeforeAll {
    $modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'deployments\add-ons\sessionHostReplacer\functions\Modules\SessionHostReplacer\SessionHostReplacer.psd1'
    Import-Module $modulePath -Force
}

Describe 'SHR per-image retirement readiness' {
    BeforeEach {
        $global:shrImages = @{
            State = @{
                Image = @{ Definition = '/gallery/desktop'; Version = '2.0.0' }
                RetirementImages = @(@{ Definition = '/gallery/desktop'; Version = '1.0.0' })
                BatchHostNames = @('original-host', 'retiring-replacement')
            }
            Calls = @()
            UnhealthyVersion = ''
        }
        Mock Test-NewSessionHostsAvailable -ModuleName SessionHostReplacer.Lifecycle {
            param($SessionHosts, $LatestImageVersion)
            $global:shrImages.Calls += @{
                Version = $LatestImageVersion.Version
                Names = @($SessionHosts.SessionHostName)
            }
            [PSCustomObject]@{
                TotalNewHosts = $SessionHosts.Count
                AvailableCount = $SessionHosts.Count
                SafeToProceed = $LatestImageVersion.Version -ne $global:shrImages.UnhealthyVersion
            }
        }
        $hosts = @(
            [PSCustomObject]@{ SessionHostName = 'old-replacement'; ImageDefinition = '/gallery/desktop'; ImageVersion = '1.0.0' }
            [PSCustomObject]@{ SessionHostName = 'new-replacement'; ImageDefinition = '/gallery/desktop'; ImageVersion = '2.0.0' }
            [PSCustomObject]@{ SessionHostName = 'retiring-replacement'; ImageDefinition = '/gallery/desktop'; ImageVersion = '1.0.0' }
            [PSCustomObject]@{ SessionHostName = 'unrelated'; ImageDefinition = '/gallery/other'; ImageVersion = '2.0.0' }
        )
    }

    It 'validates replacement hosts against their own saved image rather than the newest target' {
        $result = Test-ShrRetirementImagesAvailable -ARMToken token -SessionHosts $hosts -State $global:shrImages.State
        $result.SafeToProceed | Should -BeTrue
        $result.TotalNewHosts | Should -Be 2
        $global:shrImages.Calls.Count | Should -Be 2
        $global:shrImages.Calls[0].Names | Should -Not -Contain 'retiring-replacement'
        @($global:shrImages.Calls.Names) | Should -Not -Contain 'unrelated'
    }

    It 'does not require new-target hosts before continuing retirement backed by healthy prior-image hosts' {
        $oldHosts = @($hosts | Where-Object { $_.ImageVersion -eq '1.0.0' })
        $result = Test-ShrRetirementImagesAvailable -ARMToken token -SessionHosts $oldHosts -State $global:shrImages.State
        $result.SafeToProceed | Should -BeTrue
        $result.TotalNewHosts | Should -Be 1
    }

    It 'blocks retirement if a remaining replacement-image group is unhealthy' {
        $global:shrImages.UnhealthyVersion = '1.0.0'
        $result = Test-ShrRetirementImagesAvailable -ARMToken token -SessionHosts $hosts -State $global:shrImages.State
        $result.SafeToProceed | Should -BeFalse
    }

    It 'never treats missing replacement capacity as readiness' {
        $result = Test-ShrRetirementImagesAvailable -ARMToken token -SessionHosts @() -State $global:shrImages.State
        $result.SafeToProceed | Should -BeFalse
    }
}

Describe 'SHR semantic protected configuration' {
    It 'accepts JSON formatting and property-order changes without accepting value changes' {
        $coordinator = Get-Module SessionHostReplacer.Continuation -All | Select-Object -First 1
        & $coordinator {
            $settings = @{ SessionHostParameters = '{"Location":"eastus","Tags":{"a":"one","b":"two"}}' }
            $state = @{
                ConfigurationHash = Get-ShrConfigurationHash -Settings $settings
                ConfigurationTargetCount = $null
            }
            Get-ShrConfigurationHash -Settings $settings -OperationState $state -CaptureTarget | Out-Null
            $settings.SessionHostParameters = '{ "Tags": { "b": "two", "a": "one" }, "Location": "eastus" }'
            (Get-ShrConfigurationHash -Settings $settings -OperationState $state) | Should -Be $state.ConfigurationHash
            $settings.SessionHostParameters = '{"Location":"westus","Tags":{"a":"one","b":"two"}}'
            (Get-ShrConfigurationHash -Settings $settings -OperationState $state) | Should -Not -Be $state.ConfigurationHash
        }
    }
}

Describe 'SHR transient cleanup verification' {
    BeforeEach {
        Mock Get-ShrWorkerState -ModuleName SessionHostReplacer.DeviceCleanup { @{ Id = 'operation' } }
        Mock Assert-ShrWorkerLease -ModuleName SessionHostReplacer.DeviceCleanup {}
        Mock Write-LogEntry -ModuleName SessionHostReplacer.DeviceCleanup {}
        Mock Invoke-AzureRestMethod -ModuleName SessionHostReplacer.DeviceCleanup {
            throw [System.Net.Http.HttpRequestException]::new('temporary verification failure')
        }
        Mock Get-SessionHostDirectoryDevices -ModuleName SessionHostReplacer.DeviceCleanup {
            throw [System.Net.Http.HttpRequestException]::new('temporary verification failure')
        }
    }

    It 'preserves transient <Surface> read failures instead of converting them into permanent incomplete-cleanup errors' -ForEach @(
        @{ Surface = 'AVD' }, @{ Surface = 'VM' }, @{ Surface = 'Entra' }, @{ Surface = 'Intune' }
    ) {
        $hostState = [PSCustomObject]@{
            Name = 'host'
            VMName = 'host'
            VMUri = 'https://management.azure.com/vm'
            AVDConfirmed = $Surface -ne 'AVD'
            VMConfirmed = $Surface -ne 'VM'
            EntraIDConfirmed = $Surface -ne 'Entra'
            IntuneConfirmed = $Surface -ne 'Intune'
        }
        $cleanup = Get-Module SessionHostReplacer.DeviceCleanup -All | Select-Object -First 1
        {
            & $cleanup {
                param($HostState, $Surface)
                Wait-SessionHostDeletionVerification -ARMToken token -GraphToken token -HostsToVerify @($HostState) `
                    -RemoveEntraDevice:($Surface -eq 'Entra') -RemoveIntuneDevice:($Surface -eq 'Intune') `
                    -ResourceManagerUri 'https://management.azure.com' `
                    -HostPoolSubscriptionId sub -HostPoolResourceGroupName hosts -HostPoolName pool
            } $hostState $Surface
        } | Should -Throw '*temporary verification failure*'
    }
}

AfterAll {
    Remove-Variable shrImages -Scope Global -ErrorAction SilentlyContinue
    Remove-Module SessionHostReplacer -Force
}
