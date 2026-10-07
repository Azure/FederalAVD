# Schedule Session Host Maintenance

This operation schedules a one-time maintenance replacement on an existing Session Host Replacer.
It does not deploy or reconfigure the replacer. The selected replacer remains configured for
continuous `DeleteFirst` behavior and returns to that behavior automatically after the request
completes or expires.

Use the separate Template Spec Form View for an Azure portal experience, or use
[`Start-SessionHostMaintenanceReplacement.ps1`](../sessionHostReplacer/Start-SessionHostMaintenanceReplacement.ps1)
for PowerShell automation and air-gapped workflows.

## Prerequisites

- The Session Host Replacer is deployed and configured for `DeleteFirst`.
- Any scaling plan assigned to the host pool is disabled.
- No replacement deployment, pending recovery, replacer-owned drain, or shutdown-retained rollback
  VM remains.
- Entra device cleanup is enabled when session hosts are Entra joined.
- The operator has permission to read and update the selected Function App settings.

## Portal Scheduling

Publish the add-on Template Specs with:

```powershell
.\tools\New-TemplateSpecs.ps1 -CreateAddOns
```

Open **Schedule AVD Session Host Maintenance** in the Azure portal, select the existing Session Host
Replacer Function App, and provide the approved exact image version and UTC maintenance window. The
form reads the replacer application settings through ARM. For Compute Gallery configurations, it
derives the configured image definition and lists its non-excluded published versions in a dropdown.
Marketplace configurations retain an exact-version text entry. The deployment verifies that a
gallery definition supplied through a direct template call matches the replacer configuration.

The form requires explicit acknowledgements for forced sign-out, a possible full-pool outage, and
the absence of shutdown-retained rollback VMs.

The operation performs a guarded read-modify-write of the Function App application settings. It
preserves unrelated settings and changes only `MaintenanceRequest`. The deployment fails without
changing settings when:

- the selected app is not recognized as a Session Host Replacer;
- the configured replacement mode is not `DeleteFirst`;
- another request is populated and replacement was not explicitly authorized;
- required outage acknowledgements are missing; or
- Entra device cleanup is not enabled for an Entra-joined pool.

Runtime checks independently reject enabled autoscale, image mismatch, retained rollback VMs,
in-flight work, and other unsafe state.

> [!IMPORTANT]
> Do not enable ARM deployment debug logging for this operation. The template lists and reapplies
> the existing Function App settings so unrelated settings are preserved, and debug request/response
> logging can record sensitive resource properties.

## Required RBAC

The deploying identity needs:

- `Microsoft.Web/sites/read`
- `Microsoft.Web/sites/config/list/action`
- `Microsoft.Web/sites/config/write`
- `Microsoft.Compute/galleries/images/versions/read` on the configured Compute Gallery image
  definition when the form lists gallery versions
- permission to create a resource-group deployment in the Function App resource group

## Timing

The UTC start is evaluated by the Function App timer. With the default 30-minute cadence, the
operation can start up to approximately one timer interval after the requested time. Normal new
replacement batches are suspended after the request is scheduled; monitoring and exact-name
recovery already in progress continue.

After completion or expiry, continuous `DeleteFirst` behavior resumes automatically. The populated
request remains as an audit and replay-protection record. Select **Replace the existing populated
maintenance request** only after confirming that the prior request completed, expired, or was
intentionally abandoned.
