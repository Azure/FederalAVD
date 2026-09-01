$repoRoot = Split-Path -Parent $PSScriptRoot
$sharedPolicyPath = Join-Path $repoRoot 'deployments\shared\modules\orchestration\sessionHostPolicy\vmApplications.bicep'
$sharedDefinitionPath = Join-Path $repoRoot 'deployments\shared\modules\orchestration\sessionHostPolicy\modules\vmApplications.policyDefinition.bicep'
$sharedMonitoringPath = Join-Path $repoRoot 'deployments\shared\modules\orchestration\sessionHostPolicy\monitoring.bicep'
$sharedGuestAttestationPath = Join-Path $repoRoot 'deployments\shared\modules\orchestration\sessionHostPolicy\guestAttestation.bicep'
$sharedManagedDiskPath = Join-Path $repoRoot 'deployments\shared\modules\orchestration\sessionHostPolicy\managedDiskNetworkAccess.bicep'
$sharedAuthoringPath = Join-Path $repoRoot 'deployments\shared\modules\orchestration\sessionHostPolicy\AUTHORING.md'
$automatedPolicyPath = Join-Path $repoRoot 'deployments\automatedHostPools\policy\main.bicep'
$addOnPath = Join-Path $repoRoot 'deployments\add-ons\sessionHostPolicy\main.bicep'
$formPath = Join-Path $repoRoot 'deployments\add-ons\sessionHostPolicy\uiFormDefinition.json'
$examplePath = Join-Path $repoRoot 'customer-examples\parameters\add-ons\sessionHostPolicy.parameters.json'
$templateSpecsPath = Join-Path $repoRoot 'tools\New-TemplateSpecs.ps1'

