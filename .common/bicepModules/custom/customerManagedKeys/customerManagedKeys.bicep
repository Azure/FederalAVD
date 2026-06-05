// ============================================================================
// Unified Customer-Managed Keys Module
// ============================================================================
// Single module that handles ALL CMK scenarios in the FederalAVD repo:
//
//   PaaS mode     — creates one key + one UAI + role assignment per PaaS
//                   encryption config. The UAI resource ID and principal ID are
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
// Role assignments are made at Key Vault key scope — the most restrictive and
// recommended scope.
// ============================================================================

// ─── Common parameters ───────────────────────────────────────────────────────

@description('Required. Resource ID of the Key Vault in which keys will be created.')
param keyVaultResourceId string

@description('Required. CMK type — drives key type (RSA vs RSA-HSM) and disk encryption type.')
@allowed([
  'CustomerManaged'
  'CustomerManagedHSM'
  'PlatformManagedAndCustomerManaged'
  'PlatformManagedAndCustomerManagedHSM'
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

// ─── PaaS mode parameters ────────────────────────────────────────────────────

@description('''
Optional. Names of Key Vault keys to create for CMK encryption.
One key is created per entry. All keys are assigned to the single identityName UAI.
For a single storage account, pass a one-element array.
For FSLogix with multiple accounts, pass all key names (one per account).
''')
param keyNames string[] = []

@description('Optional. Name of the user-assigned identity to create for CMK. Required when keyNames is not empty.')
param identityName string = ''

// ─── Disk mode parameters ────────────────────────────────────────────────────

@description('''
Optional. Array of disk encryption set CMK configurations.
Each entry produces: one KV key (unless skipKeyCreation), one DiskEncryptionSet,
one key-scoped role assignment (Crypto Service Encryption User).
  keyName                           — name of the key to create
  diskEncryptionSetName             — name of the DiskEncryptionSet to create
  confidentialVMOSDiskEncryption    — when true, uses ConfidentialVmEncryptedWithCustomerKey DES type
                                      and grants CVM Orchestrator the Crypto Release User role
  confidentialVMOrchestratorObjectId — required when confidentialVMOSDiskEncryption is true;
                                       object ID of the Confidential VM Orchestrator
                                       enterprise application (bf7b6499-ff71-4aa2-97a4-f372087be7f0)
  skipKeyCreation                   — when true, skips key creation (key was pre-created via
                                      Run Command or external process due to key release policy
                                      immutability). Used by hostpool Run Command path.
                                      When false/omitted, key is created via ARM with release policy.
                                      WARNING: ARM key creation with keyReleasePolicy is a one-time
                                      operation — the policy is immutable. Re-deploying will fail if
                                      the key already exists. Use skipKeyCreation on subsequent deploys.
''')
param diskEncryptionConfigs diskEncryptionConfigType[] = []

// ─── Types ───────────────────────────────────────────────────────────────────

type diskEncryptionConfigType = {
  @description('Name of the Key Vault key to create or reference for this disk encryption configuration.')
  keyName: string
  
  @description('Name of the Disk Encryption Set resource to create.')
  diskEncryptionSetName: string
  
  @description('When true, configures Confidential VM disk encryption behavior and release-user assignment.')
  confidentialVMOSDiskEncryption: bool?
  
  @description('Object ID of the Confidential VM Orchestrator service principal. Required when confidentialVMOSDiskEncryption is true.')
  confidentialVMOrchestratorObjectId: string?
  
  @description('When true, skips ARM key creation — key was pre-created via Run Command or external process.')
  skipKeyCreation: bool?
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

// Key release policy covering all Azure regions (commercial + sovereign).
// The anyOf structure allows any listed attestation authority to satisfy the policy,
// so a single policy JSON works across all clouds without modification.
// This policy is used for Confidential VM encryption keys (exportable RSA-HSM).
// IMPORTANT: Azure Key Vault key release policies are immutable once set.
// Re-deploying with this policy on an existing key will fail. See documentation.
var cvmKeyReleasePolicy = base64('{"version":"1.0.0","anyOf":[{"authority":"https://sharedeus.eus.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"tdxvm"},{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://sharedwus.wus.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"tdxvm"},{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://sharedneu.neu.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"tdxvm"},{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://sharedweu.weu.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"tdxvm"},{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://sharedsasia.sasia.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"tdxvm"},{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://sharedeasia.easia.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"tdxvm"},{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://sharedjpe.jpe.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"tdxvm"},{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://sharedswn.swn.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"tdxvm"},{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://shareditn.itn.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"tdxvm"},{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://sharedeus2.eus2.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"tdxvm"},{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://sharedeus2e.eus2e.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"tdxvm"},{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://sharedscus.scus.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://sharedcuse.cuse.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://sharedcus.cus.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"tdxvm"},{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://sharedeau.eau.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"tdxvm"},{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://sharedsau.sau.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"tdxvm"},{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://sharedcin.cin.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://shareduaen.uaen.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://shareddewc.dewc.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://sharedwus3.wus3.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"tdxvm"},{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]}]}')

// ─── PaaS: Keys ──────────────────────────────────────────────────────────────

module paasKeys '../../keyVault/vaults/keys/deploy.bicep' = [
  for (keyName, i) in keyNames: {
    name: 'CMK-PaaSKey-${i}-${deploymentSuffix}'
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

// ─── PaaS: User-Assigned Identity (single, shared by all keys) ──────────────
// Deployed whenever keyNames is non-empty. Callers on the SAI path (e.g. RSV)
// do not invoke this module at all — they manage their own identity and RBAC.

module paasIdentity '../../managedIdentity/userAssignedIdentities/deploy.bicep' = if (!empty(keyNames)) {
  name: 'CMK-PaaSUAI-${deploymentSuffix}'
  params: {
    name: identityName
    location: location
    tags: union(parentTag, tags[?'Microsoft.ManagedIdentity/userAssignedIdentities'] ?? {})
  }
}

// ─── PaaS: Role Assignments (Key Vault Crypto Service Encryption User) ──────
// One role assignment per key, all scoped to the same shared UAI.

module paasKeyRoleAssignments '../../keyVault/vaults/keys/roleAssignment.bicep' = [
  for (keyName, i) in keyNames: {
    name: 'CMK-PaaSKeyRA-${i}-${deploymentSuffix}'
    scope: resourceGroup(keyVaultSubscriptionId, keyVaultResourceGroup)
    params: {
      keyVaultName: keyVaultName
      keyName: keyName
      assignments: [
        {
          principalId: paasIdentity!.outputs.principalId
          principalType: 'ServicePrincipal'
          roleDefinitionId: roleKeyVaultCryptoEncryptionUser
        }
      ]
    }
    dependsOn: [
      paasKeys[i]
    ]
  }
]

// ─── Disk: Keys ──────────────────────────────────────────────────────────────
// Skipped when skipKeyCreation=true (key pre-created via Run Command).
// For CVM configs without skipKeyCreation, key is created via ARM with
// exportable=true and a key release policy covering all Azure regions.
// WARNING: Key release policies are immutable — re-deploying will fail if the
// key already exists. This is a one-time operation; use skipKeyCreation on
// subsequent deploys or document this as a first-deploy-only step.

module diskKeys '../../keyVault/vaults/keys/deploy.bicep' = [
  for (config, i) in diskEncryptionConfigs: if (!(config.?skipKeyCreation ?? false)) {
    name: 'CMK-DiskKey-${i}-${deploymentSuffix}'
    scope: resourceGroup(keyVaultSubscriptionId, keyVaultResourceGroup)
    params: {
      keyVaultName: keyVaultName
      name: config.keyName
      kty: kty
      keySize: 4096
      attributesEnabled: true
      attributesExportable: config.?confidentialVMOSDiskEncryption ?? false
      keyOps: (config.?confidentialVMOSDiskEncryption ?? false)
        ? ['encrypt', 'decrypt', 'sign', 'verify', 'wrapKey', 'unwrapKey']
        : []
      rotationPolicy: (config.?confidentialVMOSDiskEncryption ?? false) ? {} : rotationPolicy
      keyReleasePolicy: (config.?confidentialVMOSDiskEncryption ?? false)
        ? { data: cvmKeyReleasePolicy, contentType: 'application/json; charset=utf-8' }
        : {}
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

@description('Resource ID of the CMK encryption user-assigned identity. Empty when no CMK keys are requested.')
output identityResourceId string = !empty(keyNames) ? paasIdentity!.outputs.resourceId : ''

@description('Principal ID of the CMK encryption user-assigned identity. Empty when no CMK keys are requested.')
output identityPrincipalId string = !empty(keyNames) ? paasIdentity!.outputs.principalId : ''

@description('Disk CMK results — one entry per diskEncryptionConfigs element.')
output diskResults diskResultType[] = [
  for (config, i) in diskEncryptionConfigs: {
    diskEncryptionSetResourceId: diskEncryptionSets[i].outputs.resourceId
  }
]

// ─── Output types ─────────────────────────────────────────────────────────────

type diskResultType = {
  @description('Resource ID of the Disk Encryption Set created for the corresponding diskEncryptionConfigs entry.')
  diskEncryptionSetResourceId: string
}
