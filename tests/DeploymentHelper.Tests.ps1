BeforeDiscovery {
    $entryPointPaths = @(
        'deployments\hostpools\hostpool.json'
        'deployments\automatedHostPools\automatedHostPool.json'
        'deployments\add-ons\fslogixStorage\main.json'
    )
}

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $helperPath = Join-Path $repoRoot 'deployments\shared\modules\orchestration\deploymentHelper\deploy.bicep'
    $entryPointPaths = @(
        'deployments\hostpools\hostpool.json'
        'deployments\automatedHostPools\automatedHostPool.json'
        'deployments\add-ons\fslogixStorage\main.json'
    )
}

Describe 'Deployment helper OS disk SKU' {
    BeforeAll {
        $helper = Get-Content -LiteralPath $helperPath -Raw
    }

    It 'uses a fixed Standard SSD independent of workload disk settings' {
        $helper | Should -Match "osDiskSku: 'StandardSSD_LRS'"
        $helper | Should -Not -Match '(?m)^param diskSku string\s*$'
    }

    It 'embeds the fixed helper SKU in <_>' -ForEach $entryPointPaths {
        $relativePath = $_
        $arm = Get-Content -LiteralPath (Join-Path $repoRoot $relativePath) -Raw
        $arm | Should -Match '"osDiskSku"\s*:\s*\{\s*"value"\s*:\s*"StandardSSD_LRS"'
    }
}

