BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $fixture = Join-Path $TestDrive 'type-imports.bicep'
    $armPath = Join-Path $TestDrive 'type-imports.json'
    $imports = [ordered]@{
        'resourceModules\compute\virtualMachines\deploy.bicep' = 'extensionType'
        'resourceModules\compute\galleries\images\versions\deploy.bicep' = 'galleryImageVersionTargetRegionType'
        'resourceModules\compute\virtualMachines\runCommands\deploy.bicep' = 'runCommandParameterType'
        'resourceModules\storage\storageAccounts\deploy.bicep' = 'filesConfigurationType, networkAclsType'
        'resourceModules\storage\storageAccounts\fileServices\deploy.bicep' = 'smbSettingsType'
        'resourceModules\desktopVirtualization\scalingPlans\types.bicep' = 'scalingDayType, scalingTimeType, scalingHostPoolReferenceType, pooledScalingScheduleType, personalScalingScheduleType, dynamicScalingScheduleType'
        'resourceModules\authorization\roleAssignments\types.bicep' = 'roleAssignmentType'
        'orchestration\customizations\types.bicep' = 'artifactCustomizationType, restartableArtifactCustomizationType, resolvedCustomizationType'
        'resourceModules\types\identityTypes.bicep' = 'entraGroupType'
        'resourceModules\types\diagnosticSettings.bicep' = 'diagnosticSettingsType'
    }
    $lines = @()
    foreach ($entry in $imports.GetEnumerator()) {
        $source = Join-Path $repoRoot ('deployments\shared\modules\' + $entry.Key)
        $relative = [IO.Path]::GetRelativePath($TestDrive, $source).Replace('\', '/')
        $lines += "import { $($entry.Value) } from '$relative'"
    }
    $lines += @(
        '@secure()'
        'param extensions { items: extensionType[] }'
        'param region galleryImageVersionTargetRegionType'
        'param commandArguments runCommandParameterType[]'
        '@secure()'
        'param protectedArguments { items: runCommandParameterType[] }'
        'param configuration filesConfigurationType'
        'param network networkAclsType'
        'param smb smbSettingsType'
        'param day scalingDayType'
        'param time scalingTimeType'
        'param hostPool scalingHostPoolReferenceType'
        'param pooled pooledScalingScheduleType'
        'param personal personalScalingScheduleType'
        'param dynamic dynamicScalingScheduleType'
        'param assignments roleAssignmentType[]'
        'param artifact artifactCustomizationType'
        'param restartableArtifact restartableArtifactCustomizationType'
        'param resolvedArtifact resolvedCustomizationType'
        'param group entraGroupType'
        'param diagnostics diagnosticSettingsType'
    )
    [IO.File]::WriteAllLines($fixture, $lines)
    $diagnostics = @(& az bicep build --file $fixture --outfile $armPath 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Type import compilation failed: $($diagnostics -join [Environment]::NewLine)"
    }
    $template = Get-Content -LiteralPath $armPath -Raw | ConvertFrom-Json -Depth 100
}

Describe 'Shared Bicep type ownership' {
    It 'imports every relocated contract without deploying its owner resources' {
        ($template.resources | ConvertTo-Json -Compress) | Should -BeIn @('{}', '[]')
        foreach ($entry in $imports.GetEnumerator()) {
            foreach ($typeName in ($entry.Value -split ', ')) {
                $template.definitions.PSObject.Properties.Name | Should -Contain $typeName
            }
        }
    }

    It 'preserves secure extension settings and protected parameter envelopes' {
        $template.definitions.extensionType.properties.protectedSettings.type | Should -Be 'secureObject'
        $template.definitions.extensionType.properties.protectedSettings.nullable | Should -BeTrue
        $template.parameters.extensions.type | Should -Be 'secureObject'
        $template.parameters.protectedArguments.type | Should -Be 'secureObject'
        $template.definitions.runCommandParameterType.properties.PSObject.Properties.Name |
            Should -Be @('name', 'value')
    }

    It 'preserves the gallery replication and disk encryption contract' {
        $region = $template.definitions.galleryImageVersionTargetRegionType
        $region.properties.PSObject.Properties.Name |
            Should -Be @('name', 'regionalReplicaCount', 'storageAccountType', 'excludeFromLatest', 'encryption')
        ($region.properties.storageAccountType.allowedValues | Sort-Object) |
            Should -Be (@('Standard_LRS', 'Standard_ZRS', 'Premium_LRS', 'PremiumV2_LRS') | Sort-Object)
        $region.properties.encryption.properties.osDiskImage.properties.securityProfile.properties.secureVMDiskEncryptionSetId.type |
            Should -Be 'string'
    }

    It 'preserves Azure Files sizing, network and independent SMB encryption contracts' {
        $template.definitions.filesConfigurationType.properties.PSObject.Properties.Name |
            Should -Be @('kind', 'skuName', 'accessTier', 'largeFileSharesState', 'provisionedIops', 'provisionedThroughputMiBps')
        $template.definitions.networkAclsType.properties.defaultAction.allowedValues | Should -Be @('Allow', 'Deny')
        $template.definitions.smbSettingsType.properties.encryptionInTransit.properties.required.type |
            Should -Be 'bool'
        $template.definitions.smbSettingsType.properties.encryptionInTransit.nullable | Should -BeTrue
    }

    It 'keeps artifact workflow contracts separate from generic Run Command arguments' {
        $template.definitions.artifactCustomizationType.properties.PSObject.Properties.Name |
            Should -Be @('name', 'blobNameOrUri', 'arguments', 'successExitCodes')
        $template.definitions.restartableArtifactCustomizationType.properties.restart.nullable | Should -BeTrue
        $template.definitions.resolvedCustomizationType.properties.restart.nullable | Should -Not -BeTrue
        $artifactTypes = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\shared\modules\orchestration\customizations\types.bicep') -Raw
        $artifactTypes | Should -Not -Match 'runCommandParameterType'
    }

    It 'preserves scaling schedule variants and cross-resource references' {
        ($template.definitions.scalingDayType.allowedValues | Sort-Object) |
            Should -Be (@('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday') | Sort-Object)
        $template.definitions.scalingTimeType.properties.PSObject.Properties.Name | Should -Be @('hour', 'minute')
        $template.definitions.dynamicScalingScheduleType.properties.PSObject.Properties.Name |
            Should -Contain 'rampUpMaximumHostPoolSize'
        $template.definitions.personalScalingScheduleType.properties.PSObject.Properties.Name |
            Should -Contain 'rampUpActionOnDisconnect'
        $template.definitions.pooledScalingScheduleType.properties.PSObject.Properties.Name |
            Should -Contain 'rampDownStopHostsWhen'
        $template.definitions.roleAssignmentType.properties.PSObject.Properties.Name |
            Should -Be @('roleDefinitionId', 'principalId', 'principalType', 'description')
        $template.definitions.entraGroupType.properties.PSObject.Properties.Name | Should -Be @('id', 'name')
        $template.definitions.diagnosticSettingsType.properties.PSObject.Properties.Name |
            Should -Contain 'workspaceId'
    }
}
