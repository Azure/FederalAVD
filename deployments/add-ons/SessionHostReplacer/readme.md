# AVD Session Host Replacer Add-On

## Overview

The AVD Session Host Replacer is an automated Azure Function that manages the lifecycle of Azure Virtual Desktop session hosts. It monitors session host age and image versions, automatically draining and replacing outdated VMs to maintain fleet health, security compliance, and image currency. This add-on enables continuous image updates without manual intervention.

## Features

- **Automated Age-Based Replacement**: Replaces session hosts exceeding configured age threshold (default: 45 days)
- **Image Version Tracking**: Detects session hosts using outdated VM images and triggers replacements when newer versions are available
- **Graceful Draining**: Drains user sessions before deletion with configurable grace periods (default: 24 hours)
- **User Notifications**: (Optional) Sends messages to active users before draining session hosts
- **Progressive Scale-Up**: (Optional) Gradually increases deployment batch size based on successful deployments, starting small and scaling up over time
- **Tag-Based Opt-In**: Only replaces session hosts with inclusion tag (`IncludeInAutoReplace: true`)
- **Device Cleanup**: Optional automatic removal of Entra ID and Intune device records when deleting session hosts
- **Template Spec Integration**: Deploys new session hosts using pre-compiled Template Spec or auto-creates one from existing configuration
- **Zero Trust Networking**: Full support for private endpoints and VNet integration
- **Customer-Managed Encryption**: Optional customer-managed keys for function app storage
- **Comprehensive Monitoring**: Application Insights integration with detailed logging and diagnostics

## How It Works

### Workflow

1. **Timer Trigger**: Function runs on a configurable schedule (default: every hour)
2. **Session Host Discovery**: Enumerates all session hosts in the hostpool using Azure REST API
3. **Tag Validation**: Filters to session hosts with `IncludeInAutoReplace: true` tag (auto-fixes missing/invalid tags if enabled)
4. **Age & Image Analysis**: 
   - Calculates session host age from `AutoReplaceDeployTimestamp` tag
   - Retrieves latest VM image version from marketplace or gallery
   - Compares current session host image version against latest
5. **Drain Decision**: Marks session hosts for draining if:
   - Age exceeds `targetVMAgeDays` threshold, OR
   - Image version is outdated
6. **Deployment Check**: Checks for running deployments in session host resource group (skips deployment if active)
7. **Progressive Scale-Up** (if enabled):
   - Calculates deployment batch size based on current percentage and consecutive successes
   - Starts with small batch (e.g., 10%), gradually increases after successful deployments
   - Resets to initial percentage on failures
8. **New Session Host Deployment**: Deploys new VMs using Template Spec with indexed naming
9. **Grace Period Monitoring**: Tracks drained session hosts with `AutoReplacePendingDrainTimestamp` tag
10. **Deletion**: Removes session hosts after grace period elapses and no active sessions remain
11. **Device Cleanup** (if enabled): Removes corresponding Entra ID and Intune device records
12. **Scaling Plan Integration**: Applies scaling plan exclusion tag to drained hosts

### Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────────────┐
│  SessionHostReplacer Function App (Timer: Configurable, default hourly) │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │ 1. Enumerate Session Hosts (AVD REST API)                          │  │
│  │ 2. Validate & Fix Tags (IncludeInAutoReplace, DeployTimestamp)     │  │
│  │ 3. Analyze Age & Image Version                                     │  │
│  │ 4. Calculate Deployment Batch Size (Progressive Scale-Up)          │  │
│  │ 5. Deploy New Session Hosts (Template Spec)                        │  │
│  │ 6. Drain Old Session Hosts (Update allowNewSession to false)       │  │
│  │ 7. Monitor Grace Period                                            │  │
│  │ 8. Delete Drained Session Hosts (After grace period + no sessions) │  │
│  │ 9. Cleanup Entra/Intune Devices (Graph API - optional)             │  │
│  └────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────┘
           │                            │                       │
           ▼                            ▼                       ▼
   ┌───────────────┐          ┌─────────────────────┐  ┌──────────────┐
   │  Host Pool    │          │  Session Host RG    │  │  Graph API   │
   │  (Read/Write) │          │  (Deploy/Delete VMs)│  │  (Optional)  │
   └───────────────┘          └─────────────────────┘  └──────────────┘
```

## Prerequisites

### 1. User-Assigned Managed Identity with Graph API Permissions

The function app requires a **User-Assigned Managed Identity** with Microsoft Graph API permissions pre-configured (required only if device cleanup is enabled):

**PowerShell Setup:**
```powershell
# Create the User-Assigned Managed Identity
$resourceGroup = "rg-avd-management"
$identityName = "uami-avd-session-host-replacer"
$location = "eastus"

$identity = New-AzUserAssignedIdentity `
    -ResourceGroupName $resourceGroup `
    -Name $identityName `
    -Location $location

# Get the principal ID
$principalId = $identity.PrincipalId
$clientId = $identity.ClientId

Write-Host "User-Assigned Identity Resource ID: $($identity.Id)"
Write-Host "Principal ID: $principalId"
Write-Host "Client ID: $clientId"

# Connect to Microsoft Graph (requires privileges to grant application permissions)
Connect-MgGraph -Scopes "Application.Read.All", "AppRoleAssignment.ReadWrite.All"

# Get Microsoft Graph Service Principal
$graphSp = Get-MgServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'"

# Get required Graph API permissions
$deviceReadWrite = $graphSp.AppRoles | Where-Object { $_.Value -eq "Device.ReadWrite.All" }
$intuneReadWrite = $graphSp.AppRoles | Where-Object { $_.Value -eq "DeviceManagementManagedDevices.ReadWrite.All" }

# Grant Device.ReadWrite.All permission
New-MgServicePrincipalAppRoleAssignment `
    -ServicePrincipalId $principalId `
    -PrincipalId $principalId `
    -ResourceId $graphSp.Id `
    -AppRoleId $deviceReadWrite.Id

# Grant DeviceManagementManagedDevices.ReadWrite.All permission
New-MgServicePrincipalAppRoleAssignment `
    -ServicePrincipalId $principalId `
    -PrincipalId $principalId `
    -ResourceId $graphSp.Id `
    -AppRoleId $intuneReadWrite.Id

Write-Host "Graph API permissions granted successfully"
Write-Host "Save the Identity Resource ID for deployment: $($identity.Id)"
```

