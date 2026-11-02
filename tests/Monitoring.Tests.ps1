$repoRoot = Split-Path -Parent $PSScriptRoot
$monitoringCases = @(
    @{ Name = 'Shared Services'; Path = 'deployments\sharedServices\sharedServices.json'; ModuleName = 'monitoring' }
    @{ Name = 'standard host pool'; Path = 'deployments\hostpools\hostpool.json'; ModuleName = 'sharedMonitoring' }
    @{ Name = 'automated host pool'; Path = 'deployments\automatedHostPools\automatedHostPool.json'; ModuleName = 'sharedMonitoring' }
    @{ Name = 'PoC host pool'; Path = 'deployments\hostpoolPoc\hostpoolPoc.json'; ModuleName = 'monitoring' }
)

Describe 'AVD monitoring destination table prerequisites' {
    foreach ($case in $monitoringCases) {
        Context $case.Name {
            BeforeAll {
                $arm = Get-Content -LiteralPath (Join-Path $repoRoot $case.Path) -Raw | ConvertFrom-Json
                $monitoring = $arm.resources.($case.ModuleName)
                $template = $monitoring.properties.template
                $workspace = $template.resources.logAnalyticsWorkspace
                $workspaceTemplate = $workspace.properties.template
                $tables = $workspaceTemplate.resources.builtInTables
                $dcr = $template.resources.avdInsightsDataCollectionRule
                $dcrResources = @($dcr.properties.template.resources |
                    Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' })
            }

            It 'provisions exactly the built-in tables required by the DCR streams' {
                $names = @($workspace.properties.parameters.builtInTableNames.value)
                ($names | Sort-Object) -join ',' | Should Be 'Event,Perf'
                $dcrResources.Count | Should Be 1
                $streams = @($dcrResources[0].properties.dataFlows.streams |
                    ForEach-Object { $_ -replace '^Microsoft-', '' } | Sort-Object -Unique)
                ($names | Sort-Object) -join ',' | Should Be ($streams -join ',')
            }

            It 'uses the supported table API and the workspace as the parent' {
                $tables.type | Should Be 'Microsoft.OperationalInsights/workspaces/tables'
                $tables.apiVersion | Should Be '2022-10-01'
                $tables.dependsOn | Should Contain 'logAnalyticsWorkspace'
                $tables.name | Should Be "[format('{0}/{1}', parameters('name'), parameters('builtInTableNames')[copyIndex()])]"
                $tables.copy.count | Should Be "[length(parameters('builtInTableNames'))]"
            }

            It 'leaves standard columns, custom columns, plan and retention to Azure or existing settings' {
                @($tables.properties.PSObject.Properties.Name).Count | Should Be 1
                $tables.properties.PSObject.Properties.Name | Should Be 'schema'
                @($tables.properties.schema.PSObject.Properties.Name).Count | Should Be 1
                $tables.properties.schema.PSObject.Properties.Name | Should Be 'name'
                $tables.properties.schema.name | Should Be "[parameters('builtInTableNames')[copyIndex()]]"
            }

            It 'waits for the entire workspace-and-tables deployment before creating the DCR' {
                $dcr.dependsOn | Should Contain 'logAnalyticsWorkspace'
                $dcr.dependsOn | Should Contain 'dataCollectionEndpoint'
                $dcr.properties.parameters.logAnalyticsWorkspaceResourceId.value |
                    Should Be "[reference('logAnalyticsWorkspace').outputs.resourceId.value]"
            }

            It 'keeps built-in table provisioning opt-in for other workspace-module callers' {
                @($workspaceTemplate.parameters.builtInTableNames.defaultValue).Count | Should Be 0
                $workspaceTemplate.parameters.builtInTableNames.type | Should Be 'array'
                $arm.parameters.PSObject.Properties.Name | Should Not Contain 'builtInTableNames'
            }

            It 'retains the monitoring creation condition and requires no script or fixed delay' {
                $monitoring.condition | Should Not BeNullOrEmpty
                $monitoringJson = $template | ConvertTo-Json -Depth 100 -Compress
                $monitoringJson | Should Not Match 'Microsoft\.Resources/deploymentScripts|Start-Sleep'
            }
        }
    }
}
