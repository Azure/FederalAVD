[**Home**](../README.md) | [**Quick Start**](quick-start.md) | [**Add-Ons**](add-ons.md) | [**Host Pool Deployment**](hostpool-deployment.md) | [**Image Build**](image-build.md) | [**Artifacts**](artifacts-guide.md) | [**Features**](features.md) | [**Parameters**](parameters.md) | [**Compliance**](compliance.md) | [**BCDR**](bcdr.md)

# Add-Ons

Add-ons extend the core FederalAVD deployment with operational automation, monitoring, and maintenance capabilities. Each add-on is independently deployed and has no hard dependency on any other add-on.

---

## Available Add-Ons

| Add-On | Purpose | When to Deploy |
|--------|---------|----------------|
| [**AVD Alerts**](avd-alerts.md) | Azure Monitor alert rules for host pools, session hosts, FSLogix, VM performance, storage, and Service Health | Any production AVD environment |
| [**Session Host Replacer**](session-host-replacer.md) | Automatically drains and replaces session hosts when a new gallery image version is published | Environments using custom images with recurring image builds |
| [**Storage Quota Manager**](storage-quota-manager.md) | Automatically expands Azure Files Premium share quotas before they fill up | Environments using Azure Files for FSLogix profile containers |
| [**M365 Route Table Updater**](m365-route-table-updater.md) | Keeps an Azure Route Table current with the latest Microsoft 365 IP ranges | Force-tunneled environments where M365 traffic must bypass the NVA |
| [**Deploy Additional Session Hosts**](../deployments/add-ons/sessionHosts/README.md) | Deploys additional VMs into an existing host pool without modifying host pool infrastructure | Scaling up capacity in an existing host pool |
| [**Run Commands on VMs**](../deployments/add-ons/runCommandsOnVms/README.md) | Executes one or more scripts on selected VMs in a resource group via ARM Run Commands | Ad-hoc patching, configuration, or diagnostics on session hosts |
| [**Update FSLogix Storage Key**](../deployments/add-ons/updateStorageAccountKeyOnSessionHosts/README.md) | Rotates the FSLogix storage account key on all session hosts | Environments using Entra ID-only identities with FSLogix key-based auth that require periodic key rotation |

---

## Deployment Methods

All add-ons support three deployment methods:

| Method | Availability | Best For |
|--------|-------------|----------|
| **Blue Button (Azure Portal)** | Commercial and Government | First deployment with guided form |
| **Template Spec** | All clouds including air-gapped | Repeatable deployments; air-gapped clouds |
| **PowerShell / Azure CLI** | All clouds | Scripted or CI/CD deployments |

### Template Spec — All Add-Ons

```powershell
.\tools\New-TemplateSpecs.ps1 `
  -ResourceGroupName 'rg-avd-operations-p-eus2' `
  -Location 'eastus2' `
  -CreateAddOns $true
```

This publishes all add-on templates as Template Specs in the specified resource group.

---

## Add-On Selection Guide

### Always deploy
- **AVD Alerts** — Every production AVD environment benefits from alerting.

### Deploy when using custom images
- **Session Host Replacer** — Automates the drain-and-replace cycle triggered by new image versions. Without it, you must drain and replace manually using `TagAndDrainSessionHosts.ps1`.

### Deploy when using Azure Files for FSLogix
- **Storage Quota Manager** — Prevents outages caused by share quota exhaustion. Azure Files Premium shares have a fixed provisioned quota; the runbook expands it automatically.

### Deploy when force-tunneling internet traffic
- **M365 Route Table Updater** — Microsoft 365 IP ranges change frequently. Without automation, routes go stale and M365 traffic begins traversing the on-premises path, degrading Teams/OneDrive performance.

---

## Zero Trust Alignment

Each add-on is designed to the same Zero Trust baseline as the core FederalAVD deployment:

| Control | All Automation Add-Ons |
|---------|------------------------|
| No public inbound access | `publicNetworkAccess: false` on all Automation Accounts |
| No stored credentials | System-assigned managed identity only; `disableLocalAuth: true` |
| Least-privilege RBAC | Each add-on's managed identity is scoped to the minimum required resource group |
| Diagnostic logging | Automation Account job logs → Log Analytics workspace |

See the individual add-on pages and [compliance.md](compliance.md) for full control mapping details.
