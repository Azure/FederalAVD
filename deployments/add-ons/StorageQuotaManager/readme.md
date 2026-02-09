# FSLogix Storage Quota Manager Add-On

## Overview

The FSLogix Storage Quota Manager is an automated Azure Function that monitors all file shares in a specified storage resource group and automatically increases quotas when capacity thresholds are reached. This add-on is designed for FSLogix profile storage using Azure Files Premium.

## Features

- **Automated Quota Management**: Monitors all file shares in a storage resource group and automatically increases quotas to prevent storage exhaustion
- **Smart Tiered Scaling Logic**: 
  - **Small shares (< 500GB)**: Increases by 100GB when less than 50GB remains (allows time for gradual AVD stamp rollout)
  - **Large shares (≥ 500GB)**: Increases by 500GB when less than 500GB remains (ensures capacity during mass onboarding)
  - **Zero usage**: No action taken on unused shares
- **Automatic Storage Discovery**: Discovers all file shares in the specified storage resource group dynamically
- **Flexible Infrastructure**: Deploy with new or existing App Service Plan
- **Zero Trust Networking**: Optional private endpoints for function app and supporting storage account, plus VNet integration
- **Customer-Managed Encryption**: Optional customer-managed keys (CMK) using Azure Key Vault for function app storage
- **Comprehensive Monitoring**: Application Insights integration with detailed logging and diagnostics
- **RBAC-Based Security**: Uses system-assigned managed identity with Storage Account Contributor role scoped to the storage resource group

## How It Works

1. **Timer Trigger**: Azure Function runs on a configurable schedule (default: every 60 minutes)
2. **Storage Discovery**: Lists all storage accounts in the specified resource group
3. **Share Analysis**: For each storage account, enumerates all file shares and checks usage
4. **Intelligent Scaling**: Applies tiered logic based on current quota and remaining capacity
5. **Automatic Increase**: Issues REST API calls to increase quotas when thresholds are met
6. **Detailed Logging**: Records all quota changes and decisions to Application Insights

## Prerequisites

- Azure resource group containing FSLogix storage accounts with Azure Files Premium file shares
- Permissions to deploy resources and assign RBAC roles
- (Optional) Existing App Service Plan for cost savings
- (Optional) VNet with subnets if using private endpoints:
  - Subnet delegated to `Microsoft.Web/serverFarms` for function app VNet integration
  - Subnet for private endpoints (function app and storage)
  - Private DNS zones for blob, file, queue, table, and function app services

## Deployment Methods

### Quick Deploy

