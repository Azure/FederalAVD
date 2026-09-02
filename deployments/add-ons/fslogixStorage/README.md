# FSLogix Storage Add-On

This add-on provisions FSLogix storage independently of a FederalAVD host pool deployment. It uses
the same `deployments/shared/modules/orchestration/fslogix.bicep` module as the host pool and is
also composed by the automated host-pool deployment before policy and session-host provisioning.

## Boundary

The add-on owns profile storage configuration and the temporary resources needed to initialize it.
It creates a temporary resource group, deployment VM, user-assigned identity, and role assignments.
After storage configuration completes, the VM removes its external role assignments and deletes the
temporary resource group, including itself and its identity. The add-on does not create a host pool,
session host, policy assignment, Key Vault, Log Analytics workspace, Recovery Services vault, or
backup policy. Those shared resources are supplied by resource ID or name. AVD Shared Services can
create the regional FSLogix vault and policy before this add-on is deployed.

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
When an existing host pool is selected, its resource ID is applied as the `cm-resource-parent` tag
to newly created storage resource groups, temporary deployment resources, storage accounts, private
endpoints, NetApp resources, backup registrations, encryption keys, and the storage encryption
identity. Shared and future-host-pool modes do not apply a parent tag because no single existing
host pool owns those resources at deployment time.
Azure Files storage account prefixes use the same deterministic `fslogix${uniqueString(...)}`
calculation as the host-pool deployment and are limited to 13 characters so appending the two-digit
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

Every storage option uses a temporary deployment VM and identity. Azure Files uses the VM to set the
root NTFS security descriptor through the Azure Files REST API, including storage-account-key mode.
Domain-backed and Entra Kerberos options also use it for identity configuration, and Azure NetApp
Files uses it to set volume permissions. The form collects these temporary-resource settings near
the end, after the durable storage configuration. Cleanup removes the external role assignments and
deletes the temporary resource group after configuration.

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
| NTFS permissions | Deployment VM Run Command | Deployment VM Run Command |
| Private networking | Private endpoint | Delegated subnet |
| Customer-managed keys | Existing Key Vault; keys and identity created automatically | Managed by the NetApp account path |
| Diagnostics | Existing Log Analytics workspace | Not configured by the shared module |
| Backup | Existing Recovery Services vault and policy from AVD Shared Services or another provider | Not configured by the shared module |

For Azure Files backup, deploy AVD Shared Services with `deployFSLogixBackupVault: true`, then pass
its `fslogixBackupVaultResourceId` output to `recoveryServicesVaultResourceId` and its
`fslogixBackupPolicyName` output to `fileSharePolicyName`. The add-on owns registration of its
storage accounts and shares as protected items; it does not modify the shared vault or policy.

## NTFS and Entra Kerberos Automation

The add-on calls the same shared FSLogix storage module and scripts as the host-pool deployment.
For Azure Files, that path creates shares, configures the selected identity provider, applies share
RBAC, and runs `Set-NtfsPermissionsAzureFiles.ps1` from the temporary deployment VM. AD DS, Entra
Domain Services, and Entra Kerberos Hybrid use domain group names; Entra Kerberos Cloud Only uses
Microsoft Entra group object IDs.

Entra Kerberos automation follows the host-pool identity model. The temporary deployment identity
performs Azure Resource Manager and storage operations. A separate existing application-update
identity is attached to the temporary VM and is used to acquire Microsoft Graph tokens for:

- Updating storage account application manifests and private endpoint identifier URIs.
- Enabling cloud group SIDs for Entra Kerberos Cloud Only.
- Granting the storage account enterprise applications delegated Microsoft Graph consent.

The application-update identity must already have the Microsoft Graph application permissions
`Application.ReadWrite.All` and `DelegatedPermissionGrant.ReadWrite.All`. The add-on does not grant
these tenant-level permissions, matching the host-pool deployment. Use
`tools/Test-EntraKerberosManagedIdentityPermissions.ps1` to validate the identity before deployment.
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

- The temporary deployment resource group must be dedicated to this deployment and must differ from
   the storage resource group. Cleanup deletes the entire temporary resource group. A resource group
   left by a failed run may be reused to resume that same deployment, but it must not contain unrelated
   resources.
- An existing virtual network and subnet must be available for the temporary deployment VM. The
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
- **Azure Files backup:** The selected Recovery Services vault and file-share backup policy must
   already exist and be usable by the storage accounts being protected.

The temporary deployment VM uses Run Command to register domain-backed storage, update Entra
Kerberos applications, grant consent, and initialize NTFS permissions. Its identity receives only
the deployment-resource-group and storage-resource-group roles needed for that work and cleanup.
Cleanup removes storage role assignments before deleting the temporary resource group.

For Azure Files, the temporary VM remains in a workgroup. The scripts install the Active Directory
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

The add-on outputs a `fslogixConfiguration` object accepted directly by
`deployments/automatedHostPools/policy/main.bicep`:

```bicep
output fslogixConfiguration object = {
  identitySolution: identitySolution
  storageService: storageService
  containerType: containerType
  fileShareNames: fileShareNames
  localStorageAccountResourceIds: storageAccountResourceIds
  remoteStorageAccountResourceIds: remoteStorageAccountResourceIds
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
