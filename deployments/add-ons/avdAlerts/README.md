# AVD Alerts Add-On

## Overview

The AVD Alerts Add-On deploys a comprehensive set of Azure Monitor alert rules for Azure Virtual
Desktop. It covers the full operational surface of an AVD environment: host pool capacity,
session host health, user connections, FSLogix profile storage, VM performance, Azure Files and
Azure NetApp Files storage, and Azure Service Health.

The add-on is subscription-scoped. A single deployment covers any number of host pools and
storage accounts across resource groups in the subscription.

**Alert count per pooled host pool:** up to 21 scheduled query rule alerts  
**Alert count per personal host pool:** up to 18 scheduled query rule alerts (no capacity alerts; session host unhealthy applies to all pool types)  
**Per-deployment fixed alerts:** 4 Service Health activity log alerts  
**Per-storage-account alerts:** 6 metric alerts + 2 log-based (when storage alerts enabled)  
**Per-ANF-volume alerts:** 2 metric alerts (when ANF alerts enabled)  
**Per-host-pool VM alerts:** 6 metric alerts

---

## Zero Trust Alignment

This add-on is Zero Trust-aligned by default:

| Control | Implementation |
|---------|----------------|
| **No public network access** | Automation Account deployed with `publicNetworkAccess: false` and `disableLocalAuth: true` |
| **Managed identity only** | System-assigned managed identity — no stored credentials, no service principals, no connection strings |
| **Least-privilege RBAC** | Three scoped role assignments: Desktop Virtualization Reader (subscription), Log Analytics Contributor (workspace RG), Storage Account Contributor (storage RG, when applicable) |
| **Diagnostic logging** | Automation Account job logs and streams sent to Log Analytics workspace |
| **No inbound traffic** | Automation runbooks make outbound ARM control-plane calls only — no inbound triggers, no webhooks |
| **Action group enforcement** | UI form enforces selection of a `global`-location action group — required for Service Health alerts |

---

## Architecture

### Deployed Resources

| Resource | Location | Purpose |
|----------|----------|---------|
| **Resource Group** | Subscription | Created if `createResourceGroup: true`; otherwise uses existing |
| **Automation Account** (Basic SKU) | Alert RG | Hosts runbooks, schedules, variables, and managed identity |
| **Automation Variables** | Automation Account | `HostPoolInfo`, `StorageAccountIds`, `ResourceManagerUri` — read by runbooks at runtime |
| **PowerShell 7.2 Runbooks** | Automation Account | `AvdStorageLogData` — collects Azure Files share usage metrics for log-based storage space alerts |
| **Schedules** | Automation Account | Recurring 15-minute triggers |
| **Job Schedules** | Automation Account | Link runbooks to schedules |
| **Scheduled Query Rules** | Alert RG | Log Analytics-based alerts for host pool health, connections, FSLogix, disk, and storage space |
| **Metric Alerts** | Alert RG (centralized) | VM performance, storage latency/availability/throttling, ANF capacity |
| **Activity Log Alerts** | Alert RG | Azure Service Health (incident, maintenance, advisory, security) |
| **Role Assignments** | Subscription / Workspace RG / Storage RG | RBAC for managed identity |
| **Diagnostic Settings** | Automation Account | Job logs → Log Analytics workspace |

### Module Structure

```
main.bicep                    ← subscription-scoped entry point
modules/
  automationAccount.bicep     ← Automation Account, runbooks, schedules, RBAC
  hostPoolAlerts.bicep        ← log-based alerts per host pool (21 per pooled, 17 per personal)
  vmAlerts.bicep              ← VM alerts (CPU/disk metrics + disk space/memory SQRs) scoped to each VM resource group
  serviceHealthAlerts.bicep   ← subscription-scoped Service Health activity log alerts
  storageAlerts.bicep         ← Azure Files metric + log-based alerts per storage account
  anfAlerts.bicep             ← ANF volume metric alerts
```

### Alert Scoping

- **Log-based alerts** (Scheduled Query Rules) are scoped to the Log Analytics workspace.
  Queries filter by host pool resource ID to isolate each pool's data.
- **VM metric alerts** are deployed to the centralized alert resource group. Each alert rule's
  metric scope targets the VM resource group, covering all VMs in that group via a
  multi-resource scope.
