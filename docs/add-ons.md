[**Home**](../README.md) | [**Quick Start**](quick-start.md) | [**Add-Ons**](add-ons.md) | [**Host Pool Deployment**](hostpool-deployment.md) | [**Image Build**](image-build.md) | [**Artifacts**](artifacts-guide.md) | [**Features**](features.md) | [**Parameters**](parameters.md) | [**Compliance**](compliance.md) | [**BCDR**](bcdr.md)

# Add-Ons

Add-ons extend the core FederalAVD deployment with operational automation, monitoring, and maintenance capabilities. Each add-on is deployed independently; its page identifies any required existing resources or deployment-order dependencies.

---

## Available Add-Ons

| Add-On | Purpose | When to Deploy |
| --- | --- | --- |
| [**AVD Alerts**](avd-alerts.md) | Azure Monitor alert rules for host pools, session hosts, FSLogix, VM performance, storage, and Service Health | Any production AVD environment |
| [**FSLogix Storage**](../deployments/add-ons/fslogixStorage/README.md) | Provisions standalone Azure Files or Azure NetApp Files profile storage | When profile storage must be deployed independently of a host pool |
| [**Session Host Replacer**](session-host-replacer.md) | Automatically drains and replaces session hosts when a new gallery image version is published | Standard-management host pools using custom images with recurring image builds; not automated host pools |
| [**Storage Quota Manager**](storage-quota-manager.md) | Automatically expands Azure Files Premium share quotas before they fill up | Environments using Azure Files for FSLogix profile containers |
| [**M365 Route Table Updater**](m365-route-table-updater.md) | Keeps an Azure Route Table current with the latest Microsoft 365 IP ranges | Force-tunneled environments where M365 traffic must bypass the NVA |
| [**Deploy Additional Session Hosts**](../deployments/add-ons/sessionHosts/README.md) | Deploys additional VMs into an existing host pool without modifying host pool infrastructure | Scaling up capacity in an existing host pool |
| [**Session Host Policy**](../deployments/add-ons/sessionHostPolicy/README.md) | Applies shared VM Applications, AVD Insights monitoring, Guest Attestation, and managed-disk isolation policies | Standard or externally managed session hosts in a dedicated VM resource group |
| [**Run Commands on VMs**](../deployments/add-ons/runCommandsOnVms/README.md) | Executes one or more scripts on selected VMs in a resource group via ARM Run Commands | Ad-hoc patching, configuration, or diagnostics on session hosts |
| [**Update FSLogix Storage Key**](../deployments/add-ons/updateStorageAccountKeyOnSessionHosts/README.md) | Rotates the FSLogix storage account key on all session hosts | Environments using Entra ID-only identities with FSLogix key-based auth that require periodic key rotation |

---

## Deployment Methods

All add-ons support three deployment methods:

| Method | Availability | Best For |
| --- | --- | --- |
| **Template Spec** | All clouds including air-gapped | Every first deployment; guided configuration and parameter generation |
| **Blue Button (Azure Portal)** | Commercial and Government | Portal fallback when publishing a Template Spec is not practical |
| **PowerShell / Azure CLI** | All clouds | Subsequent scripted or CI/CD deployments using exported parameters |

Use the Template Spec portal form for the first deployment of an add-on. On **Review + create**,
select **Create**. After the deployment is submitted, select **Download template and parameters**
and retain the working parameter file for subsequent PowerShell or CI/CD deployments. Hand-author
parameters only when the Template Spec UI is unavailable.

### Template Spec — All Add-Ons

```powershell
.\tools\New-TemplateSpecs.ps1 `
  -ResourceGroupName 'rg-avd-operations-p-eus2' `
  -Location 'eastus2' `
  -createSharedServices $false `
  -createNetwork $false `
  -createImageManagement $false `
  -createCustomImage $false `
  -createHostPool $false `
  -createAutomatedHostPool $false `
  -CreateAddOns $true