**Azure CLI Setup:**
```bash
# Create User-Assigned Managed Identity
RESOURCE_GROUP="rg-avd-management"
IDENTITY_NAME="uami-avd-session-host-replacer"
LOCATION="eastus"

az identity create \
    --resource-group $RESOURCE_GROUP \
    --name $IDENTITY_NAME \
    --location $LOCATION

# Get identity details
IDENTITY_ID=$(az identity show --resource-group $RESOURCE_GROUP --name $IDENTITY_NAME --query id -o tsv)
PRINCIPAL_ID=$(az identity show --resource-group $RESOURCE_GROUP --name $IDENTITY_NAME --query principalId -o tsv)

echo "Identity Resource ID: $IDENTITY_ID"
echo "Principal ID: $PRINCIPAL_ID"

# Grant Graph API permissions (requires Azure AD admin role)
# Use Microsoft Graph PowerShell or Azure Portal to grant:
# - Device.ReadWrite.All
# - DeviceManagementManagedDevices.ReadWrite.All
```

> **Note**: Graph API permissions are only required if `removeEntraDevice` or `removeIntuneDevice` parameters are set to `true`. If device cleanup is not needed, the identity only requires Azure RBAC permissions (automatically granted during deployment).

### 2. Session Host Template Spec (Optional - Auto-Created if Not Provided)

You can either provide an existing Template Spec or let the add-on create one automatically.

**Option A: Use Existing Template Spec**

If you already have a Template Spec for session host deployments:
```powershell
$templateSpecVersionResourceId = "/subscriptions/{sub-id}/resourceGroups/{rg}/providers/Microsoft.Resources/templateSpecs/{name}/versions/{version}"
```

**Option B: Auto-Create Template Spec (Recommended)**

Leave `sessionHostTemplateSpecVersionResourceId` empty, and the add-on will:
1. Create a Template Spec in the same resource group as the function app
2. Use the naming convention derived from your hostpool name
3. Default to version `1.0.0` (configurable via `templateSpecVersion` parameter)

The Template Spec wraps the session host deployment module and will be used for all new deployments.

### 3. Key Vault with Session Host Credentials

A Key Vault containing session host deployment secrets:

| Secret Name | Required | Description |
|-------------|----------|-------------|
| `VirtualMachineAdminPassword` | Yes | Local administrator password for session hosts |
| `VirtualMachineAdminUserName` | Yes | Local administrator username for session hosts |
| `DomainJoinUserPassword` | Conditional | Domain join account password (required for domain-joined VMs) |
| `DomainJoinUserPrincipalName` | Conditional | Domain join account UPN (required for domain-joined VMs) |

```powershell
# Example: Create Key Vault secrets
$keyVaultName = "kv-avd-credentials"

Set-AzKeyVaultSecret -VaultName $keyVaultName -Name "VirtualMachineAdminUserName" -SecretValue (ConvertTo-SecureString "avdadmin" -AsPlainText -Force)
Set-AzKeyVaultSecret -VaultName $keyVaultName -Name "VirtualMachineAdminPassword" -SecretValue (ConvertTo-SecureString "P@ssw0rd123!" -AsPlainText -Force)
Set-AzKeyVaultSecret -VaultName $keyVaultName -Name "DomainJoinUserPrincipalName" -SecretValue (ConvertTo-SecureString "avd-join@contoso.com" -AsPlainText -Force)
Set-AzKeyVaultSecret -VaultName $keyVaultName -Name "DomainJoinUserPassword" -SecretValue (ConvertTo-SecureString "P@ssw0rd456!" -AsPlainText -Force)
```

### 4. Session Host Tagging Strategy

Session hosts must be tagged to participate in automated replacement. The add-on uses three tags:

| Tag Name | Default | Purpose | Auto-Created |
|----------|---------|---------|--------------|
| `IncludeInAutoReplace` | (configurable) | Opt-in flag for automation | No (must be set manually or via deployment) |
| `AutoReplaceDeployTimestamp` | (configurable) | ISO 8601 timestamp of VM deployment | Yes (if `fixSessionHostTags: true`) |
| `AutoReplacePendingDrainTimestamp` | (configurable) | ISO 8601 timestamp when drain started | Yes (set during drain) |

**Manual Tagging Example:**
```powershell
# Tag existing session hosts for automated replacement
$sessionHostRG = "rg-avd-session-hosts"
$vmName = "vm-avd-001"

$tags = @{
    "IncludeInAutoReplace" = "true"
    "AutoReplaceDeployTimestamp" = (Get-Date).ToUniversalTime().ToString('o')
}

$vm = Get-AzVM -ResourceGroupName $sessionHostRG -Name $vmName
Update-AzTag -ResourceId $vm.Id -Tag $tags -Operation Merge
```

**Tag Auto-Fix Feature:**
- When `fixSessionHostTags: true` (default), the function automatically creates missing `AutoReplaceDeployTimestamp` tags using the VM's creation time
- Set `includePreExistingSessionHosts: true` to include session hosts deployed before this add-on was installed

### 5. App Service Plan (Optional)

The function app requires a **Premium V3 App Service Plan** for VNet integration support. You can either:

**Option A: Use Existing Plan (Recommended for Cost Savings)**
```powershell
$appServicePlanResourceId = "/subscriptions/{sub-id}/resourceGroups/{rg}/providers/Microsoft.Web/serverfarms/{plan-name}"
```

**Option B: Create New Plan**
Leave `appServicePlanResourceId` empty and set `zoneRedundant: false` (or `true` for zone redundancy).

```powershell
# Create App Service Plan manually (Premium V3 required for VNet integration)
New-AzAppServicePlan `
    -ResourceGroupName "rg-avd-management" `
    -Name "asp-avd-functions" `
    -Location "eastus" `
    -Tier "PremiumV3" `
    -WorkerSize "Small" `
    -NumberofWorkers 1

$plan = Get-AzAppServicePlan -ResourceGroupName "rg-avd-management" -Name "asp-avd-functions"
Write-Host "App Service Plan Resource ID: $($plan.Id)"
```

> **Note**: If using an existing plan, ensure it's in the same region as the function app deployment.

### 6. Networking (Optional - for Private Endpoints)

If using private endpoints (`privateEndpoint: true`), you need:

- **VNet with subnets**:
  - Subnet delegated to `Microsoft.Web/serverFarms` for function app VNet integration
  - Subnet for private endpoints (function app and storage)
- **Private DNS Zones**:
  - `privatelink.blob.core.windows.net` (or `.usgovcloudapi.net` for Azure Gov)
  - `privatelink.file.core.windows.net`
  - `privatelink.queue.core.windows.net`
  - `privatelink.table.core.windows.net`
  - `privatelink.azurewebsites.net` (or `.azurewebsites.us` for Azure Gov)

