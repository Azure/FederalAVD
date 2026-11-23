BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $entrySource = Get-Content (Join-Path $repoRoot 'deployments\automatedHostPools\automatedHostPool.bicep') -Raw
    $policySource = Get-Content (Join-Path $repoRoot 'deployments\automatedHostPools\policy\main.bicep') -Raw
    $definitionSource = Get-Content (Join-Path $repoRoot 'deployments\shared\modules\orchestration\sessionHostPolicy\modules\configureSessionHost.policyDefinition.bicep') -Raw
    $remediationSource = Get-Content (Join-Path $repoRoot 'deployments\shared\modules\orchestration\sessionHostPolicy\modules\templates\RunCommand\ConfigureSessionHost.bicep') -Raw
    $form = Get-Content (Join-Path $repoRoot 'deployments\automatedHostPools\uiFormDefinition.json') -Raw | ConvertFrom-Json
    $scriptPath = Join-Path $repoRoot 'deployments\automatedHostPools\scripts\Initialize-SessionHost.ps1'
    $scriptSource = Get-Content $scriptPath -Raw
    $tokens = $null
    $parseErrors = $null
    $scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
    foreach ($functionName in @('Assert-FSLogixAzureFilesAccounts', 'ConvertFrom-JsonString')) {
        $functionAst = $scriptAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
        }, $true)
        Invoke-Expression $functionAst.Extent.Text
    }
    function Write-Log { param($Message, $Category) }
    $storageSwitch = $scriptAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.SwitchStatementAst] -and $node.Condition.Extent.Text -eq '$StorageService'
    }, $true).Extent.Text
    $pathRouting = $scriptAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.IfStatementAst] -and $node.Extent.Text -match '^If \(\$OSSGroupsArray.Count -gt 0\)'
    }, $true).Extent.Text
    $profiles = $form.view.properties.steps | Where-Object name -eq 'profiles'
    $storageControls = ($profiles.elements | Where-Object name -eq 'storage').elements
    $existingControls = ($profiles.elements | Where-Object name -eq 'existingStorage').elements
}

