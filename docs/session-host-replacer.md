[**Home**](../README.md) | [**Quick Start**](quick-start.md) | [**Add-Ons**](add-ons.md) | [**Host Pool Management**](host-pool-management.md) | [**Automation**](automation-guide.md)

# Session Host Replacer Add-On

The Session Host Replacer is an Azure Function add-on that replaces standard-management Azure
Virtual Desktop session hosts when a newer Compute Gallery image version is available.

> **Standard host pools only.** Do not target an automated host pool that uses Session Host
> Configuration. Automated pools use native Session Host Update. See
> [Choose a Host Pool Management Approach](host-pool-management.md).

## Documentation Map

Each document has one purpose:

| Document | Purpose |
| --- | --- |
| [Add-on README](../deployments/add-ons/sessionHostReplacer/README.md) | Prerequisites, deployment, parameters, monitoring, configuration management, and troubleshooting |
| [Canonical replacement flow](../deployments/add-ons/sessionHostReplacer/replacement-flow.md) | SideBySide and DeleteFirst sequencing, scaling-phase behavior, readiness, recovery, and safety invariants |
| [Deployment update guide](../deployments/add-ons/sessionHostReplacer/deployment-guide.md) | Updating the deployed Function App code and reviewing operational settings |
| [Logging guide](../deployments/add-ons/sessionHostReplacer/logging-guide.md) | Logging conventions and diagnostic configuration |
| [Alerts guide](../deployments/add-ons/sessionHostReplacer/alerts/alerts-guide.md) | Recommended monitoring alerts |

The canonical flow document is authoritative when a lifecycle summary elsewhere conflicts with
detailed replacement behavior.

## Replacement Modes

### SideBySide

SideBySide deploys and validates new hosts before removing old hosts.

- Best availability and rollback options.
- Requires temporary subnet, compute quota, and VM capacity for both generations.
- Can retain deallocated old hosts for a configured rollback period.
- Replacement deployment and validation can continue during the pre-RampUp, RampUp, and Peak
  destructive-work freeze; old-host removal waits for RampDown or OffPeak.

### DeleteFirst

DeleteFirst removes a capacity-safe batch before deploying replacements with the same names.

- Avoids temporary pool doubling.
- Preserves hostnames and dedicated-host placement.
- Persists recovery mappings before deletion and blocks new deletion until unresolved replacements
  are registered and healthy.
- Retains at least one online healthy host.
- Starts no new delete/deploy batch during the 60-minute pre-RampUp window, RampUp, or Peak.
- Exact-name replacement is blocked for a one-host target because it cannot preserve availability.

See the [canonical replacement flow](../deployments/add-ons/sessionHostReplacer/replacement-flow.md)
for complete sequencing and failure behavior.

## Key Capabilities

- Image-version-based replacement with optional rollout delay and rollback protection.
- Explicit or cycle-based auto-detected target host count.
- Progressive batch growth with independent mode-specific ceilings.
- Scaling-aware readiness with exact-image validation evidence.
- Replacer-owned scaling exclusions that do not overwrite administrator-owned exclusions.
- Configurable drain notification, minimum drain time, and active-session grace period.
- Entra device cleanup required for DeleteFirst replacement of Microsoft Entra joined hosts and
  optional for domain-joined or hybrid-joined hosts.
- Optional Intune cleanup, highly recommended before DeleteFirst hostname reuse for Intune-enrolled
  Entra-joined or hybrid-joined hosts.
- Centralized Azure Monitor Workbook and alerting guidance.
- Validated operational-setting updates through
  [Set-SessionHostReplacerConfiguration.ps1](../deployments/add-ons/sessionHostReplacer/Set-SessionHostReplacerConfiguration.ps1).
- Azure Commercial, Government, Secret, and Top Secret support.

## Deployment

Deploy one Session Host Replacer instance per standard host pool. Template Specs provide the guided
portal form in every supported cloud and are the recommended first-deployment method.

Start with the
[complete deployment prerequisites](../deployments/add-ons/sessionHostReplacer/README.md#prerequisites)
and
[Template Spec deployment instructions](../deployments/add-ons/sessionHostReplacer/README.md#template-spec-portal-form-first-deployment).

## Operations

Use the centralized workbook to review replacement progress, effective scaling behavior, current
configuration, warnings, and errors. Use the guarded configuration command to review or update
supported operational settings without displaying secrets:

```powershell
.\Set-SessionHostReplacerConfiguration.ps1 `
  -FunctionAppName <function-app-name> `
  -ResourceGroupName <function-app-resource-group>
```

Replacement mode, timer schedule, identity, networking, permissions, and infrastructure remain
Template Spec or Bicep deployment concerns. A later Template Spec redeployment can overwrite direct
operational-setting changes unless its authoritative parameters are updated to match.

## Related Documentation

- [Add-Ons](add-ons.md)
- [Host Pool Management](host-pool-management.md)
- [Image Automation](automation-guide.md)
- [Image Build](image-build.md)
- [BCDR](bcdr.md)
- [Air-Gapped Clouds](air-gapped-clouds.md)