### 7. Customer-Managed Encryption (Optional)

For customer-managed keys:

- **User-Assigned Managed Identity for encryption** (different from the function identity)
- **Azure Key Vault** with encryption key
- **RBAC**: Identity must have **Key Vault Crypto Service Encryption User** role on Key Vault

```powershell
# Create encryption identity
$encryptionIdentity = New-AzUserAssignedIdentity `
    -ResourceGroupName "rg-avd-management" `
    -Name "uami-encryption" `
    -Location "eastus"

# Grant Key Vault Crypto Service Encryption User role
$keyVaultResourceId = "/subscriptions/{sub-id}/resourceGroups/{rg}/providers/Microsoft.KeyVault/vaults/{kv-name}"
New-AzRoleAssignment `
    -ObjectId $encryptionIdentity.PrincipalId `
    -RoleDefinitionName "Key Vault Crypto Service Encryption User" `
    -Scope $keyVaultResourceId
```
## Deployment

### Azure Portal

1. Navigate to **Azure Portal**
2. Search for **Deploy a custom template**
3. Select **Build your own template in the editor**
4. Upload `main.bicep` from `deployments/add-ons/SessionHostReplacer/`
5. Or use the `uiFormDefinition.json` for a guided form experience
6. Fill in required parameters (see Parameters section below)
7. Review and create

### Azure PowerShell

```powershell
$subscriptionId = (Get-AzContext).Subscription.Id
$location = "eastus"
$resourceGroup = "rg-avd-management"

$params = @{
    # Core Parameters
    hostPoolResourceId = "/subscriptions/$subscriptionId/resourceGroups/rg-avd-hostpool/providers/Microsoft.DesktopVirtualization/hostPools/hp-avd-prod"
    virtualMachinesResourceGroupId = "/subscriptions/$subscriptionId/resourceGroups/rg-avd-session-hosts"
    virtualMachineNamePrefix = "avd"
    virtualMachineSubnetResourceId = "/subscriptions/$subscriptionId/resourceGroups/rg-network/providers/Microsoft.Network/virtualNetworks/vnet-avd/subnets/snet-sessionhosts"
    
    # Identity & Credentials
    sessionHostReplacerUserAssignedIdentityResourceId = "/subscriptions/$subscriptionId/resourceGroups/rg-avd-management/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uami-avd-session-host-replacer"
    credentialsKeyVaultResourceId = "/subscriptions/$subscriptionId/resourceGroups/rg-avd-keyvault/providers/Microsoft.KeyVault/vaults/kv-avd-credentials"
    
    # Infrastructure (Optional - will create new if not provided)
    appServicePlanResourceId = "/subscriptions/$subscriptionId/resourceGroups/rg-avd-management/providers/Microsoft.Web/serverfarms/asp-avd-functions"
    sessionHostTemplateSpecVersionResourceId = "/subscriptions/$subscriptionId/resourceGroups/rg-avd-management/providers/Microsoft.Resources/templateSpecs/ts-avd-session-hosts/versions/1.0.0"
    
    # Lifecycle Management
    targetVMAgeDays = 45
    drainGracePeriodHours = 24
    fixSessionHostTags = $true
    includePreExistingSessionHosts = $true
    removeEntraDevice = $true
    removeIntuneDevice = $true
    
    # Progressive Scale-Up (Optional)
    enableProgressiveScaleUp = $false
    initialDeploymentPercentage = 10
    scaleUpIncrementPercentage = 20
    maxDeploymentBatchSize = 10
    
    # Session Host Configuration
    identitySolution = "ActiveDirectoryDomainServices"
    domainName = "contoso.com"
    ouPath = "OU=AVD,OU=Computers,DC=contoso,DC=com"
    imagePublisher = "MicrosoftWindowsDesktop"
    imageOffer = "windows-11"
    imageSku = "win11-25h2-avd"
    virtualMachineSize = "Standard_D4ads_v5"
    securityType = "TrustedLaunch"
    
    # Monitoring
    logAnalyticsWorkspaceResourceId = "/subscriptions/$subscriptionId/resourceGroups/rg-monitoring/providers/Microsoft.OperationalInsights/workspaces/law-avd"
    
    # Encryption (Optional)
    keyManagementStorageAccounts = "CustomerManaged"
    encryptionKeyVaultResourceId = "/subscriptions/$subscriptionId/resourceGroups/rg-avd-keyvault/providers/Microsoft.KeyVault/vaults/kv-encryption"
    
    location = $location
}

New-AzResourceGroupDeployment `
    -ResourceGroupName $resourceGroup `
    -TemplateFile "deployments/add-ons/SessionHostReplacer/main.bicep" `
    -TemplateParameterObject $params `
    -Verbose
```

### Azure CLI

```bash
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
LOCATION="eastus"
RESOURCE_GROUP="rg-avd-management"

az deployment group create \
    --resource-group $RESOURCE_GROUP \
    --template-file deployments/add-ons/SessionHostReplacer/main.bicep \
    --parameters \
        hostPoolResourceId="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/rg-avd-hostpool/providers/Microsoft.DesktopVirtualization/hostPools/hp-avd-prod" \
        virtualMachinesResourceGroupId="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/rg-avd-session-hosts" \
        virtualMachineNamePrefix="avd" \
        virtualMachineSubnetResourceId="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/rg-network/providers/Microsoft.Network/virtualNetworks/vnet-avd/subnets/snet-sessionhosts" \
        sessionHostReplacerUserAssignedIdentityResourceId="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/rg-avd-management/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uami-avd-session-host-replacer" \
        credentialsKeyVaultResourceId="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/rg-avd-keyvault/providers/Microsoft.KeyVault/vaults/kv-avd-credentials" \
        appServicePlanResourceId="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/rg-avd-management/providers/Microsoft.Web/serverfarms/asp-avd-functions" \
        targetVMAgeDays=45 \
        drainGracePeriodHours=24 \
        identitySolution="ActiveDirectoryDomainServices" \
        domainName="contoso.com" \
        ouPath="OU=AVD,OU=Computers,DC=contoso,DC=com" \
        imagePublisher="MicrosoftWindowsDesktop" \
        imageOffer="windows-11" \
        imageSku="win11-25h2-avd" \
        virtualMachineSize="Standard_D4ads_v5" \
        location=$LOCATION
```

## Parameters

The SessionHostReplacer add-on has a comprehensive set of parameters organized into logical categories. Below are the key parameters - see `main.bicep` for the complete list.

