$repoRoot = Split-Path -Parent $PSScriptRoot

$formCases = @(
    @{
        Name = 'standard host pool'
        Path = Join-Path $repoRoot 'deployments\hostpools\uiFormDefinition.json'
    }
    @{
        Name = 'session hosts add-on'
        Path = Join-Path $repoRoot 'deployments\add-ons\sessionHosts\uiFormDefinition.json'
    }
    @{
        Name = 'session host replacer add-on'
        Path = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\uiFormDefinition.json'
    }
)

Describe 'Host-pool availability-zone controls' {
    foreach ($formCase in $formCases) {
        Context $formCase.Name {
            BeforeAll {
                $form = Get-Content -LiteralPath $formCase.Path -Raw | ConvertFrom-Json
                $hostsStep = $form.view.properties.steps | Where-Object { $_.name -eq 'hosts' }
                $resourceSkusApi = $hostsStep.elements | Where-Object { $_.name -eq 'resourceSkusApi' }
                $specs = $hostsStep.elements | Where-Object { $_.name -eq 'specs' }
                $genericSize = $specs.elements | Where-Object { $_.name -eq 'sizeGeneric' }
                $availability = $hostsStep.elements | Where-Object { $_.name -eq 'availability' }
                $availabilityOption = $availability.elements | Where-Object { $_.name -eq 'availability' }
                $availabilityZones = $availability.elements | Where-Object { $_.name -eq 'availabilityZones' }
            }

            It 'projects advertised and restricted zones from the SKU API' {
                $availabilityZones.constraints.allowedValues | Should Match 'resourceSkusApi\.value'
                $availabilityZones.constraints.allowedValues | Should Match 'locationInfo'
                $availabilityZones.constraints.allowedValues | Should Match "restriction\.type, 'Zone'"
                $availabilityZones.constraints.allowedValues | Should Not Match 'transformed\.'
            }

            It 'keeps availability options populated and filters restricted zone choices' {
                $availabilityOption.constraints.allowedValues | Should Match 'resourceSkusApi\.value'
                $availabilityOption.constraints.allowedValues | Should Match "restriction\.type, 'Zone'"
                $availabilityOption.defaultValue | Should Match "restriction\.type, 'Zone'"
                $availabilityZones.constraints.allowedValues | Should Match "(sku\.restrictedZones|restriction\.type, 'Zone')"
                $availabilityZones.defaultValue | Should Match "(sku\.restrictedZones|restriction\.type, 'Zone')"
            }

            It 'uses an API-backed searchable VM-size dropdown' {
                $genericSize.type | Should Be 'Microsoft.Common.DropDown'
                $genericSize.filter | Should Be $true
                $genericSize.constraints.allowedValues | Should Match "resourceSkusApi\.transformed\.(genericVMSizes|vmSizes)"
                ($resourceSkusApi.request.transforms.PSObject.Properties.Value -join "`n") | Should Match 'description:join'
                (Get-Content -LiteralPath $formCase.Path -Raw) | Should Not Match 'Microsoft\.Compute\.SizeSelector'
            }

            It 'preserves the availabilityZones deployment output' {
                $form.view.outputs.parameters.availabilityZones | Should Match 'availabilityZones'
                $form.view.outputs.parameters.virtualMachineSize | Should Match 'sizeGeneric'
            }
        }
    }
}