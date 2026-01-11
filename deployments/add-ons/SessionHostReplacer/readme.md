# AVD Session Host Replacer

> **Part of the [Federal AVD Solution](../../../README.md)** | See also: [Features Overview](../../../docs/features.md) | [Quick Start Guide](../../../docs/quickStart.md)

Automated Azure Function for managing Azure Virtual Desktop session host lifecycle through continuous image updates with flexible replacement strategies.

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Replacement Modes](#replacement-modes)
- [Prerequisites](#prerequisites)
- [Deployment](#deployment)
- [Configuration](#configuration)
- [Permissions Setup](#permissions-setup)
- [How It Works](#how-it-works)
- [Process Flows](#process-flows)
- [Troubleshooting](#troubleshooting)
- [Maintenance](#maintenance)

## Overview

The Session Host Replacer monitors AVD session hosts and automatically replaces them when new images are available. It handles the complete lifecycle: detection → draining → deployment → deletion → device cleanup.

**Key Benefits:**

- **Flexible Replacement Strategies**: Choose between SideBySide (zero-downtime) or DeleteFirst (cost-optimized) modes
- **Zero-downtime rolling updates** with automatic capacity management (SideBySide mode)
- **Cost-optimized replacements** with controlled capacity reduction (DeleteFirst mode)
- **Zero-touch image updates** with automatic version tracking
- **Graceful user session handling** with configurable grace periods
- **Progressive scale-up** for gradual, validated rollouts
- **Shutdown retention** for rollback capability (SideBySide mode)
- **Auto-detect target count** for dynamic scaling plan compatibility
- **Device cleanup** (Entra ID + Intune) with automatic hostname reuse
- **Multi-cloud support** (Commercial, GCC High, DoD, China; US Secret/Top Secret via auto-detection)

## Features

### Core Capabilities

- **Image Version Tracking**: Detects outdated images and triggers updates
- **Flexible Replacement Strategies**: Choose between SideBySide and DeleteFirst modes
- **Graceful Draining**: Configurable grace period for active sessions (default: 24 hours)
- **Minimum Drain Time**: Safety buffer for zero-session hosts before deletion (default: 15 minutes)
- **Progressive Scale-Up**: Gradual rollouts starting with small percentages and scaling up after success
- **Shutdown Retention**: Rollback capability by retaining old hosts in shutdown state (SideBySide mode)
- **Auto-Detect Target Count**: Maintains current host count, compatible with dynamic scaling plans
- **Tag-Based Opt-In**: Only affects hosts tagged with `IncludeInAutoReplace: true`
- **Device Cleanup**: Removes Entra ID and Intune device records automatically
- **Failed Deployment Recovery**: Automatic cleanup of partial resources and retry logic

### Enterprise Features

- **Zero Trust Networking**: Private endpoints and VNet integration
- **Customer-Managed Encryption**: CMK support for function storage
- **Multi-Cloud**: Commercial, GCC, GCC High, DoD, US Government Secret, and US Government Top Secret environments
- **Comprehensive Monitoring**: Application Insights integration with pre-built dashboard
- **Template Spec Integration**: Consistent deployments with versioning
- **Real-Time Visibility**: Azure Monitor Workbook dashboard for deployment tracking and host pool health
- **Dedicated Host Support**: Preserves and reuses dedicated host assignments (DeleteFirst mode)

## Replacement Modes

The Session Host Replacer supports two distinct replacement strategies to accommodate different operational priorities:

### SideBySide Mode (Default)

**Best for**: Zero-downtime requirements, production environments, large host pools

**How it works**:
- Deploys new session hosts **before** deleting old ones
- Host pool temporarily doubles in size during replacement cycles
- New hosts are added, users naturally migrate, then old hosts are removed
- No capacity reduction at any point

**Characteristics**:
- ✅ **Zero downtime** - users always have available capacity
- ✅ **Maximum safety** - new hosts validated before old ones removed
- ✅ **Shutdown retention option** - keep old hosts powered off for rollback
- ✅ **Auto-detect target count** - compatible with scaling plans
- ✅ **Progressive scale-up** - gradual rollouts with validation
- ❌ **Higher temporary cost** - pays for both old and new hosts during transition
- ❌ **Requires capacity headroom** - subnet, quotas, dedicated hosts must support 2x size

**Configuration parameters**:
- `replacementMode`: `SideBySide`
- `targetSessionHostCount`: 0 (auto-detect) or specific number
- `maxDeploymentBatchSize`: Maximum deployments per run (default: 100)
- `minimumHostIndex`: Starting host number (default: 1)
- `enableShutdownRetention`: Keep old hosts shutdown for rollback (default: false)
- `shutdownRetentionDays`: Days to retain shutdown hosts (default: 3)

**Use cases**:
- Production environments with strict SLA requirements
- Large host pools where cost of temporary doubling is acceptable
- Environments requiring rollback capability
- Organizations with sufficient subnet IP space and Azure quotas

### DeleteFirst Mode

**Best for**: Cost optimization, resource-constrained environments, smaller host pools

**How it works**:
- Deletes idle old session hosts **first**, then deploys replacements
- Maintains minimum capacity percentage during replacements
- Reuses hostnames and dedicated host assignments from deleted hosts
- Gradual replacement controlled by max deletions per cycle

**Characteristics**:
- ✅ **Cost optimized** - no host pool doubling, pays only for needed capacity
- ✅ **Resource efficient** - lower IP address and quota consumption
- ✅ **Hostname reuse** - leverages deleted names for new hosts
- ✅ **Dedicated host preservation** - maintains host group assignments
- ❌ **Temporary capacity reduction** - some hosts unavailable during replacement
- ❌ **Requires device cleanup** - Graph API permissions mandatory for name reuse
- ❌ **Slower rollouts** - limited by max deletions per cycle

**Configuration parameters**:
- `replacementMode`: `DeleteFirst`
- `targetSessionHostCount`: Specific number (auto-detect not supported)
- `maxDeletionsPerCycle`: Maximum hosts to replace per run (default: 5)
- `minimumCapacityPercentage`: Safety floor for available capacity (default: 80%)
- `removeEntraDevice`: Must be `true` for hostname reuse
- `removeIntuneDevice`: Must be `true` for hostname reuse

**Use cases**:
- Dev/test environments with relaxed availability requirements
- Cost-sensitive deployments where temporary doubling is prohibitive
- Resource-constrained environments (limited IPs, quotas, or dedicated hosts)
- Smaller host pools where temporary capacity reduction is acceptable
- Environments using dedicated hosts where reuse is required

### Mode Comparison Matrix

| Feature | SideBySide | DeleteFirst |
|---------|------------|-------------|
| **Downtime** | None | Temporary capacity reduction |
| **Cost during replacement** | 2x (temporary) | 1x (no doubling) |
| **Hostname reuse** | No (generates new names) | Yes (reuses deleted names) |
| **Dedicated host support** | No (new hosts on different hosts) | Yes (preserves assignments) |
| **Shutdown retention** | Yes (optional) | No |
| **Auto-detect target count** | Yes | No (explicit count required) |
| **Device cleanup required** | Optional | Mandatory (for hostname reuse) |
| **Progressive scale-up** | Yes | Yes |
| **Subnet IP requirements** | 2x during replacement | 1x (no spike) |
| **Rollback capability** | Yes (with shutdown retention) | No |
| **Deployment velocity** | Fast (batch size up to 1000) | Controlled (max deletions per cycle) |
| **Minimum drain time** | Yes | Yes |
| **Best for** | Production, zero-downtime | Cost optimization, resource constraints |

### Choosing the Right Mode

**Choose SideBySide if**:
- Zero downtime is a hard requirement
- You have sufficient subnet IP space and Azure quotas
- Cost of temporary doubling is acceptable
- You want rollback capability via shutdown retention
- You're using dynamic scaling plans (auto-detect target count)

**Choose DeleteFirst if**:
- Cost optimization is the priority
- Subnet IP space or quotas are constrained
- You're using dedicated hosts and need to preserve assignments
- Temporary capacity reduction is acceptable
- You can enable Graph API permissions for device cleanup

## Prerequisites

### Azure Resources Required

1. **Azure Function App** (PowerShell 7.4)
   - **New Deployment**: Creates Premium Windows plan (P0v3) with zone redundancy option
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
     - `Device.ReadWrite.All` - For Entra ID device deletion
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
   - **Image Version Settings**: Optional delay before replacement after new image detection
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
    "TargetSessionHostCount": "0",
    "MaxDeploymentBatchSize": "10",
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
- ❌ **Directory Roles** - Do NOT work for API calls by service principals (e.g., Cloud Device Administrator is NOT needed)

**Required Permissions:**

1. **Device.ReadWrite.All** (1138cb37-bd11-4084-a2b7-9f71582aeddb)
   - Purpose: Delete devices from Entra ID
   - Note: This permission IS sufficient for device deletion when used by service principals

2. **DeviceManagementManagedDevices.ReadWrite.All** (243333ab-4d21-40cb-a475-36241daa0842)
   - Purpose: Delete devices from Intune

### Manual Permission Grant (if script fails)

```powershell
# Connect with required scopes
Connect-MgGraph -Scopes "Application.Read.All","AppRoleAssignment.ReadWrite.All"

# Get managed identity and Graph service principals
$mi = Get-MgServicePrincipal -ServicePrincipalId <managed-identity-object-id>
$graph = Get-MgServicePrincipal -Filter "displayName eq 'Microsoft Graph'"

# Grant Device.ReadWrite.All
$roleId = "1138cb37-bd11-4084-a2b7-9f71582aeddb"
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

### Replacement Triggers

The Session Host Replacer operates in **Image-Version-Based Replacement** mode:

- Replaces session hosts when their image version differs from the latest available version
- Use this to ensure all hosts run the latest OS/application patches
- Replacement happens whenever a new image is published (subject to optional delay)
- **Ringed Roll-out Support**: Use `replaceSessionHostOnNewImageVersionDelayDays` to delay replacement after a new image is detected (0-30 days). This emulates a staged deployment strategy similar to Windows Update rings, allowing you to validate a new image in production before rolling it out fleet-wide
- **Rollback Protection**: By default, the function will not replace hosts if their current image version is newer than the latest available version. Set `allowImageVersionRollback` to true to override this behavior

### Target Session Host Count

The `targetSessionHostCount` parameter defines your desired host pool size with two modes:

#### Explicit Count Mode
Set to a specific number (e.g., 100) to maintain that exact count throughout replacement cycles:
- Function always tries to maintain this specific number
- Does not adapt to manual scaling changes
- Best for static host pools with predictable capacity needs

#### Auto-Detect Mode (Recommended)
Set to `0` to automatically maintain the current count when replacement cycles begin:
- Function captures initial count when first outdated host is detected
- This count is maintained throughout the entire replacement cycle
- After all hosts are replaced, the next cycle captures the new current count
- **Perfect for dynamic scaling plans**: Function adapts to whatever count your scaling plan has set
- **Manual scaling compatible**: Make temporary adjustments between image updates

**Example scenario with auto-detect**:
1. Scaling plan maintains 50 hosts during normal operations
2. New image version is detected
3. Function captures "50" as target for this replacement cycle
4. Function replaces all 50 hosts while maintaining that count
5. After replacement completes, scaling plan increases to 75 hosts
6. Next image update will use "75" as the target

**Important**: Auto-detect mode is only supported in **SideBySide mode**. DeleteFirst mode requires an explicit target count.

### Tag Schema

Session hosts use these tags for automation:

| Tag | Purpose | Example Value | When Set |
|-----|---------|---------------|----------|
| `IncludeInAutoReplace` | Opt-in to automation | `true` | At deployment or manually |
| `AutoReplaceDeployTimestamp` | Birth timestamp for tracking | `2024-12-01T10:00:00Z` | At deployment |
| `AutoReplacePendingDrainTimestamp` | When draining started | `2024-12-15T14:30:00Z` | When placed in drain mode |
| `AutoReplaceShutdownTimestamp` | When host was shutdown (SideBySide with retention) | `2024-12-20T16:00:00Z` | When shutdown for retention |
| `ScalingPlanExclusion` | Exclude from scaling | `SessionHostReplacer` | Set at deployment, during drain mode, and shutdown retention. Removed when cycle completes (or when new hosts are active in SideBySide+retention mode) |

## Process Flows

### SideBySide Mode Workflow

```
┌────────────────────────────────────────────────────────────────┐
│  Timer Trigger (Configurable) → Analyze → Make Decisions       │
└────────────────────────────────────────────────────────────────┘
                           │
         ┌─────────────────┴──────────────────┐
         │                                    │
    ┌────▼────────┐                   ┌───────▼───────┐
    │  Drain Old  │                   │ Deploy New    │
    │  Hosts      │                   │ Hosts First   │
    │  (Set Tag)  │                   │ (Parallel)    │
    └────┬────────┘                   └───────┬───────┘
         │                                    │
         │        ┌───────────────────────────┘
         │        │
    ┌────▼────────▼────────┐
    │  Wait for Grace      │
    │  Period & Drain      │
    │  (24h default)       │
    └────┬─────────────────┘
         │
    ┌────▼─────────────────┐
    │  Shutdown or Delete  │
    │  + Device Cleanup    │
    │  (Based on Setting)  │
    └──────────────────────┘

```

**Detailed Steps**:

1. **Discovery**: Enumerate all session hosts via AVD Host Pool API
2. **Tag Validation**: Filter to hosts with `IncludeInAutoReplace: true`
3. **Target Count Determination**: Use explicit count or auto-detect current count at cycle start
4. **Image Version Check**: Compare each host's image to latest marketplace/gallery version
5. **Capacity Planning**: Calculate automatic buffer (equals target count) for zero-downtime updates
6. **Progressive Scale-Up** (if enabled): Calculate batch size based on consecutive successes
7. **Deployment Submission**: Deploy new hosts using Template Spec (up to MaxDeploymentBatchSize)
8. **Drain Decision**: Mark old hosts for draining if:
   - New hosts are successfully deployed and registered
   - Image version differs from latest
   - Minimum drain time not yet met (if zero sessions)
9. **Grace Period Tracking**: Monitor via `AutoReplacePendingDrainTimestamp` tag
10. **Deletion or Shutdown**: After grace period + zero sessions:
    - **Without shutdown retention**: Delete VM, disks, NIC, session host registration
    - **With shutdown retention**: Shutdown (deallocate) VM and set `AutoReplaceShutdownTimestamp` tag
11. **Device Cleanup** (if enabled): Remove from Entra ID and Intune
12. **Expired Shutdown Cleanup**: Automatically delete VMs that have been shutdown beyond retention period
13. **State Tracking**: Save deployment state to Table Storage for progressive scale-up and auto-detect mode

### DeleteFirst Mode Workflow

```
┌────────────────────────────────────────────────────────────────┐
│  Timer Trigger (Configurable) → Analyze → Make Decisions       │
└────────────────────────────────────────────────────────────────┘
                           │
         ┌─────────────────┴──────────────────┐
         │                                    │
    ┌────▼────────────┐              ┌────────▼──────────┐
    │  Drain Old      │              │  Capacity Check   │
    │  Hosts          │              │  (Respect Min %)  │
    │  (Set Tag)      │              └────────┬──────────┘
    └────┬────────────┘                       │
         │                                    │
    ┌────▼────────────────────────────────────▼─────┐
    │  Wait for Grace Period & Zero Sessions        │
    │  (24h for active, 15min for zero sessions)    │
    └────┬──────────────────────────────────────────┘
         │
    ┌────▼─────────────────────┐
    │  Delete Session Hosts    │
    │  + VM + Disks + NIC      │
    │  + Device Cleanup        │
    │  (Capture hostname &     │
    │   dedicated host info)   │
    └────┬─────────────────────┘
         │
    ┌────▼─────────────────────┐
    │  Wait for Azure          │
    │  Resource Cleanup        │
    │  (Poll until deleted)    │
    └────┬─────────────────────┘
         │
    ┌────▼─────────────────────┐
    │  Deploy Replacements     │
    │  (Reuse deleted names    │
    │   and dedicated hosts)   │
    └──────────────────────────┘

```

**Detailed Steps**:

1. **Discovery**: Enumerate all session hosts via AVD Host Pool API
2. **Tag Validation**: Filter to hosts with `IncludeInAutoReplace: true`
3. **Target Count Validation**: Verify explicit target count is set (auto-detect not supported)
4. **Image Version Check**: Compare each host's image to latest marketplace/gallery version
5. **Capacity Calculation**: Determine max deletions respecting:
   - `maxDeletionsPerCycle`: Upper limit per run
   - `minimumCapacityPercentage`: Safety floor (e.g., 80% of target must remain available)
6. **Drain Decision**: Mark old hosts for draining
7. **Grace Period Tracking**: Monitor via `AutoReplacePendingDrainTimestamp` tag
8. **Pre-Deletion Capture**: Before deletion, save:
   - Hostname (for reuse in new deployment)
   - Dedicated host ID (if assigned)
   - Dedicated host group ID (if assigned)
   - Availability zones (if assigned)
9. **Critical Deletion**: Delete session host + VM + disks + NIC + Entra/Intune devices
   - **Failure handling**: If any deletion fails, halt deployment to prevent hostname conflicts
   - **Success tracking**: Only reuse names from successfully deleted hosts
10. **Azure Resource Verification**: Poll Azure APIs to confirm VMs are fully deleted (up to 5 minutes)
11. **Deployment Submission**: Deploy replacement hosts:
    - Reuse deleted hostnames (prevents name exhaustion)
    - Reuse dedicated host assignments (prevents stranding hosts)
    - Progressive scale-up (if enabled)
12. **Failed Deployment Recovery**: If deployment fails after successful deletions:
    - Pending hostnames saved to Table Storage
    - Next run attempts redeployment with saved names
    - Prevents lost capacity from deletion without replacement
13. **State Tracking**: Save deployment state including pending host mappings for recovery

### Key Differences Between Modes

| Aspect | SideBySide | DeleteFirst |
|--------|------------|-------------|
| **Order of operations** | Deploy → Drain → Delete | Drain → Delete → Wait → Deploy |
| **Hostname handling** | Generate new sequential names | Reuse deleted hostnames |
| **Capacity during replacement** | 2x (old + new simultaneously) | <1x (deletions before deployments) |
| **Dedicated host preservation** | No (new hosts on different hosts) | Yes (captures and reuses assignments) |
| **Failure recovery** | Non-critical (names not reused) | Critical (saves pending names for retry) |
| **Deployment dependencies** | Independent operations | Deployment depends on successful deletion |
| **Resource verification** | Not required | Polls Azure until VMs fully deleted |

### Progressive Scale-Up Mechanics

When `enableProgressiveScaleUp` is enabled, deployments start small and gradually increase:

**Configuration**:
- `initialDeploymentPercentage`: Starting batch size (e.g., 20%)
- `scaleUpIncrementPercentage`: Amount to increase after successes (e.g., 40%)
- `successfulRunsBeforeScaleUp`: Consecutive successes needed to scale up (default: 1)

**Behavior**:
- **New cycle starts**: Reset to initial percentage (e.g., 20%)
- **Cycle detected by**: Image version change OR completion of previous cycle (0 hosts to replace, 0 deploying, 0 draining)
- **After successful deployment**: Increment consecutive success counter
- **Scale up trigger**: After N consecutive successes, increase percentage by increment
- **Maximum**: Scale up to 100%
- **After failure**: Reset to initial percentage and clear success counter

**Example** (100 hosts to replace, 20% initial, 50% increment, 1 success required):
1. **Run 1**: Deploy 20 hosts (20% of 100) → Success
2. **Run 2**: Deploy 70 hosts (70% = 20% + 50%) → Success
3. **Run 3**: Deploy 100 hosts (100% = capped at max, would be 120%) → Remaining 10 deployed
4. **Run 4**: No more hosts to deploy, cycle complete

**SideBySide mode constraint**: `maxDeploymentBatchSize` acts as ceiling. If percentage calculation exceeds this, uses batch size instead.

**DeleteFirst mode constraint**: `maxDeletionsPerCycle` limits both deletions and subsequent deployments.

**State persistence**: Deployment state (percentage, consecutive successes, pending hosts) saved to Table Storage.

## Configuration

### Replacement Mode Parameters

| Setting | Default | Applies To | Description |
|---------|---------|------------|-------------|
| `replacementMode` | `SideBySide` | All | Replacement strategy: `SideBySide` (zero-downtime) or `DeleteFirst` (cost-optimized) |
| `targetSessionHostCount` | `0` | All | Target host pool size. Set to 0 for auto-detect mode (SideBySide only) or specific number for explicit count |
| `drainGracePeriodHours` | `24` | All | Grace period in hours for session hosts **with active sessions** before forced deletion (1-168 hours) |
| `minimumDrainMinutes` | `15` | All | Minimum drain time in minutes for session hosts **with zero sessions** before eligible for deletion (0-120 minutes). Acts as safety buffer for API lag and race conditions |

### SideBySide Mode Parameters

| Setting | Default | Description |
|---------|---------|-------------|
| `maxDeploymentBatchSize` | `100` | Maximum deployments per function run (1-1000). Limits concurrent ARM deployments regardless of progressive scale-up percentage |
| `minimumHostIndex` | `1` | Starting host number for hostname generation (1-999). Useful for starting numbering at specific value (e.g., 10) |
| `enableShutdownRetention` | `false` | Shutdown (deallocate) old hosts instead of deleting them, enabling rollback to previous image |
| `shutdownRetentionDays` | `3` | Days to retain shutdown hosts before automatic deletion (1-7). Provides rollback window |

### DeleteFirst Mode Parameters

| Setting | Default | Description |
|---------|---------|-------------|
| `maxDeletionsPerCycle` | `5` | Maximum hosts to delete and deploy per cycle (1-50). Controls replacement pace - function deletes this many, then deploys same count |
| `minimumCapacityPercentage` | `80` | Safety floor: minimum percentage of target capacity to maintain (50-100%). Deletions capped to prevent dropping below threshold. Higher = more conservative, lower = more aggressive |

### Progressive Scale-Up Parameters

| Setting | Default | Description |
|---------|---------|-------------|
| `enableProgressiveScaleUp` | `false` | Enable percentage-based gradual deployment scale-up. Starts small and increases after consecutive successes |
| `initialDeploymentPercentage` | `20` | Starting batch size as percentage of total needed hosts (1-100%). Used when progressive scale-up is enabled |
| `scaleUpIncrementPercentage` | `40` | Percentage increase added after successful deployment runs (5-50%). Progressive increments until reaching 100% |
| `successfulRunsBeforeScaleUp` | `1` | Consecutive successful runs required before increasing percentage (1-5). More successes = more conservative |

### Image Version & Rollout Parameters

| Setting | Default | Description |
|---------|---------|-------------|
| `replaceSessionHostOnNewImageVersionDelayDays` | `0` | Days to wait after new image detection before starting replacements (0-30). Enables ringed rollouts for image validation |
| `allowImageVersionRollback` | `false` | Allow replacement even if current version is newer than latest available. Prevents accidental downgrades by default |

### Tagging & Automation Parameters

| Setting | Default | Description |
|---------|---------|-------------|
| `fixSessionHostTags` | `true` | Automatically add missing tags to session hosts during execution (IncludeInAutoReplace, AutoReplaceDeployTimestamp) |
| `includePreExistingSessionHosts` | `true` | Include session hosts that existed before automation deployment. If false, only new hosts are managed |
| `tagIncludeInAutomation` | `IncludeInAutoReplace` | Tag name identifying hosts included in automation. Must be set to `true` to enable automation |
| `tagDeployTimestamp` | `AutoReplaceDeployTimestamp` | Tag name for deployment timestamp (ISO 8601 format) |
| `tagPendingDrainTimestamp` | `AutoReplacePendingDrainTimestamp` | Tag name for drain start timestamp |
| `tagShutdownTimestamp` | `AutoReplaceShutdownTimestamp` | Tag name for shutdown timestamp (SideBySide with retention) |
| `tagScalingPlanExclusionTag` | `ScalingPlanExclusion` | Tag name for excluding hosts from scaling plans. Applied to newly deployed hosts, hosts in drain, and shutdown retention VMs. Removed when cycle completes (or when new capacity is active in SideBySide+retention) |

### Device Cleanup Parameters

| Setting | Default | Description |
|---------|---------|-------------|
| `removeEntraDevice` | `true` | Remove Entra ID device records when deleting session hosts. **Required for DeleteFirst mode** (hostname reuse) |
| `removeIntuneDevice` | `true` | Remove Intune device records when deleting session hosts. **Required for DeleteFirst mode** (hostname reuse) |

### Scheduling Parameters

| Setting | Default | Description |
|---------|---------|-------------|
| `timerSchedule` | `0 0,30 * * * *` | NCrontab format: `{second} {minute} {hour} {day} {month} {day-of-week}`. Default runs every 30 minutes at :00 and :30. Stagger across deployments by varying minutes |

**Timer Schedule Examples**:
- `0 0,30 * * * *` - Every 30 minutes (at :00 and :30 past each hour)
- `0 15,45 * * * *` - Every 30 minutes starting at :15 (runs at :15 and :45)
- `0 0 * * * *` - Every hour on the hour
- `0 0 */2 * * *` - Every 2 hours
- `0 0 8-17 * * 1-5` - Every hour from 8 AM to 5 PM, Monday through Friday
- `0 0,30 8-17 * * 1-5` - Every 30 minutes from 8 AM to 5 PM, Monday through Friday

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

### Configuration Examples

#### Example 1: SideBySide with Zero-Downtime (Production)

```bicep
replacementMode: 'SideBySide'
targetSessionHostCount: 0  // Auto-detect for scaling plan compatibility
drainGracePeriodHours: 24  // 24-hour grace period for active sessions
minimumDrainMinutes: 30    // 30-minute safety buffer for zero-session hosts
maxDeploymentBatchSize: 100  // Deploy up to 100 hosts concurrently
enableProgressiveScaleUp: true
initialDeploymentPercentage: 10  // Start with 10% of needed hosts
scaleUpIncrementPercentage: 20   // Increase by 20% after successes
enableShutdownRetention: true    // Enable rollback capability
shutdownRetentionDays: 3         // Keep old hosts for 3 days
```

#### Example 2: DeleteFirst for Cost Optimization (Dev/Test)

```bicep
replacementMode: 'DeleteFirst'
targetSessionHostCount: 20  // Explicit count required
drainGracePeriodHours: 4    // Shorter grace period for dev
minimumDrainMinutes: 5      // Minimal safety buffer
maxDeletionsPerCycle: 5     // Replace 5 hosts per cycle
minimumCapacityPercentage: 70  // More aggressive (allow up to 30% reduction)
removeEntraDevice: true     // Required for hostname reuse
removeIntuneDevice: true    // Required for hostname reuse
```

#### Example 3: Gradual Ringed Rollout (Large Production)

```bicep
replacementMode: 'SideBySide'
targetSessionHostCount: 500
replaceSessionHostOnNewImageVersionDelayDays: 7  // Wait 7 days to validate new image
enableProgressiveScaleUp: true
initialDeploymentPercentage: 5   // Very conservative start (5% = 25 hosts)
scaleUpIncrementPercentage: 10   // Gradual increases
successfulRunsBeforeScaleUp: 2   // Require 2 consecutive successes
maxDeploymentBatchSize: 50       // Limit concurrent deployments
```

#### Example 4: Fast Rollout (Small Pool, Trusted Images)

```bicep
replacementMode: 'SideBySide'
targetSessionHostCount: 10
drainGracePeriodHours: 6   // Shorter grace period
minimumDrainMinutes: 0     // No safety buffer (delete immediately when zero sessions)
enableProgressiveScaleUp: false  // Deploy all at once
maxDeploymentBatchSize: 10       // Deploy all 10 simultaneously
replaceSessionHostOnNewImageVersionDelayDays: 0  // Immediate replacement
```

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

**Cause:** Missing Device.ReadWrite.All permission in token

**Resolution:**

```powershell
# Check if permission is granted
.\Set-GraphPermissions.ps1 -ManagedIdentityObjectId <object-id>

# If granted but not in token:
1. Wait 10-60 minutes for Azure AD propagation
2. Stop Function App completely
3. Wait 2-3 minutes
4. Start Function App
5. Check logs for token roles - should include Device.ReadWrite.All
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

# Fix if fixSessionHostTags=false
Update-AzTag -ResourceId $vm.Id -Operation Merge -Tag @{
    "IncludeInAutoReplace" = "true"
    "AutoReplaceDeployTimestamp" = (Get-Date).ToString("o")
}
```

**B. Image Version Not Detected:**

Verify image version detection is working:

```kusto
traces
| where message contains "IMAGE_INFO"
| order by timestamp desc
| take 1
```

Check that latest version differs from current host versions.

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
.\Set-GraphPermissions.ps1 -ManagedIdentityObjectId <object-id>
```

#### 6. DeleteFirst Mode: Deployment Conflicts

**Symptoms:**

- Deployments fail with "resource already exists" errors
- Function logs show deletion success but deployment fails

**Cause:** Azure resource cleanup not complete before reusing names

**Resolution:**

The function automatically polls for deletion completion (up to 5 minutes). If this happens:

1. Check if deletion verification completed:
```kusto
traces
| where message contains "VM" and message contains "deletion confirmed"
| order by timestamp desc
```

2. If verification timed out, manually verify VM deletion:
```powershell
Get-AzVM -ResourceGroupName "rg-sessionhosts" -Name "vm-oldhost-001"
# Should return 'ResourceNotFound' error
```

3. If VM still exists, deletion may have failed. Check deployment state:
```kusto
traces
| where message contains "CRITICAL ERROR" or message contains "deletion failures"
| order by timestamp desc
```

#### 7. Progressive Scale-Up Not Increasing

**Symptoms:**

- Deployments stay at initial percentage
- Consecutive successes not incrementing

**Causes & Solutions:**

**A. Previous deployment still running:**

```kusto
traces
| where message contains "Previous deployment is still running"
| order by timestamp desc
```

Wait for previous deployment to complete before next scale-up.

**B. Failed deployment between runs:**

```kusto
traces
| where message contains "Previous deployment failed"
| order by timestamp desc
```

Progressive scale-up resets on failure. Next successful deployment will restart from initial percentage.

**C. New cycle started:**

```kusto
traces
| where message contains "Detected new update cycle"
| order by timestamp desc
```

Scale-up resets when new image version detected or previous cycle completes.

#### 8. Auto-Detect Target Count Not Working

**Symptoms:**

- Target count shows as 0 or wrong number
- Logs show unexpected target count

**Causes & Solutions:**

**A. Using DeleteFirst mode:**

Auto-detect is only supported in SideBySide mode. Set explicit `targetSessionHostCount`.

**B. Cycle not started yet:**

Auto-detect captures count when first outdated host is detected:

```kusto
traces
| where message contains "New cycle detection" or message contains "Starting new update cycle"
| order by timestamp desc
```

If no outdated hosts exist, auto-detect hasn't captured a count yet.

**C. Check current stored target:**

```kusto
traces
| where message contains "SETTINGS"
| order by timestamp desc
| take 1
```

Look for `TargetSessionHostCount` value. If "Auto", count will be captured at next cycle start.

#### 9. Shutdown Retention VMs Not Being Deleted

**Symptoms:**

- Old VMs remain in shutdown state beyond retention period
- Logs show shutdown VMs but no cleanup

**Resolution:**

Check for expired shutdown VMs:

```kusto
traces
| where message contains "Shutdown retention is enabled"
| where message contains "expired shutdown VM"
| order by timestamp desc
```

Verify `enableShutdownRetention` is true and `shutdownRetentionDays` is configured:

```powershell
$app = Get-AzFunctionApp -ResourceGroupName "rg-management" -Name "func-sessionhostreplacer"
$app.ApplicationSettings["EnableShutdownRetention"]   # Should be "true"
$app.ApplicationSettings["ShutdownRetentionDays"]     # Should be 1-7
```

#### 10. Minimum Drain Time Not Respected

**Symptoms:**

- Hosts with zero sessions deleted immediately
- Expected safety buffer not applied

**Cause:** `minimumDrainMinutes` set to 0 or drain timestamp not set properly

**Resolution:**

```kusto
traces
| where message contains "MinimumDrainMinutes"
| order by timestamp desc
| take 1
```

Check configuration:
```powershell
$app = Get-AzFunctionApp -ResourceGroupName "rg-management" -Name "func-sessionhostreplacer"
$app.ApplicationSettings["MinimumDrainMinutes"]  # Recommended: 15-30
```

Verify hosts have drain timestamp tag:
```powershell
$vm = Get-AzVM -ResourceGroupName "rg-sessionhosts" -Name "vm-001"
$vm.Tags["AutoReplacePendingDrainTimestamp"]  # Should be ISO 8601 timestamp
```

#### 11. Capacity Drops Too Low in DeleteFirst Mode

**Symptoms:**

- Too many hosts deleted at once
- Host pool capacity drops significantly

**Cause:** `minimumCapacityPercentage` set too low or `maxDeletionsPerCycle` too high

**Resolution:**

Adjust safety parameters:

```bicep
minimumCapacityPercentage: 80  // Increase to be more conservative (prevents dropping below 80%)
maxDeletionsPerCycle: 3         // Decrease for slower, safer replacements
```

Verify current settings:

```kusto
traces
| where message contains "SETTINGS"
| where message contains "MinimumCapacityPercent"
| order by timestamp desc
| take 1
```

#### 12. Failed Deployment Artifacts Not Cleaned Up

**Symptoms:**

- Orphaned VMs without session host registration
- VMs with names not following convention
- Failed deployments remain in resource group

**Resolution:**

Check for failed deployment cleanup:

```kusto
traces
| where message contains "failed deployments for cleanup" or message contains "orphaned VMs"
| order by timestamp desc
```

The function automatically cleans up failed deployments. If cleanup fails:

1. Manually identify orphaned VMs:
```powershell
# Get all VMs in resource group
$vms = Get-AzVM -ResourceGroupName "rg-sessionhosts"

# Get registered session hosts
$hostPool = Get-AzWvdHostPool -ResourceGroupName "rg-hostpool" -Name "hp-prod"
$sessionHosts = Get-AzWvdSessionHost -HostPoolName $hostPool.Name -ResourceGroupName "rg-hostpool"

# Find VMs not registered as session hosts
$orphanedVMs = $vms | Where-Object { 
    $vmName = $_.Name
    -not ($sessionHosts | Where-Object { $_.Name -like "*$vmName*" })
}
```

2. Manually clean up orphaned resources
3. Check pending host mappings in deployment state (DeleteFirst mode only)

### Monitoring Best Practices

1. **Set up Alerts:**

   ```kusto
   // Alert on repeated failures
   traces
   | where customDimensions.Category == "Function.session-host-replacer"
   | where severityLevel >= 3
   | summarize ErrorCount=count() by bin(timestamp, 1h)
   | where ErrorCount > 5
   
   // Alert on DeleteFirst mode deletion failures (critical)
   traces  
   | where message contains "CRITICAL ERROR" and message contains "deletion failures"
   | where timestamp > ago(1h)
   
   // Alert on progressive scale-up failures
   traces
   | where message contains "Reset consecutive successes" and severityLevel >= 2
   | where timestamp > ago(1h)
   ```

2. **Daily Health Check Queries:**

   ```kusto
   // Current state summary
   traces
   | where customDimensions.Category == "Function.session-host-replacer"
   | where message contains "METRICS"
   | order by timestamp desc
   | take 1
   | project timestamp, message
   
   // Recent deployment activity
   traces
   | where message contains "Deployment submitted"
   | where timestamp > ago(7d)
   | summarize Deployments=count(), HostsDeployed=sum(toint(extract(@"(\d+) VMs requested", 1, message))) by bin(timestamp, 1d)
   
   // Replacement cycle progress
   traces
   | where message contains "SETTINGS" or message contains "METRICS"
   | where timestamp > ago(1d)
   | order by timestamp desc
   | project timestamp, ReplacementMode=extract(@"ReplacementMode: (\w+)", 1, message),
             ToReplace=extract(@"ToReplace: (\d+)", 1, message),
             InDrain=extract(@"InDrain: (\d+)", 1, message),
             RunningDeployments=extract(@"RunningDeployments: (\d+)", 1, message)
   ```

3. **Weekly Health Check:**
   - Review successful replacement count via workbook dashboard
   - Check average age of fleet
   - Verify no stuck deployments (running > 2 hours)
   - Confirm device cleanup working (no orphaned Entra/Intune devices)
   - Validate progressive scale-up trajectory (if enabled)
   - Check shutdown retention cleanup (SideBySide mode)

4. **Monthly Review:**
   - Assess replacement mode effectiveness (cost vs. downtime)
   - Review batch size and progressive scale-up settings
   - Evaluate grace period effectiveness (too long/short?)
   - Check for orphaned devices in Entra ID/Intune
   - Validate Template Spec currency
   - Review capacity planning (subnet IPs, quotas, dedicated hosts)

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

// Drain and deletion activity
traces
| where message contains "drain" or message contains "delete" or message contains "shutdown"
| order by timestamp desc

// Progressive scale-up tracking
traces
| where message contains "consecutive successes" or message contains "CurrentPercentage"
| order by timestamp desc

// Mode-specific queries
// DeleteFirst: Hostname reuse tracking
traces
| where message contains "Captured dedicated host properties" or message contains "Reuse deleted names"
| order by timestamp desc

// SideBySide: Shutdown retention tracking  
traces
| where message contains "shutdown retention" or message contains "expired shutdown"
| order by timestamp desc

// Errors only
traces
| where severityLevel >= 3
| order by timestamp desc
```

### Monitoring Dashboard

The Session Host Replacer includes a pre-built Azure Monitor Workbook that provides real-time visibility into automation status and host pool health.

**Access the Dashboard:**

1. Navigate to Azure Portal → **Monitor** → **Workbooks**
2. Select **AVD Session Host Replacer Dashboard**
3. Or navigate directly from the Function App → **Monitoring** → **Workbooks**
4. **Select Host Pool**: Use the dropdown to filter by a specific host pool or view all

**Dashboard Features:**

- **📊 Key Performance Indicators**
  - Total session hosts
  - Hosts pending replacement
  - Hosts in drain mode
  - Hosts pending deletion
  - Hosts in shutdown retention (SideBySide mode)

- **🎯 Host Pool Consistency**
  - Hosts by image version
  - Hosts by age distribution
  - Replacement status breakdown
  - Replacement mode indicator

- **🔄 Deployment Progress**
  - Deployment activity timeline
  - Progressive scale-up status (current percentage, consecutive successes)
  - Success/failure tracking
  - Running vs. completed deployments

- **⏱️ Session Drain Status**
  - Hosts currently draining
  - Grace period countdowns
  - Active session counts
  - Minimum drain time compliance

- **🗑️ Deletion Activity**
  - Host deletion operations
  - Device cleanup (Entra ID + Intune)
  - Shutdown retention tracking (deallocated VMs awaiting rollback or expiration)
  - Expired shutdown VM cleanup (automatic after retention period)
  - Scaling plan exclusion management (protects retention VMs, allows scaling of new hosts)

- **⚙️ Configuration Summary**
  - Current replacement mode
  - Target host count (explicit or auto-detect)
  - Grace period and minimum drain settings
  - Progressive scale-up configuration
  - Batch size limits

- **⚠️ Errors and Warnings**
  - Recent errors with timestamps
  - Error trends over time
  - Failed deployment tracking
  - Critical alerts (DeleteFirst deletion failures)

- **📈 Historical Trends**
  - Function execution frequency
  - Average host pool size over time
  - Replacement cycle duration
  - Deployment success rate
  - Image version adoption timeline

**Customization:**

The workbook is fully customizable. You can:

- **Switch between host pools**: Dynamic dropdown populated from your environment
- Adjust time ranges (1 hour to 30 days)
- Add custom queries
- Modify visualizations
- Export data for reporting
- Filter by replacement mode

> **Multi-Tenant Support**: If you manage multiple host pools with separate Session Host Replacer deployments logging to the same Application Insights workspace, use the **Host Pool** parameter to filter the dashboard to a specific host pool or view aggregate data across all pools.

### Enterprise Workbook Architecture

The Session Host Replacer uses a **centralized workbook** pattern for enterprise-wide visibility:

- **Single Workbook** deploys to a central location (defaults to first deployment region)
- **Cross-Region Queries**: The workbook queries all regional Application Insights instances in your subscription
- **Multi-Region Filtering**: Use the **Application Insights** parameter to select which regions to view
- **Host Pool Filtering**: Use the **Host Pool** parameter to filter to specific pools or view all

**Deployment Behavior:**

- **First Deployment**: Creates the workbook in the specified `workbookLocation` (defaults to deployment region)
- **Subsequent Deployments**: Reuse the existing workbook (idempotent deployment)
- The workbook automatically discovers all Session Host Replacer Application Insights instances

**Location Note:** The workbook's physical location doesn't affect its cross-region query capabilities (similar to AVD Insights). You can optionally specify a preferred `workbookLocation` parameter if you want to control where it's deployed.

This pattern:

- **Single Pane of Glass**: One dashboard for all regions and host pools
- **Flexible Filtering**: View one region, multiple regions, or all regions
- **Idempotent**: No conflicts when deploying to multiple regions
- **Cost Efficient**: One workbook vs N (per region)

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
