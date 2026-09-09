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
