// ============================================================================
// Hostpool Naming Module
// Computes all resource names for a host pool deployment.
// No resources are deployed — this module is purely for name resolution.
//
// Location: deployments/shared/modules/orchestration/naming/hostPool.bicep
// Called by: standard host pools, automated host pools, and standalone FSLogix storage deployments
// ============================================================================

// Naming convention controlling how all resources are named.
// The default value produces names aligned with the Cloud Adoption Framework (CAF) naming convention:
// resourceType-workload-purpose-location.
// Note: purpose is a FederalAVD addition with no direct CAF equivalent — it provides per-resource
// uniqueness within a deployment.
// Component requirements:
//   purpose      — REQUIRED. Many resources share a type across a host pool deployment (multiple RGs, UAIs,
//                  Key Vaults, DES). Without purpose they produce identical names and the deployment fails.
//   resourceType — Strongly recommended. Without it resource names carry no type identifier.
//   location     — Optional. When omitted the location abbreviation is still embedded in storage account names
//                  and added to Key Vault unique-string seeds so cross-region deployments remain collision-free,
//                  but other resource names will not contain a location segment.
//   workload, freeform1, environment, freeform2 — Optional static tokens.
// Produced automatically by the Portal UI; when deploying via ARM/Bicep CLI, omit to accept the
// defaults or override individual properties.
@description('Optional. Shared naming-convention overrides. Include purpose to distinguish same-type resources; omitted properties retain shared defaults.')
// naming-policy: defaults
param namingConvention object = {
  components: ['resourceType', 'workload', 'purpose', 'location']
  delimiter: '-'
  workload: 'avd'
}

@description('Azure region for VM / session host resources.')
param virtualMachinesRegion string

@description('Azure region for control plane resources (host pool, workspace, app groups).')
param controlPlaneRegion string = virtualMachinesRegion

@description('The zero-padded host pool base name (identifier + optional index), already computed by the caller. Required.')
param identifier string

@description('Global feed region. Pass empty string when there is no global feed workspace.')
param globalFeedRegion string = ''

@description('Existing feed workspace resource ID. When set, its resource group is reused for the control plane. Pass empty string when creating a new workspace.')
param existingFeedWorkspaceResourceId string = ''

@description('Subscription ID that owns Shared Services and control-plane resources. Defaults to the deployment subscription.')
param sharedServicesSubscriptionId string = subscription().subscriptionId

targetScope = 'subscription'

import { namingPolicy, resolveConvention, regionAbbreviation, resourceTypeFirst, resourceName, shortScopedUnique, fslogixStoragePrefix, deploymentVmName, privateEndpointPattern, privateEndpointNicPattern, namePattern } from './naming.bicep'

metadata name = 'Host pool naming'
metadata description = 'Computes names for standard and automated host pools, the dedicated PoC, and shared FSLogix storage. Deploys no resources; preserves solution-specific seeds, constraints, and adoption rules.'

// ── Location resolution ───────────────────────────────────────────────────────
var vmsLocAbbr = regionAbbreviation(virtualMachinesRegion, environment().name)
var cpLocAbbr = regionAbbreviation(controlPlaneRegion, environment().name)

// ── Naming convention components ──────────────────────────────────────────────
var convention = resolveConvention(namingConvention)
var cnv_delimiter = convention.delimiter
var cnv_vmsloc   = !empty(namingConvention.?vmsLocationAbbreviation ?? '')
  ? namingConvention.vmsLocationAbbreviation : vmsLocAbbr
var cnv_cploc    = !empty(namingConvention.?cpLocationAbbreviation  ?? '')
  ? namingConvention.cpLocationAbbreviation  : cpLocAbbr
var cnv_rtCodes = convention.resourceTypeCodes
var cnv_secretsKeyVaultNameOverride = namingConvention.?secretsKeyVaultNameOverride ?? ''
var cnv_encryptionKeyVaultNameOverride = namingConvention.?encryptionKeyVaultNameOverride ?? ''

// ── Derived flags ─────────────────────────────────────────────────────────────
// RT is considered last only when resourceType is explicitly the final non-'none' component.
var cnv_rtFirst = resourceTypeFirst(namingConvention)

// ── Temporary Deployment Resources ───────────────────────────────────────────
var resourceGroupDeployment = resourceName(namingConvention, 'deploymentResourceGroup', cnv_vmsloc, identifier, '')
var depVirtualMachineName = deploymentVmName(namingConvention, cnv_vmsloc, identifier)
var depVirtualMachineDiskName = namePattern('deploymentDisk', { vm: depVirtualMachineName, osdisks: cnv_rtCodes.osdisks })
var depVirtualMachineNicName = namePattern('deploymentNic', { vm: depVirtualMachineName, networkInterfaces: cnv_rtCodes.networkInterfaces })

