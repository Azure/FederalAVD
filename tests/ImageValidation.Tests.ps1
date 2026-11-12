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
        foreach ($type in @('osdisks', 'networkInterfaces', 'templateSpecs', 'keyVaults')) {
            $template.variables.names | Should Match "__bicep\.resourceNameForType\(parameters\('namingConvention'\), '$type', parameters\('identifier'\), variables\('namingContext'\)\)"
        }
        $template.variables.validationVirtualMachineName |
            Should Match "__bicep\.resourceNameForType\(parameters\('namingConvention'\), 'virtualMachines', parameters\('identifier'\), variables\('namingContext'\)\)"
        $template.variables.names | Should Match "greater\(length\(variables\('validationVirtualMachineName'\)\), variables\('namingPolicy'\)\.limits\.deploymentVm\)"
        $template.variables.namingPolicy.limits.deploymentVm | Should Be 15
        $template.resources.templateSpec.properties.parameters.templateSpecName.value | Should Be "[variables('names').templateSpecName]"
        $template.resources.rg.name | Should Be "[variables('names').resourceGroup]"
        $template.resources.userAssignedIdentity.properties.parameters.name.value | Should Be "[variables('names').userAssignedIdentity]"
        foreach ($name in @('functionAppName', 'storageAccountName', 'applicationInsightsName', 'privateEndpointNameConv', 'privateEndpointNICNameConv')) {
            $app.$name.value | Should Be "[variables('names').$name]"
        }
        $template.outputs.generatedNames.value | Should Be "[variables('names')]"
    }

    It 'preserves explicit name overrides in the shared naming call' {
        foreach ($name in @('resourceGroupNameOverride', 'userAssignedIdentityNameOverride', 'appServicePlanNameOverride', 'functionAppNameOverride', 'storageAccountNameOverride', 'encryptionKeyVaultNameOverride')) {
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
        foreach ($variable in @('integrationSubnetId', 'endpointSubnetId', 'blobDnsZoneId', 'appDnsZoneId', 'vaultDnsZoneId')) {
            $template.variables.$variable | Should Match "parameters\('privateEndpoint'\)"
            $template.variables.$variable | Should Match "fail\('Private mode requires"
        }
        $app.functionAppDelegatedSubnetResourceId.value | Should Be "[variables('integrationSubnetId')]"
        $app.privateEndpointSubnetResourceId.value | Should Be "[variables('endpointSubnetId')]"
        $app.azureBlobPrivateDnsZoneResourceId.value | Should Be "[variables('blobDnsZoneId')]"
        $app.azureFunctionAppPrivateDnsZoneResourceId.value | Should Be "[variables('appDnsZoneId')]"
    }

    It 'embeds the packaged timer code and requires an explicit schedule' {
        ($template.parameters.schedule.PSObject.Properties.Name -contains 'defaultValue') | Should Be $false
        $runContent = $timer.files.value.'run.ps1'
        if ($runContent -match "^\[variables\('([^']+)'\)\]$") {
            $runContent = $template.variables.($Matches[1])
        }
        $runContent | Should Be (Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\add-ons\imageValidation\scripts\run.ps1') -Raw)
        ($timer.files.value.PSObject.Properties.Name -contains 'requirements.psd1') | Should Be $true
        ($timer.files.value.PSObject.Properties.Name -contains '../profile.ps1') | Should Be $true
        $timer.schedule.value | Should Be "[parameters('schedule')]"
        $timer.functionName.value | Should Be 'ImageValidation'
        $app.enableQueueStorage.value | Should Be $false
        $app.enableTableStorage.value | Should Be $false
    }

    It 'wires generated VM names and required workload inputs into app settings' {
        foreach ($name in @('imageVersionResourceId', 'keyVaultResourceId', 'privateIPAddress', 'subnetResourceId', 'virtualMachineSize')) {
            $template.parameters.$name.type | Should Be 'string'
            ($template.parameters.$name.PSObject.Properties.Name -contains 'defaultValue') | Should Be $false
            $app.functionAppAppSettings.value | Should Match "parameters\('$name'\)"
        }
        foreach ($name in @('diskName', 'networkInterfaceName', 'virtualMachineName')) {
            $app.functionAppAppSettings.value | Should Match "variables\('names'\)\.$name"
        }
        $app.functionAppAppSettings.value | Should Match "string\(parameters\('runCommandSettings'\)\)"
        $commandType = ($template.parameters.runCommandSettings.items.'$ref' -split '/')[-1]
        $template.definitions.$commandType.properties.parameters.type | Should Be 'array'
        $template.variables.additionalAppSettings | Should Match "fail\('Additional Function App settings cannot override"
        $template.variables.additionalAppSettings | Should Match "toLower"
    }

    It 'uses HSM customer-managed encryption and only enables monitoring with an existing workspace' {
        $app.keyManagementStorageAccounts.value | Should Be 'CustomerManagedHSM'
        $app.enableApplicationInsights.value | Should Be "[not(empty(parameters('logAnalyticsWorkspaceResourceId')))]"
        $app.logAnalyticsWorkspaceResourceId.value | Should Be "[parameters('logAnalyticsWorkspaceResourceId')]"
        $app.privateLinkScopeResourceId.value | Should Be "[parameters('privateLinkScopeResourceId')]"
    }

    It 'creates the encryption vault and storage-named key before Function infrastructure' {
        $vaults = $template.resources.encryptionKeyVault
        $cmk = $template.resources.storageCmk
        ($vaults.dependsOn -contains 'rg') | Should Be $true
        $vaults.properties.parameters.deploySecretsKeyVault.value | Should Be $false
        $vaults.properties.parameters.deployEncryptionKeyVault.value | Should Be $true
        $vaults.properties.parameters.encryptionKeyVaultName.value | Should Be "[variables('names').encryptionKeyVaultName]"
        ($cmk.dependsOn -contains 'encryptionKeyVault') | Should Be $true
        $cmk.properties.parameters.keyVaultResourceId.value |
            Should Be "[reference('encryptionKeyVault').outputs.encryptionKeyVaultResourceId.value]"
        $cmk.properties.parameters.keyNames.value.Count | Should Be 1
        $cmk.properties.parameters.keyNames.value[0] | Should Be $app.storageAccountName.value
        $app.encryptionKeyName.value | Should Be $app.storageAccountName.value
        $app.encryptionKeyVaultResourceId.value | Should Be $cmk.properties.parameters.keyVaultResourceId.value
        $cmk.properties.parameters.identityName.value | Should Be "[variables('names').storageEncryptionIdentityName]"
        $app.storageEncryptionIdentityName.value | Should Be $cmk.properties.parameters.identityName.value
        ($app.storageEncryptionIdentityName.value -ne $app.functionAppUserAssignedIdentityResourceId.value) | Should Be $true
        ($template.resources.functionApp.dependsOn -contains 'storageCmk') | Should Be $true
        ($template.resources.functionApp.dependsOn -contains 'encryptionKeyVault') | Should Be $true
        $app.functionAppAppSettings.value | Should Match "parameters\('keyVaultResourceId'\)"
    }

    It 'reuses protected Premium vault and key-scoped CMK provisioning with private networking and monitoring' {
        $vaults = $template.resources.encryptionKeyVault
        $vault = $vaults.properties.template.resources.encryptionKeyVault.properties.parameters
        $vault.sku.value | Should Be 'premium'
        $vault.enablePurgeProtection.value | Should Be $true
        $vault.enableSoftDelete.value | Should Be $true
        $vaults.properties.parameters.azureKeyVaultPrivateDnsZoneResourceId.value | Should Be "[variables('vaultDnsZoneId')]"
        $vaults.properties.parameters.privateEndpointSubnetResourceId.value | Should Be "[variables('endpointSubnetId')]"
        $vaults.properties.parameters.privateEndpoint.value | Should Be "[parameters('privateEndpoint')]"
        $vaults.properties.parameters.paasPublicNetworkAccess | Should Be $app.paasPublicNetworkAccess
        $vaults.properties.parameters.logAnalyticsWorkspaceResourceId.value | Should Be "[parameters('logAnalyticsWorkspaceResourceId')]"
        $vaults.properties.template.variables.encryptionKvNetworkAcls.bypass | Should Be 'AzureServices'
        $cmk = $template.resources.storageCmk.properties.template
        $template.resources.storageCmk.properties.parameters.keyManagementType.value | Should Be 'CustomerManagedHSM'
        $cmk.resources.paasKeys.properties.parameters.keySize.value | Should Be 4096
        $cmk.resources.paasKeys.properties.parameters.attributesExportable.value | Should Be $false
        $cmk.resources.paasKeys.properties.parameters.rotationPolicy.value | Should Be "[variables('rotationPolicy')]"
        $cmk.variables.roleKeyVaultCryptoEncryptionUser | Should Be 'e147488a-f6f5-4113-8e2d-b22465e65bf6'
        ($cmk.resources.paasKeyRoleAssignments.dependsOn -contains 'paasIdentity') | Should Be $true
        ($cmk.resources.paasKeyRoleAssignments.dependsOn -contains "[format('paasKeys[{0}]', copyIndex())]") | Should Be $true
    }

    It 'applies one tag set from Portal or parameter files to all supported resources' {
        $template.parameters.tags.type | Should Be 'object'
        @($template.parameters.tags.defaultValue.PSObject.Properties).Count | Should Be 0
        ($template.parameters.PSObject.Properties.Name -contains 'tagsByResource') | Should Be $false
        ($template.variables.PSObject.Properties.Name -contains 'commonTags') | Should Be $false
        ($template.variables.PSObject.Properties.Name -contains 'resourceTags') | Should Be $false
        $tagExpression = "[parameters('tags')]"
        $template.resources.rg.tags | Should Be $tagExpression
        $template.resources.userAssignedIdentity.properties.parameters.tags.value | Should Be $tagExpression
        $template.resources.templateSpec.properties.parameters.tags.value | Should Be $tagExpression
        $specTemplate = $template.resources.templateSpec.properties.template
        foreach ($resource in $specTemplate.resources) {
            $resource.tags | Should Be "[parameters('tags')]"
        }
        $specVersion = $specTemplate.resources | Where-Object type -eq 'Microsoft.Resources/templateSpecs/versions'
        $vmTemplate = $specVersion.properties.mainTemplate
        if ($vmTemplate -is [string] -and $vmTemplate -match "^\[variables\('([^']+)'\)\]$") {
            $vmTemplate = $specTemplate.variables.($Matches[1])
        }
        ($vmTemplate.parameters.tags.PSObject.Properties.Name -contains 'defaultValue') | Should Be $false
        $vmTemplate.resources.virtualMachine.properties.parameters.tags.value | Should Be "[[parameters('tags')]"
        foreach ($moduleName in @('encryptionKeyVault', 'storageCmk', 'serverFarm', 'functionApp')) {
            $template.resources.$moduleName.properties.parameters.tags.value | Should Be $tagExpression
        }
        $app.functionAppAppSettings.value | Should Match "string\(parameters\('tags'\)\)"
        $runContent = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\add-ons\imageValidation\scripts\run.ps1') -Raw
        $runContent | Should Match 'tags = @\{ value = \(\$env:tags \| ConvertFrom-Json -ErrorAction Stop\) \}'
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
