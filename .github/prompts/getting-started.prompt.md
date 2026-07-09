---
mode: ask
description: Guide me through getting started with FederalAVD — deployment path, prerequisites, and first steps.
---

I am new to this repo and want to deploy Azure Virtual Desktop using FederalAVD.

**Before giving me a plan, ask me these three questions and wait for all my answers:**

1. **Which Azure cloud?** Commercial, Government, Government Secret, or Government Top Secret? *(Blue Button UI is only available for Commercial and Government.)*
2. **Do you need custom software pre-installed in images, or are marketplace images sufficient?** *(If marketplace images are fine, you can skip Steps 1–3 entirely.)*
3. **Do you already have a VNet and subnet ready?** *(If yes, you can skip Step 0.)*

Once I answer, give me **exactly one next step** — not a menu. Route me as follows:

- **Existing VNet + marketplace images → golden path:** Send me straight to [Your First Deployment](../docs/quick-start.md#your-first-deployment-golden-path) and walk me through the ~12-step PowerShell sequence. Do not show me the tier table or decision guide.
- **Need networking:** Start with Step 0, then continue to the appropriate next step.
- **Need custom images, no CMK:** Step 2 (imageManagement) → optional Step 3 (imageBuild) → Step 4 (hostPool).
- **Need custom images + CMK:** Step 1 (keyVaults) first — the Key Vault must exist before imageManagement can encrypt the gallery and storage account — then Step 2 → optional Step 3 → Step 4.
- **Air-gapped (Secret/Top Secret):** Blue Button is unavailable. Use Template Spec + Portal UI or PowerShell. Pass `-Environment AzureUSGovernment` (or the appropriate environment name) to `Connect-AzAccount`.

**Always include these gotcha warnings relevant to my path:**

- **Custom images / artifacts storage:** `Owner` or `Contributor` alone is not enough when the storage account disables shared key access (which is the default). Add **`Storage Blob Data Contributor`** on the artifacts storage account to the identity running `Update-ImageArtifacts.ps1` or `Deploy-ImageManagement.ps1`. Symptom: `403 AuthorizationFailure` or `This request is not authorized to perform this operation`. See [troubleshooting](../docs/troubleshooting.md#storage-blob-data-access-fails-with-403).
- **CMK / Key Vault:** `Owner` or `Contributor` does not grant Key Vault key operation rights (control plane ≠ data plane). Add **`Key Vault Crypto Officer`** on the encryption Key Vault to the deploying identity. See [troubleshooting](../docs/troubleshooting.md#key-vault-crypto-officer-missing).
- **Sequencing with CMK:** Deploy Key Vaults (Step 1) **before** Image Management (Step 2) when using CMK. imageManagement needs the Key Vault resource ID to encrypt the compute gallery and storage account at creation time. See [troubleshooting](../docs/troubleshooting.md#cmk-deployment-fails-image-management-deployed-before-key-vaults).
- **Parameter files:** Remove `timeStamp` from any saved parameter file before reusing it — it should auto-generate fresh on every deployment run. See [troubleshooting](../docs/troubleshooting.md#timestamp-in-parameter-file-causes-stale-image-versions).
- **customer/ folder:** Copy examples from `customer/examples/` to `customer/parameters/` (or `customer/artifacts/`) before editing. Never edit examples in place. `customer/` is git-ignored by design — don't expect changes there to be tracked or pushed. See [troubleshooting](../docs/troubleshooting.md#editing-customerexamples-or-missing-customer-changes).

Do not present the full tier table, the full decision tree, or all five deployment steps unless I ask. Start with the three questions.
