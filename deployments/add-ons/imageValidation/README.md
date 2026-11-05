# Image Validation Add-On

![Graphic highlighting image validation process](../../../docs/images/imageValidation.png)

[main.bicep](./main.bicep) deploys a resource group, user-assigned managed identity, Windows PowerShell Function App, identity-authenticated runtime storage, and a native timer function named `ImageValidation`. It creates a Dedicated Windows plan unless an existing compatible plan ID is supplied. The deployment uses the shared Function App, hosting-plan identity, and timer modules; it does not duplicate their resource definitions.

## Centralized naming

The deployment imports `functionAppNames` and `resourceNameForType` from the
[shared naming policy](../../shared/modules/orchestration/naming/README.md).
There is no add-on-specific naming engine or copied abbreviation catalog.

- `identifier` defaults to `iv`, deliberately short enough for generated runtime
  storage names. Use distinct identifiers for independent instances.
- `namingConvention: {}` uses current shared defaults, including component order,
  delimiter, workload, region mappings, type abbreviations, and length limits.
- The resource group is named first with subscription context and an empty
  resource-group field. The resolved group name then supplies the actual context
  for app resources and their deterministic uniqueness seed.
- The app, runtime storage, Insights, storage-CMK identity reservation, and private
  endpoint/NIC patterns come from `functionAppNames`. The group, runtime identity,
  and separately owned plan use `resourceNameForType`.
- Explicit overrides bypass generation for the group, runtime identity, app,
  storage, and new plan. An existing plan ID skips plan creation entirely.
- `generatedNames` returns all resolved names and endpoint patterns. Patterns are
  resolved by the shared infrastructure module against each endpoint target.
  Insights is created only when a workspace is selected. The storage-CMK identity
  name is reserved in the bundle but is **not deployed**: this version selects
  platform-managed storage encryption with infrastructure encryption.

For `eastus` and the default convention, the group is `rg-avd-iv-use`, the app
identity is `uai-avd-iv-use`, and the plan is `asp-avd-iv-use`. App and storage
names include the shared six-character application/scope hash. Changing naming
inputs can create different resources; it does not migrate an existing instance.

The unused draft `namingComponentOrder` parameter is replaced by the shared
`namingConvention` contract.

## Parameters

| Parameter | Default / requirement |
| --- | --- |
| `location` | Subscription deployment location |
| `identifier`, `namingConvention` | `iv`, `{}` |
| `resourceGroupNameOverride`, `userAssignedIdentityNameOverride` | Empty generates names; the deployment manages the selected group and identity |
| `functionAppNameOverride`, `storageAccountNameOverride` | Empty generates names; supply globally available explicit names as needed |
| `appServicePlanNameOverride` | Empty generates the new plan name; ignored for an existing plan ID |
| `existingAppServicePlanResourceId` | Empty creates a dedicated plan; otherwise supply a same-region Windows Dedicated plan supporting VNet integration and Always On |
| `imageDefinitionResourceId` | Required existing Azure Compute Gallery image definition resource ID |
| `schedule` | Required six-field Functions NCRONTAB schedule, or supported app-setting reference |
| `functionAppAppSettings` | `[]`; additional `{ name, value }` settings, without plaintext secrets |
| `privateEndpoint` | `true`; explicit `false` enables public app and storage access |
| `functionAppDelegatedSubnetResourceId` | Required for private mode; existing same-region integration subnet delegated to `Microsoft.Web/serverFarms` |
| `privateEndpointSubnetResourceId` | Required for private mode; separate existing endpoint subnet |
| `azureBlobPrivateDnsZoneResourceId` | Required for private mode; target-cloud blob zone linked to the integration VNet |
| `azureFunctionAppPrivateDnsZoneResourceId` | Required for private mode; target-cloud app zone linked to the integration VNet |
| `logAnalyticsWorkspaceResourceId` | Empty disables Insights/diagnostics; otherwise uses the existing workspace |
| `privateLinkScopeResourceId` | Empty uses public Insights ingestion/query when monitoring is enabled; supply an existing configured AMPLS for private monitoring |
| `tags` | `{}`; flat tags applied through the shared modules' per-resource-type tag interface |

## Prerequisites and permissions

The draft [virtual machine module](./modules/virtualMachine.bicep) accepts
`runCommandSettings`, defaulting to `[]`. Each entry requires a unique `name`,
an inline `script`, and `parameters`: an array of `{ name: string, value: string }`
objects (use `[]` for scripts without parameters). These are regular Run Command
parameters, not protected parameters; do not include secrets. This module is not
yet wired into a working validation workflow.

Private mode disables public app/storage endpoints, creates app and blob private
endpoints, and routes Function traffic through the integration subnet. DNS zones
and VNet links must already exist and resolve from that VNet, including app SCM
records where required. The template checks missing private inputs; operators
must verify subnet separation, delegation, region, available addresses, routing,
firewall access, and DNS resolution. It does not create networking.

