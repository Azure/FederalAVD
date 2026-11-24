# FSLogix Storage Add-On

This add-on provisions FSLogix storage independently of a FederalAVD host pool deployment. It uses
the same `deployments/shared/modules/orchestration/fslogix/fslogix.bicep` module as the host pool and is
also composed by the automated host-pool deployment before policy and session-host provisioning.

## Boundary

The add-on owns profile storage configuration and the temporary resources needed to initialize it.
For identity-based storage authentication, it creates a temporary resource group, deployment VM,
user-assigned identity, and role assignments. After storage configuration completes, the VM removes
its external role assignments and deletes the temporary resource group, including itself and its
identity. Entra ID storage-account-key authentication skips these temporary resources and the
deployment VM's NTFS configuration. The add-on does not create a host pool,
session host, policy assignment, Key Vault, or Log Analytics workspace. Those shared resources
are supplied by resource ID. For Azure Files snapshot backup, the add-on can consume an existing
vault and policy, create a shared regional vault in the operations resource group, or create a
dedicated vault in the storage resource group. It reuses the same backup vault module as AVD
Shared Services. Office container shares are never enrolled by the shared FSLogix backup module.

## Deployment

Use the Template Spec portal form for the first deployment. Publish the add-on Template Specs with
[`New-TemplateSpecs.ps1`](../../../tools/New-TemplateSpecs.ps1), then open **Template Specs** in the
Azure portal and deploy **AVD FSLogix Storage**. On **Review + create**, select **Create**. After the
deployment is submitted, select **Download template and parameters** and retain the working
parameter file for subsequent PowerShell or CI/CD deployments.

### Portal Form Behavior

Use `uiFormDefinition.json` with the subscription-scoped `main.bicep` template. The form uses the
standard deployment scope control for subscription and region selection, then lets you select an
existing storage resource group or create a new one. It follows the same identity, storage,
permissions, networking, encryption, monitoring, backup, and Azure NetApp Files choices as the
host-pool FSLogix experience. Encryption key management, private networking, monitoring, and
recovery are grouped on the Zero Trust Configuration page. Resource tags and optional naming
overrides are grouped on the final Tags and Naming page.

For Azure Files, the portal form checks the Storage resource provider SKU inventory for the selected
subscription and region. For Legacy billing it checks `Standard_ZRS` with the `StorageV2` account
kind or `Premium_ZRS` with `FileStorage`; for Provisioned v2 it checks `StandardV2_ZRS` or
`PremiumV2_ZRS`, both with `FileStorage`. When the matching
ZRS SKU is available and has no location restriction, the form offers both LRS and ZRS, defaults to
ZRS, and warns only if LRS is selected. Otherwise, only LRS is offered. Direct Bicep, PowerShell, and
CI/CD deployments retain the `LocallyRedundant` parameter default and must select
`ZoneRedundant` explicitly.
V2 LRS and ZRS availability checks use the selected role's effective tier and billing model;
unavailable v2 SKUs do not silently fall back to legacy inventory or billing.

For Cloud Cache, the form follows the host-pool workflow instead of accepting raw identifiers.
Azure Files users select a remote region and existing storage accounts discovered from Azure.
Azure NetApp Files users select a remote account, capacity pool, and volumes. The add-on accepts
the selected NetApp volume resource IDs and resolves their SMB server FQDNs through the shared
FSLogix resolver. Optional remote selections must contain one storage account per local storage
account or one NetApp volume per FSLogix share, in profile-then-Office order.

