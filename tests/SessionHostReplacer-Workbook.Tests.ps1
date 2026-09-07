$repoRoot = Split-Path -Parent $PSScriptRoot
$bicepPath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\main.bicep'
$templatePath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\main.json'
$formPath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\uiFormDefinition.json'
$namingPath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\modules\naming.bicep'
$workbookModulePath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\modules\workBook\workbook.bicep'

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