Describe 'Deployment helper optional domain join across solutions' {
    BeforeDiscovery {
        $cases = @(
            @{
                Name = 'standard host pool'
                Template = 'deployments\hostpools\hostpool.json'
                Form = 'deployments\hostpools\uiFormDefinition.json'
                Step = 'operationsAndMonitoring'
                Section = 'deploymentVm'
                Size = 'size'
                Identity = "steps('hosts').identity.machineIdentity"
                NetAppDeployment = "and(not(equals(steps('controlPlane').hostPool.type, 'Personal')), equals(steps('userProfiles').profileSolution, 'FSLogix'), steps('userProfiles').deployStorage, equals(steps('userProfiles').storageService, 'AzureNetAppFiles'))"
                RequiredVariable = 'createDeploymentVm'
                KeyVaultParameter = 'existingCredentialsKeyVaultResourceId'
                JoinExpression = "[or(parameters('domainJoinDeploymentVirtualMachine'), equals(split(parameters('fslogixStorageService'), ' ')[0], 'AzureNetAppFiles'))]"
                JoinOutput = "[and(contains(steps('hosts').identity.machineIdentity, 'DomainServices'), if(and(not(equals(steps('controlPlane').hostPool.type, 'Personal')), equals(steps('userProfiles').profileSolution, 'FSLogix'), steps('userProfiles').deployStorage, equals(steps('userProfiles').storageService, 'AzureNetAppFiles')), true, and(or(and(equals(steps('userProfiles').profileSolution, 'FSLogix'), steps('userProfiles').deployStorage), steps('hosts').diskEncryption.confidentialVMOSDiskEncryption, not(empty(steps('controlPlane').naming.desktopFriendlyName))), steps('operationsAndMonitoring').deploymentVm.domainJoin)))]"
            }
            @{
                Name = 'FSLogix storage add-on'
                Template = 'deployments\add-ons\fslogixStorage\main.json'
                Form = 'deployments\add-ons\fslogixStorage\uiFormDefinition.json'
                Step = 'deployment'
                Section = ''
                Size = 'deploymentVirtualMachineSize'
                Identity = "steps('identity').machineIdentity"
                NetAppDeployment = "startsWith(steps('storage').storageService, 'AzureNetAppFiles')"
                RequiredVariable = 'deployDeploymentVirtualMachine'
                KeyVaultParameter = 'credentialsKeyVaultResourceId'
                JoinExpression = "[or(parameters('domainJoinDeploymentVirtualMachine'), equals(variables('storageSolution'), 'AzureNetAppFiles'))]"
                JoinOutput = "[and(contains(steps('identity').machineIdentity, 'DomainServices'), if(startsWith(steps('storage').storageService, 'AzureNetAppFiles'), true, steps('deployment').domainJoin))]"
            }
        )
    }

    Context '<Name>' -ForEach $cases {
        BeforeAll {
            $case = $_
            $template = Get-Content -LiteralPath (Join-Path $repoRoot $case.Template) -Raw | ConvertFrom-Json
            $form = Get-Content -LiteralPath (Join-Path $repoRoot $case.Form) -Raw | ConvertFrom-Json
            $step = $form.view.properties.steps | Where-Object name -eq $case.Step
            $elements = if ($case.Section) {
                ($step.elements | Where-Object name -eq $case.Section).elements
            }
            else {
                $step.elements
            }
            $checkbox = $elements | Where-Object name -eq 'domainJoin'
            $helperParameters = $template.resources.deploymentHelper.properties.parameters
        }

        It 'defaults direct deployments and the optional checkbox to no requested join' {
            $template.parameters.domainJoinDeploymentVirtualMachine.type | Should -Be 'bool'
            $template.parameters.domainJoinDeploymentVirtualMachine.defaultValue | Should -Be $false
            $checkbox.type | Should -Be 'Microsoft.Common.CheckBox'
            ($checkbox.PSObject.Properties.Name -contains 'defaultValue') | Should -Be $false
            $checkbox.constraints.required | Should -Not -Be $true
        }

        It 'places the checkbox after size and hides it for mandatory NetApp joins or unsupported identities' {
            $names = @($elements.name)
            $names.IndexOf('domainJoin') | Should -Be ($names.IndexOf($case.Size) + 1)
            $checkbox.visible | Should -Be "[and(contains($($case.Identity), 'DomainServices'), not($($case.NetAppDeployment)))]"
            $form.view.outputs.parameters.domainJoinDeploymentVirtualMachine | Should -Be $case.JoinOutput
        }

        It 'preserves helper creation conditions and automatic NetApp domain join' {
            $template.resources.deploymentHelper.condition | Should -Be "[variables('$($case.RequiredVariable)')]"
            $template.variables.($case.RequiredVariable) | Should -Not -Match "parameters\('domainJoinDeploymentVirtualMachine'\)"
            $helperParameters.domainJoinDeploymentVirtualMachine.value | Should -Be $case.JoinExpression
        }

        It 'rejects unsupported identity, missing credentials, and missing or externally owned helper cases' {
            $guard = $template.variables.deploymentVmDomainJoinIsValid
            $guard | Should -Match "not\(parameters\('domainJoinDeploymentVirtualMachine'\)\)"
            $guard | Should -Match ([regex]::Escape("variables('$($case.RequiredVariable)')"))
            $guard | Should -Match "contains\(parameters\('identitySolution'\), 'DomainServices'\)"
            $guard | Should -Match "not\(empty\(parameters\('domainName'\)\)\)"
            $guard | Should -Match ([regex]::Escape("parameters('$($case.KeyVaultParameter)')"))
            $guard | Should -Match "parameters\('domainJoinUserPrincipalName'\)"
            $guard | Should -Match "parameters\('domainJoinUserPassword'\)"
            $guard | Should -Match 'fail\('
            $validationConsumer = if ($case.Section) {
                $template.resources.hostsResourceGroup.properties.parameters.location
            }
            else {
                $template.resources.fslogix.properties.parameters.activeDirectoryConnection
            }
            $validationConsumer | Should -Match "variables\('deploymentVmDomainJoinIsValid'\)"
        }

        It 'reuses manual and Key Vault domain credentials without new credential inputs' {
            $helperParameters.domainName.value | Should -Be "[parameters('domainName')]"
            foreach ($name in @('domainJoinUserPrincipalName', 'domainJoinUserPassword')) {
                $helperParameters.$name | Should -Match ([regex]::Escape("parameters('$name')"))
                $helperParameters.$name | Should -Match "createObject\('reference',"
                $helperParameters.$name | Should -Match ([regex]::Escape("parameters('$($case.KeyVaultParameter)')"))
                $helperParameters.$name | Should -Match ([regex]::Escape("'secretName', '$($name.Substring(0, 1).ToUpper() + $name.Substring(1))'"))
            }
        }

        It 'retains the existing domain-joined helper OU selection' {
            if ($case.Section) {
                $helperParameters.ouPath.value | Should -Be "[parameters('vmOUPath')]"
            }
            else {
                $helperParameters.ouPath |
                    Should -Be "[if(not(empty(parameters('deploymentVirtualMachineOrganizationalUnitPath'))), createObject('value', parameters('deploymentVirtualMachineOrganizationalUnitPath')), createObject('value', parameters('organizationalUnitPath')))]"
            }
        }
}
    }
