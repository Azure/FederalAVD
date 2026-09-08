$repoRoot = Split-Path -Parent $PSScriptRoot
$bicepPath = Join-Path $repoRoot 'deployments\imageBuild\imageBuild.bicep'
$armPath = Join-Path $repoRoot 'deployments\imageBuild\imageBuild.json'
$formPath = Join-Path $repoRoot 'deployments\imageBuild\uiFormDefinition.json'

Describe 'Image Build regional replication behavior' {
    It 'limits the primary Compute Gallery to the deployment subscription and region' {
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $prereqs = $form.view.properties.steps | Where-Object { $_.name -eq 'prereqs' }
        $gallerySection = $prereqs.elements | Where-Object { $_.name -eq 'gallery' }
        $gallerySelector = $gallerySection.elements | Where-Object { $_.name -eq 'gallery' }

        $gallerySelector.options.filter.subscription | Should Be 'onBasics'
        $gallerySelector.options.filter.location | Should Be 'onBasics'
    }

    It 'does not persistently add a remote-gallery region to primary-gallery targets' {
        $bicep = Get-Content -LiteralPath $bicepPath -Raw
        $bicep | Should Not Match 'var imageVersionReplicationRegions = empty\(remoteComputeGalleryResourceId\)'
        $bicep | Should Match 'imageVersionReplicationRegions: localImageVersionTargetRegionsWithEncryption'
        $bicep | Should Not Match 'initialLocalImageVersionTargetRegions'
    }

    It 'keeps the generated capture target-regions expression below the ARM limit' {
        $arm = Get-Content -LiteralPath $armPath -Raw | ConvertFrom-Json
        $expression = $arm.resources.captureImage.properties.parameters.imageVersionReplicationRegions

        $expression.Length | Should BeLessThan 81920
    }

    It 'captures the remote gallery version from the build source with source and remote targets' {
        $bicep = Get-Content -LiteralPath $bicepPath -Raw
        $bicep | Should Match "module remoteImageVersion[\s\S]*?location: computeLocation"
        $bicep | Should Match 'var remoteImageVersionTargetRegions = map\(defaultRemoteImageVersionTargetRegions'
        $bicep | Should Match 'var defaultRemoteImageVersionTargetRegions = \[[\s\S]*?name: computeLocation[\s\S]*?name: remoteLocation'
    }

    It 'does not use an encrypted gallery image version as the remote source' {
        $bicep = Get-Content -LiteralPath $bicepPath -Raw
        $bicep | Should Not Match 'sourceId: captureImage\.outputs\.imageVersionId'
        $bicep | Should Not Match 'removeRemoteSourceBridgeReplica'
        $bicep | Should Match "sourceId: contains\(effectiveGalleryImageDefinitionSecurityType, 'Supported'\) \? captureImage\.outputs\.managedImageId : ''"
        $bicep | Should Match "virtualMachineId: !contains\(effectiveGalleryImageDefinitionSecurityType, 'Supported'\) \? imageVm\.outputs\.resourceId : ''"
    }

    It 'supports regional standard and Confidential VM DES values' {
        $bicep = Get-Content -LiteralPath $bicepPath -Raw
        $bicep | Should Match 'diskEncryptionSetResourceId: string\?'
        $bicep | Should Match 'confidentialVMDiskEncryptionSetResourceId: string\?'
        $bicep | Should Match 'region\.\?diskEncryptionSetResourceId'
        $bicep | Should Match 'region\.\?confidentialVMDiskEncryptionSetResourceId'
    }

    It 'collects regional DES selections in the replication grid' {
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $imageDest = $form.view.properties.steps | Where-Object { $_.name -eq 'imageDest' }
        $imageVersion = $imageDest.elements | Where-Object { $_.name -eq 'imageVersion' }
        $disasterRecovery = $imageDest.elements | Where-Object { $_.name -eq 'disasterRecovery' }
        $additionalRegionsChoice = $imageVersion.elements | Where-Object { $_.name -eq 'specifyAdditionalReplicaRegions' }
        $additionalReplicaRegions = $imageVersion.elements | Where-Object { $_.name -eq 'additionalReplicaRegions' }
        $remoteGalleryInfo = $disasterRecovery.elements | Where-Object { $_.name -eq 'infoDisasterRecovery' }
        $remoteGalleryChoice = $disasterRecovery.elements | Where-Object { $_.name -eq 'specifyRemoteGallery' }
        $columns = $additionalReplicaRegions.constraints.columns

        $additionalRegionsChoice.type | Should Be 'Microsoft.Common.OptionsGroup'
        $additionalRegionsChoice.defaultValue | Should Be 'No'
        @($additionalRegionsChoice.constraints.allowedValues).Count | Should Be 2
        @($additionalRegionsChoice.constraints.allowedValues.value) -contains $true | Should Be $true
        @($additionalRegionsChoice.constraints.allowedValues.value) -contains $false | Should Be $true
        $additionalRegionsChoice.label | Should Match 'primary Compute Gallery'
        $additionalReplicaRegions.label | Should Be 'Additional Replica Regions'
        $replicaWarning = $imageVersion.elements | Where-Object { $_.name -eq 'repRegionsText' }
        $replicaWarning.type | Should Be 'Microsoft.Common.InfoBox'
        $replicaWarning.options.style | Should Be 'Warning'
        $replicaWarning.options.text | Should Match 'cannot enforce'
        $replicaWarning.options.text | Should Match 'region-to-DES mismatch'
        $remoteGalleryInfo.options.text | Should Match 'primary Compute Gallery'
        $remoteGalleryInfo.options.text | Should Match 'separate Compute Gallery'
        $remoteGalleryChoice.label | Should Match 'separate Compute Gallery'

        ($columns | Where-Object { $_.id -eq 'diskEncryptionSetResourceId' }).element.type |
            Should Be 'Microsoft.Common.DropDown'
        ($columns | Where-Object { $_.id -eq 'confidentialVMDiskEncryptionSetResourceId' }).element.type |
            Should Be 'Microsoft.Common.DropDown'
        ($columns | Where-Object { $_.id -eq 'diskEncryptionSetResourceId' }).element.multiLine |
            Should Be $true
        ($columns | Where-Object { $_.id -eq 'confidentialVMDiskEncryptionSetResourceId' }).element.multiLine |
            Should Be $true
        ($columns | Where-Object { $_.id -eq 'diskEncryptionSetResourceId' }).element.constraints.required |
            Should Match 'galleryImageVersionEncryptionType'
        ($columns | Where-Object { $_.id -eq 'diskEncryptionSetResourceId' }).element.constraints.required |
            Should Not Match '\$rowIndex|additionalReplicaRegions'
        (($columns | Where-Object { $_.id -eq 'diskEncryptionSetResourceId' }).element.PSObject.Properties.Name -contains 'visible') |
            Should Be $false
        ($columns | Where-Object { $_.id -eq 'diskEncryptionSetResourceId' }).element.constraints.allowedValues |
            Should Match 'diskEncryptionSetsApi\.transformed\.(customerManaged|doubleEncryption)'
        ($columns | Where-Object { $_.id -eq 'diskEncryptionSetResourceId' }).element.constraints.allowedValues |
            Should Match 'NotApplicable'
        ($columns | Where-Object { $_.id -eq 'diskEncryptionSetResourceId' }).element.constraints.allowedValues |
            Should Not Match '\$rowIndex|additionalReplicaRegions'
        ($columns | Where-Object { $_.id -eq 'diskEncryptionSetResourceId' }).element.constraints.allowedValues |
            Should Match 'Region:'
        ($columns | Where-Object { $_.id -eq 'confidentialVMDiskEncryptionSetResourceId' }).element.constraints.required |
            Should Match 'EncryptedWithCmk'
        ($columns | Where-Object { $_.id -eq 'confidentialVMDiskEncryptionSetResourceId' }).element.constraints.required |
            Should Not Match '\$rowIndex|replicationRegions'
        (($columns | Where-Object { $_.id -eq 'confidentialVMDiskEncryptionSetResourceId' }).element.PSObject.Properties.Name -contains 'visible') |
            Should Be $false
        ($columns | Where-Object { $_.id -eq 'confidentialVMDiskEncryptionSetResourceId' }).element.constraints.allowedValues |
            Should Match 'NotApplicable'
        ($columns | Where-Object { $_.id -eq 'confidentialVMDiskEncryptionSetResourceId' }).element.constraints.allowedValues |
            Should Not Match '\$rowIndex|additionalReplicaRegions'
        ($columns | Where-Object { $_.id -eq 'confidentialVMDiskEncryptionSetResourceId' }).element.constraints.allowedValues |
            Should Match 'Region:'
        ($columns | Where-Object { $_.id -eq 'name' }).element.constraints.allowedValues |
            Should Match "not\(equals\(toLower\(replace\(item, ' ', ''\)\), toLower\(steps\('basics'\)\.scope\.location\.name\)\)\)"
    }

    It 'places all encryption controls in active image version and disaster recovery sections' {
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $imageDest = $form.view.properties.steps | Where-Object { $_.name -eq 'imageDest' }
        $imageVersion = $imageDest.elements | Where-Object { $_.name -eq 'imageVersion' }
        $disasterRecovery = $imageDest.elements | Where-Object { $_.name -eq 'disasterRecovery' }

        @($imageDest.elements | Where-Object { $_.name -eq 'encryption' }).Count | Should Be 0
        @($imageVersion.elements | Where-Object { $_.name -eq 'confidentialVMEncryptionType' }).Count | Should Be 1
        @($imageVersion.elements | Where-Object { $_.name -eq 'existingConfidentialVMDiskEncryptionSetResourceId' }).Count | Should Be 1
        @($disasterRecovery.elements | Where-Object { $_.name -eq 'existingRemoteConfidentialVMDiskEncryptionSetResourceId' }).Count | Should Be 1
    }

    It 'selects one encryption type and filters primary and remote DES choices exactly' {
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $imageDest = $form.view.properties.steps | Where-Object { $_.name -eq 'imageDest' }
        $imageVersion = $imageDest.elements | Where-Object { $_.name -eq 'imageVersion' }
        $disasterRecovery = $imageDest.elements | Where-Object { $_.name -eq 'disasterRecovery' }
        $encryptionType = $imageVersion.elements | Where-Object { $_.name -eq 'galleryImageVersionEncryptionType' }
        $desApi = $imageVersion.elements | Where-Object { $_.name -eq 'diskEncryptionSetsApi' }
        $primaryDes = $imageVersion.elements | Where-Object { $_.name -eq 'existingDiskEncryptionSetResourceId' }
        $remoteDes = $disasterRecovery.elements | Where-Object { $_.name -eq 'existingRemoteDiskEncryptionSetResourceId' }

        $encryptionType.defaultValue | Should Be 'Platform-managed key'
        @($encryptionType.constraints.allowedValues.value) | Should Be @(
            'PlatformManaged'
            'EncryptionAtRestWithCustomerKey'
            'EncryptionAtRestWithPlatformAndCustomerKeys'
        )
        $desApi.condition | Should Match "not\(empty\(steps\('basics'\)\.scope\.subscription\)\)"
        $desApi.request.path | Should Match 'api-version=2024-03-02'
        $desApi.request.transforms.customerManaged | Should Match "properties\.encryptionType == 'EncryptionAtRestWithCustomerKey'"
        $desApi.request.transforms.doubleEncryption | Should Match "properties\.encryptionType == 'EncryptionAtRestWithPlatformAndCustomerKeys'"
        $desApi.request.transforms.confidentialVm | Should Match "properties\.encryptionType == 'ConfidentialVmEncryptedWithCustomerKey'"
        $desApi.request.transforms.customerManaged | Should Match 'sort_by\([\s\S]*?, &location\)'
        $desApi.request.transforms.doubleEncryption | Should Match 'sort_by\([\s\S]*?, &location\)'
        $desApi.request.transforms.confidentialVm | Should Match 'sort_by\([\s\S]*?, &location\)'
        $primaryDes.constraints.allowedValues | Should Match 'imageVersion\.diskEncryptionSetsApi\.transformed\.customerManaged'
        $primaryDes.constraints.allowedValues | Should Match 'imageVersion\.diskEncryptionSetsApi\.transformed\.doubleEncryption'
        $remoteDes.constraints.allowedValues | Should Match 'imageVersion\.diskEncryptionSetsApi\.transformed\.customerManaged'
        $remoteDes.constraints.allowedValues | Should Match 'imageVersion\.diskEncryptionSetsApi\.transformed\.doubleEncryption'
        $primaryDes.constraints.allowedValues | Should Not Match "not\(equals\(des\.properties\.encryptionType"
        $remoteDes.constraints.allowedValues | Should Not Match "not\(equals\(des\.properties\.encryptionType"
        $primaryDes.constraints.allowedValues | Should Not Match "steps\('prereqs'\)\.gallery\.gallery\.id"
    }

    It 'emits source and additional-region DES IDs through their respective inputs' {
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $outputs = $form.view.outputs.parameters
        $outputs.diskEncryptionSetResourceId | Should Match 'existingDiskEncryptionSetResourceId'
        $outputs.confidentialVMDiskEncryptionSetResourceId | Should Match 'existingConfidentialVMDiskEncryptionSetResourceId'
        $outputs.imageVersionTargetRegions | Should Match 'diskEncryptionSetResourceId'
        $outputs.imageVersionTargetRegions | Should Match 'confidentialVMDiskEncryptionSetResourceId'
        $outputs.imageVersionTargetRegions | Should Match "galleryImageVersionEncryptionType, 'PlatformManaged'"
        $outputs.imageVersionTargetRegions | Should Match "confidentialVMEncryptionType, 'EncryptedWithCmk'"
        $outputs.remoteConfidentialVMDiskEncryptionSetResourceId |
            Should Match "contains\([\s\S]*?'Confidential'\), equals\(steps\('imageDest'\)\.imageVersion\.confidentialVMEncryptionType, 'EncryptedWithCmk'\)"
    }

    It 'emits top-level defaults and only optional grid rows through target regions' {
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $outputs = $form.view.outputs.parameters
        $targetRegionsOutput = $outputs.imageVersionTargetRegions

        $targetRegionsOutput | Should Match "if\(equals\(steps\('imageDest'\)\.imageVersion\.specifyAdditionalReplicaRegions, true\), map"
        $targetRegionsOutput | Should Not Match "steps\('basics'\)\.scope\.location\.name"
        $targetRegionsOutput | Should Match "steps\('imageDest'\)\.imageVersion\.replicaCount"
        $targetRegionsOutput | Should Match "steps\('imageDest'\)\.imageVersion\.storageAccountType"
        @($outputs.PSObject.Properties.Name) -contains 'imageVersionDefaultReplicaCount' | Should Be $true
        @($outputs.PSObject.Properties.Name) -contains 'imageVersionDefaultStorageAccountType' | Should Be $true
        @($outputs.PSObject.Properties.Name) -contains 'imageVersionExcludeFromLatest' | Should Be $true
        @($outputs.PSObject.Properties.Name) -contains 'diskEncryptionSetResourceId' | Should Be $true
        @($outputs.PSObject.Properties.Name) -contains 'confidentialVMDiskEncryptionSetResourceId' | Should Be $true
    }

    It 'maps every form output to an ARM input and emits every required input' {
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $arm = Get-Content -LiteralPath $armPath -Raw | ConvertFrom-Json
        $formParameterNames = @($form.view.outputs.parameters.PSObject.Properties.Name)
        $armParameterNames = @($arm.parameters.PSObject.Properties.Name)
        $requiredArmParameterNames = @(
            $arm.parameters.PSObject.Properties |
                Where-Object { -not ($_.Value.PSObject.Properties.Name -contains 'defaultValue') } |
                Select-Object -ExpandProperty Name
        )

        @($formParameterNames | Where-Object { $_ -notin $armParameterNames }).Count | Should Be 0
        @($requiredArmParameterNames | Where-Object { $_ -notin $formParameterNames }).Count | Should Be 0
        @($armParameterNames | Where-Object { $_ -notin $formParameterNames } | Sort-Object) |
            Should Be @(
                'deploymentPrefix'
                'timeStamp'
            )
    }

    It 'keeps existing regional objects compatible and normalizes form sentinels' {
        $bicep = Get-Content -LiteralPath $bicepPath -Raw
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $targetRegionsOutput = $form.view.outputs.parameters.imageVersionTargetRegions

        $bicep | Should Match 'diskEncryptionSetResourceId: string\?'
        $bicep | Should Match 'confidentialVMDiskEncryptionSetResourceId: string\?'
        $bicep | Should Match "region\.\?diskEncryptionSetResourceId \?\? \(toLower\(region\.name\) == toLower\(computeLocation\) \? diskEncryptionSetResourceId : ''\)"
        $bicep | Should Match "region\.\?confidentialVMDiskEncryptionSetResourceId \?\? \(toLower\(region\.name\) == toLower\(computeLocation\)"
        $bicep | Should Match 'imageVersionDefaultReplicaCount: imageVersionDefaultReplicaCount'
        $bicep | Should Match 'imageVersionDefaultStorageAccountType: imageVersionDefaultStorageAccountType'
        $bicep | Should Match 'imageVersionExcludeFromLatest: imageVersionExcludeFromLatest'
        $bicep | Should Match 'diskEncryptionSetId: diskEncryptionSetResourceId'
        $bicep | Should Match "fail\('imageVersionTargetRegions must contain each region only once\.'\)"
        $bicep | Should Match 'name: toLower\(region\.name\) == toLower\(computeLocation\) \? computeLocation : region\.name'
        $bicep | Should Match '!empty\(region\.diskEncryptionSetResourceId\) \|\| !empty\(galleryImageVersionConfidentialVMEncryptionType\)'
        $targetRegionsOutput | Should Match "equals\(coalesce\(region\.diskEncryptionSetResourceId, ''\), 'NotApplicable'\)"
        $targetRegionsOutput | Should Match "not\(equals\(coalesce\(region\.confidentialVMDiskEncryptionSetResourceId, ''\), 'NotApplicable'\)\)"
    }

    It 'matches the source region case-insensitively in the shared image-version module' {
        $modulePath = Join-Path $repoRoot 'deployments\shared\modules\resourceModules\compute\galleries\images\versions\deploy.bicep'
        $module = Get-Content -LiteralPath $modulePath -Raw

        $module | Should Match 'toLower\(region\.name\) == toLower\(location\)'
    }

    It 'uses canonical enum spellings downstream' {
        $bicep = Get-Content -LiteralPath $bicepPath -Raw

        $bicep | Should Match "'DoD'"
        $bicep | Should Not Match "(?-i)'DOD'"
        $bicep | Should Match "'TrustedLaunchAndConfidentialVmSupported'[\s\S]*?'TrustedLaunchAndConfidentialVMSupported'"
        $bicep | Should Match "imageDefinitionSecurityType == 'TrustedLaunchAndConfidentialVMSupported'[\s\S]*?'TrustedLaunchAndConfidentialVmSupported'"
        $bicep | Should Match 'teamsCloudType: teamsCloudType'
    }
}
