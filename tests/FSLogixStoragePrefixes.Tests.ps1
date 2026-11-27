BeforeDiscovery {
    $prefixCases = @(
        @{ Name = 'standard'; Directory = 'deployments\hostpools'; TemplateName = 'hostpool' }
        @{ Name = 'automated'; Directory = 'deployments\automatedHostPools'; TemplateName = 'automatedHostPool' }
    )
}

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'NamingTestHelpers.ps1')
}

Describe 'Independent FSLogix storage prefixes' {
    Context '<Name> host pool' -ForEach $prefixCases {
        BeforeAll {
            $directoryPath = Join-Path $repoRoot $Directory
            $source = Get-Content (Join-Path $directoryPath "$TemplateName.bicep") -Raw
            $template = Get-Content (Join-Path $directoryPath "$TemplateName.json") -Raw | ConvertFrom-Json -Depth 100
            $form = Get-Content (Join-Path $directoryPath 'uiFormDefinition.json') -Raw | ConvertFrom-Json -Depth 100
            $controls = @($form.view.properties.steps | ForEach-Object { Get-TestFormElement $_.elements })
            $profile = $controls | Where-Object name -EQ 'fslogixStoragePrefixValue'
            $office = $controls | Where-Object name -EQ 'fslogixOfficeStoragePrefixValue'
            $bindings = $form.view.outputs.parameters

            function New-PrefixFormSteps {
                param($Deploy = $true, $Backend = 'AzureFiles', $Containers = 'ProfileContainerOfficeContainer', $ProfilePrefix = 'myprofiles', $OfficePrefix = 'myoffice')
                @{
                    tagsAndNaming = @{
                        naming = @{
                            fslogixStoragePrefixValue = $ProfilePrefix
                            fslogixOfficeStoragePrefixValue = $OfficePrefix
                        }
                    }
                    userProfiles = @{
                        deployStorage = $Deploy
                        storageService = $Backend
                        fslogixContainerType = $Containers
                    }
                    profiles = @{
                        deployStorage = $Deploy
                        storage = @{
                            service = $Backend
                            containerType = $Containers
                        }
                    }
                }
            }
        }

        It 'exposes separate, correctly labeled controls and preserves the original Profile control ID' {
            @($profile).Count | Should -Be 1
            @($office).Count | Should -Be 1
            $profile.label | Should -Be 'Custom Profile Storage Prefix'
            $office.label | Should -Be 'Custom Office Storage Prefix'
            $profile.defaultValue | Should -Be ''
            $office.defaultValue | Should -Be ''
            $profile.constraints.regex | Should -Be '^[a-z0-9]{0,13}$'
            $office.constraints.validations[0].regex | Should -Be '^$|^[a-z0-9]{3,13}$'
        }

        It 'returns both explicit prefixes and shows both controls when creating Office containers' {
            $steps = New-PrefixFormSteps
            Invoke-TestNamingFormExpression -Expression $bindings.fslogixProfileStorageAccountNamePrefix -Steps $steps | Should -Be 'myprofiles'
            Invoke-TestNamingFormExpression -Expression $bindings.fslogixOfficeStorageAccountNamePrefix -Steps $steps | Should -Be 'myoffice'
            Invoke-TestNamingFormExpression -Expression $profile.visible -Steps $steps | Should -BeTrue
            Invoke-TestNamingFormExpression -Expression $office.visible -Steps $steps | Should -BeTrue
        }

        It 'retains naming-convention fallback when both controls are blank' {
            $steps = New-PrefixFormSteps -ProfilePrefix '' -OfficePrefix ''
            Invoke-TestNamingFormExpression -Expression $bindings.fslogixProfileStorageAccountNamePrefix -Steps $steps | Should -Be ''
            Invoke-TestNamingFormExpression -Expression $bindings.fslogixOfficeStorageAccountNamePrefix -Steps $steps | Should -Be ''
            $template.parameters.fslogixOfficeStorageAccountNamePrefix.defaultValue | Should -Be ''
            $template.parameters.fslogixOfficeStorageAccountNamePrefix.maxLength | Should -Be 13
            $source | Should -Match "effectiveFslogixOfficeStorageAccountNamePrefix =[\s\S]*?: !empty\(fslogixOfficeStorageAccountNamePrefix\) \? fslogixOfficeStorageAccountNamePrefix : naming\.fslogixOfficeStorageAccountNamePrefix"
        }

        It 'hides Office and resets its output when only Profile containers are selected' {
            $steps = New-PrefixFormSteps -Containers 'ProfileContainer'
            Invoke-TestNamingFormExpression -Expression $office.visible -Steps $steps | Should -BeFalse
            Invoke-TestNamingFormExpression -Expression $bindings.fslogixOfficeStorageAccountNamePrefix -Steps $steps | Should -Be ''
            Invoke-TestNamingFormExpression -Expression $bindings.fslogixProfileStorageAccountNamePrefix -Steps $steps | Should -Be 'myprofiles'
        }

        It 'resets both prefixes and hides controls for existing storage or NetApp' {
            foreach ($steps in @(
                (New-PrefixFormSteps -Deploy $false)
                (New-PrefixFormSteps -Backend 'AzureNetAppFiles')
            )) {
                foreach ($expression in @($profile.visible, $office.visible)) {
                    Invoke-TestNamingFormExpression -Expression $expression -Steps $steps | Should -BeFalse
                }
                foreach ($expression in @($bindings.fslogixProfileStorageAccountNamePrefix, $bindings.fslogixOfficeStorageAccountNamePrefix)) {
                    Invoke-TestNamingFormExpression -Expression $expression -Steps $steps | Should -Be ''
                }
            }
        }

        It 'rejects matching explicit prefixes while allowing separate or blank prefixes' {
            $expression = $office.constraints.validations[1].isValid
            Invoke-TestNamingFormExpression -Expression $expression -Steps (New-PrefixFormSteps -OfficePrefix 'myprofiles') | Should -BeFalse
            Invoke-TestNamingFormExpression -Expression $expression -Steps (New-PrefixFormSteps) | Should -BeTrue
            Invoke-TestNamingFormExpression -Expression $expression -Steps (New-PrefixFormSteps -OfficePrefix '') | Should -BeTrue
            foreach ($invalid in @('ab', 'Office', 'my-office', 'abcdefghijklmn')) {
                ($invalid -cmatch $office.constraints.validations[0].regex) | Should -BeFalse
            }
            foreach ($valid in @('', 'myoffice', 'abcdefghijklm')) {
                ($valid -cmatch $office.constraints.validations[0].regex) | Should -BeTrue
            }
        }

        It 'wires the effective Office prefix into storage creation while preserving CMK naming' {
            $source | Should -Match 'officeStorageAccountNamePrefix: effectiveFslogixOfficeStorageAccountNamePrefix'
            $source | Should -Match 'officeEncryptionKeyNameConv: naming.encryptionKeyNameFSLogixOffice'
            foreach ($binding in $bindings.PSObject.Properties) {
                $template.parameters.PSObject.Properties.Name | Should -Contain $binding.Name
            }
        }
    }

    It 'uses the overridden Office prefix in standard host-pool account IDs and lifecycle tags' {
        $source = Get-Content (Join-Path $repoRoot 'deployments\hostpools\hostpool.bicep') -Raw
        foreach ($name in @('existingFslogixOfficeAccountIds', 'fslLocalOfficeStorageAccountNames')) {
            $block = [regex]::Match($source, '(?ms)^var ' + $name + ' = .*?(?=^var |\z)').Value
            $block | Should -Match 'effectiveFslogixOfficeStorageAccountNamePrefix'
            $block | Should -Not -Match 'naming\.fslogixOfficeStorageAccountNamePrefix'
        }
    }

    It 'retains the shared case-insensitive collision guard for both resolved prefixes' {
        $source = Get-Content (Join-Path $repoRoot 'deployments\shared\modules\orchestration\fslogix\modules\azureFiles.bicep') -Raw
        $source | Should -Match 'toLower\(officeStorageAccountNamePrefix\) != toLower\(profileStorageAccountNamePrefix\)'
        $source | Should -Match "fail\('Profile and Office Azure Files storage account prefixes must differ\.'\)"
    }
}
