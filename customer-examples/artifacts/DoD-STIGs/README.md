# Apply-STIGsAVD.ps1

## Overview

This PowerShell script automates the application of Defense Information Systems Agency (DISA) Security Technical Implementation Guides (STIGs) to custom images for Azure Virtual Desktop (AVD) session hosts or deployed session hosts. It uses the Local Group Policy Object (LGPO) tool to apply GPO settings, security templates, audit policies, and additional registry-based mitigations.

## Purpose

- Apply DISA STIG Group Policy Objects to Windows 10/11 and supported Windows Server Member Server systems
- Configure security settings for AVD environments
- Apply STIGs for common enterprise applications
- Implement additional security mitigations beyond standard STIG GPOs
- Support version tracking and automated upgrades

## Parameters

### `ApplicationsToSTIG`

- **Type:** String array
- **Default:** `@('Adobe Acrobat Pro', 'Adobe Acrobat Reader', 'Google Chrome', 'Mozilla Firefox')`
- **Description:** Third-party applications to apply STIGs to

### `SearchForApplications`

- **Type:** Switch
- **Description:** When specified, verifies applications in `ApplicationsToSTIG` are installed before applying settings

### `AllowLocalUserRemoteInteractiveLogon`

- **Type:** Switch
- **Description:** When specified, permits eligible local accounts to log on through Remote Desktop Services by removing the local-account deny SIDs (`*S-1-5-113` and `*S-1-5-114`) from the STIG-defined Remote Desktop Services deny right. It does not modify local console `SeInteractiveLogonRight` or `SeDenyInteractiveLogonRight`. It does not create a user-right assignment that the STIG omits. Guests and all other deny principals remain.
- **RDS membership:** A local account must still belong to either the local **Administrators** or **Remote Desktop Users** group to receive the Remote Desktop Services allow right.
- **Compatibility alias:** The former `AllowLocalUserLogon` parameter name remains available as an alias with the same RDS-only behavior.

### `ExecutionProfile`

- **Type:** String
- **Default:** `ZeroTrustImageBuild`
- **Allowed values:** `ZeroTrustImageBuild`, `Packer`, `AzureVMImageBuilder`, `SessionHost`
- **Description:** Identifies how the script is being executed so it applies only the compatibility exceptions required by that environment. `AllowLocalUserRemoteInteractiveLogon` remains independent because it controls intended local-account RDS access rather than build transport.

| Profile | Execution path | Additional behavior |
| --- | --- | --- |
| `ZeroTrustImageBuild` | FederalAVD VM Run Command / VM agent | No remote build-account exception |
| `Packer` | Local administrator over WinRM | Temporarily preserves local-account network logon, the remote administrative token, and local firewall rules during provisioning |
| `AzureVMImageBuilder` | Microsoft Azure VM Image Builder over WinRM HTTPS/5986 | Temporarily preserves local-account network logon, the remote administrative token, local firewall rules, and service-controlled WinRM authentication during customization |
| `SessionHost` | Post-deployment session-host customization | Selects firewall behavior from the effective domain-join state |

The Packer template must use NTLM over HTTPS. The profile does not weaken the STIG prohibition on
Basic authentication or permit unencrypted WinRM. Its local-network-logon, token-filtering, and
firewall changes are temporary build-transport exceptions. Use the finalization provisioner in
the `packer` subfolder to restore final policy and run Sysprep before Packer captures the image.

Azure VM Image Builder is also built on Packer, but its service controls the Windows communicator
and connects to the build VM through WinRM over HTTPS port 5986. The `AzureVMImageBuilder` profile
temporarily enables the required WinRM policy state and automatically installs
`azure-vm-image-builder/DeprovisioningScript.ps1` as `C:\DeprovisioningScript.ps1`. AIB invokes
that exact path from its hidden final customizer. The override restores final STIG policy and then
runs Sysprep, so no separate AIB finalizer customizer is required.

### `OverrideDomainJoin`

