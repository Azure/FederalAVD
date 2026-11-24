# Automated Host Pool PowerShell Scripts

This directory contains scripts owned by the automated host pool policy workflow. Shared scripts
used by both host pool implementations are documented in the
[shared scripts reference](../../shared/scripts/README.md).

## Policy-Managed Session Host Configuration

### [Initialize-SessionHost.ps1](Initialize-SessionHost.ps1)

Configures a policy-created automated session host after VM provisioning.

- **Used by:** The shared Session Host Policy `ConfigureSessionHost` nested Run Command template
- **Parameters:** `StorageSuffix`, `TimeZone`, GPU flags, and FSLogix storage settings including
  `ConfigureFSLogix`, `ContainerType`, `IdentitySolution`, local and remote storage locations,
  `OSSGroups`, `SizeInMBs`, and `StorageService`. `ContainerType` determines the fixed share
  names, Office-container enablement, and Cloud Cache behavior.
- **Behavior:** Configures time zone, GPU settings, FSLogix Profile and ODFC containers, Cloud Cache,
  Object Specific Settings, Defender exclusions, and Entra Kerberos policy as selected; also resizes
  the operating-system partition.

This isn't the same script as
[deployments/shared/scripts/Initialize-SessionHost.ps1](../../shared/scripts/Initialize-SessionHost.ps1).
The shared implementation is used for directly managed standard session hosts and also downloads and
installs the AVD agent using a host pool registration token. Automated host pool VMs are joined and
registered by the policy-governed provisioning workflow, so this solution-owned implementation only
applies post-provisioning host configuration.

Azure Files Profile containers use `LocalProfileStorageAccountNames` and
`RemoteProfileStorageAccountNames`. Office containers use `LocalOfficeStorageAccountNames` and
`RemoteOfficeStorageAccountNames`, never the Profile name arrays. Initialization validates one
distinct Office account per Profile shard in matching local/remote order and preserves the same
SID-index mapping. Azure NetApp Files retains its ordered Profile/Office server arrays.

The canonical remediation template also accepts storage-key `EntraId` configurations, although the
automated public entry currently exposes identity-based authentication only. Keys for each role
are supplied in Run Command `protectedParameters`: `LocalProfileStorageAccountKeys`,
`RemoteProfileStorageAccountKeys`, `LocalOfficeStorageAccountKeys`, and `RemoteOfficeStorageAccountKeys`.
The policy adapter grants its remediation identity Storage Account Key Operator at each selected
account, only for storage-key configurations. Initialization requires one account/key per role and
location, installs each credential separately as SYSTEM, and fails missing/overlapping pairs.
The initializer uses the same self-contained native `CredWriteW` helper as standard initialization
and key rotation, not `cmdkey` or a key-bearing child-process command line. Leading-slash and
quoted-looking keys retain their exact bytes. Native failures stop initialization; PowerShell
FullLanguage and permitted `Add-Type` execution are prerequisites. This does not override
domain/MDM credential-storage policy or make PowerShell telemetry secret-safe.

Custom script invocations must use the explicit Profile name/key arguments; generic local/remote
storage argument names are not aliases. Policy parameters and lifecycle tags also use explicit
Profile names; existing deployments must follow
[contract migration](../../../docs/design.md#consumer-contract-migration-and-consistency).

Storage-key mode sets the ADMX Machine **Access Network as Computer Object** policy (supported-on
`v2105`) to DWORD `1` separately at `HKLM\SOFTWARE\FSLogix\Profiles` and
`HKLM\SOFTWARE\Policies\FSLogix\ODFC`, conditioned on that role's keys. DWORD `0` means attach as
user. Microsoft cautions that computer-level access can expose every container to the host.
Identity-based behavior and existing location registry scopes/types remain unchanged; the
[official configuration reference](https://learn.microsoft.com/fslogix/reference-configuration-settings)
permits both REG_SZ and REG_MULTI_SZ for VHDLocations/CCDLocations. The mappings were checked against
the current [official FSLogix policy templates](https://aka.ms/fslogix_download) and documentation.
Validate effective settings and sign-in on supported FSLogix/Windows builds after configuration;
offline checks do not demonstrate SMB access, profile attachment, or Cloud Cache failover.

## Deployment Sequencing

### [Wait-PolicyPropagation.ps1](Wait-PolicyPropagation.ps1)

Introduces an explicit delay after policy and role assignment deployment so Azure control-plane
propagation can complete before dependent automated host pool resources are created.

- **Used by:** `modules/waitForPolicyPropagation.bicep`
- **Parameters:** `WaitSeconds`, an integer from 1 through 600
- **Behavior:** Writes the selected wait interval, waits once, and reports completion.

## Conventions

- These scripts are embedded by Bicep with `loadTextContent()` and aren't interactive utilities.
- Every PowerShell file must remain ASCII-only because Bicep embeds it in generated ARM JSON.
- Cross-solution behavior should remain in shared orchestration; this folder contains only workflow
  differences specific to policy-created automated hosts.
