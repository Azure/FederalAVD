# Automated Host Pool PowerShell Scripts

This directory contains scripts owned by the automated host pool policy workflow. Shared scripts
used by both host pool implementations are documented in the
[shared scripts reference](../../shared/scripts/README.md).

## Policy-Managed Session Host Configuration

### [Initialize-SessionHost.ps1](Initialize-SessionHost.ps1)

Configures a policy-created automated session host after VM provisioning.

- **Used by:** The shared Session Host Policy `ConfigureSessionHost` nested Run Command template
- **Parameters:** `StorageSuffix`, `TimeZone`, GPU flags, and FSLogix storage settings including
  `ConfigureFSLogix`, `CloudCache`, `IdentitySolution`, local and remote storage locations,
  `OSSGroups`, `Shares`, `SizeInMBs`, and `StorageService`
- **Behavior:** Configures time zone, GPU settings, FSLogix Profile and ODFC containers, Cloud Cache,
  Object Specific Settings, Defender exclusions, and Entra Kerberos policy as selected; also resizes
  the operating-system partition.

This isn't the same script as
[deployments/shared/scripts/Initialize-SessionHost.ps1](../../shared/scripts/Initialize-SessionHost.ps1).
The shared implementation is used for directly managed standard session hosts and also downloads and
installs the AVD agent using a host pool registration token. Automated host pool VMs are joined and
registered by the policy-governed provisioning workflow, so this solution-owned implementation only
applies post-provisioning host configuration.

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
