$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'tools\New-TemplateSpecs.ps1'
$tokens = $null
$parseErrors = $null
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)

if ($parseErrors.Count -gt 0) {
    throw "New-TemplateSpecs.ps1 has $($parseErrors.Count) PowerShell parse error(s)."
}

Describe 'Networking Template Spec form parameter contract' {
    $template = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\networking\networking.json') -Raw | ConvertFrom-Json
    $form = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\networking\uiFormDefinition.json') -Raw | ConvertFrom-Json
    $wrapperTemplate = $template.resources.vnetResources.properties.template
    $networkTemplate = $wrapperTemplate.resources.vnetResources.properties.template
    $virtualNetworkStep = $form.view.properties.steps | Where-Object { $_.name -eq 'virtualNetwork' }
    $deploymentSection = $virtualNetworkStep.elements | Where-Object { $_.name -eq 'deploy' }
    $routingControl = $deploymentSection.elements | Where-Object { $_.name -eq 'defaultRouteType' }

    It 'maps every template parameter without a default, including nullable parameters' {
        $outputNames = @($form.view.outputs.parameters.PSObject.Properties.Name)
        $missingOutputs = @(
            $template.parameters.PSObject.Properties |
                Where-Object {
                    $null -eq $_.Value.PSObject.Properties['defaultValue'] -and
                    $_.Name -notin $outputNames
                } |
                Select-Object -ExpandProperty Name
        )

        $missingOutputs | Should BeNullOrEmpty
        @($outputNames | Where-Object { $_ -notin $template.parameters.PSObject.Properties.Name }) |
            Should BeNullOrEmpty
        ($outputNames -contains 'defaultOutboundAccess') | Should Be $false
        foreach ($networkScope in @($template, $wrapperTemplate, $networkTemplate)) {
            ($networkScope.parameters.PSObject.Properties.Name -contains 'defaultOutboundAccess') | Should Be $false
        }
    }

    It 'offers exactly the routing modes accepted at every template scope' {
        foreach ($networkScope in @($template, $wrapperTemplate, $networkTemplate)) {
            @(Compare-Object @('default', 'nva', 'nat') @($networkScope.parameters.defaultRouting.allowedValues)) |
                Should BeNullOrEmpty
            @(Compare-Object @($routingControl.constraints.allowedValues.value) @($networkScope.parameters.defaultRouting.allowedValues)) |
                Should BeNullOrEmpty
        }
        ($routingControl.defaultValue -in $routingControl.constraints.allowedValues.label) | Should Be $true
        $form.view.outputs.parameters.defaultRouting | Should Match 'deploy\.defaultRouteType'
    }

    It 'limits NAT creation to NAT routing or NVA bypass and public Shortpath' {
        $networkTemplate.variables.deployNatGateway |
            Should Be "[or(equals(parameters('defaultRouting'), 'nat'), and(equals(parameters('defaultRouting'), 'nva'), or(parameters('includeAvdBypassRoutes'), parameters('rdpShortpathPublicNetworks'))))]"
        $networkTemplate.resources.natGateway.condition | Should Be "[variables('deployNatGateway')]"
        $networkTemplate.resources.publicIp.condition | Should Be "[variables('deployNatGateway')]"
    }

    It 'creates and attaches a route table only in NVA mode' {
        $networkTemplate.resources.routeTable.condition | Should Be "[equals(parameters('defaultRouting'), 'nva')]"
        $hosts = $networkTemplate.variables.copy | Where-Object { $_.name -eq 'snetHosts' }
        $attachment = "[if(equals(parameters('defaultRouting'), 'nva'), createObject('id', resourceId('Microsoft.Network/routeTables', parameters('routeTableName'))), null())]"
        $hosts.input.properties.routeTable | Should Be $attachment
        $networkTemplate.variables.snetFunctionApp |
            Should Match ([regex]::Escape("'routeTable', $($attachment.Trim('[', ']'))"))
    }

    It 'explicitly disables implicit outbound access on every created subnet purpose' {
        $hosts = $networkTemplate.variables.copy | Where-Object { $_.name -eq 'snetHosts' }
        ($hosts.input.properties.PSObject.Properties.Name -contains 'defaultOutboundAccess') | Should Be $true
        $hosts.input.properties.defaultOutboundAccess | Should Be $false
        $networkTemplate.variables.snetPrivateEndpoints |
            Should Match ([regex]::Escape("'defaultOutboundAccess', false()"))
        $networkTemplate.variables.snetFunctionApp |
            Should Match ([regex]::Escape("'defaultOutboundAccess', false()"))
    }

    It 'preserves gateway transit wiring and emits a boolean when peering is not selected' {
        $networkTemplate.resources.localVnetPeering.properties.parameters.useRemoteGateways.value |
            Should Be "[parameters('virtualNetworkGatewayOnHub')]"
        $networkTemplate.resources.remoteVnetPeering.properties.parameters.allowGatewayTransit.value |
            Should Be "[parameters('virtualNetworkGatewayOnHub')]"
        $form.view.outputs.parameters.virtualNetworkGatewayOnHub |
            Should Be "[if(steps('virtualNetwork').deployVnet, if(steps('virtualNetwork').deploy.peerVnetToHub, steps('virtualNetwork').deploy.hubVirtualNetworkGateway, false), false)]"
    }
}