The add-on uses the host-pool naming module. The Storage Purpose selection distinguishes between
storage associated with an existing host pool persona, storage for a future host pool persona, and
storage shared by multiple host pools, which is the default. Persona-specific modes use the same
**Host Pool Persona** terminology and validation as the host-pool form. Selecting an existing
FederalAVD host pool uses its `hpIdentifier` tag as the editable Host Pool Persona default and
offers its `hpNamingConvention` tag as the default naming convention. Users can choose the standard
resource type, workload, purpose, and region convention instead. Future-persona deployments require
an explicit identifier. Shared deployments default the editable identifier to `fslogix`, following
the fixed purpose-token pattern used by shared `operations`, `monitoring`, `control-plane`, and
`image-management` resources. With the standard convention, the shared storage resource group uses
the `fslogix-storage` purpose value. Change the identifier only when separate shared FSLogix storage
scopes must coexist in the same region.
When host-pool naming is not selected or no naming tag is available, the Portal emits an empty
convention object and the shared naming library applies the canonical defaults. The output must
not read defaults from the hidden naming-policy control before it initializes; doing so can leave
the initial form page blank and break step navigation.
The editable shared-storage identifier uses a literal default checked against the canonical
policy by Pester, rather than a runtime hidden-control lookup.
When an existing host pool is selected, its resource ID is applied as the `cm-resource-parent` tag
to newly created storage resource groups, temporary deployment resources, storage accounts, private
endpoints, NetApp resources, backup registrations, encryption keys, and the storage encryption
identity. Shared and future-host-pool modes do not apply a parent tag because no single existing
host pool owns those resources at deployment time.
Azure Files storage account prefixes use the central deterministic naming bundle: `fslpc` for Profile
accounts and `fsloc` for Office accounts. Prefixes are limited to 13 characters so appending the two-digit
storage index remains compatible with Active Directory computer account names. Advanced overrides
are optional and may be supplied individually; every blank override continues to use the generated
name.

For Azure NetApp Files, the add-on can create the complete account, capacity pool, and volume stack;
create a capacity pool and volumes in an existing account; or create volumes in an existing account
and capacity pool. Existing accounts are referenced without modification and must already contain a
valid Active Directory connection. The add-on always creates new FSLogix volumes; it does not adopt
or modify existing volumes.

Authentication follows the host-pool form's join-type-first decision tree. AD DS session hosts use
AD DS authentication and may use Azure Files or Azure NetApp Files. Microsoft Entra Domain Services
session hosts use Azure Files with Entra Domain Services authentication. Microsoft Entra-joined
session hosts use Azure Files and then choose storage account keys, Microsoft Entra Kerberos for
cloud-only identities, or Microsoft Entra Kerberos for hybrid identities.

Identity-based storage authentication uses a temporary deployment VM and identity. Azure Files uses
the VM to set the root NTFS security descriptor through the Azure Files REST API. Domain-backed and
Entra Kerberos options also use it for applicable identity configuration, and Azure NetApp Files
uses it to set volume permissions. Cleanup removes the external role assignments and deletes the
temporary resource group after configuration.

The **Temporary Deployment Resources** step remains visible for all authentication methods. When
**Microsoft Entra joined** and **Storage account key** are selected, the step shows an information
box explaining that no deployment VM is created. VM network, subnet, size, and OU controls are
hidden and not required; temporary-resource naming overrides are also hidden. The subnet output is
an empty string, and the unused VM size uses the template default. Other authentication methods
retain the deployment VM controls and requirements. Direct template deployments can omit
`deploymentVirtualMachineSubnetResourceId` for storage-account-key authentication or when reusing an
externally managed deployment VM; the subnet is required when this add-on creates the VM.

For AD DS and Microsoft Entra Domain Services, **Domain join deployment VM** appears immediately
after the temporary VM size when domain join is optional. For Azure NetApp Files, the form hides
the checkbox and submits `true` because domain join is required. Otherwise, it is unchecked by
default and reuses the configured domain and
manual or Key Vault credentials. The parameter `domainJoinDeploymentVirtualMachine` defaults to
`false`. A true value requires an add-on-managed helper, a domain name, and domain credentials;
it is rejected for Entra-joined identity modes or an externally managed VM. Join an external helper
through its owning deployment instead.

The helper uses `deploymentVirtualMachineOrganizationalUnitPath` when supplied, otherwise
`organizationalUnitPath`. The existing Portal helper OU override remains available for Azure NetApp
Files; other optional joins reuse the storage OU. Azure NetApp Files retains automatic domain join
for parameter-file deployments as well. Ensure domain-controller connectivity and DNS resolution,
review the OU's policies for compatibility with the temporary Windows Server helper, and remove
its AD computer account through the approved directory cleanup process after Azure cleanup.

