# Copilot Task Brief — Make First Deployment Mistake-Proof (FederalAVD)

> **Use:** Run in GitHub Copilot **agent mode** (VS Code or the coding agent), or save as `.github/prompts/improve-onboarding.prompt.md`. This updates **docs and prompts only** — no deployment templates. One PR per task group.

## Context

Repo: **Azure/FederalAVD** — AVD deployment automation for Commercial, Gov, Secret, Top Secret. Read `.github/copilot-instructions.md` first for the repo model; don't restate it.

The docs are extensive and accurate. The problem is **not** missing content — it's that first-timers still make avoidable mistakes because:

1. **Choice overload before the first win** — tiers (1–4), a decision tree, three deployment methods, and Steps 0–4 all appear before the user has deployed anything once.
2. **Predictable footguns that fail silently at deploy time**, with the fix buried in `docs/troubleshooting.md` (unopened until after failure). The top five, all already hinted at in the docs:
   - **Storage data-plane RBAC** — `Owner`/`Contributor` assumed sufficient; shared-key access is disabled, so **Storage Blob Data Contributor** is required.
   - **Key Vault data-plane RBAC** — CMK needs **Key Vault Crypto Officer** (control plane ≠ data plane).
   - **`timeStamp`** left in saved parameter files, breaking auto-versioning.
   - **`customer/` workflow** — editing `customer-examples/` in place, or expecting git to track the git-ignored `customer/`.
   - **Out-of-order sequencing** — Image Management before Key Vaults when using CMK.

## Goal

Make the golden path impossible to get wrong, and make the top five mistakes fail fast with the fix — **without adding doc surface area**. Sharpen and cross-link existing pages; don't create new ones. Success = a first-timer with an existing VNet reaches a working host pool with no human help.

## Principles

- One obvious path for beginners; branches stay, but out of the way.
- Catch mistakes inline at the point of action, not only in troubleshooting.
- Every gotcha gets a one-liner: "if *symptom*, it's because *cause* — *fix*."
- No fabrication — reuse only roles, params, paths, and commands that exist. Mark gaps `TODO(author):`.
- Keep multi-cloud facts correct (Blue Button unavailable air-gapped, `-Environment`, endpoints) and match existing voice/nav bar.

## Tasks

**1 — "Your First Deployment" golden path.** `docs/quick-start.md` (new section *above* the tier table) + a one-line `README.md` pointer. One zero-branch scenario: existing VNet, marketplace image, PowerShell, no CMK, defaults elsewhere. ~12 copy-pasteable steps ending in a live host pool, with an explicit "ignore tiers/Steps 0–3/Template Specs/CMK for now" note. *Done:* a reader reaches a deployed host pool from this section alone, without entering the decision guide.

**2 — 60-second preflight.** `docs/quick-start.md` (callout in Essential Prerequisites, linked from Task 1). Yes/no checks that catch silent failures up front: subscription role **including the data-plane roles**, `Microsoft.DesktopVirtualization` registered, VNet+subnet, AVD user group, `Az` module, correct `-Environment`. Reference a `tools/` validation script if one exists; otherwise `TODO(author):` — don't invent one. *Done:* each item is verifiable in under a minute and maps to an error it prevents.

**3 — Inline gotcha callouts.** `docs/quick-start.md`, `docs/hostpool-deployment.md`, `docs/image-build.md`. Put a consistent **⚠️ Common mistake** callout at each footgun's point of action for all five gotchas above. *Done:* each appears exactly once, inline, in "if *symptom* → *cause* → *fix*" form.

**4 — Harden the Copilot prompt.** `.github/prompts/getting-started.prompt.md`. Instruct Copilot to ask 2–3 diagnostic questions first (existing VNet? marketplace/custom? CMK? which cloud?), route to exactly one path, default beginners to the Task 1 golden path, and warn about the relevant gotchas. *Done:* given "I want to deploy AVD," it asks first and lands one next step + warnings — not the full tier table.

**5 — Default to generated parameter files.** `docs/quick-start.md`. Promote "generate parameter files from the Template Spec UI" from a buried tip to the recommended first-param-file method (built-in validation, no hand-edited JSON); keep hand-authoring as the alternative and keep the `timeStamp` removal warning. *Done:* beginners are steered to generate-then-save before hand-editing.

**6 — Surface mistakes + troubleshooting early.** `docs/quick-start.md`, `docs/README.md`, `README.md`. Add a compact **"Top 5 first-deployment mistakes"** list (one line each) linking into `docs/troubleshooting.md` anchors, reachable within one click of the first screen. *Done:* troubleshooting is linked from the golden path and preflight, not just the index.

## Guardrails

- Touch only `docs/` and `.github/prompts/` (+ the `README.md` pointers named above). **Never** `deployments/`, `policy/`, `tools/`, or `customer/`.
- Extend existing pages; no new top-level docs unless a task says so.
- Preserve every link and the nav bar; don't break relative paths when inserting.
- No fabricated roles, params, resource names, commands, or scripts — mark `TODO(author):` when unsure, especially for air-gapped claims.

## Done + PRs

First-timer reaches a working host pool from the golden path alone; all five gotchas caught by preflight or inline callout; the Copilot prompt asks before it answers; no template/policy/customer file touched. Split into: **PR A** = Tasks 1, 2, 5 · **PR B** = Tasks 3, 6 · **PR C** = Task 4.

**PR title:** `docs: make first deployment mistake-proof — golden path, preflight, inline gotchas, diagnostic Copilot prompt`
