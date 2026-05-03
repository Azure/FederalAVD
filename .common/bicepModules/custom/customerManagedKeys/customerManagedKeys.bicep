// ============================================================================
// Unified Customer-Managed Keys Module
// ============================================================================
// Single module that handles ALL CMK scenarios in the FederalAVD repo:
//
//   Storage mode  — creates one key + one UAI + role assignment per storage
//                   account config. The UAI resource ID and principal ID are
//                   returned so callers can embed CMK directly in the storage
//                   account PUT (avoiding a two-step SAI pattern that fails
//                   under Azure Policy deny-effect rules).
//
//   Disk mode     — creates one key + one DiskEncryptionSet with system-
//                   assigned identity + role assignment. The DES resource ID
//                   is returned for use by VM deployments. Confidential VM
//                   mode is also supported (ConfidentialVmEncryptedWithCustomerKey
//                   + release-user role for the CVMOrchestrator service principal).
//
// Callers that previously used per-solution inline CMK logic should switch to
// this module and consume its outputs instead of duplicating key/identity/RA
// boilerplate.
//
// Role assignments are made at Key Vault key scope — the most restrictive and
// recommended scope. After this module completes, role assignments are in the
// ARM control plane. Because this module must complete (including RA propagation)
// before storage accounts or VMs are deployed, the run-command polling pattern
// used in the legacy disk-CMK module is unnecessary and has been removed.
// Simply ensuring this module's deployment completes before dependent resources
// provides sufficient ordering for AAD propagation.
// ============================================================================

// ─── Common parameters ───────────────────────────────────────────────────────

@description('Required. Resource ID of the Key Vault in which keys will be created.')
param keyVaultResourceId string

@description('Required. CMK type — drives key type (RSA vs RSA-HSM) and disk encryption type.')
@allowed([
  'CustomerManaged'
  'CustomerManagedHSM'
])
param keyManagementType string

@description('Optional. Key expiration in days. Also controls auto-rotation: keys rotate 7 days before expiry.')
@minValue(7)
param keyExpirationInDays int = 180

@description('Optional. Azure region for UAIs and DiskEncryptionSets. Defaults to resource group location.')
param location string = resourceGroup().location

@description('Optional. Tags to apply to created resources. Uses standard Azure resource-type tag bag pattern.')
param tags object = {}

@description('Optional. Resource ID to stamp as the cm-resource-parent tag on keys and identities.')
param parentResourceId string = ''

@description('Optional. Suffix appended to deployment names for uniqueness.')
param deploymentSuffix string = uniqueString(resourceGroup().id, deployment().name)

// ─── Storage mode parameters ─────────────────────────────────────────────────

@description('''
Optional. Names of Key Vault keys to create for storage account CMK encryption.
One key is created per entry. All keys are assigned to the single storageIdentityName UAI.
For a single storage account, pass a one-element array.
For FSLogix with multiple accounts, pass all key names (one per account).
''')
param storageKeyNames string[] = []

@description('Optional. Name of the user-assigned identity to create for storage CMK. Required when storageKeyNames is not empty.')
param storageIdentityName string = ''

// ─── Disk mode parameters ────────────────────────────────────────────────────

@description('''
Optional. Array of disk encryption set CMK configurations.
Each entry produces: one KV key (unless confidentialVM), one DiskEncryptionSet,
one key-scoped role assignment (Crypto Service Encryption User).
  keyName                       — name of the key to create
  diskEncryptionSetName         — name of the DiskEncryptionSet to create
  confidentialVMOSDiskEncryption — when true, skips key creation (key is created
                                   via run command by the Confidential VM
                                   infrastructure) and uses ConfidentialVmEncryptedWithCustomerKey
  confidentialVMOrchestratorObjectId — required when confidentialVMOSDiskEncryption is true;
                                       object ID of the Confidential VM Orchestrator
                                       enterprise application (bf7b6499-ff71-4aa2-97a4-f372087be7f0)
''')
param diskEncryptionConfigs diskEncryptionConfigType[] = []