- **Storage metric alerts** are deployed to the centralized alert resource group. Each alert
  rule's metric scope targets the individual storage account.
- **ANF capacity alerts** are deployed to the centralized alert resource group. Each alert
  rule's metric scope targets the individual ANF volume.
- **Service Health alerts** are scoped to the subscription.

Centralizing all alert rules in one resource group simplifies RBAC (a single IAM assignment
grants read access to all alerts), audit (one Activity Log to watch), and incident response
(Azure Monitor Alerts blade shows everything in one place).

### Host Pool Type Gating

| Alert Category | Pooled | Personal |
|----------------|--------|----------|
| Capacity (50% / 85% / 95%) | ✅ | ❌ (meaningless for 1:1 assignment) |
| Session Host Unhealthy | ✅ | ✅ |
| All other alerts | ✅ | ✅ |

### Resource Tagging

Every alert rule deployed by this add-on receives a `cm-resource-parent` tag set to the host
pool resource ID. This enables cost management tools to associate alert costs with the host
pool they monitor.

---

## Prerequisites

- An existing **Log Analytics Workspace** where AVD host pool diagnostic data is flowing
  (`WVDConnections`, `WVDAgentHealthStatus`, `WVDErrors`, `Perf`, `Event`).  
  Enable diagnostics on each host pool: **Host Pool → Diagnostic settings → Send to Log Analytics**.
