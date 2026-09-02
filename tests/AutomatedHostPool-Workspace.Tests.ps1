$repoRoot = Split-Path -Parent $PSScriptRoot
$formPath = Join-Path $repoRoot 'deployments\automatedHostPools\uiFormDefinition.json'

Describe 'Automated host-pool workspace selection' {
    BeforeAll {
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $controlPlaneStep = $form.view.properties.steps | Where-Object { $_.name -eq 'controlPlane' }
        $workspaceSection = $controlPlaneStep.elements | Where-Object { $_.name -eq 'workspace' }
        $workspaceCreateOption = $workspaceSection.elements | Where-Object { $_.name -eq 'createOption' }
        $existingWorkspace = $workspaceSection.elements | Where-Object { $_.name -eq 'existingWorkspace' }
        $existingWorkspaceOutput = $form.view.outputs.parameters.existingFeedWorkspaceResourceId
    }

    It 'offers workspace resource IDs as dropdown values' {
        $existingWorkspace.constraints.allowedValues | Should Match '"value":"'
        $existingWorkspace.constraints.allowedValues | Should Match 'vdws\.id'
    }

    It 'uses the standard host-pool update option contract' {
        $workspaceCreateOption.defaultValue | Should Be 'Update an existing Workspace'
        $workspaceCreateOption.constraints.required | Should Be $true
        ($workspaceCreateOption.constraints.allowedValues | Where-Object { $_.value -eq 'update' }).Count | Should Be 1
        $existingWorkspace.visible | Should Match "workspace\.createOption, 'update'"
    }

    It 'outputs the selected workspace exactly like the standard host-pool form' {
        $existingWorkspace.PSObject.Properties.Name | Should Not Match 'defaultValue'
        $existingWorkspaceOutput | Should Be "[if(equals(steps('controlPlane').workspace.createOption, 'update'), steps('controlPlane').workspace.existingWorkspace, '')]"
        $existingWorkspaceOutput | Should Not Match 'workspacesApi'
    }

    It 'matches the standard host-pool workspace parameter name' {
        ($form.view.outputs.parameters.PSObject.Properties.Name -join ',') | Should Match '(^|,)existingFeedWorkspaceResourceId(,|$)'
    }
}