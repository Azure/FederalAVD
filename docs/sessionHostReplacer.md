[**Home**](../README.md) | [**Quick Start**](quickStart.md) | [**Host Pool Deployment**](hostpoolDeployment.md) | [**Image Build**](imageBuild.md) | [**Artifacts**](artifactsGuide.md) | [**Features**](features.md) | [**Parameters**](parameters.md)

# Session Host Replacer Add-On

> **Note:** The Session Host Replacer is now available as a standalone add-on. For complete documentation, deployment instructions, and configuration details, see the **[Session Host Replacer Add-On Documentation](../deployments/add-ons/SessionHostReplacer/readme.md)**.

## Overview

The Session Host Replacer is an automated Azure Function that manages the lifecycle of Azure Virtual Desktop session hosts. It monitors session host image versions and automatically drains and replaces outdated VMs to maintain fleet health, security compliance, and image currency.

**Key Features:**
- **Flexible replacement strategies**: SideBySide (zero-downtime) or DeleteFirst (cost-optimized)
- **Image version tracking** with automatic updates
- **Graceful session draining** with configurable grace periods (default: 24 hours)
- **Minimum drain time** safety buffer for zero-session hosts (default: 15 minutes)
- **Progressive scale-up** for gradual, validated rollouts
- **Shutdown retention** for rollback capability (SideBySide mode)
- **Auto-detect target count** for dynamic scaling plan compatibility
- **Tag-based opt-in** model with automatic tag healing
- **Device cleanup** (Entra ID + Intune) with automatic hostname reuse
- **Template Spec integration** for consistent deployments
- **Comprehensive monitoring** with pre-built Azure Monitor Workbook dashboard
- **Multi-cloud support** (Commercial, GCC High, DoD, China; US Secret/Top Secret)

## Replacement Modes

### SideBySide Mode (Default)
- **Zero downtime**: New hosts added before old ones removed
- **Host pool temporarily doubles** during replacement cycles
- **Shutdown retention option**: Keep old hosts powered off for rollback
- **Auto-detect target count**: Compatible with dynamic scaling plans
- **Best for**: Production environments with SLA requirements

### DeleteFirst Mode
- **Cost optimized**: No host pool doubling, pays only for needed capacity
- **Temporary capacity reduction**: Deletes idle hosts before deploying replacements
- **Hostname reuse**: Leverages deleted names for new hosts
- **Dedicated host preservation**: Maintains host group assignments
- **Device cleanup required**: Graph API permissions mandatory
- **Best for**: Cost-sensitive environments, resource constraints (IPs/quotas), dedicated hosts

See the [complete mode comparison](../deployments/add-ons/SessionHostReplacer/readme.md#replacement-modes) for detailed decision guidance.

## Quick Start

For detailed deployment instructions, prerequisites, and configuration options, refer to the complete add-on documentation:

**[Session Host Replacer Add-On - Complete Documentation](../deployments/add-ons/SessionHostReplacer/readme.md)**

## Key Capabilities

### Progressive Scale-Up
Gradual deployment rollouts that start with small percentages and increase after successful deployments:
- Configurable initial percentage (e.g., 10% of needed hosts)
- Incremental scale-up after consecutive successes
- Automatic reset on failures or new image versions
- Works in both SideBySide and DeleteFirst modes

### Shutdown Retention (SideBySide Mode)
Rollback capability by retaining old session hosts in shutdown state:
- Configurable retention period (1-7 days)
- Automatic cleanup after retention expires
- Enables quick rollback if issues discovered with new image
- No additional cost (deallocated VMs only incur disk storage costs)

### Auto-Detect Target Count (SideBySide Mode)
Automatically maintains the current host count at replacement cycle start:
- Perfect for environments using dynamic scaling plans
- Adapts to manual scaling adjustments between image updates
- Function captures initial count when first outdated host detected
- Maintained throughout entire replacement cycle

### Ringed Rollout Support
Delay replacement after new image detection for validation:
- Configurable delay (0-30 days)
- Validate new image in production before fleet-wide rollout
- Similar to Windows Update ring strategy
- Enables gradual exposure of new images

### Device Cleanup & Hostname Reuse
Automatic cleanup of stale device records with intelligent hostname reuse:
- Removes Entra ID and Intune device records
- **DeleteFirst mode**: Reuses hostnames from deleted hosts (prevents name exhaustion)
- **DeleteFirst mode**: Preserves dedicated host assignments
- Automatic verification of resource cleanup before reuse

### Comprehensive Monitoring
Pre-built Azure Monitor Workbook dashboard:
- Real-time replacement cycle progress
- Progressive scale-up status tracking
- Deployment success/failure trends
- Host pool health metrics
- Image version adoption timeline
- Error and warning alerts
- Cross-region support (single dashboard for all regions)

## Migration from Integrated Feature

If you were previously using the Session Host Replacer as an integrated hostpool feature, it is now deployed as a separate add-on. The add-on architecture provides:
- Independent lifecycle management
- Easier updates and maintenance
- Support for multiple hostpools
- Enhanced configuration flexibility
- New replacement modes (DeleteFirst)
- New features (shutdown retention, progressive scale-up, auto-detect)

---

## Legacy Documentation (For Reference Only)

The information below documents the previous integration approach and is retained for reference purposes only. **For current deployments, use the standalone add-on documented above.**

---

## Architecture (Legacy)

### Components Created
1. **Azure Function App** - Hosts the PowerShell-based session host replacement logic
2. **Storage Account** - Stores function app artifacts and queue/table data
3. **Application Insights** - Monitors function app performance and execution
4. **App Service Plan** - Shared hosting plan in the management resource group

### Module Structure (Legacy)
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
azureBlobPrivateDnsZoneResourceId: '/subscriptions/.../privateDnsZones/privatelink.blob.core.usgovcloudapi.net'
azureFilesPrivateDnsZoneResourceId: '/subscriptions/.../privateDnsZones/privatelink.file.core.usgovcloudapi.net'
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
