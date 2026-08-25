# Standard Host Pool Issues

This document tracks discrepancies and potential defects discovered in the standard host-pool deployment while developing and validating the automated host-pool deployment. These items are intentionally recorded for later correction and are not fixed unless their status says otherwise.

## Status Values

- **Open** - Confirmed discrepancy that still needs correction.
- **Investigate** - Suspected issue that needs focused validation.
- **Resolved** - Corrected and validated.
- **Not an issue** - Reviewed and determined to be intentional or valid.

## Findings

| ID | Status | Area | Finding | Impact | Evidence / Proposed Follow-up |
| --- | --- | --- | --- | --- | --- |
| SHP-001 | Resolved | User Profiles / Azure NetApp Files | The `configureSessionHostsHeader` visibility expression referenced `steps('hosts').configureSessionHosts`; the control belongs to `steps('userProfiles').configureSessionHosts`. | The Session Host Configuration heading could fail to appear or produce a Form View expression error in the Azure NetApp Files workflow. | Corrected the expression to use the User Profiles step. The automated form already references its owning `steps('profiles').configureSessionHosts` control and is not affected. |
| SHP-002 | Resolved | User Profiles / group selectors | Four selectors used `keyPath: "displayName"`, but their picker transforms return objects shaped as `{ id, name }`. | Selected group labels could render incorrectly and selector behavior could be unreliable. | Changed the desktop assignment, Azure Files, Azure NetApp Files, and Share Management group selectors to `keyPath: "name"`. All automated group selectors already use `name`; its service-principal selector correctly consumes `{ displayName, id }`. |
| SHP-003 | Resolved | User Profiles / group selectors | Four selectors had `barColor` and `link` expressions that tested the entire `BladeInvokeControl` instead of its transformed group collection. | Empty selections could be shown as valid or produce misleading action text. | Changed all eight expressions to test `.transformed.groups`. The automated form already uses the transformed group collection for equivalent selector state and is not affected. |
| SHP-004 | Resolved | User Profiles / Azure Files | Portal forms exposed inconsistent controls for soft-delete retention and Kerberos encryption even though Azure Backup applies 14-day share soft delete and the secure Kerberos default is `AES256`. | Portal deployments could diverge from the intended storage-protection defaults or expose legacy encryption choices unnecessarily. | Standard, automated, and standalone FSLogix deployments now inherit the 14-day soft-delete and `AES256` Kerberos defaults from Bicep. The automated and standalone soft-delete controls were removed; standard never exposed one. The automated Kerberos selector was also removed. |
| SHP-005 | Resolved | User Profiles / existing storage | Existing-storage count validation depended on a computed `storageCount` slider whose default became invalid when sharding had no selected groups. Automated validation also did not explicitly account for Storage Account Keys and lacked remote-account cardinality validation. | Incorrect count evaluation could block valid configure-only deployments or allow mismatched storage/group assignments. Automated sharding was also limited to two accounts by leaf-module decorators. | Removed the standard computed slider and applied the derived count directly, with one account while groups are empty or when Storage Account Keys/no sharding is used. Added matching local/remote validation and Bicep guards to both entries, normalized automated Storage Account Keys arrays to one account, and removed the automated two-account limit. |
| SHP-006 | Resolved | User Profiles / Azure NetApp Files | Existing volume IDs were converted to SMB server FQDNs by matching resource IDs against expected share names. | Custom or pre-existing volume names that did not contain `profile-containers` or `office-containers` were omitted from session-host configuration. | The shared resolver now preserves selected input order and validates one volume per FSLogix share. Both forms always emit arrays, enforce one or two selected volumes as appropriate, and identify profile-then-Office ordering. The shared fix covers standard and automated host pools. |
| SHP-007 | Resolved | Zero Trust / disk encryption | The Session Host Disk Encryption Key Management dropdown had a static double-encryption default that Confidential VM excludes. The hidden Confidential OS Disk Encryption checkbox could also retain `true` outside Confidential VM. | Security-type transitions could leave an invalid dropdown selection, show Confidential VM-only controls, or emit Confidential VM encryption for Standard and Trusted Launch hosts. | Made the standard default security-aware, gated Confidential VM state and controls by security type, and normalized emitted Confidential VM key management to `PlatformManaged` or `CustomerManagedHSM`. Automated already had a dynamic default; its output now also normalizes stale transitions to `CustomerManagedHSM`. |
| SHP-008 | Resolved | Operations / Azure Files backup | Standard and Shared Services allowed up to 365 days for daily snapshot retention, while Microsoft documents a 200-day maximum for snapshot-tier daily recovery points. | Values above the service limit could fail policy deployment or produce an unsupported policy. | Capped the shared FSLogix snapshot-policy module and Shared Services input at 200 days. Standard retains 365 days for Personal VM backup but limits pooled Azure Files policy creation to 200 in both Form View and Bicep. Automated and standalone FSLogix deployments only register with existing policies and are not affected. |

## Intentional Automated Host Pool Differences

These differences are deliberate and should not be filed as standard host-pool defects:

| Area | Difference | Reason |
| --- | --- | --- |
| Credentials | The automated host-pool form requires a predeployed credentials Key Vault and does not offer manual credential entry. | Native Session Host Configuration requires credentials to be available from Key Vault, and the automated deployment must not submit secret values through Form View. |
| Encryption Key Vault | The automated host-pool form requires an existing encryption Key Vault for customer-managed disk or FSLogix storage encryption. | Shared Services owns Key Vault creation and automated deployments compose existing shared prerequisites rather than create security resources inline. |
| Host-pool type | The automated deployment does not include Personal host-pool messaging or controls. | The current automated implementation deploys pooled host pools only. |
| FSLogix application | The automated deployment configures FSLogix through policy for lifecycle-managed session hosts. | Native session-host replacement requires configuration to be reapplied to newly created VMs without redeploying the host pool. |

## Adding Findings

Add new findings with the next `SHP-###` identifier. Include the affected file or module, observable impact, and the smallest validation needed to confirm or close the item.