Describe 'Automated FSLogix Office contract' {
    It 'preserves inheritance defaults and forwards the independent Office storage settings' {
        $entrySource | Should -Match "param fslogixOfficeStorageTier string = 'Inherit'"
        $entrySource | Should -Match "param fslogixOfficeStorageRedundancy string = 'Inherit'"
        $entrySource | Should -Match 'param fslogixOfficeShareSizeInGB int = 0'
        foreach ($parameter in @('officeStorageAccountNamePrefix', 'officeEncryptionKeyNameConv', 'officeStorageSku', 'officeStorageRedundancy', 'officeShareSizeInGB')) {
            $entrySource | Should -Match "$parameter`: "
        }
        $entrySource | Should -Match 'output fslogixOfficeStorageAccountResourceIds array'
        $entrySource | Should -Match 'storageKeyNames: concat\('
        $entrySource | Should -Match 'naming\.encryptionKeyNameFSLogixOffice'
    }

    It 'maps both Office roles from entry configuration through assignment and policy to remediation' {
        foreach ($role in @('Local', 'Remote')) {
            $entrySource | Should -Match "param fslogixExisting${role}OfficeStorageAccountResourceIds string\[\] = \[\]"
            $entrySource | Should -Match "${role}OfficeStorageAccountResourceIds: fslogixExisting${role}OfficeStorageAccountResourceIds"
            $policySource | Should -Match "fslogix${role}OfficeStorageAccountResourceIds: \{"
            $definitionSource | Should -Match "fslogix${role}OfficeStorageAccountResourceIds: \{"
            $definitionSource | Should -Match "value: '\[parameters\(\\'fslogix${role}OfficeStorageAccountResourceIds\\'\)\]'"
            $remediationSource | Should -Match "param fslogix${role}OfficeStorageAccountResourceIds array = \[\]"
            $remediationSource | Should -Match "name: '${role}OfficeStorageAccountNames'"
            $form.view.outputs.parameters.PSObject.Properties.Name | Should -Contain "fslogixExisting${role}OfficeStorageAccountResourceIds"
        }
        $entrySource | Should -Match 'localOfficeStorageAccountResourceIds: fslogixStorage!\.outputs\.officeStorageAccountResourceIds'
    }

    It 'keeps role keys protected and account RBAC scoped to storage-key configurations' {
        $protectedSource = $remediationSource.Substring($remediationSource.IndexOf('protectedParameters:'))
        foreach ($role in @('Local', 'Remote')) {
            foreach ($kind in @('', 'Office')) {
                $protectedSource | Should -Match "name: '${role}${kind}StorageAccountKeys'"
            }
        }
        $policySource | Should -Match "storageKeyAccountResourceIds = configureFSLogix && fslogixConfiguration.identitySolution == 'EntraId'"
        $policySource | Should -Match 'storage/storageAccounts/roleAssignment\.bicep'
        $policySource | Should -Match "scope: resourceGroup\(split\(id, '/'\)\[2\], split\(id, '/'\)\[4\]\)"
        $policySource | Should -Match 'policyIdentityStorageKeyOperator'
    }

    It 'persists ordered Profile and Office names together in host resource-group lifecycle tags' {
        foreach ($role in @('Local', 'Remote')) {
            foreach ($kind in @('', 'Office')) {
                $configurationProperty = $role.Substring(0, 1).ToLowerInvariant() + $role.Substring(1) + $kind + 'StorageAccountResourceIds'
                $mapping = "fsl${role}${kind}StorageAccountNames: string(map(fslogixConfiguration.$configurationProperty, id => last(split(id, '/'))))"
                $policySource | Should -Match ([regex]::Escape($mapping))
            }
        }
        $policySource | Should -Match "var fslogixStorageAccountTags = fslogixConfiguration.storageService == 'AzureFiles'"
        $policySource | Should -Match '\}, fslogixStorageAccountTags\)'
        $policySource | Should -Match 'tags: union\(existingSessionHostResourceGroup.tags \?\? \{\}, resourceGroupTags\)'
        $entrySource | Should -Match 'fslogixConfiguration: deployFSLogixStorage \? deployedFslogixConfiguration : existingFslogixConfiguration'
    }

    It 'keeps the named-command compliance lifecycle unchanged' {
        $definitionSource | Should -Match "defaultValue: 'ConfigureSessionHost'"
        $definitionSource | Should -Match "version: '1\.0\.0'"
        $definitionSource | Should -Match "field: 'Microsoft.Compute/virtualMachines/runCommands/provisioningState'\s+equals: 'Succeeded'"
    }

    It 'uses label defaults and Azure Files Office visibility for each new form setting' {
        foreach ($name in @('officeStorageTier', 'officeStorageRedundancy')) {
            $control = $storageControls | Where-Object name -eq $name
            $control.constraints.allowedValues.label | Should -Contain $control.defaultValue
            $control.visible | Should -Match 'AzureFiles'
            $control.visible | Should -Match 'Office'
        }
        ($storageControls | Where-Object name -eq 'officeShareSizeInGB').defaultValue | Should -Be 0
        foreach ($name in @('localOfficeStorageAccounts', 'remoteOfficeStorageAccounts')) {
            $control = $existingControls | Where-Object name -eq $name
            $control.constraints.allowedValues | Should -Match 'localStorageAccounts'
            $control.constraints.allowedValues | Should -Match 'remoteStorageAccounts'
        }
        ($storageControls | Where-Object name -eq 'registerBackup').toolTip | Should -Match 'only newly deployed Profile'
        ($existingControls | Where-Object name -eq 'storageAccountsRequiredTextBlock').options.text | Should -Not -Match '^\['
    }
}