- **Type:** Switch
- **Description:** Treats a workgroup build VM as intended for a domain-joined deployment when selecting final-state policy behavior. This is intended for uncommon cases where the captured image is guaranteed to join a domain.
- **Principal limitation:** Domain Admins and Enterprise Admins cannot be resolved before the machine actually joins a domain. On a workgroup build VM, the script therefore removes the package placeholders even when this override is enabled. Apply the required domain user-right assignments through domain policy, or rerun policy after domain join.
- **Firewall interaction:** With the override enabled, `ZeroTrustImageBuild` retains the domain-oriented STIG firewall merge setting. `Packer` and `AzureVMImageBuilder` temporarily remove it because their local WinRM firewall rules must remain effective during provisioning. Their finalizers restore it before capture.

### `STIGsUrl`

- **Type:** String (URL)
- **Default:** `'https://dl.dod.cyber.mil/wp-content/uploads/stigs/zip/U_STIG_GPO_Package_July_2026.zip'`
- **Description:** URL of the STIG GPO package to download and apply

### `Upgrade`

- **Type:** Switch
- **Description:** When specified, compares every applicable STIG folder version with its registry value and resets local group policy if any value is missing or different before re-applying

## Usage Examples

### Basic Usage

```powershell
.\Apply-STIGsAVD.ps1
```

### With Application Search

```powershell
.\Apply-STIGsAVD.ps1 -SearchForApplications
```

### Upgrade Mode

```powershell
.\Apply-STIGsAVD.ps1 -Upgrade
```

### Custom Application List

```powershell
.\Apply-STIGsAVD.ps1 -ApplicationsToSTIG @('Google Chrome', 'Mozilla Firefox')
```

When passing the same parameter through an image-build or session-host customization, keep the
native PowerShell array syntax inside the JSON `arguments` string. `Invoke-Customization.ps1`
converts it to a string array before splatting the parameters into this script:

```json
"arguments": "-ApplicationsToSTIG @('Google Chrome','Mozilla Firefox') -SearchForApplications"
```

### Allow Local User RDS Logon

```powershell
.\Apply-STIGsAVD.ps1 -AllowLocalUserRemoteInteractiveLogon
```

### Packer Image Build

Configure Packer to use NTLM over HTTPS, then select its execution profile:

```powershell
.\Apply-STIGsAVD.ps1 -ExecutionProfile Packer
```

After all other provisioning and validation, run
[`packer/Finalize-STIGsForPacker.ps1`](packer/Finalize-STIGsForPacker.ps1) as the final Packer
provisioner. The accompanying [`packer/README.md`](packer/README.md) contains workgroup and
intended-domain HCL examples. The helper restores the temporary Packer exceptions, invokes
Sysprep, and returns control to the Azure ARM builder for power-off and capture.

### Azure VM Image Builder

Select the Azure VM Image Builder execution profile in the AIB PowerShell customizer that invokes
this artifact:

```powershell
.\Apply-STIGsAVD.ps1 -ExecutionProfile AzureVMImageBuilder
```

The artifact installs the required `C:\DeprovisioningScript.ps1` override automatically. Keep the
STIG customizer after software installation and any customizers that need to restart Windows.
Later AIB customizers may continue to use WinRM. At the end of customization, AIB's hidden final
customizer invokes the override, which restores the temporary exceptions and performs Sysprep.
See [`azure-vm-image-builder/README.md`](azure-vm-image-builder/README.md) for lifecycle details.

### Image Intended for Domain Join

For an agent-based build VM that is currently in a workgroup but is guaranteed to join a domain:

```powershell
.\Apply-STIGsAVD.ps1 `
  -ExecutionProfile AzureVMImageBuilder `
  -OverrideDomainJoin
```

## What the Script Does

### 1. Initialization

- Classifies the OS by SKU and product type, including Windows Enterprise multi-session SKU 175
- Supports Windows 10/11 clients and Windows Server 2022 and 2025 Member Servers
- Rejects domain controllers and unsupported server releases before applying policy
- Creates temporary working directories
- Initializes logging

### 2. LGPO Tool Setup

- Downloads LGPO.exe if not present in `C:\Windows\System32`
- Extracts and copies to system directory

### 3. STIG Package Processing

- Downloads or uses local STIG GPO package
- Extracts ADMX/ADML policy definition files
- Copies policy files to `C:\Windows\PolicyDefinitions`

