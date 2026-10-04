# Deploying Session Host Replacer Updates

> **Note:** For comprehensive deployment instructions, prerequisites, permissions setup, and troubleshooting, see [README.md](README.md).

This document provides quick reference for deploying updates to an existing Session Host Replacer function and guidance for choosing deployment options.

## Scope

This guide covers updating an existing Function App deployment and reviewing its operational
settings. It does not redefine replacement behavior or duplicate the full first-deployment
parameter reference.

- Choose a mode and review parameters in [README.md](README.md#replacement-modes).
- Review execution, scaling-phase, readiness, and recovery behavior in the
  [canonical replacement flow](replacement-flow.md).

## Timer Schedule Guidance

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
$sourcePath = ".\deployments\add-ons\sessionHostReplacer\functions"
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
cd deployments/add-ons/sessionHostReplacer
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

## Review or Update Existing Operational Settings

Use the repository-provided configuration command instead of editing unlabelled Function App
environment variables directly:

```powershell
.\Set-SessionHostReplacerConfiguration.ps1 `
    -FunctionAppName <function-app-name> `
    -ResourceGroupName <function-app-resource-group>
```

Supply supported setting parameters and `-WhatIf` to preview a change. The command validates
mode-specific settings, displays a diff, and preserves unrelated app settings. Replacement mode,
timer schedule, identity, networking, device-cleanup permissions, and infrastructure changes must
still be made through the Template Spec. Keep its parameter source synchronized because a later
redeployment can overwrite direct operational changes.

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
