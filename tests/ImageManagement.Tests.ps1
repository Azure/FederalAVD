$repoRoot = Split-Path -Parent $PSScriptRoot
$formPath = Join-Path $repoRoot 'deployments\imageManagement\uiFormDefinition.json'
$bicepPath = Join-Path $repoRoot 'deployments\imageManagement\imageManagement.bicep'
$armPath = Join-Path $repoRoot 'deployments\imageManagement\imageManagement.json'
$locationsPath = Join-Path $repoRoot 'deployments\shared\data\locations.json'

Describe 'Image Management storage account prefix' {
    BeforeAll {
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $bicep = Get-Content -LiteralPath $bicepPath -Raw
        $arm = Get-Content -LiteralPath $armPath -Raw
        $tagsStep = $form.view.properties.steps | Where-Object { $_.name -eq 'tagsAndNaming' }
        $namingSection = $tagsStep.elements | Where-Object { $_.name -eq 'naming' }
        $prefix = $namingSection.elements | Where-Object { $_.name -eq 'imageManagementStoragePrefix' }
        $locationError = $namingSection.elements | Where-Object { $_.name -eq 'imageManagementStorageLocationError' }
    }

    It 'accepts one optional shared lowercase alphanumeric prefix up to 5 characters' {
        $prefix.constraints.required | Should Be $false
        $prefix.constraints.regex | Should Be '^[a-z0-9]{0,5}$'
        $prefix.visible | Should Match "deployArtifactsStorageAccount"
        $prefix.visible | Should Match "deployBuildLogsStorageAccount"
        '' | Should Match $prefix.constraints.regex
        'cont1' | Should Match $prefix.constraints.regex
        'cont12' | Should Not Match $prefix.constraints.regex
        'contoso-avd' | Should Not Match $prefix.constraints.regex
        ([regex]::IsMatch('CONTOSO', $prefix.constraints.regex)) | Should Be $false
        ('cont1' + 'imgassets' + 'use2' + 'abcdef').Length | Should Be 24
        $locationError.visible | Should Match 'imageManagementStoragePrefix'
        $locationError.visible | Should Match 'locationAbbreviationOverride'
        $locationError.visible | Should Match 'deployArtifactsStorageAccount'
        $locationError.visible | Should Match 'deployBuildLogsStorageAccount'
        $locationError.options.text | Should Match 'no more than 4 characters'
    }

    It 'fits every built-in location abbreviation within the custom naming budget' {
        $locations = Get-Content -LiteralPath $locationsPath -Raw | ConvertFrom-Json
        $abbreviationLengths = foreach ($cloud in $locations.PSObject.Properties) {
            foreach ($location in $cloud.Value.PSObject.Properties) {
                ([string]$location.Value.abbreviation).Length
            }
        }

        (($abbreviationLengths | Measure-Object -Maximum).Maximum -le 4) | Should Be $true
    }

    It 'maps the form value into the naming convention object' {
        $form.view.outputs.parameters.namingConvention | Should Match 'imageManagementStoragePrefix'
        $form.view.outputs.parameters.namingConvention | Should Match "steps\('tagsAndNaming'\)\.naming\.imageManagementStoragePrefix"
    }

    It 'preserves default names and uses deterministic custom-prefix names' {
        $bicep | Should Match "namingConvention\.\?imageManagementStoragePrefix"
        $bicep | Should Match "must contain no more than 5 lowercase letters or numbers"
        $bicep | Should Match "location abbreviation must contain no more than 4 characters"
        $bicep | Should Match "take\(uniqueString\(subscription\(\)\.subscriptionId, resourceGroupName, location\), 6\)"
        $bicep | Should Match '\$\{effectiveImageManagementStoragePrefix\}imgassets\$\{cnv_loc\}\$\{customPrefixSaUnique\}'
        $bicep | Should Match '\$\{effectiveImageManagementStoragePrefix\}imglogs\$\{cnv_loc\}\$\{customPrefixSaUnique\}'
        $bicep | Should Match "cnv_rtFirst[\s\S]+saRtCode\}imgassets"
        $arm | Should Match 'imageManagementStoragePrefix'
        $arm | Should Match 'imgassets'
        $arm | Should Match 'imglogs'
    }
}