```

This publishes all add-on templates as Template Specs in the specified resource group. Publishing
does not deploy the add-ons. In the Azure portal, open **Template Specs**, select the required
add-on, and choose **Deploy**.

---

## Add-On Selection Guide

### Always deploy

- **AVD Alerts** — Every production AVD environment benefits from alerting.

### Deploy when using custom images in a standard host pool

- **Session Host Replacer** — Automates the drain-and-replace cycle triggered by new image versions. Without it, you must drain and replace manually using `TagAndDrainSessionHosts.ps1`.

Automated host pools use native Session Host Configuration and Session Host Update. Don't attach
Session Host Replacer or the Session Hosts add-on because Azure Virtual Desktop exclusively owns
their VM lifecycle. See [Choose a Host Pool Management Approach](host-pool-management.md).

### Deploy when using Azure Files for FSLogix

- **Storage Quota Manager** — Prevents outages caused by share quota exhaustion. Azure Files Premium shares have a fixed provisioned quota; the runbook expands it automatically.

### Deploy when force-tunneling internet traffic

- **M365 Route Table Updater** — Microsoft 365 IP ranges change frequently. Without automation, routes go stale and M365 traffic begins traversing the on-premises path, degrading Teams/OneDrive performance.

---

## Zero Trust Alignment

Each Automation Account add-on is designed to the same Zero Trust baseline as the core FederalAVD deployment:

| Control | All Automation Add-Ons |
| --- | --- |
| No public inbound access | `publicNetworkAccess: false` on all Automation Accounts |
| No stored credentials | System-assigned managed identity only; `disableLocalAuth: true` |
| Least-privilege RBAC | Each add-on's managed identity is scoped to the minimum required resource group |
| Diagnostic logging | Automation Account job logs → Log Analytics workspace |

### Why no Private Link or Hybrid Worker is required

All Automation Account add-ons in this solution share the same execution pattern:

- Runbooks authenticate exclusively with the system-assigned **managed identity** — no stored credentials, no shared keys
- Runbooks communicate only with **Azure Resource Manager (ARM) over HTTPS** — no private endpoints, no VNet resources, no on-premises targets
- Inbound public access is **blocked** (`publicNetworkAccess: false`)

ARM endpoints are identity-gated, TLS-protected, audited, and FedRAMP High authorized. For ARM-only runbooks using managed identity, inbound blocking is the only meaningful network exposure. Once that is addressed, no additional network isolation is required for Zero Trust or NIST 800-53 compliance.

Although the Automation cloud worker runs on shared compute, this is not a compliance issue for ARM-only workloads:

- All calls are identity-bound — no ambient credential exists on the worker
- No sensitive data is processed or stored on the worker
- No private network access occurs from the worker
- All operations are recorded in Azure Activity Logs and Automation job logs

This design satisfies the following NIST SP 800-53 controls without Private Link or a Hybrid Worker:

| Control | How it is met |
| --- | --- |
| **SC-7 / SC-7(5)** Boundary Protection | Inbound public access blocked; all outbound calls go to identity-gated ARM endpoints |
| **AC-4** Information Flow Enforcement | Traffic flows only to authorized ARM endpoints over TLS 1.2+; no unrestricted egress |
| **AC-3** Access Enforcement | Managed identity enforces least-privilege per explicit role assignment; no shared credential |
| **IA-2 / IA-5** Identity & Authentication | System-assigned managed identity — no password, no stored secret, no shared key |
| **SC-12 / SC-13** Cryptographic Protection | All ARM traffic over TLS 1.2+; identity tokens are short-lived and cryptographically signed |
| **AU-2 / AU-6** Audit & Logging | Automation Account job logs and Azure Activity Logs forwarded to Log Analytics |

### When Private Link and a Hybrid Worker are required

A Hybrid Runbook Worker and Private Link are required only when a runbook must reach resources that are inaccessible from the cloud worker, such as:

- Storage accounts or Key Vaults configured with **private endpoints only**
- SQL, PostgreSQL, or Cosmos DB with private endpoint access
- Virtual machines over WinRM or SSH
- Internal REST APIs behind a firewall or NSG
- On-premises resources

None of the Automation Account add-ons in this solution access any of those resources. The cloud worker is the correct and compliant choice for this workload pattern.

See the individual add-on pages and [compliance.md](compliance.md) for full control mapping details.