### 4. GPO Application

- Identifies applicable STIG folders based on OS version
- For Windows Server packages, reads each `Backup.xml` and imports only the matching Member Server computer/user GPOs; Domain Controller GPOs are never imported
- Applies STIGs for:
  - Windows 10/11
  - Windows Server 2022/2025 Member Servers
  - Microsoft Edge
  - Windows Firewall
  - Internet Explorer
  - Windows Defender Antivirus
  - Microsoft 365/Office/Teams (if detected)
  - Third-party applications (Adobe, Chrome, Firefox, etc.)

### 5. AVD-Specific Exceptions

- Configures Remote Desktop Users remote interactive logon rights
- Optionally removes local-account SIDs from the RDS deny right through `AllowLocalUserRemoteInteractiveLogon`
- Removes ECC curves SSL configuration that breaks AVD
- Configures firewall settings for non-domain joined systems
- Removes Edge proxy configuration (V-235798)
- Removes BitLocker startup PIN requirement (V-253260 - NA for stateless AVD session hosts)

### 6. Additional Windows Client Security Mitigations

The supplemental remediations below implement Windows client STIG findings and run only on
Windows 10/11. Windows Server support applies the official Member Server GPOs and common AVD
compatibility exceptions. The Windows Server 2022 V2R10 and Windows Server 2025 V1R3 manual
XCCDF files have been reviewed. Safe non-GPO Server remediations are applied separately with
their Server feature names and release-specific V-IDs. See the Server STIG scope notes below.

| STIG ID | Severity | Action |
| --- | --- | --- |
| V-253289 | MEDIUM | Disables Secondary Logon service |
| V-257592 | MEDIUM | Disables PortProxy |
| V-253396 | MEDIUM | Enables Explorer Data Execution Prevention |
| V-253275 | HIGH | Removes IIS-WebServer and IIS-HostableWebCore optional features |
| V-253276 | MEDIUM | Removes SNMP Client Windows Capability |
| V-253277 | MEDIUM | Disables Simple TCP/IP Services optional feature |
| V-253278 | MEDIUM | Disables Telnet Client optional feature |
| V-253279 | MEDIUM | Disables TFTP Client optional feature |
| V-253285 | MEDIUM | Disables both Windows PowerShell 2.0 optional features on versions where they are present |
| V-253286 | MEDIUM | Disables SMB v1 protocol |
| V-288475 | MEDIUM | Disables all Wi-Fi Direct adapters, including hidden adapters |
| V-268317 | — | Removes Microsoft Copilot (provisioned and user AppX packages) |
| V-253359 | MEDIUM | Removes "Run as different user" from context menus |
| V-253340/41/42 | MEDIUM | Restricts Application, Security, and System event log access |

### Windows Server STIG scope

The Server 2022 V2R10 and Server 2025 V1R3 manuals were compared with the July 2026 Server GPO
package (Server 2022 V2R9 and Server 2025 V1R2). The GPOs contain most policy-based controls.
The artifact additionally applies these manual-XCCDF remediations during an image build:

| Action | Server 2022 STIG ID | Server 2025 STIG ID |
| --- | --- | --- |
| Remove Simple TCP/IP Services | V-254272 | V-278020 |
| Remove Telnet Client | V-254273 | V-278021 |
| Remove TFTP Client | V-254274 | V-278022 |
| Remove SMBv1 | V-254275 | V-278023 |
| Remove Windows PowerShell 2.0 | V-254278 | V-278026 |
| Disable physical Wi-Fi adapters | Not present | V-278017 |
| Disable Bluetooth Support Service | Not present | V-278018 |

Server feature-removal failures stop the artifact. Server 2025 physical Wi-Fi and Bluetooth are
disabled because Azure Virtual Desktop session hosts have no approved physical wireless use.
These checks are distinct from the Windows 11 Wi-Fi Direct adapter finding.

The following manual checks still need separate handling or deployment evidence:

- Event log findings inspect the ACLs on the `.evtx` files. The client `CustomSD` registry action
  is not claimed as satisfying these Server findings.