### Required Parameters

| Parameter | Description |
|-----------|-------------|
| `hostPoolResourceId` | **Required.** Resource ID of the AVD hostpool to manage |
| `virtualMachinesResourceGroupId` | **Required.** Resource ID of the resource group containing session hosts |
| `virtualMachineNamePrefix` | **Required.** VM name prefix used for session hosts (e.g., "avd") |
| `virtualMachineSubnetResourceId` | **Required.** Subnet resource ID for session host NICs |
| `sessionHostReplacerUserAssignedIdentityResourceId` | **Required.** UAI with Graph API permissions (for device cleanup) |
| `credentialsKeyVaultResourceId` | **Required.** Key Vault containing VirtualMachineAdminPassword, VirtualMachineAdminUserName, DomainJoinUserPassword, DomainJoinUserPrincipalName secrets |

### Optional Infrastructure Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `location` | string | Resource group location | Azure region for function app |
| `tags` | object | {} | Tags for all deployed resources |
| `appServicePlanResourceId` | string | '' | Existing App Service Plan resource ID (creates new Premium V3 if empty) |
| `zoneRedundant` | bool | false | Enable zone redundancy for new App Service Plan |
| `sessionHostTemplateSpecVersionResourceId` | string | '' | Existing Template Spec version (creates new if empty) |
| `templateSpecName` | string | Auto-generated | Template Spec name (only if creating new) |
| `templateSpecVersion` | string | '1.0.0' | Template Spec version (only if creating new) |

### Optional Networking Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `privateEndpoint` | bool | false | Enable private endpoints for function app storage and function app sites endpoint |
| `privateEndpointSubnetResourceId` | string | '' | Subnet for private endpoints |
| `functionAppDelegatedSubnetResourceId` | string | '' | Subnet for VNet integration (delegated to Microsoft.Web/serverFarms) |
| `azureBlobPrivateDnsZoneResourceId` | string | '' | Blob storage private DNS zone resource ID |
| `azureFilePrivateDnsZoneResourceId` | string | '' | File storage private DNS zone resource ID |
| `azureQueuePrivateDnsZoneResourceId` | string | '' | Queue storage private DNS zone resource ID |
| `azureTablePrivateDnsZoneResourceId` | string | '' | Table storage private DNS zone resource ID |
| `azureFunctionAppPrivateDnsZoneResourceId` | string | '' | Function app private DNS zone resource ID |

### Optional Encryption Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `keyManagementStorageAccounts` | string | 'MicrosoftManaged' | Encryption: `MicrosoftManaged`, `CustomerManaged`, `CustomerManagedHSM` |
| `encryptionKeyVaultResourceId` | string | '' | Key Vault resource ID for customer-managed keys |

### Optional Monitoring Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `logAnalyticsWorkspaceResourceId` | string | '' | Log Analytics Workspace for Application Insights |
| `privateLinkScopeResourceId` | string | '' | Private Link Scope for Application Insights private connectivity |

### Lifecycle Management Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `targetVMAgeDays` | int | 45 | Age threshold (days) before session host replacement (1-365) |
| `drainGracePeriodHours` | int | 24 | Grace period (hours) after draining before deletion (1-168) |
| `fixSessionHostTags` | bool | true | Auto-fix missing/invalid AutoReplaceDeployTimestamp tags using VM creation time |
| `includePreExistingSessionHosts` | bool | true | Include session hosts deployed before this add-on was installed |
| `tagIncludeInAutomation` | string | 'IncludeInAutoReplace' | Tag name for automation opt-in |
| `tagDeployTimestamp` | string | 'AutoReplaceDeployTimestamp' | Tag name for deploy timestamp |
| `tagPendingDrainTimestamp` | string | 'AutoReplacePendingDrainTimestamp' | Tag name for drain timestamp |
| `tagScalingPlanExclusionTag` | string | 'ScalingPlanExclusion' | Tag name for scaling plan exclusion |
| `removeEntraDevice` | bool | true | Remove Entra ID device records when deleting session hosts |
| `removeIntuneDevice` | bool | true | Remove Intune device records when deleting session hosts |
| `timerSchedule` | string | '0 0 * * * *' | CRON expression (default: every hour) |

### Progressive Scale-Up Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `enableProgressiveScaleUp` | bool | false | Enable percentage-based batching that gradually increases |
| `initialDeploymentPercentage` | int | 10 | Starting deployment size as % of needed hosts (1-100) |
| `scaleUpIncrementPercentage` | int | 20 | % increase after successful runs (5-50) |
| `maxDeploymentBatchSize` | int | 10 | Max hosts per run ceiling (1-50) |
| `successfulRunsBeforeScaleUp` | int | 1 | Consecutive successes before increasing % (1-5) |

### Session Host Configuration Parameters

The add-on includes 30+ parameters for session host configuration (image, size, security, FSLogix, monitoring, etc.). Key parameters:

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `imagePublisher` | string | 'MicrosoftWindowsDesktop' | Marketplace image publisher |
| `imageOffer` | string | 'windows-11' | Marketplace image offer |
| `imageSku` | string | 'win11-25h2-avd' | Marketplace image SKU |
| `customImageResourceId` | string | '' | Custom image resource ID (overrides marketplace) |
| `virtualMachineSize` | string | 'Standard_D4ads_v5' | VM size for session hosts |
| `identitySolution` | string | 'ActiveDirectoryDomainServices' | Identity solution |
| `domainName` | string | '' | Domain name for domain join |
| `ouPath` | string | '' | OU path for domain join |
| `securityType` | string | 'TrustedLaunch' | Security type: Standard, TrustedLaunch, ConfidentialVM |
| `availability` | string | 'AvailabilityZones' | Availability: AvailabilityZones, AvailabilitySets, None |
| `diskSku` | string | 'Premium_LRS' | OS disk SKU |
| `fslogixConfigureSessionHosts` | bool | false | Configure FSLogix on session hosts |
| `enableMonitoring` | bool | false | Enable Azure Monitor Agent |

> **Note**: See `main.bicep` for the complete list of session host parameters. All parameters from the sessionHost module are supported.

## RBAC Permissions

The function app's User-Assigned Managed Identity is automatically granted the following Azure RBAC roles during deployment:

| Role | Scope | Purpose |
|------|-------|---------|
| **Virtual Machine Contributor** | Virtual Machines Subscription | Deploy and delete VMs, update VM tags, manage VM resources |
| **Desktop Virtualization Host Pool Contributor** | Host Pool Resource Group | Update host pool, manage session hosts, drain sessions |
| **Reader** | Template Spec Resource Group | Read Template Spec for session host deployments |

