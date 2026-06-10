# AVD Session Hosts Add-On

> **Part of the [Federal AVD Solution](../../../README.md)** | See also: [Host Pool Deployment Guide](../../../docs/hostpool-deployment.md) | [Session Host Replacer](../sessionHostReplacer/README.md)

Deploy additional session hosts into an existing Azure Virtual Desktop host pool without modifying any host pool infrastructure.

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Prerequisites](#prerequisites)
- [Deployment](#deployment)
- [Parameters](#parameters)
- [Naming Convention Auto-Detection](#naming-convention-auto-detection)
- [Key Vault Secrets](#key-vault-secrets)
- [Session Host Replacer Integration](#session-host-replacer-integration)

---

## Overview

The Session Hosts add-on provides a standalone Bicep template (`main.bicep`) that deploys virtual machines directly into an existing AVD host pool. It is designed for two scenarios:

1. **Standalone portal deployment** — manually scale out a host pool by adding more session hosts through the Azure portal UI form.
2. **Template Spec target for the Session Host Replacer** — the [Session Host Replacer](../sessionHostReplacer/README.md) function app loads this template as a Template Spec to perform automated, rolling session host replacements.

The template delegates VM creation to the same shared orchestration module used by the full host pool deployment, ensuring complete feature parity including FSLogix, monitoring, security baselines, and customizations.

---

## Features

- **Flexible naming** — convention mode (prefix + auto-incrementing index) or an explicit list of computer names
- **Naming convention auto-detection** — infers VM, NIC, OS disk, and availability set naming patterns from the existing host pool name
- **All identity solutions** — Active Directory Domain Services, Entra Domain Services, Entra ID (cloud-only), Entra Kerberos (cloud-only), and Entra Kerberos (hybrid)
- **Marketplace and custom images** — supports marketplace SKUs or Azure Compute Gallery image versions
- **Availability strategies** — None, Availability Zones, or Availability Sets (with automatic index calculation)
- **FSLogix configuration** — Azure Files or Azure NetApp Files, all container types, cloud cache failover
- **Security** — Trusted Launch, Confidential VM, encryption at host, customer-managed keys, disk access restrictions, Secure Boot, vTPM
- **Monitoring** — Azure Monitor agent with data collection rules and endpoints
- **Post-provisioning customizations** — custom script extension configurations
- **Dedicated host support** — per-VM dedicated host group and host assignments
- **Backup** — optional enrollment in a Recovery Services Vault backup policy (personal host pools)
- **IPv6** — optional dual-stack NIC configuration
- **Intune enrollment** — automatic enrollment for Entra ID-joined hosts
- **Multi-cloud** — Azure Commercial, Azure Government, Azure Government Secret, and Azure Government Top Secret

---

## Prerequisites

Before deploying session hosts, ensure the following are in place:

1. **Existing AVD host pool** with a valid registration token.  
   > To generate a new token: Azure portal → Host Pool → Overview → Registration key → Generate new key.

2. **Credentials Key Vault** containing the required secrets (see [Key Vault Secrets](#key-vault-secrets)).

3. **Subnet** with available IP addresses in the target region.

4. **Image** — a marketplace image SKU or an Azure Compute Gallery image version.

5. *(Optional)* **Artifacts storage** — if using session host customizations, the artifacts container URI and a user-assigned managed identity with `Storage Blob Data Reader` access.

6. *(Optional)* **Monitoring resources** — AVD Insights data collection rule, data collection endpoint resource IDs.

---

## Required Permissions

This template deploys at **resource group scope** — no subscription-level role is required for deployment submission (unlike `hostpool.bicep`).

### Role assignments summary

| Role | Scope | Required for |
|---|---|---|
| `Contributor` | **Hosts resource group** | Create VMs, NICs, OS disks, availability sets, extensions, Run Commands, DCR associations |
| `Desktop Virtualization Host Pool Contributor` | **Host pool resource group** | Read host pool properties and call `listRegistrationTokens` to obtain the registration token |
| `Key Vault Secrets User` | **Credentials Key Vault** | Read `VirtualMachineAdminPassword`, `VirtualMachineAdminUserName`, `DomainJoinUserPassword`, `DomainJoinUserPrincipalName` secrets via `getSecret()` at deployment time |
| `Storage Blob Data Reader` | **Artifacts storage account** | *(Optional)* Download customization scripts and installers from the artifacts container |
| `Key Vault Secrets User` | **Disk encryption Key Vault** | *(Optional)* Read the CMK key URI when `diskEncryptionSetResourceId` is provided |
| `Backup Contributor` | **Recovery Services Vault** | *(Optional)* Enroll VMs in a backup policy when `deployRecoveryServices = true` (personal host pools) |

> **Note on `Contributor` scope:** Contributor on the hosts RG is the minimum practical scope. The VM, NIC, disk, extension, and Run Command resource types span three different resource providers (`Microsoft.Compute`, `Microsoft.Network`, `Microsoft.Insights`) and no single narrower built-in role covers all of them. For a tighter custom role definition see [Custom RBAC Roles — Session Hosts Add-On Operator](../../../docs/custom-roles.md#session-hosts-add-on-operator).

### Comparison with `hostpool.bicep`

The full `hostpool.bicep` template (`targetScope = 'subscription'`) additionally requires `Microsoft.Resources/deployments/write` at **subscription scope** even when no subscription-level resources are being created. This add-on template avoids that requirement because `main.bicep` defaults to `targetScope = 'resourceGroup'`, making it suitable for operators who are constrained to resource group scope.

---

## Deployment

### Azure Portal (UI Form)

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fadd-ons%2FsessionHosts%2Fmain.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fadd-ons%2FsessionHosts%2FuiFormDefinition.json)
[![Deploy to Azure Gov](https://aka.ms/deploytoazuregovbutton)](https://portal.azure.us/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fadd-ons%2FsessionHosts%2Fmain.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fadd-ons%2FsessionHosts%2FuiFormDefinition.json)

The portal form walks through four steps:

| Step | Contents |
|------|----------|
| **Deployment Basics** | Host pool subscription and selection; auto-reads host pool tags to pre-populate defaults |
| **Identity** | Identity solution, domain name, OU path (ADDS/EntraDS), credentials Key Vault |
| **Session Hosts** | Subscription/region/resource group, naming, network, image, VM size, availability, security, FSLogix, monitoring, customizations |
| **Review + Create** | ARM template validation and deployment |

### PowerShell / Azure CLI

Deploy `main.json` (the compiled ARM template) with your parameter values directly:

```powershell
New-AzResourceGroupDeployment `
  -ResourceGroupName '<vm-resource-group>' `
  -TemplateFile 'deployments/add-ons/sessionHosts/main.json' `
  -hostPoolResourceId '<host-pool-resource-id>' `
  -credentialsKeyVaultResourceId '<key-vault-resource-id>' `
  -identitySolution 'ActiveDirectoryDomainServices' `
  -subnetResourceId '<subnet-resource-id>' `
  -virtualMachineSize 'Standard_D4s_v5' `
  -sessionHostNamePrefix 'avd' `
  -sessionHostCount 2 `
  -sessionHostIndex 1
```

### Template Spec (Air-Gapped / All Clouds)

Publish `main.json` as an Azure Template Spec and deploy from there. This is the recommended approach for Secret and Top Secret clouds and is required by the Session Host Replacer function app. See [New-TemplateSpecs.ps1](../../../tools/New-TemplateSpecs.ps1) for the publishing helper script.

---

## Parameters

### Required Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `hostPoolResourceId` | string | Resource ID of the AVD host pool to register session hosts with |
| `credentialsKeyVaultResourceId` | string | Resource ID of the Key Vault containing VM and domain join credentials |
| `identitySolution` | string | Identity join method: `ActiveDirectoryDomainServices`, `EntraDomainServices`, `EntraId`, `EntraKerberos-CloudOnly`, `EntraKerberos-Hybrid` |
| `subnetResourceId` | string | Resource ID of the subnet where session host NICs will be placed |
| `virtualMachineSize` | string | Azure VM SKU for the session hosts (e.g. `Standard_D4s_v5`) |

### Session Host Count and Naming

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `sessionHostCount` | int | `0` | Number of session hosts to deploy (convention mode) |
| `sessionHostIndex` | int | `0` | Starting index for VM name generation (convention mode) |
| `sessionHostNamePrefix` | string | `''` | Short name prefix (e.g. `avd`); ignored when `sessionHostNames` is set |
| `sessionHostNameIndexLength` | int | `2` | Number of zero-padded digits in the index (1–4) |
| `sessionHostNames` | array | `[]` | Explicit list of computer names; overrides convention mode when non-empty |

### Image

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `imageReference` | object | `{}` | Pre-built image reference object; takes precedence over offer/SKU/gallery fields |
| `imagePublisher` | string | `MicrosoftWindowsDesktop` | Marketplace image publisher |
| `imageOffer` | string | `''` | Marketplace image offer (e.g. `Office-365`, `Windows-11`) |
| `imageSku` | string | `''` | Marketplace image SKU (e.g. `win11-25h2-avd-m365`) |
| `customImageResourceId` | string | `''` | Resource ID of an Azure Compute Gallery image version; used when `imageReference` is empty |

### Availability

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `availability` | string | `None` | Availability strategy: `None`, `AvailabilityZones`, `AvailabilitySets` |
| `availabilityZones` | array | `[]` | Availability zones to spread hosts across (when `availability` is `AvailabilityZones`) |
| `availabilitySetNameConv` | string | `''` | Availability set naming convention override (auto-detected when empty) |
| `dedicatedHostGroupResourceIds` | array | `[]` | Per-VM dedicated host group resource IDs |
| `dedicatedHostResourceIds` | array | `[]` | Per-VM dedicated host resource IDs |
| `preferredZones` | array | `[]` | Per-VM preferred availability zones |

### Security

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `securityType` | string | `TrustedLaunch` | VM security profile: `Standard`, `TrustedLaunch`, `ConfidentialVM` |
| `secureBootEnabled` | bool | `true` | Enable Secure Boot |
| `vTpmEnabled` | bool | `true` | Enable virtual TPM |
| `encryptionAtHost` | bool | `true` | Enable encryption at host for all disks and cache |
| `confidentialVMOSDiskEncryption` | bool | `false` | Enable OS disk encryption with VMGuestState (Confidential VMs only) |
| `diskEncryptionSetResourceId` | string | `''` | Resource ID of the disk encryption set for customer-managed key encryption |
| `diskAccessId` | string | `''` | Resource ID of a disk access resource to restrict managed disk network access |
| `integrityMonitoring` | bool | `false` | Enable Guest Attestation extension for boot integrity monitoring |

### Disk

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `diskSku` | string | `Premium_LRS` | OS disk storage SKU: `Standard_LRS`, `StandardSSD_LRS`, `Premium_LRS` |
| `diskSizeGB` | int | `0` | OS disk size in GB; `0` inherits the image default |

### Network

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `enableAcceleratedNetworking` | bool | `true` | Enable accelerated networking on session host NICs |
| `enableIPv6` | bool | `false` | Enable IPv6 dual-stack on session host NICs |

### FSLogix

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `fslogixConfigureSessionHosts` | bool | `false` | Configure FSLogix profile container settings on session hosts |
| `fslogixContainerType` | string | `ProfileContainer` | FSLogix container type: `ProfileContainer`, `ProfileOfficeContainer`, `CloudCacheProfileContainer`, `CloudCacheProfileOfficeContainer` |
| `fslogixStorageService` | string | `AzureFiles` | Storage backend: `AzureFiles`, `AzureNetAppFiles` |
| `fslogixLocalStorageAccountResourceIds` | array | `[]` | Local Azure Files storage account resource IDs |
| `fslogixLocalNetAppVolumeResourceIds` | array | `[]` | Local Azure NetApp Files volume resource IDs |
| `fslogixRemoteStorageAccountResourceIds` | array | `[]` | Remote Azure Files storage account resource IDs (cloud cache failover) |
| `fslogixRemoteNetAppVolumeResourceIds` | array | `[]` | Remote Azure NetApp Files volume resource IDs (cloud cache failover) |
| `fslogixOSSGroups` | array | `[]` | Entra ID group object IDs for Office container separation |
| `fslogixSizeInMBs` | int | `30720` | Maximum FSLogix VHD/VHDX size in megabytes |

### Monitoring

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `enableMonitoring` | bool | `false` | Enable Azure Monitor agent on session hosts |
| `avdInsightsDataCollectionRulesResourceId` | string | `''` | Resource ID of the AVD Insights data collection rule |
| `dataCollectionEndpointResourceId` | string | `''` | Resource ID of the Azure Monitor data collection endpoint |

### Artifacts and Customizations

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `artifactsContainerUri` | string | `''` | URI of the blob storage container holding scripts and artifacts |
| `artifactsUserAssignedIdentityResourceId` | string | `''` | Resource ID of the managed identity with `Storage Blob Data Reader` access |
| `sessionHostCustomizations` | array | `[]` | Custom script extension configurations for post-provisioning customization |

### Identity and Domain Join

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `domainName` | string | `''` | Active Directory domain name; leave empty for Entra ID join |
| `ouPath` | string | `''` | Distinguished Name of the OU for session host computer accounts |
| `intuneEnrollment` | bool | `false` | Enroll session hosts in Microsoft Intune (Entra ID join only) |

### Backup

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `recoveryServicesVaultResourceId` | string | `''` | Resource ID of a Recovery Services Vault for VM backup enrollment |
| `vmBackupPolicyName` | string | `''` | Backup policy name within the vault; defaults to `AvdPolicyVm` when empty |

### Other

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `location` | string | RG location | Azure region for session host VMs |
| `timeZone` | string | `Eastern Standard Time` | Windows time zone for session host VMs |
| `hibernationEnabled` | bool | `false` | Enable VM hibernation |
| `tags` | object | `{}` | Tags applied to all deployed resources, keyed by resource type |
| `agentBootLoaderDownloadUrl` | string | `''` | Override AVD Agent Boot Loader download URL (air-gapped clouds) |
| `agentDownloadUrl` | string | `''` | Override AVD Agent download URL (air-gapped clouds) |
| `virtualMachineNameConv` | string | `''` | VM naming convention override (`SHNAME` placeholder); auto-detected when empty |
| `networkInterfaceNameConv` | string | `''` | NIC naming convention override (`SHNAME` placeholder); auto-detected when empty |
| `osDiskNameConv` | string | `''` | OS disk naming convention override (`SHNAME` placeholder); auto-detected when empty |

---

## Naming Convention Auto-Detection

When naming convention override parameters are left empty, the template infers them from the existing host pool name. It detects whether the host pool follows a `<abbreviation>-<basename>-<location>` (prefix) or `<basename>-<location>-<abbreviation>` (suffix) convention and applies the same pattern to VMs, NICs, OS disks, and availability sets.

This ensures new session hosts are consistent with those already in the pool, which is important for the Session Host Replacer to correctly identify and replace hosts by name.

---

## Key Vault Secrets

The credentials Key Vault must contain the following secrets before deployment:

| Secret Name | Required When | Description |
|-------------|---------------|-------------|
| `VirtualMachineAdminUserName` | Always | Local administrator username for the session host VMs |
| `VirtualMachineAdminPassword` | Always | Local administrator password for the session host VMs |
| `DomainJoinUserPrincipalName` | `identitySolution` contains `DomainServices` | UPN of the domain join service account (e.g. `domjoin@contoso.com`) |
| `DomainJoinUserPassword` | `identitySolution` contains `DomainServices` | Password for the domain join service account |

---

## Session Host Replacer Integration

This template is designed to be published as an Azure Template Spec and consumed by the [Session Host Replacer](../sessionHostReplacer/README.md) function app. When used in that context:

- The Session Host Replacer passes an explicit `sessionHostNames` array (overriding convention mode) to control exactly which VMs are created.
- Naming convention parameters are omitted so the template auto-detects them from the host pool name.
- The same Key Vault and host pool configuration used during the original host pool deployment are reused.

See the [Session Host Replacer documentation](../sessionHostReplacer/README.md) and [New-TemplateSpecs.ps1](../../../tools/New-TemplateSpecs.ps1) for publishing instructions.
