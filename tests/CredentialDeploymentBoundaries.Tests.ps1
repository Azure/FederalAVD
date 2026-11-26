BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot

    function Get-CredentialResource {
        param($Template)
        if ($Template.resources -is [array]) { $Template.resources } else { $Template.resources.PSObject.Properties.Value }
    }

    function Get-CredentialTemplate {
        param($Template)
        $Template
        foreach ($resource in (Get-CredentialResource -Template $Template)) {
            if ($resource.properties.template) {
                Get-CredentialTemplate -Template $resource.properties.template
            }
        }
        foreach ($variable in $Template.variables.PSObject.Properties.Value) {
            if ($variable.resources -and $variable.'$schema') {
                Get-CredentialTemplate -Template $variable
            }
        }
    }
}

Describe 'Secure credential module boundaries' {
    BeforeAll {
        $runCommandPath = [IO.Path]::GetRelativePath($TestDrive, (Join-Path $repoRoot 'deployments\shared\modules\resourceModules\compute\virtualMachines\runCommands\deploy.bicep')).Replace('\', '/')
        $vmPath = [IO.Path]::GetRelativePath($TestDrive, (Join-Path $repoRoot 'deployments\shared\modules\resourceModules\compute\virtualMachines\deploy.bicep')).Replace('\', '/')
        $netAppPath = [IO.Path]::GetRelativePath($TestDrive, (Join-Path $repoRoot 'deployments\shared\modules\resourceModules\netApp\netAppAccounts\deploy.bicep')).Replace('\', '/')
        $fixturePath = Join-Path $TestDrive 'SecureCredentials.bicep'
        $armPath = Join-Path $TestDrive 'SecureCredentials.json'
        $fixture = @"
@secure()
param password string

module command '$runCommandPath' = {
  params: {
    name: 'synthetic-command'
    virtualMachineName: 'synthetic-vm'
    script: 'param([string]`$DomainJoinUserPwd)'
    parameters: [{ name: 'PublicArgument', value: 'synthetic-public' }]
    protectedParameters: {
      items: [{ name: 'DomainJoinUserPwd', value: password }]
    }
  }
}

module vm '$vmPath' = {
  params: {
    name: 'synthetic-vm'
    adminPassword: password
    adminUsername: 'synthetic-admin'
    nicName: 'synthetic-nic'
    osDiskName: 'synthetic-os'
    subnetResourceId: '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/synthetic/providers/Microsoft.Network/virtualNetworks/synthetic/subnets/synthetic'
    extensions: {
      items: [{
        name: 'JsonADDomainExtension'
        publisher: 'Microsoft.Compute'
        type: 'JsonADDomainExtension'
        typeHandlerVersion: '1.3'
        settings: { Name: 'synthetic.invalid', User: 'synthetic-user' }
        protectedSettings: { Password: password }
      }]
    }
  }
}

module netapp '$netAppPath' = {
  params: {
    name: 'synthetic-netapp'
    activeDirectory: {
      domain: 'synthetic.invalid'
      username: 'synthetic-user'
      password: password
    }
  }
}
"@
        [IO.File]::WriteAllText($fixturePath, $fixture, [Text.Encoding]::ASCII)
        az bicep build --file $fixturePath --outfile $armPath --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw 'Failed to compile secure credential boundary fixture.' }
        $template = Get-Content -LiteralPath $armPath -Raw | ConvertFrom-Json -Depth 100
    }

    It 'secures the entire <Parameter> deployment parameter' -TestCases @(
        @{ Module = 'command'; Parameter = 'protectedParameters' }
        @{ Module = 'vm'; Parameter = 'extensions' }
        @{ Module = 'netapp'; Parameter = 'activeDirectory' }
    ) {
        param($Module, $Parameter)
        $template.resources.$Module.properties.template.parameters.$Parameter.type |
            Should -Be 'secureObject'
    }

    It 'unwraps the Run Command array only into the protected resource field' {
        $command = $template.resources.command
        $command.properties.parameters.protectedParameters.value.items.name | Should -Be 'DomainJoinUserPwd'
        $command.properties.parameters.protectedParameters.value.items.value | Should -Be "[parameters('password')]"
        $resource = $command.properties.template.resources.runCommand
        $resource.properties.protectedParameters | Should -Match "parameters\('protectedParameters'\)\.items"
        $resource.properties.parameters | Should -Not -Match 'protectedParameters|password'
        $command.properties.template.parameters.protectedParameters.defaultValue.items.Count | Should -Be 0
        $resource.properties.source.script | Should -Match "parameters\('script'\)"
    }

    It 'keeps extension passwords out of public settings and module outputs' {
        $vm = $template.resources.vm
        $vm.properties.parameters.extensions.value.items.protectedSettings.Password |
            Should -Be "[parameters('password')]"
        $extensions = $vm.properties.template.resources.vmExtensions
        $extensions.copy.count | Should -Match "parameters\('extensions'\)\.items"
        $extensions.properties.protectedSettings | Should -Match 'protectedSettings'
        $extensions.properties.settings | Should -Not -Match 'protectedSettings|password'
        $vm.properties.template.parameters.extensions.defaultValue.items.Count | Should -Be 0
        $vm.properties.template.outputs | ConvertTo-Json -Depth 100 |
            Should -Not -Match 'protectedSettings|password|extensions'
    }

    It 'keeps NetApp AD credentials secure until the provider request' {
        $netapp = $template.resources.netapp
        $netapp.properties.parameters.activeDirectory.value.password | Should -Be "[parameters('password')]"
        $account = Get-CredentialResource -Template $netapp.properties.template |
            Where-Object type -eq 'Microsoft.NetApp/netAppAccounts'
        $account.properties.activeDirectories |
            Should -Match "parameters\('activeDirectory'\)"
        $netapp.properties.template.outputs | ConvertTo-Json -Depth 100 |
            Should -Not -Match 'activeDirectory|password'
    }
}

Describe 'Published credential contracts in <Entry>' -ForEach @(
    @{ Entry = 'hostpools\hostpool' }
    @{ Entry = 'automatedHostPools\automatedHostPool' }
    @{ Entry = 'hostpoolPoc\hostpoolPoc' }
    @{ Entry = 'add-ons\fslogixStorage\main' }
    @{ Entry = 'imageBuild\imageBuild' }
    @{ Entry = 'add-ons\imageValidation\main' }
    @{ Entry = 'add-ons\runCommandsOnVms\main' }
) {
    BeforeAll {
        $template = Get-Content -LiteralPath (Join-Path $repoRoot "deployments\$Entry.json") -Raw | ConvertFrom-Json -Depth 100
        $templates = @(Get-CredentialTemplate -Template $template)
    }

    It 'never downgrades protected arrays or AD settings to ordinary deployment parameters' {
        $checked = 0
        foreach ($nested in $templates) {
            foreach ($name in @('protectedParameters', 'extensions', 'activeDirectory')) {
                if ($nested.parameters.PSObject.Properties.Name -contains $name) {
                    $nested.parameters.$name.type | Should -Be 'secureObject' -Because "$Entry contains the $name contract"
                    $checked++
                }
            }
        }
        $checked | Should -BeGreaterThan 0
    }

    It 'keeps domain passwords out of ordinary Run Command script parameters' {
        foreach ($nested in $templates) {
            $resources = Get-CredentialResource -Template $nested
            foreach ($resource in $resources | Where-Object type -eq 'Microsoft.Compute/virtualMachines/runCommands') {
                $resource.properties.parameters | ConvertTo-Json -Depth 100 |
                    Should -Not -Match 'DomainJoinUserPwd|DomainJoinUserPassword|RegistrationToken|StorageAccountKeys'
            }
        }
    }
}