### Microsoft Graph API Permissions (Pre-Configured)

The following application permissions must be pre-granted to the User-Assigned Managed Identity (see Prerequisites):

| Permission | Type | Purpose | Required When |
|-----------|------|---------|---------------|
| **Device.ReadWrite.All** | Application | Delete Entra ID device records | `removeEntraDevice: true` |
| **DeviceManagementManagedDevices.ReadWrite.All** | Application | Delete Intune device records | `removeIntuneDevice: true` |

> **Important**: Graph API permissions cannot be granted via Bicep and must be configured before deployment using Microsoft Graph PowerShell or Azure Portal.

## Architecture

### Deployed Resources

1. **Azure Function App** (PowerShell 7.4)
   - Runtime: PowerShell
   - Function: `session-host-replacer`
   - Trigger: Timer (configurable schedule, default: hourly)
   - Identity: User-assigned managed identity with Graph API permissions
   - RBAC: Virtual Machine Contributor, Desktop Virtualization Host Pool Contributor, Reader

2. **Function App Storage Account** (Standard_LRS)
   - Purpose: Function app backend (code, state, logs, deployment tracking)
   - Encryption: Platform-managed or customer-managed keys
   - Private endpoints: Optional (blob, file, queue, table)

3. **App Service Plan** (Premium V3 P1v3, optional)
   - Created only if `appServicePlanResourceId` is empty
   - SKU: Premium V3 (required for VNet integration)
   - Zone redundancy: Optional

4. **Template Spec** (optional)
   - Created if `sessionHostTemplateSpecVersionResourceId` is empty
   - Contains session host deployment template
   - Version: Default 1.0.0 (configurable)

5. **Application Insights** (optional)
   - Created if `logAnalyticsWorkspaceResourceId` is provided
   - Logs all function executions, decisions, and errors
   - Integrated with Log Analytics Workspace

6. **Private Endpoints** (optional, if `privateEndpoint: true`)
   - Function app storage: blob, file, queue, table
   - Function app: sites endpoint

### Resource Naming

The add-on automatically determines resource naming conventions by analyzing the provided hostpool name to match your existing naming standards:

- **Resource Type at Start**: `hp-avd-01` → Function app: `fa-shreplacer-abc123-avd-01-eus`
- **Resource Type at End**: `avd-01-hp` → Function app: `avd-01-fa-shreplacer-abc123-eus`

Naming includes:
- Hostpool identifier and index (e.g., "avd-01")
- Unique string from virtual machines resource group ID
- Region abbreviation
- Resource type abbreviation
- Function identifier ("shreplacer")

## Configuration

### Timer Schedule

The function runs on a timer trigger with a configurable CRON expression:

```bicep
timerSchedule: '0 0 * * * *'     // Every hour (default)
timerSchedule: '0 0 */6 * * *'   // Every 6 hours
timerSchedule: '0 0 2 * * *'     // Daily at 2:00 AM
timerSchedule: '0 */30 * * * *'  // Every 30 minutes
```

**CRON Format**: `{second} {minute} {hour} {day} {month} {day-of-week}`

### Progressive Scale-Up Feature

When `enableProgressiveScaleUp: true`, the function gradually increases deployment batch sizes based on success:

**Example Scenario:**
- Initial: 10% of needed hosts (e.g., 50 needed → deploy 5)
- After 1 success: 30% (10% + 20% increment → deploy 15)
- After 2 successes: 50% (30% + 20% increment → deploy 25)
- After 3 successes: 70% → deploy 35
- Continue until 100%

**On Failure:** Resets to initial percentage (10%)

**Max Ceiling:** `maxDeploymentBatchSize` (default: 10) prevents deploying more than this number even if percentage is higher

**Use Cases:**
- **Large Hostpools**: Safely roll out image updates to 100+ session hosts
- **Risk Mitigation**: Catch image or configuration issues early with small batches
- **Production Environments**: Gradual rollouts minimize user impact

### Session Host Tagging

The function uses three tags for lifecycle management:

**1. IncludeInAutoReplace** (default name, configurable)
- **Purpose**: Opt-in flag for automation
- **Value**: `"true"` or `"false"`
- **Set by**: Manual tagging or deployment templates
- **Example**: `"IncludeInAutoReplace": "true"`

**2. AutoReplaceDeployTimestamp** (default name, configurable)
- **Purpose**: Records when VM was deployed (ISO 8601 format)
- **Value**: `"2025-12-27T14:30:00.000Z"`
- **Set by**: Auto-created if `fixSessionHostTags: true`, or deployment templates
- **Used for**: Age calculation

**3. AutoReplacePendingDrainTimestamp** (default name, configurable)
- **Purpose**: Records when session host was drained
- **Value**: `"2025-12-27T14:30:00.000Z"`
- **Set by**: Function app when draining begins
- **Used for**: Grace period calculation

### Tag Auto-Fix Feature

When `fixSessionHostTags: true` (default), the function automatically:
- Creates missing `AutoReplaceDeployTimestamp` tags using VM creation time from Azure Resource Manager
- Fixes invalid date formats
- Applies to session hosts with `IncludeInAutoReplace: true`

When `includePreExistingSessionHosts: true` (default), session hosts without `AutoReplaceDeployTimestamp` tags are included in automation (timestamp auto-created from VM metadata).

## Monitoring and Logging

### Application Insights Integration

Enable Application Insights by providing `logAnalyticsWorkspaceResourceId`. All function executions, decisions, and errors are logged with detailed context.

### Key Metrics to Monitor

- **Function Executions**: Track execution count and duration
- **Session Hosts Evaluated**: Total session hosts checked per run
- **Session Hosts Filtered**: Count with `IncludeInAutoReplace: true`
- **Deployments Triggered**: New session hosts deployed
- **Session Hosts Drained**: VMs put in drain mode
- **Session Hosts Deleted**: VMs removed after grace period
- **Device Cleanup**: Entra/Intune device records deleted
- **Progressive Scale-Up**: Current deployment percentage and consecutive successes

### Sample Log Queries

**View all function executions:**
```kusto
traces
| where cloud_RoleName == "session-host-replacer"
| where timestamp > ago(24h)
| project timestamp, severityLevel, message
| order by timestamp desc
```

**Track deployment decisions:**
```kusto
traces
| where message contains "We will deploy" or message contains "Filtered to"
| project timestamp, message
| order by timestamp desc
```

