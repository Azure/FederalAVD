$repoRoot = Split-Path -Parent $PSScriptRoot
$bicepPath = Join-Path $repoRoot 'deployments\sharedServices\sharedServices.bicep'
$armPath = Join-Path $repoRoot 'deployments\sharedServices\sharedServices.json'
$formPath = Join-Path $repoRoot 'deployments\sharedServices\uiFormDefinition.json'
$workspaceModulePath = Join-Path $repoRoot 'deployments\shared\modules\orchestration\avdWorkspace\avdWorkspace.bicep'
$readmePath = Join-Path $repoRoot 'deployments\sharedServices\README.md'

Describe 'Shared Services AVD workspace ownership' {
    BeforeAll {
        $bicep = Get-Content -LiteralPath $bicepPath -Raw
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $formJson = Get-Content -LiteralPath $formPath -Raw
        $workspaceModule = Get-Content -LiteralPath $workspaceModulePath -Raw
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

    It 'preserves adopted workspace metadata and application-group references' {
        $workspaceModule | Should Match 'existingWorkspace!\.properties\.applicationGroupReferences'
        $workspaceModule | Should Match 'effectiveWorkspaceApplicationGroupReferences'
        $workspaceModule | Should Match 'effectiveWorkspaceTags'
        $workspaceModule | Should Match 'effectiveWorkspaceFriendlyName'
        $workspaceModule | Should Match 'effectiveWorkspaceDescription'
    }

    It 'honors the subscription in adopted workspace resource IDs' {
        $workspaceModule | Should Match "effectiveWorkspaceSubscriptionId = adoptWorkspace \? split\(workspaceResourceId, '/'\)\[2\]"
        $workspaceModule | Should Match 'scope: resourceGroup\(effectiveWorkspaceSubscriptionId, effectiveWorkspaceResourceGroupName\)'
        $workspaceModule | Should Match "effectiveGlobalWorkspaceSubscriptionId = adoptGlobalWorkspace"
        $workspaceModule | Should Match 'scope: resourceGroup\(effectiveGlobalWorkspaceSubscriptionId, effectiveGlobalWorkspaceResourceGroupName\)'
    }

    It 'deduplicates endpoint virtual networks and uses their actual locations' {
        $workspaceModule | Should Match 'var privateEndpointVirtualNetworkResourceIds = union\('
        $workspaceModule | Should Match "resource privateEndpointVirtualNetworks 'Microsoft.Network/virtualNetworks@2024-05-01' existing = \["
        $workspaceModule | Should Match 'privateEndpointVirtualNetworks\[indexOf\('
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