// ─── Types ───────────────────────────────────────────────────────────────────

type diskEncryptionConfigType = {
  keyName: string
  diskEncryptionSetName: string
  confidentialVMOSDiskEncryption: bool?
  confidentialVMOrchestratorObjectId: string?
}

// ─── Variables ───────────────────────────────────────────────────────────────

var keyVaultName = last(split(keyVaultResourceId, '/'))
var keyVaultSubscriptionId = split(keyVaultResourceId, '/')[2]
var keyVaultResourceGroup = split(keyVaultResourceId, '/')[4]

var kty = contains(keyManagementType, 'HSM') ? 'RSA-HSM' : 'RSA'

var rotationPolicy = {
  attributes: {
    expiryTime: 'P${string(keyExpirationInDays)}D'
  }
  lifetimeActions: [
    {
      action: { type: 'Notify' }
      trigger: { timeBeforeExpiry: 'P10D' }
    }
    {
      action: { type: 'Rotate' }
      trigger: { timeAfterCreate: 'P${string(keyExpirationInDays - 7)}D' }
    }
  ]
}

var parentTag = !empty(parentResourceId) ? { 'cm-resource-parent': parentResourceId } : {}

var roleKeyVaultCryptoEncryptionUser = 'e147488a-f6f5-4113-8e2d-b22465e65bf6'
var roleKeyVaultCryptoReleaseUser = '08bbd89e-9f13-488c-ac41-acfcb10c90ab'

// ─── Storage: Keys ───────────────────────────────────────────────────────────

module storageKeys '../../keyVault/vaults/keys/deploy.bicep' = [
  for (keyName, i) in storageKeyNames: {
    name: 'CMK-StorageKey-${i}-${deploymentSuffix}'
    scope: resourceGroup(keyVaultSubscriptionId, keyVaultResourceGroup)
    params: {
      keyVaultName: keyVaultName
      name: keyName
      kty: kty
      keySize: 4096
      attributesEnabled: true
      attributesExportable: false
      rotationPolicy: rotationPolicy
      tags: parentTag
    }
  }
]

// ─── Storage: User-Assigned Identity (single, shared by all storage keys) ────

module storageIdentity '../../managedIdentity/userAssignedIdentities/deploy.bicep' = if (!empty(storageKeyNames)) {
  name: 'CMK-StorageUAI-${deploymentSuffix}'
  params: {
    name: storageIdentityName
    location: location
    tags: union(parentTag, tags[?'Microsoft.ManagedIdentity/userAssignedIdentities'] ?? {})
  }
}

// ─── Storage: Role Assignments (Key Vault Crypto Service Encryption User) ────
// One role assignment per key, all scoped to the same shared UAI.

module storageKeyRoleAssignments '../../keyVault/vaults/keys/roleAssignment.bicep' = [
  for (keyName, i) in storageKeyNames: {
    name: 'CMK-StorageKeyRA-${i}-${deploymentSuffix}'
    scope: resourceGroup(keyVaultSubscriptionId, keyVaultResourceGroup)
    params: {
      keyVaultName: keyVaultName
      keyName: keyName
      assignments: [
        {
          principalId: storageIdentity!.outputs.principalId
          principalType: 'ServicePrincipal'
          roleDefinitionId: roleKeyVaultCryptoEncryptionUser
        }
      ]
    }
    dependsOn: [
      storageKeys[i]
    ]
  }
]

// ─── Disk: Keys (skipped for Confidential VM — CVMOrchestrator creates them) ─

module diskKeys '../../keyVault/vaults/keys/deploy.bicep' = [
  for (config, i) in diskEncryptionConfigs: if (!(config.?confidentialVMOSDiskEncryption ?? false)) {
    name: 'CMK-DiskKey-${i}-${deploymentSuffix}'
    scope: resourceGroup(keyVaultSubscriptionId, keyVaultResourceGroup)
    params: {
      keyVaultName: keyVaultName
      name: config.keyName
      kty: kty
      keySize: 4096
      attributesEnabled: true
      attributesExportable: false
      rotationPolicy: rotationPolicy
      tags: parentTag
    }
  }
]

