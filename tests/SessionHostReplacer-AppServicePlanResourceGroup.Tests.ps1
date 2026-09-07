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