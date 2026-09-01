# Session Host Policy Add-On

This subscription-scoped add-on applies reusable FederalAVD Azure Policy capabilities to session
hosts without deploying an automated host pool. Each deployment can independently enable:

- An authoritative ordered Azure Compute Gallery VM Application list.
- Azure Monitor Agent with an AVD Insights Data Collection Rule and optional Data Collection Endpoint.
- Guest Attestation on eligible Trusted Launch and Confidential VMs.
- Managed-disk isolation with public network access disabled and network access set to `DenyAll`.

Session-host guest configuration, FSLogix, private customizations, and the other automated creation
settings are intentionally not exposed.

## Scope And Ownership

Select one dedicated resource group containing only the session host VMs that should receive the
policy. The assignment evaluates every VM in that resource group. Do not target a resource group
that contains unrelated VMs.

Both this add-on and Automated Host Pools consume the same shared policy definitions and assignment
orchestration. Assignments and remediations use deterministic `avd-sh-*` names. The first
deployment records its `ownerId` in the `FederalAVD-SessionHostPolicy-Owner` resource-group tag.
Later deployments using the same owner are idempotent and update those assignments. A deployment
using a different owner fails before replacing the assignment, preventing two workflows from
silently competing for the same policy boundary. Remove the existing policy deployment and ownership
tag intentionally before transferring ownership.

The VM Application assignment owns the complete ordered
`Microsoft.Compute/virtualMachines/applicationProfile.galleryApplications` array. Do not manage
that VM property independently through another policy, the portal, or external automation.

The policy boundary includes every applicable VM or managed disk in the target resource group.
Use only a dedicated session-host resource group. Managed-disk isolation changes disk export and
public network behavior and does not deploy a Disk Access resource.

## VM Application Lifecycle

Publish immutable application versions separately with `Publish-VMApplications.ps1`, then provide
the returned Gallery application-version resource IDs in `vmApplications`. Each item requires:

- `packageReferenceId`: an immutable `/versions/Major.Minor.Patch` ID or `/versions/latest`.
- `order`: a unique operational installation order from 1 through 25.
- `treatFailureAsDeploymentFailure`: whether lifecycle failure marks VM provisioning failed.

Publishing a version does not change the policy assignment. New or updated VMs receive the policy
through Azure Policy `Modify`. Existing noncompliant VMs change only after an intentional VM update
or remediation.

Set `createRemediation` to `true` to create or update the deterministic
remediations for every enabled capability with `ReEvaluateCompliance`. Policy evaluation,
extension deployment, associations, and application installation are asynchronous. Verify the
required guest state and policy compliance before admitting users.

## Monitoring And Attestation

Monitoring requires an existing AVD Insights Data Collection Rule. A Data Collection Endpoint is
optional. The add-on enables a VM system-assigned identity, deploys Azure Monitor Agent, creates the
DCR association, and creates the DCE association when supplied. The policy identity receives the
roles declared by those policies at the narrowest required scopes.

Guest Attestation applies only to eligible Trusted Launch and Confidential VMs. Enabling the policy
does not change a VM security type or enable Secure Boot or vTPM.

## Deployment

For a first deployment, publish this add-on as a Template Spec and use its guided portal form. The
form produces a validated parameter file for subsequent repeatable PowerShell or CI/CD deployments.

For direct deployment, copy
`customer-examples/parameters/add-ons/sessionHostPolicy.parameters.json` into the git-ignored
`customer/parameters` tree, replace the example resource IDs, and deploy `main.bicep` at subscription
scope.

The deploying principal must be able to create subscription policy definitions and resource-group
policy assignments, managed identities, role assignments on the target resource group and each
referenced Compute Gallery, DCR, and optional DCE, and optional Policy Insights remediations.

## Cloud Support

The shared policies use Azure Policy, Compute Gallery, Azure Monitor, Guest Attestation, and Compute
resource types. Application versions must already exist and be replicated into the VM region.
Azure Monitor Agent is not supported in air-gapped clouds by this implementation. Before using any
capability in Azure Government Secret or Top Secret, verify its resource providers, extensions,
API versions, and regional availability. Package transfer and publication remain separate
air-gapped lifecycle steps.

## Standalone Boundary

This add-on intentionally does not expose session-host guest configuration, time-zone settings,
FSLogix Run Command configuration, encryption at host, OS disk sizing, accelerated networking,
Disk Encryption Set assignment, ownership-tag inheritance, or private customizations. Those remain
specific to Automated Host Pools or other established deployment paths.