Describe 'FSLogix Storage Template Spec deployment VM contract' {
    $form = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\add-ons\fslogixStorage\uiFormDefinition.json') -Raw | ConvertFrom-Json
    $template = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\add-ons\fslogixStorage\main.json') -Raw | ConvertFrom-Json
    $deployment = $form.view.properties.steps | Where-Object { $_.name -eq 'deployment' }
    $scope = $form.view.properties.steps | Where-Object { $_.name -eq 'scope' }
    $namingStep = $form.view.properties.steps | Where-Object { $_.name -eq 'tagsAndNaming' }
    $naming = $namingStep.elements | Where-Object { $_.name -eq 'naming' }
    $skipVm = "and(equals(steps('identity').machineIdentity, 'EntraID'), equals(steps('identity').identitySolution, 'EntraId'))"
    $requiresVm = "not($skipVm)"
    $outputs = $form.view.outputs.parameters

    It 'keeps the step visible and provides mutually exclusive literal explanations' {
        ($deployment.PSObject.Properties.Name -contains 'visible') | Should Be $false
        $requiredInfo = $deployment.elements | Where-Object { $_.name -eq 'deploymentInfo' }
        $skippedInfo = $deployment.elements | Where-Object { $_.name -eq 'deploymentNotRequiredInfo' }
        $requiredInfo.visible | Should Be "[$requiresVm]"
        $skippedInfo.visible | Should Be "[$skipVm]"
        $skippedInfo.type | Should Be 'Microsoft.Common.InfoBox'
        $skippedInfo.options.style | Should Be 'Info'
        $skippedInfo.options.text | Should Match 'No temporary deployment VM'
        $skippedInfo.options.text | Should Match 'storage account key authentication'
        $skippedInfo.options.text | Should Match 'NTFS permission configuration are skipped'
        $requiredInfo.options.text | Should Match 'identity-based'
        foreach ($info in @($requiredInfo, $skippedInfo)) {
            $info.options.text | Should Not Match '^\['
            $info.options.text | Should Not Match 'every storage option'
        }
    }

    It 'hides and makes VM selectors optional only for Entra-joined storage-key consumers' {
        foreach ($name in @('deploymentVirtualNetwork', 'deploymentVirtualMachineSubnet', 'deploymentVirtualMachineSize')) {
            $control = @($deployment.elements | Where-Object { $_.name -eq $name })
            $control.Count | Should Be 1
            $control[0].visible | Should Be "[$requiresVm]"
            $control[0].constraints.required | Should Be "[$requiresVm]"
        }
        $ou = $deployment.elements | Where-Object { $_.name -eq 'deploymentVirtualMachineOrganizationalUnitPath' }
        $ou.visible | Should Be "[and($requiresVm, startsWith(steps('storage').storageService, 'AzureNetAppFiles'))]"
        $ou.constraints.required | Should Be $ou.visible
    }

    It 'gates VM-only API calls even when a previous network selection remains populated' {
        $skus = $deployment.elements | Where-Object { $_.name -eq 'resourceSkusApi' }
        $subnets = $deployment.elements | Where-Object { $_.name -eq 'deploymentSubnetsApi' }
        @($scope.elements | Where-Object { $_.name -eq 'resourceSkusApi' }).Count | Should Be 0
        $skus.condition | Should Be "[and($requiresVm, not(empty(steps('scope').resourceScope.subscription.id)), not(empty(steps('scope').resourceScope.location)))]"
        $subnets.condition | Should Be "[and($requiresVm, not(empty(steps('deployment').deploymentVirtualNetwork.id)))]"
        $size = $deployment.elements | Where-Object { $_.name -eq 'deploymentVirtualMachineSize' }
        $size.constraints.allowedValues | Should Be "[if($requiresVm, steps('deployment').resourceSkusApi.transformed.deploymentVMSizes, parse('[]'))]"
        $subnet = $deployment.elements | Where-Object { $_.name -eq 'deploymentVirtualMachineSubnet' }
        $subnet.constraints.allowedValues | Should Match ('^\[if\(' + [regex]::Escape("and($requiresVm, not(empty(steps('deployment').deploymentVirtualNetwork.id)))"))
        $subnet.constraints.allowedValues | Should Match ", parse\('\[\]'\)\)\]$"
    }

    It 'does not pass hidden subnet, size, or OU selections to storage-key deployments' {
        $defaultSize = $template.parameters.deploymentVirtualMachineSize.defaultValue
        $outputs.deploymentVirtualMachineSize | Should Be "[if($skipVm, '$defaultSize', steps('deployment').deploymentVirtualMachineSize)]"
        $outputs.deploymentVirtualMachineSubnetResourceId | Should Be "[if($skipVm, '', steps('deployment').deploymentVirtualMachineSubnet.id)]"
        $outputs.deploymentVirtualMachineOrganizationalUnitPath |
            Should Be "[if(and($requiresVm, startsWith(steps('storage').storageService, 'AzureNetAppFiles')), steps('deployment').deploymentVirtualMachineOrganizationalUnitPath, '')]"
    }

    It 'hides and clears only temporary-resource naming overrides for storage-key authentication' {
        foreach ($parameter in @(
            'deploymentResourceGroupName',
            'deploymentVirtualMachineName',
            'deploymentVirtualMachineDiskName',
            'deploymentVirtualMachineNicName',
            'deploymentUserAssignedIdentityName'
        )) {
            $control = $naming.elements | Where-Object { $_.name -eq "${parameter}Override" }
            $control.visible | Should Be "[and(steps('tagsAndNaming').naming.enableNameOverrides, $requiresVm)]"
            $outputs.$parameter | Should Be "[if(and(steps('tagsAndNaming').naming.enableNameOverrides, $requiresVm), coalesce(steps('tagsAndNaming').naming.${parameter}Override, ''), '')]"
        }
        $storageOverride = $naming.elements | Where-Object { $_.name -eq 'storageResourceGroupNameOverride' }
        $storageOverride.visible | Should Be "[and(steps('tagsAndNaming').naming.enableNameOverrides, steps('scope').createStorageResourceGroup)]"
    }

    It 'allows omission of the subnet but rejects it when this add-on creates a VM' {
        $template.parameters.deploymentVirtualMachineSubnetResourceId.defaultValue | Should Be ''
        $template.parameters.deploymentVirtualMachineSubnetResourceId.metadata.description | Should Match '^Conditional\.'
        $template.variables.deploymentVirtualMachineRequired | Should Be "[not(equals(parameters('identitySolution'), 'EntraId'))]"
        $template.variables.deployDeploymentVirtualMachine | Should Be "[and(parameters('manageDeploymentVirtualMachine'), variables('deploymentVirtualMachineRequired'))]"
        $template.resources.deploymentHelper.condition | Should Be "[variables('deployDeploymentVirtualMachine')]"
        $template.resources.cleanupDeploymentHelper.condition | Should Be "[variables('deployDeploymentVirtualMachine')]"
        $template.resources.deploymentHelper.properties.parameters.virtualMachineSubnetResourceId |
            Should Be "[if(or(not(variables('deployDeploymentVirtualMachine')), not(empty(parameters('deploymentVirtualMachineSubnetResourceId')))), createObject('value', parameters('deploymentVirtualMachineSubnetResourceId')), createObject('value', fail('deploymentVirtualMachineSubnetResourceId is required when the add-on creates a temporary deployment VM.')))]"
    }

    It 'maps all outputs to known parameters and supplies every required parameter' {
        $parameterNames = @($template.parameters.PSObject.Properties.Name)
        $outputNames = @($outputs.PSObject.Properties.Name)
        @($outputNames | Where-Object { $_ -notin $parameterNames }) | Should BeNullOrEmpty
        @($template.parameters.PSObject.Properties | Where-Object {
            $null -eq $_.Value.PSObject.Properties['defaultValue'] -and $_.Name -notin $outputNames
        }) | Should BeNullOrEmpty
    }

    It 'fits the ARM and Template Spec UTF-8 size budgets including the form and envelope' {
        $templateBytes = [Text.Encoding]::UTF8.GetByteCount(($template | ConvertTo-Json -Depth 100 -Compress))
        $payload = @{
            location = 'eastus'
            properties = @{
                mainTemplate = $template
                uiFormDefinition = $form
                linkedTemplates = @()
            }
        }
        $payloadBytes = [Text.Encoding]::UTF8.GetByteCount(($payload | ConvertTo-Json -Depth 100 -Compress))
        $envelopeAllowance = 64KB
        $templateBytes | Should BeLessThan 4MB
        ($payloadBytes + $envelopeAllowance) | Should BeLessThan 2MB
        Write-Host "FSLogix ARM: $templateBytes bytes; headroom: $(4MB - $templateBytes) bytes."
        Write-Host "FSLogix Template Spec with form and 64 KiB envelope allowance: $($payloadBytes + $envelopeAllowance) bytes; headroom: $(2MB - $payloadBytes - $envelopeAllowance) bytes."
    }
}

