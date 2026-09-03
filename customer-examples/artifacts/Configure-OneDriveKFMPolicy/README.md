# Configure-OneDrive.ps1

## Overview

This PowerShell script configures OneDrive Known Folder Move (KFM) policies for Azure Virtual
Desktop environments using a built-in Registry.pol (PReg format) direct writer - no LGPO.exe
required. It enables silent OneDrive account configuration, Files On-Demand, and automatic
redirection of Desktop, Documents, and Pictures to OneDrive for Business.

> This is a customer example. Copy the folder to `customer/artifacts/` before customizing or
> packaging it. Run it during image build after OneDrive has been installed per-machine.

## Purpose

- Enable OneDrive Known Folder Move (KFM) via Local Group Policy
- Silently configure OneDrive for Microsoft Entra joined session hosts
- Enable Files On-Demand to limit initial hydration of cloud content
- Automatically redirect Desktop, Documents, and Pictures folders to OneDrive
- Prevent users from redirecting protected folders back to the local profile
- Optionally enable OneDrive integration for RemoteApp sessions

## Parameters

### `TenantId`

- **Type:** String
- **Required:** Yes
- **Description:** The Microsoft Entra tenant ID for your organization
- **Format:** GUID (e.g., `12345678-1234-1234-1234-123456789012`)
- **Purpose:** Associates OneDrive KFM with your specific Microsoft 365 tenant

### `EnableRemoteApp`

- **Type:** Switch
- **Required:** No
- **Description:** Enables `EnableEnhancedShellExperienceForRemoteApp` when OneDrive must launch
    and remain active with published RemoteApp sessions. Omit for full desktop deployments.

### `WarningMinDiskSpaceLimitInMB`

- **Type:** Integer
- **Required:** No
- **Default:** `10240` (10 GB)
- **Range:** `0` through `10240000` MB
- **Description:** Warns users when downloading a OneDrive file would leave less than this amount
    of available space.

### `MinDiskSpaceLimitInMB`

- **Type:** Integer
- **Required:** No
- **Default:** `5120` (5 GB)
- **Range:** `0` through `10240000` MB
- **Description:** Blocks OneDrive file downloads when available space is below this amount. It
    must not exceed `WarningMinDiskSpaceLimitInMB`.

## Usage Examples

### Basic Usage

```powershell
.\Configure-OneDrive.ps1 -TenantId "12345678-1234-1234-1234-123456789012"
```

### With Variable

```powershell
$tenantId = "12345678-1234-1234-1234-123456789012"
.\Configure-OneDrive.ps1 -TenantId $tenantId
```

### Custom Free-Space Thresholds

```powershell
.\Configure-OneDrive.ps1 `
    -TenantId "12345678-1234-1234-1234-123456789012" `
    -WarningMinDiskSpaceLimitInMB 15360 `
    -MinDiskSpaceLimitInMB 10240
```

### Finding Your Tenant ID

```powershell
# Method 1: Microsoft Entra admin center
# Navigate to: Identity > Overview > Tenant ID

