BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $source = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\shared\modules\orchestration\fslogix\modules\azureFiles.bicep') -Raw
    $templateDirectory = Join-Path ([IO.Path]::GetTempPath()) ('FederalAVD-RunCommandSequencing-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $templateDirectory -ErrorAction Stop | Out-Null
    $templatePath = Join-Path $templateDirectory 'azureFiles.json'
    az bicep build --file (Join-Path $repoRoot 'deployments\shared\modules\orchestration\fslogix\modules\azureFiles.bicep') --outfile $templatePath --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Failed to compile Azure Files orchestration.' }
    $template = Get-Content -LiteralPath $templatePath -Raw | ConvertFrom-Json -Depth 100
    . (Join-Path $PSScriptRoot 'NamingTestHelpers.ps1')
    $accountStages = @{
        storageAccounts = 'storage'
        fileServices = 'files'
        shares = 'share'
        privateEndpoints = 'endpoint'
    }
    $commandStages = @{
        configureADDSAuth = 'domain'
        configureEntraKerberosWithDomainInfo = 'hybrid'
        updateStorageApplicationsManifest = 'manifest'
        SetNTFSPermissions = 'ntfs'
        grantStorageApplicationsConsent = 'consent'
    }
    $nameFunctions = foreach ($module in @($accountStages.Keys) + @($commandStages.Keys)) {
        $expression = [regex]::Match($source, '(?ms)^module ' + $module + '\s.*?\n\s+name: ''([^''\r\n]+)''').Groups[1].Value
        if (-not $expression) { throw "No explicit deployment name found for $module." }
        "func $module(role { roleName: string }, account { roleName: string, name: string }, shardRange string, deploymentNameSuffix string) string => '$expression'"
    }
    $suffixExpression = [regex]::Match($source, '(?m)^var deploymentNameSuffix = (.+)$').Groups[1].Value.Trim().
        Replace('resourceGroup().id', 'scopeId').Replace('deployment().name', 'parentName')
    $rangeExpression = [regex]::Match($source, '(?m)^var shardRange = (.+)$').Groups[1].Value.Trim()
    $nameFunctions += "func nameSuffix(scopeId string, parentName string) string => $suffixExpression"
    $nameFunctions += "func nameRange(storageIndex int, storageCount int) string => $rangeExpression"
    $accountExpressions = foreach ($module in $accountStages.Keys) {
        "$module({ roleName: c.roleName }, { roleName: c.roleName, name: c.accountName }, nameRange(c.index, c.count), nameSuffix(c.scopeId, c.parentName))"
    }
    $commandExpressions = foreach ($module in $commandStages.Keys) {
        "$module({ roleName: c.roleName }, { roleName: c.roleName, name: c.accountName }, nameRange(c.index, c.count), nameSuffix(c.scopeId, c.parentName))"
    }
    $vectors = @'
var cases = [
  { roleName: 'Profile', accountName: 'myprofiles01', index: 1, count: 2, scopeId: 'storage-a', parentName: 'parent-a' }
  { roleName: 'Office', accountName: 'myoffice01', index: 1, count: 2, scopeId: 'storage-a', parentName: 'parent-a' }
  { roleName: 'Profile', accountName: 'myprofiles01', index: 1, count: 2, scopeId: 'storage-a', parentName: 'parent-b' }
  { roleName: 'Profile', accountName: 'myprofiles01', index: 1, count: 2, scopeId: 'storage-b', parentName: 'parent-a' }
  { roleName: 'Profile', accountName: 'myprofiles00', index: 0, count: 1, scopeId: 'storage-a', parentName: 'parent-a' }
  { roleName: 'Office', accountName: 'myoffice07', index: 7, count: 2, scopeId: 'storage-a', parentName: 'parent-a' }
  { roleName: 'Profile', accountName: 'myprofiles99', index: 99, count: 3, scopeId: 'storage-a', parentName: 'parent-a' }
  { roleName: 'Profile', accountName: 'abcdefghijklmnopqrstuvwx', index: 99, count: 800, scopeId: 'storage-a', parentName: 'parent-a' }
]
'@
    $fixtureSource = "targetScope = 'local'`n" + ($nameFunctions -join "`n") + "`n" + $vectors + "`n" +
        "var results = map(cases, c => { suffix: nameSuffix(c.scopeId, c.parentName), range: nameRange(c.index, c.count), accounts: [$($accountExpressions -join ', ')], commands: [$($commandExpressions -join ', ')] })`n" +
        "output encodedResults string = base64(string({ cases: results }))"
    $fixturePath = Join-Path $templateDirectory 'deployment-names.bicep'
    [IO.File]::WriteAllText($fixturePath, $fixtureSource)
    $nameCases = (Invoke-TestNamingVectors -TemplateFile $fixturePath).cases.value

    $smbMatch = [regex]::Match($source, '(?ms)^var smbSettingsValues = (\{.*?^\})')
    if (-not $smbMatch.Success) { throw 'Production SMB security settings were not found.' }
    $securityFixtureSource = "targetScope = 'local'`nfunc smbSecurity(identitySolution string) object => $($smbMatch.Groups[1].Value)`n" + @'
var identities = ['EntraId', 'ActiveDirectoryDomainServices', 'EntraDomainServices', 'EntraKerberos-Hybrid', 'EntraKerberos-CloudOnly']
var results = map(identities, mode => { identitySolution: mode, settings: smbSecurity(mode) })
output encodedResults string = base64(string({ security: results }))
'@
    $securityFixturePath = Join-Path $templateDirectory 'smb-security.bicep'
    [IO.File]::WriteAllText($securityFixturePath, $securityFixtureSource)
    $securityCases = (Invoke-TestNamingVectors -TemplateFile $securityFixturePath).security.value
}

