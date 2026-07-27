# FSLogix Storage Quota Manager Add-On

## Overview

The FSLogix Storage Quota Manager is an Azure Automation Account runbook that monitors all Azure Files Premium file shares in a specified storage resource group and automatically increases quotas when capacity thresholds are reached. This add-on is designed to prevent FSLogix profile containers from running out of space without requiring manual intervention.

## Features

- **Automated Quota Management**: Monitors all file shares in a storage resource group and automatically increases quotas to prevent storage exhaustion
- **Smart Tiered Scaling**:
  - **Small shares (< 500 GB)**: Increases by 100 GB when fewer than 50 GB remain
  - **Large shares (>= 500 GB)**: Increases by 500 GB when fewer than 500 GB remain
  - **Zero usage**: No action taken on unused shares
- **Lightweight Infrastructure**: Azure Automation Account (Basic SKU) - no App Service Plan,
  no function app storage account, no private endpoints required
- **RBAC-Based Security**: System-assigned managed identity with Storage Account Contributor
  scoped to the storage resource group — no stored credentials, no secrets
- **All-cloud Support**: Works in Azure Commercial, Government, and air-gapped clouds

## Prerequisites

- Azure resource group where the Automation Account will be deployed
- Resource group containing FSLogix Azure Files Premium storage accounts
- Permissions to deploy resources and assign RBAC roles at resource group scope

## Deployment Methods

### Quick Deploy

Click the button for your target cloud to open the deployment UI in Azure Portal:

