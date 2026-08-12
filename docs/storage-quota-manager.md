[**Home**](../README.md) | [**Quick Start**](quick-start.md) | [**Add-Ons**](add-ons.md) | [**Host Pool Deployment**](hostpool-deployment.md) | [**Image Build**](image-build.md) | [**Artifacts**](artifacts-guide.md) | [**Features**](features.md) | [**Parameters**](parameters.md) | [**Compliance**](compliance.md) | [**BCDR**](bcdr.md)

# Storage Quota Manager Add-On

> **Note:** For complete deployment instructions, parameter reference, architecture details, and troubleshooting, see the **[Storage Quota Manager Add-On Documentation](../deployments/add-ons/storageQuotaManager/README.md)**.

## Overview

The FSLogix Storage Quota Manager is an Azure Automation runbook that monitors Azure Files Premium shares and automatically increases their provisioned quota before they fill up. It prevents FSLogix profile containers from running out of space without requiring manual intervention.

**Key Features:**
- **Tiered auto-scaling**: Small shares (< 500 GB) grow by 100 GB; large shares grow by 500 GB — triggered when remaining free space crosses the threshold
- **All shares, one deployment**: Monitors every file share in the target storage resource group — covers all host pools sharing that storage account
- **Lightweight**: Azure Automation Account (Basic SKU) only — no App Service Plan, no function app storage, no private endpoints required
- **Managed identity**: System-assigned identity with Storage Account Contributor scoped to the storage resource group — no stored credentials
- **Configurable frequency**: Default every 15 minutes; adjustable down to 1-minute intervals for high-churn environments
- **All-cloud support**: Works in Azure Commercial, Government, and air-gapped clouds

## Prerequisites

- Resource group where the Automation Account will be deployed
- Resource group containing the FSLogix Azure Files Premium storage accounts to monitor
- Permission to deploy resources and assign RBAC roles at resource group scope

## Deployment

### Blue Button (Azure Commercial / Government)

[![Deploy to Azure](images/deploytoazurebutton.png)](https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fadd-ons%2FstorageQuotaManager%2Fmain.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fadd-ons%2FstorageQuotaManager%2FuiFormDefinition.json) [![Deploy to Azure Gov](images/deploytoazuregovbutton.png)](https://portal.azure.us/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fadd-ons%2FstorageQuotaManager%2Fmain.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fadd-ons%2FstorageQuotaManager%2FuiFormDefinition.json)

### Template Spec (All Clouds Including Air-Gapped)

```powershell
.\tools\New-TemplateSpecs.ps1 `
  -ResourceGroupName 'rg-avd-operations-p-eus2' `
  -Location 'eastus2' `
  -CreateAddOns $true
```

Then open `ts-sqm-{region}` in the Azure Portal.

### PowerShell

```powershell
New-AzResourceGroupDeployment `
  -ResourceGroupName 'rg-avd-automation-p-eus2' `
  -TemplateFile '.\deployments\add-ons\storageQuotaManager\main.json' `
  -storageResourceGroupId '/subscriptions/{sub-id}/resourceGroups/rg-avd-storage-p-eus2'
```

## Key Parameters

| Parameter | Default | Description |
| --- | --- | --- |
| `storageResourceGroupId` | _(required)_ | Resource ID of the resource group containing the FSLogix storage accounts |
| `scheduleFrequencyMinutes` | `15` | How often the runbook checks quotas (minimum 15) |
| `logAnalyticsWorkspaceResourceId` | _(none)_ | Workspace for Automation Account job logs |
| `runbookContentUri` | GitHub raw URL | Leave default for Commercial/Government; clear for air-gapped |
| `createJobSchedule` | `true` | Leave `true` for all standard deployments. Set `false` only if you receive a Conflict error after deleting and recreating the account with the same name |

## Zero Trust Alignment

| Control | Implementation |
| --- | --- |
| No public inbound access | `publicNetworkAccess: false` on the Automation Account |
| No stored credentials | System-assigned managed identity; `disableLocalAuth: true` |
| Least-privilege RBAC | Storage Account Contributor scoped to storage resource group only |
| Diagnostic logging | Automation Account job logs → Log Analytics workspace |

> **No Private Link or Hybrid Worker required.** This runbook communicates exclusively with Azure Resource Manager (to read share quotas and issue update calls) using its managed identity. ARM endpoints are identity-gated, TLS-protected, and FedRAMP High authorized. Blocking inbound public access is the only required network control. See [add-ons.md — Zero Trust Alignment](add-ons.md#zero-trust-alignment) for the NIST control mapping and full rationale.

## Redeployment

Normal incremental redeployments are fully idempotent — leave `createJobSchedule = true`. Set it to `false` only if you receive a `Conflict / jobSchedule already exists` error, which occurs only when the Automation Account was deleted from ARM and recreated with the same name.

For full details see the [add-on README](../deployments/add-ons/storageQuotaManager/README.md).
