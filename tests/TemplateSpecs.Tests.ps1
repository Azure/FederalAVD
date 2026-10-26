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

Import-Module Az.Resources -ErrorAction Stop
$functionDefinitions = $scriptAst.FindAll(
    { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },
    $true
)
foreach ($functionDefinition in $functionDefinitions) {
    Invoke-Expression $functionDefinition.Extent.Text
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
        $package = New-DeduplicatedTemplateSpecPackage -TemplateFile $TemplateFile -FormFile $FormFile -Location 'usgovvirginia'
        $payloadBytes = $package.PayloadBytes
        if ($payloadBytes + 16384 -gt 2000000) {
            throw "$Name and its Portal form serialize to $payloadBytes bytes using the normal SDK serializer, exceeding the 2,000,000-byte budget including a 16,384-byte metadata allowance."
        }
    }

    It 'preserves all non-annotation content in <Name>' -TestCases $sizeCases {
        param($Name, $TemplateFile, $FormFile)

        $original = [Microsoft.Azure.Commands.ResourceManager.Cmdlets.Components.TemplateSpecPackagingEngine]::Pack($TemplateFile)
        $package = [pscustomobject]@{
            RootTemplate = $original.RootTemplate.DeepClone()
            UIFormDefinition = [Newtonsoft.Json.Linq.JObject]::Parse((Get-Content -LiteralPath $FormFile -Raw))
        }
        Remove-TemplateSpecInternalAnnotations -Node $package.RootTemplate
        $restored = $package.RootTemplate.DeepClone()
        foreach ($metadata in @($original.RootTemplate.SelectTokens('$..metadata'))) {
            $published = $restored.SelectToken($metadata.get_Path())
            if ($metadata -isnot [Newtonsoft.Json.Linq.JObject]) {
                [Newtonsoft.Json.Linq.JToken]::DeepEquals($metadata, $published) | Should Be $true
                continue
            }
            foreach ($property in $metadata.Properties()) {
                if ($null -eq $published -or $null -eq $published[$property.Name]) {
                    ($property.Name -in @('description', '_generator', '__bicep_imported_from!')) | Should Be $true
                }
                else {
                    [Newtonsoft.Json.Linq.JToken]::DeepEquals($property.Value, $published[$property.Name]) | Should Be $true
                }
            }
            $parent = $restored.SelectToken($metadata.get_Parent().get_Parent().get_Path())
            $parent['metadata'] = $metadata.DeepClone()
        }
        [Newtonsoft.Json.Linq.JToken]::DeepEquals($original.RootTemplate, $restored) | Should Be $true
        foreach ($interfaceName in @('parameters', 'outputs', 'definitions')) {
            if ($null -eq $original.RootTemplate[$interfaceName]) {
                continue
            }
            foreach ($metadata in @($original.RootTemplate[$interfaceName].SelectTokens('$..metadata'))) {
                if ($null -ne $metadata['description']) {
                    [string]$package.RootTemplate.SelectToken($metadata.get_Path())['description'] |
                        Should Be ([string]$metadata['description'])
                }
            }
        }
        $expectedForm = [Newtonsoft.Json.Linq.JObject]::Parse((Get-Content -LiteralPath $FormFile -Raw))
        [Newtonsoft.Json.Linq.JToken]::DeepEquals($expectedForm, $package.UIFormDefinition) | Should Be $true
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

    It 'filters annotations idempotently without changing the source of <Name>' -TestCases $sizeCases {
        param($Name, $TemplateFile, $FormFile)

        $templateHash = (Get-FileHash -LiteralPath $TemplateFile).Hash
        $formHash = (Get-FileHash -LiteralPath $FormFile).Hash
        $package = New-DeduplicatedTemplateSpecPackage -TemplateFile $TemplateFile -FormFile $FormFile -Location 'usgovvirginia'
        $before = $package.RootTemplate.DeepClone()
        Remove-TemplateSpecInternalAnnotations -Node $package.RootTemplate
        [Newtonsoft.Json.Linq.JToken]::DeepEquals($before, $package.RootTemplate) | Should Be $true
        foreach ($artifact in $package.Artifacts) {
            $before = $artifact.Template.DeepClone()
            Remove-TemplateSpecInternalAnnotations -Node $artifact.Template
            [Newtonsoft.Json.Linq.JToken]::DeepEquals($before, $artifact.Template) | Should Be $true
        }
        [Text.Encoding]::UTF8.GetByteCount((Get-DeduplicatedTemplateSpecPayload -Package $package -Location 'usgovvirginia')) |
            Should Be $package.PayloadBytes
        (Get-FileHash -LiteralPath $TemplateFile).Hash | Should Be $templateHash
        (Get-FileHash -LiteralPath $FormFile).Hash | Should Be $formHash
    }
}

