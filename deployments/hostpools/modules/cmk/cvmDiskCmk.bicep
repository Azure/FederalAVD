targetScope = 'subscription'

// Handles the two-step Confidential VM disk encryption CMK flow:
//   Step 1 — Run Command on the deployment VM creates the CVM encryption key with a key
//             release policy via the Key Vault data plane. ARM key PUT does not support
//             key release policies — they must be set through the data plane.
//   Step 2 — This focused module creates the DiskEncryptionSet
//             (ConfidentialVmEncryptedWithCustomerKey type), grants the DES system identity
//             Key Vault Crypto Service Encryption User on the key, and grants the CVM
//             Orchestrator service principal Key Vault Crypto Service Release User on the key.

param resourceGroupHosts string
param resourceGroupDeployment string
param keyVaultResourceId string
param keyVaultUri string
param keyName string
param diskEncryptionSetName string
param confidentialVMOrchestratorObjectId string
param deploymentVirtualMachineName string
param deploymentUserAssignedIdentityClientId string
param location string
param tags object = {}
param hostPoolResourceId string

// Step 1: Create the CVM key with a key release policy via the Key Vault data plane.
// The release policy is immutable once set; this run command is idempotent — it skips
// creation if the key already exists.
module setEncryptionKeyRunCommand '../../../shared/modules/resourceModules/compute/virtualMachines/runCommands/deploy.bicep' = {
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
    script: loadTextContent('../../scripts/Set-ConfidentialVMOSDiskEncryptionKey.ps1')
    treatFailureAsDeploymentFailure: true
  }
}

var keyVaultName = last(split(keyVaultResourceId, '/'))
var keyVaultSubscriptionId = split(keyVaultResourceId, '/')[2]
var keyVaultResourceGroup = split(keyVaultResourceId, '/')[4]
var parentTag = { 'cm-resource-parent': hostPoolResourceId }

// Step 2: Create the Confidential VM DiskEncryptionSet for the pre-created key.
module diskEncryptionSet '../../../shared/modules/resourceModules/compute/diskEncryptionSets/deploy.bicep' = {
  scope: resourceGroup(resourceGroupHosts)
  params: {
    name: diskEncryptionSetName
    location: location
    keyVaultResourceId: keyVaultResourceId
    keyName: keyName
    encryptionType: 'ConfidentialVmEncryptedWithCustomerKey'
    rotationToLatestKeyVersionEnabled: false
    systemAssignedIdentity: true
    tags: union(parentTag, tags[?'Microsoft.Compute/diskEncryptionSets'] ?? {})
  }
  dependsOn: [
    setEncryptionKeyRunCommand
  ]
}

// Step 3: Grant the DES encryption role and CVM Orchestrator release role at key scope.
module keyRoleAssignments '../../../shared/modules/resourceModules/keyVault/vaults/keys/roleAssignment.bicep' = {
  scope: resourceGroup(keyVaultSubscriptionId, keyVaultResourceGroup)
  params: {
    keyVaultName: keyVaultName
    keyName: keyName
    assignments: [
      {
        principalId: diskEncryptionSet.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionId: 'e147488a-f6f5-4113-8e2d-b22465e65bf6'
      }
      {
        principalId: confidentialVMOrchestratorObjectId
        principalType: 'ServicePrincipal'
        roleDefinitionId: '08bbd89e-9f13-488c-ac41-acfcb10c90ab'
      }
    ]
  }
}

@description('Resource ID of the created Confidential VM DiskEncryptionSet.')
output diskEncryptionSetResourceId string = diskEncryptionSet.outputs.resourceId
