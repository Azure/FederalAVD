---
name: federalavd-windows-policy-validation
description: "Create, modify, review, and validate Windows policy settings in FederalAVD scripts and artifacts. Use when changing Optimize-AVDImage.ps1, Registry.pol writes, policy registry values, Windows services or scheduled tasks used as policy controls, ADMX-backed settings, default-user policies, Start/Search behavior, or restricted-network Windows configuration."
argument-hint: "[script, policy, or intended Windows behavior]"
---

# FederalAVD Windows Policy Validation

Use this workflow for Windows operating-system and Microsoft product policy settings in deployment
scripts and image artifacts. It applies to ADMX-backed Registry.pol entries, direct policy-registry
writes, default-user policy, and service or task changes intended to enforce policy behavior.

## Evidence Standard

Do not infer behavior from registry value names, existing repository code, generated ARM JSON,
community optimization lists, search results, or third-party examples. Existing code is an
implementation to verify, not an authority.

A policy change requires both of these sources:

1. The current ADMX file and matching language ADML file from the target Windows build or installed
   product policy package.
2. Current official Microsoft Learn, Policy CSP, product policy, or product-group documentation.

If the sources conflict, are version-mismatched, or do not document the intended outcome, stop and
report the uncertainty. Do not implement a plausible substitute. For a setting with no ADMX backing,
require explicit official Microsoft or vendor registry documentation and label it as non-ADMX.

## Procedure

1. State the exact intended behavior and the behavior that must remain available. Identify the target
   Windows build, edition, optimization profile, user type, and connected or air-gapped context.
2. Locate the policy in the target system's `%SystemRoot%\PolicyDefinitions` ADMX and matching
   locale ADML. For Edge, Office, OneDrive, or another separately serviced product, use the policy
   templates matching the installed product version.
3. Record the policy friendly name, explanation text, policy class, category path, registry key,
   value name, value type, enabled value, disabled value, supported-on declaration, and any option
   or list elements. Do not assume that `0` means disabled or `1` means enabled.
4. Corroborate the mapping and effect with current official Microsoft documentation. Prefer the
   generated Policy CSP reference for exact scope, edition, build, and Group Policy mappings, then
   use product documentation for behavior and side effects.
5. Distinguish the controlling policy from adjacent policies. For example, cloud organizational
   search, web results, Search highlights, consumer suggestions, and Microsoft Store availability
   are separate controls. Do not broaden the change to make an uncertain result disappear.
6. Confirm Computer versus User scope. Route Computer policy to Machine Registry.pol and User policy
   to User Registry.pol or the repository's established default-user mechanism. A machine value at
   a user-only path is not equivalent.
7. Check precedence and profile coverage. Identify domain or MDM policy that can override local
   policy, existing duplicate writes, intentional later overrides, and every profile or air-gapped
   combination that should receive the setting.
8. Add a nearby comment naming the ADMX policy, non-obvious value semantics, supported-edition
   limitation, material side effect, and an official reference. Update the owning README when the
   setting changes user-visible behavior or deliberately deviates from Microsoft VDI guidance.
9. Add focused static tests for the exact path, value, type, scope, profile coverage, and duplicate
   guard. Static tests establish that the intended configuration is emitted; they do not prove the
   Windows client honors it as expected.
10. For scripts embedded with `loadTextContent`, regenerate the tracked ARM JSON from Bicep and run
    the repository Bicep/ARM synchronization check. Never hand-edit the embedded script in JSON.
11. Run PowerShell parser tests and the repository's ASCII-only check after every `.ps1` edit.
12. Validate user-visible outcomes on a representative supported Windows build after required
    restart, sign-in, or new-profile creation. Verify effective policy with `gpresult`, `rsop.msc`,
    or the resulting policy registry data, then test both the blocked behavior and preserved
    behavior. If live validation is unavailable, state that clearly and do not claim the UX issue is
    fixed.

## Completion Report

Report the two authoritative sources used, exact policy mapping, supported scope and editions,
profiles affected, preserved behavior, executable validation, and whether live Windows behavior was
verified. Separate proven configuration facts from expected client behavior.
