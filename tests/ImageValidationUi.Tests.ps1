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

    It 'provides the requested steps plus validation VM, networking and monitoring settings' {
        ($form.view.properties.steps.name -join ',') | Should Be 'basics,validationVm,functionApp,networking,monitoring,namingAndTags'
        $steps.functionApp.label | Should Be 'Function App Settings'
        $steps.namingAndTags.label | Should Be 'Naming + Tags'
    }

    It 'maps every output to the current compiled subscription contract' {
        $form.view.outputs.kind | Should Be 'Subscription'
        $form.view.outputs.subscriptionId | Should Be "[steps('basics').subscription.subscriptionId]"
        $form.view.outputs.location | Should Be "[steps('basics').location.name]"
        ($form.view.outputs.parameters.PSObject.Properties.Name | Sort-Object) -join ',' |
            Should Be (($template.parameters.PSObject.Properties.Name | Sort-Object) -join ',')
        $form.view.outputs.parameters.imageDefinitionResourceId | Should Be "[steps('basics').imageDefinition.id]"
        $form.view.outputs.parameters.privateEndpoint | Should Be "[equals(steps('networking').privateEndpoint, 'private')]"
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
        ($steps.networking.elements | Where-Object name -eq 'privateEndpoint').defaultValue |
            Should Be 'Private endpoints (recommended)'
        $template.parameters.privateEndpoint.defaultValue | Should Be $true
        ($steps.namingAndTags.elements | Where-Object name -eq 'identifier').defaultValue |
            Should Be $template.parameters.identifier.defaultValue
        ($steps.monitoring.elements | Where-Object name -eq 'enableMonitoring').defaultValue | Should Be 'Disabled'
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
        $privateSection = $steps.networking.elements | Where-Object name -eq 'privateNetwork'
        $privateSection.visible | Should Be "[equals(steps('networking').privateEndpoint, 'private')]"
        foreach ($name in @('integrationSubnetId', 'endpointSubnetId', 'blobDnsZone', 'appDnsZone', 'vaultDnsZone')) {
            ($privateSection.elements | Where-Object name -eq $name).constraints.required |
                Should Be $privateSection.visible
        }
        foreach ($name in @('functionAppDelegatedSubnetResourceId', 'privateEndpointSubnetResourceId', 'azureBlobPrivateDnsZoneResourceId', 'azureFunctionAppPrivateDnsZoneResourceId', 'azureKeyVaultPrivateDnsZoneResourceId')) {
            $form.view.outputs.parameters.$name | Should Match "^\[if\(equals\(steps\('networking'\)\.privateEndpoint, 'private'\), .+, ''\)\]$"
        }
        $form.view.outputs.parameters.existingAppServicePlanResourceId |
            Should Be "[if(equals(steps('functionApp').hostingPlan, 'existing'), steps('functionApp').existingPlan.id, '')]"
        $form.view.outputs.parameters.privateLinkScopeResourceId |
            Should Be "[if(and(equals(steps('monitoring').enableMonitoring, 'enabled'), equals(steps('monitoring').privateMonitoring, 'private')), steps('monitoring').privateLinkScope.id, '')]"
        $form.view.outputs.parameters.encryptionKeyVaultNameOverride |
            Should Be "[steps('namingAndTags').overrides.encryptionKeyVault]"
    }

    It 'outputs typed app-setting rows and a flat tag object' {
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
        $form.view.outputs.parameters.tags |
            Should Be "[coalesce(steps('namingAndTags').tags['Microsoft.Resources/resourceGroups'], parse('{}'))]"
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
