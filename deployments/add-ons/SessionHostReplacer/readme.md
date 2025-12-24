# AVD Session Host Replacer Add-On

Automated lifecycle management for Azure Virtual Desktop session hosts. This add-on deploys a PowerShell function app that monitors session host age and image versions, automatically replacing outdated VMs to maintain fleet health and security compliance.

## Features

- **Automated Session Host Replacement**: Monitors session host age and replaces VMs exceeding configured thresholds
- **Image Version Tracking**: Detects outdated session hosts using old VM images and triggers replacements
- **Graceful Draining**: Drains user sessions before deletion with configurable grace periods
- **User Notifications**: Sends messages to active users before draining session hosts
- **Throttled Replacements**: Configurable limit on simultaneous replacements for safety
- **Tag-Based Opt-In**: Only replaces session hosts with inclusion tag
- **Device Cleanup**: Optional Entra ID and Intune device record removal
- **Template Spec Integration**: Deploys new session hosts using pre-compiled Template Spec
- **Private Endpoint Support**: Full network isolation for function app and storage

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Session Host Replacer Function App (Timer: Every 6 hours)  │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  1. Get Session Hosts (REST API)                     │   │
│  │  2. Check Age & Image Version                        │   │
│  │  3. Drain Old Session Hosts (Update allowNewSession) │   │
│  │  4. Deploy New Session Hosts (Template Spec)         │   │
│  │  5. Delete Drained Session Hosts after Grace Period  │   │
│  │  6. Cleanup Entra/Intune Devices (Graph API)         │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
           │                            │
           ▼                            ▼
   ┌───────────────┐          ┌─────────────────────┐
   │  Host Pool    │          │  Session Host RG    │
   │  (Read)       │          │  (Deploy/Delete VMs)│
   └───────────────┘          └─────────────────────┘
```

## Prerequisites

### 1. User-Assigned Managed Identity with Graph API Permissions

The function app requires a User-Assigned Managed Identity with Microsoft Graph API permissions pre-configured:

```powershell
# Create the User-Assigned Managed Identity
$resourceGroup = "rg-avd-management"
$identityName = "uami-avd-session-host-replacer"
$location = "usgovvirginia"

$identity = New-AzUserAssignedIdentity `
    -ResourceGroupName $resourceGroup `
    -Name $identityName `
    -Location $location

# Get the principal ID
$principalId = $identity.PrincipalId
$clientId = $identity.ClientId

# Connect to Microsoft Graph
Connect-MgGraph -Scopes "Application.Read.All", "AppRoleAssignment.ReadWrite.All"

# Get Microsoft Graph Service Principal
$graphSp = Get-MgServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'"

# Get required Graph API permissions
$deviceReadWrite = $graphSp.AppRoles | Where-Object { $_.Value -eq "Device.ReadWrite.All" }
$intuneReadWrite = $graphSp.AppRoles | Where-Object { $_.Value -eq "DeviceManagementManagedDevices.ReadWrite.All" }

# Grant permissions
New-MgServicePrincipalAppRoleAssignment `
    -ServicePrincipalId $principalId `
    -PrincipalId $principalId `
    -ResourceId $graphSp.Id `
    -AppRoleId $deviceReadWrite.Id

New-MgServicePrincipalAppRoleAssignment `
    -ServicePrincipalId $principalId `
    -PrincipalId $principalId `
    -ResourceId $graphSp.Id `
    -AppRoleId $intuneReadWrite.Id

Write-Host "User-Assigned Identity Resource ID: $($identity.Id)"
Write-Host "Save this value for the deployment parameter: sessionHostReplacerUserAssignedIdentityResourceId"
```

### 2. Template Spec for Session Host Deployments

Compile your session host bicep template to JSON and create a Template Spec:

```powershell
# Compile bicep to JSON
bicep build deployments/hostpools/modules/sessionHosts/sessionHosts.bicep --outfile sessionHosts.json

# Create Template Spec
$templateSpecRG = "rg-avd-management"
$templateSpecName = "ts-avd-session-hosts"
$version = "1.0.0"

New-AzTemplateSpec `
    -ResourceGroupName $templateSpecRG `
    -Name $templateSpecName `
    -Version $version `
    -Location $location `
    -TemplateFile "./sessionHosts.json"

