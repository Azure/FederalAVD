$repoRoot = Split-Path -Parent $PSScriptRoot
$formPath = Join-Path $repoRoot 'deployments\add-ons\imageValidation\uiFormDefinition.json'
$form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
$steps = @{}
foreach ($step in $form.view.properties.steps) {
    $steps[$step.name] = $step
}

Describe 'Image validation Portal form' {
    BeforeAll {
        $compiledPath = Join-Path ([IO.Path]::GetTempPath()) ('FederalAVD-ImageValidationUi-' + [guid]::NewGuid().ToString('N') + '.json')
        & az bicep build --file (Join-Path $repoRoot 'deployments\add-ons\imageValidation\main.bicep') --outfile $compiledPath
        if ($LASTEXITCODE -ne 0) { throw 'Image validation infrastructure did not compile.' }
        $template = Get-Content -LiteralPath $compiledPath -Raw | ConvertFrom-Json
    }

    AfterAll {
        if (Test-Path -LiteralPath $compiledPath) {
            Remove-Item -LiteralPath $compiledPath -Force -ErrorAction Stop
        }
    }

    It 'provides the requested steps with network and monitoring settings under the function app' {
        ($form.view.properties.steps.name -join ',') | Should Be 'basics,validationVm,functionApp,namingAndTags'
        $steps.functionApp.label | Should Be 'Function App Settings'
        $networkSection = $steps.functionApp.elements | Where-Object name -eq 'networkSettings'
        $networkSection.type | Should Be 'Microsoft.Common.Section'
        $networkSection.label | Should Be 'Network Settings'
        ($networkSection.elements.name -join ',') | Should Be 'privateEndpoint,publicWarning,prerequisites,integrationSubnetId,endpointSubnetId,blobDnsZone,appDnsZone,vaultDnsZone'
        @($networkSection.elements | Where-Object type -eq 'Microsoft.Common.Section').Count | Should Be 0
        (Get-Content -LiteralPath $formPath -Raw) | Should Not Match "steps\('networking'\)|\.privateNetwork\."
        $steps.namingAndTags.label | Should Be 'Naming + Tags'
    }

    It 'maps every output to the current compiled subscription contract' {
        $form.view.outputs.kind | Should Be 'Subscription'
        $form.view.outputs.subscriptionId | Should Be "[steps('basics').subscription.subscriptionId]"
        $form.view.outputs.location | Should Be "[steps('basics').location.name]"
        ($form.view.outputs.parameters.PSObject.Properties.Name | Sort-Object) -join ',' |
            Should Be (($template.parameters.PSObject.Properties.Name | Sort-Object) -join ',')
        $form.view.outputs.parameters.imageDefinitionResourceId | Should Be "[steps('basics').imageDefinition.id]"
        $form.view.outputs.parameters.privateEndpoint | Should Be "[equals(steps('functionApp').networkSettings.privateEndpoint, 'private')]"
        $form.view.outputs.parameters.namingConvention | Should Be "[parse('{}')]"
        $template.parameters.functionAppAppSettings.type | Should Be 'array'
        $template.parameters.privateEndpoint.type | Should Be 'bool'
        $template.parameters.tags.type | Should Be 'object'
    }

    It 'uses label defaults and preserves the template defaults' {
        foreach ($step in $form.view.properties.steps) {
            foreach ($element in $step.elements) {
                if ($element.type -eq 'Microsoft.Common.DropDown' -and $element.defaultValue) {
                    ($element.defaultValue -in $element.constraints.allowedValues.label) | Should Be $true
                }
            }
        }
        (($steps.functionApp.elements | Where-Object name -eq 'networkSettings').elements | Where-Object name -eq 'privateEndpoint').defaultValue |
            Should Be 'Private endpoints (recommended)'
        $template.parameters.privateEndpoint.defaultValue | Should Be $true
        (($steps.namingAndTags.elements | Where-Object name -eq 'naming').elements | Where-Object name -eq 'identifier').defaultValue |
            Should Be $template.parameters.identifier.defaultValue
        (($steps.functionApp.elements | Where-Object name -eq 'monitoring').elements | Where-Object name -eq 'enableMonitoring').defaultValue | Should Be 'Disabled'
    }

    It 'maps the required validation VM inputs and defaults Run Commands to a typed empty array' {
        foreach ($name in @('imageVersionResourceId', 'keyVault', 'subnetResourceId', 'privateIPAddress', 'virtualMachineSize')) {
            ($steps.validationVm.elements | Where-Object name -eq $name).constraints.required | Should Be $true
        }
        $form.view.outputs.parameters.imageVersionResourceId | Should Be "[steps('validationVm').imageVersionResourceId]"
        $form.view.outputs.parameters.keyVaultResourceId | Should Be "[steps('validationVm').keyVault.id]"
        $form.view.outputs.parameters.privateIPAddress | Should Be "[steps('validationVm').privateIPAddress]"
        $form.view.outputs.parameters.subnetResourceId | Should Be "[steps('validationVm').subnetResourceId]"
        $form.view.outputs.parameters.virtualMachineSize | Should Be "[steps('validationVm').virtualMachineSize]"
        $form.view.outputs.parameters.imageLicenseType | Should Be "[steps('validationVm').licenseType]"
        $form.view.outputs.parameters.runCommandSettings | Should Be "[parse('[]')]"
        $template.parameters.runCommandSettings.type | Should Be 'array'
        @($template.parameters.runCommandSettings.defaultValue).Count | Should Be 0
        $regex = ($steps.validationVm.elements | Where-Object name -eq 'privateIPAddress').constraints.validations[0].regex
        ('10.0.0.4' -match $regex) | Should Be $true
        ('10.0.0.256' -match $regex) | Should Be $false
    }

    It 'requires private inputs only in private mode and clears disabled selections' {
        $networkSection = $steps.functionApp.elements | Where-Object name -eq 'networkSettings'
        $privateCondition = "[equals(steps('functionApp').networkSettings.privateEndpoint, 'private')]"
        ($networkSection.elements | Where-Object name -eq 'prerequisites').visible | Should Be $privateCondition
        ($networkSection.elements | Where-Object name -eq 'publicWarning').visible |
            Should Be "[equals(steps('functionApp').networkSettings.privateEndpoint, 'public')]"
        $form.view.outputs.parameters.privateEndpoint | Should Be $privateCondition
        $privateOutputs = @{
            functionAppDelegatedSubnetResourceId = 'integrationSubnetId'
            privateEndpointSubnetResourceId = 'endpointSubnetId'
            azureBlobPrivateDnsZoneResourceId = 'blobDnsZone.id'
            azureFunctionAppPrivateDnsZoneResourceId = 'appDnsZone.id'
            azureKeyVaultPrivateDnsZoneResourceId = 'vaultDnsZone.id'
        }
        foreach ($name in @('integrationSubnetId', 'endpointSubnetId', 'blobDnsZone', 'appDnsZone', 'vaultDnsZone')) {
            $control = $networkSection.elements | Where-Object name -eq $name
            $control.visible | Should Be $privateCondition
            $control.constraints.required | Should Be $privateCondition
        }
        foreach ($name in $privateOutputs.Keys) {
            $form.view.outputs.parameters.$name |
                Should Be "[if(equals(steps('functionApp').networkSettings.privateEndpoint, 'private'), steps('functionApp').networkSettings.$($privateOutputs[$name]), '')]"
        }
        ($networkSection.elements | Where-Object name -eq 'endpointSubnetId').constraints.validations[1].isValid |
            Should Be "[not(equals(toLower(steps('functionApp').networkSettings.integrationSubnetId), toLower(steps('functionApp').networkSettings.endpointSubnetId)))]"
        $form.view.outputs.parameters.existingAppServicePlanResourceId |
            Should Be "[if(equals(steps('functionApp').hostingPlan, 'existing'), steps('functionApp').existingPlan.id, '')]"
        $form.view.outputs.parameters.privateLinkScopeResourceId |
            Should Be "[if(and(equals(steps('functionApp').monitoring.enableMonitoring, 'enabled'), equals(steps('functionApp').monitoring.privateMonitoring, 'private')), steps('functionApp').monitoring.privateLinkScope.id, '')]"
        $form.view.outputs.parameters.encryptionKeyVaultNameOverride |
            Should Be "[steps('namingAndTags').naming.encryptionKeyVault]"
    }

    It 'groups monitoring controls and preserves conditional selections and output bindings' {
        $monitoringSection = $steps.functionApp.elements | Where-Object name -eq 'monitoring'
        $monitoringSection.type | Should Be 'Microsoft.Common.Section'
        $monitoringSection.label | Should Be 'Monitoring'
        ($monitoringSection.elements.name -join ',') | Should Be 'enableMonitoring,workspace,privateMonitoring,monitoringInfo,privateLinkScope'
        @($monitoringSection.elements | Where-Object type -eq 'Microsoft.Common.Section').Count | Should Be 0
        (Get-Content -LiteralPath $formPath -Raw) | Should Not Match "steps\('monitoring'\)"
        $enabled = "[equals(steps('functionApp').monitoring.enableMonitoring, 'enabled')]"
        foreach ($name in @('workspace', 'privateMonitoring', 'monitoringInfo')) {
            ($monitoringSection.elements | Where-Object name -eq $name).visible | Should Be $enabled
        }
        foreach ($name in @('workspace', 'privateMonitoring')) {
            ($monitoringSection.elements | Where-Object name -eq $name).constraints.required | Should Be $enabled
        }
        foreach ($control in $monitoringSection.elements | Where-Object type -eq 'Microsoft.Common.DropDown') {
            ($control.defaultValue -in $control.constraints.allowedValues.label) | Should Be $true
        }
        $privateScope = $monitoringSection.elements | Where-Object name -eq 'privateLinkScope'
        $privateScope.visible | Should Be "[and(equals(steps('functionApp').monitoring.enableMonitoring, 'enabled'), equals(steps('functionApp').monitoring.privateMonitoring, 'private'))]"
        $privateScope.constraints.required | Should Be $privateScope.visible
        $form.view.outputs.parameters.logAnalyticsWorkspaceResourceId |
            Should Be "[if(equals(steps('functionApp').monitoring.enableMonitoring, 'enabled'), steps('functionApp').monitoring.workspace.id, '')]"
        $form.view.outputs.parameters.privateLinkScopeResourceId |
            Should Be "[if(and(equals(steps('functionApp').monitoring.enableMonitoring, 'enabled'), equals(steps('functionApp').monitoring.privateMonitoring, 'private')), steps('functionApp').monitoring.privateLinkScope.id, '')]"
    }

    It 'outputs typed app-setting rows' {
        $grid = $steps.functionApp.elements | Where-Object name -eq 'appSettings'
        ($grid.constraints.columns.id -join ',') | Should Be 'name,value'
        ($template.parameters.functionAppAppSettings.items.properties.PSObject.Properties.Name | Sort-Object) -join ',' |
            Should Be 'name,value'
        $grid.constraints.rows.count.min | Should Be 0
        foreach ($column in $grid.constraints.columns) {
            $column.element.type | Should Be 'Microsoft.Common.TextBox'
            ($column.element.PSObject.Properties.Name -contains 'defaultValue') | Should Be $false
        }
        $form.view.outputs.parameters.functionAppAppSettings | Should Be "[steps('functionApp').appSettings]"
    }

    It 'passes the single tag set without a separate tagsByResource parameter' {
        $template.parameters.tags.type | Should Be 'object'
        $form.view.outputs.parameters.tags | Should Match "^\[if\(empty\(steps\('namingAndTags'\)\.tagsSection\.tags\), parse\('\{\}'\), parse\(concat\("
        $form.view.outputs.parameters.tags | Should Not Match 'toObject|tagsByResource'
        ($form.view.outputs.parameters.PSObject.Properties.Name -contains 'tagsByResource') | Should Be $false
        ($template.parameters.PSObject.Properties.Name -contains 'tagsByResource') | Should Be $false
        $tagsSection = $steps.namingAndTags.elements | Where-Object name -eq 'tagsSection'
        $tagsControl = $tagsSection.elements | Where-Object name -eq 'tags'
        $tagsControl.type | Should Be 'Microsoft.Common.EditableGrid'
        $tagsControl.constraints.rows.count.min | Should Be 0
        $tagsControl.constraints.rows.count.max | Should Be 50
        ($tagsControl.constraints.columns.id -join ',') | Should Be 'key,value'
        foreach ($column in $tagsControl.constraints.columns) {
            $column.element.type | Should Be 'Microsoft.Common.TextBox'
            ($column.element.PSObject.Properties.Name -contains 'defaultValue') | Should Be $false
        }
        $keyColumn = $tagsControl.constraints.columns | Where-Object id -eq 'key'
        $valueColumn = $tagsControl.constraints.columns | Where-Object id -eq 'value'
        $keyColumn.element.constraints.required | Should Be $true
        $valueColumn.element.constraints.required | Should Be $false
        $keyRegex = $keyColumn.element.constraints.validations[0].regex
        ('Environment' -match $keyRegex) | Should Be $true
        (('a' * 128) -match $keyRegex) | Should Be $true
        (('a' * 129) -match $keyRegex) | Should Be $false
        foreach ($key in @('', 'Invalid/Key', 'Invalid\Key', 'Invalid?Key', 'Invalid&Key', 'Invalid%Key', 'Invalid<Key', 'Invalid>Key', "Invalid`nKey")) {
            ($key -match $keyRegex) | Should Be $false
        }
        $keyColumn.element.constraints.validations[1].isValid |
            Should Be "[equals(length(filter(steps('namingAndTags').tagsSection.tags, (item) => equals(toLower(item.key), toLower(last(take(steps('namingAndTags').tagsSection.tags, `$rowIndex)).key)))), 1)]"
        $valueRegex = $valueColumn.element.constraints.validations[0].regex
        ('' -match $valueRegex) | Should Be $true
        ('Quotes: " and path: C:\Temp' -match $valueRegex) | Should Be $true
        (('a' * 256) -match $valueRegex) | Should Be $true
        (('a' * 257) -match $valueRegex) | Should Be $false
        ($tagsSection.elements | Where-Object name -eq 'tagsInfo').options.text |
            Should Be 'Enter tags to apply to all the resources that support tags in this solution.'
        (Get-Content -LiteralPath $formPath -Raw) | Should Not Match "\[['""]"
    }

    It 'separates naming and tags into sections with updated bindings' {
        ($steps.namingAndTags.elements.name -join ',') | Should Be 'naming,tagsSection'
        ($steps.namingAndTags.elements.label -join ',') | Should Be 'Naming,Tags'
        foreach ($section in $steps.namingAndTags.elements) {
            $section.type | Should Be 'Microsoft.Common.Section'
            @($section.elements | Where-Object type -eq 'Microsoft.Common.Section').Count | Should Be 0
        }
        $naming = $steps.namingAndTags.elements | Where-Object name -eq 'naming'
        ($naming.elements.name -join ',') | Should Be 'namingInfo,identifier,resourceGroup,identity,encryptionKeyVault,plan,functionApp,storage'
        $bindings = @{
            identifier = 'identifier'
            resourceGroupNameOverride = 'resourceGroup'
            userAssignedIdentityNameOverride = 'identity'
            encryptionKeyVaultNameOverride = 'encryptionKeyVault'
            functionAppNameOverride = 'functionApp'
            storageAccountNameOverride = 'storage'
        }
        foreach ($parameter in $bindings.Keys) {
            $form.view.outputs.parameters.$parameter | Should Be "[steps('namingAndTags').naming.$($bindings[$parameter])]"
        }
        $form.view.outputs.parameters.appServicePlanNameOverride |
            Should Be "[if(equals(steps('functionApp').hostingPlan, 'new'), steps('namingAndTags').naming.plan, '')]"
        (Get-Content -LiteralPath $formPath -Raw) |
            Should Not Match "steps\('namingAndTags'\)\.(overrides|identifier|tags)\b"
    }

    It 'requires schedule structure without restricting it to a hard-coded schedule' {
        $schedule = $steps.functionApp.elements | Where-Object name -eq 'schedule'
        $schedule.constraints.required | Should Be $true
        $schedule.defaultValue | Should BeNullOrEmpty
        $regex = $schedule.constraints.validations[0].regex
        ('0 0 2 * * *' -match $regex) | Should Be $true
        ('%ImageValidationSchedule%' -match $regex) | Should Be $true
        ('0 2 * * *' -match $regex) | Should Be $false
        ('   ' -match $regex) | Should Be $false
    }

    It 'keeps explanatory text literal including nested sections' {
        $controls = @($form.view.properties.steps.elements)
        $controls += @($controls | Where-Object type -eq 'Microsoft.Common.Section' | ForEach-Object { $_.elements })
        foreach ($control in $controls | Where-Object type -eq 'Microsoft.Common.TextBlock') {
            $control.options.text | Should Not Match '^\['
        }
    }

    It 'fits the serialized Template Spec budget including the form and SDK envelope' {
        Import-Module Az.Resources -ErrorAction Stop
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $repoRoot 'tools\New-TemplateSpecs.ps1'), [ref]$tokens, [ref]$parseErrors
        )
        if ($parseErrors.Count -gt 0) { throw 'Template Spec publisher has parse errors.' }
        foreach ($definition in $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $true)) {
            Invoke-Expression $definition.Extent.Text
        }
        $package = New-DeduplicatedTemplateSpecPackage -TemplateFile $compiledPath -FormFile $formPath -Location 'eastus'
        $armBytes = (Get-Item -LiteralPath $compiledPath).Length
        ($armBytes -lt 4000000) | Should Be $true
        ($package.PayloadBytes + 16384 -lt 2000000) | Should Be $true
        Write-Host "Image validation ARM: $armBytes bytes; ARM headroom: $(4000000 - $armBytes) bytes; Template Spec with form: $($package.PayloadBytes) bytes; publishing headroom: $(2000000 - $package.PayloadBytes - 16384) bytes."
    }
}