// ── Operations / Monitoring Resource Groups ───────────────────────────────────
var resourceGroupOperations = resourceName(namingConvention, 'operationsResourceGroup', cnv_vmsloc, identifier, '')
var resourceGroupMonitoring = resourceName(namingConvention, 'monitoringResourceGroup', cnv_vmsloc, identifier, '')
var resourceGroupConsolidated = resourceName(namingConvention, 'consolidatedResourceGroup', cnv_vmsloc, identifier, '')
var sharedResourceGroupOperations = resourceName(namingConvention, 'operationsResourceGroup', cnv_cploc, identifier, '')
var sharedResourceGroupMonitoring = resourceName(namingConvention, 'monitoringResourceGroup', cnv_cploc, identifier, '')

// Seed matches sharedServices.bicep exactly.
var uniqueStringOperations = shortScopedUnique(namingConvention, subscription().subscriptionId, resourceGroupOperations, virtualMachinesRegion)
var sharedUniqueStringOperations = shortScopedUnique(namingConvention, sharedServicesSubscriptionId, sharedResourceGroupOperations, controlPlaneRegion)

// Unique string is embedded in the purpose slot so the final name matches the original CAF pattern:
// kv-avd-sec-{unique}-use  (RT-first)  /  avd-sec-{unique}-use-kv  (RT-last)
// Vault formatting replaces underscores/dots with hyphens and applies the shared length limit.
var keyVaultNameSecrets = !empty(cnv_secretsKeyVaultNameOverride)
  ? cnv_secretsKeyVaultNameOverride
  : resourceName(namingConvention, 'secretsKeyVault', cnv_vmsloc, identifier, uniqueStringOperations)
var keyVaultNameEncryption = !empty(cnv_encryptionKeyVaultNameOverride)
  ? cnv_encryptionKeyVaultNameOverride
  : resourceName(namingConvention, 'encryptionKeyVault', cnv_vmsloc, identifier, uniqueStringOperations)
var sharedKeyVaultNameSecrets = !empty(cnv_secretsKeyVaultNameOverride)
  ? cnv_secretsKeyVaultNameOverride
  : resourceName(namingConvention, 'secretsKeyVault', cnv_cploc, identifier, sharedUniqueStringOperations)
var sharedKeyVaultNameEncryption = !empty(cnv_encryptionKeyVaultNameOverride)
  ? cnv_encryptionKeyVaultNameOverride
  : resourceName(namingConvention, 'encryptionKeyVault', cnv_cploc, identifier, sharedUniqueStringOperations)

// ── Monitoring ────────────────────────────────────────────────────────────────
var dataCollectionEndpointName = resourceName(namingConvention, 'dataCollectionEndpoint', cnv_vmsloc, identifier, '')
var logAnalyticsWorkspaceName = resourceName(namingConvention, 'logAnalyticsWorkspace', cnv_vmsloc, identifier, '')
var sharedDataCollectionEndpointName = resourceName(namingConvention, 'dataCollectionEndpoint', cnv_cploc, identifier, '')
var sharedLogAnalyticsWorkspaceName = resourceName(namingConvention, 'logAnalyticsWorkspace', cnv_cploc, identifier, '')

// ── Global Feed Resources ─────────────────────────────────────────────────────
// Global feed is a single shared resource — no location component in its name.
var globalFeedResourceGroupName = !empty(globalFeedRegion)
  ? resourceName(namingConvention, 'globalFeedResourceGroup', '', identifier, '')
  : ''
var globalFeedWorkspaceName = resourceName(namingConvention, 'globalFeedWorkspace', '', identifier, '')

// ── Control Plane Shared Resources ───────────────────────────────────────────
var resourceGroupControlPlane = sharedResourceGroupControlPlane
var workspaceName = empty(existingFeedWorkspaceResourceId)
  ? resourceName(namingConvention, 'hostWorkspace', cnv_cploc, identifier, '')
  : last(split(existingFeedWorkspaceResourceId, '/'))
var sharedResourceGroupControlPlane = empty(existingFeedWorkspaceResourceId)
  ? resourceName(namingConvention, 'controlPlaneResourceGroup', cnv_cploc, identifier, '')
  : toLower(split(existingFeedWorkspaceResourceId, '/')[2]) == toLower(sharedServicesSubscriptionId)
      ? split(existingFeedWorkspaceResourceId, '/')[4]
      : fail('The existing feed workspace subscription must match the target control-plane subscription.')
