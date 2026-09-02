---
mode: ask
description: Guide me through getting started with FederalAVD — deployment path, prerequisites, and first steps.
---

I am new to this repo and want to deploy Azure Virtual Desktop using FederalAVD. For a first
deployment, guide me through the Template Spec portal forms so I can use their dynamic validation,
deploy successfully, and retain the generated parameter files for later PowerShell or CI/CD use.

**Before giving me a plan, ask me these five questions and wait for all my answers:**

1. **Which Azure cloud?** Commercial, Government, Government Secret, or Government Top Secret? *(Blue Button UI is only available for Commercial and Government.)*
2. **Do you need custom software baked into an image, applied to session hosts at runtime, or not at all?** *(Runtime artifact hosting can use Step 2 without Step 3.)*
3. **Do you already have a VNet and subnet ready?** *(If yes, you can skip Step 0.)*
4. **Must shared Key Vault, monitoring, or FSLogix backup resources exist before the first host pool?** *(Step 1 is required before automated host pools and Image Management CMK. A first standard Step 4 deployment can instead create resources for later standard host pools to reuse.)*
5. **Should FSLogix profile storage be dedicated to each host pool, selected from existing storage, or independently deployed and shared across host pools?** *(The FSLogix Storage add-on can create shared profile storage, but its selected Key Vault, Log Analytics workspace, and backup vault/policy must already exist.)*

Once I answer, give me **exactly one next step** - not a menu. Route me as follows:

- **Existing VNet + marketplace images -> standard PoC:** Start with the standard Host Pool Template Spec portal form. Tell me to select **Create** on **Review + create**, then download its generated template and parameters after submission and save the parameter file under `customer/parameters/hostpools/`. Do not start with PowerShell or hand-edited JSON.
- **Multiple standard host pools with shared supporting resources:** The first Step 4 deployment can create Key Vaults, monitoring, and the FSLogix backup vault/policy. Later standard host-pool forms should select those existing resources. Do not require Step 1 unless the resources must exist before the first host pool.
- **Automated host-pool PoC:** Deploy AVD Shared Services with the Secrets Key Vault enabled first, then pass its `secretsKeyVaultResourceId` output to `credentialsKeyVaultResourceId` in the automated Host Pool deployment.
- **Need networking:** Start with Step 0, then continue to the appropriate next step.
- **Need runtime artifacts without a custom image:** Step 2 (imageManagement) -> Step 4 (hostPool).
- **Need a custom image, no Image Management CMK or centralized monitoring prerequisite:** Step 2 (imageManagement) -> Step 3 (imageBuild) -> Step 4 (hostPool).
- **Need Image Management artifact storage or gallery image versions protected by CMK:** Step 1 (sharedServices) first, then Step 2 -> Step 3 only when building an image -> Step 4.
- **Need independently deployed shared FSLogix storage with no CMK, diagnostics, or backup, or with all prerequisite IDs already available:** FSLogix Storage add-on -> Step 4 for each consuming host pool.
- **Need independently deployed shared FSLogix storage and FederalAVD must create its CMK, monitoring, or backup prerequisites:** Step 1 -> FSLogix Storage add-on -> Step 4 for each consuming host pool.
- **Azure Government Secret or Top Secret:** Recommend Step 1 by default, then Step 2 -> Step 3 -> Step 4. Omit Step 1 only when the user identifies approved shared Key Vault, Log Analytics, DCR/DCE, diagnostics, and key-management services that provide equivalent documented control coverage.
- **Air-gapped (Secret/Top Secret):** Blue Button is unavailable. Use Template Spec + Portal UI or PowerShell. Pass `-Environment AzureUSGovernment` (or the appropriate environment name) to `Connect-AzAccount`.

For each required component:

1. Tell me which Template Spec to deploy.
2. Explain only the decisions visible in that form that affect my selected path.
3. Tell me to select **Create** on **Review + create**, then download the generated template and
   parameters after submission.
4. Give me the exact destination under `customer/parameters/`. For Image Build files, remind me to remove `timeStamp`.
5. Identify only the deployment outputs needed by the next form.

Treat PowerShell and CLI as the repeat-deployment and automation path after the first successful UI
deployment. Show those commands only when I ask or after the generated parameter file is saved.

**Always include these gotcha warnings relevant to my path:**

- **Custom images / artifacts storage:** `Owner` or `Contributor` alone is not enough when the storage account disables shared key access (which is the default). Add **`Storage Blob Data Contributor`** on the artifacts storage account to the identity running `Update-ImageArtifacts.ps1` or `Deploy-ImageManagement.ps1`. Symptom: `403 AuthorizationFailure` or `This request is not authorized to perform this operation`. See [troubleshooting](../docs/troubleshooting.md#storage-blob-data-access-fails-with-403).
- **CMK / Key Vault:** `Owner` or `Contributor` does not grant Key Vault key operation rights (control plane ≠ data plane). Add **`Key Vault Crypto Officer`** on the encryption Key Vault to the deploying identity. See [troubleshooting](../docs/troubleshooting.md#key-vault-crypto-officer-missing).
- **Sequencing with Image Management CMK:** Deploy AVD Shared Services (Step 1) **before** Image Management (Step 2) when artifact/build-log storage or gallery image versions use CMK. Image Management needs the encryption Key Vault resource ID to encrypt storage and create the gallery Disk Encryption Set. A standard Step 4 deployment can create its own Key Vault and CMK resources inline. See [troubleshooting](../docs/troubleshooting.md#cmk-deployment-fails-image-management-deployed-before-key-vaults).
- **Parameter files:** Remove `timeStamp` from saved Image Build parameter files before reusing them so each build gets fresh identities. Other deployment templates no longer expose this parameter. See [troubleshooting](../docs/troubleshooting.md#timestamp-in-parameter-file-causes-stale-image-versions).
- **customer/ folder:** Copy examples from `customer-examples/` to `customer/parameters/` (or `customer/artifacts/`) before editing. Never edit examples in place. `customer/` is git-ignored by design — don't expect changes there to be tracked or pushed. See [troubleshooting](../docs/troubleshooting.md#editing-customerexamples-or-missing-customer-changes).

Do not present the full tier table, the full decision tree, all deployment methods, or all five
deployment steps unless I ask. Start with the five questions.
