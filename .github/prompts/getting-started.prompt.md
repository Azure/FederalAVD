---
mode: ask
description: Guide me through getting started with FederalAVD — deployment path, prerequisites, and first steps.
---

I am new to this repo and want to deploy Azure Virtual Desktop using FederalAVD. For a first
deployment, guide me through the Template Spec portal forms so I can use their dynamic validation,
deploy successfully, and retain the generated parameter files for later PowerShell or CI/CD use.

**Before giving me a plan, ask me these four questions and wait for all my answers:**

1. **Which Azure cloud?** Commercial, Government, Government Secret, or Government Top Secret? *(Blue Button UI is only available for Commercial and Government.)*
2. **Do you need custom software pre-installed in images, or are marketplace images sufficient?** *(If marketplace images are fine, you can skip Steps 1–3 entirely.)*
3. **Do you already have a VNet and subnet ready?** *(If yes, you can skip Step 0.)*
4. **Do you require customer-managed keys, centralized Log Analytics monitoring, or have diagnostic-settings policies assigned?** *(Any of these can require AVD Shared Services before downstream deployments.)*

Once I answer, give me **exactly one next step** - not a menu. Route me as follows:

- **Existing VNet + marketplace images -> PoC:** Start with the Host Pool Template Spec portal form. Tell me to download its generated parameter file, remove `timeStamp`, and save it under `customer/parameters/hostpools/`. Do not start with PowerShell or hand-edited JSON.
- **Need networking:** Start with Step 0, then continue to the appropriate next step.
- **Need custom images, no CMK or centralized monitoring prerequisite:** Step 2 (imageManagement) -> optional Step 3 (imageBuild) -> Step 4 (hostPool).
- **Need custom images + CMK, centralized monitoring, or diagnostic-policy prerequisite:** Step 1 (sharedServices) first, then Step 2 -> optional Step 3 -> Step 4.
- **Azure Government Secret or Top Secret:** Recommend Step 1 by default, then Step 2 -> Step 3 -> Step 4. Omit Step 1 only when the user identifies approved shared Key Vault, Log Analytics, DCR/DCE, diagnostics, and key-management services that provide equivalent documented control coverage.
- **Air-gapped (Secret/Top Secret):** Blue Button is unavailable. Use Template Spec + Portal UI or PowerShell. Pass `-Environment AzureUSGovernment` (or the appropriate environment name) to `Connect-AzAccount`.

For each required component:

1. Tell me which Template Spec to deploy.
2. Explain only the decisions visible in that form that affect my selected path.
3. Tell me to download the generated parameters before submitting the deployment.
4. Give me the exact destination under `customer/parameters/` and remind me to remove `timeStamp`.
5. Identify only the deployment outputs needed by the next form.

Treat PowerShell and CLI as the repeat-deployment and automation path after the first successful UI
deployment. Show those commands only when I ask or after the generated parameter file is saved.

**Always include these gotcha warnings relevant to my path:**

- **Custom images / artifacts storage:** `Owner` or `Contributor` alone is not enough when the storage account disables shared key access (which is the default). Add **`Storage Blob Data Contributor`** on the artifacts storage account to the identity running `Update-ImageArtifacts.ps1` or `Deploy-ImageManagement.ps1`. Symptom: `403 AuthorizationFailure` or `This request is not authorized to perform this operation`. See [troubleshooting](../docs/troubleshooting.md#storage-blob-data-access-fails-with-403).
- **CMK / Key Vault:** `Owner` or `Contributor` does not grant Key Vault key operation rights (control plane ≠ data plane). Add **`Key Vault Crypto Officer`** on the encryption Key Vault to the deploying identity. See [troubleshooting](../docs/troubleshooting.md#key-vault-crypto-officer-missing).
- **Sequencing with CMK:** Deploy AVD Shared Services (Step 1) **before** Image Management (Step 2) when using CMK. imageManagement needs the Key Vault resource ID to encrypt the compute gallery and storage account at creation time. See [troubleshooting](../docs/troubleshooting.md#cmk-deployment-fails-image-management-deployed-before-key-vaults).
- **Parameter files:** Remove `timeStamp` from any saved parameter file before reusing it — it should auto-generate fresh on every deployment run. See [troubleshooting](../docs/troubleshooting.md#timestamp-in-parameter-file-causes-stale-image-versions).
- **customer/ folder:** Copy examples from `customer-examples/` to `customer/parameters/` (or `customer/artifacts/`) before editing. Never edit examples in place. `customer/` is git-ignored by design — don't expect changes there to be tracked or pushed. See [troubleshooting](../docs/troubleshooting.md#editing-customerexamples-or-missing-customer-changes).

Do not present the full tier table, the full decision tree, all deployment methods, or all five
deployment steps unless I ask. Start with the four questions.
