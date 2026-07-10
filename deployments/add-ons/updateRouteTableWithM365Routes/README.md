# M365 Route Table Updater Add-On

> **Part of the [Federal AVD Solution](../../../README.md)** | See also: [Features Overview](../../../docs/features.md) | [Quick Start Guide](../../../docs/quick-start.md)

Automated Azure Automation runbook that keeps an Azure Route Table current with the latest Microsoft 365 IP address ranges, ensuring M365-bound traffic stays on the Microsoft global backbone rather than traversing a force-tunnel to on-premises.

## Table of Contents

- [The Problem This Solves](#the-problem-this-solves)
- [How It Works](#how-it-works)
- [Prerequisites](#prerequisites)
- [Deployment](#deployment)
- [Redeployment](#redeployment)
- [Parameters](#parameters)
- [Architecture](#architecture)
- [Troubleshooting](#troubleshooting)

---

## The Problem This Solves

Many federal and enterprise organizations configure Azure virtual networks with a **default route (0.0.0.0/0) via a Network Virtual Appliance or on-premises gateway** — commonly called force tunneling. Every packet leaving an Azure VM is inspected or routed on-premises before reaching the internet, which satisfies security and audit requirements.

The problem is Microsoft 365. AVD session hosts communicate constantly with Exchange Online, SharePoint Online, Teams, OneDrive, and other M365 workloads. When that traffic is forced on-premises and back to the internet, it:

- **Exits and re-enters the Microsoft backbone** instead of staying on it end-to-end
- **Adds latency** through the on-premises network path
- **Saturates VPN/ExpressRoute bandwidth** with high-volume M365 data flows
- **Breaks real-time workloads** (Teams audio/video) that are latency-sensitive

The fix is to add specific host routes for M365 IP prefixes to the route table with a **Next Hop Type of Internet**. These more-specific routes override the default force-tunnel route and allow M365 traffic to leave Azure directly onto the Microsoft global backbone, where it stays for the entire journey to the Microsoft 365 service edge.

The challenge is that **Microsoft publishes updated M365 IP ranges regularly** (typically every few weeks). Keeping those routes current manually is error-prone and operationally expensive.

This add-on automates the full lifecycle: download, reconcile, and apply on a schedule.

---

## How It Works

1. **Schedule triggers** the runbook at a configurable interval (default: every 8 hours).
2. **Version check**: The runbook reads the current M365 endpoint version from the Microsoft 365 IP/URL web service. If the version matches the tag stored on the route table from the last successful run, no changes are needed and the runbook exits immediately.
3. **Download**: If the version has changed, the runbook downloads the current full IP prefix list for the configured M365 endpoint instance (worldwide, GCC High, DoD, or China).
4. **Reconcile**: The runbook compares the downloaded prefixes against the existing routes in the table whose names start with the instance-specific prefix (`M365-`, `M365-GCCH-`, `M365-DoD-`, or `M365-China-`). Routes for new prefixes are added; routes for removed prefixes are deleted. All other routes in the table are left untouched.
5. **Apply**: A single HTTP PUT updates the route table with the reconciled route set.
6. **Tag update**: The new M365 endpoint version is written back as a tag on the route table, establishing the baseline for the next run.

Multiple instances can coexist in the same route table — each uses its own prefix namespace so their routes never conflict.

---

## Prerequisites

- An Azure Route Table in the same subscription as this deployment.
- A subnet with `publicNetworkAccess: false` or network connectivity suitable for an Automation Account. No public IP is required on the Automation Account; it calls the M365 web service and ARM endpoints outbound via Azure networking.
- Permissions to deploy resources and create role assignments (Owner or User Access Administrator + Contributor on the target resource group and on the route table's resource group).

---

## Deployment

### Template Spec (Recommended)

Publish the template spec using the `New-TemplateSpecs.ps1` tool or publish manually, then deploy from the Azure Portal. The guided form covers all required and optional parameters.

```powershell
New-AzTemplateSpec `
    -Name 'ts-m365-route-table-updater' `
    -ResourceGroupName 'rg-avd-operations' `
    -Version '1.0' `
    -Location 'eastus2' `
    -TemplateFile '.\main.json' `
    -UIFormDefinitionFile '.\uiFormDefinition.json'
```

> For air-gapped clouds (Secret/Top Secret), Blue Button is not available. Use Template Specs or PowerShell.

### Azure PowerShell

```powershell
New-AzResourceGroupDeployment `
    -ResourceGroupName 'rg-avd-operations' `
    -TemplateFile '.\main.json' `
    -routeTableResourceId '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/routeTables/<name>' `
    -m365EndpointInstance 'worldwide'
```

### Azure CLI

```bash
az deployment group create \
  --resource-group rg-avd-operations \
  --template-file main.json \
  --parameters \
      routeTableResourceId='/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/routeTables/<name>' \
      m365EndpointInstance='worldwide'
```

---

## Redeployment

> **Critical — read before redeploying.**

Azure Automation caches the runbook-to-schedule association internally, keyed on the **automation account name**. This cache persists even after deleting the job schedule resource, all child resources, or the automation account itself and recreating it with the same name. If ARM tries to create the `jobSchedule` resource when that cached link already exists, the deployment fails with:

```
A jobSchedule with same id already exists. (Code: Conflict)
```

The template includes a `createJobSchedule` parameter (default `true`) to control this behavior.

| Scenario | `createJobSchedule` |
|---|---|
| First deployment to a new automation account name | `true` (default) |
| Redeployment to an existing automation account | `false` |

**In the Template Spec form:** Advanced tab → **Job Schedule** section → uncheck **"Create Job Schedule Link"** before redeploying.

**Via PowerShell:**
```powershell
New-AzResourceGroupDeployment ... -createJobSchedule $false
```

The existing link is not affected when `createJobSchedule` is `false` — the runbook continues to run on its schedule.

### Managing the Job Schedule from Cloud Shell

Because `publicNetworkAccess` is `false` on the Automation Account, all job schedule management must be performed from **Azure Cloud Shell** (which runs inside Azure's network). Local PowerShell, the Azure CLI, and the Azure Portal browser-side calls cannot reach the Automation Account's child resources.

**List and delete the job schedule link (Cloud Shell only):**

```powershell
$aaName = 'your-automation-account-name'
$rgName  = 'your-resource-group-name'
$subId   = (Get-AzContext).Subscription.Id
$base    = "/subscriptions/$subId/resourceGroups/$rgName/providers/Microsoft.Automation/automationAccounts/$aaName"

# List existing job schedules
$jsResponse = Invoke-AzRestMethod -Method GET -Path ($base + '/jobSchedules?api-version=2023-11-01')
$jsResponse.Content | ConvertFrom-Json | Select-Object -ExpandProperty value

# Delete a specific job schedule (replace the GUID with the jobScheduleId from the list above)
$jsId = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
Invoke-AzRestMethod -Method DELETE -Path ($base + '/jobSchedules/' + $jsId + '?api-version=2023-11-01')
```

---

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `location` | No | Resource group location | Azure region for all resources. |
| `tags` | No | `{}` | Tags applied to all resources. |
| `automationAccountNameOverride` | No | Auto-generated | Explicit Automation Account name. Leave blank to use the derived name. |
| `logAnalyticsWorkspaceResourceId` | No | `''` | Resource ID of a Log Analytics Workspace for diagnostic settings. |
| `routeTableResourceId` | **Yes** | — | Resource ID of the Azure Route Table to manage. The Automation Account managed identity receives Network Contributor on the route table's resource group. |
| `m365EndpointInstance` | No | `worldwide` | M365 endpoint instance: `worldwide`, `usgovgcchigh`, `usgovdod`, or `china`. |
| `scheduleFrequencyHours` | No | `8` | How often the runbook checks for updated M365 IP ranges (1–24 hours). |
| `runbookContentUri` | No | GitHub raw URL | URI of the runbook `.ps1` file. Override for air-gapped or private deployments. |
| `createJobSchedule` | No | `true` | Set `true` on first deployment, `false` on every redeployment. See [Redeployment](#redeployment). |

---

## Architecture

```
Azure Automation Account (System-Assigned MI)
├── Automation Variables
│   ├── RouteTableResourceId
│   ├── M365EndpointInstance
│   └── ResourceManagerUri
├── Runbook: Update-M365RouteTable (PowerShell 7.2)
├── Schedule: M365RouteUpdater-Schedule (recurring, configurable interval)
└── Job Schedule: links Runbook to Schedule (controlled by createJobSchedule param)

Role Assignment
└── Automation Account MI → Network Contributor → Route Table Resource Group

Route Table (existing, managed by this add-on)
└── Routes: M365-* (added/removed by runbook; all other routes untouched)
```

**Security defaults:**

- `publicNetworkAccess: false` on the Automation Account — no inbound exposure.
- `disableLocalAuth: false` — ARM management plane remains accessible (required for deployment).
- System-assigned managed identity — no stored credentials.
- Network Contributor scoped to the route table's resource group only.

---

## Troubleshooting

### Deployment fails with "A jobSchedule with same id already exists"

You are redeploying to an automation account that was previously deployed. Set `createJobSchedule` to `false` (uncheck the checkbox in the Advanced tab) and redeploy.

If the error occurs on a first deployment to what you believe is a new account name, Azure Automation may have cached state from a previous account with the same name. Use a different name via `automationAccountNameOverride`.

### Runbook is not running / job history is empty

1. Confirm the job schedule link exists. From Cloud Shell, list job schedules as shown in the [Cloud Shell section](#managing-the-job-schedule-from-cloud-shell) above.
2. If no job schedule exists (first deployment with `createJobSchedule = true` failed silently), redeploy with `createJobSchedule = true` using a different automation account name, or create the link manually from Cloud Shell:

```powershell
$jsGuid = [System.Guid]::NewGuid().ToString()
$body   = '{"properties":{"runbook":{"name":"Update-M365RouteTable"},"schedule":{"name":"M365RouteUpdater-Schedule"}}}'
Invoke-AzRestMethod -Method PUT -Path ($base + '/jobSchedules/' + $jsGuid + '?api-version=2023-11-01') -Payload $body
```

### Runbook fails with authentication errors

Ensure the Automation Account system-assigned managed identity has been granted **Network Contributor** on the route table's resource group. This role assignment is created by the template as a separate module scoped to that resource group. If deploying with limited permissions, the role assignment step may have been skipped.

### Routes are not updating

Check the runbook job output in the Automation Account (via Portal → Automation Account → Jobs). Common causes:

- The M365 endpoint API version has not changed since the last run — this is expected behavior. The runbook exits without changes when the version is current.
- The route table resource ID stored in the `RouteTableResourceId` automation variable does not match the actual route table. Verify in the Automation Account → Variables blade.
- Network connectivity from the Automation Account sandbox to `endpoints.office.com` (M365 API) and the ARM endpoint is blocked. Verify the Automation Account can reach these endpoints.

### Cannot see child resources (runbook, schedule, variables) in local tools

This is expected. `publicNetworkAccess: false` hides all child resources from tools running outside Azure's network. Use **Azure Cloud Shell** for all Automation Account management operations. The Azure Portal browser also cannot display child resources for this reason.
