$repoRoot = Split-Path -Parent $PSScriptRoot

Describe 'Explicit standard host-pool locations' {
    BeforeAll {
        $source = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\hostpools\hostpool.bicep') -Raw
        $template = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\hostpools\hostpool.json') -Raw | ConvertFrom-Json
        $form = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\hostpools\uiFormDefinition.json') -Raw | ConvertFrom-Json
        $hosts = $form.view.properties.steps | Where-Object name -eq 'hosts'
        $scope = $hosts.elements | Where-Object name -eq 'scope'
        $location = $scope.elements | Where-Object name -eq 'location'
        $network = $hosts.elements | Where-Object name -eq 'network'
        $virtualNetwork = $network.elements | Where-Object name -eq 'virtualNetwork'
    }

    It 'defaults VM location to control-plane location and control-plane location to deployment location' {
        $template.parameters.controlPlaneLocation.defaultValue | Should Be '[deployment().location]'
        $template.parameters.virtualMachinesLocation.defaultValue | Should Be "[parameters('controlPlaneLocation')]"
        $template.parameters.controlPlaneLocation.minLength | Should Be 1
        $template.parameters.virtualMachinesLocation.minLength | Should Be 1
    }

    It 'passes both selected form locations and preserves a label-based VM-location default' {
        $form.view.outputs.parameters.controlPlaneLocation | Should Be "[steps('controlPlane').scope.location.name]"
        $form.view.outputs.parameters.virtualMachinesLocation | Should Be "[steps('hosts').scope.location.name]"
        $location.defaultValue | Should Be "[steps('controlPlane').scope.location.displayName]"
        $location.constraints.required | Should Be $true
        $location.constraints.allowedValues | Should Be "[steps('hosts').scope.locationsApi.transformed.list]"
    }

    It 'keeps the VNet selector restricted to the selected VM location' {
        $virtualNetwork.constraints.allowedValues | Should Match ([regex]::Escape("equals(vnet.location, steps('hosts').scope.location.name)"))
    }

    It 'uses the explicit VM location for actual compute, storage, encryption and helper placement' {
        foreach ($module in @(
            'hostsResourceGroup', 'storageResourceGroup', 'deploymentResourceGroup',
            'deploymentHelper', 'virtualMachinesDiskCmk', 'cvmDiskCmk', 'storageCmk',
            'fslogix', 'diskAccess', 'sessionHosts', 'cleanupDeploymentHelper'
        )) {
            $template.resources.$module.properties.parameters.location.value | Should Be "[parameters('virtualMachinesLocation')]"
        }
        $template.resources.controlPlane.properties.parameters.virtualMachinesRegion.value | Should Be "[parameters('virtualMachinesLocation')]"
    }

    It 'uses the independent control-plane location for shared resources and the AVD control plane' {
        foreach ($module in @(
            'sharedMonitoring', 'sharedFilesBackup', 'sharedOperationsResourceGroup',
            'sharedMonitoringResourceGroup', 'controlPlaneResourceGroup'
        )) {
            $template.resources.$module.properties.parameters.location.value | Should Be "[parameters('controlPlaneLocation')]"
        }
        $template.resources.sharedAvdWorkspace.properties.parameters.workspaceLocation.value | Should Be "[parameters('controlPlaneLocation')]"
        $template.resources.controlPlane.properties.parameters.controlPlaneRegion.value | Should Be "[parameters('controlPlaneLocation')]"
    }

    It 'passes the same explicit locations to centralized naming without a VNet lookup or naming deployment' {
        $source | Should Not Match 'vmVirtualNetwork|var virtualMachinesRegion|effectiveControlPlaneRegion|module naming '
        $template.variables.naming | Should Match ([regex]::Escape("'virtualMachinesLocation', parameters('virtualMachinesLocation')"))
        $template.variables.naming | Should Match ([regex]::Escape("'controlPlaneLocation', parameters('controlPlaneLocation')"))
        ($template.resources.PSObject.Properties.Name -contains 'naming') | Should Be $false
    }

    It 'maps every form output to an existing deployment parameter' {
        foreach ($parameter in $form.view.outputs.parameters.PSObject.Properties) {
            ($template.parameters.PSObject.Properties.Name -contains $parameter.Name) | Should Be $true
        }
    }

    It 'records an explicit VM location in each standard host-pool parameter sample' {
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $repoRoot 'deployments\hostpools\parameters') -Filter '*.parameters.json') {
            $sample = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            [string]::IsNullOrWhiteSpace($sample.parameters.virtualMachinesLocation.value) | Should Be $false
            $sample.parameters.virtualMachinesLocation.value | Should Be $sample.parameters.controlPlaneLocation.value
        }
    }
}
