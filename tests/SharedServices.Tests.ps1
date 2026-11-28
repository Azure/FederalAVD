BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $bicepPath = Join-Path $repoRoot 'deployments\sharedServices\sharedServices.bicep'
    $armPath = Join-Path $repoRoot 'deployments\sharedServices\sharedServices.json'
    $formPath = Join-Path $repoRoot 'deployments\sharedServices\uiFormDefinition.json'
    $workspaceModulePath = Join-Path $repoRoot 'deployments\shared\modules\orchestration\avdWorkspace\avdWorkspace.bicep'
    $keyVaultModulePath = Join-Path $repoRoot 'deployments\shared\modules\orchestration\keyVaults\keyVaults.bicep'
    $azureFilesModulePath = Join-Path $repoRoot 'deployments\shared\modules\orchestration\fslogix\modules\azureFiles.bicep'
    $backupVaultModulePath = Join-Path $repoRoot 'deployments\shared\modules\orchestration\recoveryServices\fslogixBackupVault.bicep'
    $readmePath = Join-Path $repoRoot 'deployments\sharedServices\README.md'
}

Describe 'Shared Services Portal network access' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'NamingTestHelpers.ps1')
        . (Join-Path $PSScriptRoot 'UiFormTestHelpers.ps1')
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $operations = $form.view.properties.steps | Where-Object name -eq 'operations'
        $access = $operations.elements | Where-Object name -eq 'backupNetworking'
        $networkStep = $form.view.properties.steps | Where-Object name -eq 'privateNetworking'
        $network = $networkStep.elements | Where-Object name -eq 'privateEndpointSubnets'
        $dns = $operations.elements | Where-Object name -eq 'privateDnsSection'
        $outputs = $form.view.outputs.parameters
    }

    It 'keeps Backup endpoint and DNS controls separate from shared subnet placement and Key Vault public access' {
        $selector = $access.elements | Where-Object name -eq 'backupConnectivity'
        $selector.type | Should -Be 'Microsoft.Common.DropDown'
        $selector.defaultValue | Should -Be 'Select Backup connectivity'
        $selector.constraints.required | Should -Be $true
        ($selector.constraints.allowedValues.label -join ',') | Should -Be 'Select Backup connectivity,Private connectivity,Public connectivity'
        ($selector.constraints.allowedValues.value -join ',') | Should -Be ',Private,Public'
        @($access.elements | Where-Object name -eq 'paasPublicNetworkAccess').Count | Should -Be 0
        (($operations.elements | Where-Object name -eq 'keyVaultPublicNetworking').elements |
            Where-Object name -eq 'keyVaultPublicNetworkAccess').defaultValue | Should -Be 'Disabled'
        @($operations.elements | Where-Object name -eq 'privateEndpoint').Count | Should -Be 0
        $names = @($operations.elements.name)
        $names | Should -Not -Contain 'networkSection'
        [array]::IndexOf($names, 'backupNetworking') | Should -BeLessThan ([array]::IndexOf($names, 'privateDnsSection'))
        $stepNames = @($form.view.properties.steps.name)
        [array]::IndexOf($stepNames, 'avdControlPlane') | Should -BeLessThan ([array]::IndexOf($stepNames, 'privateNetworking'))
    }

    It 'preserves native outputs and independent public access for <Mode>' -TestCases @(
        @{ Mode = 'PublicEndpoint'; Private = $false }
        @{ Mode = 'PrivateEndpoint'; Private = $true }
    ) {
        param($Mode, $Private)

        foreach ($public in @('Disabled', 'EnabledWithRestrictions', 'Enabled')) {
            foreach ($integrateDns in @($false, $true)) {
                foreach ($resources in @(
                    @{ deploySecretsKeyVault = $false; deployEncryptionKeyVault = $false; deployFSLogixBackupVault = $false }
                    @{ deploySecretsKeyVault = $true; deployEncryptionKeyVault = $false; deployFSLogixBackupVault = $false }
                    @{ deploySecretsKeyVault = $false; deployEncryptionKeyVault = $true; deployFSLogixBackupVault = $false }
                    @{ deploySecretsKeyVault = $false; deployEncryptionKeyVault = $false; deployFSLogixBackupVault = $true }
                    @{ deploySecretsKeyVault = $true; deployEncryptionKeyVault = $true; deployFSLogixBackupVault = $true }
                )) {
                    $steps = @{
                        operations = @{
                            paasConnectivity = @{ scenario = 'Custom' }
                            backupNetworking = @{
                                backupPrivateEndpoint = $Private
                                backupPublicNetworkAccess = $(if ($Private) { 'Disabled' } else { 'Enabled' })
                            }
                            keyVaultPublicNetworking = @{ keyVaultPublicNetworkAccess = $public }
                            keyVaultPrivateNetworking = @{
                                keyVaultPrivateEndpoint = $true
                                enablePrivateDNSIntegration = $integrateDns
                                vaultPrivateDnsZone = 'keyvault-dns'
                            }
                            privateDnsSection = @{
                                enablePrivateDNSIntegration = $integrateDns
                                vaultPrivateDnsZone = 'keyvault-dns'
                                backupPrivateDnsZone = 'backup-dns'
                                blobPrivateDnsZone = 'blob-dns'
                                queuePrivateDnsZone = 'queue-dns'
                            }
                            resources = $resources
                        }
                        avdControlPlane = @{
                            sharedWorkspace = @{ manageWorkspace = $false }
                            workspaceFeedEndpoint = @{ manageFeedEndpoint = $false }
                            globalFeed = @{ manageGlobalWorkspace = $false }
                        }
                        privateNetworking = @{
                            privateEndpointSubnets = @{ subnet = @{ id = 'subnet-id' } }
                        }
                    }
                    $paas = Invoke-CuiExpression $outputs.paasNetworking $steps
                    $placements = Invoke-CuiExpression $outputs.privateEndpointSubnetResourceIds $steps
                    $zoneIds = Invoke-CuiExpression $outputs.privateDnsZoneResourceIds $steps
                    $backupPrivate = $Private -and $resources.deployFSLogixBackupVault
                    if ($resources.deployFSLogixBackupVault) {
                        $paas.backup.privateEndpoint | Should -BeOfType ([bool])
                        $paas.backup.privateEndpoint | Should -Be $backupPrivate
                    } else {
                        $paas.backup.Count | Should -Be 0
                    }
                    $sharedPrivate = $backupPrivate -or $resources.deploySecretsKeyVault -or $resources.deployEncryptionKeyVault
                    Invoke-CuiExpression $network.visible $steps | Should -Be $sharedPrivate
                    Invoke-CuiExpression $dns.visible $steps | Should -Be $backupPrivate
                    $placements.sharedResources |
                        Should -Be $(if ($sharedPrivate) { 'subnet-id' } else { '' })
                    if ($resources.deploySecretsKeyVault -or $resources.deployEncryptionKeyVault) {
                        $paas.keyVault.publicNetworkAccess | Should -Be $public
                    } else {
                        $paas.keyVault.Count | Should -Be 0
                    }
                    $zoneIds.vault |
                        Should -Be $(if ($integrateDns -and ($resources.deploySecretsKeyVault -or $resources.deployEncryptionKeyVault)) { 'keyvault-dns' } else { '' })
                    foreach ($zone in @(
                        @{ Parameter = 'backup'; Value = 'backup-dns' }
                        @{ Parameter = 'blob'; Value = 'blob-dns' }
                        @{ Parameter = 'queue'; Value = 'queue-dns' }
                    )) {
                        $zoneIds.($zone.Parameter) |
                            Should -Be $(if ($Private -and $integrateDns -and $resources.deployFSLogixBackupVault) { $zone.Value } else { '' })
                    }
                }
            }
        }
    }

    It 'gates network and DNS discovery on private access and their selected dependencies' {
        $vnetApi = $network.elements | Where-Object name -eq 'virtualNetworksApi'
        $subnetApi = $network.elements | Where-Object name -eq 'subnetsApi'
        $dnsApi = $dns.elements | Where-Object name -eq 'privateDNSZonesApi'
        foreach ($mode in @('PublicEndpoint', 'PrivateEndpoint')) {
            foreach ($selected in @($false, $true)) {
                $steps = @{
                    operations = @{
                        paasConnectivity = @{ scenario = 'Custom' }
                        resources = @{ deploySecretsKeyVault = $false; deployEncryptionKeyVault = $false; deployFSLogixBackupVault = $true }
                        keyVaultPrivateNetworking = @{ keyVaultPrivateEndpoint = $false }
                        backupNetworking = @{ backupPrivateEndpoint = ($mode -eq 'PrivateEndpoint') }
                        privateDnsSection = @{
                            enablePrivateDNSIntegration = $selected
                            privateDNSZonesSubscription = $(if ($selected) { @{ id = 'dns-subscription-id' } } else { $null })
                        }
                    }
                    avdControlPlane = @{
                        sharedWorkspace = @{ manageWorkspace = $false }
                        workspaceFeedEndpoint = @{ manageFeedEndpoint = $false }
                        globalFeed = @{ manageGlobalWorkspace = $false }
                    }
                    privateNetworking = @{
                        privateEndpointSubnets = @{
                            networkSubscription = $(if ($selected) { @{ id = 'subscription-id' } } else { $null })
                            virtualNetwork = $(if ($selected) { @{ id = 'vnet-id' } } else { $null })
                        }
                    }
                }
                foreach ($condition in @($vnetApi.condition, $subnetApi.condition, $dnsApi.condition)) {
                    Invoke-CuiExpression $condition $steps | Should -Be ($mode -eq 'PrivateEndpoint' -and $selected)
                }
            }
        }
    }
}

