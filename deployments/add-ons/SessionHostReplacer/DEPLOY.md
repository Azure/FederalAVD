# Deploying Session Host Replacer Updates

> **Note:** For comprehensive deployment instructions, prerequisites, permissions setup, and troubleshooting, see [README.md](README.md).

This document provides quick reference for deploying updates to an existing Session Host Replacer function and guidance for choosing deployment options.

## Choosing Your Replacement Mode

Before deploying, understand the two replacement strategies:

### SideBySide Mode (Recommended for Most)
- **Zero downtime** - new hosts added before old ones removed
- **Higher temporary cost** - host pool temporarily doubles
- **Shutdown retention option** - keep old hosts for rollback
- **Best for**: Production environments, large pools, SLA requirements

### DeleteFirst Mode (For Resource-Constrained Environments)
- **Cost optimized** - no host pool doubling
- **Temporary capacity reduction** - some hosts unavailable during replacement
- **Hostname reuse** - requires device cleanup (Graph API permissions mandatory)
- **Best for**: Dev/test, cost-sensitive, IP/quota constrained, dedicated host environments

See [README.md - Replacement Modes](README.md#replacement-modes) for detailed comparison.

## Configuration Best Practices

### SideBySide Mode Configuration

```bicep
// Basic zero-downtime setup
replacementMode: 'SideBySide'
targetSessionHostCount: 0  // Auto-detect for scaling plan compatibility
drainGracePeriodHours: 24
minimumDrainMinutes: 15    // Safety buffer for zero-session hosts
maxDeploymentBatchSize: 100
```

**With Progressive Scale-Up (Large Pools)**:
```bicep
enableProgressiveScaleUp: true
initialDeploymentPercentage: 10  // Start with 10%
scaleUpIncrementPercentage: 20   // Increase by 20% after success
successfulRunsBeforeScaleUp: 1   // Scale up after each success
```

**With Shutdown Retention (Rollback Capability)**:
```bicep
enableShutdownRetention: true
shutdownRetentionDays: 3  // Keep old hosts shutdown for 3 days
```

**With Ringed Rollout (Validate Before Fleet-Wide)**:
```bicep
replaceSessionHostOnNewImageVersionDelayDays: 7  // Wait 7 days to validate new image
```

### DeleteFirst Mode Configuration

```bicep
replacementMode: 'DeleteFirst'
targetSessionHostCount: 50  // Explicit count required (no auto-detect)
maxDeletionsPerCycle: 5     // Replace 5 hosts per run
minimumCapacityPercentage: 80  // Maintain at least 80% capacity
drainGracePeriodHours: 24
minimumDrainMinutes: 15
removeEntraDevice: true     // REQUIRED for hostname reuse
removeIntuneDevice: true    // REQUIRED for hostname reuse
```

**Important**: DeleteFirst mode requires Graph API permissions to be configured (see [README.md - Permissions Setup](README.md#permissions-setup)).

### Timer Schedule Guidance

**Default** (Every 30 minutes):
```bicep
timerSchedule: '0 0,30 * * * *'  // Runs at :00 and :30
```

**Hourly** (Lower overhead):
```bicep
timerSchedule: '0 0 * * * *'  // Every hour on the hour
```

**Business Hours Only** (Cost optimization):
```bicep
timerSchedule: '0 0 8-17 * * 1-5'  // 8 AM - 5 PM, Mon-Fri
```

**Staggered Across Multiple Deployments**:
- Deployment 1: `'0 0,30 * * * *'` (runs at :00 and :30)
- Deployment 2: `'0 15,45 * * * *'` (runs at :15 and :45)
- Avoids concurrent ARM API load

## Quick Deployment Steps

### Option 1: Update via Azure Portal (Fastest)
1. Navigate to your Function App in Azure Portal
2. Go to **Development Tools** → **App Service Editor**
3. Navigate to `Modules\SessionHostReplacer\SessionHostReplacer.psm1`
4. Replace the entire file content with your updated local version
5. Save the file
6. **Restart the Function App**

### Option 2: Deploy via PowerShell
From the repository root:

```powershell
# Compress the function app
$sourcePath = ".\deployments\add-ons\SessionHostReplacer\functions"
$zipPath = ".\SessionHostReplacer.zip"

Compress-Archive -Path "$sourcePath\*" -DestinationPath $zipPath -Force

# Deploy to Azure Function
$functionAppName = "your-function-app-name"
$resourceGroup = "your-resource-group"

Publish-AzWebApp -ResourceGroupName $resourceGroup -Name $functionAppName -ArchivePath $zipPath -Force

# Restart to reload modules
Restart-AzFunctionApp -ResourceGroupName $resourceGroup -Name $functionAppName -Force
```

### Option 3: Deploy via Azure CLI
```bash
# Zip the function folder
cd deployments/add-ons/SessionHostReplacer
zip -r SessionHostReplacer.zip functions/*

# Deploy
az functionapp deployment source config-zip \
  --resource-group <resource-group> \
  --name <function-app-name> \
  --src SessionHostReplacer.zip

# Restart
az functionapp restart \
  --resource-group <resource-group> \
  --name <function-app-name>
```

## Important: Restart Function App

After deploying, **always restart the Function App** to:
1. Clear any cached modules
2. Reload updated PowerShell modules
3. Clear token caches (if token acquisition logic changed)

## Verify Deployment

Check Application Insights for recent execution:

```kusto
traces
| where customDimensions.Category == "Function.session-host-replacer"
| where timestamp > ago(10m)
| order by timestamp desc
| take 20
```

Look for:
- ✅ Function execution started
- ✅ No module load errors
- ✅ Expected configuration values loaded
- ✅ No authentication failures

## For Complete Documentation

See [README.md](README.md) for:
- Prerequisites and permissions setup
- Full configuration reference
- Troubleshooting guide
- Monitoring best practices


### Module not reloading?
- Azure Functions cache PowerShell modules
- Restart is required to reload
- Consider adding version number to module manifest for tracking