# Get the Template Spec Version Resource ID
$templateSpec = Get-AzTemplateSpec -ResourceGroupName $templateSpecRG -Name $templateSpecName -Version $version
Write-Host "Template Spec Version Resource ID: $($templateSpec.Versions[$version].Id)"
Write-Host "Save this value for the deployment parameter: sessionHostTemplateSpecVersionResourceId"
```

### 3. App Service Plan

The function app requires a Premium V3 App Service Plan (shared or dedicated):

```powershell
# Create App Service Plan (Premium V3 for VNet integration)
$appServicePlanRG = "rg-avd-management"
$appServicePlanName = "asp-avd-functions"

New-AzAppServicePlan `
    -ResourceGroupName $appServicePlanRG `
    -Name $appServicePlanName `
    -Location $location `
    -Tier "PremiumV3" `
    -WorkerSize "Small" `
    -NumberofWorkers 1

$plan = Get-AzAppServicePlan -ResourceGroupName $appServicePlanRG -Name $appServicePlanName
Write-Host "App Service Plan Resource ID: $($plan.Id)"
Write-Host "Save this value for the deployment parameter: appServicePlanResourceId"
```

### 4. Encryption Resources

For customer-managed encryption keys:

- User-Assigned Managed Identity for encryption
- Azure Key Vault with encryption key
- Appropriate RBAC on Key Vault (Key Vault Crypto Officer or Key Vault Crypto User)

### 5. Session Host Tagging

Session hosts must be tagged to opt into automated replacement:

```powershell
# Tag session hosts for automated replacement
$sessionHostRG = "rg-avd-session-hosts"
$vmName = "avd-vm-001"

$tags = @{
    "IncludeInAutoReplace" = "true"
    "AutoReplaceDeployTimestamp" = (Get-Date).ToUniversalTime().ToString('o')
}

Update-AzTag -ResourceId "/subscriptions/{subscriptionId}/resourceGroups/$sessionHostRG/providers/Microsoft.Compute/virtualMachines/$vmName" -Tag $tags -Operation Merge
```

## Deployment

### Azure Portal

Use the **Deploy to Azure** button or deploy via Azure Portal Custom Deployment using `uiFormDefinition.json`.

### PowerShell

```powershell
$subscriptionId = (Get-AzContext).Subscription.Id
$location = "usgovvirginia"

$params = @{
    hostPoolResourceId = "/subscriptions/$subscriptionId/resourceGroups/rg-avd-hostpool/providers/Microsoft.DesktopVirtualization/hostPools/hp-avd-prod"
    sessionHostResourceGroupName = "rg-avd-session-hosts"
    sessionHostTemplateSpecVersionResourceId = "/subscriptions/$subscriptionId/resourceGroups/rg-avd-management/providers/Microsoft.Resources/templateSpecs/ts-avd-session-hosts/versions/1.0.0"
    sessionHostReplacerUserAssignedIdentityResourceId = "/subscriptions/$subscriptionId/resourceGroups/rg-avd-management/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uami-avd-session-host-replacer"
    appServicePlanResourceId = "/subscriptions/$subscriptionId/resourceGroups/rg-avd-management/providers/Microsoft.Web/serverfarms/asp-avd-functions"
    encryptionUserAssignedIdentityResourceId = "/subscriptions/$subscriptionId/resourceGroups/rg-avd-management/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uami-encryption"
    encryptionKeyVaultUri = "https://kv-avd-encryption.vault.usgovcloudapi.net/"
    
    # Lifecycle Management Parameters
    maxSessionHostsToReplace = 1
    targetVMAgeDays = 45
    drainGracePeriodHours = 24
    removeEntraDevice = $false
    removeIntuneDevice = $false
    
    location = $location
}

New-AzSubscriptionDeployment `
    -Location $location `
    -TemplateFile "deployments/add-ons/SessionHostReplacer/main.bicep" `
    -TemplateParameterObject $params `
    -Verbose
```

### Azure CLI

```bash
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
LOCATION="usgovvirginia"

az deployment sub create \
    --location $LOCATION \
    --template-file deployments/add-ons/SessionHostReplacer/main.bicep \
    --parameters \
        hostPoolResourceId="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/rg-avd-hostpool/providers/Microsoft.DesktopVirtualization/hostPools/hp-avd-prod" \
        sessionHostResourceGroupName="rg-avd-session-hosts" \
        sessionHostTemplateSpecVersionResourceId="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/rg-avd-management/providers/Microsoft.Resources/templateSpecs/ts-avd-session-hosts/versions/1.0.0" \
        sessionHostReplacerUserAssignedIdentityResourceId="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/rg-avd-management/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uami-avd-session-host-replacer" \
        credentialsKeyVaultResourceId="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/rg-avd-keyvault/providers/Microsoft.KeyVault/vaults/kv-avd-credentials" \
        appServicePlanResourceId="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/rg-avd-management/providers/Microsoft.Web/serverfarms/asp-avd-functions" \
        encryptionUserAssignedIdentityResourceId="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/rg-avd-management/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uami-encryption" \
        encryptionKeyVaultUri="https://kv-avd-encryption.vault.usgovcloudapi.net/" \
        maxSessionHostsToReplace=1 \
        targetVMAgeDays=45 \
        drainGracePeriodHours=24 \
        location=$LOCATION
