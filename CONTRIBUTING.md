# Contributing to FederalAVD

Use this guide for contributions made manually or with GitHub Copilot. Repository
documentation and checks, not a previous chat or a contributor's personal Copilot
configuration, should provide enough context to reproduce and review a change.

## Get ready

1. Read the [README](README.md), [design](docs/design.md), and the documentation
   for the component you intend to change.
2. Clone the repository and open its root folder in your editor. Create a focused
   branch and check `git status` before editing; preserve unrelated local changes.
3. Have Git and PowerShell available. Bicep changes and compilation checks require
   Azure CLI with Bicep available through `az bicep`. PowerShell tests use Pester;
   Template Spec packaging checks also require Az.Resources. Use a Pester version
   compatible with the selected tests and their documented invocation.
4. Azure sign-in is not needed for offline compilation and packaging checks.
   Publication and deployment tests require authorized access to an isolated test
   environment. Confirm the active cloud, subscription, resource group, and expected
   cost before any Azure writes.

Do not put credentials, customer identifiers, or deployment-specific data in
source, examples, logs, or PR attachments. Keep customer configurations under the
git-ignored [customer folder](customer/README.md). Copy reference packages and
parameters from [customer-examples](customer-examples/) for deployment use; change
tracked examples only when the contribution intentionally updates those examples.
Report vulnerabilities through the [security policy](SECURITY.md), not a public issue.

## Working with Copilot

The repository-wide entry point is
[.github/copilot-instructions.md](.github/copilot-instructions.md). Specialized
workflows live in [.github/skills](.github/skills/).

- Enable repository custom instructions in your Copilot client where supported.
  Check its instruction/context references or diagnostics to confirm that this
  repository's instructions are loaded; support and visibility vary by client.
- For a task, have Copilot read this guide, the applicable skill, and the affected
  source before proposing edits. If automatic skill discovery is unavailable,
  explicitly attach or reference the relevant `SKILL.md`.
- Include the desired outcome, affected component, target cloud, and acceptance
  criteria. Do not assume a new chat has context from another contributor's session.
- Ask for the exact validation commands, results, and remaining live checks.
  Review generated changes yourself: instructions guide the assistant but do not
  guarantee correctness or replace tests and maintainer review.

For example:

> Read CONTRIBUTING.md, the repository Copilot instructions, and the Bicep
> maintenance skill. Update the specified host-pool behavior without changing
> public parameter names. Trace affected module callers, Portal forms, examples,
> and documentation. Run the relevant offline checks and list any live validation
> that remains.

Keep reusable decisions in repository documentation, not only in chat. Link from
the relevant skill or repository instructions instead of duplicating detailed
rules across multiple files.

## Choose the applicable workflow

Read every skill that applies to the change, including overlapping workflows.

| Change | Workflow |
| --- | --- |
| Bicep, generated ARM, module contracts, Template Specs | [Bicep maintenance](.github/skills/federalavd-bicep-maintenance/SKILL.md) |
| Portal forms, defaults, constraints, parameter bindings | [UI form maintenance](.github/skills/federalavd-ui-form-maintenance/SKILL.md) |
| Session-host Azure Policy and remediation | [Policy authoring](.github/skills/federalavd-policy-authoring/SKILL.md) |
| Windows policy scripts or artifacts | [Windows policy validation](.github/skills/federalavd-windows-policy-validation/SKILL.md) |
| Software artifacts and download definitions | [Artifact authoring](.github/skills/federalavd-artifact-authoring/SKILL.md) |
| Restricted-network dependencies and transfer inventories | [Air-gapped readiness](.github/skills/federalavd-air-gapped-readiness/SKILL.md) |
| Deployment ordering and resource ID wiring | [Dependency review](.github/skills/federalavd-deployment-dependency-review/SKILL.md) |
| AVD alert queries | [KQL validation](.github/skills/avd-alert-kql-validation/SKILL.md) |
| Compliance evidence and control mappings | [Compliance review](.github/skills/federalavd-compliance-review/SKILL.md) |

## Make a focused change

1. Trace the entry point, shared modules, callers, parameters, and outputs before
   editing. Prefer shared-module reuse for capabilities used by multiple solutions.
2. Edit Bicep sources, not generated ARM JSON. Rebuild affected tracked ARM files,
   including generated-template dependencies in the order specified by the
   [Bicep skill](.github/skills/federalavd-bicep-maintenance/SKILL.md).
3. Keep public contracts stable unless a breaking change is intentional and
   documented. Update affected Portal forms, reference parameters, tests, and
   deployment documentation together.
4. Keep PowerShell scripts ASCII-only. Follow the authoritative-source and live
   behavior verification requirements in the relevant Windows policy or KQL skill;
   an existing registry value or query is not proof of correctness.
5. Explain architectural decisions in the relevant documentation, starting with
   the [design documentation](docs/design.md). Keep publication-only packaging
   transformations separate from Bicep deployment logic and tracked ARM output.

## Validate the change

Run checks from the repository root. Start with the smallest relevant test files;
add regression coverage for changed behavior and broaden the selection when shared
dependencies are affected. Read the selected tests for additional prerequisites.

For example, after following the Bicep skill's build and synchronization steps:

```powershell
# Select the component test relevant to your change.
Invoke-Pester -Script tests\HostPool.Tests.ps1

# For changes affecting generated templates and publication size:
Invoke-Pester -Script tests\TemplateSpecs.Tests.ps1,tests\HostPoolOrchestratorSize.Tests.ps1

git diff --check
```

Template Spec checks measure the complete serialized package, including linked
artifacts, the Portal form, and envelope allowance. Report remaining headroom;
source or ARM file size alone is insufficient. See the
[size-budget tests](tests/TemplateSpecs.Tests.ps1).

Offline parsing, compilation, restoration-equivalence, and size checks do not prove
Azure service acceptance or user-visible behavior. Follow the applicable skill's
live requirements: Portal text-binding changes need a render smoke test, and
publisher changes need publication and deployment validation. Identify the
tested cloud and scenarios; do not extrapolate success to other clouds.

Documentation-only changes need link and formatting checks, not deployment tests,
unless they change executable examples that require validation. If any required
check cannot run, state the blocker and remaining validation explicitly rather
than reporting the change as fully validated.

## Submit a pull request

Include:

- The problem, intended behavior, and scope of the change.
- Affected components and clouds, compatibility considerations, and any migration
  steps or intentional deviations from documented behavior.
- Exact validation commands and outcomes, size headroom where applicable, and
  live-test evidence or checks still outstanding.
- Related documentation updates and any known limitations.

Review the final diff for unrelated changes, generated-file synchronization, and
sensitive data before submitting. Follow the CLA bot's instructions described in
the [README](README.md#-contributing) and the [Code of Conduct](CODE_OF_CONDUCT.md).
