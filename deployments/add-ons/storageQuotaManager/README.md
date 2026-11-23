# FSLogix Storage Quota Manager Add-On

## Overview

The FSLogix Storage Quota Manager is an Azure Automation Account runbook that monitors supported Azure Files SMB shares in a specified storage resource group and automatically increases or decreases capacity quotas. It supports provisioned v1 SSD, provisioned v2 HDD/SSD, and legacy StorageV2 pay-as-you-go accounts. Existing deployment resources and defaults are unchanged.

## Features

Account discovery is resource-group-wide, not restricted to a legacy FSLogix prefix.
Separate Profile (`fslpc`) and Office (`fsloc`) accounts in the selected resource group are both
discovered, and each share is evaluated against its own usage and current quota. The runbook
uses one configured scaling policy for the whole resource group, not independent per-role
thresholds. Initial Office tier and quota overrides do not create a separate scaling policy.
Quota management does not enroll shares in backup; Office backup exclusion remains unchanged.

- **Automated Quota Management**: Discovers supported accounts across the storage resource group and adjusts SMB share capacity; unsupported kinds, SKUs, and protocols are explicitly logged and skipped
- **Smart Tiered Scaling**:
  - **Small shares (< 500 GiB)**: Increases by 100 GiB when fewer than 50 GiB remain
  - **Large shares (>= 500 GiB)**: Increases by 500 GiB when fewer than 500 GiB remain
  - **Decrease**: Reclaims 100 GiB on small shares with more than 200 GiB free, or 500 GiB on large shares with more than 1,000 GiB free, subject to cooldowns and limits
  - **Zero usage**: No action taken on unused shares
- **Capacity Only**: Preserves independently provisioned v2 IOPS and bandwidth; no performance auto-scaling
- **Lightweight Infrastructure**: Azure Automation Account (Basic SKU) - no App Service Plan,
  no function app storage account, no private endpoints required
- **RBAC-Based Security**: System-assigned managed identity with Storage Account Contributor
  scoped to the storage resource group — no stored credentials, no secrets
- **Cloud-Aware Endpoint**: Uses the configured ARM endpoint; API, SKU, and regional availability must be verified in each cloud, including Government and air-gapped clouds

## Prerequisites