- Volume format, certificate-installation-file cleanup, antivirus/IDPS, patch timeliness,
  approved DoW certificate stores, account governance, LAPS, and legal notice values require
  runtime validation or organization-specific inputs and evidence.
- OpenSSH findings in Server 2025 are not applicable when OpenSSH is not installed. The artifact
  does not install OpenSSH solely to make those conditional findings applicable.
- Domain Controller-only findings are outside scope because this artifact rejects domain
  controllers and imports only Member Server GPOs.

The artifact intentionally changes STIG-defined remote-interactive-logon rights for AVD compatibility.
In particular, allowing local RDS logon removes local-account deny SIDs from
`SeDenyRemoteInteractiveLogonRight`, which is a documented deviation from Server 2022 V-254439
and Server 2025 V-278188. Local console interactive logon rights remain unchanged. The artifact also removes the GPO
setting that renames the built-in Administrator account, so Server 2022 V-254447 and Server 2025
V-278197 must be addressed by the approved account-management process. These deviations must be
included in the system security plan and accepted by the authorizing official where applicable.

### 7. Version Tracking

- Detects each applicable STIG release from its folder name, such as `DoD Windows 11 v2r8`
- Records mixed Server package releases with an explicit Member Server role, such as `DoD WinSvr 2022 MS = v2r9`
- Stamps a separate registry value for every successfully applied STIG at `HKLM:\Software\DoD\STIG`
- Enables upgrade detection on subsequent runs

## Offline Usage

To use this script in air-gapped or offline environments:

### Download LGPO Tool

Download <https://download.microsoft.com/download/8/5/C/85C25433-A1B0-4FFA-9429-7E023E7DA8D8/LGPO.zip>
and place it in the same directory as the script.

### Download STIG GPO Package

Download the latest package ZIP file from <https://public.cyber.mil/stigs/gpo> and place it in the
same directory as the script.

### Run Script

```powershell
.\Apply-STIGsAVD.ps1
```

## Logging

Logs are created in:

```text
C:\Windows\Logs\Configuration\Apply-STIGs-<timestamp>.log
```

## Version Management

The script implements version tracking to support upgrades:

- **Initial Run:** Creates one registry value per applicable STIG, using the STIG name and its `v<major>r<revision>` release
- **Upgrade Mode (`-Upgrade`):** Compares every applicable package release with its existing registry value
- **Missing or Different Value:** Resets Local Group Policy before applying all applicable STIGs
- **All Values Match:** Skips policy reset and applies the STIGs incrementally
- **Legacy Migration:** Removes the old package-level `Version` value after all individual values are stamped successfully

## Functions

| Function | Description |
| --- | --- |
| `Disable-OptionalFeatureIfEnabled` | Disables a Windows optional feature if currently enabled |
| `Get-InstalledApplication` | Queries registry for installed applications |
| `Get-InternetFile` | Downloads files from URLs with progress tracking |
| `Get-OperatingSystemContext` | Classifies supported client and server operating systems, prioritizing multi-session SKU 175 over product type |
| `Get-GpoBackupDisplayName` | Reads a GPO backup display name from `Backup.xml` |
| `Get-ApplicableGpoFolders` | Selects applicable backups and excludes Domain Controller GPOs from Server packages |
| `Uninstall-WindowsServerFeatureIfInstalled` | Removes a prohibited Server feature and fails if servicing does not report success |
| `New-Log` | Initializes logging infrastructure |
| `Reset-LocalPolicy` | Resets Local Group Policy and optionally Local Security Policy |
| `Set-RegistryValue` | Creates or updates registry values |
| `Get-StigVersionMap` | Extracts each STIG name and release from applicable package folder names |
| `Update-LocalGPOTextFile` | Creates LGPO text files for registry-based policy settings |
| `Write-Log` | Writes formatted log entries |

## Requirements

- **OS:** Windows 10/11 or Windows Server 2022/2025 Member Server; domain controllers, Windows Server 2016/2019, and other unsupported releases fail before any policy is applied
- **Permissions:** Administrator / SYSTEM
- **PowerShell:** 5.1 or higher
- **Network Access:** Required for downloading LGPO and STIG packages (unless using offline mode)

## Image Build Behavior