var sharedWorkspaceName = resourceName(namingConvention, 'workspace', cnv_cploc, identifier, '')

// ── Control Plane HostPool Resources ──────────────────────────────────────────
var desktopApplicationGroupName = resourceName(namingConvention, 'desktopApplicationGroup', cnv_cploc, identifier, '')
var hostPoolName = resourceName(namingConvention, 'hostPool', cnv_cploc, identifier, '')
var scalingPlanName = resourceName(namingConvention, 'scalingPlan', cnv_cploc, identifier, '')

// ── Common HostPool Naming Conventions ───────────────────────────────────────
var privateEndpointNameConv = privateEndpointPattern(cnv_rtFirst, cnv_rtCodes.privateEndpoints)
var privateEndpointNICNameConv = privateEndpointNicPattern(cnv_rtFirst, cnv_rtCodes.privateEndpoints, cnv_rtCodes.networkInterfaces)

var recoveryServicesVaultNameVMs = resourceName(namingConvention, 'vmBackupVault', cnv_vmsloc, identifier, '')
var recoveryServicesVaultNameFSLogix = resourceName(namingConvention, 'filesBackupVault', cnv_vmsloc, identifier, '')
var sharedRecoveryServicesVaultNameFSLogix = resourceName(namingConvention, 'filesBackupVault', cnv_cploc, identifier, '')
var userAssignedIdentityNameConv = resourceName(namingConvention, 'identityPattern', cnv_vmsloc, identifier, '')
var policyRemediationIdentityName = replace(userAssignedIdentityNameConv, 'TOKEN', namePattern('policyIdentityPurpose', { delimiter: cnv_delimiter }))
var azureMonitorAgentIdentityName = replace(userAssignedIdentityNameConv, 'TOKEN', namePattern('monitorIdentityPurpose', {}))

// ── Compute Resources ─────────────────────────────────────────────────────────
var resourceGroupHosts = resourceName(namingConvention, 'hostsResourceGroup', cnv_vmsloc, identifier, '')
var availabilitySetNameConv = namePattern('availabilitySet', { name: resourceName(namingConvention, 'availabilitySet', cnv_vmsloc, identifier, ''), delimiter: cnv_delimiter })
var virtualMachineNameConv = !empty(namingConvention.?virtualMachineNameConvOverride ?? '') ? namingConvention.virtualMachineNameConvOverride : namingPolicy.patterns.virtualMachine
var virtualMachineDiskNameConv = !empty(namingConvention.?virtualMachineDiskNameConvOverride ?? '') ? namingConvention.virtualMachineDiskNameConvOverride : namingPolicy.patterns.osDisk
var virtualMachineNicNameConv = !empty(namingConvention.?virtualMachineNicNameConvOverride ?? '') ? namingConvention.virtualMachineNicNameConvOverride : namingPolicy.patterns.nic

var diskAccessName = resourceName(namingConvention, 'diskAccess', cnv_vmsloc, identifier, '')
var diskEncryptionSetNameConv = resourceName(namingConvention, 'diskEncryptionSetPattern', cnv_vmsloc, identifier, '')
var diskEncryptionSetNameConfidentialVMs = replace(diskEncryptionSetNameConv, 'TOKEN', namePattern('confidentialDiskPurpose', { delimiter: cnv_delimiter }))
var diskEncryptionSetNameCustomerManaged = replace(diskEncryptionSetNameConv, 'TOKEN', namePattern('customerDiskPurpose', { delimiter: cnv_delimiter }))
var diskEncryptionSetNamePlatformAndCustomerManaged = replace(diskEncryptionSetNameConv, 'TOKEN', namePattern('doubleEncryptionDiskPurpose', { delimiter: cnv_delimiter }))

// ── Storage Resources ─────────────────────────────────────────────────────────
var resourceGroupStorage = resourceName(namingConvention, 'storageResourceGroup', cnv_vmsloc, identifier, '')
var netAppAccountName = resourceName(namingConvention, 'netAppAccount', cnv_vmsloc, identifier, '')
var netAppCapacityPoolName = resourceName(namingConvention, 'netAppCapacityPool', cnv_vmsloc, identifier, '')

// FSLogix storage account naming (max 15 chars for domain-join compatibility)
// Add location to the seed when it is not in the naming convention components,
// matching the same logic used for Key Vault unique strings.
var uniqueStringStorage = shortScopedUnique(namingConvention, subscription().subscriptionId, resourceGroupStorage, virtualMachinesRegion)
var fslogixStorageAccountNamePrefix = fslogixStoragePrefix(namingConvention.?fslogixStoragePrefix ?? '', uniqueStringStorage)

