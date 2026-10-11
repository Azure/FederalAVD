$repoRoot = Split-Path -Parent $PSScriptRoot
$bicepPath = Join-Path $repoRoot 'deployments\sharedServices\sharedServices.bicep'
$armPath = Join-Path $repoRoot 'deployments\sharedServices\sharedServices.json'
$formPath = Join-Path $repoRoot 'deployments\sharedServices\uiFormDefinition.json'
$workspaceModulePath = Join-Path $repoRoot 'deployments\shared\modules\orchestration\avdWorkspace\avdWorkspace.bicep'
$keyVaultModulePath = Join-Path $repoRoot 'deployments\shared\modules\orchestration\keyVaults\keyVaults.bicep'
$azureFilesModulePath = Join-Path $repoRoot 'deployments\shared\modules\orchestration\fslogix\modules\azureFiles.bicep'
$backupVaultModulePath = Join-Path $repoRoot 'deployments\shared\modules\resourceModules\recoveryServices\fslogixBackupVault.bicep'
$readmePath = Join-Path $repoRoot 'deployments\sharedServices\README.md'

Describe 'Shared Services AVD workspace ownership' {
    BeforeAll {
        $bicep = Get-Content -LiteralPath $bicepPath -Raw
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $formJson = Get-Content -LiteralPath $formPath -Raw
        $workspaceModule = Get-Content -LiteralPath $workspaceModulePath -Raw
        $keyVaultModule = Get-Content -LiteralPath $keyVaultModulePath -Raw
        $azureFilesModule = Get-Content -LiteralPath $azureFilesModulePath -Raw
        $backupVaultModule = Get-Content -LiteralPath $backupVaultModulePath -Raw
        $readme = Get-Content -LiteralPath $readmePath -Raw
    }

    It 'creates or adopts a shared workspace and exposes downstream outputs' {
        $bicep | Should Match 'param manageAvdWorkspace bool = false'
        $bicep | Should Match "param avdWorkspaceMode string = 'Create'"
        $bicep | Should Match 'param existingAvdWorkspaceResourceId string'
        $bicep | Should Match 'output avdWorkspaceResourceId string'
        $bicep | Should Match 'output workspaceFeedPrivateEndpointResourceId string'
        $bicep | Should Match 'output globalFeedWorkspaceResourceId string'
        $bicep | Should Match 'output globalFeedPrivateEndpointResourceId string'
    }

    It 'returns effective IDs for created or adopted shared resources' {
        $bicep | Should Match 'param existingLogAnalyticsWorkspaceResourceId string'
        $bicep | Should Match 'param existingAVDInsightsDataCollectionRuleResourceId string'
        $bicep | Should Match 'param existingDataCollectionEndpointResourceId string'
        $bicep | Should Match 'param existingSecretsKeyVaultResourceId string'
        $bicep | Should Match 'param existingEncryptionKeyVaultResourceId string'
        $bicep | Should Match 'param existingFSLogixBackupVaultResourceId string'
        $bicep | Should Match 'param existingFSLogixBackupPolicyName string'
        $bicep | Should Match 'output logAnalyticsWorkspaceResourceId string'
        $bicep | Should Match 'output avdInsightsDataCollectionRuleResourceId string'
        $bicep | Should Match 'output dataCollectionEndpointResourceId string'
        $bicep | Should Match 'output secretsKeyVaultResourceId string'
        $bicep | Should Match 'output encryptionKeyVaultResourceId string'
        $bicep | Should Match 'output fslogixBackupVaultResourceId string'
        $bicep | Should Match 'output fslogixBackupPolicyResourceId string'
    }

    It 'supports host-pool-specific PoC naming without duplicating shared-resource orchestration' {
        $bicep | Should Match 'param avdWorkspaceNameOverride string'
        $bicep | Should Match 'param avdControlPlaneResourceGroupNameOverride string'
        $bicep | Should Match 'param globalFeedWorkspaceNameOverride string'
        $bicep | Should Match 'param globalFeedResourceGroupNameOverride string'
    }

    It 'does not create the operations resource group when every operations resource is adopted' {
        $bicep | Should Match 'var deployOperationsResourceGroup = createSecretsKeyVault \|\| createEncryptionKeyVault \|\| createFSLogixBackupVault'
        $bicep | Should Match "module operationsResourceGroup '.+' = if \(deployOperationsResourceGroup && empty\(consolidatedResourceGroupName\)\)"
    }

    It 'preserves adopted workspace metadata and application-group references' {
        $workspaceModule | Should Match 'existingWorkspace!\.properties\.applicationGroupReferences'
        $workspaceModule | Should Match 'effectiveWorkspaceApplicationGroupReferences'
        $workspaceModule | Should Match 'effectiveWorkspaceTags'
        $workspaceModule | Should Match 'effectiveWorkspaceFriendlyName'
        $workspaceModule | Should Match 'effectiveWorkspaceDescription'
    }

    It 'adds diagnostics only to newly created workspaces' {
        $workspaceModule | Should Match 'param logAnalyticsWorkspaceResourceId string'
        $workspaceModule | Should Match 'var workspaceDiagnosticSettings = !adoptWorkspace && !empty\(logAnalyticsWorkspaceResourceId\)'
        $workspaceModule | Should Match 'var globalWorkspaceDiagnosticSettings = !adoptGlobalWorkspace && !empty\(logAnalyticsWorkspaceResourceId\)'
        $workspaceModule | Should Match 'diagnosticSettings: workspaceDiagnosticSettings'
        $workspaceModule | Should Match 'diagnosticSettings: globalWorkspaceDiagnosticSettings'
        $bicep | Should Match 'logAnalyticsWorkspaceResourceId: effectiveLogAnalyticsWorkspaceResourceId'
    }

    It 'returns adopted global workspaces without requiring a new private endpoint' {
        $workspaceModule | Should Match 'output globalWorkspaceResourceId string = manageGlobalWorkspace'
        $workspaceModule | Should Match ': globalWorkspaceResourceId'
        $workspaceModule | Should Match "module globalFeedPrivateEndpoint '.+' = if \(manageGlobalWorkspace && !empty\(globalFeedPrivateEndpointSubnetResourceId\)\)"
        $workspaceModule | Should Match 'output globalFeedPrivateEndpointResourceId string = manageGlobalWorkspace && !empty\(globalFeedPrivateEndpointSubnetResourceId\)'
    }

    It 'honors the subscription in adopted workspace resource IDs' {
        $workspaceModule | Should Match "effectiveWorkspaceSubscriptionId = adoptWorkspace \? split\(workspaceResourceId, '/'\)\[2\]"
        $workspaceModule | Should Match 'scope: resourceGroup\(effectiveWorkspaceSubscriptionId, effectiveWorkspaceResourceGroupName\)'
        $workspaceModule | Should Match "effectiveGlobalWorkspaceSubscriptionId = adoptGlobalWorkspace"
        $workspaceModule | Should Match 'scope: resourceGroup\(effectiveGlobalWorkspaceSubscriptionId, effectiveGlobalWorkspaceResourceGroupName\)'
    }

    It 'uses conditional endpoint virtual networks and their actual locations' {
        $workspaceModule | Should Match "resource workspaceFeedVirtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = if"
        $workspaceModule | Should Match "resource globalFeedVirtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = if"
        $workspaceModule | Should Match 'location: workspaceFeedVirtualNetwork!\.location'
        $workspaceModule | Should Match 'location: globalFeedVirtualNetwork!\.location'
        $workspaceModule | Should Not Match 'indexOf\('
    }

    It 'uses each selected subnet parent virtual network location for PaaS private endpoints' {
        $keyVaultModule | Should Match "resource privateEndpointVirtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing"
        $keyVaultModule | Should Match 'location: privateEndpointVirtualNetwork!\.location'
        $azureFilesModule | Should Match "resource privateEndpointVirtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing"
        $azureFilesModule | Should Match 'location: privateEndpointVirtualNetwork!\.location'
        $backupVaultModule | Should Match "resource privateEndpointVirtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing"
        $backupVaultModule | Should Match 'location: privateEndpointVirtualNetwork!\.location'
    }

    It 'maps every new form output to a Bicep parameter' {
        $parameterNames = @($bicep | Select-String -Pattern '(?m)^param\s+([A-Za-z0-9_]+)' -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value })
        foreach ($outputName in $form.view.outputs.parameters.PSObject.Properties.Name) {
            ($parameterNames -contains $outputName) | Should Be $true
        }
    }

    It 'documents the shared owner and host-pool consumer contract' {
        $readme | Should Match 'dedicated AVD'
        $readme | Should Match 'existingFeedWorkspaceResourceId'
        $readme | Should Match 'application group'
        $formJson | Should Match 'Adoption preserves every existing application group reference'
    }
}