# Method 2: PowerShell (Az module)
Connect-AzAccount
(Get-AzContext).Tenant.Id
```

## What the Script Does

### 1. OneDrive ADMX Templates

- Locates the OneDrive version folder under the install directory (supports both per-machine `%ProgramFiles%\Microsoft OneDrive` and per-user `%ProgramFiles(x86)%\Microsoft OneDrive`)
- Copies `OneDrive.admx` to `C:\Windows\PolicyDefinitions\`
- Copies matching `.adml` files to `C:\Windows\PolicyDefinitions\en-us\`

### 2. OneDrive and KFM Configuration

The script configures these computer policies:

| Registry value | Value | Effect |
| --- | --- | --- |
| `SilentAccountConfig` | `1` | Silently configures OneDrive using an available Microsoft Entra credential. |
| `FilesOnDemandEnabled` | `1` | Makes new synchronized content online-only by default and downloads content when opened. |
| `KFMSilentOptIn` | Tenant ID | Silently moves Desktop, Documents, and Pictures into the organization's OneDrive. |
| `KFMBlockOptOut` | `1` | Prevents users from redirecting protected folders back to the local profile. |
| `WarningMinDiskSpaceLimitInMB` | `10240` by default | Warns before a download would reduce available space below the configured MB threshold. |
| `MinDiskSpaceLimitInMB` | `5120` by default | Blocks OneDrive downloads below the configured available-space threshold. |
| `EnableEnhancedShellExperienceForRemoteApp` | `1` when selected | Enables the enhanced shell behavior used by OneDrive in RemoteApp scenarios. |

#### Silent Known Folder Move

- **Policy:** `KFMSilentOptIn`
- **Value:** Your Tenant ID
- **Effect:** Automatically moves known folders to OneDrive without user prompts
- **Folders Affected:** Desktop, Documents, Pictures

#### Block Opt-Out

- **Policy:** `KFMBlockOptOut`
- **Value:** `1` (Enabled)
- **Effect:** Prevents users from stopping known folder redirection
- **Purpose:** Ensures data is backed up to OneDrive

### 3. Policy Application

- Writes settings directly to `Registry.pol` in MS-GPREG (PReg) binary format - no LGPO.exe required
- Updates `gpt.ini` so the Group Policy client on deployed session hosts knows to process the Registry CSE
- `gpupdate` is intentionally not called during image build; the GP client processes `Registry.pol` automatically at startup/logon on deployed machines

### 4. Registry Configuration

- Sets registry values for OneDrive KFM
- Applies to all users via Computer Configuration

## Policy Settings Applied

```text
Computer Configuration
+-- Administrative Templates
    +-- OneDrive
        +-- Silently sign in users to the OneDrive sync app: [Enabled]
        +-- Use OneDrive Files On-Demand: [Enabled]
        +-- Silently move Windows known folders to OneDrive: [Enabled]
        |   +-- Tenant ID: [Your Tenant ID]
        +-- Prevent users from redirecting their Windows known folders to their PC: [Enabled]
        +-- Warn users who are low on disk space: [10240 MB by default]
        +-- Block file downloads when users are low on disk space: [5120 MB by default]
```

## Registry Locations

```text
HKLM:\SOFTWARE\Policies\Microsoft\OneDrive
    SilentAccountConfig: 1
    FilesOnDemandEnabled: 1
        KFMSilentOptIn: [Your Tenant ID]
        KFMBlockOptOut: 1
        WarningMinDiskSpaceLimitInMB: 10240
        MinDiskSpaceLimitInMB: 5120