```

## Parameters

### Core Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `hostPoolResourceId` | Yes | - | Resource ID of the AVD Host Pool to manage |
| `sessionHostResourceGroupName` | Yes | - | Resource group containing session hosts |
| `resourceGroupManagement` | No | Extracted from appServicePlanResourceId | Resource group for function app and storage resources |
| `sessionHostTemplateSpecVersionResourceId` | Yes | - | Template Spec version for session host deployments |
| `sessionHostReplacerUserAssignedIdentityResourceId` | Yes | - | UAI with Graph API permissions |
| `credentialsKeyVaultResourceId` | Yes | - | Key Vault resource ID containing session host credentials |
| `virtualMachineNamePrefix` | Yes | - | VM name prefix used for session hosts |
| `appServicePlanResourceId` | Yes | - | App Service Plan resource ID |
| `location` | No | deployment().location | Location for deployment metadata |

### Resource Naming

Resource names are automatically generated using the same naming convention as the hostpool deployment. The naming convention is derived from:
- **Host Pool Resource ID**: Provides the naming context
- **Session Host Resource Group**: Location is used for regional naming

See [deployments/hostpools/modules/resourceNames.bicep](../../hostpools/modules/resourceNames.bicep) for the complete naming logic.

No additional naming parameters are required since this add-on replaces existing session hosts rather than creating new naming patterns.for encryption |
| `encryptionKeyVaultResourceId` | Yes | - | Key Vault resource ID |
| `encryptionKeyVaultUri` | Yes | - | Key Vault URI |
| `encryptionKeyName` | No | Auto-generated | Name for encryption key |

### Lifecycle Management Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `maxSessionHostsToReplace` | No | 1 | Max session hosts to replace per execution (1-20) |
| `targetVMAgeDays` | No | 45 | Age threshold in days for replacement (1-365) |
| `drainGracePeriodHours` | No | 24 | Grace period after draining before deletion (1-168) |
| `fixSessionHostTags` | No | true | Auto-fix missing/invalid tags |
| `includePreExistingSessionHosts` | No | false | Include session hosts without tags |
| `tagIncludeInAutomation` | No | IncludeInAutoReplace | Tag name for opt-in |
| `removeEntraDevice` | No | false | Remove Entra device records |
| `removeIntuneDevice` | No | false | Remove Intune device records |
| `timerSchedule` | No | Every 6 hours | Cron expression for execution schedule |

### Networking Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `privateEndpoint` | No | false | Enable private endpoints |
| `privateEndpointSubnetResourceId` | No | Empty | Subnet for private endpoints |
| `privateEndpointNamePrefix` | No | Empty | Prefix for private endpoint names |

### Monitoring Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `logAnalyticsWorkspaceResourceId` | No | Empty | Log Analytics Workspace for Application Insights |
| `appInsightsName` | No | Auto-generated | Application Insights name |
| `privateLinkScopeResourceId` | No | Empty | Private Link Scope for Application Insights |

## RBAC Permissions

The function app's User-Assigned Managed Identity is automatically granted:

### Azure RBAC Roles

| Role | Scope | Purpose |
|------|-------|---------|
| **Desktop Virtualization Virtual Machine Contributor** | Session Host RG | Deploy and delete VMs, update host pool |
| **Tag Contributor** | Session Host RG | Update VM tags (drain timestamp, inclusion) |
| **Reader** | Host Pool RG | Read host pool configuration |

### Microsoft Graph API Permissions

| Permission | Type | Purpose |
|-----------|------|---------|
| **Device.ReadWrite.All** | Application | Delete Entra device records |
| **DeviceManagementManagedDevices.ReadWrite.All** | Application | Delete Intune device records |

> **Note**: Graph API permissions must be pre-granted on the User-Assigned Managed Identity (see Prerequisites).

## Configuration

### Timer Schedule

The function runs on a timer trigger (default: every 6 hours). Customize using cron expressions:

```bicep
timerSchedule: '0 0 */6 * * *'  // Every 6 hours
timerSchedule: '0 0 2 * * *'    // Daily at 2 AM
timerSchedule: '0 0 */12 * * *' // Every 12 hours
```

### Session Host Parameters

The `sessionHostParameters` object is passed to the Template Spec during deployment. This should match your session host deployment configuration.

**Important:** The `credentialsKeyVaultResourceId` parameter is required and must be passed both at the main deployment level AND within `sessionHostParameters`:

```bicep
// Main deployment parameter
credentialsKeyVaultResourceId: '/subscriptions/xxxxx/resourceGroups/rg-kv/providers/Microsoft.KeyVault/vaults/kv-credentials'

