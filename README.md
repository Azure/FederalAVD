# 🖥️ Federal Azure Virtual Desktop Automation

> **Enterprise-grade Azure Virtual Desktop deployment automation for Azure Commercial, Government, Secret, and Top Secret clouds**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Azure](https://img.shields.io/badge/Azure-AVD-0078D4?logo=microsoft-azure)](https://azure.microsoft.com/services/virtual-desktop/)
[![GitHub Copilot](https://img.shields.io/badge/GitHub%20Copilot-enabled-8957e5?logo=github)](https://github.com/features/copilot)

> **New to this repo?** Open GitHub Copilot Chat and ask *"How do I get started with FederalAVD?"* — Copilot is pre-loaded with repo context and can guide you through deployment decisions, parameter choices, and troubleshooting.

---

## 📋 Overview

FederalAVD is a modular deployment and operations toolkit for Azure Virtual Desktop. It can deploy
networking and shared prerequisites, image infrastructure, custom images, and either standard- or
automated-management host pools. Independently deployable add-ons provide profile storage,
monitoring, governance, maintenance, and session-host lifecycle automation.

Most components support Azure Commercial, Azure Government, Azure Government Secret, and Azure
Government Top Secret. Capabilities that depend on preview services, public service endpoints, or
cloud-specific extensions have narrower support and are called out below.

### What You Can Deploy

| Deployment | What it can create | When to use it | Documentation |
| --- | --- | --- | --- |
| 🌐 **Networking** | Resource groups, VNets, purpose-specific subnets, NSGs, NAT Gateway or NVA routing, optional AVD bypass routes, hub peering, DDoS Network Protection, and private DNS zones | Build networking when approved landing-zone networking does not already exist | [Networking](deployments/networking/README.md) |
| 🔒 **AVD Shared Services** | Separate secrets and encryption Key Vaults, optional Log Analytics workspace, AVD Insights DCR/DCE and Azure Monitor Agent identity, and optional shared FSLogix Recovery Services vault and Azure Files backup policy | Seed regional resources before consumers that require credentials, CMK, centralized monitoring, or shared FSLogix backup | [Shared Services](deployments/sharedServices/README.md) |
| 📦 **Image Management** | Azure Compute Gallery, optional artifact and build-log storage, managed identity and RBAC, private endpoints, CMK resources, and a persistent image-build resource group | Host customizations or create and retain custom gallery images | [Image Management](deployments/imageManagement/README.md) |
| 🎨 **Image Build** | Temporary orchestration and image VMs; software installation; custom artifacts; Windows Update; AppX removal; profile-aware VDI optimization; Sysprep; gallery image capture and replication | Bake a controlled custom image without depending on the Azure VM Image Builder service | [Image Build](docs/image-build.md) |
| 🏢 **Standard Host Pool** | Pooled or personal host pool, workspace and application groups, directly managed session-host VMs, power-management scaling, FSLogix storage, monitoring, security, and optional backup | Use in every supported cloud when direct VM lifecycle control is required | [Host Pool Deployment](docs/hostpool-deployment.md) |
| ⚙️ **Automated Host Pool** | Commercial pooled host pool using Session Host Configuration, native Session Host Update, optional dynamic create/delete scaling, FSLogix storage, monitoring, security, and policy-managed guest capabilities | Use when Azure Virtual Desktop should own the VM lifecycle and the preview dependency is acceptable | [Automated Host Pool](deployments/automatedHostPools/README.md) |
| 🔧 **Add-Ons** | Nine independent deployments for alerts, standalone FSLogix storage, policies, additional hosts, image-driven replacement, run commands, and route/quota/key automation | Add only the operational capabilities required by the environment | [Add-Ons](docs/add-ons.md) |

### Cloud and Deployment-Method Boundaries

| Capability | Support boundary |
| --- | --- |
| Core networking, shared services, image, and standard host-pool deployments | Azure Commercial, Government, Secret, and Top Secret, subject to resource-provider and regional availability |
| Automated host pools | Azure Commercial only; pooled only; uses the preview `2025-11-01-preview` AVD API |
| Entra Kerberos for cloud-only identities | Generally available in Azure Commercial and Azure US Government; group-scoped NTFS access and profile sharding require share-level RBAC that is limited to supported Commercial regions |
| Template Spec portal forms and PowerShell / Azure CLI | Supported deployment paths in every cloud, including air-gapped clouds after required files are transferred |
| Blue Button portal links | Azure Commercial and Azure Government only; unavailable in Secret and Top Secret |
| Components that retrieve public service data at runtime | Require a reachable approved endpoint; they are not automatically usable in a disconnected cloud |

---

## 🚀 Quick Start

Ready to deploy? The **[Quick Start Guide](docs/quick-start.md)** walks you through the complete deployment process with decision trees, prerequisites, and step-by-step instructions.

**New to FederalAVD?** → **[Start with the PoC callout in Step 4](docs/quick-start.md#step-4-deploy-host-pool)** (existing VNet + marketplace images, no CMK) | **[Top 5 first-deployment mistakes](docs/troubleshooting.md#top-5-first-deployment-mistakes)**

**👉 [Get Started Now →](docs/quick-start.md)** — choose your path (PoC · custom images · enterprise CMK), review prerequisites, and follow step-by-step instructions. The guide identifies which deployment methods are available in each cloud.

---

## 🏗️ Capability Summary

### Host Pools and Session Hosts

FederalAVD provides two separate host-pool deployments. Both create the AVD control plane and can
integrate profile storage and monitoring, but they have different VM ownership boundaries:

| Capability | Standard host pool | Automated host pool |
| --- | --- | --- |
| Pool types | Pooled and personal | Pooled only |
| VM lifecycle owner | Customer, FederalAVD tooling, or Session Host Replacer | Azure Virtual Desktop |
| Cloud availability | Commercial, Government, Secret, and Top Secret | Commercial only |
| Image source | Marketplace or Compute Gallery | Marketplace or Compute Gallery |
| Capacity management | Fixed host count or scaling plans that start and stop existing VMs | Fixed count, power management, or dynamic create/delete/power-manage scaling |
| Image update | Customer replacement workflow or Session Host Replacer | Native Session Host Update |
| Additional VM deployment | Session Hosts add-on | Change Session Host Configuration or managed instance count |
| Pool conversion | Not supported; deploy and migrate to a new host pool | Not supported; deploy and migrate to a new host pool |

See [Choose a Host Pool Management Approach](docs/host-pool-management.md) before deployment.

### Images and Application Delivery

- Image Management can host artifact ZIPs even when no custom image is built.
- Image Build can install FSLogix, Microsoft 365 Apps, OneDrive, Teams, Windows updates, and custom
  artifact packages; remove selected AppX packages; apply VDI optimization; and capture replicated
  Compute Gallery image versions.
- Customer example artifacts include optional configuration and application patterns. Examples,
  including STIG content, are not applied unless copied into the customer area and selected.
- `Publish-VMApplications.ps1` can publish eligible artifact ZIPs as independently versioned Azure
  Compute Gallery VM Applications. Uploading an artifact does not publish or assign it.
- Standard hosts can receive provisioning customizations or externally managed software. Automated
  hosts can use ordered policy-managed VM Applications and the configuration mechanisms documented
  for Session Host Configuration.

See [Artifacts](docs/artifacts-guide.md), [Image Build](docs/image-build.md), and
[VM Applications](docs/vm-applications.md).

### Identity, Profiles, and Data Protection

- Five session-host identity choices: Active Directory Domain Services, Microsoft Entra Domain
  Services, Entra Kerberos hybrid, Entra Kerberos cloud-only, and Entra ID with FSLogix storage keys.
- Azure Files supports every identity choice. Azure NetApp Files support depends on the selected
  domain-backed architecture; review the compatibility matrix before selection.
- FSLogix Profile, Profile plus Office, and Cloud Cache container patterns, with Azure Files
  sharding and group-scoped permissions where supported.
- Profile storage can be created with a host pool, reused as an existing resource, or deployed
  first with the standalone FSLogix Storage add-on for sharing across host pools.
- Optional Azure Files backup registration uses an existing Recovery Services vault and policy;
  AVD Shared Services can deploy the shared vault and policy. Personal-host VM backup is configured
  separately by the standard host-pool path.
- Optional platform-managed or customer-managed encryption, private endpoints, storage firewall
  rules, and managed-disk network isolation are available where the selected service supports them.

### Monitoring, Governance, and Operations

- Log Analytics, AVD diagnostic settings, Azure Monitor Agent, Data Collection Rules, and optional
  Data Collection Endpoints support AVD Insights monitoring.
- The AVD Alerts add-on deploys host-pool, session-host, connection, FSLogix, VM, storage, NetApp,
  and Service Health alert rules against existing monitoring and notification resources.
- Session Host Policy can independently apply ordered VM Applications, Azure Monitor Agent and DCR
  associations, Guest Attestation, and managed-disk isolation to a dedicated VM resource group.
- Naming convention controls, resource tags, multi-subscription control-plane/monitoring placement,
  custom RBAC guidance, compliance mappings, and air-gapped transfer guidance support enterprise
  operations without claiming that every control is enabled by default.

---

## 🔧 Add-Ons

Optional add-ons are independent deployments. Their prerequisites and compatibility boundaries vary:

| Add-On | Purpose | Compatibility / prerequisite | Documentation |
| --- | --- | --- | --- |
| 🚨 **AVD Alerts** | Deploys Azure Monitor scheduled-query, metric, and Service Health alerts for AVD, VMs, Azure Files, and Azure NetApp Files | Requires an existing Log Analytics workspace with required data and a global Action Group | [AVD Alerts](docs/avd-alerts.md) |
| 📁 **FSLogix Storage** | Provisions Azure Files or Azure NetApp Files profile storage independently of a host-pool deployment | Use before consuming host pools when storage is shared; selected CMK, monitoring, and backup services must already exist | [FSLogix Storage](deployments/add-ons/fslogixStorage/README.md) |
| 🔄 **Session Host Replacer** | Detects new gallery image versions and performs controlled drain-and-replace operations | Standard-management host pools only; not compatible with automated host pools | [Session Host Replacer](docs/session-host-replacer.md) |
| 📊 **Storage Quota Manager** | Monitors and automatically increases Azure Files Premium share quotas before exhaustion | Targets all eligible shares in the selected storage resource group | [Storage Quota Manager](docs/storage-quota-manager.md) |
| 🌐 **M365 Route Table Updater** | Reconciles Microsoft 365 service IP prefixes into an Azure route table for force-tunnel bypass | Requires runtime access to the Microsoft 365 endpoint service and an existing route table | [M365 Route Table Updater](docs/m365-route-table-updater.md) |
| 🖥️ **Additional Session Hosts** | Adds VMs to an existing host pool without redeploying its control plane; also supplies the replacer's VM template | Standard-management host pools only | [Session Hosts](deployments/add-ons/sessionHosts/README.md) |
| 📋 **Session Host Policy** | Applies ordered VM Applications, AVD Insights monitoring, Guest Attestation, and managed-disk isolation policies | Targets a dedicated VM resource group; capability availability must be verified in Secret and Top Secret | [Session Host Policy](deployments/add-ons/sessionHostPolicy/README.md) |
| 📝 **Run Commands on VMs** | Executes inline, URI-hosted, or artifact-storage PowerShell on selected VMs | Resource-group scoped; use only where the VM lifecycle owner permits out-of-band configuration | [Run Commands](deployments/add-ons/runCommandsOnVms/README.md) |
| 🔑 **Update FSLogix Storage Key** | Updates the selected storage account key in Windows Credential Manager on session hosts | For FSLogix storage-key authentication; requires VM and storage key permissions | [Update Storage Key](deployments/add-ons/updateStorageAccountKeyOnSessionHosts/README.md) |

### Operational Scripts

| Tool | Purpose | Documentation |
| --- | --- | --- |
| `New-TemplateSpecs.ps1` | Publish guided portal forms for selected core deployments and add-ons as Azure Template Specs | [Quick Start](docs/quick-start.md#1-publish-the-core-template-specs) |
| `Deploy-ImageManagement.ps1` | Deploy Image Management from a parameter file and optionally update artifact packages | [Automation](docs/automation-guide.md#step-2-deploy-image-management) |
| `Update-ImageArtifacts.ps1` | Merge customer artifact definitions, download or use pre-staged payloads, package artifacts, and upload them to Image Management storage | [Update Image Artifacts](docs/update-image-artifacts.md) |
| `Publish-VMApplications.ps1` | Publish selected artifact ZIPs as immutable Compute Gallery VM Application versions | [VM Applications](docs/vm-applications.md) |
| `Invoke-ImageBuilds.ps1` | Submit repeatable image builds from parameter files | [Automation](docs/automation-guide.md) |
| `Set-SessionHostMaintenanceMode.ps1` | Apply or remove AVD drain mode and a scaling-plan exclusion tag for a numeric host range | [Manual Image Replacement](docs/automation-guide.md#manual-approach-set-sessionhostmaintenancemodeps1) |

---

## 🔒 Zero Trust Security

This solution provides controls that can be selected to align a deployment with
[Microsoft's Zero Trust principles for Azure Virtual Desktop](https://learn.microsoft.com/security/zero-trust/azure-infrastructure-avd).
The controls are conditional: deploying FederalAVD does not by itself satisfy an organization's
complete security or compliance baseline.

### Security Controls

| Layer | Capability |
| --- | --- |
| **🌐 Network** | Session hosts without public IPs; optional private endpoints, firewalls, NSGs, routing, and private DNS |
| **🔐 Identity** | Managed identities for service access; multiple supported session-host and FSLogix identity models; Key Vault-backed deployment credentials |
| **📁 Data** | Azure platform encryption plus optional CMK, private storage connectivity, disk network isolation, and backup integration |
| **🎯 Access** | Scoped RBAC assignments, application-group assignments, and optional session-host Azure Policy controls |
| **📊 Monitoring** | Optional centralized diagnostics and performance collection, plus separately deployed operational alerts |
| **⚙️ Configuration** | Repeatable Bicep deployments, artifact-based customization, image-managed fleet patterns, and policy-managed guest capabilities |

FederalAVD's AVD Insights configuration does not collect the Windows Security event log. Deploy a
supplemental DCR or SIEM agent when audit requirements include Security events. See the
[Compliance Control Mapping](docs/compliance.md#audit-and-accountability-au).

**[Zero Trust Architecture Details](docs/features.md#zero-trust-architecture)**

---

## 🌍 Identity Solutions

Support for multiple identity configurations to meet organizational requirements:

| Identity Solution | Description | Use Case |
| --- | --- | --- |
| **Active Directory Domain Services** | Traditional hybrid identity with AD domain join | Enterprise hybrid environments with on-premises AD |
| **Entra Domain Services** | Managed domain services in Azure | Cloud-focused without on-premises AD infrastructure |
| **Entra Kerberos (Hybrid)** | Entra ID-joined hosts with AD user accounts | Modernizing while maintaining AD user accounts |
| **Entra Kerberos (Cloud-Only)** | Entra-joined hosts and Entra-only users with Azure Files Kerberos | Commercial and Azure US Government; no AD DS dependency; advanced group access is region-limited |
| **Entra ID with Storage Keys** | Entra-joined hosts with FSLogix Azure Files credentials stored per host | Cloud-native deployments that do not use Kerberos; rotate keys operationally |

**[Identity Solutions Details](docs/features.md#identity-solutions)**

---

## 📚 Documentation

### Getting Started

- 📖 [Quick Start Guide](docs/quick-start.md) - Step-by-step deployment instructions with path selection (PoC / custom software / enterprise CMK)
- 🤖 [End-to-End Automation Guide](docs/automation-guide.md) - Chaining steps together and passing outputs
- 🏗️ [Design](docs/design.md) - Architecture and resource organization
- ⚙️ [Parameters Reference](docs/parameters.md) - Per-solution parameter documentation index

### Deployment Guides

- 🌐 [Networking](deployments/networking/README.md) - Deploy VNets, subnets, routing, NSGs, and private DNS
- 🔒 [AVD Shared Services](deployments/sharedServices/README.md) - Deploy shared Key Vault, monitoring, and FSLogix backup resources
- 📦 [Image Management](deployments/imageManagement/README.md) - Deploy gallery, artifact, logging, identity, and image-build resources
- 🏢 [Host Pool Deployment](docs/hostpool-deployment.md) - Deploy AVD host pools
- ⚙️ [Automated Host Pool](deployments/automatedHostPools/README.md) - Deploy Commercial pooled host pools managed by AVD
- 🎨 [Image Build Guide](docs/image-build.md) - Build custom images
- 📦 [Artifacts & Image Management](docs/artifacts-guide.md) - Software artifact system
- 🔧 [Update-ImageArtifacts Script](docs/update-image-artifacts.md) - Script usage guide

### Advanced Topics

- ✨ [Features](docs/features.md) - Detailed feature descriptions
- 🚫 [Limitations](docs/limitations.md) - Known limitations and workarounds
- 🔧 [Troubleshooting](docs/troubleshooting.md) - Common issues and solutions
- 🔐 [Entra Kerberos Setup](docs/entra-kerberos-cloud-only.md) - Kerberos configuration
- 🌐 [Air-Gapped Clouds](docs/air-gapped-clouds.md) - Secret/Top Secret deployment

### Add-Ons

- 📚 [Complete Add-On Catalog](docs/add-ons.md)
- 🚨 [AVD Alerts](docs/avd-alerts.md)
- 📁 [FSLogix Storage](deployments/add-ons/fslogixStorage/README.md)
- 🔄 [Session Host Replacer](docs/session-host-replacer.md)
- 📊 [Storage Quota Manager](docs/storage-quota-manager.md)
- 🌐 [M365 Route Table Updater](docs/m365-route-table-updater.md)
- 🖥️ [Additional Session Hosts](deployments/add-ons/sessionHosts/README.md)
- 📋 [Session Host Policy](deployments/add-ons/sessionHostPolicy/README.md)
- 📝 [Run Commands on VMs](deployments/add-ons/runCommandsOnVms/README.md)
- 🔑 [Update FSLogix Storage Key](deployments/add-ons/updateStorageAccountKeyOnSessionHosts/README.md)

---

## 🤝 Contributing

This project welcomes contributions and suggestions. Most contributions require you to agree to a Contributor License Agreement (CLA) declaring that you have the right to, and actually do, grant us the rights to use your contribution.

When you submit a pull request, a CLA bot will automatically determine whether you need to provide a CLA and decorate the PR appropriately. Simply follow the instructions provided by the bot.

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/). For more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with questions or comments.

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

## ™️ Trademarks

This project may contain trademarks or logos for projects, products, or services. Authorized use of Microsoft trademarks or logos is subject to and must follow [Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/legal/intellectualproperty/trademarks/usage/general). Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion or imply Microsoft sponsorship. Any use of third-party trademarks or logos are subject to those third-party's policies.