Describe 'Automated FSLogix Azure Files role validation' {
    BeforeEach {
        $configuration = @{
            LocalProfileNames = @('profile01', 'profile02')
            RemoteProfileNames = @('remoteprofile01', 'remoteprofile02')
            LocalOfficeNames = @('office01', 'office02')
            RemoteOfficeNames = @('remoteoffice01', 'remoteoffice02')
            Groups = @('group01', 'group02')
            OfficeEnabled = $true
            UseStorageKeys = $false
            LocalProfileKeys = @()
            RemoteProfileKeys = @()
            LocalOfficeKeys = @()
            RemoteOfficeKeys = @()
        }
    }

    It 'accepts aligned local/remote Office shards and Profile-only configurations' {
        { Assert-FSLogixAzureFilesAccounts @configuration } | Should -Not -Throw
        $configuration.OfficeEnabled = $false
        $configuration.LocalOfficeNames = @()
        $configuration.RemoteOfficeNames = @()
        { Assert-FSLogixAzureFilesAccounts @configuration } | Should -Not -Throw
    }

    It 'rejects missing or unequal Office pairs instead of falling back to Profile storage' {
        $configuration.LocalOfficeNames = @()
        { Assert-FSLogixAzureFilesAccounts @configuration } | Should -Throw '*Office requires*'
        $configuration.LocalOfficeNames = @('office01', 'office02')
        $configuration.RemoteOfficeNames = @('remoteoffice01')
        { Assert-FSLogixAzureFilesAccounts @configuration } | Should -Throw '*Office requires*'
    }

    It 'rejects cross-role overlap case-insensitively and duplicates across locations' {
        $configuration.LocalOfficeNames = @('PROFILE01', 'office02')
        { Assert-FSLogixAzureFilesAccounts @configuration } | Should -Throw '*unique and disjoint*'
        $configuration.LocalOfficeNames = @('office01', 'office02')
        $configuration.RemoteProfileNames = @('profile01', 'remoteprofile02')
        { Assert-FSLogixAzureFilesAccounts @configuration } | Should -Throw '*unique and disjoint*'
    }

    It 'rejects mismatched SID group counts and Office arrays for Profile-only layouts' {
        $configuration.Groups = @('group01')
        { Assert-FSLogixAzureFilesAccounts @configuration } | Should -Throw '*groups must match*'
        $configuration.Groups = @('group01', 'group02')
        $configuration.OfficeEnabled = $false
        { Assert-FSLogixAzureFilesAccounts @configuration } | Should -Throw '*Profile-only*'
    }

    It 'requires an independent Office key for storage-key EntraId' {
        $configuration.UseStorageKeys = $true
        $configuration.Groups = @()
        $configuration.LocalProfileNames = @('profile01')
        $configuration.LocalOfficeNames = @('office01')
        $configuration.RemoteProfileNames = @()
        $configuration.RemoteOfficeNames = @()
        $configuration.LocalProfileKeys = @('test-profile-key')
        { Assert-FSLogixAzureFilesAccounts @configuration } | Should -Throw '*separate key*'
        $configuration.LocalOfficeKeys = @('test-office-key')
        { Assert-FSLogixAzureFilesAccounts @configuration } | Should -Not -Throw
        $configuration.LocalOfficeKeys = @('')
        { Assert-FSLogixAzureFilesAccounts @configuration } | Should -Throw '*cannot be empty*'
    }
}