**Monitor draining and deletions:**
```kusto
traces
| where message contains "Draining" or message contains "Deleting" or message contains "Device cleanup"
| project timestamp, message
| order by timestamp desc
```

**Progressive scale-up tracking:**
```kusto
traces
| where message contains "ConsecutiveSuccesses" or message contains "CurrentPercentage"
| project timestamp, message
| order by timestamp desc
```

**Errors and warnings:**
```kusto
traces
| where severityLevel >= 2  // Warning or Error
| where timestamp > ago(7d)
| project timestamp, severityLevel, message
| order by timestamp desc
```

### Deployment State Tracking

When progressive scale-up is enabled, the function stores deployment state in table storage:
- **ConsecutiveSuccesses**: Number of successful deployments in a row
- **CurrentPercentage**: Current deployment size percentage
- **LastStatus**: 'Success' or 'Failed'
- Resets to initial percentage on failures

## Troubleshooting

### Function Not Executing

**Symptoms**: No logs in Application Insights, no activity

**Checks**:
1. Verify function app is running: `az functionapp show --name <name> --resource-group <rg> --query state`
2. Check timer trigger: Navigate to Function App → Functions → `session-host-replacer` → Integration
3. Verify App Service Plan is not stopped
4. Check Application Insights connection string configuration

**Resolution**:
```powershell
# Restart function app
Restart-AzFunctionApp -ResourceGroupName <rg> -Name <functionAppName>

# Verify timer trigger
Get-AzFunctionAppSetting -ResourceGroupName <rg> -Name <functionAppName> | Where-Object { $_.Name -like "*Timer*" }
```

### RBAC Permission Errors

**Symptoms**: Logs show "403 Forbidden" or "Insufficient permissions"

**Checks**:
1. Verify User-Assigned Identity is attached to function app
2. Check role assignments on virtual machines subscription, hostpool resource group, and template spec resource group
3. Confirm Graph API permissions (if device cleanup enabled)

**Resolution**:
```powershell
# Get function app identity
$functionApp = Get-AzWebApp -ResourceGroupName <rg> -Name <functionAppName>
$identityResourceId = $functionApp.Identity.UserAssignedIdentities.Keys[0]
$identity = Get-AzUserAssignedIdentity -ResourceId $identityResourceId
$principalId = $identity.PrincipalId

# Verify role assignments
Get-AzRoleAssignment -ObjectId $principalId | Format-Table RoleDefinitionName, Scope

# Expected roles:
# - Virtual Machine Contributor (VMs subscription)
# - Desktop Virtualization Host Pool Contributor (hostpool RG)
# - Reader (template spec RG)

# Grant missing role (example: Virtual Machine Contributor)
$vmsSubscriptionId = "<subscription-id>"
New-AzRoleAssignment `
    -ObjectId $principalId `
    -RoleDefinitionName "Virtual Machine Contributor" `
    -Scope "/subscriptions/$vmsSubscriptionId"
```

### Graph API Permission Errors

**Symptoms**: Logs show "Insufficient privileges to complete the operation" when cleaning up devices

**Checks**:
1. Verify UAI has Graph API application permissions
2. Confirm permissions were granted by tenant admin (not just assigned)
3. Check environment variables: `GraphEndpoint`, `UserAssignedIdentityClientId`

**Resolution**:
```powershell
Connect-MgGraph -Scopes "Application.Read.All", "AppRoleAssignment.ReadWrite.All"

# Get service principal for the UAI
$identity = Get-AzUserAssignedIdentity -ResourceGroupName <rg> -Name <identityName>
$sp = Get-MgServicePrincipal -Filter "AppId eq '$($identity.ClientId)'"

# Check current permissions
Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id | Format-Table AppRoleId, ResourceDisplayName

# Grant missing permissions (see Prerequisites section for full script)
```

### Session Hosts Not Being Replaced

**Symptoms**: Function executes but no session hosts are drained or deployed

**Checks**:
1. Verify session hosts have `IncludeInAutoReplace: true` tag
2. Check session host age meets `targetVMAgeDays` threshold
3. Confirm image version check (marketplace: latest version, custom: image resource exists)
4. Look for running deployments (function skips deployment if active deployment found)
5. Review Application Insights logs for decision logic

**Resolution**:
```powershell
# Check session host tags
$vmRG = "rg-avd-session-hosts"
$vms = Get-AzVM -ResourceGroupName $vmRG
foreach ($vm in $vms) {
    $tags = (Get-AzResource -ResourceId $vm.Id).Tags
    Write-Host "$($vm.Name): IncludeInAutoReplace = $($tags['IncludeInAutoReplace']), DeployTimestamp = $($tags['AutoReplaceDeployTimestamp'])"
}

# Manually tag a VM
$vm = Get-AzVM -ResourceGroupName $vmRG -Name "avd-vm-001"
$tags = @{
    "IncludeInAutoReplace" = "true"
    "AutoReplaceDeployTimestamp" = (Get-Date).ToUniversalTime().ToString('o')
}
Update-AzTag -ResourceId $vm.Id -Tag $tags -Operation Merge
```

### Template Spec Deployment Failures

**Symptoms**: Function logs show deployment errors, new session hosts not created

**Checks**:
1. Verify Template Spec exists and version is correct
2. Check all session host parameters are valid
3. Confirm Key Vault secrets exist and function has access
4. Review deployment logs in Azure Portal (Resource Group → Deployments)
5. Validate subnet has available IPs
6. Check for resource locks

**Resolution**:
```powershell
# Verify Template Spec
Get-AzTemplateSpec -ResourceGroupName <template-spec-rg> -Name <template-spec-name> -Version <version>

# Check deployment history
Get-AzResourceGroupDeployment -ResourceGroupName <session-host-rg> | Select-Object DeploymentName, ProvisioningState, Timestamp, CorrelationId | Format-Table

# View failed deployment details
$deployment = Get-AzResourceGroupDeployment -ResourceGroupName <session-host-rg> -Name <deployment-name>
$deployment.Properties.Error
```

### Tag Auto-Fix Not Working

**Symptoms**: Session hosts without `AutoReplaceDeployTimestamp` not getting auto-fixed

**Checks**:
1. Verify `fixSessionHostTags: true` in configuration
2. Confirm session hosts have `IncludeInAutoReplace: true`
3. Check VM resource metadata is accessible
4. Review function logs for tag fixing activity

**Resolution**:
Ensure environment variables are correct:
```powershell
Get-AzFunctionAppSetting -ResourceGroupName <rg> -Name <functionAppName> | Where-Object { $_.Name -like "*Tag*" -or $_.Name -like "*Fix*" }