```

## Known Folders

The following Windows known folders are automatically redirected to OneDrive:

| Folder | Default Path | OneDrive Path |
| --- | --- | --- |
| **Desktop** | `C:\Users\<username>\Desktop` | `C:\Users\<username>\OneDrive - <Organization>\Desktop` |
| **Documents** | `C:\Users\<username>\Documents` | `C:\Users\<username>\OneDrive - <Organization>\Documents` |
| **Pictures** | `C:\Users\<username>\Pictures` | `C:\Users\<username>\OneDrive - <Organization>\Pictures` |

## How KFM Works

### Initial Sync Process

1. **Account configuration:** On a Microsoft Entra joined host, OneDrive uses the available user
    credential to configure the work account silently.
2. **Folder check:** OneDrive checks whether Desktop, Documents, and Pictures are eligible for KFM.
3. **Silent move:** OneDrive changes the known-folder locations and begins moving eligible content
    into the organization's OneDrive sync root.
4. **Synchronization:** OneDrive uploads local content and maintains synchronization with the
    service. Files On-Demand keeps new synchronized content online-only until it is opened.

### User Experience

- **Transparent:** Users continue accessing folders normally
- **Normally silent:** Eligible users do not need to complete OneDrive account setup or KFM dialogs.
    Configuration errors can still require user or administrator remediation.
- **Automatic:** Happens on next OneDrive client startup
- **Familiar paths:** Users continue to access Desktop, Documents, and Pictures through their normal
    Windows locations after KFM succeeds.

## Benefits for AVD

### Data Protection

- **Cloud copy:** Files that finish synchronizing are stored in OneDrive
- **Host replacement:** Synchronized content remains available if a session host is replaced
- **Version History:** OneDrive maintains file version history

### User Roaming

- **Multi-Device:** Files accessible from any device
- **Session Portability:** Users get same files on any AVD host
- **Personal/Pooled:** Supported when the host and profile architecture meets OneDrive VDI
    requirements

### Profile Optimization

- **Reduced initial hydration:** Files On-Demand downloads file content when it is opened rather
    than downloading the entire OneDrive during account setup.
- **Profile-aware storage:** The default OneDrive sync root is under `%UserProfile%`. OneDrive
    placeholders, metadata, cache, and hydrated file content therefore occupy space in an FSLogix
    Profile Container.
- **Space reclamation:** The FederalAVD full optimization profiles configure Storage Sense to
    return eligible cloud-backed files not opened for 30 days to online-only state. FSLogix VHD disk
    compaction can reclaim resulting free space from a dynamically expanding container at sign-out.
- **Low-space protection:** OneDrive warns at 10 GB free and blocks additional file downloads at
    5 GB free by default. These thresholds protect space but do not dehydrate existing content or
    shrink the FSLogix container.
- **Capacity planning:** Files On-Demand reduces local consumption but does not guarantee a small
    profile. Size and monitor containers for actual hydrated content and application data.

## Requirements

### Prerequisites

- **OS:** A OneDrive-supported Windows client or Windows Server operating system
- **OneDrive Client:** Current OneDrive sync client installed per-machine before this artifact runs
- **Permissions:** Administrator / SYSTEM
- **PowerShell:** 5.1 or higher
- **Licensing:** Microsoft 365 subscription with OneDrive for Business
- **Network:** Runtime connectivity to the required OneDrive and Microsoft 365 endpoints
- **Device identity:** Microsoft Entra joined for `SilentAccountConfig`; disable silent account
    configuration when that requirement is not met
- **Profile persistence:** Use the latest FSLogix release for supported OneDrive operation in
    nonpersistent VDI and ensure a user's container is not attached concurrently to multiple sessions

### Tenant Configuration

- **Microsoft Entra ID:** Users must have Microsoft Entra identities and an eligible credential in
    the Windows session
- **OneDrive:** OneDrive for Business enabled for users
- **Licenses:** Users must have OneDrive licenses assigned
- **Existing redirection:** Resolve Windows Folder Redirection and KFM mappings to other Microsoft
    365 tenants before enabling this policy

## Logging

Logs are created in:

```text
C:\Windows\Logs\Configuration\Configure-OneDrive-<timestamp>.log
```

Log entries include:

- ADMX/ADML copy status
- Policy application details
- Registry value creation

## Functions

| Function | Description |
| --- | --- |
| `New-Log` | Initializes logging infrastructure |
| `Set-PolicyRegistryValue` | Queues a registry value for writing to Registry.pol |
| `Remove-PolicyRegistryValue` | Queues a registry value deletion in Registry.pol |
| `Invoke-PolicyUpdate` | Flushes the queue to Registry.pol and updates gpt.ini |
| `Set-RegistryValue` | Creates or updates registry values outside Group Policy |
| `Write-Log` | Writes formatted log entries |

## Offline Image Build and Runtime Connectivity

This script has no external tool dependencies. It writes Registry.pol directly using an
embedded PReg-format writer - LGPO.exe is not required and does not need to be present. The image
build can therefore run without internet access after the per-machine OneDrive installer is staged.

This does not make OneDrive, KFM, or Files On-Demand an air-gapped runtime solution. KFM needs
OneDrive service connectivity to upload content, and opening an online-only file needs connectivity
to download it. Do not apply this configuration in a disconnected environment unless all required
service endpoints are reachable through an approved network path.

To use this script in air-gapped environments:

1. **Ensure OneDrive Client Installed:**
    - Include the approved OneDrive per-machine installer in image-build content.
    - Do not rely on the inbox client being present or current.

2. **Run Script:**

   ```powershell
   .\Configure-OneDrive.ps1 -TenantId "your-tenant-id"
   ```

## Troubleshooting

### Common Issues

**Issue:** Known folders not moving to OneDrive

- **Solution:** Confirm the host is Microsoft Entra joined, OneDrive is silently signed in, the
    tenant ID is correct, no conflicting Folder Redirection policy is enabled, and the files meet
    OneDrive sync requirements

**Issue:** Users see prompts to move folders

- **Solution:** Verify `KFMSilentOptIn` registry value; restart OneDrive client

**Issue:** Some files not syncing

- **Solution:** Check OneDrive sync health and activity, endpoint connectivity, storage quota, and
    current OneDrive restrictions and limitations

**Issue:** Folders redirected to wrong tenant

- **Solution:** Verify Tenant ID; check user is signed into correct OneDrive account

### Verification

Check if policies were applied:

```powershell
# Check KFM registry values
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\OneDrive"

# Check OneDrive status (run as user)
$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe /status

# Generate Group Policy report
gpresult /h C:\Temp\gpresult.html