Describe 'Automated FSLogix role path construction' {
    It 'constructs Office paths exclusively from paired Office arrays at the same shard index' {
        $StorageService = 'AzureFiles'
        $StorageSuffix = 'core.windows.net'
        $IdentitySolution = 'EntraKerberos-CloudOnly'
        $ProfileShareName = 'profile-containers'
        $OfficeShareName = 'office-containers'
        $OSSGroups = '["group01","group02"]'
        $LocalStorageAccountNames = '["profile01","profile02"]'
        $RemoteStorageAccountNames = '["remoteprofile01","remoteprofile02"]'
        $LocalOfficeStorageAccountNames = '["office01","office02"]'
        $RemoteOfficeStorageAccountNames = '["remoteoffice01","remoteoffice02"]'
        $LocalStorageAccountKeys = $RemoteStorageAccountKeys = $LocalOfficeStorageAccountKeys = $RemoteOfficeStorageAccountKeys = '[]'
        foreach ($name in @('LocalProfileContainerPaths', 'LocalCloudCacheProfileContainerPaths', 'LocalOfficeContainerPaths', 'LocalCloudCacheOfficeContainerPaths', 'RemoteProfileContainerPaths', 'RemoteCloudCacheProfileContainerPaths', 'RemoteOfficeContainerPaths', 'RemoteCloudCacheOfficeContainerPaths')) {
            Set-Variable -Name $name -Value ([System.Collections.ArrayList]::new())
        }
        . ([scriptblock]::Create($storageSwitch))
        $LocalProfileContainerPaths[1] | Should -Be '\\profile02.file.core.windows.net\profile-containers'
        $LocalOfficeContainerPaths[1] | Should -Be '\\office02.file.core.windows.net\office-containers'
        $RemoteOfficeContainerPaths[1] | Should -Be '\\remoteoffice02.file.core.windows.net\office-containers'
        $RemoteCloudCacheOfficeContainerPaths[1] | Should -Be 'type=smb,connectionString=\\remoteoffice02.file.core.windows.net\office-containers'
    }

    It 'includes remote ANF providers without depending on Azure account-name arrays' {
        $StorageService = 'AzureNetAppFiles'
        $LocalNetAppServers = '["local-profile.example","local-office.example"]'
        $RemoteNetAppServers = '["remote-profile.example","remote-office.example"]'
        $ProfileShareName = 'profile-containers'
        $OfficeShareName = 'office-containers'
        $OSSGroupsArray = @()
        $RemoteStorageAccountNamesArray = @()
        $CloudCacheBool = $true
        $RegSettings = [System.Collections.ArrayList]::new()
        foreach ($name in @('LocalProfileContainerPaths', 'LocalCloudCacheProfileContainerPaths', 'LocalOfficeContainerPaths', 'LocalCloudCacheOfficeContainerPaths', 'RemoteProfileContainerPaths', 'RemoteCloudCacheProfileContainerPaths', 'RemoteOfficeContainerPaths', 'RemoteCloudCacheOfficeContainerPaths')) {
            Set-Variable -Name $name -Value ([System.Collections.ArrayList]::new())
        }
        . ([scriptblock]::Create($storageSwitch))
        . ([scriptblock]::Create($pathRouting))
        $profileSetting = $RegSettings | Where-Object Path -eq 'HKLM:\SOFTWARE\FSLogix\Profiles'
        $officeSetting = $RegSettings | Where-Object Path -eq 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'
        $profileSetting.Value.Count | Should -Be 2
        $officeSetting.Value.Count | Should -Be 2
        $profileSetting.Value[1] | Should -Be 'type=smb,connectionString=\\remote-profile.example\profile-containers'
        $officeSetting.Value[1] | Should -Be 'type=smb,connectionString=\\remote-office.example\office-containers'
        $pathRouting | Should -Not -Match '\$RemoteStorageAccountNamesArray'
    }

    It 'installs Profile and Office credentials independently in storage-key mode' {
        $scriptSource | Should -Match 'Set-FSLogixStorageCredential -AccountName \$LocalOfficeStorageAccountNamesArray\[0\] -AccountKey \$LocalOfficeStorageAccountKeysArray\[0\]'
        $scriptSource | Should -Match 'Set-FSLogixStorageCredential -AccountName \$RemoteOfficeStorageAccountNamesArray\[0\] -AccountKey \$RemoteOfficeStorageAccountKeysArray\[0\]'
        $scriptSource | Should -Match 'Set-FSLogixStorageCredential -AccountName \$LocalStorageAccountNamesArray\[0\] -AccountKey \$LocalStorageAccountKeysArray\[0\]'
        $scriptSource | Should -Not -Match 'cmdkey'
        $scriptSource | Should -Match 'Set-StorageAccountCredential -TargetName .* -UserName .* -Password \$AccountKey'
        $scriptSource | Should -Match 'throw new Win32Exception'
    }

    It 'keeps location policy scopes and documented MultiString types unchanged' {
        $scriptSource | Should -Match "Name = 'VHDLocations'; Path = 'HKLM:\\SOFTWARE\\FSLogix\\Profiles'; PropertyType = 'MultiString'"
        $scriptSource | Should -Match "Name = 'CCDLocations'; Path = 'HKLM:\\SOFTWARE\\Policies\\FSLogix\\ODFC'; PropertyType = 'MultiString'"
        $scriptSource | Should -Match '\$LocalOfficeStorageAccountKeysArray.Count -gt 0\) \{\s+\$RegSettings.Add.*AccessNetworkAsComputerObject.*Policies\\FSLogix\\ODFC'
    }

    It 'keeps PowerShell syntactically valid and ASCII-only' {
        $parseErrors.Count | Should -Be 0
        $scriptSource | Should -Not -Match '[^\x00-\x7F]'
        @(ConvertFrom-JsonString -JsonString '[]' -Name 'empty').Count | Should -Be 0
    }
}
