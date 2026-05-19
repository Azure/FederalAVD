targetScope = 'subscription'

// Handles the two-step Confidential VM disk encryption CMK flow:
//   Step 1 — Run Command on the deployment VM creates the CVM encryption key with a key
//             release policy via the Key Vault data plane. ARM key PUT does not support
//             key release policies — they must be set through the data plane.
//   Step 2 — Shared customerManagedKeys module creates the DiskEncryptionSet
//             (ConfidentialVmEncryptedWithCustomerKey type), grants the DES system identity
//             Key Vault Crypto Service Encryption User on the key, and grants the CVM
//             Orchestrator service principal Key Vault Crypto Service Release User on the key.

@description('Required. Resource group name where the DiskEncryptionSet will be created.')
param resourceGroupHosts string

@description('Required. Resource group name where the deployment VM runs.')
param resourceGroupDeployment string

@description('Required. Resource ID of the Key Vault holding the CVM encryption key.')
param keyVaultResourceId string

@description('Required. URI of the Key Vault (e.g. https://myvault.vault.azure.net).')
param keyVaultUri string

@description('Required. Name of the CVM encryption key to create in the Key Vault.')
param keyName string

@description('Required. Name of the DiskEncryptionSet to create.')
param diskEncryptionSetName string

@description('Required. Object ID of the Confidential VM Orchestrator enterprise application (bf7b6499-ff71-4aa2-97a4-f372087be7f0) in your tenant.')
param confidentialVMOrchestratorObjectId string

@description('Required. Name of the deployment VM on which the Run Command will execute.')
param deploymentVirtualMachineName string

@description('Required. Client ID of the deployment user-assigned identity used to authenticate against Key Vault.')
param deploymentUserAssignedIdentityClientId string

@description('Required. Azure region for the DiskEncryptionSet.')
param location string

@description('Optional. Tags to apply to created resources.')
param tags object = {}

@description('Required. Resource ID of the host pool — stamped as the cm-resource-parent tag on keys and the DES.')
param hostPoolResourceId string

@description('Required. Deployment name suffix for uniqueness.')
param deploymentSuffix string

// Step 1: Create the CVM key with a key release policy via the Key Vault data plane.
// The release policy is immutable once set; this run command is idempotent — it skips
// creation if the key already exists.
module setEncryptionKeyRunCommand '../../../../.common/bicepModules/compute/virtualMachines/runCommands/deploy.bicep' = {
  name: 'Set-EncryptionKey-ConfidentialVM-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupDeployment)
  params: {
    name: 'Set-ConfidentialVM-Key-Disks'
    location: location
    virtualMachineName: deploymentVirtualMachineName
    parameters: [
      { name: 'KeyName', value: keyName }
      { name: 'Tags', value: string({ 'cm-resource-parent': hostPoolResourceId }) }
      { name: 'UserAssignedIdentityClientId', value: deploymentUserAssignedIdentityClientId }
      { name: 'VaultUri', value: keyVaultUri }
    ]
    script: loadTextContent('../../../../.common/scripts/Set-ConfidentialVMOSDiskEncryptionKey.ps1')
    treatFailureAsDeploymentFailure: true
  }
}

// Step 2: Create the DiskEncryptionSet and role assignments.
// skipKeyCreation: true — the key was already created by the Run Command above.
module cmk '../../../../.common/bicepModules/custom/customerManagedKeys/customerManagedKeys.bicep' = {
  name: 'CVM-DiskCMK-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupHosts)
  params: {
    keyVaultResourceId: keyVaultResourceId
    // CVM keys are always RSA-HSM (exportable, with release policy) — HSM tier required.
    keyManagementType: 'CustomerManagedHSM'
    location: location
    tags: tags
    deploymentSuffix: deploymentSuffix
    parentResourceId: hostPoolResourceId
    diskEncryptionConfigs: [
      {
        keyName: keyName
        diskEncryptionSetName: diskEncryptionSetName
        confidentialVMOSDiskEncryption: true
        confidentialVMOrchestratorObjectId: confidentialVMOrchestratorObjectId
        // Key was pre-created above — skip ARM key creation to avoid immutability errors on re-deploy.
        skipKeyCreation: true
      }
    ]
  }
  dependsOn: [
    setEncryptionKeyRunCommand
  ]
}

@description('Resource ID of the created Confidential VM DiskEncryptionSet.')
output diskEncryptionSetResourceId string = cmk.outputs.diskResults[0].diskEncryptionSetResourceId
