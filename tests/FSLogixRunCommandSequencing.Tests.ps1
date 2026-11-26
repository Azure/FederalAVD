BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $source = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\shared\modules\orchestration\fslogix\modules\azureFiles.bicep') -Raw
    $templateDirectory = Join-Path ([IO.Path]::GetTempPath()) ('FederalAVD-RunCommandSequencing-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $templateDirectory -ErrorAction Stop | Out-Null
    $templatePath = Join-Path $templateDirectory 'azureFiles.json'
    az bicep build --file (Join-Path $repoRoot 'deployments\shared\modules\orchestration\fslogix\modules\azureFiles.bicep') --outfile $templatePath --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Failed to compile Azure Files orchestration.' }
    $template = Get-Content -LiteralPath $templatePath -Raw | ConvertFrom-Json -Depth 100
}

AfterAll {
    if (Test-Path -LiteralPath $templateDirectory) {
        Remove-Item -LiteralPath $templateDirectory -Recurse -Force -ErrorAction Stop
    }
}

Describe 'Azure Files helper VM command sequencing' {
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
        $profilePosition = $source.IndexOf("commandPrefix: 'Profile-'")
        $officePosition = $source.IndexOf("commandPrefix: 'Office-'")
        $profilePosition | Should -BeGreaterOrEqual 0
        $officePosition | Should -BeGreaterThan $profilePosition
        foreach ($module in @('storageAccounts', 'fileServices', 'shares', 'privateEndpoints')) {
            $template.resources.$module.copy.mode | Should -Not -Be 'serial'
        }
    }
}
