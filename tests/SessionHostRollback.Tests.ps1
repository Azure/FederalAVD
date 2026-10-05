$repoRoot = Split-Path -Parent $PSScriptRoot
$rollbackScriptPath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\Invoke-SessionHostRollback.ps1'

function New-RollbackArmResponse {
    param(
        [object]$Content,
        [int]$StatusCode = 200
    )

    [PSCustomObject]@{
        StatusCode = $StatusCode
        Content = if ($null -eq $Content) {
            ''
        }
        else {
            $Content | ConvertTo-Json -Depth 20 -Compress
        }
    }
}

Describe 'Session Host Replacer rollback execution' {
    BeforeEach {
        $global:rollbackSimulation = @{
            FunctionState = 'Stopped'
            ScalingExclusionValue = 'SessionHostReplacer'
            Calls = @()
        }

        Mock Get-AzContext {
            [PSCustomObject]@{
                Subscription = [PSCustomObject]@{
                    Id = 'function-subscription'
                }
            }
        }
        Mock Start-Sleep {}
        Mock Invoke-AzRestMethod {
            param($Method, $Path, $Payload)

            $global:rollbackSimulation.Calls += [PSCustomObject]@{
                Method = $Method
                Path = $Path
                Payload = $Payload
            }

            if ($Path -like '*/config/appsettings/list?api-version=*') {
                return New-RollbackArmResponse -Content @{
                    properties = @{
                        ReplacementMode = 'SideBySide'
                        EnableShutdownRetention = 'true'
                        VirtualMachinesSubscriptionId = 'vm-subscription'
                        VirtualMachinesResourceGroupName = 'rg-hosts'
                        HostPoolSubscriptionId = 'hostpool-subscription'
                        HostPoolResourceGroupName = 'rg-hostpool'
                        HostPoolName = 'hp-prod'
                        Tag_ShutdownTimestamp = 'AutoReplaceShutdownTimestamp'
                        Tag_ScalingPlanExclusionTag = 'ScalingPlanExclusion'
                        Tag_IncludeInAutomation = 'IncludeInAutoReplace'
                    }
                }
            }

            if ($Path -like '*/providers/Microsoft.Web/sites/func-shr?api-version=*') {
                return New-RollbackArmResponse -Content @{
                    properties = @{
                        state = $global:rollbackSimulation.FunctionState
                    }
                }
            }

            if ($Path -like '*/providers/Microsoft.Web/sites/func-shr/stop?api-version=*') {
                $global:rollbackSimulation.FunctionState = 'Stopped'
                return New-RollbackArmResponse -Content $null -StatusCode 202
            }

            if ($Path -like '*/providers/Microsoft.Compute/virtualMachines?api-version=*') {
                return New-RollbackArmResponse -Content @{
                    value = @(
                        @{
                            name = 'avd-001'
                            id = '/subscriptions/vm-subscription/resourceGroups/rg-hosts/providers/Microsoft.Compute/virtualMachines/avd-001'
                            tags = @{
                                AutoReplaceShutdownTimestamp = '2026-10-05T10:00:00Z'
                                ScalingPlanExclusion = $global:rollbackSimulation.ScalingExclusionValue
                                IncludeInAutoReplace = 'true'
                            }
                        }
                    )
                }
            }

            if ($Path -like '*/hostPools/hp-prod/sessionHosts?api-version=*') {
                return New-RollbackArmResponse -Content @{
                    value = @(
                        @{
                            id = '/subscriptions/hostpool-subscription/resourceGroups/rg-hostpool/providers/Microsoft.DesktopVirtualization/hostPools/hp-prod/sessionHosts/avd-001.contoso.test'
                            name = 'avd-001.contoso.test'
                            properties = @{
                                resourceId = '/subscriptions/vm-subscription/resourceGroups/rg-hosts/providers/Microsoft.Compute/virtualMachines/avd-001'
                                status = 'Shutdown'
                                allowNewSession = $false
                                healthCheckResults = @()
                            }
                        }
                    )
                }
            }

            if ($Method -eq 'GET' -and $Path -like '*/sessionHosts/avd-001.contoso.test?api-version=*') {
                return New-RollbackArmResponse -Content @{
                    id = '/subscriptions/hostpool-subscription/resourceGroups/rg-hostpool/providers/Microsoft.DesktopVirtualization/hostPools/hp-prod/sessionHosts/avd-001.contoso.test'
                    properties = @{
                        status = 'Available'
                        allowNewSession = $false
                        healthCheckResults = @(
                            @{
                                healthCheckResult = 'HealthCheckSucceeded'
                            }
                        )
                    }
                }
            }

            if ($Method -in @('POST', 'PATCH')) {
                return New-RollbackArmResponse -Content $null -StatusCode 202
            }

            throw "Unexpected ARM request: $Method $Path"
        }
    }

    AfterEach {
        Remove-Variable rollbackSimulation -Scope Global -ErrorAction SilentlyContinue
    }

    It 'restores a retained host in safe order and opts it out of automation' {
        $result = & $rollbackScriptPath `
            -FunctionAppName func-shr `
            -FunctionAppResourceGroupName rg-operations `
            -Confirm:$false `
            -PassThru

        $result.SessionHostName | Should Be 'avd-001'
        $result.Status | Should Be 'Restored'
        $result.AutomationEnabled | Should Be $false

        $startCall = $global:rollbackSimulation.Calls | Where-Object {
            $_.Method -eq 'POST' -and $_.Path -like '*/virtualMachines/avd-001/start?api-version=*'
        } | Select-Object -First 1
        $allowSessionCall = $global:rollbackSimulation.Calls | Where-Object {
            $_.Method -eq 'PATCH' -and $_.Path -like '*/sessionHosts/avd-001.contoso.test?api-version=*'
        } | Select-Object -First 1
        $tagCalls = @($global:rollbackSimulation.Calls | Where-Object {
            $_.Method -eq 'PATCH' -and $_.Path -like '*/providers/Microsoft.Resources/tags/default?api-version=*'
        })

        $startCall | Should Not BeNullOrEmpty
        $allowSessionCall | Should Not BeNullOrEmpty
        ($allowSessionCall.Payload | ConvertFrom-Json).properties.allowNewSession | Should Be $true
        $tagCalls.Count | Should Be 2

        $deleteTagCall = $tagCalls | Where-Object {
            ($_.Payload | ConvertFrom-Json).operation -eq 'Delete'
        } | Select-Object -First 1
        $mergeTagCall = $tagCalls | Where-Object {
            ($_.Payload | ConvertFrom-Json).operation -eq 'Merge'
        } | Select-Object -First 1
        $deleteTags = ($deleteTagCall.Payload | ConvertFrom-Json).properties.tags
        ($deleteTags.PSObject.Properties.Name -contains 'AutoReplaceShutdownTimestamp') |
            Should Be $true
        ($deleteTags.PSObject.Properties.Name -contains 'ScalingPlanExclusion') |
            Should Be $true

        $mergeTags = ($mergeTagCall.Payload | ConvertFrom-Json).properties.tags
        $mergeTags.IncludeInAutoReplace | Should Be 'false'
    }

    It 'fails closed when the Function App is running and stop was not requested' {
        $global:rollbackSimulation.FunctionState = 'Running'

        $caughtError = $null
        try {
            & $rollbackScriptPath `
                -FunctionAppName func-shr `
                -FunctionAppResourceGroupName rg-operations `
                -Confirm:$false
        }
        catch {
            $caughtError = $_
        }

        $caughtError | Should Not BeNullOrEmpty
        $caughtError.Exception.Message | Should Match 'Stop it first or rerun with -StopFunctionApp'

        @($global:rollbackSimulation.Calls | Where-Object {
            $_.Path -like '*/virtualMachines/avd-001/start?api-version=*'
        }).Count | Should Be 0
    }

    It 'stops a running Function App before starting retained hosts when explicitly requested' {
        $global:rollbackSimulation.FunctionState = 'Running'

        & $rollbackScriptPath `
            -FunctionAppName func-shr `
            -FunctionAppResourceGroupName rg-operations `
            -StopFunctionApp `
            -Confirm:$false

        $stopIndex = -1
        $startIndex = -1
        for ($index = 0; $index -lt $global:rollbackSimulation.Calls.Count; $index++) {
            $call = $global:rollbackSimulation.Calls[$index]
            if ($call.Path -like '*/sites/func-shr/stop?api-version=*') {
                $stopIndex = $index
            }
            if ($call.Path -like '*/virtualMachines/avd-001/start?api-version=*') {
                $startIndex = $index
            }
        }

        $stopIndex | Should BeGreaterThan -1
        $startIndex | Should BeGreaterThan $stopIndex
    }

    It 'preserves an administrator-owned scaling exclusion' {
        $global:rollbackSimulation.ScalingExclusionValue = 'Administrator'

        & $rollbackScriptPath `
            -FunctionAppName func-shr `
            -FunctionAppResourceGroupName rg-operations `
            -Confirm:$false

        $deleteTagCall = $global:rollbackSimulation.Calls | Where-Object {
            $_.Method -eq 'PATCH' -and
            $_.Path -like '*/providers/Microsoft.Resources/tags/default?api-version=*' -and
            ($_.Payload | ConvertFrom-Json).operation -eq 'Delete'
        } | Select-Object -First 1
        $deleteTags = ($deleteTagCall.Payload | ConvertFrom-Json).properties.tags

        ($deleteTags.PSObject.Properties.Name -contains 'AutoReplaceShutdownTimestamp') |
            Should Be $true
        ($deleteTags.PSObject.Properties.Name -contains 'ScalingPlanExclusion') |
            Should Be $false
    }
}
