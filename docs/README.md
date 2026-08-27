[**Home**](../README.md) | [**Quick Start**](quick-start.md) | [**Host Pool Deployment**](hostpool-deployment.md) | [**Image Build**](image-build.md) | [**Artifacts**](artifacts-guide.md) | [**Features**](features.md) | [**Parameters**](parameters.md) | [**Compliance**](compliance.md) | [**BCDR**](bcdr.md)

# Documentation Index

Use the nav bar above for the primary workflow pages. This index organizes all documentation by topic and audience.

---

## Getting Started

| Page | Description |
| --- | --- |
| [Quick Start Guide](quick-start.md) | Start here to choose standard or automated host-pool management, select only the required deployment steps, and complete a first deployment. New to FederalAVD? See the [PoC callout in Step 4](quick-start.md#step-4-deploy-host-pool). [Top 5 first-deployment mistakes](troubleshooting.md#top-5-first-deployment-mistakes). |
| [Choose a Host Pool Management Approach](host-pool-management.md) | Decision guide for standard versus automated host pools, including lifecycle ownership, cloud and workload support, autoscale, image updates, and where Session Host Replacer fits. |
| [Design](design.md) | Architecture overview — resource organization, naming conventions, resource group layout, and CAF alignment. |
| [Features](features.md) | Capability overview — Zero Trust architecture, multi-subscription support, encryption options, and key solution characteristics. Intro to federal ZT mandates. |
| [Solution Limitations](limitations.md) | Known constraints and unsupported scenarios — identity solution limitations, feature gaps, and workarounds. Read before designing a deployment. |
| [Naming Convention](naming-convention.md) | How FederalAVD names resources — CAF default, `namingConvention` parameter, eight naming segments, cross-solution alignment, and examples. |

---

## Deployment Guides

| Page | Description |
| --- | --- |
| [Host Pool Deployment Guide](hostpool-deployment.md) | Deploying standard-management AVD host pools — prerequisites, deployment methods, parameter walkthrough, post-deployment tasks, scaling, and add-ons. |
| [Automated Host Pool Deployment](../deployments/automatedHostPools/README.md) | Deploying pooled Commercial host pools where Azure Virtual Desktop manages session-host creation, updates, scaling, and deletion. |
| [Custom Image Build Guide](image-build.md) | Building custom session host images with Azure Image Builder — prerequisites, build process, deployment methods, and monitoring. |
| [Artifacts and Image Management Guide](artifacts-guide.md) | Artifact packaging and image management infrastructure — how artifacts are uploaded, referenced, and executed in image builds and session host deployments. |
| [Update-ImageArtifacts.ps1 Script Guide](update-image-artifacts.md) | Reference for the script that downloads, packages, and uploads software artifacts to the artifacts storage account. Covers all download methods including winget, GitHub Releases, and UWP/MSIX preserve-layout. |
| [End-to-End Automation Guide](automation-guide.md) | CI/CD pipeline patterns for automating the full deployment and image refresh lifecycle. |

---

## Security and Compliance

| Page | Description |
| --- | --- |
| [Compliance Control Mapping](compliance.md) | ISSO/AO authorization reference — control-by-control mapping to NIST SP 800-53 / FedRAMP High, DoD SRG IL4/IL5, CMMC 2.0, HIPAA, CJIS, StateRAMP, IRS P1075, ISO 27001, and federal Zero Trust mandates (OMB M-22-09, CISA ZTMM). |
| [Custom RBAC Roles](custom-roles.md) | Least-privilege custom role definitions for each deployment operator (imageManagement, imageBuild, hostpool). Use when built-in roles are too broad. |
| [Grant Graph API Permissions](grant-graph-perms.md) | How to grant Microsoft Graph API permissions to the managed identity used by automation. Required for certain Entra ID operations. |
| [Air-Gapped Cloud Considerations](air-gapped-clouds.md) | Beginner path and authoritative deployment checklist for Azure Secret and Azure Top Secret, including marketplace versus custom images, private DNS deployment, endpoint validation, and artifact transfer. |

---

## Identity and Storage Configuration

| Page | Description |
| --- | --- |
| [Entra Kerberos for Azure Files (Cloud-Only)](entra-kerberos-cloud-only.md) | Configuring Entra ID Kerberos authentication for FSLogix Azure Files storage with cloud-only (non-domain-joined) identities. |
| [Entra Kerberos for Azure Files (Hybrid)](entra-kerberos-hybrid.md) | Configuring Entra ID Kerberos authentication for FSLogix Azure Files storage in hybrid (domain-joined) environments. |

---

## Add-Ons

| Page | Description |
| --- | --- |
| [**Add-Ons Overview**](add-ons.md) | Index of all available add-ons with selection guidance, Zero Trust alignment summary, and deployment methods. Start here. |
| [AVD Alerts](avd-alerts.md) | 40 Azure Monitor alert rules covering host pool capacity, session host health, FSLogix profiles, VM performance, storage, and Service Health. |
| [Session Host Replacer](session-host-replacer.md) | Automated Azure Function that drains and replaces session hosts in standard-management pools when a new gallery image version is published. |
| [Storage Quota Manager](storage-quota-manager.md) | Automated Azure Automation runbook that expands Azure Files Premium share quotas before they fill. Prevents FSLogix profile outages. |
| [M365 Route Table Updater](m365-route-table-updater.md) | Automated Azure Automation runbook that keeps an Azure Route Table current with M365 IP ranges. For force-tunneled environments. |

---

## Operations and Cost Management

| Page | Description |
| --- | --- |
| [BCDR — Business Continuity & Disaster Recovery](bcdr.md) | Availability zones, cross-region replication, FSLogix Cloud Cache, image gallery replication, VM backup, session host replacer rollback, and RTO/RPO reference. |
| [Chargeback for Shared Resources](chargeback-shared-resources.md) | Cost attribution strategies for shared infrastructure (RSV, storage, networking) using existing deployment tags — no code changes required. |

---

## Reference

| Page | Description |
| --- | --- |
| [Parameters Reference](parameters.md) | Parameter documentation for all deployment templates — hostpool, imageBuild, imageManagement, sharedServices, networking — with compliance quick-reference. |
| [Naming Convention](naming-convention.md) | Full naming convention reference — `namingConvention` parameter schema, CAF default patterns, RT-first/RT-last, segment descriptions, and aligned cross-solution examples. |
| [Troubleshooting](troubleshooting.md) | Common deployment errors and fixes — role assignment failures, image build issues, FSLogix authentication errors, and more. |
