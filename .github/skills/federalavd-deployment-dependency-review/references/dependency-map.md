# Core Dependency Map

| Producer | Output | Consumer |
| --- | --- | --- |
| Security and Monitoring | `secretsKeyVaultResourceId` | Host Pool `existingCredentialsKeyVaultResourceId` |
| Security and Monitoring | `encryptionKeyVaultResourceId` | Image Management `encryptionKeyVaultResourceId`; Host Pool `existingEncryptionKeyVaultResourceId` |
| Security and Monitoring | `logAnalyticsWorkspaceResourceId` | Image Management `logAnalyticsWorkspaceResourceId`; Host Pool `existingLogAnalyticsWorkspaceResourceId` |
| Security and Monitoring | `avdInsightsDataCollectionRuleResourceId` | Host Pool `existingAVDInsightsDataCollectionRuleResourceId` |
| Security and Monitoring | `dataCollectionEndpointResourceId` | Host Pool `existingDataCollectionEndpointResourceId` |
| Image Management | `computeGalleryResourceId` | Image Build `computeGalleryResourceId` |
| Image Management | `artifactsStorageAccountResourceId` | `Update-ImageArtifacts.ps1 -StorageAccountResourceId` |
| Image Management | `artifactsBlobContainerUrl` | Image Build `artifactsContainerUri` |
| Image Management | `managedIdentityResourceId` | Image Build `userAssignedIdentityResourceId` |
| Image Management | `buildLogsStorageAccountResourceId` | Image Build `logStorageAccountResourceId` |
| Image Management | `diskEncryptionSetResourceId` | Image Build `diskEncryptionSetResourceId` |
| Image Management | `confidentialVmDiskEncryptionSetResourceId` | Image Build `confidentialVMDiskEncryptionSetResourceId` |
| Image Management | `imageBuildResourceGroupResourceId` | Image Build `imageBuildResourceGroupId` |
| Image Build | `customImageResourceId` | Host Pool `customImageResourceId` |

Confirm names against the current entry Bicep templates before editing parameters; documentation and
template versions can drift during active development.
