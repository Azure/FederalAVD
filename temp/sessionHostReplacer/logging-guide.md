# Session Host Replacer - Logging Guidelines

## Logging Levels

The SessionHostReplacer uses `Write-HostDetailed` with the following levels:

- **Host**: Critical status information that should always be visible
- **Information**: Important status messages for tracking progress
- **Verbose**: Detailed diagnostic information, only shown when verbose mode is enabled
- **Warning**: Issues that don't stop execution
- **Error**: Failures that impact functionality

## Enabling Verbose Mode

### Option 1: Application Settings (Recommended for Production)
Add this setting to your Function App configuration:

```powershell
AzureWebJobsLogging__FileLoggingMode = "Always"
FUNCTIONS_WORKER_RUNTIME_VERSION = "7"
```

In Azure Portal:
1. Navigate to Function App → Configuration → Application Settings
2. Add: `FUNCTIONS_WORKER_RUNTIME_VERSION` = `7`
3. To see verbose logs in Application Insights, add a query filter

### Option 2: host.json Configuration
Edit `host.json` in your function app root:

```json
{
  "version": "2.0",
  "logging": {
    "logLevel": {
      "default": "Information",
      "Function": "Information",
      "Host.Results": "Information"
    },
    "console": {
      "isEnabled": true
    }
  },
  "extensions": {
    "logging": {
      "fileLoggingMode": "always"
    }
  }
}
```

### Option 3: Local Development with VSCode
Set `$VerbosePreference = 'Continue'` at the start of run.ps1:

```powershell
$VerbosePreference = 'Continue'
```

### Option 4: Query Application Insights
Verbose logs are captured in Application Insights. Query them with:

```kusto
traces
| where customDimensions.Category == "Function.session-host-replacer"
| where message contains "[Verbose]"
| order by timestamp desc
```

## Current Logging Strategy

### Host Level (Always Visible)
- Function start/stop
- Token acquisition status
- Session host counts
- Deployment decisions and submission
- Deletion decisions
- Major state transitions

### Information Level (Default)
- Deployment state tracking
- Previous deployment status checks
- Image version detection
- State persistence operations

### Verbose Level (Diagnostic)
- Individual session host details
- VM tag operations
- Image version enumeration
- API response details
- Cache operations

### Warning Level
- Non-critical failures (Graph token, device cleanup)
- Unexpected conditions that don't stop execution
- Previous deployment still running

### Error Level  
- Token acquisition failures
- Deployment submission errors
- Critical API failures
- State persistence errors

## Recommended Changes

To reduce log noise while maintaining visibility, the following logs should be changed from Host/Information to Verbose:

### In run.ps1:
- Subscription IDs → Verbose
- Token acquisition success → Verbose (keep failure as Host)
- Image reference details → Verbose
- Running deployment count → Verbose

### In SessionHostReplacer.psm1:
- Individual session host processing → Verbose
- VM tag operations → Verbose
- Image version details → Verbose
- Template spec version resolution → Verbose
- State table creation → Verbose
- Individual drain operations → Verbose

### Keep as Host/Information:
- Overall session host counts
- Deployment decisions (how many to deploy/delete)
- Deployment submission results
- Progressive scale-up status
- Previous deployment outcome
- Critical errors
