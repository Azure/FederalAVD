$repoRoot = Split-Path -Parent $PSScriptRoot
$restartScriptPath = Join-Path $repoRoot 'deployments\imageBuild\scripts\Restart-Vm.ps1'
$customizeModulePath = Join-Path $repoRoot 'deployments\imageBuild\modules\customizeImage.bicep'

function New-TestVmInstanceView {
    param (
        [string]$PowerState,
        [string]$AgentState
    )

    [pscustomobject]@{
        statuses = @(
            [pscustomobject]@{ code = $PowerState }
        )
        vmAgent = [pscustomobject]@{
            statuses = @(
                [pscustomobject]@{ code = $AgentState }
            )
        }
    }
}

Describe 'Image Build restart stability' {
    BeforeEach {
        $global:RestartStabilityNow = [datetime]'2026-01-01T00:00:00Z'
        $global:RestartStabilityGetCount = 0
        $global:RestartStabilityPostCount = 0
        $global:RestartStabilityStates = @(
            (New-TestVmInstanceView -PowerState 'PowerState/running' -AgentState 'ProvisioningState/succeeded')
            (New-TestVmInstanceView -PowerState 'PowerState/stopped' -AgentState 'ProvisioningState/unavailable')
            (New-TestVmInstanceView -PowerState 'PowerState/running' -AgentState 'ProvisioningState/succeeded')
            (New-TestVmInstanceView -PowerState 'PowerState/running' -AgentState 'ProvisioningState/succeeded')
            (New-TestVmInstanceView -PowerState 'PowerState/running' -AgentState 'ProvisioningState/succeeded')
            (New-TestVmInstanceView -PowerState 'PowerState/running' -AgentState 'ProvisioningState/succeeded')
        )

        Mock Get-Date {
            $global:RestartStabilityNow = $global:RestartStabilityNow.AddSeconds(60)
            $global:RestartStabilityNow
        }
        Mock Start-Sleep {}
        Mock Invoke-RestMethod {
            param($Headers, $Method, $Uri)

            if ($Uri -like 'http://169.254.169.254/*') {
                return [pscustomobject]@{ access_token = 'test-token' }
            }
            if ($Method -eq 'Post' -and $Uri -match '/restart\?') {
                $global:RestartStabilityPostCount++
                return
            }
            if ($Method -eq 'Get' -and $Uri -match '/instanceView\?') {
                $index = [Math]::Min($global:RestartStabilityGetCount, $global:RestartStabilityStates.Count - 1)
                $global:RestartStabilityGetCount++
                return $global:RestartStabilityStates[$index]
            }

            throw "Unexpected REST request: $Method $Uri"
        }
    }

    AfterEach {
        Remove-Variable -Name RestartStabilityNow -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name RestartStabilityGetCount -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name RestartStabilityPostCount -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name RestartStabilityStates -Scope Global -ErrorAction SilentlyContinue
    }

    It 'resets the stability timer when a follow-up reboot interrupts readiness' {
        $output = & $restartScriptPath `
            -ResourceManagerUri 'https://management.azure.com/' `
            -UserAssignedIdentityClientId '00000000-0000-0000-0000-000000000000' `
            -VmResourceId '/subscriptions/test/resourceGroups/test/providers/Microsoft.Compute/virtualMachines/image-vm' `
            -StableSeconds 180 `
            -ReadyTimeoutSeconds 900 `
            -PollIntervalSeconds 5

        $global:RestartStabilityPostCount | Should Be 1
        $global:RestartStabilityGetCount | Should Be 6
        ($output -join "`n") | Should Match 'Resetting stability timer'
        ($output -join "`n") | Should Match 'remained ready for 180 seconds'
    }

    It 'configures extended stabilization only for the post-update restart' {
        $content = Get-Content -LiteralPath $customizeModulePath -Raw
        $postUpdatesBlock = [regex]::Match(
            $content,
            "resource restartUpdates[\s\S]*?module conditionalRestartPostUpdates"
        ).Value

        $postUpdatesBlock | Should Match "name: 'StableSeconds'[\s\S]*?value: '180'"
        $postUpdatesBlock | Should Match "name: 'ReadyTimeoutSeconds'[\s\S]*?value: '1800'"
        $postUpdatesBlock | Should Match 'timeoutInSeconds: 2100'
        $content | Should Match "resource restartMicrosoftSoftware[\s\S]*?parameters: restartVMParameters"
        $content | Should Match "resource restartCustomizations[\s\S]*?parameters: restartVMParameters"
    }
}
