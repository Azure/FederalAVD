BeforeDiscovery {
    $consumerCases = @(
        @{ Name = 'standard host pool'; Source = 'deployments\hostpools\hostpool.bicep'; Form = 'deployments\hostpools\uiFormDefinition.json' }
        @{ Name = 'standalone storage'; Source = 'deployments\add-ons\fslogixStorage\main.bicep'; Form = 'deployments\add-ons\fslogixStorage\uiFormDefinition.json' }
    )
}

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    function Get-OfficeFormElements {
        param($Elements)
        foreach ($element in $Elements) {
            $element
            if ($element.elements) {
                Get-OfficeFormElements $element.elements
            }
        }
    }
}

Describe 'Standard FSLogix Office consumer contracts' {
    Context '<Name>' -ForEach $consumerCases {
        BeforeAll {
            $sourceText = Get-Content (Join-Path $repoRoot $Source) -Raw
            $formObject = Get-Content (Join-Path $repoRoot $Form) -Raw | ConvertFrom-Json
            $allElements = @($formObject.view.properties.steps | ForEach-Object { Get-OfficeFormElements $_.elements })
            $officeElements = @($allElements | Where-Object name -Match 'office|Office')
            $parameters = $formObject.view.outputs.parameters
        }

        It 'retains public Profile names and adds inheritable Office settings' {
            $sourceText | Should -Match "param fslogixProfileStorageRedundancy string = 'LocallyRedundant'"
            $sourceText | Should -Match "param fslogixOfficeStorageTier string = 'Inherit'"
            $sourceText | Should -Match "param fslogixOfficeStorageRedundancy string = 'Inherit'"
            $sourceText | Should -Match '@minValue\(0\)\s+@maxValue\(262144\)[\s\S]*?param fslogixOfficeShareSizeInGB int = 0'
            $sourceText | Should -Match "fslogixOfficeStorageTier == 'Inherit'"
            $sourceText | Should -Match "fslogixOfficeStorageRedundancy == 'Inherit'"
            $sourceText | Should -Match 'fslogixOfficeShareSizeInGB == 0'
        }

        It 'passes separate naming, CMK, tier, redundancy and quota contracts' {
            foreach ($contract in @('officeStorageAccountNamePrefix', 'officeEncryptionKeyNameConv', 'officeStorageTier', 'officeStorageRedundancy', 'officeShareSizeInGB')) {
                $sourceText | Should -Match ('(?m)^\s+' + $contract + ':')
            }
            $sourceText | Should -Match 'naming\.fslogixOfficeStorageAccountNamePrefix'
            $sourceText | Should -Match 'naming\.encryptionKeyNameFSLogixOffice'
            $sourceText | Should -Match 'storageKeyNames: concat\('
            $sourceText | Should -Match 'outputs\.officeStorageAccountResourceIds'
        }

        It 'binds every Office form output to a declared public parameter' {
            foreach ($binding in $parameters.PSObject.Properties | Where-Object Name -Match 'Office|office') {
                $sourceText | Should -Match ('(?m)^param ' + [regex]::Escape($binding.Name) + ' ')
                $binding.Value | Should -Match "OfficeContainer"
            }
            $parameters.fslogixOfficeStorageTier | Should -Match "'Inherit'"
            $parameters.fslogixOfficeStorageRedundancy | Should -Match "'Inherit'"
            $parameters.fslogixOfficeShareSizeInGB | Should -Match ', 0\)\]'
        }

        It 'uses supported controls with display-label dropdown defaults' {
            foreach ($element in $officeElements) {
                $element.type | Should -BeIn @('Microsoft.Common.DropDown', 'Microsoft.Common.TextBox', 'Microsoft.Common.TextBlock', 'Microsoft.Common.Slider')
                if ($element.type -eq 'Microsoft.Common.DropDown' -and $element.constraints.allowedValues -is [array]) {
                    $element.defaultValue | Should -BeIn $element.constraints.allowedValues.label
                }
                if ($element.type -eq 'Microsoft.Common.TextBlock') {
                    $element.options.text | Should -Not -Match '^\['
                }
            }
            $guidance = $officeElements | Where-Object name -EQ 'officeStorageGuidance'
            $guidance.options.text | Should -Match 'fslpc and fsloc'
        }

        It 'blocks mismatched or overlapping existing remote role arrays in the form and deployment' {
            $validation = $allElements | Where-Object name -EQ 'remoteOfficePairingValidation'
            $validation.readOnly | Should -BeTrue
            $validation.constraints.validations[0].isValid | Should -Match 'equals\(length\('
            $validation.constraints.validations[0].isValid | Should -Match 'toLower'
            $validation.constraints.validations[0].isValid | Should -Match 'empty\(filter\('
            $sourceText | Should -Match 'intersection\('
            $sourceText | Should -Match "fail\('[^']*(Office|office)[^']*(paired|pair|one-for-one)"
        }

        It 'keeps new form expressions balanced and resets hidden Office outputs' {
            $expressions = @(
                $officeElements | ForEach-Object {
                    $_.visible
                    $_.constraints.allowedValues
                    $_.constraints.required
                    $_.constraints.validations.isValid
                }
                $parameters.PSObject.Properties | Where-Object Name -Match 'Office|office' | ForEach-Object Value
            )
            foreach ($expression in $expressions | Where-Object { $_ -is [string] -and $_.StartsWith('[') }) {
                $withoutLiterals = [regex]::Replace($expression, "'(?:''|[^'])*'", '')
                $balance = 0
                foreach ($character in $withoutLiterals.ToCharArray()) {
                    if ($character -eq '(') { $balance++ }
                    if ($character -eq ')') { $balance-- }
                    $balance | Should -BeGreaterOrEqual 0
                }
                $balance | Should -Be 0
                $expression | Should -Match '\]$'
            }
            foreach ($binding in $parameters.PSObject.Properties | Where-Object Name -Match 'Office.*ResourceIds') {
                $binding.Value | Should -Match "parse\('\[\]'\)"
            }
        }
    }

    It 'forwards explicit standard-host Office arrays without falling back to Profile IDs' {
        $sourceText = Get-Content (Join-Path $repoRoot 'deployments\hostpools\hostpool.bicep') -Raw
        $sourceText | Should -Match 'param fslogixExistingLocalOfficeStorageAccountResourceIds string\[\] = \[\]'
        $sourceText | Should -Match 'param fslogixExistingRemoteOfficeStorageAccountResourceIds string\[\] = \[\]'
        $sourceText | Should -Match 'fslogixLocalOfficeStorageAccountResourceIds: deployFSLogixStorage\s+\? fslogix!\.outputs\.officeStorageAccountResourceIds\s+: effectiveFslogixExistingLocalOfficeStorageAccountResourceIds'
        $sourceText | Should -Match 'fslogixRemoteOfficeStorageAccountResourceIds: effectiveFslogixExistingRemoteOfficeStorageAccountResourceIds'
        $sourceText | Should -Match 'fslogixExistingNetAppConfigurationIsValid && fslogixExistingOfficeStorageConfigurationIsValid'
    }

    It 'emits paired local and remote Office name tags alongside Profile tags on the hosts resource group' {
        $sourceText = Get-Content (Join-Path $repoRoot 'deployments\hostpools\hostpool.bicep') -Raw
        $tagBlocks = @{}
        foreach ($tagName in @('fslLocalProfileStorageAccountNames', 'fslRemoteProfileStorageAccountNames', 'fslLocalOfficeStorageAccountNames', 'fslRemoteOfficeStorageAccountNames')) {
            $tagBlocks[$tagName] = [regex]::Match($sourceText, '(?ms)^var ' + $tagName + ' = .*?(?=^var |\z)').Value
            $tagBlocks[$tagName] | Should -Match ($tagName + ': string\(map\(')
            $tagBlocks[$tagName] | Should -Not -Match '\b(sort|union|filter)\('
        }
        foreach ($tagName in @('fslLocalProfileStorageAccountNames', 'fslLocalOfficeStorageAccountNames')) {
            $tagBlocks[$tagName] | Should -Match 'range\(0, fslogixStorageCount\)'
            $tagBlocks[$tagName] | Should -Match "padLeft\(i \+ fslogixStorageIndex, 2, '0'\)"
        }
        $tagBlocks.fslLocalProfileStorageAccountNames | Should -Match 'effectiveFslogixProfileStorageAccountNamePrefix'
        $tagBlocks.fslLocalOfficeStorageAccountNames | Should -Match 'naming\.fslogixOfficeStorageAccountNamePrefix'
        $tagBlocks.fslLocalOfficeStorageAccountNames | Should -Match "map\(effectiveFslogixExistingLocalOfficeStorageAccountResourceIds, id => last\(split\(id, '/'\)\)\)"
        $tagBlocks.fslRemoteOfficeStorageAccountNames | Should -Match "map\(effectiveFslogixExistingRemoteOfficeStorageAccountResourceIds, id => last\(split\(id, '/'\)\)\)"
        $tagBlocks.fslLocalOfficeStorageAccountNames | Should -Match "fslogixOfficeEnabled && startsWith\(fslogixStorageService, 'AzureFiles'\)"
        $tagBlocks.fslRemoteOfficeStorageAccountNames | Should -Match 'fslogixOfficeEnabled && !empty\(effectiveFslogixExistingRemoteOfficeStorageAccountResourceIds\)'
        $configurationTags = [regex]::Match($sourceText, '(?ms)^var fslogixConfigurationTags = .*?(?=^var |\z)').Value
        foreach ($tagName in $tagBlocks.Keys) {
            $configurationTags | Should -Match ('(?m)^\s+' + $tagName + ',')
        }
        $sourceText | Should -Match "(?s)module hostsResourceGroup .*?tags: union\(tags\[\?'Microsoft.Resources/resourceGroups'\] \?\? \{\}, vmConfigurationTags, fslogixConfigurationTags,"
    }

    It 'keeps the disposable PoC Profile-only while accepting the shared naming contract' {
        $sourceText = Get-Content (Join-Path $repoRoot 'deployments\hostpoolPoc\hostpoolPoc.bicep') -Raw
        $sourceText | Should -Match "fslogixContainerType: 'ProfileContainer'"
        $sourceText | Should -Not -Match 'param fslogixOffice'
        $sourceText | Should -Match 'officeStorageAccountNamePrefix: naming\.fslogixOfficeStorageAccountNamePrefix'
        $sourceText | Should -Match 'fslogixLocalOfficeStorageAccountResourceIds: \[\]'
        $sourceText | Should -Match 'fslogixRemoteOfficeStorageAccountResourceIds: \[\]'
    }

    It 'exposes both role arrays in standalone configuration and validates distinct overrides' {
        $sourceText = Get-Content (Join-Path $repoRoot 'deployments\add-ons\fslogixStorage\main.bicep') -Raw
        $sourceText | Should -Match 'localOfficeStorageAccountResourceIds: fslogix\.outputs\.officeStorageAccountResourceIds'
        $sourceText | Should -Match 'remoteOfficeStorageAccountResourceIds: remoteOfficeStorageAccountConfigurationIsValid'
        $sourceText | Should -Match 'officeStorageAccountPrefixesAreDistinct'
        $sourceText | Should -Match 'toLower\(effectiveProfileStorageAccountNamePrefix\) != toLower\(effectiveOfficeStorageAccountNamePrefix\)'
        $sourceText | Should -Match 'length\(effectiveOfficeStorageAccountNamePrefix\) >= 3'
        $sourceText | Should -Match 'storageCount: remoteStorageAccountConfigurationIsValid && remoteOfficeStorageAccountConfigurationIsValid'
    }

    It 'previews fslpc and fsloc generated defaults without restricting valid explicit prefixes' {
        $form = Get-Content (Join-Path $repoRoot 'deployments\add-ons\fslogixStorage\uiFormDefinition.json') -Raw | ConvertFrom-Json
        $elements = @($form.view.properties.steps | ForEach-Object { Get-OfficeFormElements $_.elements })
        $profilePrefix = $elements | Where-Object name -EQ 'storageAccountNamePrefixOverride'
        $officePrefix = $elements | Where-Object name -EQ 'officeStorageAccountNamePrefixOverride'
        $profilePrefix.placeholder | Should -Be 'fslpc{unique}'
        $officePrefix.placeholder | Should -Be 'fsloc{unique}'
        $profilePrefix.toolTip | Should -Match 'generated fslpc prefix'
        $officePrefix.toolTip | Should -Match 'generated fsloc prefix'
        'pc' | Should -Match $profilePrefix.constraints.regex
        'oc001' | Should -Match $officePrefix.constraints.validations[0].regex
    }

    It 'keeps the separated-storage example aligned with public parameters and secure networking' {
        $sourceText = Get-Content (Join-Path $repoRoot 'deployments\add-ons\fslogixStorage\main.bicep') -Raw
        $example = Get-Content (Join-Path $repoRoot 'customer-examples\parameters\add-ons\fslogixStorage-office.parameters.json') -Raw | ConvertFrom-Json
        foreach ($parameter in $example.parameters.PSObject.Properties) {
            $sourceText | Should -Match ('(?m)^param ' + [regex]::Escape($parameter.Name) + ' ')
        }
        $example.parameters.fslogixContainerType.value | Should -Be 'ProfileOfficeContainer'
        $example.parameters.privateEndpoint.value | Should -BeTrue
        $example.parameters.paasPublicNetworkAccess.value | Should -Be 'Disabled'
    }
}