Click the button for your target cloud to open the deployment UI in Azure Portal:

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fadd-ons%2FStorageQuotaManager%2Fmain.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fadd-ons%2FStorageQuotaManager%2FuiFormDefinition.json) [![Deploy to Azure Gov](https://aka.ms/deploytoazuregovbutton)](https://portal.azure.us/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fadd-ons%2FStorageQuotaManager%2Fmain.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fadd-ons%2FStorageQuotaManager%2FuiFormDefinition.json)

**⚠️ Note:** For Air-Gapped clouds (Secret/Top Secret), create Template Specs using [`New-TemplateSpecs.ps1`](../../New-TemplateSpecs.ps1) with `-CreateAddOns $true` or use PowerShell/CLI deployment methods below.

### Azure Portal (Manual Template)

1. Navigate to **Azure Portal**
2. Search for **Deploy a custom template**
3. Select **Build your own template in the editor**
4. Upload `main.bicep` from this directory
5. Fill in the required parameters:
   - **hostPoolResourceId**: Select your AVD hostpool (used for tagging and naming conventions)
   - **storageResourceGroupId**: Full resource ID of the resource group containing your FSLogix storage accounts
   - **location**: Azure region for the function app
6. Configure optional parameters as needed
7. Review and create

### Azure CLI

```bash
az deployment group create \
  --resource-group <management-rg-name> \
  --template-file main.bicep \
  --parameters \
    hostPoolResourceId='/subscriptions/{sub-id}/resourceGroups/{rg}/providers/Microsoft.DesktopVirtualization/hostPools/{hp-name}' \
    storageResourceGroupId='/subscriptions/{sub-id}/resourceGroups/{storage-rg-name}' \
    location='eastus' \
    timerSchedule='0 */30 * * * *'
```

### Azure PowerShell

```powershell
New-AzResourceGroupDeployment `
  -ResourceGroupName '<management-rg-name>' `
  -TemplateFile '.\main.bicep' `
  -hostPoolResourceId '/subscriptions/{sub-id}/resourceGroups/{rg}/providers/Microsoft.DesktopVirtualization/hostPools/{hp-name}' `
  -storageResourceGroupId '/subscriptions/{sub-id}/resourceGroups/{storage-rg-name}' `
  -location 'eastus' `
  -timerSchedule '0 */30 * * * *'
```

## Parameters

### Required Parameters

| Parameter | Description |
|-----------|-------------|
| `hostPoolResourceId` | **Required.** Resource ID of an AVD hostpool. Used for tagging and naming convention discovery. |
| `storageResourceGroupId` | **Required.** Full resource ID of the resource group containing FSLogix storage accounts. The function will monitor ALL storage accounts and file shares in this resource group. |

### Optional Parameters

#### Infrastructure Configuration

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `location` | string | Resource group location | Azure region for function app deployment |
| `tags` | object | {} | Tags to apply to all deployed resources |
| `appServicePlanResourceId` | string | '' | Resource ID of existing App Service Plan. Leave empty to create a new S1 Standard plan. |
| `zoneRedundant` | bool | false | Enable zone redundancy for new App Service Plan (requires 3 instances). Only applies if creating new plan. |

#### Networking Configuration

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `privateEndpoint` | bool | false | Enable private endpoints for function app storage and function app itself. |
| `privateEndpointSubnetResourceId` | string | '' | Subnet for private endpoints. **Required if** `privateEndpoint=true`. |
| `functionAppDelegatedSubnetResourceId` | string | '' | Subnet delegated to `Microsoft.Web/serverFarms` for VNet integration. **Required if** `privateEndpoint=true`. |
| `azureBlobPrivateDnsZoneResourceId` | string | '' | Private DNS Zone for blob storage. Required for private endpoint DNS resolution. |
| `azureFilePrivateDnsZoneResourceId` | string | '' | Private DNS Zone for file storage. Required for private endpoint DNS resolution. |
| `azureQueuePrivateDnsZoneResourceId` | string | '' | Private DNS Zone for queue storage. Required for private endpoint DNS resolution. |
| `azureTablePrivateDnsZoneResourceId` | string | '' | Private DNS Zone for table storage. Required for private endpoint DNS resolution. |
| `azureFunctionAppPrivateDnsZoneResourceId` | string | '' | Private DNS Zone for function app. Required for private endpoint DNS resolution. |

#### Encryption Configuration

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `keyManagementStorageAccounts` | string | 'MicrosoftManaged' | Encryption key management. Options: `MicrosoftManaged`, `CustomerManaged`, `CustomerManagedHSM` |
| `encryptionKeyVaultResourceId` | string | '' | Key Vault resource ID for customer-managed keys. **Required if** using `CustomerManaged` or `CustomerManagedHSM`. |

#### Monitoring Configuration

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `logAnalyticsWorkspaceResourceId` | string | '' | Log Analytics Workspace for Application Insights. If empty, Application Insights will not be enabled. |
| `privateLinkScopeResourceId` | string | '' | Azure Monitor Private Link Scope for Application Insights private connectivity. |

#### Execution Configuration

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `timerSchedule` | string | '0 */60 * * * *' | Timer trigger CRON expression. Default runs every 60 minutes. Common values:<br>• `0 */30 * * * *` - Every 30 minutes<br>• `0 0 */6 * * *` - Every 6 hours<br>• `0 0 8 * * *` - Daily at 8:00 AM UTC |

## Architecture

### Deployed Resources

1. **Azure Function App** (PowerShell 7.4)
   - Runtime: PowerShell
   - Function: `auto-increase-file-share-quota`
   - Trigger: Timer (configurable schedule)
   - Identity: System-assigned managed identity
   - RBAC: Storage Account Contributor on storage resource group

2. **Function App Storage Account** (Standard_LRS)
   - Purpose: Function app backend (code, state, logs)
   - Encryption: Platform-managed or customer-managed keys
   - Private endpoints: Optional (blob, file, queue, table)

3. **App Service Plan** (S1 Standard, optional)
   - Created only if `appServicePlanResourceId` is empty
   - SKU: S1 (1 vCPU, 1.75 GB RAM)
   - Zone redundancy: Optional

4. **Application Insights** (optional)
   - Created if `logAnalyticsWorkspaceResourceId` is provided
   - Logs all quota checks and increases
   - Integrated with Log Analytics Workspace

5. **Private Endpoints** (optional, if `privateEndpoint=true`)
   - Function app storage: blob, file, queue, table
   - Function app: sites endpoint

### Resource Naming

The add-on automatically determines resource naming conventions by analyzing the provided hostpool name:

- **Resource Type at Start**: `hp-avd-01` → Function app: `fa-quotamanagement-abc123-avd-01-eus`
- **Resource Type at End**: `avd-01-hp` → Function app: `avd-01-fa-quotamanagement-abc123-eus`

Naming includes:

- Hostpool identifier and index
- Unique string from storage resource group ID
- Region abbreviation
- Resource type abbreviation

## Function Logic

The PowerShell function (`auto-increase-file-share-quota`) executes the following logic:

### Authentication

- Uses system-assigned managed identity to authenticate with Azure
- Obtains access token for Azure Resource Manager API
- No credentials or secrets required

### Discovery and Processing

1. **List Storage Accounts**: Queries all storage accounts in the specified resource group
2. **Enumerate Shares**: For each storage account, lists all file shares
3. **Check Usage**: Retrieves current quota (provisioned capacity) and usage (used capacity in GB)
4. **Apply Scaling Logic**: Based on current quota and remaining capacity

### Scaling Logic

#### No Action Scenarios

- **Zero Usage**: If `UsedCapacity = 0`, no changes are made
- **Above Threshold**: If remaining capacity exceeds the threshold, no action taken

#### Small Share Scaling (Quota < 500GB)

```
IF UsedCapacity > 0 AND (ProvisionedCapacity - UsedCapacity) < 50GB
THEN Increase quota by 100GB
```

- **Threshold**: 50GB remaining
- **Increase**: 100GB
- **Purpose**: Gradual scaling for new/small AVD deployments

#### Large Share Scaling (Quota ≥ 500GB)

```
IF UsedCapacity > 0 AND (ProvisionedCapacity - UsedCapacity) < 500GB
THEN Increase quota by 500GB
```

- **Threshold**: 500GB remaining
- **Increase**: 500GB
- **Purpose**: Aggressive scaling for production/mass onboarding

### Example Scenarios

| Current Quota | Used Capacity | Remaining | Action | New Quota | Reason |
|---------------|---------------|-----------|--------|-----------|--------|
| 100 GB | 0 GB | 100 GB | None | 100 GB | No usage |
| 100 GB | 55 GB | 45 GB | +100 GB | 200 GB | < 50GB remains (small share) |
| 200 GB | 160 GB | 40 GB | +100 GB | 300 GB | < 50GB remains (small share) |
| 450 GB | 180 GB | 270 GB | None | 450 GB | > 50GB remains (small share) |
| 500 GB | 50 GB | 450 GB | None | 500 GB | > 500GB remains (large share) |
| 600 GB | 150 GB | 450 GB | +500 GB | 1100 GB | < 500GB remains (large share) |
| 1000 GB | 550 GB | 450 GB | +500 GB | 1500 GB | < 500GB remains (large share) |
| 1500 GB | 800 GB | 700 GB | None | 1500 GB | > 500GB remains (large share) |

## Monitoring and Logging

### Application Insights Logs

All quota checks and increases are logged to Application Insights. Log messages include:

- Storage account and file share name
- Current quota and usage
- Remaining capacity
- Actions taken (increase amount or no change)

### Sample Log Queries

View all quota increases:

```kusto
traces
| where message contains "Increasing the file share quota"
| project timestamp, message
| order by timestamp desc
```

View quota check summary:

```kusto
traces
| where message contains "Share Capacity" or message contains "Share Usage"
| extend StorageInfo = extract(@"\[([^\]]+)\]", 1, message)
| project timestamp, StorageInfo, message
| order by timestamp desc
```

Check for errors:

```kusto
traces
| where severityLevel >= 3  // Warning or Error
| project timestamp, severityLevel, message
| order by timestamp desc
```

### Metrics to Monitor

- **Function Executions**: Monitor execution count and duration
- **Function Failures**: Alert on failed executions
- **Storage Capacity**: Track file share quota and usage over time (via Azure Storage metrics)

## Security

### Managed Identity and RBAC

The function app uses a **system-assigned managed identity** with the following permissions:

| Role | Scope | Purpose |
|------|-------|---------|
| **Storage Account Contributor** | Storage resource group | List storage accounts, enumerate file shares, read usage, update quotas |

### Least Privilege Design

- No subscription-level permissions required
- Scoped to only the storage resource group
- No access to storage data (only management plane)
- Identity is auto-created and auto-managed

### Network Security

When private endpoints are enabled:

- Function app storage account is isolated from public internet
- Function app sites endpoint can be private
- VNet integration allows function to access storage privately
- All traffic remains on Azure backbone

### Key Management

**Microsoft-Managed Keys (Default)**:

- No additional configuration
- Keys managed by Azure Storage
- Simplest option

**Customer-Managed Keys**:

- Keys stored in Azure Key Vault
- Function app storage identity gets Key Vault Crypto Service Encryption User role
- Automatic key rotation supported
- 180-day expiry with automatic renewal at 173 days

## Troubleshooting

### Function Not Executing

**Symptoms**: No logs in Application Insights, no quota increases

**Checks**:

1. Verify timer trigger schedule is correct
2. Check function app is running (not stopped)
3. Review function app configuration in Azure Portal
4. Confirm Application Insights connection string is configured

**Resolution**:

- Navigate to Function App → Functions → `auto-increase-file-share-quota` → Monitor
- Check execution history and logs

### Quota Not Increasing

**Symptoms**: Function executes but quotas remain unchanged

**Checks**:

1. **Permissions**: Verify managed identity has Storage Account Contributor role

   ```bash
   az role assignment list --assignee <function-app-principal-id> --scope <storage-rg-id>
   ```

2. **Usage Threshold**: Confirm file shares have enough usage to trigger increase
   - Small shares (< 500GB): Need < 50GB remaining
   - Large shares (≥ 500GB): Need < 500GB remaining

3. **Storage Account Access**: Ensure storage accounts are not locked or have restrictive policies

4. **Logs**: Review Application Insights for specific error messages

**Resolution**:

- Grant Storage Account Contributor role if missing
- Wait for usage to reach threshold
- Check for resource locks on storage accounts

### Authentication Errors

**Symptoms**: Logs show "Failed to authenticate Azure"

**Checks**:

1. Verify system-assigned managed identity is enabled on function app
2. Confirm identity has correct RBAC assignment
3. Check for Azure Active Directory issues

**Resolution**:

```powershell
# Re-enable system-assigned identity
$functionApp = Get-AzWebApp -ResourceGroupName <rg> -Name <function-app-name>
Set-AzWebApp -ResourceGroupName <rg> -Name <function-app-name> -AssignIdentity $true

# Assign Storage Account Contributor role
$identity = (Get-AzWebApp -ResourceGroupName <rg> -Name <function-app-name>).Identity.PrincipalId
New-AzRoleAssignment -ObjectId $identity -RoleDefinitionName "Storage Account Contributor" -Scope <storage-rg-id>
```

### Storage Account Not Found

**Symptoms**: Function logs show "storage accounts not found" or empty results

**Checks**:

1. Verify `storageResourceGroupId` parameter is correct (full resource ID)
2. Confirm storage accounts exist in the specified resource group
3. Check subscription ID in the resource ID matches where storage accounts are located

**Resolution**:

- Correct the `storageResourceGroupId` parameter in deployment
- Redeploy if necessary

### Private Endpoint Issues

**Symptoms**: Function cannot reach storage APIs, timeout errors

**Checks**:

1. Verify private DNS zones are correctly configured
2. Confirm VNet integration subnet has connectivity to private endpoint subnet
3. Check NSG rules on subnets
4. Verify private DNS zone resource IDs are correct

**Resolution**:

- Test DNS resolution from function app
- Review VNet peering and routing
- Validate private DNS zone links to VNets

## Cost Considerations

### Monthly Cost Estimates (US East)

| Component | Configuration | Estimated Cost |
|-----------|---------------|----------------|
| **App Service Plan** | PremiumV3_P0v3 (1 instance, new) | ~$120/month |
| **App Service Plan** | Shared with existing functions | ~$0/month (shared cost) |
| **Function App Storage** | Standard_LRS, minimal usage | ~$2/month |
| **Application Insights** | 5GB ingestion, 90-day retention | ~$10/month |
| **Private Endpoints** | 5 endpoints (if enabled) | ~$20/month |
| **Total (New Plan)** | - | ~$152/month |
| **Total (Shared Plan)** | - | ~$32/month |

### Cost Optimization Tips

1. **Share App Service Plan**: Use existing App Service Plan from another function to eliminate ~$75/month
2. **Adjust Timer Schedule**: Less frequent checks reduce function execution costs (minimal impact)
3. **Reduce Log Retention**: Lower Application Insights retention to 30 days
4. **Skip Private Endpoints**: If not required for compliance, save ~$20/month
5. **Right-Size App Service Plan**: If shared with minimal workload, consider B1 tier (~$13/month)

## Best Practices

### Deployment

- Deploy function app to the same Azure region as your storage accounts for optimal performance
- Use an existing App Service Plan if available to reduce costs
- Enable Application Insights for production deployments
- Tag resources appropriately using the `tags` parameter

### Monitoring

- Set up Azure Monitor alerts for function failures
- Review quota increase patterns monthly to understand growth
- Monitor storage account metrics to validate quota increases align with usage

### Security

- Use private endpoints for production environments handling sensitive data
- Enable customer-managed keys for compliance requirements
- Regularly review RBAC assignments
- Use Azure Policy to enforce network and encryption standards

### Scaling

- Adjust timer schedule based on user onboarding patterns (e.g., more frequent during mass onboarding)
- Consider multiple storage resource groups if using sharded storage architecture
- For very large environments (100+ shares), consider increasing App Service Plan SKU

## Limitations

- **Scope**: Function monitors all storage accounts and file shares in the specified resource group; cannot selectively exclude shares
- **Azure Files Premium Only**: Designed for Premium tier file shares (supports quotas up to 100 TiB)
- **Single Resource Group**: Monitors one storage resource group per function deployment
- **No Quota Decrease**: Function only increases quotas; manual intervention required to decrease
- **Timer Granularity**: Minimum practical schedule is every 5 minutes (more frequent not recommended)
- **REST API Only**: Uses Azure REST APIs directly (not Az PowerShell module) to minimize cold start time

## Frequently Asked Questions

### Can I use this with Azure Files Standard tier?

Yes, the function supports any Azure Files tier. However, the scaling logic is optimized for Premium tier where performance scales with provisioned capacity.

### What happens if I delete a file share?

The function skips shares that no longer exist. No errors are logged for non-existent shares.

### Can I monitor multiple storage resource groups?

No, each function deployment monitors one resource group. Deploy multiple instances for multiple resource groups.

### How do I change the timer schedule after deployment?

Update the `timerSchedule` parameter and redeploy, or manually edit the function configuration in Azure Portal.

### Does this work with NetApp Files?

No, this add-on is specifically designed for Azure Files. NetApp Files quotas are managed differently.

### Can I customize the scaling thresholds?

Yes, edit the `run.ps1` script and redeploy. The thresholds (50GB, 500GB) and increase amounts (100GB, 500GB) are in the script.

### What if my storage accounts are in a different subscription?

The function supports cross-subscription scenarios. Ensure the managed identity has Storage Account Contributor role in the target subscription's storage resource group.

## Related Documentation

- [Azure Files Premium Tier](https://learn.microsoft.com/azure/storage/files/storage-files-planning#premium-tier)
- [FSLogix Profile Containers](https://learn.microsoft.com/fslogix/profile-container-configuration-reference)
- [Azure Functions Timer Trigger](https://learn.microsoft.com/azure/azure-functions/functions-bindings-timer)
- [Azure Function PowerShell Developer Guide](https://learn.microsoft.com/azure/azure-functions/functions-reference-powershell)
- [Azure Managed Identities](https://learn.microsoft.com/azure/active-directory/managed-identities-azure-resources/overview)
- [Azure Storage Account Contributor Role](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles#storage-account-contributor)

## Support

For issues, questions, or feature requests:

1. Review this documentation thoroughly
2. Check Application Insights logs for error details
3. Consult the [Troubleshooting](#troubleshooting) section
4. Create an issue in the GitHub repository with:
   - Detailed description of the problem
   - Relevant logs from Application Insights
   - Deployment parameters (redact sensitive information)
   - Steps to reproduce

## Change Log

### Version 1.0

- Initial release
- PowerShell 7.4 function app
- Tiered scaling logic (100GB/500GB increases)
- Automatic storage account and file share discovery
- System-assigned managed identity with Storage Account Contributor
- Application Insights integration
- Private endpoint support
- Customer-managed encryption key support
