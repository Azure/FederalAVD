# Core Dependency Map

| Producer | Output | Consumer |
| --- | --- | --- |
| Networking | `subnetResourceIds` | Host Pool and add-on subnet parameters, selected by the output record's `purpose` property |
| Networking | `privateDnsZoneResourceIds` | AVD Shared Services, Image Management, Host Pool, and add-on private DNS zone parameters |
| AVD Shared Services (`sharedServices`) | `secretsKeyVaultResourceId` | Standard Host Pool `existingCredentialsKeyVaultResourceId`; Automated Host Pool `credentialsKeyVaultResourceId` (required) |
| AVD Shared Services (`sharedServices`) | `encryptionKeyVaultResourceId` | Image Management `encryptionKeyVaultResourceId`; Host Pool `existingEncryptionKeyVaultResourceId` |
| AVD Shared Services (`sharedServices`) | `logAnalyticsWorkspaceResourceId` | Image Management `logAnalyticsWorkspaceResourceId`; Host Pool `existingLogAnalyticsWorkspaceResourceId` |
| AVD Shared Services (`sharedServices`) | `avdInsightsDataCollectionRuleResourceId` | Host Pool `existingAVDInsightsDataCollectionRuleResourceId` |
| AVD Shared Services (`sharedServices`) | `dataCollectionEndpointResourceId` | Host Pool `existingDataCollectionEndpointResourceId` |
| AVD Shared Services (`sharedServices`) | `azureMonitorPrivateLinkScopeResourceId` | Host Pool `azureMonitorPrivateLinkScopeResourceId`; centralized monitoring and DNS automation |
| AVD Shared Services (`sharedServices`) | `fslogixBackupVaultResourceId` | Host Pool `existingFilesBackupVaultResourceId`; FSLogix Storage add-on `recoveryServicesVaultResourceId` |
| AVD Shared Services (`sharedServices`) | `fslogixBackupPolicyName` | Host Pool `existingFilesBackupPolicyName`; FSLogix Storage add-on `fileSharePolicyName` |
| Image Management | `computeGalleryResourceId` | Image Build `computeGalleryResourceId` |
| Image Management | `artifactsStorageAccountResourceId` | `Update-ImageArtifacts.ps1 -StorageAccountResourceId` |
| Image Management | `artifactsBlobContainerUrl` | Image Build `artifactsContainerUri` |
| Image Management | `managedIdentityResourceId` | Image Build `userAssignedIdentityResourceId` |
| Image Management | `buildLogsStorageAccountResourceId` | Image Build `logStorageAccountResourceId` |
| Image Management | `diskEncryptionSetResourceId` | Image Build `diskEncryptionSetResourceId` |
| Image Management | `confidentialVmDiskEncryptionSetResourceId` | Image Build `confidentialVMDiskEncryptionSetResourceId` |
| Image Management | `imageBuildResourceGroupResourceId` | Image Build `imageBuildResourceGroupId` |
| Image Build | `customImageResourceId` | Host Pool `customImageResourceId` |

## External Shared Dependencies

| Dependency | Consumer | Ownership guidance |
| --- | --- | --- |
| Global Azure Monitor Action Group | AVD Alerts `actionGroupResourceId` | Create and manage outside FederalAVD, normally with the central operations or incident-response team. The AVD Alerts form requires a same-subscription Action Group in the `global` location because Service Health alerts cannot use a regional Action Group. AVD Shared Services intentionally does not create notification receivers or webhook destinations. |

Confirm names against the current entry Bicep templates before editing parameters; documentation and
template versions can drift during active development.
