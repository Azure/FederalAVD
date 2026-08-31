$repoRoot = Split-Path -Parent $PSScriptRoot
$formPath = Join-Path $repoRoot 'deployments\automatedHostPools\uiFormDefinition.json'
$policyPath = Join-Path $repoRoot 'deployments\automatedHostPools\policy\main.bicep'

Describe 'Automated host-pool VM Application assignments' {
    BeforeAll {
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $basicsStep = $form.view.properties.steps | Where-Object { $_.name -eq 'basics' }
        $controlPlaneStep = $form.view.properties.steps | Where-Object { $_.name -eq 'controlPlane' }
        $hostsStep = $form.view.properties.steps | Where-Object { $_.name -eq 'hosts' }
        $sessionHostLocation = $hostsStep.elements | Where-Object { $_.name -eq 'location' }
        $vmApplications = $hostsStep.elements | Where-Object { $_.name -eq 'vmApplications' }
        $applicationsApi = $vmApplications.elements | Where-Object { $_.name -eq 'applicationsApi' }
        $applicationsGrid = $vmApplications.elements | Where-Object { $_.name -eq 'applications' }
        $policySource = Get-Content -LiteralPath $policyPath -Raw
    }

    It 'uses one deployment subscription selected on Basics' {
        @($basicsStep.elements | Where-Object { $_.name -eq 'subscription' }).Count | Should Be 1
        @($controlPlaneStep.elements | ForEach-Object { @($_.elements) } | Where-Object { $_.name -eq 'subscription' }).Count | Should Be 0
        (Get-Content -LiteralPath $formPath -Raw) | Should Not Match "steps\('controlPlane'\)\.scope\.subscription"
    }

    It 'uses a top-level Control Plane location as the Session Host default' {
        @($controlPlaneStep.elements | Where-Object { $_.name -eq 'controlPlaneLocation' }).Count | Should Be 1
        @($controlPlaneStep.elements | Where-Object { $_.name -eq 'scope' }).Count | Should Be 0
        $sessionHostLocation.defaultValue | Should Be "[steps('controlPlane').controlPlaneLocation.displayName]"
        (Get-Content -LiteralPath $formPath -Raw) | Should Not Match "steps\('controlPlane'\)\.scope\.controlPlaneLocation"
    }

    It 'offers latest Gallery application version references from ARM' {
        $applicationsApi.condition | Should Be "[and(equals(steps('hosts').vmApplications.enableVmApplications, true), not(empty(steps('hosts').vmApplications.gallery)))]"
        $applicationsApi.request.method | Should Be 'GET'
        $applicationsApi.request.path | Should Match '/applications\?api-version=2024-03-03'
        $applicationsApi.request.transforms.list | Should Be 'value|[*].{label:name, value:id}'
        $applicationsGrid.constraints.columns[0].element.constraints.allowedValues | Should Match "steps\('hosts'\)\.vmApplications\.applicationsApi\.transformed\.list"
        $applicationsGrid.constraints.columns[0].element.constraints.allowedValues | Should Match '/versions/latest'
        $form.view.outputs.parameters.sessionHostVmApplications | Should Be "[steps('hosts').vmApplications.applications]"
        $form.view.outputs.parameters.sessionHostVmApplications | Should Not Match 'applicationsApi'
    }

    It 'shows a schema-compliant multi-row grid only when VM Applications are selected' {
        $applicationsGrid.visible | Should Be "[equals(steps('hosts').vmApplications.enableVmApplications, true)]"
        $applicationsGrid.constraints.rows.count.min | Should Be 1
        $applicationsGrid.constraints.rows.count.max | Should Be 25
        @($applicationsGrid.constraints.columns[0].element.PSObject.Properties.Name) -notcontains 'multiLine' | Should Be $true
        $applicationsGrid.constraints.columns[1].element.type | Should Be 'Microsoft.Common.DropDown'
        @($applicationsGrid.constraints.columns[1].element.constraints.allowedValues.value) | Should Be (1..25)
        @($applicationsGrid.constraints.columns[2].element.PSObject.Properties.Name) -notcontains 'toolTip' | Should Be $true
        @($applicationsGrid.constraints.columns[2].element.PSObject.Properties.Name) -notcontains 'defaultValue' | Should Be $true
        @($vmApplications.elements | Where-Object { $_.name -eq 'noApplicationsInfo' }).Count | Should Be 0
    }

    It 'preserves the policy assignment object contract' {
        @($applicationsGrid.constraints.columns.id) | Should Be @(
            'packageReferenceId'
            'order'
            'treatFailureAsDeploymentFailure'
        )
    }

    It 'accepts version paths and rejects duplicate application definitions in Bicep' {
        $policySource | Should Match "contains\(toLower\(application.packageReferenceId\), '/versions/'\)"
        $policySource | Should Match "lastIndexOf\(toLower\(application.packageReferenceId\), '/versions/'\)"
        $policySource | Should Match 'cannot contain more than one version of the same application'
    }
}