// ── Encryption Key Names ──────────────────────────────────────────────────────
var encryptionKeyNameFSLogix = namePattern('fslogixKey', { identifier: identifier, storagePrefix: fslogixStorageAccountNamePrefix })
var encryptionKeyNameVMs = namePattern('vmKey', { identifier: identifier })
var encryptionKeyNameConfidentialVMs = namePattern('confidentialVmKey', { identifier: identifier })
var encryptionKeyNameRecoveryServices = namePattern('recoveryServicesKey', { identifier: identifier })

// ── Outputs ───────────────────────────────────────────────────────────────────
@description('Temporary deployment resource-group name, derived from the VM-region convention.')
output resourceGroupDeployment   string = resourceGroupDeployment
@description('Temporary deployment VM name, sanitized and limited to 15 characters with its existing uniqueness suffix.')
output depVirtualMachineName     string = depVirtualMachineName
@description('OS disk name for the temporary deployment VM.')
output depVirtualMachineDiskName string = depVirtualMachineDiskName
@description('NIC name for the temporary deployment VM.')
output depVirtualMachineNicName  string = depVirtualMachineNicName

@description('Operations resource-group name in the VM region; also used in the local resource uniqueness seed.')
output resourceGroupOperations   string = resourceGroupOperations
@description('Monitoring resource-group name in the VM region.')
output resourceGroupMonitoring   string = resourceGroupMonitoring
@description('Consolidated host-pool-specific resource group used by the dedicated PoC, not production shared control-plane deployments.')
output resourceGroupConsolidated string = resourceGroupConsolidated
@description('Six-character local operations uniqueness suffix; includes the VM region when location is omitted from the convention.')
output uniqueStringOperations    string = uniqueStringOperations
@description('Local credentials Key Vault name, honoring the explicit override; otherwise sanitized and limited to 24 characters.')
output keyVaultNameSecrets       string = keyVaultNameSecrets
@description('Local encryption Key Vault name, honoring the explicit override; otherwise sanitized and limited to 24 characters.')
output keyVaultNameEncryption    string = keyVaultNameEncryption
@description('Shared operations resource-group name in the control-plane region.')
output sharedResourceGroupOperations string = sharedResourceGroupOperations
@description('Shared monitoring resource-group name in the control-plane region.')
output sharedResourceGroupMonitoring string = sharedResourceGroupMonitoring
@description('Shared production control-plane resource group, or the adopted workspace resource group after subscription validation.')
output sharedResourceGroupControlPlane string = sharedResourceGroupControlPlane
@description('Shared credentials Key Vault name, seeded with the shared-services subscription and control-plane scope unless overridden.')
output sharedKeyVaultNameSecrets string = sharedKeyVaultNameSecrets
@description('Shared encryption Key Vault name, seeded with the shared-services subscription and control-plane scope unless overridden.')
output sharedKeyVaultNameEncryption string = sharedKeyVaultNameEncryption
@description('Shared FSLogix backup vault name in the control-plane region.')
output sharedRecoveryServicesVaultNameFSLogix string = sharedRecoveryServicesVaultNameFSLogix

@description('Data collection endpoint name in the VM region.')
output dataCollectionEndpointName string = dataCollectionEndpointName
@description('Log Analytics workspace name in the VM region.')
output logAnalyticsWorkspaceName   string = logAnalyticsWorkspaceName
@description('Shared data collection endpoint name in the control-plane region.')
output sharedDataCollectionEndpointName string = sharedDataCollectionEndpointName
@description('Shared Log Analytics workspace name in the control-plane region.')
output sharedLogAnalyticsWorkspaceName string = sharedLogAnalyticsWorkspaceName

@description('Global-feed resource-group name without a location component, or empty when no global-feed region is supplied.')
output globalFeedResourceGroupName string = globalFeedResourceGroupName
@description('Global-feed workspace name without a location component. The caller decides whether to deploy it.')
output globalFeedWorkspaceName      string = globalFeedWorkspaceName

@description('Production control-plane resource group; identical to sharedResourceGroupControlPlane.')
output resourceGroupControlPlane    string = resourceGroupControlPlane
@description('Host-pool-specific workspace name for the dedicated PoC, or the supplied existing workspace name.')
output workspaceName                string = workspaceName
@description('Shared production workspace name without a host-pool-specific purpose.')
output sharedWorkspaceName          string = sharedWorkspaceName
@description('Host-pool-specific desktop application-group name in the control-plane region.')
output desktopApplicationGroupName  string = desktopApplicationGroupName
@description('Host-pool-specific host pool name in the control-plane region.')
output hostPoolName                 string = hostPoolName
@description('Host-pool-specific scaling plan name in the control-plane region.')
output scalingPlanName              string = scalingPlanName