The native timer uses blob host storage; queue/table endpoints are disabled.
The shared module grants the app identity its built-in host-storage roles.
No subscription-wide or image/VM workload permissions are granted. Assign only
the permissions required by the approved validation implementation to the returned
`userAssignedIdentityPrincipalId`; arrange authorization before scheduled work
starts. The deployment principal needs resource deployment, identity assignment,
host-storage role-assignment, and the relevant subnet/private-DNS permissions.

The shared runtime currently selects PowerShell 7.6, Functions v4, and .NET 10.
Verify that runtime, Windows plan SKU, networking, and monitoring capabilities
are available in the target cloud/region. No cross-cloud live validation has
been performed. Code and its dependencies must be pre-staged for restricted
environments. Function-level `files` does not install app-level `host.json`,
PowerShell modules, profiles, or managed dependencies.

## Deploy with PowerShell

Review the packaged validation scripts and create environment-specific input JSON
under the git-ignored [customer area](../../../customer/README.md). For example, save this
input shape as `customer\parameters\imageValidation\infrastructure.json` and
replace every resource ID before use:

```json
{
  "imageDefinitionResourceId": "/subscriptions/<subscription>/resourceGroups/<group>/providers/Microsoft.Compute/galleries/<gallery>/images/<definition>",
  "schedule": "0 0 2 * * *",
  "functionAppDelegatedSubnetResourceId": "/subscriptions/<subscription>/resourceGroups/<network-group>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<integration-subnet>",
  "privateEndpointSubnetResourceId": "/subscriptions/<subscription>/resourceGroups/<network-group>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<endpoint-subnet>",
  "azureBlobPrivateDnsZoneResourceId": "/subscriptions/<subscription>/resourceGroups/<dns-group>/providers/Microsoft.Network/privateDnsZones/<cloud-blob-zone>",
  "azureFunctionAppPrivateDnsZoneResourceId": "/subscriptions/<subscription>/resourceGroups/<dns-group>/providers/Microsoft.Network/privateDnsZones/<cloud-app-zone>"
}
```

From the repository root, using an authorized subscription and cloud:

```powershell
$inputs = Get-Content customer\parameters\imageValidation\infrastructure.json -Raw |
    ConvertFrom-Json -AsHashtable
New-AzSubscriptionDeployment -Name image-validation -Location eastus `
    -TemplateFile deployments\add-ons\imageValidation\main.bicep `
    -TemplateParameterObject $inputs
```

## Portal form

The [Portal form](./uiFormDefinition.json) follows the repository's Form View
patterns and maps to the current entry-template parameters:

1. **Basics** selects the deployment subscription, Function region, and existing
   Compute Gallery image definition. The template deploys at subscription scope;
   it manages the resource group named on the final step.
2. **Function App Settings** selects a new or existing same-region plan, requires
   a six-field timer schedule or app-setting reference, and provides an optional
   name/value grid for non-secret app settings. Confirm existing plans are Windows
   Dedicated with VNet integration and Always On; region filtering is not a SKU or
   operating-system compatibility check. Schedule validation checks field count,
   not NCRONTAB ranges or runtime acceptance.
3. **Networking** defaults to private endpoints and requires separate existing
   integration and endpoint subnet IDs plus target-cloud blob and app DNS zones.
   Public mode explicitly enables public app/storage access and clears private
   networking inputs, including VNet integration.
4. **Monitoring** optionally selects an existing workspace and configured Azure
   Monitor Private Link Scope. Private app/storage access alone does not make
   monitoring private.
5. **Naming + Tags** uses the short `iv` identifier and shared naming defaults,
   exposes complete name overrides, and applies one flat tag set to all resource
   types that accept tags. Custom `namingConvention` objects remain a parameter-file
   option.

The form does not accept validation code: the current template embeds the
repository scripts. Review the implementation and arrange workload permissions
before deployment. Hidden existing-plan, networking, and monitoring selections
are cleared from outputs when their corresponding options are disabled.

This add-on is not registered with the Template Spec publisher and has no tracked
ARM counterpart yet. Use Bicep with PowerShell/Azure CLI, or explicitly package the
compiled template with this form for a Template Spec. Before relying on the Portal
path, run a live render smoke test through every step, including private/public,
new/existing-plan, and monitoring transitions; offline checks do not prove Portal
expression evaluation or deployment success.

## Validation

```powershell
Invoke-Pester -Script tests\ImageValidation.Tests.ps1,tests\IdentifierNaming.Tests.ps1
Invoke-Pester -Script tests\TemplateSpecs.Tests.ps1
Invoke-Pester -Script tests\ImageValidationUi.Tests.ps1
```

Offline checks cover compilation, centralized naming wiring, private defaults,
module sequencing, form parameter bindings, existing-plan selection, and
conservative serialized size budgets. Live validation still needs a first deploy
and redeploy in the selected cloud, identity authorization, runtime startup,
private DNS/connectivity (including monitoring if selected), and successful and
failing runs of the approved validation script. Offline tests do not establish
image acceptance, runtime availability, or deployment success.