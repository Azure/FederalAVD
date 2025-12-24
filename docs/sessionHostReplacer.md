# Session Host Replacer Integration

## Overview
The Session Host Replacer capability has been integrated into the hostpool deployment as an optional feature. It automatically replaces aging or outdated session hosts with new ones based on configurable policies.

## Architecture

### Components Created
1. **Azure Function App** - Hosts the PowerShell-based session host replacement logic
2. **Storage Account** - Stores function app artifacts and queue/table data
3. **Application Insights** - Monitors function app performance and execution
4. **App Service Plan** - Shared hosting plan in the management resource group

### Module Structure
```
deployments/hostpools/
├── hostpool.bicep (main deployment - updated)
├── modules/
│   ├── sessionHostReplacer/
│   │   └── sessionHostReplacer.bicep (function app deployment)
│   ├── common/
│   │   └── functionApp/
│   │       ├── functionApp.bicep (reusable function app infrastructure)
│   │       └── function.bicep (function deployment)
│   └── management/
│       └── management.bicep (shared app service plan)
.common/scripts/session-host-replacer/
├── profile.ps1 (all replacement functions)
├── run.ps1 (timer trigger entry point)
└── requirements.psd1 (PowerShell module dependencies)
```

## Deployment

### Required Parameters
To enable the session host replacer, set this parameter in your hostpool deployment:

```bicep
deploySessionHostReplacer: true
```

### Optional Parameters
The following deployment parameters are recommended when using session host replacer:

```bicep
// Server Farm (required for function apps)
existingHostingPlanResourceId: '' // Leave empty for Complete deployments, provide for HostpoolOnly

// Function App Networking (if using private endpoints)
functionAppSubnetResourceId: '/subscriptions/.../subnets/snet-functionapps'
deployPrivateEndpoints: true
azureFunctionAppPrivateDnsZoneResourceId: '/subscriptions/.../privateDnsZones/privatelink.azurewebsites.net'
azureBlobPrivateDnsZoneResourceId: '/subscriptions/.../privateDnsZones/privatelink.blob.core.windows.net'
azureFilesPrivateDnsZoneResourceId: '/subscriptions/.../privateDnsZones/privatelink.file.core.windows.net'
azureQueuePrivateDnsZoneResourceId: '/subscriptions/.../privateDnsZones/privatelink.queue.core.windows.net'
azureTablePrivateDnsZoneResourceId: '/subscriptions/.../privateDnsZones/privatelink.table.core.windows.net'
```

### Deployment Types
- **Complete**: Deploys app service plan, function app, and all dependencies
- **HostpoolOnly**: Requires existing app service plan via `existingHostingPlanResourceId`
- **SessionHostsOnly**: Not supported (requires control plane resources)

## Configuration

### Function App Settings
The following settings are automatically configured but can be customized:

| Setting | Default Value | Description |
|---------|--------------|-------------|
| `TargetVMAgeDays` | `45` | Replace session hosts older than this many days |
| `DrainGracePeriodHours` | `24` | Hours to wait before forcefully removing drained hosts |
| `MaxSessionHostsToReplace` | `1` | Maximum concurrent replacements |
| `FixSessionHostTags` | `true` | Automatically fix missing tags on existing hosts |
| `IncludePreExistingSessionHosts` | `false` | Include pre-existing hosts in automation |
| `Tag_IncludeInAutomation` | `IncludeInAutoReplace` | Tag to identify hosts for replacement |
| `Tag_DeployTimestamp` | `AutoReplaceDeployTimestamp` | Tag storing deployment time |
| `Tag_PendingDrainTimestamp` | `AutoReplacePendingDrainTimestamp` | Tag storing drain start time |
| `Tag_ScalingPlanExclusionTag` | `ScalingPlanExclusion` | Tag to exclude from scaling plan |
| `RemoveEntraDevice` | `false` | Remove device from Entra ID on deletion |
| `RemoveIntuneDevice` | `false` | Remove device from Intune on deletion |

