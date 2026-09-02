$repoRoot = Split-Path -Parent $PSScriptRoot
$standardFormPath = Join-Path $repoRoot 'deployments\hostpools\uiFormDefinition.json'
$automatedFormPath = Join-Path $repoRoot 'deployments\automatedHostPools\uiFormDefinition.json'
$automatedBicepPath = Join-Path $repoRoot 'deployments\automatedHostPools\automatedHostPool.bicep'

Describe 'Common host-pool UI form behavior' {
    BeforeAll {
        $standardForm = Get-Content -LiteralPath $standardFormPath -Raw | ConvertFrom-Json
        $automatedForm = Get-Content -LiteralPath $automatedFormPath -Raw | ConvertFrom-Json
        $automatedBicep = Get-Content -LiteralPath $automatedBicepPath -Raw
        $standardFormJson = Get-Content -LiteralPath $standardFormPath -Raw

        $standardControlPlane = $standardForm.view.properties.steps | Where-Object { $_.name -eq 'controlPlane' }
        $standardWorkspaceApi = $standardControlPlane.elements | Where-Object { $_.name -eq 'workspacesApi' }
        $standardWorkspaceSection = $standardControlPlane.elements | Where-Object { $_.name -eq 'workspace' }
        $standardExistingWorkspace = $standardWorkspaceSection.elements | Where-Object { $_.name -eq 'existingWorkspace' }
        $standardOutputs = $standardForm.view.outputs.parameters

        $automatedControlPlane = $automatedForm.view.properties.steps | Where-Object { $_.name -eq 'controlPlane' }
        $automatedWorkspaceSection = $automatedControlPlane.elements | Where-Object { $_.name -eq 'workspace' }
        $automatedExistingWorkspace = $automatedWorkspaceSection.elements | Where-Object { $_.name -eq 'existingWorkspace' }

        $automatedProfiles = $automatedForm.view.properties.steps | Where-Object { $_.name -eq 'profiles' }
        $automatedStorage = $automatedProfiles.elements | Where-Object { $_.name -eq 'storage' }
        $automatedStorageService = $automatedStorage.elements | Where-Object { $_.name -eq 'service' }

        $automatedOperations = $automatedForm.view.properties.steps | Where-Object { $_.name -eq 'operationsAndMonitoring' }
        $automatedMonitoring = $automatedOperations.elements | Where-Object { $_.name -eq 'monitoring' }
        $automatedEnableMonitoring = $automatedMonitoring.elements | Where-Object { $_.name -eq 'enableMonitoring' }

        $automatedProfiles = $automatedForm.view.properties.steps | Where-Object { $_.name -eq 'profiles' }
        $entraKerberosInfoBox = $automatedProfiles.elements | Where-Object { $_.name -eq 'entraKerberosInfoBox' }
    }

    It 'outputs a selected standard workspace without rechecking API results' {
        $standardOutputs.existingFeedWorkspaceResourceId | Should Be "[if(equals(steps('controlPlane').workspace.createOption, 'update'), steps('controlPlane').workspace.existingWorkspace, '')]"
        $standardOutputs.workspaceFriendlyName | Should Be "[if(equals(steps('controlPlane').workspace.createOption, 'update'), '', steps('controlPlane').naming.workspaceFriendlyName)]"
        $standardOutputs.existingFeedWorkspaceResourceId | Should Not Match 'workspacesApi'
    }

    It 'requires an explicit existing workspace selection in both forms' {
        $standardExistingWorkspace.PSObject.Properties.Name | Should Not Match 'defaultValue'
        $automatedExistingWorkspace.PSObject.Properties.Name | Should Not Match 'defaultValue'
        $standardExistingWorkspace.constraints.required | Should Be $true
        $automatedExistingWorkspace.constraints.required | Should Be $true
    }

    It 'uses the current workspace list API in the standard form' {
        $standardWorkspaceApi.request.path | Should Match 'api-version=2024-04-03'
        $standardWorkspaceApi.request.path | Should Not Match '2022-02-10-preview'
    }

    It 'matches the selected standard VM SKU exactly for capabilities and zones' {
        $standardFormJson | Should Not Match "\(sku\) => contains\(sku\.name, if\(equals\(steps\('hosts'\)\.security\.securityType"
        $standardFormJson | Should Match "\(sku\) => equals\(sku\.name, if\(equals\(steps\('hosts'\)\.security\.securityType"
    }

    It 'enables automated AVD Insights monitoring by default' {
        $automatedEnableMonitoring.defaultValue | Should Be $true
    }

    It 'defaults automated FSLogix storage to Azure Files Premium' {
        $automatedStorageService.defaultValue | Should Be 'Azure Files Premium'
        $automatedForm.view.outputs.parameters.fslogixStorageService | Should Match "'AzureFiles Premium'"
        $automatedBicep | Should Match "param fslogixStorageService string = 'AzureFiles Premium'"
    }

    It 'links automated Entra Kerberos guidance to the selected identity model' {
        $entraKerberosInfoBox.options.uri | Should Match 'EntraKerberos-CloudOnly'
        $entraKerberosInfoBox.options.uri | Should Match 'entra-kerberos-cloud-only\.md'
        $entraKerberosInfoBox.options.uri | Should Match 'entra-kerberos-hybrid\.md'
    }
}