# Should show:
# FixSessionHostTags = true
# IncludePreExistingSessionHosts = true
# Tag_IncludeInAutomation = IncludeInAutoReplace
# Tag_DeployTimestamp = AutoReplaceDeployTimestamp
```

### Device Cleanup Failures

**Symptoms**: Session hosts deleted but Entra/Intune device records remain

**Checks**:
1. Verify `removeEntraDevice` or `removeIntuneDevice` is `true`
2. Check Graph API permissions (see Graph API Permission Errors section)
3. Confirm session hosts are Entra-joined or Hybrid-joined
4. Review function logs for Graph API errors

**Resolution**:
Manual device cleanup:
```powershell
# Connect to Microsoft Graph
Connect-MgGraph -Scopes "Device.ReadWrite.All", "DeviceManagementManagedDevices.ReadWrite.All"

# Find Entra device
$deviceName = "avd-vm-001"
$device = Get-MgDevice -Filter "displayName eq '$deviceName'"
Remove-MgDevice -DeviceId $device.Id

# Find Intune device
$intuneDevice = Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '$deviceName'"
Remove-MgDeviceManagementManagedDevice -ManagedDeviceId $intuneDevice.Id
```

### Progressive Scale-Up Not Increasing

**Symptoms**: Deployment percentage stays at initial value despite successful deployments

**Checks**:
1. Verify `enableProgressiveScaleUp: true`
2. Check `successfulRunsBeforeScaleUp` threshold (default: 1)
3. Review consecutive successes counter in function logs
4. Confirm deployments are actually succeeding (check Azure deployments)

**Resolution**:
```powershell
# Check function app settings
Get-AzFunctionAppSetting -ResourceGroupName <rg> -Name <functionAppName> | Where-Object { $_.Name -like "*Progress*" -or $_.Name -like "*ScaleUp*" }

# Should show:
# EnableProgressiveScaleUp = true
# InitialDeploymentPercentage = 10
# ScaleUpIncrementPercentage = 20
# MaxDeploymentBatchSize = 10
# SuccessfulRunsBeforeScaleUp = 1

# View deployment state in table storage (requires storage access)
# State is stored in the function app storage account in table: "DeploymentState"
```

### Private Endpoint Connectivity Issues

**Symptoms**: Function cannot reach Azure APIs, timeout errors

**Checks**:
1. Verify VNet integration is configured on function app
2. Check private DNS zones are linked to VNets
3. Confirm NSG rules allow outbound to Azure services
4. Validate private endpoint DNS resolution
5. Check route tables

**Resolution**:
```powershell
# Test DNS resolution from function app (using Kudu console)
# Navigate to: https://<function-app-name>.scm.azurewebsites.net/DebugConsole
# Run: nslookup management.azure.com
# Should resolve to private IP if using private endpoints

# Verify VNet integration
$functionApp = Get-AzWebApp -ResourceGroupName <rg> -Name <functionAppName>
$functionApp.VirtualNetworkSubnetId