[![Deploy to Azure](../../../docs/images/deploytoazurebutton.png)](https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fadd-ons%2FstorageQuotaManager%2Fmain.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fadd-ons%2FstorageQuotaManager%2FuiFormDefinition.json) [![Deploy to Azure Gov](../../../docs/images/deploytoazuregovbutton.png)](https://portal.azure.us/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fadd-ons%2FstorageQuotaManager%2Fmain.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fadd-ons%2FstorageQuotaManager%2FuiFormDefinition.json)

> For air-gapped clouds (Secret / Top Secret) or internet-restricted environments, see
> [Air-Gapped Deployment](#air-gapped-deployment) below. For Template Specs, use
> [`New-TemplateSpecs.ps1`](../../../tools/New-TemplateSpecs.ps1) with `-CreateAddOns $true`.

### Azure CLI

```bash
az deployment group create \
  --resource-group rg-avd-automation \
  --template-file main.json \
  --parameters \
    storageResourceGroupId='/subscriptions/{sub-id}/resourceGroups/{storage-rg}' \
    location='usgovvirginia'
```

### Azure PowerShell

```powershell
New-AzResourceGroupDeployment `
  -ResourceGroupName 'rg-avd-automation' `
  -TemplateFile '.\main.json' `
  -storageResourceGroupId '/subscriptions/{sub-id}/resourceGroups/{storage-rg}' `
  -location 'usgovvirginia'
```

## Parameters

### Required

| Parameter | Description |
|-----------|-------------|
| `storageResourceGroupId` | Full resource ID of the resource group containing FSLogix storage accounts. The runbook monitors **all** storage accounts and file shares in this group. |

### Optional

| Parameter | Default | Description |
|-----------|---------|-------------|
| `location` | Resource group location | Azure region for the Automation Account. |
| `tags` | `{}` | Tags applied to all deployed resources. |
| `automationAccountNameOverride` | _(derived)_ | Explicit name for the Automation Account. If empty, derived from the storage resource group using the pattern `aa-sqm-{unique}-{region}`. |
| `scheduleFrequencyMinutes` | `15` | How often the runbook checks quotas, in minutes. Minimum 15. |
| `runbookContentUri` | GitHub raw URL | URI of the runbook PS1 file fetched by Azure at deployment. Leave empty for air-gapped environments — see [Air-Gapped Deployment](#air-gapped-deployment). |
| `logAnalyticsWorkspaceResourceId` | _(none)_ | Log Analytics Workspace resource ID for Automation Account diagnostic settings (job logs and metrics). |
| `createJobSchedule` | `true` | Set `true` on first deployment. Set `false` on all redeployments to avoid the `jobSchedule already exists` Conflict error. |
| `deploymentTime` | _(utcNow)_ | UTC timestamp used to compute the initial schedule start time (10 minutes after deployment). |

## Architecture

### Deployed Resources

| Resource | Purpose |
|----------|---------|
| **Azure Automation Account** (Basic SKU) | Hosts the runbook, schedule, variables, and managed identity |
| **Automation Variables** | `ResourceGroupName`, `SubscriptionId`, `ResourceManagerUri` — read by the runbook at runtime |
| **PowerShell 7.2 Runbook** | `Set-StorageQuota` — quota monitoring and scaling logic |
| **Schedule** | Minute-frequency recurring trigger (default every 15 min) |
| **Job Schedule** | Links the runbook to the schedule |
| **Role Assignment** | Storage Account Contributor on the storage resource group |

### Why Automation Account Instead of Function App?

Azure Automation is a better fit for this workload because all operations are ARM control-plane
calls to `management.azure.com` — there is no data-plane storage access and no inbound traffic.
This eliminates the need for:

- App Service Plan
- Function app storage account
- Private endpoints and VNet integration
- Customer-managed encryption keys

The result is a simpler, cheaper deployment with a smaller attack surface.

## Air-Gapped Deployment

In Secret, Top Secret, and other internet-restricted environments, Azure's deployment
infrastructure cannot reach the public GitHub URI used by default for the runbook.

### Option 1 — Clear the URI, publish manually (recommended)

1. Set `runbookContentUri` to an empty string `''` (or clear the field in the Portal UI).
2. Deploy the template. The Automation Account, schedule, and job schedule are all created.
   The runbook (`Set-StorageQuota`) is created in **New** (unpublished) state — jobs will
   not run until it is published.
3. Publish the runbook using one of the methods below.

#### Publish via Azure Portal

1. Navigate to the Automation Account in the Azure Portal.
2. Under **Process Automation**, select **Runbooks**.
3. Click **Import a runbook**.
4. Browse to `runbook/run.ps1` from this add-on directory.
5. Set **Runbook type** to **PowerShell 7.2**.
6. Click **Create**, then open the runbook and click **Publish**.

#### Publish via PowerShell (from a connected machine)

```powershell
$rg   = 'rg-avd-automation'
$aa   = 'aa-sqm-abc123-usge'   # Automation Account name from deployment outputs
$file = '.\runbook\run.ps1'

Import-AzAutomationRunbook `
  -ResourceGroupName $rg `
  -AutomationAccountName $aa `
  -Path $file `
  -Name 'Set-StorageQuota' `
  -Type PowerShell72 `
  -Force

Publish-AzAutomationRunbook `
  -ResourceGroupName $rg `
  -AutomationAccountName $aa `
  -Name 'Set-StorageQuota'
```

### Option 2 — Host the runbook internally

Upload `runbook/run.ps1` to an internal web server or Azure Blob Storage (using a SAS URL)
and set `runbookContentUri` to that URI. Azure deployment infrastructure fetches from that
URI during template deployment.

> **Note on SAS URLs and Zero Trust**: Generating SAS tokens requires shared key access on
> the storage account. If your environment enforces shared key disablement (ZTI policy),
> use Option 1 (manual publish) instead.

## Runbook Logic

The runbook (`Set-StorageQuota`) runs on its configured schedule and applies the following
quota scaling logic to every file share in the storage resource group:

| Current Quota | Remaining Capacity | Action | New Quota |
|---------------|-------------------|--------|-----------|
| Any | 0 GB used | None | Unchanged |
| < 500 GB | > 50 GB remaining | None | Unchanged |
| < 500 GB | < 50 GB remaining | +100 GB | Quota + 100 GB |
| >= 500 GB | > 500 GB remaining | None | Unchanged |
| >= 500 GB | < 500 GB remaining | +500 GB | Quota + 500 GB |

### Authentication

The runbook authenticates using the Automation Account system-assigned managed identity
(`Connect-AzAccount -Identity`) and then calls the Azure Storage REST API using a bearer
token obtained from `Get-AzAccessToken`. No credentials or secrets are stored anywhere.

## Monitoring

Automation Account job logs are available in the Azure Portal without any additional setup:

- **Portal**: Automation Account > Jobs — view per-execution status, output, and errors
- **Log Analytics**: If `logAnalyticsWorkspaceResourceId` is provided, `JobLogs` and
  `JobStreams` are forwarded for alerting and long-term retention

Set up an Azure Monitor alert on the `JobLogs` table filtering for `ResultType == Failed`
to receive notifications on runbook failures.

## Security

| Control | Implementation |
|---------|---------------|
| **Authentication** | System-assigned managed identity — no stored credentials |
| **Authorization** | Storage Account Contributor on storage resource group only |
| **Scope** | ARM management plane only — no data plane access |
| **Network** | No inbound endpoints, no VNet required |
| **Secrets** | None — Automation Variables are not encrypted (resource group / subscription ID are not sensitive) |

## Troubleshooting

### Runbook not executing

- Verify the runbook status is **Published** (not New). See [Air-Gapped Deployment](#air-gapped-deployment) for publish steps.
- Confirm the job schedule link exists: Automation Account > Schedules > click the schedule > Linked runbooks.
- If this is a redeployment and the job schedule was not created, manually link the runbook to the schedule in the Portal.

### Quota not increasing

1. **Permissions** — verify the managed identity has Storage Account Contributor on the storage resource group:
   ```powershell
   $principalId = (Get-AzAutomationAccount -ResourceGroupName <rg> -Name <aa-name>).Identity.PrincipalId
   Get-AzRoleAssignment -ObjectId $principalId
   ```
2. **Threshold** — confirm shares have enough usage to trigger the logic (< 50 GB or < 500 GB remaining).
3. **Automation Variables** — check that `ResourceGroupName`, `SubscriptionId`, and `ResourceManagerUri` are set correctly under the Automation Account > Shared Resources > Variables.

### Authentication errors in job output

- Confirm the system-assigned managed identity is enabled on the Automation Account.
- Re-run the role assignment module or manually assign Storage Account Contributor.

### Storage accounts not found

- Verify `storageResourceGroupId` is the correct full resource ID (including subscription).
- Confirm the storage accounts exist in that resource group.

## Limitations

- Monitors all storage accounts and file shares in the specified resource group — no per-share exclusions
- Single resource group per deployment (deploy multiple instances for multiple groups)
- Quota only increases — manual decreases are possible via Portal or PowerShell but are limited to once per 24 hours and cannot go below current used size
- Minimum schedule interval is 15 minutes (Azure Automation constraint)
- No data-plane access — cannot read file content, only management plane quota metadata

## Related Documentation

- [Azure Automation Runbooks](https://learn.microsoft.com/azure/automation/automation-runbook-types)
- [Azure Files Premium Tier](https://learn.microsoft.com/azure/storage/files/storage-files-planning#premium-tier)
- [FSLogix Profile Containers](https://learn.microsoft.com/fslogix/profile-container-configuration-reference)
- [Azure Managed Identities](https://learn.microsoft.com/azure/active-directory/managed-identities-azure-resources/overview)
