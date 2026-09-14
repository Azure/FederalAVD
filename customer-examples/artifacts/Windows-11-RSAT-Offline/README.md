# Windows 11 RSAT Offline

Installs these Windows 11 Remote Server Administration Tools (RSAT) capabilities without access
to Windows Update or WSUS:

- `Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0`
- `Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0`
- `Rsat.DHCP.Tools~~~~0.0.1.0`

The installer uses `Add-WindowsCapability` with both `-Source` and `-LimitAccess`. It is
idempotent: capabilities already in the `Installed` state are skipped, and each newly installed
capability is checked before the script succeeds.

## Supported configuration

- Windows 11 Enterprise or Windows 11 Enterprise multi-session, x64
- A Features on Demand source matching the target Windows 11 release, architecture, and installed
  language
- Image-build or session-host customization running as Administrator or SYSTEM

Do not use Windows 10, Windows Server, Arm64, or a different Windows 11 release's Features on
Demand payload. A mismatched or incomplete source commonly fails with `0x800f081f` (source files
could not be found) or `0x800f0950` (capability installation failed).

## Prepare the artifact

Copy this example into the git-ignored customer artifact directory:

```powershell
Copy-Item -Recurse -Path 'customer-examples\artifacts\Windows-11-RSAT-Offline' `
    -Destination 'customer\artifacts\'
```

## Get the Microsoft source media

Microsoft does not provide a stable public URL for the Windows 11 Features on Demand payload, so
it cannot be added to `downloads.json`. Obtain the **Windows 11 Languages and Optional Features**
ISO through one of these licensed download portals.

### Microsoft Volume Licensing

The account must have the **VL Administrator** or **Product download manager** role for the
applicable License ID.

1. Sign in to the [Microsoft 365 admin center](https://admin.microsoft.com/).
2. Go to **Billing** > **Your products** > **Volume licensing**.
3. Under **Products and services**, select **View downloads and keys**.
4. Search for `Windows 11 Languages and Optional Features`.
5. Select the Windows 11 release matching the target image, choose the x64 ISO download, and
   download it to the connected preparation workstation.

The direct Volume Licensing products page is
<https://admin.microsoft.com/Adminportal/Home#/subscriptions/vlnew/downloadsandkeys>.

### Visual Studio subscription

If the organization has a Visual Studio subscription that includes Windows media:

1. Sign in to <https://my.visualstudio.com/downloads> with the identity assigned the subscription.
2. Search for `Windows 11 Languages and Optional Features`.
3. Download the x64 ISO for the release matching the target image.

If neither portal offers the ISO, ask the organization's Microsoft licensing administrator or
reseller for access. Do not substitute a Windows installation ISO: it does not contain the RSAT
Features on Demand repository.

### Confirm the required release and languages

Run this on a VM created from the same image definition used by the image build:

```powershell
Get-ComputerInfo |
    Select-Object WindowsProductName, WindowsVersion, OsBuildNumber, OsArchitecture
Get-WinUserLanguageList |
    Select-Object -ExpandProperty LanguageTag
```

The Languages and Optional Features ISO must match the Windows 11 release. Include satellite
packages for every installed language. Build-number servicing revisions can differ, but do not
mix release media such as 23H2, 24H2, or 25H2.

For example, inspection of the `CLIENT_FOD_LP_X64FRE_MULTI_DV9` media showed capability package
version `10.0.26100.1`. That is Windows 11 version 24H2 media. Use it for a 24H2 target image; do
not assume that the preparation workstation's Windows release identifies the image-build target.

## Stage the source

RSAT packages have language satellites, and Active Directory tools also depend on
`Rsat.ServerManager.Tools`. Microsoft requires a well-formed repository containing package
metadata and dependencies. Do not hand-copy CAB files based only on their filenames.

### Option 1: Copy the complete ISO repository

This is the simplest and safest method, but it creates a large artifact. Mount the downloaded ISO
and copy the complete contents of its `LanguagesAndOptionalFeatures` repository into the
artifact's `Payload` directory:

```powershell
$isoPath = 'C:\Downloads\Windows11-LanguagesAndOptionalFeatures.iso'
$diskImage = Mount-DiskImage -ImagePath $isoPath -PassThru
$fodDrive = (($diskImage | Get-Volume).DriveLetter + ':')
$payloadPath = '.\customer\artifacts\Windows-11-RSAT-Offline\Payload'
New-Item -Path $payloadPath -ItemType Directory -Force | Out-Null
Copy-Item -Path "$fodDrive\LanguagesAndOptionalFeatures\*" `
    -Destination $payloadPath `
    -Recurse `
    -Force
Dismount-DiskImage -ImagePath $isoPath
```