- An existing **Action Group** at the **global** location in the same subscription.
  Service Health activity log alerts require a global action group.
  See [Creating a Global Action Group](#creating-a-global-action-group) below.
- **Permissions** to deploy resources and assign RBAC roles at the subscription scope.

### Creating a Global Action Group

Azure Monitor Service Health alerts can only fire against action groups at the `global` location.
A standard action group created in a specific region will not appear in the deployment form and
cannot be selected for Service Health alerts.

**Azure Portal:**

1. Open **Monitor** → **Alerts** → **Action groups** → **+ Create**.
2. Select your **Subscription** and **Resource Group**.
3. Set **Region** to **Global**.
4. Give it a name (e.g., `ag-avd-alerts-global`).
5. Add notification receivers on the **Notifications** tab (Email, SMS, Voice, etc.).
6. Click **Review + create**.

**PowerShell:**

```powershell
New-AzActionGroup `
  -ResourceGroupName 'rg-avd-operations-p-eus2' `
  -Name 'ag-avd-alerts-global' `
  -Location 'global' `
  -ShortName 'avdalerts' `
  -EmailReceiver @(
    New-AzActionGroupEmailReceiverObject `
      -Name 'AVD Ops Team' `
      -EmailAddress 'avd-ops@contoso.com'
  )
```

**Azure CLI:**

```bash
az monitor action-group create \
  --resource-group rg-avd-operations-p-eus2 \
  --name ag-avd-alerts-global \
  --location global \
  --short-name avdalerts \
  --action email avd-ops-email avd-ops@contoso.com
```

> **Tip:** If your deployment form shows no action groups in the dropdown, it is filtering for
> `global`-location groups only. Verify your action group's location with:
> ```powershell
> (Get-AzActionGroup -ResourceGroupName '{rg}' -Name '{ag}').Location  # expected: global
> ```

---

## Deployment Methods

### Template Spec (Recommended)

```powershell
.\tools\New-TemplateSpecs.ps1 `
  -ResourceGroupName 'rg-avd-operations-p-eus2' `
  -Location 'eastus2' `
  -CreateAddOns $true
```

Then open the published spec `ts-avd-alerts-{region}` in the Azure Portal.

### Blue Button (Azure Commercial / Government only)

> Not available in air-gapped (Secret / Top Secret) clouds.

[![Deploy to Azure](../../../docs/images/deploytoazurebutton.png)](https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fadd-ons%2FavdAlerts%2Fmain.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fadd-ons%2FavdAlerts%2FuiFormDefinition.json) [![Deploy to Azure Gov](../../../docs/images/deploytoazuregovbutton.png)](https://portal.azure.us/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fadd-ons%2FavdAlerts%2Fmain.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fadd-ons%2FavdAlerts%2FuiFormDefinition.json)

### PowerShell

```powershell
New-AzSubscriptionDeployment `
  -Location 'eastus2' `
  -TemplateFile '.\main.json' `
  -resourceGroupName 'rg-avd-monitoring-p-eus2' `
  -createResourceGroup $true `
  -logAnalyticsWorkspaceResourceId '/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.OperationalInsights/workspaces/{ws}' `
  -actionGroupResourceId '/subscriptions/{sub}/resourceGroups/{rg}/providers/microsoft.insights/actionGroups/{ag}' `
  -hostPoolInfo @(
    @{
      hostPoolResourceId = '/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.DesktopVirtualization/hostPools/{hp}'
      vmResourceGroupId  = '/subscriptions/{sub}/resourceGroups/{vm-rg}'
      hostPoolType       = 'Pooled'
    }
  )
```

### Azure CLI

```bash
az deployment sub create \
  --location eastus2 \
  --template-file main.json \
  --parameters \
    resourceGroupName='rg-avd-monitoring-p-eus2' \
    createResourceGroup=true \
    logAnalyticsWorkspaceResourceId='/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.OperationalInsights/workspaces/{ws}' \
    actionGroupResourceId='/subscriptions/{sub}/resourceGroups/{rg}/providers/microsoft.insights/actionGroups/{ag}' \
    hostPoolInfo='[{"hostPoolResourceId":"...","vmResourceGroupId":"...","hostPoolType":"Pooled"}]'
```

---

## Parameters

### Required

| Parameter | Description |
|-----------|-------------|
| `location` | Azure region for the Automation Account and alert rules. |
| `resourceGroupName` | Name of the resource group to deploy into. |
| `logAnalyticsWorkspaceResourceId` | Resource ID of the Log Analytics Workspace receiving AVD diagnostics. |
| `actionGroupResourceId` | Resource ID of an existing Action Group at the **global** location. |
| `hostPoolInfo` | Array of host pool objects. Each must have `hostPoolResourceId`, `vmResourceGroupId`, and `hostPoolType` (`Pooled` or `Personal`). |

### Optional - Deployment Behavior

| Parameter | Default | Description |
|-----------|---------|-------------|
| `createResourceGroup` | `false` | Create the resource group if it does not exist. |
| `alertNamePrefix` | `AVD` | Short prefix prepended to every alert name. Change when deploying multiple environments in the same subscription. |
| `autoResolveAlert` | `true` | Auto-resolve alerts when the condition clears on the next evaluation. |
| `automationAccountNameOverride` | _(derived)_ | Explicit name for the Automation Account. When empty, uses `aa-avd-alerts-{regionAbbr}`. |
| `tags` | `{}` | Tags applied to all deployed resources. |

### Optional - Storage / ANF

| Parameter | Default | Description |
|-----------|---------|-------------|
| `storageAccountResourceIds` | `[]` | Resource IDs of Azure Files Premium storage accounts. When provided, storage metric and log-based alerts are deployed. |
| `anfVolumeResourceIds` | `[]` | Resource IDs of Azure NetApp Files volumes. When provided, ANF capacity alerts are deployed. |
| `runbookContentUriStorage` | GitHub raw URL | URI of the `AvdStorageLogData` runbook PS1 file. Set to empty string `''` for air-gapped environments. |
| `createJobSchedules` | `true` | Leave `true` for all standard deployments. Set `false` only if you receive a `Conflict / jobSchedule already exists` error — see [Redeployment](#redeployment). |
| `deploymentTime` | `utcNow()` | UTC timestamp used to compute the schedule start time (10 min after deployment). |

### Optional - Alert Categories

All default to `true`. Set to `false` to skip that category.

| Parameter | Alert Category |
|-----------|---------------|
| `enableCapacityAlerts` | Host pool capacity (50% / 85% / 95%) — Pooled pools only |
| `enableAvailabilityAlerts` | Session host health, personal host unhealthy, no resources available |
| `enableConnectionAlerts` | Connection failures, disconnected sessions (24h / 72h), slow logon |
| `enableLocalDiskAlerts` | Session host C: drive free space (<= 10% / <= 5%) |
| `enableFslogixAlerts` | FSLogix profile errors (VHD full, network, attach, service, compaction) |
| `enableCpuAlerts` | Session host CPU (> 85% / > 95%) |
| `enableMemoryAlerts` | Session host available memory (< 2 GB / < 1 GB) |
| `enableOsDiskAlerts` | Session host OS disk bandwidth (> 85% / > 95%) |
| `enableStorageLatencyAlerts` | Azure Files latency (> 50ms / > 100ms) |
| `enableStorageAvailabilityAlerts` | Azure Files availability (< 99%) |
| `enableStorageThrottlingAlerts` | Azure Files throttling |
| `enableAnfCapacityAlerts` | ANF volume capacity (>= 85% / >= 95%) |
| `enableServiceHealthAlerts` | Azure Service Health (incident, maintenance, advisory, security) |

---

## Alert Reference

See [ALERT-RESPONSE.md](./ALERT-RESPONSE.md) for the full alert inventory with severity levels,
trigger conditions, and recommended response actions.

---

## Air-Gapped Deployment

In Secret, Top Secret, and other internet-restricted environments where Azure deployment
infrastructure cannot reach `raw.githubusercontent.com`:

1. Set `runbookContentUriStorage` to `''` (empty string) — or clear the field in the form.
2. Deploy the template. The Automation Account and all alert rules are fully deployed.
   The runbook is created in **New** (unpublished) state — storage space log alerts will not
   fire until the runbook is published and has run at least once.
3. Publish the runbook manually:

**Via Azure Portal:**  
Automation Account → Runbooks → `AvdStorageLogData` → Edit → Publish

**Via Cloud Shell (required when `publicNetworkAccess: false` blocks local tools):**
```powershell
$aa = '/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Automation/automationAccounts/{name}'
Invoke-AzRestMethod -Method POST -Path ($aa + '/runbooks/AvdStorageLogData/publish?api-version=2023-11-01')
```

---

## Redeployment

Normal incremental redeployments work correctly — ARM handles the job schedule idempotently
when the Automation Account already exists. Leave `createJobSchedules: true` for all standard
redeployments.

Set `createJobSchedules: false` **only** if you receive:
> `Code: Conflict / A jobSchedule with same id already exists`

This error occurs specifically when the Automation Account was **deleted from ARM** and is being
recreated with the same name. Azure Automation's backend caches the runbook-to-schedule
association by account name. That cache persists through ARM deletion and is restored the moment
an account with the same name exists again, causing the new create call to conflict.

To clear the cached association before redeploying with `createJobSchedules: true`:
```powershell
$base = '/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Automation/automationAccounts/{name}'
$jsId = ((Invoke-AzRestMethod -Method GET -Path ($base + '/jobSchedules?api-version=2023-11-01')).Content | ConvertFrom-Json).value[0].properties.jobScheduleId
Invoke-AzRestMethod -Method DELETE -Path ($base + '/jobSchedules/' + $jsId + '?api-version=2023-11-01')
```

---

## Troubleshooting

### Alert rules deployed but no alerts firing

1. Verify AVD diagnostic settings are enabled and sending data to the workspace:
   `WVDConnections`, `WVDAgentHealthStatus`, `WVDErrors`, `Perf`, `Event`.
2. Confirm the workspace is the same one selected during deployment.
3. For log-based alerts, the query window must contain matching data. Use Log Analytics
   to run the alert query manually against the workspace.
4. For storage log-based alerts, verify the `AvdStorageLogData` runbook has run at
   least once successfully (Automation Account → Jobs).

### Storage space alerts not firing

The `AvdStorageLogData` runbook writes share usage data to the Automation Account job stream,
which Log Analytics ingests via diagnostic settings. If no data appears:
1. Check Automation Account → Jobs for `AvdStorageLogData` run status and output.
2. Verify the managed identity has **Storage Account Contributor** on the storage RGs.
3. Verify diagnostic settings on the Automation Account are pointing to the workspace.

### Deployment fails with `Conflict / jobSchedule already exists`

See [Redeployment](#redeployment) above.

### Service Health alerts not firing

The Action Group must be at the **global** location. The deployment form enforces this, but if
deploying via PowerShell/CLI, verify the action group location:
```powershell
(Get-AzActionGroup -ResourceGroupName '{rg}' -Name '{ag}').Location
```
Expected: `global`

### KQL semantic errors on alert rules

All queries in this add-on explicitly cast `WVDAgentHealthStatus` string columns to their
correct numeric types (`tolong()`, `tobool()`) before aggregation. If you see KQL type errors
in the Azure Portal alert rule editor, ensure you are viewing the version deployed from this
add-on and not an older manually edited copy.
