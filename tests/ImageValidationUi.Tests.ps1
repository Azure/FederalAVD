$repoRoot = Split-Path -Parent $PSScriptRoot
$formPath = Join-Path $repoRoot 'deployments\add-ons\imageValidation\uiFormDefinition.json'
$templatePath = Join-Path $repoRoot 'deployments\add-ons\imageValidation\main.json'
$form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
$template = Get-Content -LiteralPath $templatePath -Raw | ConvertFrom-Json
$steps = @{}
foreach ($step in $form.view.properties.steps) {
    $steps[$step.name] = $step
}

Describe 'Image validation Portal form' {
    It 'maps every output to a template parameter and supplies every required parameter' {
        $form.view.outputs.kind | Should Be 'Subscription'
        $form.view.outputs.subscriptionId | Should Be "[concat('/subscriptions/', steps('basics').scope.subscription.subscriptionId)]"
        $form.view.outputs.location | Should Be "[steps('basics').scope.location.name]"
        foreach ($name in $form.view.outputs.parameters.PSObject.Properties.Name) {
            ($template.parameters.PSObject.Properties.Name -contains $name) | Should Be $true
        }
        foreach ($parameter in $template.parameters.PSObject.Properties) {
            if ($parameter.Value.PSObject.Properties.Name -notcontains 'defaultValue') {
                ($form.view.outputs.parameters.PSObject.Properties.Name -contains $parameter.Name) | Should Be $true
            }
        }
        ($form.view.properties.steps.name -join ',') | Should Be 'basics,virtualMachine,functionApp,namingAndTags'
    }

    It 'binds the selected gallery version, VM networking, and integrity monitoring' {
        $outputs = $form.view.outputs.parameters
        $outputs.imageVersionResourceId |
            Should Be "[first(map(steps('virtualMachine').image.versionsApi.transformed.list, (item) => item.value))]"
        $outputs.keyVaultResourceId | Should Be "[steps('virtualMachine').credentials.keyVault.id]"
        $outputs.subnetResourceId | Should Be "[steps('virtualMachine').network.subnet]"
        $outputs.privateIPAddress | Should Be "[steps('virtualMachine').network.privateIPAddress]"
        $outputs.virtualMachineSize | Should Be "[steps('virtualMachine').general.size]"
        $outputs.integrityMonitoring | Should Be "[steps('virtualMachine').security.integrityMonitoring]"
        $outputs.secureBoot | Should Be "[steps('virtualMachine').security.secureBoot]"
        $outputs.vTpm | Should Be "[steps('virtualMachine').security.vTpm]"
    }

    It 'clears new-plan inputs for an existing plan without submitting an invalid SKU' {
        $outputs = $form.view.outputs.parameters
        $outputs.appServicePlanName |
            Should Be "[if(steps('functionApp').general.existingAppServicePlan, '', steps('namingAndTags').naming.appServicePlan)]"
        $outputs.appServicePlanResourceId |
            Should Be "[if(steps('functionApp').general.existingAppServicePlan, steps('functionApp').general.appServicePlan.id, '')]"
        $outputs.appServicePlanSku |
            Should Be "[if(steps('functionApp').general.existingAppServicePlan, 'P0v3', steps('functionApp').general.appServicePlanSku)]"
        ($template.parameters.appServicePlanSku.allowedValues -contains 'P0v3') | Should Be $true
    }

    It 'uses the VM subnet for endpoints and selects integration for both private and service modes' {
        $network = $steps.functionApp.elements | Where-Object name -eq 'networkSettings'
        $control = $network.elements | Where-Object name -eq 'networkAccess'
        ($control.constraints.allowedValues.value -join ',') | Should Be 'private,service,public'
        $control.defaultValue | Should Be 'Disable public access and use private access'
        $form.view.outputs.parameters.endpointType | Should Be "[steps('functionApp').networkSettings.networkAccess]"
        $integration = $network.elements | Where-Object name -eq 'delegatedSubnet'
        $integration.visible | Should Be "[not(equals(steps('functionApp').networkSettings.networkAccess, 'public'))]"
        $integration.constraints.allowedValues | Should Match 'microsoft.web/serverfarms'
        $form.view.outputs.parameters.functionAppDelegatedSubnetResourceId |
            Should Be "[if(not(equals(steps('functionApp').networkSettings.networkAccess, 'public')), steps('functionApp').networkSettings.delegatedSubnet, '')]"
        ($form.view.outputs.parameters.PSObject.Properties.Name -contains 'privateEndpointSubnetResourceId') | Should Be $false
        $dns = $steps.functionApp.elements | Where-Object name -eq 'privateDnsZones'
        $dns.visible | Should Be "[equals(steps('functionApp').networkSettings.networkAccess, 'private')]"
        foreach ($binding in @(
            @{ Parameter = 'azureBlobPrivateDnsZoneResourceId'; Control = 'azureBlobs' }
            @{ Parameter = 'azureFunctionAppPrivateDnsZoneResourceId'; Control = 'azureFunctions' }
            @{ Parameter = 'azureKeyVaultPrivateDnsZoneResourceId'; Control = 'keyVault' }
        )) {
            $form.view.outputs.parameters.($binding.Parameter) |
                Should Be "[if(equals(steps('functionApp').networkSettings.networkAccess, 'private'), steps('functionApp').privateDnsZones.$($binding.Control), '')]"
        }
    }

    It 'clears disabled monitoring outputs and selects private monitoring only in private mode' {
        $form.view.outputs.parameters.logAnalyticsWorkspaceResourceId |
            Should Be "[if(equals(steps('functionApp').monitoring.enableMonitoring, 'enabled'), steps('functionApp').monitoring.workspace.id, '')]"
        $form.view.outputs.parameters.privateLinkScopeResourceId |
            Should Be "[if(and(equals(steps('functionApp').monitoring.enableMonitoring, 'enabled'), equals(steps('functionApp').networkSettings.networkAccess, 'private')), steps('functionApp').monitoring.privateLinkScope.id, '')]"
        $monitoring = $steps.functionApp.elements | Where-Object name -eq 'monitoring'
        ($monitoring.elements | Where-Object name -eq 'privateLinkScope').visible |
            Should Be "[and(equals(steps('functionApp').monitoring.enableMonitoring, 'enabled'), equals(steps('functionApp').networkSettings.networkAccess, 'private'))]"
    }

    It 'aligns artifact grid columns with the shared customization type and clears disabled customizations' {
        $customizations = $steps.virtualMachine.elements | Where-Object name -eq 'customizations'
        $grid = $customizations.elements | Where-Object name -eq 'customScripts'
        $grid.type | Should Be 'Microsoft.Common.EditableGrid'
        $typeName = ($template.parameters.virtualMachineCustomizations.items.'$ref' -split '/')[-1]
        ($grid.constraints.columns.id | Sort-Object) -join ',' |
            Should Be (($template.definitions.$typeName.properties.PSObject.Properties.Name | Sort-Object) -join ',')
        foreach ($column in $grid.constraints.columns) {
            $column.element.type | Should Be 'Microsoft.Common.TextBox'
            ($column.element.PSObject.Properties.Name -contains 'defaultValue') | Should Be $false
        }
        $form.view.outputs.parameters.virtualMachineCustomizations |
            Should Be "[if(steps('virtualMachine').customizations.addCustomScripts, steps('virtualMachine').customizations.customScripts, parse('[]'))]"
        foreach ($name in @('artifactsContainerUri', 'artifactsUserAssignedIdentityResourceId')) {
            $form.view.outputs.parameters.$name | Should Match "^(\[if\(steps\('virtualMachine'\)\.customizations\.addCustomScripts,)"
            $form.view.outputs.parameters.$name | Should Match ", ''\)\]$"
        }
    }

    It 'passes explicit names and resource-type tags rather than generated-name inputs' {
        $naming = $steps.namingAndTags.elements | Where-Object name -eq 'naming'
        foreach ($binding in @(
            @{ Parameter = 'resourceGroupName'; Control = 'resourceGroup' }
            @{ Parameter = 'functionAppName'; Control = 'functionApp' }
            @{ Parameter = 'storageAccountName'; Control = 'storage' }
            @{ Parameter = 'applicationInsightsName'; Control = 'applicationInsights' }
            @{ Parameter = 'keyVaultName'; Control = 'keyVault' }
            @{ Parameter = 'userAssignedIdentityName'; Control = 'userAssignedIdentity' }
            @{ Parameter = 'virtualMachineName'; Control = 'virtualMachine' }
            @{ Parameter = 'diskName'; Control = 'disk' }
            @{ Parameter = 'networkInterfaceName'; Control = 'networkInterface' }
            @{ Parameter = 'templateSpecName'; Control = 'templateSpec' }
        )) {
            $form.view.outputs.parameters.($binding.Parameter) |
                Should Be "[steps('namingAndTags').naming.$($binding.Control)]"
            ($naming.elements.name -contains $binding.Control) | Should Be $true
        }
        $tags = ($steps.namingAndTags.elements | Where-Object name -eq 'tagsSection').elements |
            Where-Object name -eq 'tags'
        $tags.type | Should Be 'Microsoft.Common.TagsByResource'
        $form.view.outputs.parameters.tags | Should Be "[steps('namingAndTags').tagsSection.tags]"
    }

    It 'accepts six-field schedules and app-setting references with the current default' {
        $general = $steps.functionApp.elements | Where-Object name -eq 'general'
        $schedule = $general.elements | Where-Object name -eq 'schedule'
        $schedule.defaultValue | Should Be $template.parameters.schedule.defaultValue
        $regex = $schedule.constraints.validations[0].regex
        ('0 0 21 * * *' -match $regex) | Should Be $true
        ('%ImageValidationSchedule%' -match $regex) | Should Be $true
        ('0 21 * * *' -match $regex) | Should Be $false
        ('   ' -match $regex) | Should Be $false
        foreach ($step in $form.view.properties.steps) {
            $controls = @($step.elements) + @($step.elements | ForEach-Object { $_.elements })
            foreach ($control in $controls | Where-Object type -in @('Microsoft.Common.DropDown', 'Microsoft.Common.OptionsGroup')) {
                if ($control.defaultValue -and $control.defaultValue -notmatch '^\[' -and $control.constraints.allowedValues -is [array]) {
                    ($control.defaultValue -in $control.constraints.allowedValues.label) | Should Be $true
                }
            }
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
        $package = New-DeduplicatedTemplateSpecPackage -TemplateFile $templatePath -FormFile $formPath -Location 'eastus'
        $armBytes = (Get-Item -LiteralPath $templatePath).Length
        ($armBytes -lt 4000000) | Should Be $true
        ($package.PayloadBytes + 16384 -lt 2000000) | Should Be $true
        Write-Host "Image validation ARM: $armBytes bytes; ARM headroom: $(4000000 - $armBytes) bytes; Template Spec with form: $($package.PayloadBytes) bytes; publishing headroom: $(2000000 - $package.PayloadBytes - 16384) bytes."
    }
}
