# AVD Shared Services Deployment

> **Related guides:** [Quick Start](../../docs/quick-start.md#step-1-deploy-avd-shared-services) |
> [Automation](../../docs/automation-guide.md) |
> [Parameters](../../docs/parameters.md) |
> [Naming](../../docs/naming-convention.md)

## Overview

This subscription-scoped Bicep deployment creates regional services that can be shared by Image
Management, host pools, and add-ons:

- Separate Secrets and Encryption Key Vaults
- Optional centralized Log Analytics workspace, AVD Insights Data Collection Rule (DCR), Data
  Collection Endpoint (DCE), and Azure Monitor Agent user-assigned identity
- Optional Recovery Services vault and Azure Files snapshot backup policy for FSLogix storage
- Optional private endpoints for the deployed Key Vaults and Recovery Services vault

Shared Services is not required for every standard host pool. A standard host-pool deployment can
create equivalent resources inline for itself and later standard pools. Deploy Shared Services
first when a consumer needs these resources before the first standard host pool, including:

- An automated host pool, which requires an existing credentials Key Vault
- Image Management using customer-managed keys (CMK)
- Central monitoring required before diagnostic-enabled resources are created
- Shared FSLogix storage that needs a pre-existing backup vault and policy
- Multiple deployments that should reuse regional security and monitoring resources

## Deployment Scope and Resources

The entry point is `sharedServices.bicep` and its target scope is the subscription.

```text
Operations subscription
├── Operations resource group (always created)
│   ├── Secrets Key Vault (optional, enabled by default)
│   │   ├── VM administrator secrets (when supplied)
│   │   ├── Domain join secrets (when supplied)
│   │   └── Private endpoint (optional)
│   ├── Encryption Key Vault (optional, enabled by default)
│   │   └── Private endpoint (optional)
│   ├── Azure Monitor Agent identity (only when monitoring uses another subscription)
│   └── FSLogix Recovery Services vault and backup policy (optional)
│       └── Private endpoint (optional)
└── Monitoring resource group (when monitoring uses this subscription)
    ├── Log Analytics workspace
    ├── AVD Insights DCR
    ├── DCE
  └── Azure Monitor Agent identity (optional; same-subscription placement)

Optional monitoring subscription
└── Monitoring resource group (when a different subscription is selected)
    ├── Log Analytics workspace
    ├── AVD Insights DCR
    └── DCE
```

When monitoring is deployed to another subscription, the Azure Monitor Agent identity remains in
the operations subscription so automated host pools in that subscription can use it. All resources
from one Shared Services deployment use the same Azure region.

### Resource Conditions

| Resource | Condition | Notes |
| --- | --- | --- |
| Operations resource group | Always | Contains Key Vaults and the optional FSLogix backup vault |
| Secrets Key Vault | `deploySecretsKeyVault = true` | Standard SKU; RBAC authorization; ARM template deployment enabled |
| Encryption Key Vault | `deployEncryptionKeyVault = true` | Premium SKU; soft delete and purge protection enabled |
| Key Vault private endpoints | `privateEndpoint = true` and the applicable vault is deployed | Uses the supplied subnet; DNS integration is optional in Bicep but normally required operationally |
| Monitoring resource group, workspace, DCR, and DCE | `deployMonitoring = true` | Can be placed in the operations subscription or another selected subscription |
| Azure Monitor Agent identity | `deployMonitoring = true` and `deployAzureMonitorAgentIdentity = true` | Intended for reuse by automated host pools in the operations subscription and region |
| Recovery Services vault and Azure Files policy | `deployFSLogixBackupVault = true` | Snapshot data remains in each storage account; the vault maintains backup policy and metadata |
| Recovery Services private endpoint | Backup vault deployed, `privateEndpoint = true`, and private endpoint/DNS inputs supplied | Requires the Azure Backup, Blob, and Queue private DNS zones for complete DNS integration |

## Deployment Order

Use only the steps required by the selected architecture:

```text
Networking (optional)
  -> Shared Services (when shared prerequisites are needed)
    -> Image Management (optional)
      -> Image Build (optional)
        -> Host Pool
```

Important dependencies:

- Deploy the Encryption Key Vault before Image Management when Image Management storage or gallery
  image versions use CMK.
- Deploy the Secrets Key Vault before an automated host pool. The automated deployment requires its
  resource ID.
- Deploy monitoring before resources subject to `DeployIfNotExists` diagnostic-settings policies
  when those policies require an existing Log Analytics workspace.
- Deploy the FSLogix backup vault and policy before a host pool or standalone FSLogix Storage
  deployment that registers Azure Files shares for backup.

## Prerequisites

### Permissions

The deployment identity must be able to:

- Create subscription deployments and resource groups in the operations subscription
- Create the selected Key Vault, monitoring, managed identity, Recovery Services, private endpoint,
  and diagnostic-setting resources
- Deploy monitoring resources into the selected monitoring subscription, when different
- Associate the workspace and DCE with an existing Azure Monitor Private Link Scope (AMPLS), when
  selected
- Use and join the selected private endpoint subnet and private DNS zones

Downstream CMK deployments create keys in the Encryption Key Vault. Before running those consumers,
grant their deployment identity **Key Vault Crypto Officer** on this vault. `Owner` and
`Contributor` control-plane roles do not grant Key Vault data-plane key operations.

### Private Connectivity

When `privateEndpoint` is enabled, provide an existing private endpoint subnet without service
delegations. Provide the cloud-appropriate private DNS zones:

- Key Vault: `privatelink.vaultcore.azure.net` or the cloud-specific equivalent
- Azure Backup: `privatelink.<region>.backup.windowsazure.com` or the cloud-specific equivalent
- Blob: `privatelink.blob.<storage-suffix>`
- Queue: `privatelink.queue.<storage-suffix>`

The guided form filters existing networks and zones. The template does not create VNets, subnets,
private DNS zones, AMPLS private endpoints, or DNS links.

## Parameters

### Key Vaults and Credentials

| Parameter | Default | Purpose |
| --- | --- | --- |
| `deploySecretsKeyVault` | `true` | Deploy the Standard Secrets Key Vault |
| `secretsKeyVaultEnableSoftDelete` | `true` | Enable recoverable deletion on the Secrets Key Vault |
| `secretsKeyVaultEnablePurgeProtection` | `true` | Prevent purge during the retention period |
| `secretsKeyVaultRetentionInDays` | `90` | Secrets Key Vault retention; allowed range is 7-90 days |
| `virtualMachineAdminUserName` | Empty | Secure value stored as `VirtualMachineAdminUserName` |
| `virtualMachineAdminPassword` | Empty | Secure value stored as `VirtualMachineAdminPassword` |
| `domainJoinUserPrincipalName` | Empty | Secure value stored as `DomainJoinUserPrincipalName` |
| `domainJoinUserPassword` | Empty | Secure value stored as `DomainJoinUserPassword` |
| `deployEncryptionKeyVault` | `true` | Deploy the Premium Encryption Key Vault used by downstream CMK deployments |
| `encryptionKeyVaultRetentionInDays` | `90` | Encryption Key Vault retention; allowed range is 7-90 days |

Credential inputs are optional. Omitted values do not create empty secrets. Supply credentials as
secure deployment parameters or populate the vault through an approved secrets-management process.
Do not commit secret values to parameter files.

### Networking and Diagnostics

| Parameter | Default | Purpose |
| --- | --- | --- |
| `privateEndpoint` | `false` | Deploy private endpoints for selected Key Vaults and the FSLogix backup vault |
| `privateEndpointSubnetResourceId` | Empty | Existing subnet used by private endpoints |
| `azureKeyVaultPrivateDnsZoneResourceId` | Empty | Key Vault private DNS zone integration |
| `azureBackupPrivateDnsZoneResourceId` | Empty | Azure Backup private DNS zone integration |
| `azureBlobPrivateDnsZoneResourceId` | Empty | Blob private DNS zone integration for Azure Backup |
| `azureQueuePrivateDnsZoneResourceId` | Empty | Queue private DNS zone integration for Azure Backup |
| `permittedIPs` | `[]` | Public IP/CIDR allowlist applied to both Key Vaults |
| `existingLogAnalyticsWorkspaceResourceId` | Empty | Existing workspace used only for Key Vault and backup-vault diagnostics when new monitoring is not deployed |

If private endpoints are enabled and `permittedIPs` is empty, public access is disabled on the Key
Vaults. If permitted IPs are also supplied, the Key Vault public endpoint remains enabled but its
firewall defaults to deny and permits only the supplied addresses. The Recovery Services vault
disables public access whenever its private endpoint option is enabled.

### Central Monitoring

| Parameter | Default | Purpose |
| --- | --- | --- |
| `deployMonitoring` | `false` | Deploy a shared workspace, AVD Insights DCR, and DCE |
| `deployAzureMonitorAgentIdentity` | `true` | Deploy the regional identity used by automated-host monitoring |
| `logAnalyticsWorkspaceSubscriptionId` | Empty | Monitoring subscription; empty uses the operations subscription |
| `logAnalyticsWorkspaceSku` | `PerGB2018` | Workspace pricing tier |
| `logAnalyticsWorkspaceRetentionInDays` | `30` | Workspace retention; allowed range is 30-730 days |
| `azureMonitorPrivateLinkScopeResourceId` | Empty | Existing AMPLS to which the new workspace and DCE are added |

Supplying AMPLS disables public network access on the DCE and adds the workspace and DCE as scoped
resources. The networking platform must manage the AMPLS access modes, private endpoint, private DNS
zones, and name resolution. The general `privateEndpoint` setting does not create Azure Monitor
private endpoints.

### FSLogix Azure Files Backup

| Parameter | Default | Purpose |
| --- | --- | --- |
| `deployFSLogixBackupVault` | `false` | Deploy the shared regional Recovery Services vault and policy |
| `fslogixBackupPolicyName` | `filesharepolicy` | Azure Files snapshot backup policy name |
| `fslogixBackupRetentionDays` | `30` | Daily snapshot retention; allowed range is 1-200 days |
| `fslogixBackupTimeZone` | `UTC` | Windows time-zone ID used by the daily schedule |

This deployment creates the vault and policy. Each consuming host-pool or FSLogix Storage deployment
registers its own eligible Azure Files storage account and share with that vault and policy. Azure
NetApp Files is not protected by this Azure Files backup policy.

### Naming and Tags

| Parameter | Default | Purpose |
| --- | --- | --- |
| `namingConvention` | CAF-aligned object | Controls resource names across the deployment |
| `secretsKeyVaultNameOverride` | Empty | Complete Secrets Key Vault name override, maximum 24 characters |
| `encryptionKeyVaultNameOverride` | Empty | Complete Encryption Key Vault name override, maximum 24 characters |
| `tags` | `{}` | Resource-type-keyed tag object |

Use the same `namingConvention` object across FederalAVD deployments for consistent names. See the
[Naming Convention guide](../../docs/naming-convention.md).

## Deployment

### Template Spec Portal Form (Recommended First Deployment)

Publish only the Shared Services Template Spec from the repository root:

```powershell
.\tools\New-TemplateSpecs.ps1 `
  -Location '<region>' `
  -createSharedServices $true `
  -createNetwork $false `
  -createImageManagement $false `
  -createCustomImage $false `
  -createHostPool $false `
  -createAutomatedHostPool $false `
  -CreateAddOns $false
```

Publishing does not deploy Shared Services. In the Azure portal, open **Template Specs**, select
**AVD Shared Services**, and choose **Deploy**. After submitting the deployment, download the
template and parameters and retain the validated parameter file under
`customer\parameters\sharedServices\` for repeatable deployments.

### Azure Portal Blue Button

Blue Button deployment is available in Azure Commercial and Azure Government. Use Template Specs
or PowerShell/CLI in Azure Government Secret and Top Secret.

[![Deploy to Azure](../../docs/images/deploytoazurebutton.png)](https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2FsharedServices%2FsharedServices.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2FsharedServices%2FuiFormDefinition.json)
[![Deploy to Azure Gov](../../docs/images/deploytoazuregovbutton.png)](https://portal.azure.us/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2FsharedServices%2FsharedServices.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2FsharedServices%2FuiFormDefinition.json)

### PowerShell or Azure CLI

For repeatable deployment, start with the parameter file exported from the Template Spec form. The
repository also includes a minimal automated-host-pool prerequisite example:

- `customer-examples/parameters/sharedServices/poc.automatedHostPoolPrerequisites.sharedServices.parameters.json`

Copy examples into the git-ignored customer area before editing them:

```powershell
Copy-Item `
  '.\customer-examples\parameters\sharedServices\poc.automatedHostPoolPrerequisites.sharedServices.parameters.json' `
  '.\customer\parameters\sharedServices\poc.sharedServices.parameters.json'

$vmAdminUserName = Read-Host 'VM administrator username' -AsSecureString
$vmAdminPassword = Read-Host 'VM administrator password' -AsSecureString

$deployment = New-AzDeployment `
  -Name "shared-services-$(Get-Date -Format 'yyyyMMddHHmmss')" `
  -Location '<region>' `
  -TemplateFile '.\deployments\sharedServices\sharedServices.bicep' `
  -TemplateParameterFile '.\customer\parameters\sharedServices\poc.sharedServices.parameters.json' `
  -virtualMachineAdminUserName $vmAdminUserName `
  -virtualMachineAdminPassword $vmAdminPassword
```

For Azure CLI, pass secrets from an approved secure source rather than placing them in shell history
or committed parameter files:

```bash
az deployment sub create \
  --name shared-services \
  --location <region> \
  --template-file deployments/sharedServices/sharedServices.bicep \
  --parameters @customer/parameters/sharedServices/prod.sharedServices.parameters.json
```

## Outputs and Consumers

Outputs for resources that were not selected are empty strings.

| Output | Downstream parameter |
| --- | --- |
| `secretsKeyVaultResourceId` | Standard host pool: `existingCredentialsKeyVaultResourceId` |
| `secretsKeyVaultResourceId` | Automated host pool, Session Hosts, or Session Host Replacer: `credentialsKeyVaultResourceId` |
| `encryptionKeyVaultResourceId` | Image Management or FSLogix Storage: `encryptionKeyVaultResourceId` |
| `encryptionKeyVaultResourceId` | Standard host pool: `existingEncryptionKeyVaultResourceId` |
| `logAnalyticsWorkspaceResourceId` | Image Management: `logAnalyticsWorkspaceResourceId` |
| `logAnalyticsWorkspaceResourceId` | Host pool: `existingLogAnalyticsWorkspaceResourceId` |
| `avdInsightsDataCollectionRuleResourceId` | Host pool: `existingAVDInsightsDataCollectionRuleResourceId` |
| `dataCollectionEndpointResourceId` | Host pool: `existingDataCollectionEndpointResourceId` |
| `azureMonitorAgentIdentityResourceId` | Automated host pool: `monitoringUserAssignedIdentityResourceId` |
| `azureMonitorPrivateLinkScopeResourceId` | Host pool: `azureMonitorPrivateLinkScopeResourceId` |
| `fslogixBackupVaultResourceId` | Pooled host pool: `existingFilesBackupVaultResourceId` |
| `fslogixBackupPolicyName` | Pooled host pool: `existingFilesBackupPolicyName` |
| `fslogixBackupVaultResourceId` | FSLogix Storage: `recoveryServicesVaultResourceId` |
| `fslogixBackupPolicyName` | FSLogix Storage: `fileSharePolicyName` |

Additional outputs provide generated resource names, the Encryption Key Vault URI, monitoring
resource-group name, and FSLogix backup policy resource ID.

## Security and Operational Notes

- Both Key Vaults use Azure RBAC authorization. Shared Services does not grant administrators or
  downstream deployment identities broad data-plane access.
- The Secrets Key Vault permits ARM template deployment so approved downstream templates can
  resolve credential references. Consumers still require their documented identity and RBAC setup.
- The Encryption Key Vault is Premium, purge-protected, and enabled for disk encryption. Encryption
  keys are created by downstream CMK deployments, not by Shared Services itself.
- Key Vault and Recovery Services diagnostics are sent to the newly deployed workspace, or to
  `existingLogAnalyticsWorkspaceResourceId` when supplied without new monitoring.
- The AVD Insights DCR collects the supported performance and event data documented for FederalAVD.
  It does not collect the Windows Security event log; add a supplemental DCR or SIEM agent when
  Security events are required.
- A Recovery Services vault and policy do not protect shares until a consuming deployment registers
  the Azure Files storage account and protected items.
- Validate service and regional availability in the target cloud before deployment. Blue Button
  links are not available in air-gapped clouds, and any required templates or dependencies must be
  transferred through the approved process.

## Next Steps

1. Record the outputs required by each downstream deployment.
2. Upload image artifacts after Image Management is deployed and before any image build consumes
   them.
3. Deploy a host pool only after its required credential, monitoring, encryption, and backup inputs
   resolve to resources in the intended subscriptions and region.
4. Use the [Quick Start](../../docs/quick-start.md) for the complete deployment sequence and the
   [Automation Guide](../../docs/automation-guide.md) for output-to-input wiring.
