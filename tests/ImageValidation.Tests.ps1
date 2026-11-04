$repoRoot = Split-Path -Parent $PSScriptRoot

Describe 'Image validation infrastructure' {
    BeforeAll {
        $compiledPath = Join-Path ([IO.Path]::GetTempPath()) ('FederalAVD-ImageValidation-' + [guid]::NewGuid().ToString('N') + '.json')
        & az bicep build --file (Join-Path $repoRoot 'deployments\add-ons\imageValidation\main.bicep') --outfile $compiledPath
        if ($LASTEXITCODE -ne 0) { throw 'Image validation infrastructure did not compile.' }
        $template = Get-Content -LiteralPath $compiledPath -Raw | ConvertFrom-Json
        $app = $template.resources.functionApp.properties.parameters
        $timer = $template.resources.function.properties.parameters
    }

    AfterAll {
        if (Test-Path -LiteralPath $compiledPath) {
            Remove-Item -LiteralPath $compiledPath -Force -ErrorAction Stop
        }
    }

    It 'uses the shared naming bundle and actual owning scope for all infrastructure' {
        @($template.parameters.namingConvention.defaultValue.PSObject.Properties).Count | Should Be 0
        $template.variables.resourceGroupName | Should Match "__bicep\.resourceNameForType\(parameters\('namingConvention'\), 'resourceGroups'"
        $template.variables.groupContext.resourceGroupName | Should Be ''
        $template.variables.namingContext | Should Match "variables\('resourceGroupName'\)"
        $template.variables.names | Should Match '__bicep\.functionAppNames'
        $template.variables.names | Should Match "'userAssignedIdentities'"
        $template.variables.names | Should Match "'appServicePlans'"
        $template.resources.rg.name | Should Be "[variables('names').resourceGroup]"
        $template.resources.userAssignedIdentity.properties.parameters.name.value | Should Be "[variables('names').userAssignedIdentity]"
        foreach ($name in @('functionAppName', 'storageAccountName', 'applicationInsightsName', 'privateEndpointNameConv', 'privateEndpointNICNameConv')) {
            $app.$name.value | Should Be "[variables('names').$name]"
        }
        $template.outputs.generatedNames.value | Should Be "[variables('names')]"
    }

    It 'preserves explicit name overrides in the shared naming call' {
        foreach ($name in @('resourceGroupNameOverride', 'userAssignedIdentityNameOverride', 'appServicePlanNameOverride', 'functionAppNameOverride', 'storageAccountNameOverride')) {
            ($template.variables | ConvertTo-Json -Depth 10) | Should Match "parameters\('$name'\)"
        }
    }

    It 'creates a Windows Dedicated plan only when an existing plan ID is absent' {
        $template.resources.serverFarm.condition | Should Be "[empty(parameters('existingAppServicePlanResourceId'))]"
        $plan = $template.resources.serverFarm.properties.parameters
        $plan.functionAppKind.value | Should Be 'functionapp'
        $plan.hostingPlanType.value | Should Be 'Dedicated'
        $plan.planPricing.value | Should Be 'PremiumV3_P0v3'
        $plan.zoneRedundant.value | Should Be $false
        $app.serverFarmId | Should Be "[if(not(empty(parameters('existingAppServicePlanResourceId'))), createObject('value', parameters('existingAppServicePlanResourceId')), createObject('value', reference('serverFarm').outputs.hostingPlanId.value))]"
    }

    It 'attaches the created identity and sequences the timer after app infrastructure and host-storage roles' {
        $app.functionAppUserAssignedIdentityResourceId.value | Should Be "[reference('userAssignedIdentity').outputs.resourceId.value]"
        ($template.resources.functionApp.dependsOn -contains 'userAssignedIdentity') | Should Be $true
        ($template.resources.functionApp.dependsOn -contains 'serverFarm') | Should Be $true
        ($template.resources.function.dependsOn -contains 'functionApp') | Should Be $true
        $timer.functionAppName.value | Should Be "[reference('functionApp').outputs.functionAppName.value]"
        ($timer.PSObject.Properties.Name -contains 'location') | Should Be $false
        $template.outputs.userAssignedIdentityPrincipalId.value | Should Be "[reference('userAssignedIdentity').outputs.principalId.value]"
    }

    It 'requires private connectivity by default with an explicit public opt-out' {
        $template.parameters.privateEndpoint.defaultValue | Should Be $true
        $app.paasPublicNetworkAccess | Should Be "[if(parameters('privateEndpoint'), createObject('value', 'Disabled'), createObject('value', 'Enabled'))]"
        foreach ($variable in @('integrationSubnetId', 'endpointSubnetId', 'blobDnsZoneId', 'appDnsZoneId')) {
            $template.variables.$variable | Should Match "parameters\('privateEndpoint'\)"
            $template.variables.$variable | Should Match "fail\('Private mode requires"
        }
        $app.functionAppDelegatedSubnetResourceId.value | Should Be "[variables('integrationSubnetId')]"
        $app.privateEndpointSubnetResourceId.value | Should Be "[variables('endpointSubnetId')]"
        $app.azureBlobPrivateDnsZoneResourceId.value | Should Be "[variables('blobDnsZoneId')]"
        $app.azureFunctionAppPrivateDnsZoneResourceId.value | Should Be "[variables('appDnsZoneId')]"
    }

    It 'requires caller-supplied code and schedule instead of shipping successful placeholder validation' {
        ($template.parameters.files.PSObject.Properties.Name -contains 'defaultValue') | Should Be $false
        ($template.parameters.schedule.PSObject.Properties.Name -contains 'defaultValue') | Should Be $false
        $template.parameters.files.properties.'run.ps1'.type | Should Be 'string'
        $template.parameters.files.properties.'run.ps1'.nullable | Should Not Be $true
        $template.variables.validationFiles | Should Match "fail\('Supply approved image-validation code"
        $timer.files.value | Should Be "[variables('validationFiles')]"
        $timer.schedule.value | Should Be "[parameters('schedule')]"
        $timer.functionName.value | Should Be 'ImageValidation'
        $app.enableQueueStorage.value | Should Be $false
        $app.enableTableStorage.value | Should Be $false
    }

    It 'uses platform encryption and only enables monitoring with an existing workspace' {
        $app.keyManagementStorageAccounts.value | Should Be 'PlatformManaged'
        $app.enableApplicationInsights.value | Should Be "[not(empty(parameters('logAnalyticsWorkspaceResourceId')))]"
        $app.logAnalyticsWorkspaceResourceId.value | Should Be "[parameters('logAnalyticsWorkspaceResourceId')]"
        $app.privateLinkScopeResourceId.value | Should Be "[parameters('privateLinkScopeResourceId')]"
    }

    It 'fits conservative ARM and no-form Template Spec publishing budgets including the SDK envelope' {
        Import-Module Az.Resources -ErrorAction Stop
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $repoRoot 'tools\New-TemplateSpecs.ps1'), [ref]$tokens, [ref]$parseErrors
        )
        if ($parseErrors.Count -gt 0) { throw 'Template Spec publisher has parse errors.' }
        $definition = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Get-DeduplicatedTemplateSpecPayload'
        }, $true)
        Invoke-Expression $definition.Extent.Text
        $package = [pscustomobject]@{
            RootTemplate = [Newtonsoft.Json.Linq.JObject]::Parse((Get-Content -LiteralPath $compiledPath -Raw))
            UIFormDefinition = $null
            Artifacts = [System.Collections.Generic.List[Microsoft.Azure.Management.Resources.Models.LinkedTemplateArtifact]]::new()
        }
        $armBytes = (Get-Item -LiteralPath $compiledPath).Length
        $payloadBytes = [Text.Encoding]::UTF8.GetByteCount((Get-DeduplicatedTemplateSpecPayload -Package $package -Location 'eastus'))
        ($armBytes -lt 4000000) | Should Be $true
        ($payloadBytes + 16384 -lt 2000000) | Should Be $true
        Write-Host "Image validation ARM: $armBytes bytes; ARM headroom: $(4000000 - $armBytes). No-form SDK payload: $payloadBytes bytes; Template Spec headroom with metadata allowance: $(2000000 - $payloadBytes - 16384)."
    }
}
