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
| SHP-001 | Open | User Profiles / Azure NetApp Files | The `configureSessionHostsHeader` visibility expression references `steps('hosts').configureSessionHosts`; the control belongs to `steps('userProfiles').configureSessionHosts`. | The Session Host Configuration heading can fail to appear or produce a Form View expression error in the Azure NetApp Files workflow. | `deployments/hostpools/uiFormDefinition.json`; change the expression to the User Profiles step and validate in Form View Sandbox. |
| SHP-002 | Open | User Profiles / group selectors | Several selectors use `keyPath: "displayName"`, but their picker transforms return objects shaped as `{ id, name }`. | Selected group labels can render incorrectly and selector behavior may be unreliable. | Check the Azure Files, Azure NetApp Files, and Share Management selectors in `deployments/hostpools/uiFormDefinition.json`; align `keyPath` with `name` or change the transform shape consistently. |
| SHP-003 | Open | User Profiles / group selectors | Several selector `barColor` and `link` expressions test the entire `BladeInvokeControl` instead of its transformed group collection. | Empty selections can be shown as valid or produce misleading action text. | Replace checks such as `empty(...groupPickerBlade)` with checks against `...groupPickerBlade.transformed.groups`, then validate empty and populated states. |
| SHP-004 | Open | User Profiles / Azure Files | The standard form exposes storage redundancy but does not expose `fslogixSoftDeleteRetentionDays` or `fslogixStorageKerberosEncryptionType`, although both parameters exist in the standard host-pool template. | Portal users cannot configure supported Azure Files retention and Kerberos encryption settings and must rely on defaults or parameter files. | Add controls and output mappings, then validate both settings in Form View Sandbox. |
| SHP-005 | Investigate | User Profiles / existing storage | Existing-storage count validation depends on `storageCount` derived from selected groups and sharding choices. The behavior should be tested when controls are hidden, when no groups are selected, and when Storage Account Keys forces one account. | Incorrect count evaluation could block valid configure-only deployments or allow mismatched storage/group assignments. | Exercise Azure Files configure-only combinations in Form View Sandbox and compare emitted parameters with the template requirements. |
| SHP-006 | Investigate | User Profiles / Azure NetApp Files | Existing volume IDs are converted to SMB server FQDNs by matching resource IDs against expected share names. | Custom or pre-existing volume names that do not contain `profile-containers` or `office-containers` may be omitted from session-host configuration. | Review `deployments/hostpools/modules/hosts/modules/getNetAppVolumeSmbServerFqdns.bicep`; validate custom volume names and replace name-based ordering with explicit selected order or metadata if needed. |
| SHP-007 | Open | Zero Trust / disk encryption | The Session Host Disk Encryption Key Management dropdown has a static default of `Platform-Managed and Customer-Managed Keys protected by HSM`, but the Confidential VM allowed-values expression excludes that option. | Changing Security Type to Confidential VM can leave the dropdown with a default or selected value that is not in its allowed values, potentially blocking Form View validation. | Make `defaultValue` security-aware or reset the selection when the security type changes; validate Standard, Trusted Launch, and Confidential VM transitions in Form View Sandbox. |

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
