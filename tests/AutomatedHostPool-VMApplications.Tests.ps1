$repoRoot = Split-Path -Parent $PSScriptRoot
$formPath = Join-Path $repoRoot 'deployments\automatedHostPools\uiFormDefinition.json'
$policyPath = Join-Path $repoRoot 'deployments\automatedHostPools\policy\main.bicep'
$entryTemplatePath = Join-Path $repoRoot 'deployments\automatedHostPools\automatedHostPool.bicep'
$controlPlanePath = Join-Path $repoRoot 'deployments\automatedHostPools\modules\controlPlane.bicep'
$permissionsPath = Join-Path $repoRoot 'deployments\automatedHostPools\modules\permissions.bicep'

Describe 'Automated host-pool VM Application assignments' {
    BeforeAll {
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $basicsStep = $form.view.properties.steps | Where-Object { $_.name -eq 'basics' }
        $controlPlaneStep = $form.view.properties.steps | Where-Object { $_.name -eq 'controlPlane' }
        $hostsStep = $form.view.properties.steps | Where-Object { $_.name -eq 'hosts' }
        $sessionHostLocation = $hostsStep.elements | Where-Object { $_.name -eq 'location' }
        $resourceSkusApi = $hostsStep.elements | Where-Object { $_.name -eq 'resourceSkusApi' }
        $availability = $hostsStep.elements | Where-Object { $_.name -eq 'availability' }
        $vmApplications = $hostsStep.elements | Where-Object { $_.name -eq 'vmApplications' }
        $applicationsApi = $vmApplications.elements | Where-Object { $_.name -eq 'applicationsApi' }
        $applicationsGrid = $vmApplications.elements | Where-Object { $_.name -eq 'applications' }
        $policySource = Get-Content -LiteralPath $policyPath -Raw
        $entryTemplateSource = Get-Content -LiteralPath $entryTemplatePath -Raw
        $controlPlaneSource = Get-Content -LiteralPath $controlPlanePath -Raw
        $permissionsSource = Get-Content -LiteralPath $permissionsPath -Raw
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

    It 'excludes subscription-restricted zones from availability choices' {
        $resourceSkusApi.request.transforms.vmSizes | Should Match 'zones:locationInfo\[0\]\.zones'
        $resourceSkusApi.request.transforms.vmSizes | Should Match "restrictedZones:restrictions\[\?type == 'Zone'\]\.restrictionInfo\.zones"
        $availabilityOption = $availability.elements | Where-Object { $_.name -eq 'option' }
        $availabilityZones = $availability.elements | Where-Object { $_.name -eq 'availabilityZones' }
        $availabilityOption.defaultValue | Should Match 'sku\.restrictedZones'
        $availabilityOption.constraints.allowedValues | Should Match 'sku\.restrictedZones'
        $availabilityZones.defaultValue | Should Match 'sku\.restrictedZones'
        $availabilityZones.constraints.allowedValues | Should Match 'sku\.restrictedZones'
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

    It 'grants the host-pool identity gallery-scoped Reader access before host creation' {
        $entryTemplateSource | Should Match 'sessionHostVmApplications: sessionHostVmApplications'
        $controlPlaneSource | Should Match 'sessionHostVmApplications: sessionHostVmApplications'
        $permissionsSource | Should Match 'var vmApplicationGalleryResourceIds = union\(map\('
        $permissionsSource | Should Match "lastIndexOf\(toLower\(application.packageReferenceId\), '/applications/'\)"
        $permissionsSource | Should Match "var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'"
        $permissionsSource | Should Match "module vmApplicationGalleryReaderRoles '.+/compute/galleries/roleAssignment.bicep'"
        $permissionsSource | Should Match "galleryName: last\(split\(galleryResourceId, '/'\)\)"
        $controlPlaneSource | Should Match 'module sessionHostConfiguration[\s\S]+dependsOn: \[hostPoolPermissions\]'
    }
}