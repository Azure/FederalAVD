# Set-DesktopBackground.ps1

## Overview

This PowerShell script configures a custom desktop background image for Azure Virtual Desktop (AVD) session hosts using a built-in Registry.pol (PReg format) direct writer — no LGPO.exe and no internet access required.

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

### 1. Background Image Configuration

- Locates the first `.jpg` file in the script directory
- Creates `C:\Windows\Web\Wallpaper\Custom\` if it does not exist
- Copies the image to `C:\Windows\Web\Wallpaper\Custom\<filename>.jpg`

### 2. Policy Application

- Writes three **User-scope** policy values directly to `Registry.pol` in MS-GPREG (PReg) binary format — no LGPO.exe or internet access required:
  - `Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop` → `NoChangingWallPaper = 1` (prevents users from changing the wallpaper)
  - `Software\Microsoft\Windows\CurrentVersion\Policies\System` → `Wallpaper = <path>` (path to the image)
  - `Software\Microsoft\Windows\CurrentVersion\Policies\System` → `WallpaperStyle = 4` (Stretch)
- Updates `gpt.ini` so the Group Policy client on deployed session hosts applies the entries at logon
- `gpupdate` is not called; on deployed machines the GP client processes `Registry.pol` automatically at logon

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
User Configuration
└── Administrative Templates
    └── Desktop
        ├── Prevent changing desktop background: [Enabled]
        └── Desktop Wallpaper: [Enabled]
            ├── Wallpaper Name: C:\Windows\Web\Wallpaper\Custom\<image>.jpg
            └── Wallpaper Style: 4 (Stretch)
```

WallpaperStyle values: 0=Center, 1=Tile, 2=Stretch, 4=Stretch (fill), 6=Fit, 10=Fill, 22=Span

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
| `New-Log` | Initializes logging infrastructure |
| `Set-PolicyRegistryValue` | Queues a registry value for writing to Registry.pol |
| `Invoke-PolicyUpdate` | Flushes the queue to Registry.pol and updates gpt.ini |
| `Write-Log` | Writes formatted log entries |

## Requirements

- **OS:** Windows 10 or Windows 11
- **Permissions:** Administrator / SYSTEM
- **PowerShell:** 5.1 or higher
- **Network Access:** Not required — no LGPO download; policies written directly to Registry.pol

## Files and Directories

### Script Directory

```
Configure-DesktopBackground/
├── Set-DesktopBackground.ps1
└── sunrise.jpg (Replace with your image)
```

### System Locations

```
C:\Windows\Web\Wallpaper\Custom\<your-image>.jpg
C:\Windows\System32\GroupPolicy\
C:\Windows\Logs\Configuration\
```

## Troubleshooting

### Common Issues

**Issue:** Desktop background not applied

- **Solution:** Verify image file exists in script directory; check log for errors

**Issue:** No `.jpg` file found

- **Solution:** Place your `.jpg` background image in the same directory as the script

**Issue:** Image not displaying correctly

- **Solution:** Verify image format is JPEG; check resolution and aspect ratio

**Issue:** Users can still change wallpaper

- **Solution:** Verify Group Policy was applied; check `gpresult /h report.html`

### Verification

Check if policy was applied:

```powershell
# Check User registry.pol was written
Test-Path "$env:SystemRoot\System32\GroupPolicy\User\Registry.pol"

# Generate Group Policy report
gpresult /h C:\Temp\gpresult.html
```

## Best Practices

1. **Test First:** Test desktop background on multiple monitor configurations
2. **Image Optimization:** Compress images to reduce deployment size
3. **Naming Convention:** Use descriptive image names (e.g., `contoso-wallpaper-2025.jpg`)
4. **Version Control:** Track wallpaper changes with versioned filenames

## References

- [Microsoft Learn: Desktop Wallpaper Configuration](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/wallpaper-and-themes-windows-11)
- [AVD Customization Best Practices](https://learn.microsoft.com/en-us/azure/virtual-desktop/customize-session-host-configuration)

## Support

For issues or questions related to this script, refer to the main repository documentation or contact your IT support team.