- The temporary extraction directory is cleared before each run and removed in a `finally` block.
- LGPO, `gpupdate`, service, optional-feature, capability, AppX, and PortProxy remediation failures stop the build rather than producing a partially hardened image.
- Optional services, features, capabilities, and packages that are not installed are treated as not applicable.
- The script does not initiate a restart. Image-build orchestration should restart the VM after this customization and before image capture.
- Packer builds must use the finalization provisioner in the `packer` subfolder as their last
  provisioner. It restores temporary Packer compatibility policy and performs Sysprep before the
  Azure ARM builder captures the VM.
- Azure VM Image Builder builds automatically install the deprovisioning override from the
  `azure-vm-image-builder` subfolder. Do not run a separate Sysprep customizer; AIB invokes the
  override from its hidden final customizer.
- Pre-stage `LGPO.zip` and the STIG package ZIP in this artifact for deterministic and air-gapped builds.

## Important Notes

### Administrator Account Handling

The script removes STIG policies that disable and rename the built-in Administrator account. This should be handled separately via:

```powershell
$adminAccount = Get-LocalUser | Where-Object { $_.SID -like "*-500" }
Rename-LocalUser -Name $adminAccount.Name -NewName $newAdminName
Disable-LocalUser -Name $newAdminName
```

### Domain vs Workgroup

The script automatically detects domain membership and supports an explicit intended-domain override:

- **Actually domain joined:** Resolves Domain Admins and Enterprise Admins in STIG-defined user-right assignments.
- **Workgroup:** Removes unresolved domain-principal placeholders.
- **Workgroup with `OverrideDomainJoin`:** Selects domain-oriented final-state settings that do not require domain SID resolution. Domain-principal assignments remain deferred until domain join.

### AVD Compatibility

Several STIG settings are incompatible with AVD and are automatically removed:

- ECC curves SSL configuration
- Firewall local policy merge (workgroup and Packer profiles)
- Edge proxy settings
- CTRL+ALT+DEL requirement (workgroup only)

## Registry Locations

### STIG Version Tracking

```text
HKLM:\Software\DoD\STIG
  DoD Windows 11: v2r8
  DoD Microsoft Edge: v2r5
  DoD Windows Defender Firewall: v2r2
  DoD Google Chrome: v2r11
  DoD WinSvr 2022 MS: v2r9
```

The exact values depend on the operating system, installed applications, and
`ApplicationsToSTIG`/`SearchForApplications` selections for that run.

### Security Mitigations

```text
HKLM:\SYSTEM\CurrentControlSet\Services\seclogon
  Start: 4 (Disabled)

HKLM:\SOFTWARE\Classes\<filetype>\shell\runasuser
  SuppressionPolicy: 4096

HKLM:\SOFTWARE\Microsoft\Cryptography\WinTrust\Config
HKLM:\SOFTWARE\WOW6432Node\Microsoft\Cryptography\WinTrust\Config
  EnableCertPaddingCheck: 1
```

## Troubleshooting

### Common Issues

**Issue:** LGPO.exe not found

- **Solution:** Ensure internet connectivity or place LGPO.zip in script directory

**Issue:** Unable to download STIG package

- **Solution:** Verify `$STIGsUrl` parameter or place STIG ZIP in script directory

**Issue:** AVD connectivity issues after STIG application

- **Solution:** Verify AVD exceptions are applied correctly; check firewall settings

**Issue:** Individual STIG release values are not stamped to the registry

- **Solution:** Ensure script runs with Administrator privileges

## Security Compliance

This script implements the following security frameworks and standards:

- DISA STIGs for Windows 10/11
- NIST 800-53 controls
- SRG (Security Requirements Guide) requirements
- CVE mitigations

## References

- [DISA STIGs](https://public.cyber.mil/stigs/)
- [LGPO Tool Documentation](https://techcommunity.microsoft.com/t5/microsoft-security-baselines/lgpo-exe-local-group-policy-object-utility-v1-0/ba-p/701045)
- [AVD Security Best Practices](https://learn.microsoft.com/en-us/azure/virtual-desktop/security-guide)

## Support

For issues or questions related to this script, refer to the main repository documentation or contact your security/compliance team.
