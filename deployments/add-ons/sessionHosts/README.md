# AVD Session Hosts Add-On

> **Part of the [Federal AVD Solution](../../../README.md)** | See also: [Features Overview](../../../docs/features.md) | [Quick Start Guide](../../../docs/quickStart.md)

Deploy Azure Virtual Desktop session hosts into an existing host pool — without touching the host pool infrastructure.

## Table of Contents

- [Overview](#overview)
- [When to Use This vs. the Host Pool Template](#when-to-use-this-vs-the-host-pool-template)
- [What Gets Deployed](#what-gets-deployed)
- [Prerequisites](#prerequisites)
- [Deployment Options](#deployment-options)
- [Key Parameters](#key-parameters)

---

## Overview

The Session Hosts add-on is a focused, standalone template that adds virtual machines to an existing AVD host pool. It handles everything needed for the VMs themselves — VM creation, disk attachment, NIC provisioning, domain join or Entra ID join, AVD agent registration, FSLogix configuration, and optional monitoring extensions — but it requires the host pool, network, Key Vault, and FsLogix infrastructure to already exist.

**Key capabilities:**

- All five identity solutions: ADDS, Entra Domain Services, Entra ID, Entra Kerberos (Hybrid), Entra Kerberos (Cloud-Only)
- Flexible VM naming: enter a prefix + count + starting index, or supply an explicit list of names
- Trusted Launch and Confidential VM security types with vTPM and Secure Boot
- Marketplace images and Azure Compute Gallery images
- Availability Zones and Availability Sets
- Optional FSLogix configuration (Azure Files or Azure NetApp Files, including Cloud Cache)
- Optional Azure Monitor / VM Insights monitoring
- Optional post-deployment customizations via the artifacts system
- Batched deployments to stay within ARM resource limits (up to 45 VMs per batch, auto-calculated)
- Multi-cloud support (Commercial, GCC, GCC High, DoD, Secret, Top Secret)

---

## When to Use This vs. the Host Pool Template

The [host pool template](../../hostpools/README.md) has a **SessionHostsOnly** deployment mode that adds session hosts to an existing pool. Both templates ultimately do the same job, but they have different audiences and complexity levels.

| | **Session Hosts Add-On** | **Host Pool — SessionHostsOnly mode** |
|--|--|--|
| **Best for** | Lower-complexity deployments, day-to-day capacity additions, teams that don't need to adjust host pool or storage settings | Teams already operating with the full host pool template and its parameter model |
| **Deployment surface** | Focused — only session host parameters | Full host pool parameter set; unused parameters still need values |
| **Portal UI** | Streamlined wizard scoped to session host settings | Full host pool wizard; many steps are skipped but still visible |
| **Integration with Session Host Replacer** | ✅ This add-on is the deployment template the SHR function app calls to create replacement hosts | Uses the host pool template via Template Spec |
| **Infrastructure awareness** | Reads host pool tags to auto-populate naming convention and identity defaults | Reads the same tags; more infrastructure options visible |

**Rule of thumb:** If you already deployed your host pool with the FederalAVD host pool template and want to add hosts, either option works. If you are a lower-level admin adding capacity, or you are deploying from a non-standard setup, use this add-on — it has less to configure and less to get wrong.

---

## What Gets Deployed

All resources are deployed into the **existing session hosts resource group** (inferred from the host pool's `hostsResourceGroupId` tag, or specified directly).

| Resource | Notes |
|----------|-------|
| Virtual Machines | Windows Server or Windows client SKU depending on host pool type |
| Network Interface Cards | One per VM; optionally with IPv6, accelerated networking |
| OS Managed Disks | Premium SSD, Standard SSD, or Standard HDD |
| Availability Sets | Created when Availability Sets mode is selected |
| AVD Agent & Boot Loader | Registered to the target host pool |
| Domain Join Extension | ADDS and Entra Domain Services identity solutions |
| Entra ID / Intune Enrollment | Entra ID–based identity solutions |
| GPU Driver Extension | Automatically applied for NV-series (AMD or NVIDIA) VM sizes |
| Azure Monitor Agent | Optional; deployed when monitoring is enabled |
| Data Collection Rule Associations | Optional; AVD Insights and/or VM Insights |
| FSLogix Configuration | Optional; configures registry and SMB share paths via Run Command |
| Custom Artifacts (Run Commands) | Optional; runs scripts from your artifacts storage container |

---

## Prerequisites

### Infrastructure

These resources must exist before deploying.

| Prerequisite | Details |
|---|---|
| **AVD Host Pool** | An existing host pool. The template registers new VMs to this pool and reads its tags for defaults. |
| **Session Hosts Resource Group** | The resource group where VMs will land. Typically tagged on the host pool as `hostsResourceGroupId`. |
| **Virtual Network Subnet** | A subnet the VM NICs will attach to. Must have connectivity to [required AVD endpoints](https://learn.microsoft.com/azure/virtual-desktop/required-fqdn-endpoint?tabs=azure). |
| **Credentials Key Vault** | A Key Vault containing the secrets listed below. The deploying identity needs `Key Vault Secrets User` on this vault. |

### Credentials Key Vault Secrets

The Key Vault must contain these secrets **with these exact names**:

| Secret Name | Required | Description |
|---|---|---|
| `VirtualMachineAdminUserName` | Always | Local administrator username for the session host VMs |
| `VirtualMachineAdminPassword` | Always | Local administrator password |
| `DomainJoinUserPrincipalName` | ADDS / Entra DS only | UPN of the account used to domain-join VMs |
| `DomainJoinUserPassword` | ADDS / Entra DS only | Password for the domain join account |

> If you deployed your host pool using FederalAVD, your operations Key Vault already contains these secrets.

### Permissions

The **deploying identity** (your account, a service principal, or a pipeline identity) needs the following:

| Scope | Role | Why |
|---|---|---|
| Session hosts resource group | **Contributor** | Create VMs, disks, NICs, availability sets |
| Credentials Key Vault | **Key Vault Secrets User** | Read VM admin and domain join credentials |
| Subnet | **Network Contributor** or **Virtual Machine Contributor** on the RG | Attach NICs to the subnet |

Additional permissions for optional features:

| Scenario | Additional Role |
|---|---|
| Intune auto-enrollment | The VMs' managed identity is enrolled automatically; no extra role needed for the deployer |
| Custom artifacts (scripts) | **Storage Blob Data Reader** on the artifacts container, granted to the artifacts user-assigned identity (not the deployer) |
| AVD Insights / VM Insights monitoring | The data collection rules must already exist; deployer needs **Contributor** on the DCR resource group to create associations |

### Optional Prerequisites

These are only needed if you want to configure the corresponding features:

| Feature | What to Prepare |
|---|---|
| **FSLogix (Azure Files)** | Storage accounts with file shares already created; accounts accessible from the subnet |
| **FSLogix (Azure NetApp Files)** | NetApp volumes already created and accessible; SMB server FQDNs are resolved automatically |
| **Custom image (Compute Gallery)** | An image version in an Azure Compute Gallery accessible from this subscription |
| **Monitoring** | Log Analytics workspace, data collection endpoint, and data collection rules for AVD Insights and/or VM Insights already deployed |
| **Artifacts** | Image Management resources deployed; artifacts container URI and user-assigned identity resource ID available |
| **Dedicated hosts** | Dedicated host groups and/or hosts pre-created; resource IDs available |

---

## Deployment Options

### Azure Portal

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2Ffederalavd%2Fmain%2Fdeployments%2Fadd-ons%2FsessionHosts%2Fmain.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2Ffederalavd%2Fmain%2Fdeployments%2Fadd-ons%2FsessionHosts%2FuiFormDefinition.json) [![Deploy to Azure Gov](https://aka.ms/deploytoazuregovbutton)](https://portal.azure.us/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2Ffederalavd%2Fmain%2Fdeployments%2Fadd-ons%2FsessionHosts%2Fmain.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2Ffederalavd%2Fmain%2Fdeployments%2Fadd-ons%2FsessionHosts%2FuiFormDefinition.json)

> **Air-gapped clouds (Secret / Top Secret):** Use [`New-TemplateSpecs.ps1`](../../../tools/New-TemplateSpecs.ps1) to create a Template Spec, then deploy from the portal using the spec.

### PowerShell — Minimal Example

Add 3 session hosts using a prefix + index range. Replace placeholder values with your own.

```powershell
New-AzResourceGroupDeployment `
    -ResourceGroupName 'rg-avd-sessionhosts-usgv' `
    -TemplateFile 'https://raw.githubusercontent.com/Azure/federalavd/main/deployments/add-ons/sessionHosts/main.json' `
    -hostPoolResourceId '/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.DesktopVirtualization/hostPools/<name>' `
    -credentialsKeyVaultResourceId '/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<name>' `
    -subnetResourceId '/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<subnet>' `
    -identitySolution 'ActiveDirectoryDomainServices' `
    -domainName 'contoso.gov' `
    -imageReference '@{publisher="MicrosoftWindowsDesktop"; offer="windows-11"; sku="win11-23h2-avd"; version="latest"}' `
    -virtualMachineSize 'Standard_D4s_v5' `
    -sessionHostNamePrefix 'avd-vm-' `
    -sessionHostCount 3 `
    -sessionHostIndex 1 `
    -sessionHostNameIndexLength 2 `
    -Verbose
```

### PowerShell — Explicit Name List

Use this form when you have pre-computed names (e.g. from the Session Host Replacer or a naming convention system).

```powershell
New-AzResourceGroupDeployment `
    -ResourceGroupName 'rg-avd-sessionhosts-usgv' `
    -TemplateFile 'https://raw.githubusercontent.com/Azure/federalavd/main/deployments/add-ons/sessionHosts/main.json' `
    -hostPoolResourceId '/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.DesktopVirtualization/hostPools/<name>' `
    -credentialsKeyVaultResourceId '/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<name>' `
    -subnetResourceId '/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<subnet>' `
    -identitySolution 'EntraId' `
    -imageReference '@{id="/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Compute/galleries/<gallery>/images/<def>/versions/<ver>"}' `
    -virtualMachineSize 'Standard_D4s_v5' `
    -sessionHostNames @('avd-vm-04', 'avd-vm-05') `
    -Verbose
```

---

## Key Parameters

### Required

| Parameter | Description |
|---|---|
| `hostPoolResourceId` | Resource ID of the target AVD host pool |
| `credentialsKeyVaultResourceId` | Resource ID of the Key Vault holding VM admin and domain join credentials |
| `subnetResourceId` | Resource ID of the subnet for session host NICs |
| `identitySolution` | Identity join type: `ActiveDirectoryDomainServices`, `EntraDomainServices`, `EntraId`, `EntraKerberos-Hybrid`, `EntraKerberos-CloudOnly` |
| `imageReference` | Object with either marketplace image fields (`publisher`, `offer`, `sku`, `version`) or a Compute Gallery version `id` |
| `virtualMachineSize` | Azure VM size (e.g. `Standard_D4s_v5`) |

### VM Naming — Choose One Mode

**Convention mode** (portal UI and manual scripts):

| Parameter | Default | Description |
|---|---|---|
| `sessionHostNamePrefix` | *(empty)* | Short prefix for session host names, e.g. `avd-vm-` |
| `sessionHostCount` | `0` | Number of VMs to create |
| `sessionHostIndex` | `0` | Starting index number (e.g. `4` → first host is `avd-vm-04`) |
| `sessionHostNameIndexLength` | `2` | Number of digits to zero-pad the index (e.g. `2` → `04`, `3` → `004`) |

**Explicit list mode** (Session Host Replacer and automation):

| Parameter | Description |
|---|---|
| `sessionHostNames` | Array of exact session host names to create; overrides convention mode when non-empty |

### Automatic Resource Naming Convention

The template auto-detects the naming convention from the host pool name and applies it to all associated resources. No configuration is needed — it mirrors the convention used by the Session Host Replacer and the host pool template.

| Host pool name format | Convention | Example session host `avd-01` produces |
|---|---|---|
| `hp-avd-01-eus` (type at start) | Resource type prefix | VM: `vm-avd-01`, NIC: `nic-avd-01`, Disk: `osdisk-avd-01` |
| `avd-01-eus-hp` (type at end) | Resource type suffix | VM: `avd-01-vm`, NIC: `avd-01-nic`, Disk: `avd-01-osdisk` |

Availability sets follow the host pool base name: e.g. `as-avd-01-eus-01` or `avd-01-eus-as-01`.

Override params (`virtualMachineNameConv`, `networkInterfaceNameConv`, `osDiskNameConv`, `availabilitySetNameConv`) are available for brownfield environments with non-standard naming. Use `SHNAME` as the session host name token and `##` as the availability set index token.

### Common Optional Parameters

| Parameter | Default | Description |
|---|---|---|
| `availability` | `None` | `None`, `AvailabilitySets`, or `AvailabilityZones` |
| `availabilityZones` | `[]` | Zones to distribute hosts across when using `AvailabilityZones` |
| `diskSku` | `Premium_LRS` | OS disk SKU: `Premium_LRS`, `StandardSSD_LRS`, `Standard_LRS` |
| `diskSizeGB` | `0` | OS disk size in GB; `0` uses the image default |
| `securityType` | `TrustedLaunch` | `Standard`, `TrustedLaunch`, or `ConfidentialVM` |
| `secureBootEnabled` | `true` | Enable Secure Boot (TrustedLaunch / ConfidentialVM) |
| `vTpmEnabled` | `true` | Enable vTPM (TrustedLaunch / ConfidentialVM) |
| `integrityMonitoring` | `false` | Enable Guest Attestation extension for integrity monitoring |
| `encryptionAtHost` | `true` | Enable encryption at host for VM disks |
| `enableAcceleratedNetworking` | `true` | Enable accelerated networking on NICs |
| `enableIPv6` | `false` | Attach an IPv6 configuration to each NIC |
| `domainName` | *(empty)* | FQDN of the AD domain; required for ADDS and Entra DS |
| `ouPath` | *(empty)* | OU distinguished name for computer objects; defaults to domain's Computers container |
| `intuneEnrollment` | `false` | Enroll VMs in Microsoft Intune (Entra ID–based identity solutions only) |
| `timeZone` | `Eastern Standard Time` | Windows time zone name for the session hosts |
| `fslogixConfigureSessionHosts` | `false` | Configure FSLogix registry settings and share paths during deployment |
| `enableMonitoring` | `false` | Deploy Azure Monitor Agent and create AVD Insights / VM Insights DCR associations |
| `sessionHostCustomizations` | `[]` | Array of custom script configurations run via the artifacts system after VM provisioning |
| `tags` | `{}` | Tags applied to deployed resources, organized by resource type |