@description('Private endpoint naming pattern; the consuming module replaces RESOURCE, SUBRESOURCE, and VNETID.')
output privateEndpointNameConv    string = privateEndpointNameConv
@description('Private endpoint NIC naming pattern; the consuming module replaces RESOURCE, SUBRESOURCE, and VNETID.')
output privateEndpointNICNameConv string = privateEndpointNICNameConv

@description('Host-pool-specific VM backup vault name in the VM region.')
output recoveryServicesVaultNameVMs     string = recoveryServicesVaultNameVMs
@description('FSLogix backup vault name in the VM region.')
output recoveryServicesVaultNameFSLogix string = recoveryServicesVaultNameFSLogix
@description('User-assigned identity naming pattern containing TOKEN for the consuming feature to replace.')
output userAssignedIdentityNameConv     string = userAssignedIdentityNameConv
@description('Session-host policy remediation identity name derived from the identity pattern.')
output policyRemediationIdentityName    string = policyRemediationIdentityName
@description('Azure Monitor Agent identity name derived from the identity pattern.')
output azureMonitorAgentIdentityName    string = azureMonitorAgentIdentityName
@description('Effective convention delimiter, including an explicitly supplied empty delimiter.')
output delimiter                        string = cnv_delimiter

@description('Host-pool-specific session-host resource-group name in the VM region.')
output resourceGroupHosts        string = resourceGroupHosts
@description('Availability-set naming pattern containing the numeric ## placeholder.')
output availabilitySetNameConv   string = availabilitySetNameConv
@description('VM naming pattern containing SHNAME unless overridden by the caller convention.')
output virtualMachineNameConv    string = virtualMachineNameConv
@description('OS disk naming pattern containing SHNAME unless overridden by the caller convention.')
output virtualMachineDiskNameConv string = virtualMachineDiskNameConv
@description('NIC naming pattern containing SHNAME unless overridden by the caller convention.')
output virtualMachineNicNameConv  string = virtualMachineNicNameConv

@description('Disk Access resource name in the VM region.')
output diskAccessName                               string = diskAccessName
@description('Disk Encryption Set naming pattern containing TOKEN for the encryption mode.')
output diskEncryptionSetNameConv                    string = diskEncryptionSetNameConv
@description('Disk Encryption Set name for confidential VMs.')
output diskEncryptionSetNameConfidentialVMs         string = diskEncryptionSetNameConfidentialVMs
@description('Disk Encryption Set name for customer-managed encryption.')
output diskEncryptionSetNameCustomerManaged         string = diskEncryptionSetNameCustomerManaged
@description('Disk Encryption Set name for combined platform-managed and customer-managed encryption.')
output diskEncryptionSetNamePlatformAndCustomerManaged string = diskEncryptionSetNamePlatformAndCustomerManaged

@description('Host-pool-specific FSLogix storage resource-group name in the VM region.')
output resourceGroupStorage          string = resourceGroupStorage
@description('Azure NetApp Files account name for this host pool.')
output netAppAccountName             string = netAppAccountName
@description('Azure NetApp Files capacity-pool name for this host pool.')
output netAppCapacityPoolName        string = netAppCapacityPoolName
@description('Six-character FSLogix storage uniqueness suffix; includes the VM region when location is omitted from the convention.')
output uniqueStringStorage           string = uniqueStringStorage
@description('FSLogix account prefix; normalizes and limits an explicit override to 13 characters, otherwise uses fslogix plus the uniqueness suffix.')
output fslogixStorageAccountNamePrefix string = fslogixStorageAccountNamePrefix

@description('FSLogix encryption key pattern containing the numeric storage-account ## placeholder.')
output encryptionKeyNameFSLogix          string = encryptionKeyNameFSLogix
@description('Session-host VM encryption key name.')
output encryptionKeyNameVMs              string = encryptionKeyNameVMs
@description('Confidential session-host VM encryption key name.')
output encryptionKeyNameConfidentialVMs  string = encryptionKeyNameConfidentialVMs
@description('Recovery Services vault encryption key name.')
output encryptionKeyNameRecoveryServices string = encryptionKeyNameRecoveryServices

@description('Location abbreviation for the VM/session host region (used by callers for non-naming-convention purposes).')
output vmsLocAbbr string = vmsLocAbbr

@description('The effective location abbreviation used in resource names for the VM region. Equals vmsLocationAbbreviation from namingConvention when set; otherwise auto-resolved from locations.json.')
output vmLocationAbbreviation string = cnv_vmsloc