# Check private endpoints
Get-AzPrivateEndpoint -ResourceGroupName <rg> | Where-Object { $_.Name -like "*shreplacer*" }
```

## Security and Best Practices

### Security Considerations

1. **User-Assigned Managed Identity with Pre-Granted Permissions**
   - Graph API permissions pre-configured eliminates post-deployment setup
   - Supports Multi-Factor Authentication and Conditional Access policies
   - No credential storage or rotation required

2. **Least Privilege RBAC**
   - Virtual Machine Contributor scoped to VMs subscription only
   - Desktop Virtualization Host Pool Contributor scoped to hostpool resource group
   - Reader scoped to template spec resource group
   - No subscription-level Owner or Contributor roles

3. **Customer-Managed Encryption Keys**
   - Optional CMK support for function app storage
   - Keys stored in Azure Key Vault with automatic rotation
   - Supports HSM-backed keys for compliance

4. **Zero Trust Networking**
   - Private endpoints isolate function app and storage from public internet
   - VNet integration for outbound connectivity
   - Private DNS integration ensures proper resolution
   - NSG and route table support

5. **Secure Credential Management**
   - Session host credentials stored in Azure Key Vault
   - Function retrieves secrets at deployment time only
   - No credentials in logs or Application Insights

6. **Tag-Based Opt-In Model**
   - Only explicitly tagged session hosts are managed
   - Prevents accidental deletion of VMs
   - Manual control over automation scope

7. **Gradual Rollouts with Progressive Scale-Up**
   - Limits blast radius of configuration issues
   - Automatic rollback on failures (resets to initial percentage)
   - Configurable max batch size ceiling

### Best Practices

#### Deployment
- **Use Existing App Service Plan**: Share with other functions to reduce costs (~$75/month savings)
- **Enable Application Insights**: Essential for monitoring and troubleshooting
- **Start with Conservative Settings**:
  - `targetVMAgeDays: 60` (longer grace period for new deployments)
  - `drainGracePeriodHours: 48` (allows more time for user sessions to gracefully close)
  - `enableProgressiveScaleUp: true` (gradual rollout for large hostpools)
  - `initialDeploymentPercentage: 5` (very small initial batch)
- **Tag New Session Hosts Automatically**: Include tags in your deployment templates
- **Test in Non-Production**: Deploy to dev/test hostpool first

#### Tagging Strategy
```powershell
# Include tags in session host deployment template
$tags = @{
    "IncludeInAutoReplace" = "true"
    "AutoReplaceDeployTimestamp" = (Get-Date).ToUniversalTime().ToString('o')
    "Environment" = "Production"
    "Owner" = "AVD-Team"
}
```

#### Monitoring
- Set up Azure Monitor alerts for function failures
- Monitor deployment success rate
- Track average session host age to validate lifecycle policy
- Alert on Graph API authentication failures (if device cleanup enabled)

#### Operational
- Review Application Insights logs weekly for trends
- Adjust `targetVMAgeDays` based on your patch/update cadence
- Coordinate timer schedule with maintenance windows if needed
- Document custom tag names if using non-default values

#### Image Management
- **Marketplace Images**: Function automatically detects latest version
- **Custom Images**: Update image resource ID parameter when new version is ready
- **Shared Image Gallery**: Use versioned image references for rollback capability
- **Testing**: Validate new images in dev environment before production

#### Progressive Scale-Up Strategy
For large hostpools (50+ session hosts):
```bicep
enableProgressiveScaleUp: true
initialDeploymentPercentage: 5    // Start with 5% (2-3 VMs if 50 total)
scaleUpIncrementPercentage: 10    // Increase by 10% each success
maxDeploymentBatchSize: 10        // Never deploy more than 10 at once
successfulRunsBeforeScaleUp: 2    // Require 2 consecutive successes before scaling up
```

## Cost Considerations

### Monthly Cost Estimates (US East)

| Component | Configuration | Estimated Cost |
|-----------|---------------|----------------|
| **App Service Plan** | Premium V3 P1v3 (new, 1 instance) | ~$210/month |
| **App Service Plan** | Shared with existing functions | ~$0/month (shared cost) |
| **Function App Storage** | Standard_LRS, minimal usage | ~$2/month |
| **Application Insights** | 5GB ingestion, 90-day retention | ~$10/month |
| **Private Endpoints** | 5 endpoints (if enabled) | ~$20/month |
| **Total (New Plan)** | - | ~$242/month |
| **Total (Shared Plan)** | - | ~$32/month |

### Cost Optimization Tips

1. **Share App Service Plan**: Use existing Premium V3 plan to eliminate ~$210/month cost
2. **Optimize Timer Schedule**: Hourly execution is usually sufficient; reduce to every 6-12 hours for lower costs
3. **Reduce Application Insights Retention**: Lower to 30 days if long-term history not needed
4. **Skip Private Endpoints**: If compliance allows, save ~$20/month by using service endpoints instead
5. **Disable Device Cleanup**: If not needed, reduces Graph API call volume (minimal cost impact)
6. **Zone Redundancy**: Only enable if required for SLA; adds ~$420/month (3 instances vs 1)

## Limitations

- **Single Hostpool Per Function**: Each deployment manages one hostpool; deploy multiple instances for multiple hostpools
- **Template Spec Dependency**: New session hosts must use Template Spec deployment model
- **Network Connectivity**: Function app requires connectivity to Azure Resource Manager, Azure Storage, and Microsoft Graph (if device cleanup enabled)
- **Same Azure Environment**: Template Spec and resources must be in same Azure cloud (Commercial/Government/China/DoD)
- **Entra/Hybrid Join Required**: Device cleanup only works for Entra-joined or Hybrid-joined session hosts
- **PowerShell Runtime**: Function is PowerShell-based; cannot use other runtimes
- **Timer Trigger Only**: Event-driven triggers not supported
- **Max Deployment Batch Size**: Hard limit of 50 hosts per run (configurable parameter)
- **No Manual Approval**: Fully automated; use tag-based opt-in for control
- **Image Version Detection**: Marketplace images use latest available; custom images require parameter update

## Frequently Asked Questions

### Can I exclude specific session hosts from replacement?
Yes, set the `IncludeInAutoReplace` tag to `false` or remove the tag entirely. Only session hosts with `IncludeInAutoReplace: true` are managed.

### What happens if a user is logged in when grace period expires?
The function checks for active sessions before deletion. If sessions remain after grace period, deletion is skipped until all sessions are logged off.

### Can I use this with session hosts in multiple resource groups?
No, each function instance manages session hosts in one resource group. Deploy multiple function instances for multiple resource groups.

### How do I update the session host image?
- **Marketplace images**: Function automatically detects the latest version; no action needed
- **Custom images**: Update the `customImageResourceId` parameter (or imagePublisher/Offer/SKU) and redeploy the function app

### Does this work with Azure Virtual Desktop Classic?
No, this add-on is designed for Azure Virtual Desktop (ARM-based) only, not AVD Classic.

### Can I customize the drain notification message to users?
Currently, user notifications are not implemented in the base function. You can extend the `run.ps1` script to add custom notification logic using PowerShell.

### What happens if Template Spec deployment fails?
The function logs the error to Application Insights and continues monitoring. Progressive scale-up (if enabled) resets to initial percentage. Existing session hosts remain operational.

### Can I run this on-premises or in other clouds?
No, the function requires Azure Function App infrastructure and Azure-specific APIs (ARM, Graph). It supports Azure Commercial, Government, and China clouds.

### How do I roll back to an older image version?
Update the session host parameters (imagePublisher/Offer/SKU or customImageResourceId) to reference the older image version and redeploy the function app configuration. Existing session hosts won't automatically roll back; you'll need to manually trigger replacement by adjusting `targetVMAgeDays` or deleting young session hosts.

### Does this work with FSLogix Cloud Cache?
Yes, all FSLogix configurations are supported including Cloud Cache. Configure FSLogix parameters in the session host configuration section.

### Can I pause automation temporarily?
Yes, either:
1. Stop the function app: `Stop-AzFunctionApp -ResourceGroupName <rg> -Name <functionAppName>`
2. Set all session host tags `IncludeInAutoReplace: false`
3. Delete the timer trigger

## Related Documentation

- [Azure Virtual Desktop Documentation](https://learn.microsoft.com/azure/virtual-desktop/)
- [Azure Functions PowerShell Developer Guide](https://learn.microsoft.com/azure/azure-functions/functions-reference-powershell)
- [Azure Template Specs](https://learn.microsoft.com/azure/azure-resource-manager/templates/template-specs)
- [Azure Managed Identities](https://learn.microsoft.com/azure/active-directory/managed-identities-azure-resources/overview)
- [Microsoft Graph API](https://learn.microsoft.com/graph/overview)
- [AVD Session Host Management](https://learn.microsoft.com/azure/virtual-desktop/manage-session-hosts)

## Support

For issues, questions, or feature requests:
1. Review this documentation thoroughly
2. Check Application Insights logs for detailed error messages
3. Consult the [Troubleshooting](#troubleshooting) section
4. Create an issue in the [FederalAVD GitHub repository](https://github.com/Azure/FederalAVD/issues) with:
   - Detailed description of the problem
   - Relevant logs from Application Insights (redact sensitive information)
   - Deployment parameters (redact secrets and IDs)
   - Steps to reproduce
   - Azure cloud environment (Commercial/Government/DoD/China)

## Change Log

### Version 1.0
- Initial release
- PowerShell 7.4 function app
- Age-based and image version-based replacement logic
- Tag-based opt-in model with auto-fix feature
- Graceful draining with configurable grace period
- Progressive scale-up feature for gradual rollouts
- Entra ID and Intune device cleanup
- Template Spec integration (auto-create or use existing)
- User-assigned managed identity with pre-granted Graph API permissions
- Application Insights integration
- Private endpoint support
- Customer-managed encryption key support
- Zero Trust networking support
- Comprehensive RBAC automation