$functionDefinitions = $scriptAst.FindAll(
    { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },
    $true
)
foreach ($functionDefinition in $functionDefinitions) {
    Invoke-Expression $functionDefinition.Extent.Text
}

Describe 'Template Spec naming conventions' {
    It 'uses the CAF-aligned default convention' {
        $name = New-ConventionName `
            -Components @('resourceType', 'workload', 'purpose', 'location') `
            -Delimiter '-' `
            -ResourceTypeCode 'ts' `
            -Purpose 'image-management' `
            -LocationAbbreviation 'use2' `
            -Workload 'avd'

        $name | Should Be 'ts-avd-image-management-use2'
    }

    It 'supports custom ordering, tokens, delimiters, and resource type codes' {
        $name = New-ConventionName `
            -Components @('freeform1', 'workload', 'purpose', 'environment', 'location', 'resourceType') `
            -Delimiter '_' `
            -ResourceTypeCode 'template' `
            -Purpose 'hostpool' `
            -LocationAbbreviation 'vir' `
            -Workload 'desktop' `
            -Environment 'prod' `
            -Freeform1 'contoso'

        $name | Should Be 'contoso_desktop_hostpool_prod_vir_template'
    }

    It 'omits none and empty optional components' {
        $name = New-ConventionName `
            -Components @('resourceType', 'none', 'freeform1', 'purpose', 'location') `
            -Delimiter '-' `
            -ResourceTypeCode 'ts' `
            -Purpose 'networking' `
            -LocationAbbreviation 'usw'

        $name | Should Be 'ts-networking-usw'
    }

    It 'accepts hashtable and PSCustomObject property sources' {
        $hashtableValue = Get-ObjectPropertyValue `
            -InputObject @{ templateSpecs = 'spec' } `
            -PropertyName 'templateSpecs' `
            -DefaultValue 'ts'
        $objectValue = Get-ObjectPropertyValue `
            -InputObject ([pscustomobject]@{ workload = 'desktop' }) `
            -PropertyName 'workload' `
            -DefaultValue 'avd'

        $hashtableValue | Should Be 'spec'
        $objectValue | Should Be 'desktop'
    }

    It 'does not expose the removed legacy naming parameter' {
        $parameterNames = $scriptAst.ParamBlock.Parameters.Name.VariablePath.UserPath

        ($parameterNames -contains 'NamingConvention') | Should Be $true
        ($parameterNames -contains 'nameConvResTypeAtEnd') | Should Be $false
    }

    It 'contains only ASCII characters' {
        (Get-Content -LiteralPath $scriptPath | Where-Object { $_ -match '[^\x00-\x7E]' }) |
            Should BeNullOrEmpty
    }
}