# Check folder redirection
Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
```

## Best Practices

1. **Pilot testing:** Test with representative users, existing data, profile sizes, host types, and
    network conditions before broad deployment.
2. **Staged rollout:** Limit rollout waves to control initial KFM upload traffic. Microsoft currently
    recommends no more than 1,000 existing devices per day and 4,000 per week for silent KFM.
3. **Failure recovery:** Consider deploying the KFM prompt policy through organizational management
    so users can correct errors when silent KFM does not succeed.
4. **Storage planning:** Size OneDrive quotas, FSLogix containers, and the backing file share for
    expected hydrated data rather than total cloud capacity alone.
5. **Bandwidth management:** Consider temporary percentage-based OneDrive upload management during
    KFM rollout; remove temporary throttling after initial uploads complete.
6. **Files On-Demand:** Keep Files On-Demand enabled. If specific files or folders must not upload,
    use supported OneDrive exclusion policies and document that excluded local content is not
    protected by OneDrive.
7. **Monitoring:** Monitor OneDrive sync health, FSLogix attach and compact events, VHDX growth,
    session sign-out duration, and KFM errors.
8. **User communication:** Explain folder redirection, online-only file behavior, required network
    access, and the effect of deleting synchronized content.

## Known Limitations

### File/Folder Restrictions

OneDrive file-size, path-length, file-name, item-count, and file-type restrictions change over time.
Validate the current [OneDrive and SharePoint restrictions and limitations](https://support.microsoft.com/office/restrictions-and-limitations-in-onedrive-and-sharepoint-64883a5d-228e-48f5-b3d2-eb39e07630fa)
before rollout. KFM does not support extending its scope through Windows Folder Redirection, and
existing Folder Redirection can prevent KFM from moving a folder.

Files that are excluded by OneDrive policy remain local and are not uploaded. Unsynchronized local
changes can be lost when a nonpersistent profile or session host is discarded; content that has
successfully synchronized remains in OneDrive.

### Performance Considerations

- **Initial Sync:** Large folders take time to upload
- **Network Usage:** OneDrive uses bandwidth for syncing
- **CPU Usage:** Sync process uses CPU resources
- **Profile Storage:** Hydrated files and OneDrive state consume FSLogix container space
- **Sign-out:** FSLogix compaction can extend sign-out while reclaiming VHDX space
- **Rehydration:** Storage Sense dehydration can require a later cloud download when a user opens
    an infrequently used file

## Advanced Configuration

### Additional OneDrive Policies

Files On-Demand is already enabled by this artifact. Evaluate additional policies through domain
Group Policy, Intune, or a customer-owned copy of this artifact. Common examples include:

- Allow only approved Microsoft 365 tenant IDs.
- Prevent personal OneDrive synchronization.
- Enable OneDrive sync health reporting.
- Use automatic upload bandwidth management.
- Require confirmation for large synchronized-content deletion operations.
- Configure selected SharePoint libraries as online-only, subject to Microsoft's library size and
    device-count guidance.

Do not configure `PreventNetworkTrafficPreUserSignIn` with this artifact. That setting prevents
OneDrive from starting automatically until a user explicitly starts synchronization and conflicts
with the intended silent account and KFM experience.

## References

- [Use the OneDrive sync app on virtual desktops](https://learn.microsoft.com/en-us/sharepoint/sync-vdi-support)
- [Redirect and move Windows known folders to OneDrive](https://learn.microsoft.com/en-us/sharepoint/redirect-known-folders)
- [Use OneDrive policies to control sync settings](https://learn.microsoft.com/en-us/sharepoint/use-group-policy)
- [OneDrive and SharePoint restrictions and limitations](https://support.microsoft.com/office/restrictions-and-limitations-in-onedrive-and-sharepoint-64883a5d-228e-48f5-b3d2-eb39e07630fa)
- [Configure Storage Sense](https://learn.microsoft.com/en-us/windows/configuration/storage/storage-sense)
- [FSLogix profile and ODFC containers](https://learn.microsoft.com/en-us/fslogix/concepts-container-types)
- [FSLogix VHD disk compaction](https://learn.microsoft.com/en-us/fslogix/concepts-vhd-disk-compaction)
- [FederalAVD image-build guidance](../../../docs/image-build.md#onedrive-fslogix-and-storage-sense)

## Support

For issues or questions related to this script, refer to the main repository documentation or contact your IT support team.
