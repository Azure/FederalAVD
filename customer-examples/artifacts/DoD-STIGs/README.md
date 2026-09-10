# Apply-STIGsAVD.ps1

## Overview

This PowerShell script automates the application of Defense Information Systems Agency (DISA) Security Technical Implementation Guides (STIGs) to Azure Virtual Desktop (AVD) session hosts. It uses the Local Group Policy Object (LGPO) tool to apply GPO settings, security templates, audit policies, and additional registry-based mitigations.

## Purpose

- Apply DISA STIG Group Policy Objects to Windows 10/11 systems
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

### `AllowLocalUserLogon`

- **Type:** Switch
- **Description:** When specified, permits eligible local accounts to log on both interactively and through Remote Desktop Services. For user-right assignments defined by the STIG, it preserves interactive logon for local Users and Administrators and removes the local-account deny SIDs (`*S-1-5-113` and `*S-1-5-114`) from interactive and Remote Desktop Services deny rights. It does not create or modify a user-right assignment that the STIG omits. Guests and all other deny principals remain.
- **RDS membership:** A local account must still belong to either the local **Administrators** or **Remote Desktop Users** group to receive the Remote Desktop Services allow right.

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

### Allow Local User Logon

```powershell
.\Apply-STIGsAVD.ps1 -AllowLocalUserLogon
```

## What the Script Does

### 1. Initialization

- Validates OS version (Windows 10 or 11)
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
- Applies STIGs for:
  - Windows 10/11
  - Microsoft Edge
  - Windows Firewall
  - Internet Explorer
  - Windows Defender Antivirus
  - Microsoft 365/Office/Teams (if detected)
  - Third-party applications (Adobe, Chrome, Firefox, etc.)

### 5. AVD-Specific Exceptions

- Configures Remote Desktop Users remote interactive logon rights
- Adjusts deny logon rights for domain/workgroup environments and `AllowLocalUserLogon`
- Removes ECC curves SSL configuration that breaks AVD
- Configures firewall settings for non-domain joined systems
- Removes Edge proxy configuration (V-235798)
- Removes BitLocker startup PIN requirement (V-253260 - NA for stateless AVD session hosts)

### 6. Additional Security Mitigations

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

### 7. Version Tracking

- Detects each applicable STIG release from its folder name, such as `DoD Windows 11 v2r8`
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
| `New-Log` | Initializes logging infrastructure |
| `Reset-LocalPolicy` | Resets Local Group Policy and optionally Local Security Policy |
| `Set-RegistryValue` | Creates or updates registry values |
| `Get-StigVersionMap` | Extracts each STIG name and release from applicable package folder names |
| `Update-LocalGPOTextFile` | Creates LGPO text files for registry-based policy settings |
| `Write-Log` | Writes formatted log entries |

## Requirements

- **OS:** Windows 10 or Windows 11; unsupported operating systems fail before any policy is applied
- **Permissions:** Administrator / SYSTEM
- **PowerShell:** 5.1 or higher
- **Network Access:** Required for downloading LGPO and STIG packages (unless using offline mode)

## Image Build Behavior

- The temporary extraction directory is cleared before each run and removed in a `finally` block.
- LGPO, `gpupdate`, service, optional-feature, capability, AppX, and PortProxy remediation failures stop the build rather than producing a partially hardened image.
- Optional services, features, capabilities, and packages that are not installed are treated as not applicable.
- The script does not initiate a restart. Image-build orchestration should restart the VM after this customization and before image capture.
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

The script automatically detects domain membership and adjusts policies accordingly:

- **Domain-Joined:** Includes Domain Admins and Enterprise Admins in deny logon rights
- **Workgroup:** Applies deny logon rights to Guests only

### AVD Compatibility

Several STIG settings are incompatible with AVD and are automatically removed:

- ECC curves SSL configuration
- Firewall local policy merge (workgroup only)
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