// Session host parameters (passed to Template Spec)
sessionHostParameters: {
  credentialsKeyVaultResourceId: '/subscriptions/xxxxx/resourceGroups/rg-kv/providers/Microsoft.KeyVault/vaults/kv-credentials'
  virtualMachineSize: 'Standard_D4s_v5'
  diskSku: 'Premium_LRS'
  imagePublisher: 'MicrosoftWindowsDesktop'
  imageOffer: 'office-365'
  imageSku: 'win11-23h2-avd-m365'
  // ... other session host parameters
}
```

**Required Key Vault Secrets:**
- `VirtualMachineAdminPassword`: Local administrator password for session hosts
- `VirtualMachineAdminUserName`: Local administrator username for session hosts
- `DomainJoinUserPassword`: Password for domain join account (required for domain-joined VMs)
- `DomainJoinUserPrincipalName`: UPN for domain join account (required for domain-joined VMs)
```

## Monitoring

### Application Insights

Enable Application Insights by providing `logAnalyticsWorkspaceResourceId`:

```powershell
# Query function execution logs
ApplicationInsights
| where AppRoleName == "func-avd-shr-xxxxx"
| where TimeGenerated > ago(24h)
| project TimeGenerated, SeverityLevel, Message
| order by TimeGenerated desc
```

### Key Metrics

- **Session hosts evaluated**: Total count checked per execution
- **Session hosts filtered**: Count with IncludeInAutoReplace tag
- **Deployments triggered**: New session hosts deployed
- **Session hosts drained**: VMs put in drain mode
- **Session hosts deleted**: VMs removed after grace period

## Troubleshooting

### Function App Not Running

1. Check timer trigger: `az functionapp function show --name <functionAppName> --resource-group <rg> --function-name session-host-replacer`
2. Verify App Service Plan is running: `az appserviceplan show --name <planName> --resource-group <rg>`
3. Check Application Insights for errors

### RBAC Permission Errors

Verify role assignments:

```powershell
$uaiPrincipalId = (Get-AzUserAssignedIdentity -ResourceGroupName <rg> -Name <identityName>).PrincipalId
Get-AzRoleAssignment -ObjectId $uaiPrincipalId
```

Expected roles:
- Desktop Virtualization Virtual Machine Contributor (Session Host RG)
- Tag Contributor (Session Host RG)
- Reader (Host Pool RG)

### Graph API Permission Errors

Verify Graph API permissions:

```powershell
Connect-MgGraph
$uaiPrincipalId = "<principalId>"
$sp = Get-MgServicePrincipal -Filter "PrincipalId eq '$uaiPrincipalId'"
Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id
```

### Session Hosts Not Replacing

1. Verify session hosts have `IncludeInAutoReplace` tag set to `true`
2. Check session host age meets `targetVMAgeDays` threshold
3. Verify Template Spec exists and is accessible
4. Check for running deployments (only deploys if no active deployments)

### Tag Issues

Enable auto-fix: `fixSessionHostTags: true`

This will:
- Create missing `AutoReplaceDeployTimestamp` tags using VM creation time
- Fix invalid date formats in tags

## Security Considerations

1. **User-Assigned Managed Identity**: Graph API permissions are pre-granted, eliminating need for post-deployment configuration
2. **Customer-Managed Keys**: Function app storage encrypted with customer keys in Key Vault
3. **Private Endpoints**: Optional network isolation for all function app and storage traffic
4. **RBAC Least Privilege**: Identity only receives minimum required permissions
5. **Throttled Operations**: `maxSessionHostsToReplace` prevents mass deletions
6. **Tag-Based Opt-In**: Only explicitly tagged session hosts are managed

## Limitations

- Function app must have network connectivity to Azure Resource Manager API
- Template Spec must be in same Azure environment (Commercial/Government/China)
- Session hosts must be Entra-joined or Hybrid-joined for device cleanup
- Maximum 20 session hosts can be replaced per execution (configurable)

## Support

For issues, questions, or contributions, please refer to the main [FederalAVD repository](https://github.com/Azure/FederalAVD).

## License

This project is licensed under the MIT License - see the LICENSE file for details.