- Azure resource group where the Automation Account will be deployed
- Resource group containing supported FSLogix Azure Files storage accounts (see [Supported accounts and limits](#supported-accounts-and-limits))
- Target cloud support for Microsoft.Storage API `2024-01-01`; provisioned v2 also requires the service usage endpoint and the selected SKU in the target region
- Permissions to deploy resources and assign RBAC roles at resource group scope

## Deployment Methods

### Template Spec Portal Form (First Deployment)

From the repository root, publish the add-on Template Specs:

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

In the Azure portal, open **Template Specs**, select **Azure Files Premium Quota Manager**, and
choose **Deploy**. On **Review + create**, select **Create**. After the deployment is submitted,
select **Download template and parameters** and retain the working parameter file for subsequent
deployments.

### Blue Button (Azure Commercial / Government Alternative)

Click the button for your target cloud to open the deployment UI in Azure Portal:

[![Deploy to Azure](../../../docs/images/deploytoazurebutton.png)](https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fadd-ons%2FstorageQuotaManager%2Fmain.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fadd-ons%2FstorageQuotaManager%2FuiFormDefinition.json) [![Deploy to Azure Gov](../../../docs/images/deploytoazuregovbutton.png)](https://portal.azure.us/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fadd-ons%2FstorageQuotaManager%2Fmain.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fadd-ons%2FstorageQuotaManager%2FuiFormDefinition.json)

> Blue Button is unavailable in air-gapped clouds. Use the Template Spec form above and see
> [Air-Gapped Deployment](#air-gapped-deployment) for artifact staging requirements.

### Azure CLI (Subsequent Deployments)

```bash
az deployment group create \
  --resource-group rg-avd-automation \
  --template-file main.json \
  --parameters \
    storageResourceGroupId='/subscriptions/{sub-id}/resourceGroups/{storage-rg}' \
    location='usgovvirginia'
```

### Azure PowerShell (Subsequent Deployments)

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
| --- | --- |
| `storageResourceGroupId` | Full resource ID of the resource group containing FSLogix storage accounts. The runbook discovers all accounts and monitors supported SMB shares in this group. |

### Optional

| Parameter | Default | Description |
| --- | --- | --- |
| `location` | Resource group location | Azure region for the Automation Account. |
| `tags` | `{}` | Tags applied to all deployed resources. |
| `automationAccountNameOverride` | _(derived)_ | Explicit name for the Automation Account. If empty, derived from the storage resource group using the pattern `aa-sqm-{unique}-{region}`. |
| `scheduleFrequencyMinutes` | `15` | How often the runbook checks quotas, in minutes. Minimum 15. |
| `runbookContentUri` | GitHub raw URL | URI of the runbook PS1 file fetched by Azure at deployment. Leave empty for air-gapped environments — see [Air-Gapped Deployment](#air-gapped-deployment). |
| `logAnalyticsWorkspaceResourceId` | _(none)_ | Log Analytics Workspace resource ID for Automation Account diagnostic settings (job logs and metrics). |
| `createJobSchedule` | `true` | Leave `true` for all standard deployments. Set `false` **only** if you receive a `Conflict / jobSchedule already exists` error — this occurs when the account was deleted from ARM and recreated with the same name. |
| `deploymentTime` | _(utcNow)_ | UTC timestamp used to compute the initial schedule start time (10 minutes after deployment). |

## Architecture

### Deployed Resources

| Resource | Purpose |
| --- | --- |
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
quota scaling logic to supported SMB shares in the storage resource group. All capacity
values below are GiB (the older descriptions used "GB" for the same binary units).
Thresholds and increments are unchanged:

| Current Quota | Remaining Capacity | Action | New Quota |
| --- | --- | --- | --- |
| Any | 0 GiB used | None | Unchanged |
| < 500 GiB | < 50 GiB remaining | Increase | Quota + 100 GiB |
| < 500 GiB | > 200 GiB remaining | Decrease, if allowed | Quota - 100 GiB |
| >= 500 GiB | < 500 GiB remaining | Increase | Quota + 500 GiB |
| >= 500 GiB | > 1,000 GiB remaining | Decrease, if allowed | Quota - 500 GiB |
| Any | Between thresholds, including equality | None | Unchanged |

### Supported accounts and limits

| Account kind | SKUs | Billing/media | Share capacity bounds |
| --- | --- | --- | --- |
| `FileStorage` | `StandardV2_LRS`, `StandardV2_ZRS` | Provisioned v2 HDD | 32–262,144 GiB |
| `FileStorage` | `PremiumV2_LRS`, `PremiumV2_ZRS` | Provisioned v2 SSD | 32–262,144 GiB |
| `FileStorage` | `Premium_LRS`, `Premium_ZRS` | Provisioned v1 SSD | 100–102,400 GiB |
| `StorageV2` | `Standard_LRS`, `Standard_ZRS`, `Standard_GRS`, `Standard_RAGRS`, `Standard_GZRS`, `Standard_RAGZRS` | Pay-as-you-go HDD | 1–102,400 GiB with `largeFileSharesState: Enabled`; conservatively 1–5,120 GiB otherwise |

For v2, the runbook requires `fileServices/default/usages/default`, intersects published
share bounds with the returned `fileShareLimits`, and checks the account's live provisioned
capacity and `storageAccountLimits` before growth. Published account ceilings are 262,144 GiB
for SSD v2 and 4,194,304 GiB for HDD v2; a smaller service-reported limit takes precedence.
Provisioned v1 accounts share a 102,400 GiB ceiling, checked against listed share quotas
(including NFS shares, although only SMB shares are resized). Growth is clamped to available
share/account capacity, with explicit limit warnings; at a limit, no PATCH is issued.
For pay-as-you-go, account-wide used storage spans other services and isn't inferred from
share quotas. Service account-capacity errors remain authoritative.

The API is pinned to **`2024-01-01`**, the earliest stable official schema containing the
v2 SKUs, `provisionedIops`, `provisionedBandwidthMibps`, service usage constraints, and
`nextAllowedQuotaDowngradeTime` (absent from `2023-05-01`). This is not a claim that every
cloud implements that API or these SKUs. Unsupported API/service calls fail the job with
the service error; there is **no automatic API downgrade or success fallback**.
Other SKUs, including future v2 redundancy variants, and NFS shares are explicitly skipped.
Omitted `enabledProtocols` uses the documented SMB default.

### Decreases, performance preservation, and failure handling

- The service's `nextAllowedQuotaDowngradeTime`, when returned, is authoritative for
  decreases, including cooldowns triggered by **increases**. Provisioned v2 documentation
  requires 24 hours after the last increase. The existing local policy of at most one
  decrease per 24 hours is retained using `sqmLastDecreased`, even after a service cooldown
  expires. Either active deadline blocks shrinkage, not growth.
- Decreases cannot go below the account/billing minimum or `ceil(used GiB) + 1`.
  Existing share metadata is merged when recording the decrease, rather than replaced.
  Malformed cooldown timestamps now fail closed instead of allowing an unsafe decrease.
- PATCH sends only `shareQuota` and, on decrease, merged metadata. It omits independently
  provisioned IOPS/bandwidth, access tier, bursting settings, and all other properties.
  It does not apply the portal's recommended-performance formulas. The returned quota
  and v2 IOPS/bandwidth are checked before logging a confirmed update.
- Missing/invalid quota, usage, v2 performance, service limits, or update responses fail
  the job, not silently convert to zero or report a successful update. REST failures stop
  processing and preserve the original service error. Earlier confirmed updates aren't
  rolled back if a later share fails.
- Usage statistics are approximate. Concurrent changes, account capacity, performance
  constraints, and cloud-specific restrictions may still cause Azure to reject a PATCH.
  Such errors fail the job explicitly; the runbook does not lower performance to make
  a capacity change fit. Provisioned v1 performance remains coupled to capacity by Azure.

Authoritative references (reviewed for this implementation):
[stable 2024-01-01 file schema](https://github.com/Azure/azure-rest-api-specs/blob/main/specification/storage/resource-manager/Microsoft.Storage/Storage/stable/2024-01-01/file.json),
[SKU schema](https://github.com/Azure/azure-rest-api-specs/blob/main/specification/storage/resource-manager/Microsoft.Storage/Storage/stable/2024-01-01/common.json),
[scale targets](https://learn.microsoft.com/azure/storage/files/storage-files-scale-targets),
[billing](https://learn.microsoft.com/azure/storage/files/understanding-billing), and
[modifying shares](https://learn.microsoft.com/azure/storage/files/modify-file-share).

Offline regression coverage: `Invoke-Pester -Path tests\StorageQuotaManager.Tests.ps1`.
Before production use, validate target-cloud API/SKU/region support and live grow/shrink,
post-increase cooldown, account-limit errors, metadata retention, and unchanged v2 performance
in an isolated account. Mocked tests do not establish service acceptance or air-gap support.

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
| --- | --- |
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
4. **Limits / compatibility** — inspect explicit share/account-limit messages or failed API calls.
   Verify cloud API/SKU availability and v2 service usage responses. Do not retry with an older
   API that omits v2 fields or silently change performance provisioning.

### Authentication errors in job output

- Confirm the system-assigned managed identity is enabled on the Automation Account.
- Re-run the role assignment module or manually assign Storage Account Contributor.

### Storage accounts not found

- Verify `storageResourceGroupId` is the correct full resource ID (including subscription).
- Confirm the storage accounts exist in that resource group.

## Limitations

- Monitors supported SMB shares in the specified resource group — no per-share exclusions
- Single resource group per deployment (deploy multiple instances for multiple groups)
- Capacity only; v2 IOPS/throughput auto-scaling and top-level `Microsoft.FileShares` resources are not supported
- Minimum schedule interval is 15 minutes (Azure Automation constraint)
- No data-plane access — cannot read file content, only management plane quota metadata

## Related Documentation

- [Azure Automation Runbooks](https://learn.microsoft.com/azure/automation/automation-runbook-types)
- [Azure Files Premium Tier](https://learn.microsoft.com/azure/storage/files/storage-files-planning#premium-tier)
- [FSLogix Profile Containers](https://learn.microsoft.com/fslogix/profile-container-configuration-reference)
- [Azure Managed Identities](https://learn.microsoft.com/azure/active-directory/managed-identities-azure-resources/overview)
