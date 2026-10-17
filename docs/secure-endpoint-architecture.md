[**Home**](../README.md) | [**Quick Start**](quick-start.md) | [**Host Pool Deployment**](hostpool-deployment.md) | [**Image Build**](image-build.md) | [**Artifacts**](artifacts-guide.md) | [**Features**](features.md) | [**Parameters**](parameters.md) | [**Compliance**](compliance.md) | [**BCDR**](bcdr.md)

# Secure Endpoint Architecture

Azure Virtual Desktop can be more than a hosted desktop service. When combined with repeatable image engineering, infrastructure as code, policy, monitoring, and controlled host replacement, it provides an architecture for building and operating secure Windows endpoints inside an Azure boundary.

FederalAVD implements the deployment and operational components of that architecture across supported Azure cloud environments.

> The secure endpoint is not a virtual machine. It is a repeatable process for defining, building, validating, deploying, observing, and replacing the endpoint.

This document describes the architectural principles behind that process. It does not claim that deploying FederalAVD alone establishes compliance or implements every security control required by an organization.

An individual session-host VM is a replaceable implementation of the endpoint definition. The
definition includes its source image, applications, configuration, policy, identity, network
access, data paths, monitoring, and lifecycle rules. A governed fleet applies that definition to
multiple endpoint instances and replaces instances that no longer represent it.

## Architectural Goals

A secure cloud endpoint architecture should enable an organization to:

- Define the endpoint configuration as version-controlled inputs.
- Build endpoints from a known and repeatable source.
- Apply identity, network, configuration, data, and monitoring controls consistently.
- Minimize configuration drift between endpoint instances.
- Replace instances that are outdated, unhealthy, or no longer conformant.
- Produce evidence showing what was deployed and how it was configured.
- Preserve the same operating model across Azure cloud boundaries where services and capabilities differ.

FederalAVD provides the deployment and lifecycle mechanisms that support these goals. Customers remain responsible for selecting, configuring, validating, and operating the controls required by their security and compliance programs.

## The Endpoint as a Control System

Traditional endpoint environments can create many independent places to configure, patch, monitor, investigate, and validate. Laptops, administrative workstations, contractor devices, virtual machines, and enclave-specific systems may each develop different configurations over time.

A cloud-hosted endpoint moves the workload execution boundary into Azure. Users continue to interact with Windows, while the organization centrally manages the supporting control layers:

1. **Identity**
2. **Network**
3. **Image**
4. **Configuration and policy**
5. **Application delivery**
6. **Data paths**
7. **Monitoring and detection**
8. **Lifecycle**
9. **Evidence**

FederalAVD can deploy and connect many of the Azure Virtual Desktop, image, storage, monitoring, governance, and lifecycle resources used in these layers. Services and controls that remain outside FederalAVD must be integrated separately.

## Control Layers

The layers form one operating system for the endpoint fleet. No single layer establishes the
security boundary by itself.

| Layer | FederalAVD role | Customer or external responsibility |
| --- | --- | --- |
| Identity | Supports multiple session-host join models, managed identities, application-group assignment, and Key Vault-backed deployment credentials | Tenant configuration, Conditional Access, identity governance, privileged access, and account lifecycle |
| Network | Deploys session hosts without public IP addresses and provides optional NSGs, routing, private endpoints, and private DNS | Enterprise egress, inspection, name resolution, service authorization, and boundary policy |
| Image | Provides Compute Gallery, Azure Image Builder, artifact staging, and versioned image mechanisms | Approve image sources, software, hardening, and release criteria |
| Configuration and policy | Provides infrastructure as code, Azure Policy capabilities, VM Applications, and controlled customization paths | Define, approve, test, and maintain the required endpoint baseline |
| Application delivery | Supports image-baked artifacts, Compute Gallery VM Applications, and documented customization exceptions | Package ownership, licensing, vulnerability management, and application acceptance |
| Data paths | Provides FSLogix storage, private connectivity, encryption options, and backup integration | Data classification, retention, DLP, sharing policy, and recovery validation |
| Monitoring and detection | Provides AVD Insights configuration, Azure diagnostics, and optional alerting | SIEM integration, security-event collection, detection engineering, investigation, and response |
| Lifecycle | Provides image refresh, controlled host replacement, and automated-host update patterns | Release approval, maintenance windows, rollback criteria, and operational ownership |
| Evidence | Produces or connects deployment inputs, image versions, deployment records, policy state, diagnostics, and operational logs | Evidence retention, interpretation, control assessment, and authorization decisions |

## Shared Responsibility

FederalAVD supplies mechanisms that an organization can configure as part of its endpoint control
implementation. It does not determine the organization's security requirements or validate that a
selected configuration satisfies them.

| Responsibility | FederalAVD contribution | Customer responsibility |
| --- | --- | --- |
| Azure resource deployment | Version-controlled Bicep, ARM templates, forms, parameters, and orchestration | Select, review, approve, and deploy the required configuration |
| Images and software | Image pipeline and artifact or VM Application delivery mechanisms | Approve sources, scan packages, test compatibility, and authorize releases |
| Windows configuration | Policy, image customization, and post-deployment configuration mechanisms | Define the organizational Windows baseline and validate user-visible behavior |
| Security services | Integration points for identity, networking, monitoring, encryption, backup, and policy | Configure tenant-wide and enterprise services outside the solution |
| Operations | Host update and replacement workflows, diagnostics, and lifecycle automation | Monitor convergence, investigate failures, approve changes, and operate recovery procedures |
| Compliance | Configuration and operational evidence sources | Determine applicability, assess controls, retain evidence, and obtain authorization |

