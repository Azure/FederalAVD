# Standard Host Pool Secret Source Alignment Notes

## Status
- Postponed by request.
- Keep current standard host pool behavior unchanged for now.

## Objective
Align standard host pools with automated host pools for credential secret sourcing while preserving backward compatibility.

## Current Standard Behavior
- Key Vault mode takes only `existingCredentialsKeyVaultResourceId`.
- Secret names are effectively fixed by template retrieval logic:
  - `VirtualMachineAdminUserName`
  - `VirtualMachineAdminPassword`
  - `DomainJoinUserPrincipalName`
  - `DomainJoinUserPassword`
- Manual mode allows direct entry of local admin and, where applicable, domain join credentials.

## Target Behavior (Future)
Support all of the following in standard host pools:
1. Manual secret values (existing behavior).
2. Key Vault default secret names (existing behavior).
3. Optional versionless secret URI overrides (new behavior).
4. Optional portal secret picker overrides via `Microsoft.Solutions.BladeInvokeControl` (new behavior).

## Recommended Delivery Plan

### Phase 1 (Lower Risk)
Implement versionless URI override parameters in `deployments/hostpools/hostpool.bicep` with defaults that preserve current names.

Add optional params:
- `vmAdministratorUsernameSecretUri`
- `vmAdministratorPasswordSecretUri`
- `domainJoinUsernameSecretUri`
- `domainJoinPasswordSecretUri`

Rules:
- If URI param is provided, extract secret name and use that with `kvCredentials.getSecret(...)`.
- If URI param is empty, fall back to current default names.
- Preserve existing parameter and UI compatibility.

Also add validation checks similar to automated host pools where practical:
- Key Vault uses Azure RBAC.
- ARM template deployment is enabled on the Key Vault.

### Phase 2 (Higher Risk, UI)
Add optional secret picker UX to `deployments/hostpools/uiFormDefinition.json`:
- Keep current Key Vault selector.
- Add `customizeSecretNames` toggle.
- Add four optional `BladeInvokeControl` pickers and selectors.
- Enforce same-vault guardrail for overrides.
- Output versionless secret URIs to the new Bicep parameters.

Important UI safety rule:
- Avoid complex expression-valued `TextBlock.options.text` in host pool form blocks.
- Use literal text and visibility conditions to avoid portal runtime binding failures.

## Acceptance Criteria
- Existing parameter files continue to deploy without changes.
- Key Vault default-name deployments behave exactly as today.
- URI override path works for all four credential secrets.
- Secret rotation does not require template changes when using versionless URIs.
- Portal flow works for:
  - EntraId
  - ActiveDirectoryDomainServices
  - EntraDomainServices
  - EntraKerberos-Hybrid (including least-privilege NTFS and shard-per-group paths)

## Suggested Validation Matrix
- Credentials source: manual, keyVault.
- Identity mode: EntraId, AD DS, Entra DS, Entra Kerberos Hybrid.
- Storage path: deployStorage true/false.
- Least privilege NTFS: on/off.
- Sharding option: None/ShardPerms.
- Secret source variants:
  - defaults only
  - one override
  - all overrides

## Out of Scope For This Task
- No changes to runtime deployment behavior now.
- No schema or UX changes in this postponed step.

## References
- Standard host pool template: `deployments/hostpools/hostpool.bicep`
- Standard host pool form: `deployments/hostpools/uiFormDefinition.json`
- Automated host pool template: `deployments/automatedHostPools/automatedHostPool.bicep`
- Automated host pool form: `deployments/automatedHostPools/uiFormDefinition.json`