For the currently mounted ISO at `F:`, the equivalent copy command is:

```powershell
$payloadPath = '.\customer\artifacts\Windows-11-RSAT-Offline\Payload'
New-Item -Path $payloadPath -ItemType Directory -Force | Out-Null
Copy-Item -Path 'F:\LanguagesAndOptionalFeatures\*' `
    -Destination $payloadPath `
    -Recurse `
    -Force
```

### Option 2: Export a reduced repository

This is the recommended production method. It requires both the Languages and Optional Features
ISO and a matching Windows 11 installation ISO because `DISM /Export-Source` evaluates capability
dependencies against a mounted Windows image.

1. Mount both ISOs.
2. Identify the desired Windows image index with
   `dism /Get-WimInfo /WimFile:E:\sources\install.wim`.
3. Mount that image and export each requested capability from the Features on Demand ISO:

```powershell
$windowsIsoDrive = 'E:'
$fodIsoDrive = 'F:'
$imageIndex = 6 # Replace with the index for the target Windows 11 edition.
$mountPath = 'C:\FodWork\Mount'
$repositoryPath = '.\customer\artifacts\Windows-11-RSAT-Offline\Payload'

New-Item -Path $mountPath, $repositoryPath -ItemType Directory -Force | Out-Null
dism.exe /Mount-Image `
    /ImageFile:"$windowsIsoDrive\sources\install.wim" `
    /Index:$imageIndex `
    /MountDir:$mountPath `
    /ReadOnly

$capabilityNames = @(
    'Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0'
    'Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0'
    'Rsat.DHCP.Tools~~~~0.0.1.0'
)

