# Deploying Session Host Replacer Updates

> **Note:** For comprehensive deployment instructions, prerequisites, permissions setup, and troubleshooting, see [README.md](README.md).

This document provides quick reference for deploying updates to an existing Session Host Replacer function.

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