AfterAll {
    if (Test-Path -LiteralPath $templateDirectory) {
        Remove-Item -LiteralPath $templateDirectory -Recurse -Force -ErrorAction Stop
    }
}

Describe 'FSLogix Azure Files security baseline' {
    It 'requires SMB 3.1.1, AES Kerberos tickets and encrypted GCM channels for every identity mode' {
        foreach ($case in $securityCases) {
            $case.settings.versions | Should -Be 'SMB3.1.1;'
            $case.settings.kerberosTicketEncryption | Should -Be 'AES-256;'
            $case.settings.channelEncryption | Should -Be 'AES-128-GCM;AES-256-GCM;'
            $case.settings.encryptionInTransit.required | Should -BeTrue
        }
    }

    It 'allows key authentication only for the explicit EntraId path' {
        ($securityCases | Where-Object identitySolution -eq 'EntraId').settings.authenticationMethods |
            Should -Be 'NTLMv2;'
        foreach ($case in $securityCases | Where-Object identitySolution -ne 'EntraId') {
            $case.settings.authenticationMethods | Should -Be 'Kerberos;'
        }
    }

    It 'configures AD storage accounts with literal AES256 without an encryption selector' {
        $template.parameters.PSObject.Properties.Name | Should -Not -Contain 'kerberosEncryptionType'
        $arguments = $template.resources.configureADDSAuth.properties.parameters.parameters.value
        ($arguments | Where-Object name -eq 'KerberosEncryptionType').value | Should -Be 'AES256'
        $root = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\shared\modules\orchestration\fslogix\fslogix.bicep') -Raw
        $root | Should -Not -Match '\bkerberosEncryptionType\b'
    }

    It 'explicitly enforces account-level HTTPS, TLS and infrastructure encryption for all accounts' {
        $parameters = $template.resources.storageAccounts.properties.parameters
        $parameters.supportsHttpsTrafficOnly.value | Should -BeTrue
        $parameters.minimumTlsVersion.value | Should -Be 'TLS1_2'
        $parameters.requireInfrastructureEncryption.value | Should -BeTrue
    }

    It 'uses a file-service API supporting the separate SMB encryption requirement' {
        $fileService = $template.resources.fileServices.properties.template.resources.fileService
        $fileService.apiVersion | Should -Be '2025-01-01'
        $template.resources.fileServices.properties.template.parameters.smbSettings |
            Should -Not -BeNullOrEmpty
        $template.variables.smbSettingsValues.encryptionInTransit.required | Should -BeTrue
    }

    It 'preserves SSD-only SMB Multichannel without changing performance inputs' {
        $template.resources.fileServices.properties.parameters.smbSettings.value |
            Should -Match "multichannel.*accountConfigurations.*\.sku.*Standard"
        $template.resources.shares.properties.parameters.provisionedIops.value |
            Should -Match 'accountConfigurations.*configuration.provisionedIops'
        $template.resources.shares.properties.parameters.provisionedThroughputMiBps.value |
            Should -Match 'accountConfigurations.*configuration.provisionedThroughputMiBps'
    }
}