// ─── Disk: DiskEncryptionSets ─────────────────────────────────────────────────

module diskEncryptionSets '../../compute/diskEncryptionSets/deploy.bicep' = [
  for (config, i) in diskEncryptionConfigs: {
    name: 'CMK-DiskEncryptionSet-${i}-${deploymentSuffix}'
    params: {
      name: config.diskEncryptionSetName
      location: location
      keyVaultResourceId: keyVaultResourceId
      keyName: config.keyName
      encryptionType: (config.?confidentialVMOSDiskEncryption ?? false)
        ? 'ConfidentialVmEncryptedWithCustomerKey'
        : (!contains(keyManagementType, 'Platform')
            ? 'EncryptionAtRestWithCustomerKey'
            : 'EncryptionAtRestWithPlatformAndCustomerKeys')
      rotationToLatestKeyVersionEnabled: (config.?confidentialVMOSDiskEncryption ?? false) ? false : true
      systemAssignedIdentity: true
      tags: union(parentTag, tags[?'Microsoft.Compute/diskEncryptionSets'] ?? {})
    }
    dependsOn: [
      diskKeys[i]
    ]
  }
]

// ─── Disk: Role Assignments (Key Vault Crypto Service Encryption User on DES) ─

module diskKeyRoleAssignments '../../keyVault/vaults/keys/roleAssignment.bicep' = [
  for (config, i) in diskEncryptionConfigs: {
    name: 'CMK-DiskKeyRA-EncryptUser-${i}-${deploymentSuffix}'
    scope: resourceGroup(keyVaultSubscriptionId, keyVaultResourceGroup)
    params: {
      keyVaultName: keyVaultName
      keyName: config.keyName
      assignments: [
        {
          principalId: diskEncryptionSets[i].outputs.principalId
          principalType: 'ServicePrincipal'
          roleDefinitionId: roleKeyVaultCryptoEncryptionUser
        }
      ]
    }
  }
]

// ─── Disk: Confidential VM Release User role (CVMOrchestrator) ───────────────

module diskKeyReleaseUserRoleAssignments '../../keyVault/vaults/keys/roleAssignment.bicep' = [
  for (config, i) in diskEncryptionConfigs: if (config.?confidentialVMOSDiskEncryption ?? false) {
    name: 'CMK-DiskKeyRA-ReleaseUser-${i}-${deploymentSuffix}'
    scope: resourceGroup(keyVaultSubscriptionId, keyVaultResourceGroup)
    params: {
      keyVaultName: keyVaultName
      keyName: config.keyName
      assignments: [
        {
          principalId: config.confidentialVMOrchestratorObjectId!
          principalType: 'ServicePrincipal'
          roleDefinitionId: roleKeyVaultCryptoReleaseUser
        }
      ]
    }
  }
]

// ─── Outputs ─────────────────────────────────────────────────────────────────

@description('Resource ID of the shared storage encryption user-assigned identity. Empty when storageKeyNames is empty.')
output storageIdentityResourceId string = !empty(storageKeyNames) ? storageIdentity!.outputs.resourceId : ''

@description('Principal ID of the shared storage encryption user-assigned identity. Empty when storageKeyNames is empty.')
output storageIdentityPrincipalId string = !empty(storageKeyNames) ? storageIdentity!.outputs.principalId : ''

@description('Disk CMK results — one entry per diskEncryptionConfigs element.')
output diskResults diskResultType[] = [
  for (config, i) in diskEncryptionConfigs: {
    diskEncryptionSetResourceId: diskEncryptionSets[i].outputs.resourceId
  }
]

// ─── Output types ─────────────────────────────────────────────────────────────

type diskResultType = {
  diskEncryptionSetResourceId: string
}