After publishing an updated Template Spec, smoke-test the form in Azure Portal. Confirm that the
storage-key path can advance past this step without VM selections, then switch to AD DS, Entra
Domain Services, and both Entra Kerberos options and verify the VM controls are required. Also test
switching back to storage keys after filling the controls: downloaded parameters must not retain
the hidden subnet or temporary-resource overrides. For Azure NetApp Files, verify the VM OU control
is still shown and required.

Create the dedicated session-host VM resource group first because Session Host Configuration can
only target an existing resource group. Then create the pooled automated host pool and Session Host
Configuration, select that resource group for its VMs, and keep the desired session host count at
zero. The automated host-pool deployment composes this template, passes its
`fslogixConfiguration` output to the internal policy stage, and requests the final session-host
count only after storage, policy, and role assignments complete.

## Capabilities

| Capability | Azure Files | Azure NetApp Files |
| --- | --- | --- |
| AD DS | Yes | Yes |
| Entra Domain Services | Yes | Yes |
| Entra Kerberos Hybrid | Yes | No |
| Entra Kerberos Cloud Only | Yes | No |
| Entra ID with storage keys | Yes | No |
| Share permissions | Default SMB share permission and admin Azure RBAC | Volume configuration |
| NTFS permissions | Deployment VM Run Command for identity-based authentication; skipped for Entra ID storage keys | Deployment VM Run Command |
| Private networking | Private endpoint | Delegated subnet |
| Customer-managed keys | Existing Key Vault; keys and identity created automatically | Managed by the NetApp account path |
| Diagnostics | Existing Log Analytics workspace | Not configured by the shared module |
| Backup | Existing or newly created shared/dedicated Recovery Services vault and policy; profile shares only | Not configured by the shared module |

### Azure Files Snapshot Backup

On **Zero Trust Configuration > Monitoring and Recovery**, choose:

| Portal choice | Behavior |
| --- | --- |
| No backup | No vault, policy, or backup enrollment. This remains the default. |
| Use an existing vault and policy | Select the vault and supply its policy name. Neither resource is modified. |
| Create a shared regional vault | Create or reuse the naming convention's operations resource group and deploy the shared regional vault and policy. |
| Create a dedicated vault | Deploy an identifier-based vault and policy in this deployment's storage resource group. |

With the default naming convention, shared vaults are named
`rsv-avd-files-<locationAbbreviation>` and dedicated vaults are named
`rsv-avd-<identifier>-backup-<locationAbbreviation>`. Both use the centralized
Recovery Services vault naming policy; an explicit `backupVaultName` overrides the generated name.