Describe 'FSLogix deployment tracking names' {
    It 'identifies the account and role for per-account modules and the inclusive range for commands' {
        foreach ($name in $nameCases[0].accounts) {
            $name | Should -Match '^fslogix-profile-myprofiles01-(storage|files|share|endpoint)-[a-z0-9]{13}$'
        }
        foreach ($name in $nameCases[1].commands) {
            $name | Should -Match '^fslogix-office-shards01-02-(domain|hybrid|manifest|ntfs|consent)-[a-z0-9]{13}$'
        }
        $nameCases[4].range | Should -Be 'shards00-00'
        $nameCases[5].range | Should -Be 'shards07-08'
        $nameCases[6].range | Should -Be 'shards99-101'
        $nameCases[7].range | Should -Be 'shards99-898'
    }

    It 'keeps names unique between roles, stages, parent deployments and storage scopes' {
        $nameCases[0].suffix | Should -Be $nameCases[1].suffix
        $nameCases[0].suffix | Should -Not -Be $nameCases[2].suffix
        $nameCases[0].suffix | Should -Not -Be $nameCases[3].suffix
        $names = @($nameCases | ForEach-Object { $_.accounts; $_.commands })
        @($names | Sort-Object -Unique).Count | Should -Be $names.Count
    }

    It 'stays within the ARM 64-character deployment-name limit without truncating identifiers' {
        foreach ($name in @($nameCases | ForEach-Object { $_.accounts; $_.commands })) {
            $name.Length | Should -BeLessOrEqual 64
            $name | Should -Match '^[a-z0-9-]+$'
        }
        $nameCases[7].accounts | Should -Contain "fslogix-profile-abcdefghijklmnopqrstuvwx-endpoint-$($nameCases[7].suffix)"
    }

    It 'emits the explicit account and range names in compiled ARM' {
        foreach ($module in $accountStages.Keys) {
            $template.resources.$module.name | Should -Match "accountConfigurations.*roleName"
            $template.resources.$module.name | Should -Match "accountConfigurations.*\.name"
            $template.resources.$module.name | Should -Match "variables\('deploymentNameSuffix'\)"
        }
        foreach ($module in $commandStages.Keys) {
            $template.resources.$module.name | Should -Match "storageRoles.*roleName"
            $template.resources.$module.name | Should -Match "variables\('shardRange'\)"
            $template.resources.$module.name | Should -Match "variables\('deploymentNameSuffix'\)"
        }
    }

    It 'preserves the stable Run Command resource names' {
        $commandNames = @{
            configureADDSAuth = 'Domain-Join'
            configureEntraKerberosWithDomainInfo = 'Configure-StorageAccountsforEntraHybrid'
            updateStorageApplicationsManifest = 'Update-Storage-Account-Application-Manifest'
            SetNTFSPermissions = 'Set-NTFS-Permissions'
            grantStorageApplicationsConsent = 'Grant-Storage-Account-Application-Consent'
        }
        foreach ($module in $commandNames.Keys) {
            $template.resources.$module.properties.parameters.name.value |
                Should -Be "[format('{0}-$($commandNames[$module])', variables('storageRoles')[copyIndex()].roleName)]"
        }
    }
}

