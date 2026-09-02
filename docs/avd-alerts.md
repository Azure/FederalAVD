[**Home**](../README.md) | [**Quick Start**](quick-start.md) | [**Add-Ons**](add-ons.md) | [**Host Pool Deployment**](hostpool-deployment.md) | [**Image Build**](image-build.md) | [**Artifacts**](artifacts-guide.md) | [**Features**](features.md) | [**Parameters**](parameters.md) | [**Compliance**](compliance.md) | [**BCDR**](bcdr.md)

# AVD Alerts Add-On

> **For complete deployment instructions, parameter reference, architecture details, and troubleshooting, see the [AVD Alerts Add-On Documentation](../deployments/add-ons/avdAlerts/README.md).**
> **For per-alert response guidance, see the [Alert Response Playbook](../deployments/add-ons/avdAlerts/ALERT-RESPONSE.md).**

## Overview

The AVD Alerts Add-On deploys 42 Azure Monitor alert rules for Azure Virtual Desktop. A single subscription-scoped deployment covers any number of host pools, storage accounts, and ANF volumes.

**Key Features:**
- **Comprehensive coverage**: Host pool capacity, session host health, user connections, FSLogix profiles, VM performance, Azure Files, ANF, and Service Health — all in one deployment
- **Host pool type gating**: Capacity alerts automatically deploy only for Pooled host pools; personal host alerts deploy only for Personal pools
- **Cloud-agnostic**: All FSLogix queries use cloud-agnostic patterns; works in Commercial, Government, and air-gapped clouds
- **Enriched FSLogix alerts**: Profile alerts include UserName, ProfileID, SessionHostName, and StorageAccount for immediate actionability
- **Configurable categories**: Each alert category can be enabled or disabled independently
- **Auto-resolve**: Alerts automatically close when the underlying condition clears

## Alert Categories

| Category | Alerts | Condition |
| --- | --- | --- |
| Host Pool Capacity | 3 | Load at 50% / 85% / 95% — Pooled only |
| Host Pool Availability | 3 | No resources, health check failure, personal host unhealthy |
| User Connections | 4 | Auth/service connection failure, session host connection failure, disconnected sessions (configurable threshold, default 8h), slow logon (configurable threshold, default 2 min) |
| Session Host Disk | 2 | Local C: drive free space <= 10% / 5% |
| FSLogix Profiles | 10 | VHD full (5% / 2%), network issue, initial attach failure, VHD reattach failure, service disabled, compaction, VHD in use, corrupted, compaction pre-check |
| VM Performance | 6 | CPU > 85% / 95%, Memory < 2 GB / 1 GB, OS Disk bandwidth > 85% / 95% |
| Azure Files Storage | 8 | Server + E2E latency (Warn / Crit, 4 rules), availability < 99%, throttling, low space 15% / 5% — optional |
| Azure NetApp Files | 2 | Volume capacity >= 85% / 95% — optional |
| Azure Service Health | 4 | Service incident, planned maintenance, health advisory, security advisory |

## Prerequisites

- Log Analytics Workspace with AVD diagnostics enabled (configured at host pool deployment)
- Action Group at the **global** location in the same subscription — required for Service Health alerts
- Subscription-level deployment permissions (the template is subscription-scoped)

## Deployment

### Template Spec Portal Form (First Deployment)

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

In the Azure portal, open **Template Specs**, select **AVD Alerts**, and choose **Deploy**. On
**Review + create**, select **Create**. After the deployment is submitted, select **Download
template and parameters** and retain the working parameter file for subsequent PowerShell or CI/CD
deployments.

### Blue Button (Azure Commercial / Government Alternative)

[![Deploy to Azure](images/deploytoazurebutton.png)](https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fadd-ons%2FavdAlerts%2Fmain.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fadd-ons%2FavdAlerts%2FuiFormDefinition.json) [![Deploy to Azure Gov](images/deploytoazuregovbutton.png)](https://portal.azure.us/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fadd-ons%2FavdAlerts%2Fmain.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fadd-ons%2FavdAlerts%2FuiFormDefinition.json)

### PowerShell (Subsequent Deployments)

```powershell
New-AzSubscriptionDeployment `
  -Location 'eastus2' `
  -TemplateFile '.\deployments\add-ons\avdAlerts\main.json' `
  -resourceGroupName 'rg-avd-operations-p-eus2' `
  -logAnalyticsWorkspaceResourceId '/subscriptions/{sub-id}/resourceGroups/{rg}/providers/Microsoft.OperationalInsights/workspaces/{workspace}' `
  -actionGroupResourceId '/subscriptions/{sub-id}/resourceGroups/{rg}/providers/Microsoft.Insights/actionGroups/{ag-name}' `
  -hostPoolInfo @(@{hostPoolResourceId='/subscriptions/...'; vmResourceGroupId='/subscriptions/...'; hostPoolType='Pooled'})
```

## Zero Trust Alignment

| Control | Implementation |
| --- | --- |
| No public inbound access | Automation Account: `publicNetworkAccess: false` |
| No stored credentials | System-assigned managed identity; `disableLocalAuth: true` |
| Least-privilege RBAC | Desktop Virtualization Reader (subscription), Log Analytics Contributor (workspace RG), Storage Account Contributor (storage RG) |
| Diagnostic logging | Automation Account job logs → Log Analytics workspace |
| Global action group enforced | UI form lists only `global`-location action groups — required for Service Health alerts |

> **No Private Link or Hybrid Worker required.** The AVD Alerts runbook communicates exclusively with Azure Resource Manager using its managed identity. ARM endpoints are identity-gated, TLS-protected, and FedRAMP High authorized. Blocking inbound public access is the only required network control. See [add-ons.md — Zero Trust Alignment](add-ons.md#zero-trust-alignment) for the NIST control mapping and full rationale.

## Redeployment

Standard redeployments are fully idempotent — leave `createJobSchedules = true`. The `false` value is only needed when the Automation Account was deleted from ARM and recreated with the same name.

## Compliance Coverage

| Control Family | Coverage |
| --- | --- |
| AU — Audit and Accountability | Service Health and Automation Account job logs sent to Log Analytics |
| CA — Assessment and Authorization | Health check alerts surface configuration drift in real time |
| CM — Configuration Management | Health check failure alerts detect unauthorized service changes (FSLogix service disabled) |
| IR — Incident Response | All Sev 1 alerts trigger immediate incident response workflows |
| SI — System and Information Integrity | Storage availability, throttling, and capacity alerts prevent data integrity failures |
| SC — System and Communications Protection | No public endpoints on Automation Account; all runbook traffic to ARM over TLS 1.2+ with managed identity (SC-7, SC-12, SC-13) |

See [compliance.md](compliance.md) for the full control mapping.