## Secure Endpoint Lifecycle

The architecture uses a continuous lifecycle rather than treating initial deployment as the final security state.

```text
Define -> Build -> Validate -> Deploy -> Observe -> Replace
```

| Phase | Purpose | FederalAVD documentation |
| --- | --- | --- |
| Define | Declare naming, topology, security choices, software, and endpoint behavior as reviewed inputs | [Parameters](parameters.md), [Naming Convention](naming-convention.md), and [Artifacts](artifacts-guide.md) |
| Build | Produce a versioned image from an approved source and controlled artifacts | [Image Build](image-build.md) and [Update Image Artifacts](update-image-artifacts.md) |
| Validate | Test the image, applications, policies, network paths, monitoring, and workload behavior before broad release | Deployment-specific validation plus organization-owned acceptance procedures |
| Deploy | Create the Azure control plane, supporting services, storage, and endpoint fleet | [Quick Start](quick-start.md) and [Host Pool Deployment](hostpool-deployment.md) |
| Observe | Collect platform health, performance, diagnostics, policy state, and operational alerts | [Features](features.md), [AVD Alerts](avd-alerts.md), and organization-owned SIEM processes |
| Replace | Drain and replace outdated or nonconformant hosts from the current endpoint definition | [Automation](automation-guide.md) and [Session Host Replacer](session-host-replacer.md) |

Validation is an explicit phase rather than an implied result of a successful Azure deployment.
Resource provisioning proves that Azure accepted the requested resources. It does not prove that
the Windows experience, application behavior, network paths, policy convergence, monitoring, or
workload-specific controls meet organizational requirements.

## Fleet Management Models

FederalAVD supports two ways to operate the endpoint lifecycle:

- **Standard host pools** preserve direct control over VM creation and replacement. An organization
  can replace image-managed hosts manually, through its own automation, or with Session Host
  Replacer.
- **Automated host pools** use Azure Virtual Desktop Session Host Configuration and Session Host
  Update to maintain the declared host configuration and lifecycle.

Both approaches can implement the secure endpoint lifecycle. Their lifecycle owner, supported
clouds, and available VM controls differ. Choose the management approach before deployment by using
[Choose a Host Pool Management Approach](host-pool-management.md).

## Secure Endpoints as an AI Access Layer

A governed Azure Virtual Desktop endpoint can provide a controlled workspace from which authorized
users access approved AI services and organizational data. Moving workload execution into an Azure
boundary can make identity, application configuration, network paths, data access, monitoring, and
endpoint replacement more consistent than relying only on independently managed physical devices.

This architecture can support an AI access pattern through:

- Identity-aware access from a centrally managed Windows environment.
- Approved browsers, clients, extensions, and supporting applications delivered through the image
  or managed application lifecycle.
- Enterprise-controlled DNS, routing, egress, and service endpoints.
- Deliberate access paths to organizational data and development resources.
- Central diagnostics, endpoint health monitoring, and replacement of outdated hosts.
- Separate endpoint definitions for personas with different data, application, or service access.

FederalAVD does not deploy or govern the AI service itself. It does not provide model hosting, model
governance, prompt or response inspection, data classification, DLP, tenant-level Copilot
configuration, or authorization to submit information to an AI service. Those controls must be
implemented by the organization and the selected AI, identity, data-governance, and security
services.

An endpoint being able to reach an AI service does not mean the service, data, or intended use is
approved. Organizations must explicitly authorize the service and validate the complete data path.

## Evidence and Compliance

Potential evidence sources include:

- Version-controlled Bicep, ARM templates, parameter files, and artifact definitions.
- Azure deployment history and resource configuration.
- Compute Gallery image definitions and immutable image versions.
- Azure Policy definitions, assignments, compliance state, and remediation records.
- Diagnostic settings, Log Analytics data, alert history, and activity logs.
- Host update, replacement, application deployment, and operational validation records.

These sources can support an assessment, but evidence must be retained and interpreted within the
organization's control implementation. See [Compliance Control Mapping](compliance.md) for the
documented FederalAVD capability mappings and configuration conditions.

## Cloud Boundary Portability

The architecture is intended to preserve the same operating model across supported Azure clouds,
not to promise identical service availability. Azure Commercial, Government, Government Secret,
and Government Top Secret can differ in resource providers, marketplace images, extensions,
service endpoints, API versions, and regional capabilities.

Disconnected and restricted environments may require software and artifacts to be transferred and
pre-staged, public runtime dependencies to be removed, and cloud-specific endpoints to be
independently authorized. Validate every build-time and runtime dependency in the target cloud. See
[Air-Gapped Cloud Considerations](air-gapped-clouds.md).

## Related Documentation

- [Design](design.md) describes the Azure resource topology that implements this operating model.
- [Features](features.md) describes the individual FederalAVD capabilities.
- [Quick Start](quick-start.md) selects and deploys the required solution components.
- [Automation](automation-guide.md) connects deployments and recurring image-refresh operations.
- [Compliance Control Mapping](compliance.md) maps configurable capabilities to security controls.
- [Solution Limitations](limitations.md) identifies unsupported or constrained scenarios.