try {
    foreach ($capabilityName in $capabilityNames) {
        dism.exe /Image:"$mountPath" `
            /Export-Source `
            /Source:"$fodIsoDrive\LanguagesAndOptionalFeatures" `
            /Target:"$repositoryPath" `
            /CapabilityName:$capabilityName
        if ($LASTEXITCODE -ne 0) {
            throw "DISM failed to export '$capabilityName' with exit code $LASTEXITCODE."
        }
    }
}
finally {
    dism.exe /Unmount-Image /MountDir:$mountPath /Discard
}
```

If the Windows installation media contains `install.esd` instead of `install.wim`, use its path
for `/WimFile` and `/ImageFile`. The exported repository contains the required neutral packages,
language satellites, dependencies, and metadata while avoiding the size of the complete ISO.

### Files observed for an en-US x64 repository

On the mounted `CLIENT_FOD_LP_X64FRE_MULTI_DV9` ISO, the package payloads associated with the
three requested capabilities and the documented Active Directory dependency are these 16 CABs:

```text
Microsoft-Windows-ActiveDirectory-DS-LDS-Tools-FoD-Package~31bf3856ad364e35~amd64~~.cab
Microsoft-Windows-ActiveDirectory-DS-LDS-Tools-FoD-Package~31bf3856ad364e35~amd64~en-US~.cab
Microsoft-Windows-ActiveDirectory-DS-LDS-Tools-FoD-Package~31bf3856ad364e35~wow64~~.cab
Microsoft-Windows-ActiveDirectory-DS-LDS-Tools-FoD-Package~31bf3856ad364e35~wow64~en-US~.cab
Microsoft-Windows-GroupPolicy-Management-Tools-FoD-Package~31bf3856ad364e35~amd64~~.cab
Microsoft-Windows-GroupPolicy-Management-Tools-FoD-Package~31bf3856ad364e35~amd64~en-US~.cab
Microsoft-Windows-GroupPolicy-Management-Tools-FoD-Package~31bf3856ad364e35~wow64~~.cab
Microsoft-Windows-GroupPolicy-Management-Tools-FoD-Package~31bf3856ad364e35~wow64~en-US~.cab
Microsoft-Windows-DHCP-Tools-FoD-Package~31bf3856ad364e35~amd64~~.cab
Microsoft-Windows-DHCP-Tools-FoD-Package~31bf3856ad364e35~amd64~en-US~.cab
Microsoft-Windows-DHCP-Tools-FoD-Package~31bf3856ad364e35~wow64~~.cab
Microsoft-Windows-DHCP-Tools-FoD-Package~31bf3856ad364e35~wow64~en-US~.cab
Microsoft-Windows-ServerManager-Tools-FoD-Package~31bf3856ad364e35~amd64~~.cab
Microsoft-Windows-ServerManager-Tools-FoD-Package~31bf3856ad364e35~amd64~en-US~.cab
Microsoft-Windows-ServerManager-Tools-FoD-Package~31bf3856ad364e35~wow64~~.cab
Microsoft-Windows-ServerManager-Tools-FoD-Package~31bf3856ad364e35~wow64~en-US~.cab
```

The full ISO repository also includes metadata used by capability servicing:

```text
FoDMetadata_Client.cab
Microsoft-Windows-FodMetadataServicing-Desktop-CompDB-Package.cab
Microsoft-Windows-FodMetadataServicing-Desktop-Metadata-Package.cab
metadata\DesktopTargetCompDB_FOD_Metadata_Neutral.xml.cab
```

This list is an audit aid, not a supported manual-copy recipe. Microsoft states that FODs with
satellite packages require a well-formed repository and must not be assembled by selecting CABs
by filename. Let `DISM /Export-Source` determine the actual reduced repository. After export, save
the authoritative inventory with:

```powershell
Get-ChildItem -LiteralPath $repositoryPath -File -Recurse |
    ForEach-Object { $_.FullName.Substring($repositoryPath.Length).TrimStart('\') } |
    Sort-Object |
    Set-Content -LiteralPath (Join-Path $repositoryPath 'SourceManifest.txt')
```

The resulting package layout is:

```text
Windows-11-RSAT-Offline/
    Install-Windows11RSATOffline.ps1
    README.md
    Payload/
        Microsoft-Windows-*-FOD-Package*.cab
        ...dependency and language CAB files...
```

Validate either repository against a disposable VM created from the exact production image before
approving it for transfer or image builds.

## Package and upload

Package the manually staged artifact without attempting any internet downloads:

```powershell
.\deployments\Update-ImageArtifacts.ps1 `
    -PackageOnly `
    -OutputPath 'C:\AirGapTransfer' `
    -SkipDownloadingNewSources
```

For a connected Azure environment, replace `-PackageOnly` and `-OutputPath` with
`-StorageAccountResourceId '<artifactsStorageAccountResourceId>'`. The resulting artifact is
`Windows-11-RSAT-Offline.zip`.

Record and verify its SHA-256 hash before and after an offline transfer:

```powershell
Get-FileHash -Algorithm SHA256 'C:\AirGapTransfer\Windows-11-RSAT-Offline.zip'
```

## Add to an image build

Add this entry to the image build `customizations` array:

```json
{
    "name": "Windows-11-RSAT-Offline",
    "blobNameOrUri": "Windows-11-RSAT-Offline.zip",
    "restart": true
}
```

No runtime internet access is required. Set `restart` to `true` so Component-Based Servicing can
complete any pending operations before later customizations run.

## Validation

After the restart, verify the capabilities on the image or session host:

```powershell
$names = @(
    'Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0'
    'Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0'
    'Rsat.DHCP.Tools~~~~0.0.1.0'
)
Get-WindowsCapability -Online -Name $names |
    Select-Object Name, State
```

All three capabilities must report `Installed`. The installer log is written to
`C:\Windows\Logs\Software\Install-Windows11RSATOffline-<timestamp>.log`.

## References

- <https://learn.microsoft.com/windows-hardware/manufacture/desktop/features-on-demand-v2--capabilities>
- <https://learn.microsoft.com/windows-hardware/manufacture/desktop/features-on-demand-non-language-fod>
- <https://learn.microsoft.com/powershell/module/dism/add-windowscapability>
- <https://learn.microsoft.com/microsoft-365/commerce/licenses/download-vl-products>