### Schedule
The function runs on a timer trigger: **Every 6 hours** (`0 0 */6 * * *`)

This can be modified in `sessionHostReplacer.bicep`:
```bicep
schedule: '0 0 */6 * * *' // Change as needed
```

## Permissions

### Managed Identity Roles
The function app is automatically assigned:
- **Desktop Virtualization Virtual Machine Contributor** - On session hosts resource group
- **Reader** - On host pool resource group

Additional permissions may be needed for:
- Entra ID device removal (requires Graph API permissions)
- Intune device removal (requires Graph API permissions)

## How It Works

1. **Timer Trigger** - Function executes every 6 hours
2. **Session Host Discovery** - Retrieves all session hosts from the host pool
3. **Filtering** - Identifies hosts marked with `IncludeInAutoReplace` tag
4. **Age Check** - Compares host age against `TargetVMAgeDays`
5. **Image Version Check** - Compares current image with latest available version
6. **Deployment Decision** - Determines how many new hosts to deploy
7. **New Host Deployment** - Creates replacement session hosts
8. **Drain Mode** - Sets old hosts to drain mode and waits for grace period
9. **Removal** - Deletes session hosts after grace period expires

## Monitoring

### Application Insights
When `enableMonitoring: true`:
- Function execution logs
- Performance metrics
- Failure tracking
- Custom telemetry from profile.ps1

### Log Analytics
All function app logs are sent to the configured Log Analytics workspace.

### Alerts
Consider creating alerts for:
- Function execution failures
- Long-running operations
- High replacement frequency

## Networking

### Private Endpoints
When `deployPrivateEndpoints: true`, the following private endpoints are created:
- Function App (`sites`)
- Storage Account (`blob`, `file`, `queue`, `table`)

### Virtual Network Integration
The function app can be integrated with a virtual network using `functionAppSubnetResourceId`. This subnet must be delegated to `Microsoft.Web/serverFarms`.

## Troubleshooting

### Common Issues

**Function not executing:**
- Check App Service Plan is running
- Verify timer trigger configuration
- Check Application Insights for errors

**Permission errors:**
- Verify managed identity has required roles
- Check resource group and subscription access

**Session hosts not replacing:**
- Verify hosts have `IncludeInAutoReplace` tag set to `true`
- Check `TargetVMAgeDays` configuration
- Review function logs for decision logic

**Storage access errors:**
- Ensure function app managed identity has Storage Blob Data Owner role
- Verify private endpoints are correctly configured
- Check DNS resolution for storage endpoints

## Cost Considerations

### Resources Deployed
- App Service Plan: **Premium V3 P1v3** (shared with increase quota function if both enabled)
- Storage Account: **Standard LRS**
- Application Insights: **Pay-as-you-go**
- Private Endpoints: **Per endpoint + data processing**

### Cost Optimization
- Shared app service plan reduces costs when multiple function apps are deployed
- Premium plan is required for virtual network integration
- Consider Consumption plan for low-frequency executions (requires code changes)

## Security Best Practices

1. **Use Private Endpoints** - Secure all network traffic
2. **Enable Managed Identity** - Avoid credential management
3. **Restrict Function App Access** - Use network restrictions
4. **Monitor Execution** - Enable Application Insights and alerting
5. **Tag Management** - Use tags to control which hosts are managed
6. **Test in Non-Production** - Validate replacement logic before production use

## Future Enhancements

Potential improvements:
- Support for Consumption plan deployment option
- Configurable replacement schedules per host pool
- Integration with change management systems
- Support for blue/green deployment patterns
- Advanced placement constraints (availability zones, dedicated hosts)

## Related Documentation
- [Azure Functions PowerShell Developer Guide](https://learn.microsoft.com/azure/azure-functions/functions-reference-powershell)
- [AVD Session Host Management](https://learn.microsoft.com/azure/virtual-desktop/set-up-scaling-script)
- [Azure Function App Networking](https://learn.microsoft.com/azure/azure-functions/functions-networking-options)