New vaults use a daily snapshot policy at **23:00** in the selected Windows time zone, with
**30 days** retention by default. Snapshot data remains in Azure Files, protected by the storage
account's encryption and networking controls; the vault holds backup metadata. The add-on does
not create a vault private endpoint because [Azure Files snapshot backup does not require one](https://learn.microsoft.com/en-us/azure/backup/private-endpoints-overview#recommended-and-supported-scenarios).
The new vault uses the shared module's enabled public network access, LRS metadata storage,
platform-managed encryption, and security defaults. Storage private endpoints remain independent.
The vault and storage accounts must be in a supported backup configuration in the same subscription
and region.

| Parameter | Default | Purpose |
| --- | --- | --- |
| `recoveryServicesVaultResourceId` | Empty | Existing vault ID. Takes precedence over vault creation. |
| `fileSharePolicyName` | `filesharepolicy` | Policy to create in a new vault or consume in an existing vault. |
| `deployFSLogixBackupVault` | `false` | Create a vault and policy when no existing vault ID is supplied. Azure Files only. |
| `backupVaultScope` | `Shared` | `Shared` uses the operations resource group; `Dedicated` uses the storage resource group. |
| `backupVaultName` | Empty | Override the new vault name. Blank uses shared regional or dedicated identifier-based naming. |
| `backupResourceGroupName` | Empty | Override the operations resource group for `Shared` creation. Ignored for `Dedicated`. |
| `fslogixBackupRetentionDays` | `30` | Daily retention for a new policy, from 1 to 200 days. |
| `fslogixBackupTimeZone` | `UTC` | Windows time-zone ID for a new policy, for example `Eastern Standard Time`. |

To consume AVD Shared Services backup resources, pass its `fslogixBackupVaultResourceId` output
to `recoveryServicesVaultResourceId` and `fslogixBackupPolicyName` to `fileSharePolicyName`.
This add-on returns those same output names plus `fslogixBackupPolicyResourceId`.
For later shard expansion, reuse the returned vault ID and policy name, and leave
`deployFSLogixBackupVault` false. This avoids changing a shared policy while adding storage.

The shared registration module protects `profile-containers` on every deployed storage account.
It always excludes `office-containers`, including case variations, for standalone, standard,
automated, and PoC FSLogix deployments. Office shares are still created and configured normally;
this exclusion does not change Cloud Cache replication or share soft delete.

**Existing Office backup protection requires operator action.** An incremental ARM deployment
does not remove protected items omitted from the template. Stop protection for any already enrolled
Office shares through the approved backup-management process, review retention/deletion choices
separately, and ensure external backup policies or automation do not enroll them again. This
deployment does not delete existing recovery points or stop existing protection automatically.

After publication, smoke-test all four Portal choices, switch between them and Azure NetApp Files,
and check downloaded parameters for stale hidden vault IDs and creation settings. After a live
deployment, verify one profile protected item per storage account, no Office protected items,
a successful scheduled snapshot, and a profile restore. Offline checks do not establish backup
or restore success.

## Public Network Access

`paasPublicNetworkAccess` selects `Disabled`, `EnabledWithRestrictions`, or `Enabled` for newly
deployed Azure Files storage independently of `privateEndpoint`. The default `Auto` derives access
from private endpoint selection and IP rules. The Portal offers the three explicit choices, initially
Disabled with private endpoints and Enabled otherwise. `permittedIPs` can be staged in Disabled
mode without enabling public access; restricted mode denies unmatched traffic even with an empty
list. Existing `AzureServices` exceptions for backup/monitoring remain configured and can still
apply when public access is Disabled. NetApp Files and existing backup vaults are not reconfigured.
See the [shared access-mode contract](../../../docs/parameters.md#paas-public-network-access).

## NTFS and Entra Kerberos Automation

The add-on calls the same shared FSLogix storage module and scripts as the host-pool deployment.
For Azure Files, that path creates shares and configures the selected authentication method.
Identity-based authentication applies share RBAC and runs `Set-NtfsPermissionsAzureFiles.ps1` from
the temporary deployment VM. AD DS, Entra Domain Services, and Entra Kerberos Hybrid use domain
group names; Entra Kerberos Cloud Only uses Microsoft Entra group object IDs. Entra ID
storage-account-key authentication bypasses share-level and NTFS authorization, so it skips the
ACL step and does not create a deployment-helper VM.

Entra Kerberos automation follows the host-pool identity model. The temporary deployment identity
performs Azure Resource Manager and storage operations. A separate existing application-update
identity is attached to the temporary VM and is used to acquire Microsoft Graph tokens for:

- Updating storage account application manifests and private endpoint identifier URIs.
- Enabling cloud group SIDs for Entra Kerberos Cloud Only.
- Granting the storage account enterprise applications delegated Microsoft Graph consent.

The application-update identity must already have the Microsoft Graph application permissions
`Application.ReadWrite.All` and `DelegatedPermissionGrant.ReadWrite.All`. The add-on does not grant
these tenant-level permissions, matching the host-pool deployment. Connect to the correct Microsoft
Graph environment first, use `tools/Set-EntraKerberosManagedIdentityPermissions.ps1` to grant the
permissions, and use `tools/Test-EntraKerberosManagedIdentityPermissions.ps1` to validate the
identity before deployment. Neither helper selects or disconnects the Graph environment.
When automation is not selected, complete the documented manual Entra Kerberos tasks after
deployment. Multifactor authentication exclusions remain manual in either mode.

## Prerequisites

### Deployment Permissions

- The deployment principal must be able to create and delete resource groups and deploy the selected
   compute, managed identity, storage, network, Azure NetApp Files, diagnostic, and backup resources.
- The deployment principal must be able to create Azure role assignments in the temporary deployment
   resource group, storage resource group, and any selected encryption Key Vault. `Owner` on the
   selected subscription satisfies both requirements. A least-privilege deployment can instead use
   `Contributor` plus `Role Based Access Control Administrator` at every affected scope.
- The signed-in portal user must be able to read the subscriptions, resource groups, virtual networks,
   subnets, Key Vaults, workspaces, vaults, managed identities, and Microsoft Entra groups shown by the
   form selectors.
- The required resource providers must already be registered: `Microsoft.Compute`,
   `Microsoft.ManagedIdentity`, `Microsoft.Network`, `Microsoft.Storage`, and `Microsoft.KeyVault`.
   Register `Microsoft.NetApp`, `Microsoft.OperationalInsights`, and `Microsoft.RecoveryServices` when
   those features are selected.

### Baseline Environment

- When a deployment VM is required, its temporary resource group must be dedicated to this deployment and must differ from
   the storage resource group. Cleanup deletes the entire temporary resource group. A resource group
   left by a failed run may be reused to resume that same deployment, but it must not contain unrelated
   resources.
- When a deployment VM is required, an existing virtual network and subnet must be available for it. The
   subnet must resolve and reach every service selected later in the form, including private storage
   endpoints, domain controllers, Key Vault private endpoints, and Azure NetApp Files volumes.
- Azure Policy assignments must permit the template's resources, managed identities, role
   assignments, VM Run Commands, and cleanup operations, or provide compliant alternatives through
   inherited policy configuration.

### Conditional Prerequisites

- **AD DS or Microsoft Entra Domain Services:** DNS from the temporary VM subnet must resolve the
   domain and reach domain controllers. Azure Files AD operations require Active Directory Web
   Services on TCP 9389. The supplied account must be able to create or join the required computer
   objects in the selected OU. Azure NetApp Files also domain-joins the temporary VM.
- **Credentials from Key Vault:** The vault must contain `DomainJoinUserPrincipalName` and
   `DomainJoinUserPassword`, allow Azure Resource Manager template deployment, and the deployment
   principal must have `Microsoft.KeyVault/vaults/deploy/action` on the vault.
- **Entra Kerberos automation:** The existing application-update identity must already have the
   Microsoft Graph application permissions `Application.ReadWrite.All` and
   `DelegatedPermissionGrant.ReadWrite.All`, with tenant admin consent. Multifactor authentication
   exclusions remain a manual prerequisite where required.
- **Private endpoints:** A non-delegated subnet must be available. When private DNS integration is
   selected, the existing Azure Files private DNS zone must resolve from the temporary VM subnet and
   the consuming session-host networks.
- **Customer-managed keys:** An existing encryption Key Vault must be available. The deployment
   principal must be able to create keys, configure their rotation policies, and create key-scoped role
   assignments. The add-on creates one indexed key per storage account, one encryption identity, and
   the Key Vault Crypto Service Encryption User assignments.
- **Azure NetApp Files:** The subscription must be enabled for Azure NetApp Files, the selected subnet
   must be delegated to `Microsoft.NetApp/volumes`, and the temporary VM must have DNS and network
   access to the domain and SMB volumes. A reused NetApp account must already have a valid Active
   Directory connection; a reused capacity pool must match the selected service level.
- **Cloud Cache:** Remote Azure Files accounts and Azure NetApp Files volumes must be writable and
   reachable from the consuming session hosts. Azure NetApp Files cross-region replication and
   replica promotion remain external operational responsibilities.
- **Diagnostics:** The selected Log Analytics workspace must already exist and accept diagnostic
   settings from the storage resources.
- **Azure Files backup:** An existing vault and file-share policy must already exist and be usable
   by the storage accounts, or select creation of a shared/dedicated vault and policy. The principal
   needs deployment permissions in the chosen backup resource group. Never place a vault in the
   temporary deployment resource group; cleanup deletes that group.

When identity-based authentication requires it, the temporary deployment VM uses Run Command to
register domain-backed storage, update Entra Kerberos applications, grant consent, and initialize
NTFS permissions. Its identity receives only the deployment-resource-group and
storage-resource-group roles needed for that work and cleanup. Cleanup removes storage role
assignments before deleting the temporary resource group. Entra ID storage-account-key
authentication skips the temporary VM.

For Azure Files, the temporary VM remains in a workgroup unless the optional domain join is
selected for AD DS or Entra Domain Services. The scripts install the Active Directory
RSAT tools, use DNS-based DC Locator to discover an ADWS-capable domain controller, and pass the
selected server and Key Vault credentials explicitly to every Active Directory operation. The OU
path controls AD DS storage computer object placement; when it is empty, the domain's default
Computers container is used. Azure NetApp Files continues to domain join the temporary VM because
its NTFS workflow mounts SMB volumes and applies ACLs through Windows file system APIs.

The temporary VM uses the fixed local administrator name `avddeploy` and a deterministic password
derived from the subscription ID, temporary resource group name, and VM name with `uniqueString()`.
The `aA1!` prefix guarantees Windows password complexity. This allows a failed deployment to resume
against an existing temporary VM without attempting to change its administrator password. The value
is a secure nested-module parameter and is not accepted by the public template, displayed in the
portal form, or emitted as an output. Because it is reproducible from deployment metadata, it is not
equivalent to a randomly generated secret; its exposure is limited by the VM's temporary lifecycle
and private network placement. Domain credentials remain separate and are read from Key Vault only
when required.

Azure Files uses `StorageFileDataSmbShareContributor` as the default share permission and grants
`Storage File Data Privileged Contributor` to each administrator group. The NTFS initialization
script applies the user-group and sharding restrictions within the shares.

AD DS, Entra Domain Services, and Azure NetApp Files require domain credentials. Entra Kerberos
Hybrid does not domain-join the storage account or temporary VM and does not require credentials for
basic authentication setup. Credentials are requested only when group-scoped NTFS access or
permission-based sharding requires the deployment to resolve synchronized AD group names to their
on-premises SIDs. The lookup account needs read access to domain and group information, not computer
join permissions. The portal form accepts secure manual entry or reads the fixed
`DomainJoinUserPrincipalName` and `DomainJoinUserPassword` secret names from the selected Key Vault.
Direct Bicep deployments can likewise use the Key Vault resource ID or the secure credential
parameters. Entra Kerberos Cloud Only and private Entra Kerberos Hybrid deployments also require the
application-update identity used by the host-pool deployment path.

NTFS access scope, sharding, user groups, and administrator groups are selected on Storage
Configuration. Standard FSLogix access allows Authenticated Users to create profile directories at
the storage root while Creator Owner permissions isolate each user's profile contents. Group-scoped
access replaces the Authenticated Users entry with the selected groups. Group selection uses the
Microsoft Entra IAM object picker and returns each group's object ID and display name to the
deployment. Microsoft Entra Kerberos supports permissions-based sharding only; AD DS and Microsoft
Entra Domain Services also support FSLogix Object Specific Settings.

## Required Outputs

### Profile and Office storage accounts

With `ProfileOfficeContainer` or `CloudCacheProfileOfficeContainer`, Azure Files always creates
separate Profile and Office accounts. There is one account per role without sharding, or one
paired account per role for each shard group. Both arrays use the same group ordering and
`storageIndex`. `fslogixProfileStorageAccountNamePrefix` is the sole Profile prefix input;
blank requests generated naming.
`officeStorageAccountNamePrefix` independently overrides Office names and must differ from Profile.
CMK creates distinct indexed keys for both roles using the same encryption identity.
Office shares are never enrolled in backup.

| Parameter | Default | Allowed values |
| --- | --- | --- |
| `fslogixOfficeStorageTier` | `Inherit` (Profile media) | `Inherit`, `Standard`, `Premium` |
| `fslogixOfficeStorageRedundancy` | `Inherit` (Profile redundancy) | `Inherit`, `LocallyRedundant`, `ZoneRedundant` |
| `fslogixOfficeShareSizeInGB` | `0` (effective Profile quota) | `0` or a quota valid for the Office billing model |

The Portal defaults new Azure Files deployments to **Premium (SSD) + Provisioned v2**.
Bicep omission preserves backend `AzureFiles`, Standard Profile media, `LocallyRedundant`, 100 GiB and `Legacy` billing.
`fslogixProfileStorageBillingModel` accepts `Legacy` or `ProvisionedV2` (default `Legacy`).
`fslogixOfficeStorageBillingModel` accepts those plus `Inherit` (default), which uses Profile billing.
`Inherit` tier uses the effective Profile tier. These account/billing combinations are supported:

| Tier | Media / billing | Account kind | Account SKUs |
| --- | --- | --- | --- |
| `Standard` | HDD / pay-as-you-go | `StorageV2` | `Standard_LRS`, `Standard_ZRS` |
| `Premium` | SSD / provisioned v1 | `FileStorage` | `Premium_LRS`, `Premium_ZRS` |
| `Standard` | HDD / provisioned v2 | `FileStorage` | `StandardV2_LRS`, `StandardV2_ZRS` |
| `Premium` | SSD / provisioned v2 | `FileStorage` | `PremiumV2_LRS`, `PremiumV2_ZRS` |

`StorageV2` is an account kind, **not** the provisioned v2 billing model. Only LRS/ZRS are offered.
The nonnullable `fslogixProfileShareSizeInGB` and `fslogixProfileStorageRedundancy` are the sole
Profile quota and redundancy inputs, matching standard and automated host pools.
`fslogixProfileStorageAccountNamePrefix` is the sole Profile prefix input; blank requests generated
naming. The generic prefix alias is removed. `fslogixStorageService` accepts only `AzureFiles` or
`AzureNetAppFiles`. `fslogixProfileStorageTier` selects Azure Files media; `fslogixNetAppServiceLevel`
independently selects NetApp Standard/Premium service level (default Premium), including the filter
for an existing capacity pool. Profile media is ignored with NetApp and NetApp service level is ignored
with Azure Files. NetApp rejects nondefault Azure Files billing, performance, redundancy and Office
overrides, and uses the Profile quota for both volumes. Old tuning aliases, composite backend/tier
values and explicit null tuning values are no longer accepted. Forms export canonical names only.
Shared authentication, sharding, count, groups and index are unchanged.

Profile account outputs are `profileStorageAccountResourceIds` and the configuration object's
`localProfileStorageAccountResourceIds` / `remoteProfileStorageAccountResourceIds`. The remote input
is `remoteProfileStorageAccountResourceIds`; Office arrays remain separate. See
[contract migration](../../../docs/design.md#consumer-contract-migration-and-consistency) before
updating saved files or output-consuming automation.

`fslogixProfileProvisionedIops`, `fslogixProfileProvisionedThroughputMiBps`,
`fslogixOfficeProvisionedIops` and `fslogixOfficeProvisionedThroughputMiBps` default to `0`.
Zero calculates recommended sizing from each role's own quota, not by copying Profile performance
to Office. Nonzero performance requires v2. V2 quotas are 32–262144 GiB; legacy maximum remains
102400 GiB (Premium minimum 100 GiB). V2 SSD permits 3000–102400 IOPS and 100–10340 MiB/s;
HDD permits 500–50000 IOPS and 60–5120 MiB/s. Azure NetApp Files retains its service-level and
volume behavior; nondefault Azure Files-only tuning is rejected. Verify cloud/subscription/region
SKU availability; no Commercial-only billing gate is imposed. There is **no automatic data
migration or account SKU conversion**. See Microsoft's
[Azure Files account and billing model definitions](https://learn.microsoft.com/en-us/azure/storage/files/storage-files-scale-targets#storage-account-data-plane-limits).

Cloud Cache retains its existing support and tier choices. Microsoft's
[virtual-desktop workloads guidance](https://learn.microsoft.com/en-us/azure/storage/files/virtual-desktop-workloads#fslogix-profile-containers)
recommends SSD file shares for FSLogix Cloud Cache because of their lower latency and higher IOPS.
This is operational guidance, not a new deployment restriction: Standard/HDD is not silently
blocked, upgraded, or migrated, and existing defaults remain unchanged. Size and load-test both
Profile and Office storage against representative user concurrency and sign-in workloads.

Office settings are Azure Files-only; Azure NetApp Files retains its separate-volume behavior.
The Portal checks Office ZRS against the effective Office tier, including when Profile redundancy
is inherited. Scripted deployments must verify regional tier/redundancy availability.
See the [Office separation example](../../../customer-examples/parameters/add-ons/fslogixStorage-office.parameters.json);
copy it into `customer/parameters/` and customize it before use.

For Cloud Cache with Office containers, pair `remoteOfficeStorageAccountResourceIds` with
`remoteProfileStorageAccountResourceIds`, one-for-one in shard order. The role arrays must not overlap;
omit both when remote storage is not selected. Local outputs `profileStorageAccountResourceIds` and
`officeStorageAccountResourceIds` contain Profile-only and Office-only IDs respectively.
The configuration object uses `localOfficeStorageAccountResourceIds` and
`remoteOfficeStorageAccountResourceIds` alongside the existing Profile fields.

Pass both role arrays to consumers and host-pool expansion. Standard host pools use
`fslogixExistingLocalProfileStorageAccountResourceIds` / `fslogixExistingLocalOfficeStorageAccountResourceIds`
and `fslogixExistingRemoteProfileStorageAccountResourceIds` / `fslogixExistingRemoteOfficeStorageAccountResourceIds`.
There is no fallback to Profile IDs.

Changing defaults or enabling separation does not migrate data, rename accounts, delete old
resources, or remove existing Office backup protection. Preserve an existing Profile prefix
explicitly before updating an existing deployment; arrange data migration and removal of previously
enrolled Office backup items through the approved operator process.

The add-on outputs a `fslogixConfiguration` object accepted directly by
`deployments/automatedHostPools/policy/main.bicep`:

```bicep
output fslogixConfiguration object = {
  identitySolution: identitySolution
  storageService: storageService
  containerType: containerType
  fileShareNames: fileShareNames
  localProfileStorageAccountResourceIds: profileStorageAccountResourceIds
  remoteProfileStorageAccountResourceIds: remoteProfileStorageAccountResourceIds
  localOfficeStorageAccountResourceIds: officeStorageAccountResourceIds
  remoteOfficeStorageAccountResourceIds: remoteOfficeStorageAccountResourceIds
  localNetAppServerFqdns: netAppServerFqdns
  remoteNetAppServerFqdns: remoteNetAppServerFqdns
  objectSpecificSettingsGroups: objectSpecificSettingsGroups
  profileSizeInMBs: profileSizeInMBs
}
```

It also outputs Azure Files storage account IDs, Azure NetApp Files volume IDs, and ANF SMB server
FQDNs for monitoring, backup, RBAC, and operational integration.

## Security Requirements

1. Automated session hosts use identity-based SMB authentication for AD DS, Entra Domain Services,
   and Entra Kerberos. Entra ID key mode retrieves keys at deployment time; the add-on never outputs
   storage keys, SAS tokens, or credentials.
2. Public network access is disabled when private endpoints are selected.
3. For customer-managed encryption, the selected Key Vault must exist and the deployment principal
   must be authorized to create keys and key-scoped role assignments. The add-on creates the keys,
   encryption identity, and role assignments before storage accounts consume them.
4. Storage admin and user permissions are assigned to Microsoft Entra groups, not individual users.
5. The generated VM administrator password and domain credentials are secure parameters and are
   not retained in deployment outputs.
6. The temporary deployment identity removes external role assignments before deleting its own
   resource group. Failed cleanup is visible through the deployment Run Command resources.
