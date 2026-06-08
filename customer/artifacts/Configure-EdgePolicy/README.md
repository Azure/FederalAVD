# Configure-EdgePolicy.ps1

## Overview

This PowerShell script configures Microsoft Edge browser policies for Azure Virtual Desktop (AVD) environments using the Local Group Policy Object (LGPO) tool. It applies enterprise-grade security and usability settings tailored for government and highly regulated environments.

## Purpose

- Configure Microsoft Edge policies via Local Group Policy
- Enable developer tools for authorized users
- Configure SmartScreen allowlist for trusted domains
- Allow popups for specific trusted URLs
- Optimize Edge for AVD environments

## Parameters

### `AllowDeveloperTools`

- **Type:** String (Boolean)
- **Default:** `'True'`
- **Description:** Enables or disables the Developer Tools (F12) in Microsoft Edge
- **Values:** `'True'` or `'False'`

### `SmartScreenAllowListDomains`

- **Type:** String (JSON array)
- **Default:** `'["portal.azure.com", "core.windows.net", "portal.azure.us", "usgovcloudapi.net"]'`
- **Description:** Domains exempted from Microsoft Defender SmartScreen warnings
- **Policy Reference:** [SmartScreenAllowListDomains](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies#smartscreenallowlistdomains)

### `PopupsAllowedForUrls`

- **Type:** String (JSON array)
- **Default:** `'["[*.]mil","[*.]gov","[*.]portal.azure.us","[*.]usgovcloudapi.net","[*.]azure.com","[*.]azure.net"]'`
- **Description:** URL patterns allowed to display popup windows
- **Policy Reference:** [PopupsAllowedForUrls](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies#popupsallowedforurls)

## Usage Examples

### Basic Usage (Default Settings)

```powershell
.\Configure-EdgePolicy.ps1
```

### Disable Developer Tools

```powershell
.\Configure-EdgePolicy.ps1 -AllowDeveloperTools 'False'
```

### Custom SmartScreen Allowlist

```powershell
$domains = '["portal.azure.com", "portal.azure.us", "contoso.com"]'
.\Configure-EdgePolicy.ps1 -SmartScreenAllowListDomains $domains
```

### Custom Popup Allowlist

```powershell
$popups = '["[*.]mil", "[*.]gov", "[*.]contoso.com"]'
.\Configure-EdgePolicy.ps1 -PopupsAllowedForUrls $popups
```

### Complete Custom Configuration

```powershell
.\Configure-EdgePolicy.ps1 `
    -AllowDeveloperTools 'False' `
    -SmartScreenAllowListDomains '["portal.azure.us", "contoso.gov"]' `
    -PopupsAllowedForUrls '["[*.]mil", "[*.]gov"]'
```

## What the Script Does

### 1. LGPO Tool Setup

- Downloads LGPO.exe if not present in `C:\Windows\System32`
- Extracts and copies to system directory

### 2. Policy Configuration

#### Developer Tools

- Enables/disables F12 Developer Tools access
- Useful for restricting advanced browser features in production

#### SmartScreen Allowlist

- Adds trusted domains to bypass SmartScreen warnings
- Essential for internal applications and Azure portals
- Prevents false positives on known-safe domains

#### Popup Management

- Allows popups from specified URL patterns
- Critical for Azure portals and government websites
- Uses wildcard patterns for domain matching

### 3. Policy Application

- Creates LGPO text files with registry settings
- Applies policies using LGPO.exe
- Runs `gpupdate /force` to apply changes immediately

## Policy Settings Applied

```
Computer Configuration
└── Administrative Templates
    └── Microsoft Edge
        ├── Allow Developer Tools: [Configured]
        ├── Configure the list of domains for which SmartScreen won't trigger warnings: [Enabled]
        │   └── Domains: [portal.azure.com, core.windows.net, ...]
        └── Allow pop-ups on specific sites: [Enabled]
            └── URL patterns: [[*.]mil, [*.]gov, ...]
```

## Registry Locations

### Developer Tools

```
HKLM:\SOFTWARE\Policies\Microsoft\Edge
  DeveloperToolsAvailability: 1 (Allowed) or 2 (Disallowed)
```

### SmartScreen Allowlist

```
HKLM:\SOFTWARE\Policies\Microsoft\Edge\SmartScreenAllowListDomains
  1: portal.azure.com
  2: core.windows.net
  ...
```

### Popup Allowlist

```
HKLM:\SOFTWARE\Policies\Microsoft\Edge\PopupsAllowedForUrls
  1: [*.]mil
  2: [*.]gov
  ...
```

## Domain Pattern Matching

### Wildcard Patterns

The `PopupsAllowedForUrls` policy supports wildcard patterns:

| Pattern | Matches |
|---------|---------|
| `[*.]mil` | All `.mil` domains and subdomains |
| `[*.]gov` | All `.gov` domains and subdomains |
| `portal.azure.us` | Exact domain match only |
| `[*.]contoso.com` | All Contoso subdomains |

### Examples

- `[*.]mil` matches: `defense.mil`, `portal.defense.mil`, `subdomain.example.mil`
- `portal.azure.us` matches: `portal.azure.us` (exact match only)

## Logging

Logs are created in:

```
C:\Windows\Logs\Configuration\Configure-EdgePolicy-<timestamp>.log
```

Log entries include:

- LGPO tool download status
- Policy application details
- Registry value creation
- gpupdate execution results

## Functions

| Function | Description |
|----------|-------------|
| `Get-InternetFile` | Downloads files from URLs with progress tracking |
| `Invoke-LGPO` | Applies Group Policy settings using LGPO.exe |
| `New-Log` | Initializes logging infrastructure |
| `Update-LocalGPOTextFile` | Creates LGPO text files for policy settings |
| `Write-Log` | Writes formatted log entries |

## Requirements

- **OS:** Windows 10 or Windows 11
- **Permissions:** Administrator / SYSTEM
- **PowerShell:** 5.1 or higher
- **Microsoft Edge:** Chromium-based Edge (pre-installed on Windows 10/11)
- **Network Access:** Required for downloading LGPO (unless using offline mode)

## Offline Usage

To use this script in air-gapped environments:

1. **Download LGPO Tool:**
   - URL: https://download.microsoft.com/download/8/5/C/85C25433-A1B0-4FFA-9429-7E023E7DA8D8/LGPO.zip
   - Place in script directory or system32

2. **Run Script:**

   ```powershell
   .\Configure-EdgePolicy.ps1
   ```

## Default Configuration (Government Cloud)

The default settings are optimized for Azure Government Cloud environments:

### SmartScreen Allowlist

- `portal.azure.com` - Azure Commercial Portal
- `core.windows.net` - Azure Storage (Commercial)
- `portal.azure.us` - Azure Government Portal
- `usgovcloudapi.net` - Azure Government APIs

### Popup Allowlist

- `[*.]mil` - All U.S. military domains
- `[*.]gov` - All U.S. government domains
- `[*.]portal.azure.us` - Azure Government portal subdomains
- `[*.]usgovcloudapi.net` - Azure Government API subdomains
- `[*.]azure.com` - Azure commercial domains
- `[*.]azure.net` - Azure infrastructure domains

## Troubleshooting

### Common Issues

**Issue:** Edge policies not applied

- **Solution:** Run `gpupdate /force`; verify registry values were created

**Issue:** Popups still blocked on allowlisted sites

- **Solution:** Verify URL pattern syntax; restart Edge browser

**Issue:** SmartScreen still warns on allowlisted domains

- **Solution:** Check domain spelling; ensure SmartScreen is enabled in Edge

**Issue:** LGPO.exe not found

- **Solution:** Ensure internet connectivity or place LGPO.zip in script directory

### Verification

Check if policies were applied:

```powershell
# Check Developer Tools setting
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Edge" -Name DeveloperToolsAvailability

# Check SmartScreen allowlist
Get-ChildItem "HKLM:\SOFTWARE\Policies\Microsoft\Edge\SmartScreenAllowListDomains"

# Check popup allowlist
Get-ChildItem "HKLM:\SOFTWARE\Policies\Microsoft\Edge\PopupsAllowedForUrls"

# Generate Group Policy report
gpresult /h C:\Temp\gpresult.html
```

## Best Practices

1. **Customize for Environment:** Adjust domain lists for your specific requirements
2. **Security First:** Only allowlist domains you trust
3. **Test Thoroughly:** Verify popup and SmartScreen behavior after deployment
4. **Document Changes:** Keep track of custom domain additions
5. **Regular Updates:** Review and update allowlists periodically

## References

- [Microsoft Edge Enterprise Policies](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies)
- [SmartScreenAllowListDomains Policy](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies#smartscreenallowlistdomains)
- [PopupsAllowedForUrls Policy](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies#popupsallowedforurls)
- [LGPO Tool Documentation](https://techcommunity.microsoft.com/t5/microsoft-security-baselines/lgpo-exe-local-group-policy-object-utility-v1-0/ba-p/701045)

## Support

For issues or questions related to this script, refer to the main repository documentation or contact your IT support team.