Describe 'Azure Files helper VM command sequencing' {
    It 'passes the scalar share name directly to NTFS and the share resource module' {
        $arguments = $template.resources.SetNTFSPermissions.properties.parameters.parameters.value
        ($arguments | Where-Object name -eq 'ShareName').value |
            Should -Be "[variables('storageRoles')[copyIndex()].shareName]"
        $parameters = $template.resources.shares.properties.parameters
        $parameters.name.value | Should -Be "[variables('accountConfigurations')[copyIndex()].shareName]"
        $parameters.storageAccountName.value | Should -Be "[variables('accountConfigurations')[copyIndex()].name]"
        $parameters.shareQuota.value | Should -Be "[variables('accountConfigurations')[copyIndex()].shareSizeInGB]"
        $parameters.PSObject.Properties.Name | Should -Not -Contain 'fileShares'
        $parameters.PSObject.Properties.Name | Should -Not -Contain 'storageSku'
    }

    It 'serializes <Module> roles in compiled ARM' -TestCases @(
        @{ Module = 'configureADDSAuth' }
        @{ Module = 'configureEntraKerberosWithDomainInfo' }
        @{ Module = 'updateStorageApplicationsManifest' }
        @{ Module = 'SetNTFSPermissions' }
        @{ Module = 'grantStorageApplicationsConsent' }
    ) {
        param($Module)
        $resource = $template.resources.$Module
        $resource | Should -Not -BeNullOrEmpty
        $resource.copy.mode | Should -Be 'serial'
        $resource.copy.batchSize | Should -Be 1
        $resource.properties.template.resources.runCommand.properties.asyncExecution | Should -Be '[parameters(''asyncExecution'')]'
        $resource.properties.parameters.PSObject.Properties.Name | Should -Not -Contain 'asyncExecution'
        $resource.properties.template.parameters.asyncExecution.defaultValue | Should -Be $false
    }

    It 'retains manifest-before-NTFS and NTFS-before-consent dependencies' {
        $template.resources.SetNTFSPermissions.dependsOn | Should -Contain 'updateStorageApplicationsManifest'
        $template.resources.SetNTFSPermissions.dependsOn | Should -Contain 'configureADDSAuth'
        $template.resources.SetNTFSPermissions.dependsOn | Should -Contain 'configureEntraKerberosWithDomainInfo'
        $template.resources.grantStorageApplicationsConsent.dependsOn | Should -Contain 'SetNTFSPermissions'
    }

    It 'forwards the complete shard range to <Module>' -TestCases @(
        @{ Module = 'configureADDSAuth' }
        @{ Module = 'configureEntraKerberosWithDomainInfo' }
        @{ Module = 'updateStorageApplicationsManifest' }
        @{ Module = 'SetNTFSPermissions' }
        @{ Module = 'grantStorageApplicationsConsent' }
    ) {
        param($Module)
        $arguments = $template.resources.$Module.properties.parameters.parameters.value
        ($arguments | Where-Object name -eq 'StorageCount').value | Should -Be "[string(parameters('storageCount'))]"
        ($arguments | Where-Object name -eq 'StorageIndex').value | Should -Be "[string(parameters('storageIndex'))]"
    }

    It 'secures both domain credential arguments in <Module>' -TestCases @(
        @{ Module = 'configureADDSAuth' }
        @{ Module = 'configureEntraKerberosWithDomainInfo' }
        @{ Module = 'SetNTFSPermissions' }
    ) {
        param($Module)
        $resource = $template.resources.$Module
        $resource.properties.template.parameters.protectedParameters.type | Should -Be 'secureObject'
        $credentials = $resource.properties.parameters.protectedParameters.value.items
        $credentials.name | Should -Be @('DomainJoinUserPrincipalName', 'DomainJoinUserPwd')
        $credentials[0].value | Should -Be "[parameters('domainJoinUserPrincipalName')]"
        $credentials[1].value | Should -Be "[parameters('domainJoinUserPassword')]"
        $resource.properties.parameters.parameters.value.name | Should -Not -Contain 'DomainJoinUserPwd'
    }

    It 'keeps Profile before Office and leaves storage loops parallel' {
        $profilePosition = $source.IndexOf("roleName: 'Profile'")
        $officePosition = $source.IndexOf("roleName: 'Office'")
        $profilePosition | Should -BeGreaterOrEqual 0
        $officePosition | Should -BeGreaterThan $profilePosition
        foreach ($module in @('storageAccounts', 'fileServices', 'shares', 'privateEndpoints')) {
            $template.resources.$module.copy.mode | Should -Not -Be 'serial'
        }
    }
}
