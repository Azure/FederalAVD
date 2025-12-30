# AVD Session Host Replacer

Automated Azure Function for managing Azure Virtual Desktop session host lifecycle through continuous image updates and age-based replacement.

## Table of Contents
- [Overview](#overview)
- [Features](#features)
- [Prerequisites](#prerequisites)
- [Deployment](#deployment)
- [Configuration](#configuration)
- [Permissions Setup](#permissions-setup)
- [How It Works](#how-it-works)
- [Troubleshooting](#troubleshooting)
- [Maintenance](#maintenance)

## Overview

The Session Host Replacer monitors AVD session hosts and automatically replaces them based on age and image version. It handles the complete lifecycle: detection → draining → deployment → deletion → device cleanup.

**Key Benefits:**

- Zero-touch image updates
- Compliance with age-based policies
- Graceful user session handling
- Optional device cleanup (Entra ID + Intune)
- Multi-cloud support (Commercial, GCC High, DoD, China; US Secret/Top Secret via auto-detection)

## Features

### Core Capabilities

- **Automated Age-Based Replacement**: Replaces hosts exceeding configured age (default: 45 days)
- **Image Version Tracking**: Detects outdated images and triggers updates
- **Graceful Draining**: Configurable grace period for active sessions (default: 24 hours)
- **Progressive Scale-Up**: Gradually increase batch size after successful deployments
- **Tag-Based Opt-In**: Only affects hosts tagged with `IncludeInAutoReplace: true`
- **Device Cleanup**: Removes Entra ID and Intune device records automatically

### Enterprise Features

- **Zero Trust Networking**: Private endpoints and VNet integration
- **Customer-Managed Encryption**: CMK support for function storage
- **Multi-Cloud**: Commercial, GCC High, DoD environments
- **Comprehensive Monitoring**: Application Insights integration
- **Template Spec Integration**: Consistent deployments with versioning

## Prerequisites

### Azure Resources Required

1. **Azure Function App** (PowerShell 7.4)
   - **New Deployment**: Creates Premium Windows plan (P1v3) with zone redundancy option
   - **Existing Plan**: Must be one of the following:
     - **Premium v3 Windows Plans**: P0v3, P1v3, P2v3, P3v3 (P0v3 recommended for cost savings)
     - **Elastic Premium Plans**: EP1, EP2, EP3
     - **Premium v2 Plans**: P1v2, P2v2, P3v2
   - ❌ **Not Compatible**: Consumption plans, Linux plans, or Standard/Basic tiers
   - **Required Features**:
     - Always On (enabled by deployment)
     - VNet Integration support (if using private endpoints)
     - PowerShell 7.4 runtime
   - 💡 **Cost Tip**: P0v3 is the most cost-effective option and fully supports all required features

2. **User-Assigned Managed Identity** with permissions:
   - **Azure RBAC:** (Automatically granted during deployment)
     - `Desktop Virtualization Contributor` on Host Pool
     - `Contributor` on Session Host Resource Group
     - `Reader` on Image Gallery/Marketplace
   - **Microsoft Graph API:** (Must be done via script)
     - `Directory.ReadWrite.All` - For Entra ID device deletion
     - `DeviceManagementManagedDevices.ReadWrite.All` - For Intune device deletion

3. **Template Spec**
4. **Application Insights** (recommended for monitoring)
5. **Storage Account** (Function App requirement)

### Software

1. PowerShell 7.2+
2. Microsoft Graph Module

## Deployment

### 1. Create Template Spec (Optional but Recommended)

A template spec is a resource type for storing an Azure Resource Manager template (ARM template) in Azure for later deployment. Template specs enable you to share ARM templates with other users in your organization through Azure RBAC controls.

**Benefits of using template specs:**

- Standard ARM/Bicep templates without external dependencies
- Azure RBAC for access control (no SAS tokens required)
- Users can deploy without write access to the template source
- Integrates with existing deployment processes (PowerShell, Azure Portal, DevOps)
- **Custom portal forms** for guided deployment experience

For more information, see [Template Specs | Microsoft Learn](https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/template-specs?tabs=azure-powershell) and [Portal Forms for Template Specs](https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/template-specs-create-portal-forms).

**To create the Session Host Replacer template spec:**

1. Connect to the correct Azure environment where `<Environment>` equals 'AzureCloud', 'AzureUSGovernment', or the air-gapped equivalent:

   ```powershell
   Connect-AzAccount -Environment <Environment>
   ```

2. Ensure your context is set to the subscription where you want to store the template spec:

   ```powershell
   Set-AzContext -Subscription <subscriptionID>
   ```

3. Navigate to the deployments folder and execute the script with the add-ons flag:

   ```powershell
   cd deployments
   .\New-TemplateSpecs.ps1 -ResourceGroupName <resource-group-name> -Location <location> -CreateAddOns $true
   ```

   Example:

   ```powershell
   .\New-TemplateSpecs.ps1 -ResourceGroupName "rg-avd-management-use2" -Location "eastus2" -CreateAddOns $true
   ```

This creates a template spec named **sessionHostReplacer** with a custom UI form in the specified resource group.

### 2. Deploy Infrastructure

You can deploy the Session Host Replacer using either the Azure Portal with the custom UI form (recommended) or PowerShell.

#### Option 1: Deploy via Azure Portal (Recommended)

The custom UI form provides a guided experience with tooltips and validation:

1. Navigate to **Template Specs** in the Azure Portal
2. Select the **sessionHostReplacer** template spec
3. Click **Deploy**
4. Fill out the form with your configuration:
   - **Basics**: Resource group, location, naming prefix
   - **Host Pool Configuration**: Host pool resource ID, target session host count
   - **Replacement Mode**: Choose Age-based or ImageVersion
   - **Identity & Permissions**: User-assigned managed identity
   - **Monitoring**: Application Insights, Log Analytics workspace
   - **Networking**: VNet integration, private endpoints (optional)
5. Review and click **Create**

The form automatically validates inputs and provides helpful descriptions for each parameter.

#### Option 2: Deploy via PowerShell

```powershell
# Set parameters
$params = @{
    resourceGroupName = "rg-avd-management-use2"
    location = "eastus2"
    hostPoolResourceId = "/subscriptions/.../resourceGroups/.../providers/Microsoft.DesktopVirtualization/hostpools/hp-prod"
    userAssignedIdentityResourceId = "/subscriptions/.../resourceGroups/.../providers/Microsoft.ManagedIdentity/userAssignedIdentities/mi-sessionhostreplacer"
    # ... other parameters
}

# Deploy using Template Spec
New-AzResourceGroupDeployment -ResourceGroupName $params.resourceGroupName `
    -TemplateSpecId "/subscriptions/.../resourceGroups/.../providers/Microsoft.Resources/templateSpecs/sessionHostReplacer/versions/1.0" `
    -TemplateParameterObject $params

# OR deploy directly from bicep file
New-AzResourceGroupDeployment -ResourceGroupName $params.resourceGroupName `
    -TemplateFile ".\deployments\add-ons\SessionHostReplacer\main.bicep" `
    -TemplateParameterObject $params
```

### 3. Grant Graph API Permissions

Run the included permission script:

```powershell
cd deployments/add-ons/SessionHostReplacer

# For Commercial Azure
.\Set-GraphPermissions.ps1 -ManagedIdentityObjectId <object-id>

# For GCC High
.\Set-GraphPermissions.ps1 -ManagedIdentityObjectId <object-id> -Environment USGov

# For DoD
.\Set-GraphPermissions.ps1 -ManagedIdentityObjectId <object-id> -Environment USGovDoD
```

> **Note:** For US Secret and Top Secret clouds, you must update the graph endpoint placeholders in the script from the reference links provided.

**Important:** After granting permissions:

1. Wait 5-10 minutes for Azure AD propagation
2. Stop the Function App completely
3. Wait 2-3 minutes
4. Start the Function App
5. Verify permissions appear in token (check logs)

### 4. Configure Function App Settings

Required settings (automatically configured during deployment):

```json
{
    "HostPoolName": "hp-prod-001",
    "HostPoolResourceGroupName": "rg-avd-hostpool",
    "HostPoolSubscriptionId": "...",
    "VirtualMachinesResourceGroupName": "rg-avd-sessionhosts",
    "VirtualMachinesSubscriptionId": "...",
    "TargetVMAgeDays": "45",
    "SessionHostDrainGraceMinutes": "1440",
    "UserAssignedIdentityClientId": "...",
    "ResourceManagerUri": "https://management.azure.com/",
    "GraphEndpoint": "https://graph.microsoft.com",
    "RemoveEntraDevice": "true",
    "RemoveIntuneDevice": "true"
}
```

### 5. Tag Session Hosts

Session hosts must be tagged to opt-in:

```powershell
$vmName = "avdvm-001"
$resourceGroup = "rg-avd-sessionhosts"

Update-AzTag -ResourceId "/subscriptions/.../resourceGroups/$resourceGroup/providers/Microsoft.Compute/virtualMachines/$vmName" `
    -Operation Merge `
    -Tag @{
        "IncludeInAutoReplace" = "true"
        "AutoReplaceDeployTimestamp" = (Get-Date).ToString("o")
    }
```

## Permissions Setup

### Understanding Permission Requirements

**For Graph API calls by service principals/managed identities:**

- ✅ **Application Permissions** (App Roles) - Required in token's `roles` claim
- ❌ **Directory Roles** - Do NOT work for API calls by service principals

**Required Permissions:**

1. **Directory.ReadWrite.All** (19dbc75e-c2e2-444c-a770-ec69d8559fc7)
   - Purpose: Delete devices from Entra ID
   - Note: `Device.ReadWrite.All` does NOT allow deletion despite the name

2. **DeviceManagementManagedDevices.ReadWrite.All** (243333ab-4d21-40cb-a475-36241daa0842)
   - Purpose: Delete devices from Intune

### Manual Permission Grant (if script fails)

```powershell
# Connect with required scopes
Connect-MgGraph -Scopes "Application.Read.All","AppRoleAssignment.ReadWrite.All"

# Get managed identity and Graph service principals
$mi = Get-MgServicePrincipal -ServicePrincipalId <managed-identity-object-id>
$graph = Get-MgServicePrincipal -Filter "displayName eq 'Microsoft Graph'"

# Grant Directory.ReadWrite.All
$roleId = "19dbc75e-c2e2-444c-a770-ec69d8559fc7"
New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $mi.Id `
    -PrincipalId $mi.Id -ResourceId $graph.Id -AppRoleId $roleId

# Grant DeviceManagementManagedDevices.ReadWrite.All
$roleId = "243333ab-4d21-40cb-a475-36241daa0842"
New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $mi.Id `
    -PrincipalId $mi.Id -ResourceId $graph.Id -AppRoleId $roleId
```

### Verify Permissions

```powershell
# Check permissions in Azure AD
$mi = Get-MgServicePrincipal -ServicePrincipalId <object-id>
$assignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $mi.Id
$graph = Get-MgServicePrincipal -Filter "displayName eq 'Microsoft Graph'"

$assignments | Where-Object { $_.ResourceId -eq $graph.Id } | ForEach-Object {
    $role = $graph.AppRoles | Where-Object { $_.Id -eq $_.AppRoleId }
    [PSCustomObject]@{
        Permission = $role.Value
        GrantedAt = $_.CreatedDateTime
    }
}
```

## How It Works

### Workflow

```
┌─────────────────────────────────────────────────────────────────┐
│  Timer Trigger (Hourly) → Analyze Hosts → Make Decisions        │
└─────────────────────────────────────────────────────────────────┘
                                    │
                    ┌───────────────┴───────────────┐
                    │                               │
            ┌───────▼─────────┐            ┌────────▼────────┐
            │  Drain Hosts    │            │  Deploy New     │
            │  (Set Drain     │            │  (Template      │
            │   Mode Tag)     │            │   Spec)         │
            └───────┬─────────┘            └────────┬────────┘
                    │                               │
            ┌───────▼─────────┐                     │
            │  Wait Grace     │                     │
            │  Period (24h)   │◄────────────────────┘
            └───────┬─────────┘
                    │
            ┌───────▼─────────┐
            │  Delete Hosts   │
            │  + VMs + Device │
            │    Objects      │
            └─────────────────┘
```

### Replacement Modes

The Session Host Replacer operates in one of two mutually exclusive modes, controlled by the `replacementMode` parameter:

**Age-Based Replacement** (`replacementMode = 'Age-based'`):

- Replaces session hosts that exceed the configured age threshold (`targetVMAgeDays`)
- Does NOT check for image version updates
- Use this mode for time-based compliance requirements (e.g., "replace all hosts older than 45 days")
- Predictable replacement schedule based purely on host age

**Image-Version-Based Replacement** (`replacementMode = 'ImageVersion'`):

- Replaces session hosts when their image version differs from the latest available version
- Does NOT check host age - only image version matters
- Use this mode to ensure all hosts run the latest OS/application patches
- Replacement happens whenever a new image is published, regardless of host age
- **Ringed Roll-out Support**: Use `replaceSessionHostOnNewImageVersionDelayDays` to delay replacement after a new image is detected (0-30 days). This emulates a staged deployment strategy similar to Windows Update rings, allowing you to validate a new image in production before rolling it out fleet-wide

> **Important:** The function operates in ONE mode at a time. It does not replace hosts based on BOTH age AND image version simultaneously. Choose the mode that aligns with your operational requirements.

### Detailed Steps

1. **Discovery**: Enumerate session hosts via ARM API
2. **Tag Validation**: Filter to hosts with `IncludeInAutoReplace: true`
3. **Replacement Check** (mode-dependent):
   - **Age-Based Mode** (`replacementMode = 'Age-based'`): Compare `AutoReplaceDeployTimestamp` to `targetVMAgeDays`
   - **Image-Version Mode** (`replacementMode = 'ImageVersion'`): Compare current image to latest marketplace/gallery version
4. **Drain Decision**: Mark for draining if replacement criteria met
5. **Deployment**: Deploy new hosts using Template Spec (respects batch size)
6. **Grace Period**: Track with `AutoReplacePendingDrainTimestamp` tag
7. **Deletion**: Remove after grace period + zero sessions
8. **Device Cleanup**: Delete from Entra ID and Intune
9. **State Tracking**: Save deployment state to Table Storage for progressive scale-up

### Tag Schema

Session hosts use these tags for automation:

| Tag | Purpose | Example Value |
|-----|---------|---------------|
| `IncludeInAutoReplace` | Opt-in to automation | `true` |
| `AutoReplaceDeployTimestamp` | Birth timestamp for age calculation | `2024-12-01T10:00:00Z` |
| `AutoReplacePendingDrainTimestamp` | When draining started | `2024-12-15T14:30:00Z` |
| `ScalingPlanExclusion` | Exclude from scaling (set during drain) | `true` |

## Configuration

### Key Settings

| Setting | Default | Description |
|---------|---------|-------------|
| `TargetVMAgeDays` | `45` | Maximum age before replacement |
| `SessionHostDrainGraceMinutes` | `1440` (24h) | Wait time before deletion |
| `AutoHealUntaggedVMs` | `true` | Auto-tag hosts missing tags |
| `RemoveEntraDevice` | `true` | Clean up Entra ID devices |
| `RemoveIntuneDevice` | `true` | Clean up Intune devices |
| `ReplaceSessionHostsOnNewImageVersion` | `true` | Trigger on image updates |
| `EnableProgressiveScaleUp` | `false` | Gradually increase batch size |
| `ProgressiveScaleUpInitialPercent` | `10` | Starting batch size (%) |
| `ProgressiveScaleUpMaxPercent` | `100` | Maximum batch size (%) |
| `ProgressiveScaleUpStepPercent` | `10` | Increment per success |
| `ProgressiveScaleUpSuccessesRequired` | `2` | Successes before increment |

### Environment-Specific Settings

**Commercial Azure (Global):**
```json
{
    "ResourceManagerUri": "https://management.azure.com/",
    "GraphEndpoint": "https://graph.microsoft.com",
    "StorageSuffix": "core.windows.net"
}
```

**GCC High (USGov):**
```json
{
    "ResourceManagerUri": "https://management.usgovcloudapi.net/",
    "GraphEndpoint": "https://graph.microsoft.us",
    "StorageSuffix": "core.usgovcloudapi.net"
}
```

**DoD (USGovDoD):**
```json
{
    "ResourceManagerUri": "https://management.usgovcloudapi.net/",
    "GraphEndpoint": "https://dod-graph.microsoft.us",
    "StorageSuffix": "core.usgovcloudapi.net"
}
```

> **Note:** Azure US Secret and US Top Secret clouds are supported via automatic environment detection during bicep deployment. The Graph endpoint is dynamically constructed as `https://graph.${environment().suffixes.storage}` and automatically configured in the Function App settings.

## Troubleshooting

### Common Issues

#### 1. Graph API 401 "Invalid Audience" Error

**Symptoms:**
- Logs show: "Access token validation failure. Invalid audience."
- Device deletion fails with 401

**Cause:** Token's audience claim doesn't match Graph endpoint

**Resolution:**
```powershell
# Verify token audience in Application Insights
traces
| where message contains "Token audience"
| order by timestamp desc
| take 10

# If wrong audience:
1. Verify GraphEndpoint setting matches environment
2. Restart Function App to clear token cache
3. Wait 5 minutes for new token acquisition
```

#### 2. Graph API 401 "Insufficient Privileges"

**Symptoms:**
- Logs show: "Insufficient privileges to complete the operation"
- Devices can be read but not deleted

**Cause:** Missing Directory.ReadWrite.All permission in token

**Resolution:**
```powershell
# Check if permission is granted
.\VERIFY-GRAPH-PERMISSIONS.ps1 -ManagedIdentityObjectId <object-id>

# If granted but not in token:
1. Wait 10-60 minutes for Azure AD propagation
2. Stop Function App completely
3. Wait 2-3 minutes
4. Start Function App
5. Check logs for token roles - should include Directory.ReadWrite.All
```

#### 3. Session Hosts Not Being Replaced

**Symptoms:**
- Function runs but doesn't drain/replace hosts
- No hosts in "pending delete" list

**Common Causes:**

**A. Missing/Invalid Tags:**
```powershell
# Check tags
$vm = Get-AzVM -ResourceGroupName "rg-sessionhosts" -Name "avdvm-001"
$vm.Tags

# Required: IncludeInAutoReplace: "true" (case-sensitive)
# Required: AutoReplaceDeployTimestamp: ISO8601 timestamp

# Fix if AutoHealUntaggedVMs=false
Update-AzTag -ResourceId $vm.Id -Operation Merge -Tag @{
    "IncludeInAutoReplace" = "true"
    "AutoReplaceDeployTimestamp" = (Get-Date).ToString("o")
}
```

**B. Age Not Exceeded:**
Check `TargetVMAgeDays` setting and host age in logs

**C. Image Version Not Detected:**
Verify `ReplaceSessionHostsOnNewImageVersion` is enabled

#### 4. Deployment Fails

**Common Issues:**
- Template Spec not found/accessible
- Insufficient RBAC permissions
- Quota limits exceeded
- No available subnet IPs

```powershell
# Check deployment errors
exceptions
| where outerMessage contains "deployment"
| order by timestamp desc

# Verify Template Spec exists
Get-AzTemplateSpec -ResourceGroupName "rg-management" -Name "sessionhost-template"

# Check managed identity RBAC
$mi = Get-AzUserAssignedIdentity -ResourceGroupName "rg-management" -Name "mi-sessionhostreplacer"
Get-AzRoleAssignment -ObjectId $mi.PrincipalId
```

#### 5. Device Not Deleted from Entra ID/Intune

**Resolution:**
```powershell
# Verify settings
$app = Get-AzFunctionApp -ResourceGroupName "rg-management" -Name "func-sessionhostreplacer"
$app.ApplicationSettings["RemoveEntraDevice"]  # Should be "true"
$app.ApplicationSettings["RemoveIntuneDevice"]  # Should be "true"

# Check Graph API calls in logs
traces
| where message contains "Removing session host" or message contains "Entra" or message contains "Intune"
| order by timestamp desc

# Verify Graph permissions
.\VERIFY-GRAPH-PERMISSIONS.ps1 -ManagedIdentityObjectId <object-id>
```

### Debug Logging

Enable verbose logging in Application Insights:

```kusto
// All function execution
traces
| where customDimensions.Category == "Function.session-host-replacer"
| order by timestamp desc

// Graph API calls
traces
| where message contains "Graph" or message contains "device"
| order by timestamp desc

// Deployment activity
traces
| where message contains "deploy" or message contains "Template Spec"
| order by timestamp desc

// Errors only
traces
| where severityLevel >= 3
| order by timestamp desc
```

## Maintenance

### Updating the Function

**Option 1: Portal (Quick Updates)**
1. Navigate to Function App → App Service Editor
2. Edit `Modules/SessionHostReplacer/SessionHostReplacer.psm1`
3. Save changes
4. Restart Function App

**Option 2: PowerShell Deployment**
```powershell
$sourcePath = ".\deployments\add-ons\SessionHostReplacer\functions"
$zipPath = ".\SessionHostReplacer.zip"

Compress-Archive -Path "$sourcePath\*" -DestinationPath $zipPath -Force

Publish-AzWebApp -ResourceGroupName "rg-management" `
    -Name "func-sessionhostreplacer" `
    -ArchivePath $zipPath -Force

Restart-AzFunctionApp -ResourceGroupName "rg-management" `
    -Name "func-sessionhostreplacer" -Force
```

**Option 3: Azure CLI**
```bash
cd deployments/add-ons/SessionHostReplacer
zip -r SessionHostReplacer.zip functions/*

az functionapp deployment source config-zip \
  --resource-group rg-management \
  --name func-sessionhostreplacer \
  --src SessionHostReplacer.zip

az functionapp restart \
  --resource-group rg-management \
  --name func-sessionhostreplacer
```

### Monitoring Best Practices

1. **Set up Alerts:**
   ```kusto
   // Alert on repeated failures
   traces
   | where customDimensions.Category == "Function.session-host-replacer"
   | where severityLevel >= 3
   | summarize ErrorCount=count() by bin(timestamp, 1h)
   | where ErrorCount > 5
   ```

2. **Weekly Health Check:**
   - Review successful replacement count
   - Check average age of fleet
   - Verify no stuck deployments
   - Confirm device cleanup working

3. **Monthly Review:**
   - Assess batch size (progressive scale-up)
   - Review grace period effectiveness
   - Check for orphaned devices
   - Validate Template Spec currency

## Additional Resources

- [Azure Functions PowerShell Documentation](https://learn.microsoft.com/en-us/azure/azure-functions/functions-reference-powershell)
- [Azure Virtual Desktop Documentation](https://learn.microsoft.com/en-us/azure/virtual-desktop/)
- [Microsoft Graph Permissions Reference](https://learn.microsoft.com/en-us/graph/permissions-reference)
- [Managed Identity Best Practices](https://learn.microsoft.com/en-us/azure/active-directory/managed-identities-azure-resources/managed-identity-best-practice-recommendations)

## License

See repository root LICENSE file.