Describe 'Shared session-host policy orchestration' {
    BeforeAll {
        $sharedPolicy = Get-Content -LiteralPath $sharedPolicyPath -Raw
        $sharedDefinition = Get-Content -LiteralPath $sharedDefinitionPath -Raw
        $sharedMonitoring = Get-Content -LiteralPath $sharedMonitoringPath -Raw
        $sharedGuestAttestation = Get-Content -LiteralPath $sharedGuestAttestationPath -Raw
        $sharedManagedDisk = Get-Content -LiteralPath $sharedManagedDiskPath -Raw
        $sharedAuthoring = Get-Content -LiteralPath $sharedAuthoringPath -Raw
        $automatedPolicy = Get-Content -LiteralPath $automatedPolicyPath -Raw
        $addOn = Get-Content -LiteralPath $addOnPath -Raw
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $example = Get-Content -LiteralPath $examplePath -Raw | ConvertFrom-Json
        $templateSpecs = Get-Content -LiteralPath $templateSpecsPath -Raw
    }

    It 'has one shared VM Application policy definition source' {
        $sharedDefinition | Should Match "param policyDefinitionName string = 'avdSessionHostVmApplication-Modify'"
        @(
            Get-ChildItem -LiteralPath (Join-Path $repoRoot 'deployments') -Filter 'sessionHostVmApplication.policyDefinition.bicep' -Recurse
        ).Count | Should Be 0
        @(
            Get-ChildItem -LiteralPath (Join-Path $repoRoot 'deployments') -Filter 'vmApplications.policyDefinition.bicep' -Recurse
        ).Count | Should Be 1
    }

    It 'uses the shared orchestration from automated and standalone entry points' {
        $automatedPolicy | Should Match "shared/modules/orchestration/sessionHostPolicy/vmApplications.bicep"
        $addOn | Should Match "shared/modules/orchestration/sessionHostPolicy/vmApplications.bicep"
        $automatedPolicy | Should Match "shared/modules/orchestration/sessionHostPolicy/monitoring.bicep"
        $addOn | Should Match "shared/modules/orchestration/sessionHostPolicy/monitoring.bicep"
        $automatedPolicy | Should Match "shared/modules/orchestration/sessionHostPolicy/guestAttestation.bicep"
        $addOn | Should Match "shared/modules/orchestration/sessionHostPolicy/guestAttestation.bicep"
        $automatedPolicy | Should Match "shared/modules/orchestration/sessionHostPolicy/modules/managedDiskNetworkAccess.policyDefinition.bicep"
        $addOn | Should Match "shared/modules/orchestration/sessionHostPolicy/managedDiskNetworkAccess.bicep"
        $automatedPolicy | Should Match 'sessionHostVmApplicationPolicyAssignmentResourceId'
    }

    It 'has one shared source for each extracted policy definition' {
        $expectedDefinitions = @(
            'azureMonitorAgent.policyDefinition.bicep'
            'configureSessionHost.policyDefinition.bicep'
            'guestAttestation.policyDefinition.bicep'
            'managedDiskNetworkAccess.policyDefinition.bicep'
            'monitoringAssociation.policyDefinition.bicep'
            'networkInterfaceAcceleratedNetworking.policyDefinition.bicep'
            'privateCustomization.policyDefinition.bicep'
            'sessionHostCompute.policyDefinition.bicep'
            'systemAssignedIdentity.policyDefinition.bicep'
            'virtualMachine-diskEncryptionSet.policyDefinition.bicep'
            'vmApplications.policyDefinition.bicep'
        )

        foreach ($definition in $expectedDefinitions) {
            @(
                Get-ChildItem -LiteralPath (Join-Path $repoRoot 'deployments') -Filter $definition -Recurse
            ).Count | Should Be 1
        }
    }

    It 'keeps all policy implementation and authoring assets in the shared domain' {
        @(
            Get-ChildItem -LiteralPath (Join-Path $repoRoot 'deployments\automatedHostPools\policy') -Filter '*.bicep' -Recurse |
                Where-Object { $_.FullName -ne $automatedPolicyPath }
        ).Count | Should Be 0
        Test-Path -LiteralPath (Join-Path $repoRoot 'deployments\automatedHostPools\policy\AUTHORING.md') | Should Be $false
        $sharedAuthoring | Should Match 'All policy definitions, initiatives, assignment helpers, remediation helpers, and nested'
        $sharedAuthoring | Should Match 'does not need multiple current consumers to belong here'
    }

    It 'uses deterministic assignment and remediation names' {
        $sharedPolicy | Should Match "modules/vmApplicationsAssignment.bicep"
        $sharedPolicy | Should Match "ownershipTagName = 'FederalAVD-SessionHostPolicy-Owner'"
        $sharedPolicy | Should Match 'already managed by session-host policy owner'
        $assignmentModule = Get-Content -LiteralPath (Join-Path (Split-Path $sharedDefinitionPath) 'vmApplicationsAssignment.bicep') -Raw
        $assignmentModule | Should Match "name: 'avd-sh-vm-applications'"
        $assignmentModule | Should Match "resource remediation 'Microsoft.PolicyInsights/remediations@2021-10-01'"
        $assignmentModule | Should Match "resourceDiscoveryMode: 'ReEvaluateCompliance'"
        $sharedMonitoring | Should Match "name: 'avd-sh-monitor'"
        $sharedMonitoring | Should Match "name: 'avd-sh-monitor-agent'"
        $sharedMonitoring | Should Match "name: 'avd-sh-monitor-dcr'"
        $sharedMonitoring | Should Match "name: 'avd-sh-monitor-dce'"
        $sharedGuestAttestation | Should Match "name: 'avd-sh-attest'"
        $sharedManagedDisk | Should Match "name: 'avd-sh-managed-disk-network'"
    }

    It 'targets an explicit dedicated resource group' {
        $addOn | Should Match 'param targetResourceGroupName string'
        $sharedPolicy | Should Match 'param targetResourceGroupName string'
        $form.view.outputs.kind | Should Be 'Subscription'
        $form.view.outputs.parameters.targetResourceGroupName | Should Be "[steps('basics').targetResourceGroupName]"
    }

    It 'keeps Form View outputs aligned with the entry template' {
        $formParameterNames = @($form.view.outputs.parameters.PSObject.Properties.Name | Sort-Object)
        $templateParameterNames = @(
            [regex]::Matches($addOn, '(?m)^param\s+([A-Za-z0-9_]+)\s+') |
                ForEach-Object { $_.Groups[1].Value } |
                Sort-Object
        )
        $formParameterNames | Should Be $templateParameterNames

        $applicationsStep = $form.view.properties.steps | Where-Object { $_.name -eq 'applications' }
        $grid = $applicationsStep.elements | Where-Object { $_.name -eq 'vmApplications' }
        @($grid.constraints.columns.id) | Should Be @(
            'packageReferenceId'
            'order'
            'treatFailureAsDeploymentFailure'
        )
        @($grid.constraints.columns.element.type | Select-Object -Unique) |
            Should Be 'Microsoft.Common.DropDown'

        @($applicationsStep.elements | Where-Object { $_.type -eq 'Microsoft.Common.CheckBox' } | ForEach-Object { $_.name }) |
            Should Be @(
                'enableVmApplications'
                'enableMonitoring'
                'enableGuestAttestation'
                'enableManagedDiskNetworkAccess'
                'createRemediation'
            )
        ($applicationsStep.elements | Where-Object { $_.name -eq 'dataCollectionRule' }).constraints.required |
            Should Be $true
    }

    It 'selects latest VM Applications from an Azure Compute Gallery' {
        $basicsStep = $form.view.properties.steps | Where-Object { $_.name -eq 'basics' }
        $applicationsStep = $form.view.properties.steps | Where-Object { $_.name -eq 'applications' }
        $subscriptionsApi = $basicsStep.elements | Where-Object { $_.name -eq 'subscriptionsApi' }
        $gallerySubscription = $applicationsStep.elements | Where-Object { $_.name -eq 'gallerySubscription' }
        $galleriesApi = $applicationsStep.elements | Where-Object { $_.name -eq 'galleriesApi' }
        $applicationsApi = $applicationsStep.elements | Where-Object { $_.name -eq 'applicationsApi' }
        $grid = $applicationsStep.elements | Where-Object { $_.name -eq 'vmApplications' }

        $subscriptionsApi.request.path | Should Be '/subscriptions?api-version=2022-12-01'
        $gallerySubscription.defaultValue | Should Be "[steps('basics').resourceScope.subscription.displayName]"
        $gallerySubscription.constraints.allowedValues | Should Match "steps\('basics'\)\.subscriptionsApi\.value"
        $galleriesApi.request.path | Should Match '/providers/Microsoft\.Compute/galleries\?api-version=2024-03-03'
        $applicationsApi.request.path | Should Match '/applications\?api-version=2024-03-03'
        $applicationsApi.request.transforms.list | Should Be 'value|[*].{label:name, value:id}'
        $grid.constraints.columns[0].element.constraints.allowedValues | Should Match "steps\('applications'\)\.applicationsApi\.transformed\.list"
        $grid.constraints.columns[0].element.constraints.allowedValues | Should Match '/versions/latest'
    }

    It 'maps all four capabilities in the direct deployment example' {
        $example.parameters.vmApplications.value.Count | Should Not Be 0
        $example.parameters.enableMonitoring.value | Should Be $true
        $example.parameters.dataCollectionRuleResourceId.value | Should Match '/providers/Microsoft.Insights/dataCollectionRules/'
        $example.parameters.enableGuestAttestation.value | Should Be $true
        $example.parameters.enableManagedDiskNetworkAccess.value | Should Be $true
    }

    It 'does not expose session-host guest configuration' {
        $addOn | Should Not Match 'configureSessionHost|sessionHostConfiguration|FSLogix|virtualMachinesTimeZone'
        (@($form.view.outputs.parameters.PSObject.Properties.Name) -join ',') | Should Not Match 'configureFSLogix'
        (@($form.view.outputs.parameters.PSObject.Properties.Name) -join ',') | Should Not Match 'virtualMachinesTimeZone'
    }

    It 'registers the add-on for Template Spec publishing' {
        $templateSpecs | Should Match "Name = 'avd-session-host-policy'"
        $templateSpecs | Should Match "FolderName = 'sessionHostPolicy'"
    }
}