Describe 'Shared Services AVD workspace ownership' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'UiFormTestHelpers.ps1')
        $bicep = Get-Content -LiteralPath $bicepPath -Raw
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $formJson = Get-Content -LiteralPath $formPath -Raw
        $workspaceModule = Get-Content -LiteralPath $workspaceModulePath -Raw
        $keyVaultModule = Get-Content -LiteralPath $keyVaultModulePath -Raw
        $azureFilesModule = Get-Content -LiteralPath $azureFilesModulePath -Raw
        $backupVaultModule = Get-Content -LiteralPath $backupVaultModulePath -Raw
        $readme = Get-Content -LiteralPath $readmePath -Raw
    }

    It 'creates or updates a shared workspace and exposes downstream outputs' {
        $bicep | Should -Match 'param manageAvdWorkspace bool = false'
        $bicep | Should -Match "param avdWorkspaceMode string = 'Create'"
        $bicep | Should -Match 'param existingAvdWorkspaceResourceId string'
        $bicep | Should -Match 'output avdWorkspaceResourceId string'
        $bicep | Should -Match 'output workspaceFeedPrivateEndpointResourceId string'
        $bicep | Should -Match 'output globalFeedWorkspaceResourceId string'
        $bicep | Should -Match 'output globalFeedPrivateEndpointResourceId string'
    }

    It 'exposes one shared subnet and routes every endpoint through it without enabling unselected AVD endpoints' {
        $template = Get-Content -LiteralPath $armPath -Raw | ConvertFrom-Json -Depth 100
        $names = @($template.parameters.PSObject.Properties.Name)
        @($names | Where-Object { $_ -like '*PrivateEndpointSubnetResourceId' }).Count | Should -Be 0
        $placementSchema = $template.definitions.($template.parameters.privateEndpointSubnetResourceIds.'$ref'.Replace('#/definitions/', ''))
        $placementSchema.properties.PSObject.Properties.Name | Should -Be 'sharedResources'
        $placementSchema.additionalProperties | Should -BeFalse
        $template.parameters.deployWorkspaceFeedPrivateEndpoint.type | Should -Be 'bool'
        $template.parameters.deployWorkspaceFeedPrivateEndpoint.defaultValue | Should -BeFalse
        foreach ($oldName in @('keyVaultPrivateEndpointSubnetResourceId', 'backupPrivateEndpointSubnetResourceId',
            'workspaceFeedPrivateEndpointSubnetResourceId', 'globalFeedPrivateEndpointSubnetResourceId')) {
            $names | Should -Not -Contain $oldName
            $form.view.outputs.parameters.PSObject.Properties.Name | Should -Not -Contain $oldName
        }
        $template.resources.keyVaults.properties.parameters.keyVaultPrivateEndpointSubnetResourceId.value |
            Should -Be "[variables('sharedResourcesPrivateEndpointSubnetResourceId')]"
        $template.resources.fslogixBackupVault.properties.parameters.privateEndpointSubnetResourceId.value |
            Should -Be "[variables('sharedResourcesPrivateEndpointSubnetResourceId')]"
        $template.resources.avdWorkspace.properties.parameters.workspaceFeedPrivateEndpointSubnetResourceId |
            Should -Be "[if(and(parameters('manageAvdWorkspace'), parameters('deployWorkspaceFeedPrivateEndpoint')), createObject('value', variables('sharedResourcesPrivateEndpointSubnetResourceId')), createObject('value', ''))]"
        $template.resources.avdWorkspace.properties.parameters.globalFeedPrivateEndpointSubnetResourceId |
            Should -Be "[if(parameters('manageGlobalAvdWorkspace'), createObject('value', variables('sharedResourcesPrivateEndpointSubnetResourceId')), createObject('value', ''))]"
        $template.variables.globalAvdWorkspaceConfigurationIsValid | Should -Match "not\(empty\(variables\('sharedResourcesPrivateEndpointSubnetResourceId'\)\)\)"
    }

    It 'returns effective IDs for created or adopted shared resources' {
        $bicep | Should -Match 'param existingLogAnalyticsWorkspaceResourceId string'
        $bicep | Should -Match 'param existingAVDInsightsDataCollectionRuleResourceId string'
        $bicep | Should -Match 'param existingDataCollectionEndpointResourceId string'
        $bicep | Should -Match 'param existingSecretsKeyVaultResourceId string'
        $bicep | Should -Match 'param existingEncryptionKeyVaultResourceId string'
        $bicep | Should -Match 'param existingFSLogixBackupVaultResourceId string'
        $bicep | Should -Match 'param existingFSLogixBackupPolicyName string'
        $bicep | Should -Match 'output logAnalyticsWorkspaceResourceId string'
        $bicep | Should -Match 'output avdInsightsDataCollectionRuleResourceId string'
        $bicep | Should -Match 'output dataCollectionEndpointResourceId string'
        $bicep | Should -Match 'output secretsKeyVaultResourceId string'
        $bicep | Should -Match 'output encryptionKeyVaultResourceId string'
        $bicep | Should -Match 'output fslogixBackupVaultResourceId string'
        $bicep | Should -Match 'output fslogixBackupPolicyResourceId string'
    }

    It 'supports host-pool-specific PoC naming without duplicating shared-resource orchestration' {
        $bicep | Should -Match 'param avdWorkspaceNameOverride string'
        $bicep | Should -Match 'param avdControlPlaneResourceGroupNameOverride string'
        $bicep | Should -Match 'param globalFeedWorkspaceNameOverride string'
        $bicep | Should -Match 'param globalFeedResourceGroupNameOverride string'
    }

    It 'does not create the operations resource group when every operations resource is adopted' {
        $bicep | Should -Match 'var deployOperationsResourceGroup = createSecretsKeyVault \|\| createEncryptionKeyVault \|\| createFSLogixBackupVault'
        $bicep | Should -Match "module operationsResourceGroup '.+' = if \(deployOperationsResourceGroup && empty\(consolidatedResourceGroupName\)\)"
    }

    It 'preserves updated workspace metadata and application-group references' {
        $workspaceModule | Should -Match 'existingWorkspace!\.properties\.applicationGroupReferences'
        $workspaceModule | Should -Match 'effectiveWorkspaceApplicationGroupReferences'
        $workspaceModule | Should -Match 'effectiveWorkspaceTags'
        $workspaceModule | Should -Match 'effectiveWorkspaceFriendlyName'
        $workspaceModule | Should -Match 'effectiveWorkspaceDescription'
    }

    It 'adds diagnostics only to newly created workspaces' {
        $workspaceModule | Should -Match 'param logAnalyticsWorkspaceResourceId string'
        $workspaceModule | Should -Match 'var workspaceDiagnosticSettings = !updateWorkspace && !empty\(logAnalyticsWorkspaceResourceId\)'
        $workspaceModule | Should -Match 'var globalWorkspaceDiagnosticSettings = !updateGlobalWorkspace && !empty\(logAnalyticsWorkspaceResourceId\)'
        $workspaceModule | Should -Match 'diagnosticSettings: workspaceDiagnosticSettings'
        $workspaceModule | Should -Match 'diagnosticSettings: globalWorkspaceDiagnosticSettings'
        $bicep | Should -Match 'logAnalyticsWorkspaceResourceId: effectiveLogAnalyticsWorkspaceResourceId'
    }

    It 'returns updated global workspaces without requiring a new private endpoint' {
        $workspaceModule | Should -Match 'output globalWorkspaceResourceId string = manageGlobalWorkspace'
        $workspaceModule | Should -Match ': globalWorkspaceResourceId'
        $workspaceModule | Should -Match "module globalFeedPrivateEndpoint '.+' = if \(manageGlobalWorkspace && !empty\(globalFeedPrivateEndpointSubnetResourceId\)\)"
        $workspaceModule | Should -Match 'output globalFeedPrivateEndpointResourceId string = manageGlobalWorkspace && !empty\(globalFeedPrivateEndpointSubnetResourceId\)'
    }

    It 'does not expose an ineffective global workspace public-access setting' {
        $workspaceModule | Should -Not -Match 'param globalWorkspacePublicNetworkAccess'
        $workspaceModule | Should -Match "publicNetworkAccess: 'Enabled'"
        $bicep | Should -Not -Match 'param globalAvdWorkspacePublicNetworkAccess'
        $formJson | Should -Not -Match 'globalWorkspacePublicNetworkAccess'
        $formJson | Should -Not -Match 'globalAvdWorkspacePublicNetworkAccess'
    }

    It 'honors the subscription in updated workspace resource IDs' {
        $workspaceModule | Should -Match "effectiveWorkspaceSubscriptionId = updateWorkspace \? split\(workspaceResourceId, '/'\)\[2\]"
        $workspaceModule | Should -Match 'scope: resourceGroup\(effectiveWorkspaceSubscriptionId, effectiveWorkspaceResourceGroupName\)'
        $workspaceModule | Should -Match "effectiveGlobalWorkspaceSubscriptionId = updateGlobalWorkspace"
        $workspaceModule | Should -Match 'scope: resourceGroup\(effectiveGlobalWorkspaceSubscriptionId, effectiveGlobalWorkspaceResourceGroupName\)'
    }

    It 'uses conditional endpoint virtual networks and their actual locations' {
        $workspaceModule | Should -Match "resource workspaceFeedVirtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = if"
        $workspaceModule | Should -Match "resource globalFeedVirtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = if"
        $workspaceModule | Should -Match 'location: workspaceFeedVirtualNetwork!\.location'
        $workspaceModule | Should -Match 'location: globalFeedVirtualNetwork!\.location'
        $workspaceModule | Should -Not -Match 'indexOf\('
    }

    It 'uses each selected subnet parent virtual network location for PaaS private endpoints' {
        $keyVaultModule | Should -Match "resource privateEndpointVirtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing"
        $keyVaultModule | Should -Match 'location: privateEndpointVirtualNetwork!\.location'
        $azureFilesModule | Should -Match "resource privateEndpointVirtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing"
        $azureFilesModule | Should -Match 'location: privateEndpointVirtualNetwork!\.location'
        $backupVaultModule | Should -Match "resource privateEndpointVirtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing"
        $backupVaultModule | Should -Match 'location: privateEndpointVirtualNetwork!\.location'
    }

    It 'maps every new form output to a Bicep parameter' {
        $parameterNames = @($bicep | Select-String -Pattern '(?m)^param\s+([A-Za-z0-9_]+)' -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value })
        foreach ($outputName in $form.view.outputs.parameters.PSObject.Properties.Name) {
            ($parameterNames -contains $outputName) | Should -Be $true
        }
    }

    It 'does not require a private endpoint virtual network to determine the backup vault region' {
        $vaultStart = $backupVaultModule.IndexOf('module recoveryServicesVault ')
        $vaultEnd = $backupVaultModule.IndexOf('module fileShareBackupPolicy ')
        $vaultBlock = $backupVaultModule.Substring($vaultStart, $vaultEnd - $vaultStart)
        $vaultBlock | Should -Match '(?m)^\s*location: location\s*$'
        $vaultBlock | Should -Not -Match 'privateEndpointVirtualNetwork'
    }

    It 'uses the subnet virtual network region only inside the conditional backup private endpoint' {
        $endpointStart = $backupVaultModule.IndexOf('module vaultPrivateEndpoint ')
        $endpointBlock = $backupVaultModule.Substring($endpointStart)
        $endpointBlock | Should -Match 'if \(createVault && privateEndpoint && !empty\(privateEndpointSubnetResourceId\) && !empty\(backupPrivateDnsZoneResourceId\)\)'
        $endpointBlock | Should -Match 'location: privateEndpointVirtualNetwork!\.location'
    }

    It 'embeds independent backup vault and private endpoint locations in all consuming templates' {
        foreach ($case in @(
            @{ Path = 'deployments\sharedServices\sharedServices.json'; Module = 'fslogixBackupVault' }
            @{ Path = 'deployments\hostpools\hostpool.json'; Module = 'sharedFilesBackup' }
            @{ Path = 'deployments\automatedHostPools\automatedHostPool.json'; Module = 'sharedFilesBackup' }
        )) {
            $template = Get-Content -LiteralPath (Join-Path $repoRoot $case.Path) -Raw | ConvertFrom-Json
            $backupTemplate = $template.resources.($case.Module).properties.template
            $backupTemplate.resources.recoveryServicesVault.properties.parameters.location.value |
                Should -Be "[parameters('location')]"
            $backupTemplate.resources.vaultPrivateEndpoint.properties.parameters.location.value |
                Should -Match 'privateEndpointVirtualNetwork'
        }
    }

    It 'separates AVD control-plane ownership, endpoints, and DNS into sections' {
        $controlPlaneStep = $form.view.properties.steps | Where-Object { $_.name -eq 'avdControlPlane' }
        $sectionNames = @($controlPlaneStep.elements | Where-Object {
            $_.type -eq 'Microsoft.Common.Section'
        } | ForEach-Object { $_.name })

        ($sectionNames -join ',') | Should -Be 'sharedWorkspace,workspaceFeedEndpoint,globalFeed,privateDns'
        $formJson | Should -Match "steps\('avdControlPlane'\)\.sharedWorkspace\.manageWorkspace"
        $formJson | Should -Match "steps\('avdControlPlane'\)\.workspaceFeedEndpoint\.manageFeedEndpoint"
        $formJson | Should -Match "steps\('avdControlPlane'\)\.globalFeed\.manageGlobalWorkspace"
        $formJson | Should -Match "steps\('avdControlPlane'\)\.privateDns\.enablePrivateDNSIntegration"
    }

    It 'limits workspace public access to feed endpoint management and supports shared DNS zones' {
        $outputs = $form.view.outputs.parameters
        $globalFeedDns = Get-CuiObjectBinding $outputs.privateDnsZoneResourceIds 'avdGlobalFeed'

        $outputs.avdWorkspacePublicNetworkAccess |
            Should -Match "workspaceFeedEndpoint\.manageFeedEndpoint"
        $globalFeedDns |
            Should -Match "reuseFeedPrivateDnsZoneForGlobalFeed"
        $globalFeedDns |
            Should -Match "privateDns\.feedPrivateDnsZone\.id"
        $globalFeedDns |
            Should -Match "privateDns\.globalPrivateDnsZone\.id"
    }

    It 'uses update for existing workspace management throughout the deployment contract' {
        $formJson | Should -Match '"label": "Update an existing workspace"'
        $formJson | Should -Match '"label": "Update an existing global-feed workspace"'
        ([regex]::Matches($formJson, '"value": "Update"').Count) | Should -Be 2
        $formJson | Should -Not -Match '"value": "Adopt"'
        $bicep | Should -Not -Match "'Adopt'"
        $workspaceModule | Should -Not -Match "'Adopt'"
    }

    It 'documents the shared owner and host-pool consumer contract' {
        $readme | Should -Match 'dedicated AVD'
        $readme | Should -Match 'existingFeedWorkspaceResourceId'
        $readme | Should -Match 'application group'
        $formJson | Should -Match 'Existing application group references'
    }
}
