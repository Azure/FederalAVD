---
name: federalavd-compliance-review
description: "Review FederalAVD configuration evidence against documented NIST, FedRAMP High, DoD IL4 or IL5, CMMC, HIPAA, CJIS, StateRAMP, IRS 1075, ISO 27001, or Zero Trust mappings. Use when assessing parameter files, identifying control gaps, or producing a control-to-feature evidence table."
argument-hint: "[framework and parameter files]"
---

# FederalAVD Compliance Review

This skill produces engineering evidence, not an authorization, attestation, or certification.

## Procedure

1. Ask for the target framework, impact level, Azure cloud, workload type, and all deployment
   parameter files in scope.
2. Read `docs/compliance.md` as the repository authority and verify cited external framework or
   Azure requirements against current official sources when the conclusion depends on them.
3. Collect relevant parameter evidence across all supplied files:

   ```powershell
   & .github/skills/federalavd-compliance-review/scripts/Get-ComplianceParameterEvidence.ps1 `
     -ParameterPath <security-parameters>,<image-management-parameters>,<host-pool-parameters>
   ```

4. Separate controls into automatic, configurable, partial, external, and out of scope. Do not
   describe a configurable control as implemented without parameter or deployed-resource evidence.
5. Map each control to the exact Bicep resource, parameter value, diagnostic setting, policy, or
   external responsibility that provides evidence.
6. Account for conditional applicability such as pooled versus personal backup, Commercial versus
   Government regions, and Dedicated Host requirements in IL5 Government regions.
7. Surface documented gaps, including supplemental Windows Security event collection, MFA and
   Conditional Access, SIEM integration, ASR where required, and organizational procedures.
8. Identify absent or conflicting parameter evidence as **Not verified**, not automatically
   non-compliant. Defaults must be confirmed in the exact deployed template version.
9. Produce a table with control, requirement, implementation type, evidence, status, gap, and owner.
10. State the review scope, source versions or retrieval dates, assumptions, and required assessor
    validation. Never claim that FederalAVD alone guarantees compliance.

See [review boundaries](./references/review-boundaries.md) before reporting conclusions.
