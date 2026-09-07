$repoRoot = Split-Path -Parent $PSScriptRoot
$bicepPath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\main.bicep'
$templatePath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\main.json'
$formPath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\uiFormDefinition.json'

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
