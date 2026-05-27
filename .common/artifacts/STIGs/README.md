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

- **Type:** String (JSON array)
- **Default:** `'["Adobe Acrobat Pro", "Adobe Acrobat Reader", "Google Chrome", "Mozilla Firefox"]'`
- **Description:** JSON string array defining third-party applications to apply STIGs to

### `SearchForApplications`

- **Type:** String (Boolean)
- **Default:** `'False'`
- **Description:** When `'True'`, verifies applications in `ApplicationsToSTIG` are installed before applying settings

### `CloudOnly`

- **Type:** String (Boolean)
- **Default:** `'True'`
- **Description:** Indicates cloud-only identity configuration. Enables cmdkey storage of storage account keys for FSLogix

### `STIGsUrl`

- **Type:** String (URL)
- **Default:** `'https://dl.dod.cyber.mil/wp-content/uploads/stigs/zip/U_STIG_GPO_Package_October_2025.zip'`
- **Description:** URL of the STIG GPO package to download and apply

### `Upgrade`

- **Type:** String (Boolean)
- **Default:** `'False'`
- **Description:** When `'True'`, checks STIG version and resets local group policy if the version has changed

### `Version`

- **Type:** String
- **Default:** `'2025.10'`
- **Format:** `YYYY.MM`
- **Description:** STIG version to stamp to the registry for tracking and upgrade detection

## Usage Examples

### Basic Usage

```powershell
.\Apply-STIGsAVD.ps1
```

### With Application Search

```powershell
.\Apply-STIGsAVD.ps1 -SearchForApplications 'True'
```

### Upgrade Mode with New Version

```powershell
.\Apply-STIGsAVD.ps1 -Upgrade 'True' -Version '2025.12'
```

### Custom Application List

```powershell
.\Apply-STIGsAVD.ps1 -ApplicationsToSTIG '["Google Chrome", "Mozilla Firefox"]'
```

### Domain-Joined Environment

```powershell
.\Apply-STIGsAVD.ps1 -CloudOnly 'False'
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
- Adjusts deny logon rights for domain/workgroup environments
- Removes ECC curves SSL configuration that breaks AVD
- Configures firewall settings for non-domain joined systems
- Removes Edge proxy configuration

### 6. Additional Security Mitigations

- **WN10-00-000175:** Disables Secondary Logon service
- **SRG-OS-000480-GPOS-00227:** Disables PortProxy
- **WN11-00-000125:** Removes Microsoft Copilot
- **SRG-OS-000095-GPOS-00049:** Removes "Run as different user" from context menus
- **CVE-2013-3900:** Enables certificate padding check

### 7. Version Tracking

- Stamps STIG version to registry at `HKLM:\Software\DoD\STIG`
- Enables upgrade detection on subsequent runs

## Offline Usage

To use this script in air-gapped or offline environments:

1. **Download LGPO Tool:**

   - URL: https://download.microsoft.com/download/8/5/C/85C25433-A1B0-4FFA-9429-7E023E7DA8D8/LGPO.zip
   - Place in the same directory as the script

2. **Download STIG GPO Package:**

   - URL: https://public.cyber.mil/stigs/gpo
   - Download the latest package ZIP file
   - Place in the same directory as the script

3. **Run Script:**

   ```powershell
   .\Apply-STIGsAVD.ps1
   ```

## Logging

Logs are created in:

```text
C:\Windows\Logs\Configuration\Apply-STIGs-<timestamp>.log
```

Log format includes:

- Timestamp
- Category (Info, Warning, Error)
- Detailed message

## Version Management

The script implements version tracking to support upgrades:

- **Initial Run:** Stamps version to `HKLM:\Software\DoD\STIG\Version`
- **Upgrade Mode:** Compares existing version with new version
- **Version Mismatch:** Resets Local Group Policy before applying new STIGs
- **Version Match:** Skips policy reset, applies STIGs incrementally

## Functions

| Function | Description |
|----------|-------------|
| `Get-InstalledApplication` | Queries registry for installed applications |
| `Get-InternetFile` | Downloads files from URLs with progress tracking |
| `Invoke-LGPO` | Applies registry text files, security templates, and audit CSVs using LGPO.exe |
| `New-Log` | Initializes logging infrastructure |
| `Reset-LocalPolicy` | Resets Local Group Policy and optionally Local Security Policy |
| `Set-RegistryValue` | Creates or updates registry values |
| `Update-LocalGPOTextFile` | Creates LGPO text files for registry-based policy settings |
| `Write-Log` | Writes formatted log entries |

## Requirements

- **OS:** Windows 10 or Windows 11
- **Permissions:** Administrator / SYSTEM
- **PowerShell:** 5.1 or higher
- **Network Access:** Required for downloading LGPO and STIG packages (unless using offline mode)

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
  Version: <YYYY.MM>
```

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

**Issue:** Version not stamped to registry

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
