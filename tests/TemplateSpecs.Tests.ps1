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

$sizeCases = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'deployments') -Filter 'uiFormDefinition.json' -File -Recurse |
    ForEach-Object {
        $formFile = $_.FullName
        Get-ChildItem -LiteralPath $_.DirectoryName -Filter '*.json' -File |
            Where-Object { Test-Path -LiteralPath ([IO.Path]::ChangeExtension($_.FullName, '.bicep')) } |
            ForEach-Object {
                @{
                    Name = $_.FullName.Substring($repoRoot.Length + 1)
                    TemplateFile = $_.FullName
                    FormFile = $formFile
                }
            }
    })

Describe 'Generated ARM and Template Spec size budgets' {
    It 'discovers published template and form pairs' {
        ($sizeCases.Count -gt 0) | Should Be $true
    }

    It 'keeps <Name> within conservative offline size budgets' -TestCases $sizeCases {
        param($Name, $TemplateFile, $FormFile)

        $armBytes = (Get-Item -LiteralPath $TemplateFile).Length
        if ($armBytes -gt 4000000) {
            throw "$Name is $armBytes bytes, exceeding the conservative 4,000,000-byte ARM file budget."
        }
        $payload = @{
            location = 'usgovvirginia'
            properties = @{
                mainTemplate = Get-Content -LiteralPath $TemplateFile -Raw | ConvertFrom-Json
                uiFormDefinition = Get-Content -LiteralPath $FormFile -Raw | ConvertFrom-Json
            }
        }
        $json = $payload | ConvertTo-Json -Depth 100 -Compress -WarningAction Stop
        $payloadBytes = [Text.Encoding]::UTF8.GetByteCount($json)
        if ($payloadBytes -gt 2000000) {
            throw "$Name and its Portal form serialize to $payloadBytes bytes, exceeding the conservative 2,000,000-byte Template Spec payload budget."
        }
    }

    It 'keeps extended examples out of emitted <Name> parameter descriptions' -TestCases $sizeCases {
        param($Name, $TemplateFile, $FormFile)

        $template = Get-Content -LiteralPath $TemplateFile -Raw | ConvertFrom-Json
        foreach ($parameter in $template.parameters.PSObject.Properties) {
            if ($parameter.Value.metadata.description -match '(?im)^\s*(?:JSON\s+)?example:\s*$') {
                throw "$Name parameter $($parameter.Name) embeds an extended example; keep it in Bicep source comments instead."
            }
        }
    }
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
