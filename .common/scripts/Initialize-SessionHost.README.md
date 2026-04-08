# Initialize-SessionHost.ps1

Comprehensive script that configures an AVD session host and registers it with a host pool in a single, unified operation. It is executed on each session host VM via **Azure Run Command** as the final step in both the [Host Pool deployment](../../deployments/hostpools/) and the [Session Host Replacer](../../deployments/add-ons/SessionHostReplacer/) add-on.

---

## Table of Contents

- [Overview](#overview)
- [How It Fits into the Deployment](#how-it-fits-into-the-deployment)
  - [Host Pool Deployment](#host-pool-deployment)
  - [Session Host Replacer Add-On](#session-host-replacer-add-on)
- [Execution Phases](#execution-phases)
  - [Phase 1: Session Host Configuration](#phase-1-session-host-configuration)
  - [Phase 2: AVD Agent Installation and Registration](#phase-2-avd-agent-installation-and-registration)
- [Parameters](#parameters)
- [Why Run Command Instead of PowerShell DSC](#why-run-command-instead-of-powershell-dsc)
- [Logs](#logs)

---

## Overview

`Initialize-SessionHost.ps1` performs two major operations in sequence on each session host VM:

1. **Configuration** — Applies all session-host-level settings: time zone, GPU optimization, Windows Update policy, and full FSLogix profile container configuration (including Cloud Cache, Object Specific Settings, and Windows Defender exclusions).
2. **Registration** — Downloads and installs the RD Infra Agent and RD Agent Boot Loader MSIs, then registers the VM with the host pool using the provided token.

By combining both phases into one script executed at the end of the VM provisioning lifecycle, the deployment is deterministic: configuration is always applied before the VM ever contacts the AVD broker.

---

## How It Fits into the Deployment

### Host Pool Deployment

In [deployments/hostpools/modules/sessionHosts/modules/virtualMachines.bicep](../../deployments/hostpools/modules/sessionHosts/modules/virtualMachines.bicep), an `Microsoft.Compute/virtualMachines/runCommands` resource named `initializeSessionHost` is declared for every session host VM in the deployment.

Key characteristics of the Run Command resource:

```bicep
resource runCommand_InitializeSessionHost 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = [
  for i in range(0, sessionHostCount): {
    ...
    properties: {
      source: {
        script: loadTextContent('../../../../../.common/scripts/Initialize-SessionHost.ps1')
      }
      treatFailureAsDeploymentFailure: true
      timeoutInSeconds: 900
      parameters: [ /* non-sensitive parameters */ ]
      protectedParameters: [ /* RegistrationToken, storage account keys */ ]
    }
    dependsOn: [
      extension_AADLoginForWindows[i]
      extension_JsonADDomainExtension[i]
      extension_AmdGpuDriverWindows[i]
      extension_NvidiaGpuDriverWindows[i]
      extension_AzureMonitorWindowsAgent[i]
      extension_GuestAttestation[i]
      customizations[i]
    ]
  }
]
```

- `loadTextContent()` embeds the full script into the ARM template at compile time — no external artifact storage is required for the script itself.
- The `dependsOn` block guarantees this script runs **after** domain join, GPU driver installation, monitoring agent, and all other VM extensions and custom image customizations have completed.
- `treatFailureAsDeploymentFailure: true` propagates any script error directly into the ARM deployment failure, making troubleshooting straightforward.
- `RegistrationToken` and storage account keys are passed as `protectedParameters`, which are encrypted end-to-end and never appear in deployment logs or outputs.

### Session Host Replacer Add-On

The Session Host Replacer ([deployments/add-ons/SessionHostReplacer/](../../deployments/add-ons/SessionHostReplacer/)) continuously monitors a host pool and deploys replacement session hosts when VMs age out or a new image version is available. It uses its own [virtualMachines.bicep](../../deployments/add-ons/SessionHostReplacer/modules/sessionHosts/modules/virtualMachines.bicep) module which follows the identical pattern — the same `runCommand_InitializeSessionHost` resource is used, with the same `dependsOn` chain, `treatFailureAsDeploymentFailure: true`, and `protectedParameters` handling.

This means every host the Session Host Replacer deploys goes through the exact same configuration and registration path as a host deployed from the standard host pool template, ensuring consistency across both deployment methods.

---

## Execution Phases

### Phase 1: Session Host Configuration

Runs first, before any contact with the AVD broker.

| Task | Detail |
|------|--------|
| **Time zone** | Sets the OS time zone to the value specified by `-TimeZone` |
| **Time zone redirection** | Enables `fEnableTimeZoneRedirection` via Group Policy registry key |
| **GPU optimization** | When `-AmdVmSize` or `-NvidiaVmSize` is `true`, writes `bEnumerateHWBeforeSW`, `AVC444ModePreferred`, and (for NVIDIA) `AVChardwareEncodePreferred` registry keys |
| **Disable automatic updates** | Optionally disables Windows Update, Microsoft Edge update, OneDrive update ring, Microsoft 365 Apps updates, and Teams auto-update via registry policy keys |
| **FSLogix configuration** | Writes all FSLogix profile and ODFC container registry settings when `-ConfigureFSLogix` is `true`. Supports both AzureFiles and AzureNetAppFiles, optional Cloud Cache, geo-redundant (local + remote) storage paths, Object Specific Settings (OSS) groups, profile container size, and VHDX volume type. Also configures ODFC (Office Data File Containers) when a second share name is provided |
| **FSLogix Windows Defender exclusions** | Adds standard FSLogix path (local and UNC) and process exclusions to Windows Defender |
| **FSLogix redirections.xml** | Automatically generates and deploys a `redirections.xml` file for Teams and/or Azure CLI if those applications are detected on the image |
| **Entra Kerberos** | Sets `CloudKerberosTicketRetrievalEnabled` when the identity solution is `EntraKerberos-Hybrid` or `EntraKerberos-CloudOnly` |
| **Storage account credentials** | Adds storage account keys to Windows Credential Manager via `cmdkey.exe` for both local and geo-redundant (remote) accounts when keys are provided |
| **OS disk resize** | Expands the OS partition to the full disk size |

### Phase 2: AVD Agent Installation and Registration

Runs only after Phase 1 completes successfully.

1. **Windows Server detection** — If the OS is Windows Server, installs the `RDS-RD-Server` feature before proceeding.
2. **Idempotency check** — Reads `HKLM:\SOFTWARE\Microsoft\RDInfraAgent`. If `IsRegistered = 1` and `RegistrationToken` is empty, the VM is already registered and the script exits cleanly without reinstalling.
3. **Agent download with tiered fallback** — The script attempts to obtain the latest `RDAgent.msi` in three stages:
   - **Stage 1 (primary):** Queries the AVD broker's `api/agentMsi/v1/agentVersion` endpoint by parsing the `GlobalBrokerResourceIdUri` claim embedded in the registration token. Also attempts the private link variant (`<EndpointPoolId>.<host>`) for private networking environments.
   - **Stage 2 (AgentUrl fallback):** Downloads from the `-AgentUrl` parameter if the broker endpoint is unreachable.
   - **Stage 3 (FallbackUrl package):** Downloads and extracts a `configuration.zip` package from `-FallbackUrl`, locates `DeployAgent.zip` inside it, and extracts both `RDAgent.msi` and `RDAgentBootLoader.msi`. This supports fully air-gapped and sovereign cloud deployments where neither the broker endpoint nor a direct MSI URL is accessible.
4. **BootLoader download** — Downloads `RDAgentBootLoader.msi` from `-AgentBootLoaderUrl`. If that also fails, falls back to the same `FallbackUrl` package mechanism.
5. **RD Infra Agent installation** — Installs via `msiexec.exe` with the registration token embedded. Includes retry logic (up to 20 retries, 30-second intervals) to handle `ERROR_INSTALL_ALREADY_RUNNING` (exit code 1618) that can occur when Windows Installer is busy with another operation.
6. **RD Agent Boot Loader installation** — Installs via `msiexec.exe` with the same retry logic.
7. **Service start** — Waits for the `RDAgentBootLoader` service to appear (up to 3 minutes) then starts it.
8. **Intune enrollment delay** — When `-AADJoin true` and `-MdmId` is set, waits 6 minutes after agent installation to allow Intune metadata to be captured before the script exits.

---

## Parameters

### Required

| Parameter | Description |
|-----------|-------------|
| `RegistrationToken` | Host pool registration token. Passed as a `protectedParameter` from Bicep — never appears in deployment logs |
| `AgentBootLoaderUrl` | Direct download URL for the RDAgentBootLoader MSI |
| `TimeZone` | Windows time zone ID (e.g., `Eastern Standard Time`) |

### Optional — Agent Installation

| Parameter | Default | Description |
|-----------|---------|-------------|
| `AgentUrl` | | Direct download URL for the RD Infra Agent MSI. Used if broker endpoint download fails |
| `FallbackUrl` | | URL to a `configuration.zip` package containing `DeployAgent.zip` with both agent MSIs. Used as last-resort fallback for air-gapped environments |
| `AADJoin` | `false` | Set to `true` if the VM is Entra ID (Azure AD) joined |
| `MdmId` | | MDM enrollment application ID for Intune enrollment alongside Entra ID join |
| `ApiVersion` | | Azure Instance Metadata Service API version, required for sovereign cloud environments |
| `StorageSuffix` | | Azure Storage DNS suffix (e.g., `core.usgovcloudapi.net`) used for managed identity authentication to Azure Storage |
| `UserAssignedIdentityClientId` | | Client ID of the user-assigned managed identity used to authenticate to Azure Storage when downloading from storage accounts |

### Optional — Session Host Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `AmdVmSize` | `false` | Set to `true` for VM SKUs with AMD GPU (e.g., NVv4 series) |
| `NvidiaVmSize` | `false` | Set to `true` for VM SKUs with NVIDIA GPU (e.g., NVsv3 series) |
| `DisableUpdates` | `false` | Set to `true` to disable automatic updates (Windows, Edge, OneDrive, Office, Teams) |
| `ConfigureFSLogix` | `false` | Set to `true` to configure FSLogix profile containers |
| `CloudCache` | `false` | Set to `true` to enable FSLogix Cloud Cache instead of standard VHDLocations |
| `IdentitySolution` | | One of: `ActiveDirectoryDomainServices`, `EntraDomainServices`, `EntraKerberos-Hybrid`, `EntraKerberos-CloudOnly`, `EntraId` |
| `StorageService` | | `AzureFiles` or `AzureNetAppFiles` |
| `Shares` | `[]` | JSON array. First element is the profile share name; optional second element is the ODFC (Office) share name |
| `SizeInMBs` | `30000` | FSLogix container size in MB |
| `LocalStorageAccountNames` | `[]` | JSON array of local/primary Azure Files storage account names |
| `LocalStorageAccountKeys` | `[]` | JSON array of local storage account keys. Passed as `protectedParameter` from Bicep |
| `LocalNetAppServers` | `[]` | JSON array of local Azure NetApp Files server FQDNs |
| `RemoteStorageAccountNames` | `[]` | JSON array of geo-redundant/secondary storage account names |
| `RemoteStorageAccountKeys` | `[]` | JSON array of geo-redundant storage account keys. Passed as `protectedParameter` from Bicep |
| `RemoteNetAppServers` | `[]` | JSON array of geo-redundant Azure NetApp Files server FQDNs |
| `OSSGroups` | `[]` | JSON array of group names for FSLogix Object Specific Settings |

---

## Why Run Command Instead of PowerShell DSC

Traditional AVD deployment templates used the **DSC VM extension** (`Microsoft.Compute/virtualMachines/extensions` with `type: DSC`) to both configure the session host and install the AVD agent. This solution replaces that approach entirely with Azure Run Command. The reasons are significant, particularly for federal and sovereign cloud deployments.

### Execution ordering and dependency control

The DSC extension runs as a standard VM extension and is subject to Azure's extension deployment parallelism. This creates race conditions — for example, the DSC extension attempting to install the AVD agent before the domain join extension has completed, or before GPU drivers are available. The Run Command resource in this repo uses an explicit `dependsOn` block listing every extension and customization that must complete first. The session host is fully configured and domain-joined before a single line of `Initialize-SessionHost.ps1` executes.

### Deployment failure surfacing

With DSC, if the MOF compilation or configuration application fails on the VM, the ARM deployment can still report success because the DSC extension reports its own status separately from the deployment. This script uses `treatFailureAsDeploymentFailure: true`. If the script exits with a non-zero code for any reason — failed download, failed MSI install, or configuration error — the entire ARM deployment resource fails immediately. Deployment failures are visible in the Azure Portal activity log and ARM deployment history without requiring a separate investigation of the VM extension status.

### No Local Configuration Manager complexity

DSC requires WMF 5.1 or later and a functioning Local Configuration Manager (LCM) on every VM. The LCM has its own state, consistency check intervals, and potential drift detection behaviors that can interfere with repeated deployments or re-registration operations. This script has no LCM dependency. It reads parameters, applies settings, and exits. The idempotency check (reading the `RDInfraAgent` registry key) is a simple conditional, not a full DSC desired-state cycle.

### No MOF compilation or external DSC artifacts

DSC deployments require either compiling a MOF file and distributing it (push) or pointing the LCM at a pull server or Azure Automation DSC (pull). Both approaches add infrastructure requirements and failure points. This script is embedded directly into the ARM template at Bicep compile time via `loadTextContent()`. There is no external script artifact to manage, no SAS token expiry to worry about, and no dependency on the availability of a separate storage account containing the DSC archive.

### Air-gapped and sovereign cloud support

Federal deployments frequently operate in environments where outbound internet access to `aka.ms` or `wvd.microsoft.com` download endpoints is blocked or tightly controlled. The DSC-based approach typically hard-codes a download URL for the AVD agent MSI. This script implements a three-tier fallback system:

1. Query the AVD broker API directly (works with Private Link enabled environments).
2. Download from an explicit MSI URL stored in an internal artifact repository.
3. Extract the agent MSIs from a `configuration.zip` package stored in a controlled Azure Storage Account, authenticated via managed identity using the Instance Metadata Service — no SAS tokens required.

This allows the same script to function identically in commercial Azure, Azure Government, and completely air-gapped sovereign environments.

### Sensitive parameter protection

The host pool registration token and storage account keys are passed as `protectedParameters` on the Run Command resource. Azure encrypts these values in transit and at rest; they are never written to deployment logs, ARM template outputs, or the VM extension status blob. The DSC extension historically passed the registration token as a plain parameter in the configuration archive or as an argument that could appear in the extension handler logs.

### Unified log output

When troubleshooting a failed session host registration using the DSC approach, an operator must examine both the DSC extension logs on the VM and any MSI installation logs in separate locations. This script writes a single structured log file to `%TEMP%\AVDSessionHostInitialization.log` covering both phases — configuration and registration — with timestamps, categories, and all parameter values (excluding sensitive ones). MSI installation logs are written alongside it. A single log file path is surfaced in the Run Command output on failure.

---

## Logs

| Log File | Content |
|----------|---------|
| `%TEMP%\AVDSessionHostInitialization.log` | Main script log covering Phase 1 and Phase 2 with timestamped entries |
| `%TEMP%\RDAgentInstall.log` | MSI installer verbose log for the RD Infra Agent |
| `%TEMP%\RDAgentBootLoaderInstall.log` | MSI installer verbose log for the RD Agent Boot Loader |

The path to the main log is echoed in the Run Command output on both success and failure, making it easy to locate when reviewing the VM's Run Command history in the Azure Portal.
