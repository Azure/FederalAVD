# Set-DesktopBackground.ps1

## Overview

This PowerShell script configures a custom desktop background image for Azure Virtual Desktop (AVD) session hosts. It uses the Local Group Policy Object (LGPO) tool to apply desktop wallpaper settings via Group Policy, with fallback support for WMI Bridge for CSP if LGPO.exe is unavailable.

## Purpose

- Set custom desktop background/wallpaper for AVD session hosts
- Apply desktop background settings via Local Group Policy
- Support image customization during deployment
- Enhance branding and user experience

## Prerequisites

### Required Files

**Desktop Background Image:**

- **File name:** Must have `.jpg` extension (default: `sunrise.jpg`)
- **Format:** JPEG
- **Resolution:** High resolution recommended (4K: 3840x2560 pixels)
- **Aspect ratio:** 3:2 (width:height)
- **Location:** Same directory as this script

**IMPORTANT:** You must replace the default `sunrise.jpg` file with your organization's custom desktop background image before deployment.

### LGPO Tool

**Online Mode:**

- Script automatically downloads LGPO.zip from Microsoft

**Offline/Air-Gapped Mode:**

- Download: https://download.microsoft.com/download/8/5/C/85C25433-A1B0-4FFA-9429-7E023E7DA8D8/LGPO.zip
- Place `LGPO.zip` in the same directory as this script

## Usage

### Basic Usage

```powershell
.\Set-DesktopBackground.ps1
```

### Deployment Scenarios

**Image Customization:**
Used during custom image build via VM Run Commands

**Session Host Deployment:**
Applied via VM Run Commands during session host deployment

**Manual Configuration:**
Run directly on session hosts with Administrator privileges

## How It Works

### 1. LGPO Tool Setup

- Checks if `lgpo.exe` exists in `C:\Windows\System32`
- If not found, downloads LGPO.zip from Microsoft
- Extracts and copies LGPO.exe to system directory

### 2. Background Image Configuration

- Locates `.jpg` file in script directory
- Copies image to `C:\Windows\Web\Wallpaper\Windows`
- Creates LGPO text file with wallpaper policy settings

### 3. Policy Application

- Applies wallpaper settings using LGPO.exe
- Sets wallpaper style (Fill, Fit, Stretch, Tile, Center, or Span)
- Prevents users from changing wallpaper
- Runs `gpupdate /force` to apply changes immediately

## Desktop Background Requirements

### Image Specifications

| Requirement | Recommendation |
|-------------|----------------|
| **Format** | JPG (JPEG) |
| **Resolution** | 4K (3840x2560 pixels) or higher |
| **Aspect Ratio** | 3:2 (width:height) |
| **File Size** | Optimized for deployment (< 5MB recommended) |
| **Color Space** | sRGB |

### Design Considerations

- **Accessibility:** Ensure desktop icons are readable over the background
- **Branding:** Follow organizational branding guidelines
- **Professional:** Appropriate for enterprise/government environments
- **Resolution Testing:** Test across different monitor resolutions
- **Aspect Ratios:** Consider 16:9, 16:10, and 3:2 monitors

## Configuration Options

### Wallpaper Style

The script sets the wallpaper style via Group Policy. The default style is applied through LGPO settings:

- **Fill:** Scales image to fill screen (crops if needed)
- **Fit:** Scales image to fit screen (no cropping, may show borders)
- **Stretch:** Stretches image to fill screen (may distort)
- **Tile:** Repeats image across screen
- **Center:** Centers image without scaling
- **Span:** Spans image across multiple monitors

### Policy Settings Applied

```
Computer Configuration
└── Administrative Templates
    └── Desktop
        └── Desktop
            ├── Desktop Wallpaper: [Enabled]
            │   └── Wallpaper Name: C:\Windows\Web\Wallpaper\Windows\<image>.jpg
            │   └── Wallpaper Style: Fill
            └── Prevent changing desktop background: [Enabled]
```

## Logging

Logs are created in:

```text
C:\Windows\Logs\Configuration\Set-DesktopBackground-<timestamp>.log
```

Log format includes:

- Timestamp
- Category (Info, Warning, Error)
- Detailed operation messages

## Functions

| Function | Description |
|----------|-------------|
| `Get-InternetFile` | Downloads files from URLs with progress tracking |
| `Invoke-LGPO` | Applies Group Policy settings using LGPO.exe |
| `New-Log` | Initializes logging infrastructure |
| `Set-RegistryValue` | Creates or updates registry values |
| `Update-LocalGPOTextFile` | Creates LGPO text files for policy settings |
| `Write-Log` | Writes formatted log entries |

## Requirements

- **OS:** Windows 10 or Windows 11
- **Permissions:** Administrator / SYSTEM
- **PowerShell:** 5.1 or higher
- **Network Access:** Required for downloading LGPO (unless using offline mode)

## Files and Directories

### Script Directory

```
Configure-DesktopBackground/
├── Set-DesktopBackground.ps1
├── sunrise.jpg (Replace with your image)
└── LGPO.zip (Optional, for offline deployment)
```

### System Locations

```
C:\Windows\System32\lgpo.exe
C:\Windows\Web\Wallpaper\Windows\<your-image>.jpg
C:\Windows\System32\GroupPolicy\
C:\Windows\Logs\Configuration\
```

## Troubleshooting

### Common Issues

**Issue:** Desktop background not applied

- **Solution:** Run `gpupdate /force` manually; verify image path and permissions

**Issue:** LGPO.exe not found

- **Solution:** Ensure internet connectivity or place LGPO.zip in script directory

**Issue:** Image not displaying correctly

- **Solution:** Verify image format is JPEG; check resolution and aspect ratio

**Issue:** Users can still change wallpaper

- **Solution:** Verify Group Policy was applied; check `gpresult /h report.html`

### Verification

Check if policy was applied:

```powershell
# Check registry value
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name Wallpaper

# Generate Group Policy report
gpresult /h C:\Temp\gpresult.html
```

## Best Practices

1. **Test First:** Test desktop background on multiple monitor configurations
2. **Image Optimization:** Compress images to reduce deployment size
3. **Offline Readiness:** Include LGPO.zip in script directory for air-gapped environments
4. **Naming Convention:** Use descriptive image names (e.g., `contoso-wallpaper-2025.jpg`)
5. **Version Control:** Track wallpaper changes with versioned filenames

## References

- [Microsoft Learn: Desktop Wallpaper Configuration](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/wallpaper-and-themes-windows-11)
- [LGPO Tool Documentation](https://techcommunity.microsoft.com/t5/microsoft-security-baselines/lgpo-exe-local-group-policy-object-utility-v1-0/ba-p/701045)
- [AVD Customization Best Practices](https://learn.microsoft.com/en-us/azure/virtual-desktop/customize-session-host-configuration)

## Support

For issues or questions related to this script, refer to the main repository documentation or contact your IT support team.