Describe 'Template Spec annotation filtering boundaries' {
    It 'retains module summaries, public help, validation, security metadata, and arbitrary data' {
        $template = [Newtonsoft.Json.Linq.JObject]::Parse(@'
{
  "$schema": "https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#",
  "metadata": {"_generator": {"name": "bicep"}, "name": "Root", "description": "Root purpose"},
  "parameters": {
    "input": {
      "type": "object",
      "metadata": {"description": "Public help", "strongType": "location"},
      "defaultValue": {"metadata": {"description": "Literal data", "_generator": "Keep"}}
    }
  },
  "resources": {
    "nested": {
      "type": "Microsoft.Resources/deployments",
      "apiVersion": "2022-09-01",
      "metadata": {"description": "Resource metadata", "_generator": "Not compiler metadata"},
      "properties": {
        "template": {
          "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
          "metadata": {"_generator": {"name": "bicep"}, "name": "Nested", "description": "Nested purpose"},
          "parameters": {
            "secret": {"type": "secureString", "minLength": 1, "metadata": {"description": "Internal help", "custom": "Keep"}},
            "choice": {"type": "object", "allowedValues": [{"metadata": {"description": "Literal allowed value"}}]}
          },
          "definitions": {
            "input": {
              "type": "object",
              "metadata": {"description": "Type help", "__bicep_imported_from!": {"source": "types.bicep"}},
              "properties": {"child": {"type": "string", "metadata": {"description": "Child help"}, "minLength": 2}},
              "additionalProperties": false
            }
          },
          "outputs": {"result": {"type": "string", "value": "[parameters('secret')]", "metadata": {"description": "Output help"}}},
          "resources": {
            "policy": {
              "type": "Microsoft.Authorization/policyDefinitions",
              "properties": {"metadata": {"description": "Policy help", "category": "Keep"}}
            }
          }
        }
      }
    }
  }
}
'@)
        $before = $template.DeepClone()
        Remove-TemplateSpecInternalAnnotations -Node $template
        [string]$template['metadata']['description'] | Should Be 'Root purpose'
        [string]$template['metadata']['name'] | Should Be 'Root'
        ($null -eq $template['metadata']['_generator']) | Should Be $true
        [Newtonsoft.Json.Linq.JToken]::DeepEquals($before['parameters'], $template['parameters']) | Should Be $true
        $nested = $template['resources']['nested']['properties']['template']
        [string]$nested['metadata']['description'] | Should Be 'Nested purpose'
        [string]$nested['metadata']['name'] | Should Be 'Nested'
        ($null -eq $nested['metadata']['_generator']) | Should Be $true
        [string]$nested['parameters']['secret']['type'] | Should Be 'secureString'
        [int]$nested['parameters']['secret']['minLength'] | Should Be 1
        [string]$nested['parameters']['secret']['metadata']['custom'] | Should Be 'Keep'
        ($null -eq $nested['parameters']['secret']['metadata']['description']) | Should Be $true
        ($null -eq $nested['definitions']['input']['metadata']) | Should Be $true
        ($null -eq $nested['definitions']['input']['properties']['child']['metadata']) | Should Be $true
        [int]$nested['definitions']['input']['properties']['child']['minLength'] | Should Be 2
        [string]$nested['parameters']['choice']['allowedValues'][0]['metadata']['description'] | Should Be 'Literal allowed value'
        [string]$nested['outputs']['result']['value'] | Should Be "[parameters('secret')]"
        ($null -eq $nested['outputs']['result']['metadata']) | Should Be $true
        [Newtonsoft.Json.Linq.JToken]::DeepEquals(
            $before['resources']['nested']['metadata'], $template['resources']['nested']['metadata']
        ) | Should Be $true
        [Newtonsoft.Json.Linq.JToken]::DeepEquals(
            $before['resources']['nested']['properties']['template']['resources'], $nested['resources']
        ) | Should Be $true
    }

    It 'rejects pre-existing relative links instead of publishing an incomplete package' {
        $source = Join-Path $TestDrive 'linked-source'
        New-Item -ItemType Directory -Path $source | Out-Null
        @'
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "resources": [{
    "type": "Microsoft.Resources/deployments",
    "apiVersion": "2022-09-01",
    "name": "linked",
    "properties": {"mode": "Incremental", "templateLink": {"relativePath": "child.json"}}
  }]
}
'@ | Set-Content -LiteralPath (Join-Path $source 'main.json')
        @'
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "metadata": {"_generator": {"name": "bicep"}, "name": "Linked", "description": "Linked purpose"},
  "parameters": {"input": {"type": "string", "metadata": {"description": "Linked public help"}}},
  "resources": []
}
'@ | Set-Content -LiteralPath (Join-Path $source 'child.json')
        '{}' | Set-Content -LiteralPath (Join-Path $source 'form.json')
        {
            New-DeduplicatedTemplateSpecPackage -TemplateFile (Join-Path $source 'main.json') -FormFile (Join-Path $source 'form.json') -Location 'usgovvirginia'
        } | Should Throw 'Pre-existing relativePath template links are not supported'
    }

    It 'reduces the host-pool request using the normal SDK serializer' {
        $templateFile = Join-Path $repoRoot 'deployments\hostpools\hostpool.json'
        $formFile = Join-Path $repoRoot 'deployments\hostpools\uiFormDefinition.json'
        $original = [Microsoft.Azure.Commands.ResourceManager.Cmdlets.Components.TemplateSpecPackagingEngine]::Pack($templateFile)
        $original.UIFormDefinition = [Newtonsoft.Json.Linq.JObject]::Parse((Get-Content -LiteralPath $formFile -Raw))
        $filtered = New-DeduplicatedTemplateSpecPackage -TemplateFile $templateFile -FormFile $formFile -Location 'usgovvirginia'
        $filteredBytes = $filtered.PayloadBytes
        $filtered.OriginalPayloadBytes | Should BeGreaterThan $filteredBytes
        $filteredBytes | Should BeLessThan 1900000
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
