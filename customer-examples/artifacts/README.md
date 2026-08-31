# Example Artifact Packages

Ready-to-use reference packages for common software and configuration tasks.
**These are not used automatically.** Copy the folders you want into `customer/artifacts/`
before running `Update-ImageArtifacts.ps1`.

## Workflow

### 1. Copy artifact folders

Copy each package folder you want into `customer/artifacts/`:

```powershell
# Copy a single package
Copy-Item -Recurse -Path "customer-examples\artifacts\Google-Chrome-Enterprise" `
          -Destination "customer\artifacts\"

# Or copy all packages at once
Copy-Item -Recurse -Path "customer-examples\artifacts\*" -Destination "customer\artifacts\"
```

### 2. Copy and edit downloads.json

Many packages require `Update-ImageArtifacts.ps1` to download their installer automatically.
Copy the example file to your customer parameters folder:

```powershell
Copy-Item -Path "customer-examples\parameters\imageManagement\downloads.json" `
          -Destination "customer\parameters\imageManagement\" -Force
```

Then open `customer\parameters\imageManagement\downloads.json` and **remove every entry
for packages you are not using**. Each entry downloads one or more files at artifact update
time — leaving entries for packages that don't exist in `customer/artifacts/` wastes
download bandwidth and upload time. The `DestinationFolders` field on each entry identifies
which artifact folder(s) receive the downloaded file.

Packages that have no `downloads.json` entry are either fully self-contained (scripts and
configuration only) or require manually staged files (such as patch files for
`Windows-Catalog-Updates`).

### 3. Upload to blob storage

```powershell
.\deployments\Update-ImageArtifacts.ps1 `
    -StorageAccountResourceId "<artifactsStorageAccountResourceId>"
```

> See [customer/README.md](../../customer/README.md) for full copy commands,
> `-CustomerRootPath` usage for external customer repos, and source control options.

### Passing arguments to PowerShell artifacts

Image-build and session-host customizations pass one `arguments` string through the shared
`Invoke-Customization.ps1` orchestrator. For every `.ps1` artifact, including a `.ps1` inside a
ZIP package, the orchestrator converts that string to typed named parameters and splats them into
the artifact script.

- Strings: `-Mode Full` or `-Mode 'Value with spaces'`
- Booleans: `-Enabled $true` or `-Enabled $false`
- Switches: `-Force` with no value
- String arrays: `-Domains @('a.com','b.com')`

Use native `@()` syntax for string arrays inside JSON parameter files; single quotes require no
JSON escaping. The shared parser does not evaluate `@{}` hashtables or arbitrary PowerShell
objects. If an artifact accepts structured data as a string, serialize that payload in the format
the artifact documents, such as the JSON string accepted by Edge `ManagedSearchEngines`.

See [Artifact Development Guide](../../docs/artifacts-guide.md#passing-parameters-to-artifacts) for
the complete shared argument contract. EXE, MSI, and BAT artifacts use their executable's own
command-line syntax instead of PowerShell parameter splatting.

---

## Available packages

| Package | Description | downloads.json key(s) |
| --- | --- | --- |
| [7-Zip](7-Zip/) | 7-Zip archiver | `7Zip` |
| [Adobe-Acrobat-Reader-DC](Adobe-Acrobat-Reader-DC/) | Adobe Acrobat Reader DC | `AdobeAcrobatReaderDC` |
| [Amazon-Workspaces-Client](Amazon-Workspaces-Client/) | Amazon WorkSpaces client | `AmazonWorkSpacesClient` |
| [BuiltIn-UWP-Apps](BuiltIn-UWP-Apps/) | Provision built-in Windows UWP apps for all users | `WindowsCalculator`, `MicrosoftPaint`, `SnippingTool`, `Notepad`, `MicrosoftClipchamp`, `MicrosoftPhotos` |
| [Configure-AVDSessionHostPolicy](Configure-AVDSessionHostPolicy/) | Configure AVD security, graphics, Shortpath, and directional clipboard policies | `AVDAdministrativeTemplates` |
| [Configure-ChromePolicy](Configure-ChromePolicy/) | Apply Google Chrome Group Policy settings, including search provider enforcement | `ChromeEnterpriseAdministrativeTemplates` |
| [Configure-DesktopBackground](Configure-DesktopBackground/) | Set a custom desktop wallpaper | — |
| [Configure-EdgePolicy](Configure-EdgePolicy/) | Apply Edge Group Policy settings via LGPO, including search provider enforcement | `EdgeEnterpriseAdministrativeTemplates` |
| [Configure-Office365Policy](Configure-Office365Policy/) | Apply Microsoft 365 Group Policy settings via LGPO | `Office365AdministrativeTemplates` |
| [Configure-OneDriveKFMPolicy](Configure-OneDriveKFMPolicy/) | Configure OneDrive Known Folder Move | — |
| [Configure-RemoteDesktopPolicy](Configure-RemoteDesktopPolicy/) | Configure Remote Desktop session policies | — |
| [Configure-SecureNetworkProtocols](Configure-SecureNetworkProtocols/) | Disable legacy TLS/SSL and weak cipher suites | — |
| [Configure-WindowsUpdatePolicy](Configure-WindowsUpdatePolicy/) | Configure Windows Update / WSUS policy settings | — |
| [DoD-InstallRoot](DoD-InstallRoot/) | Install DoD Root CA certificates | `DoDInstallRoot` |
| [DoD-STIGs](DoD-STIGs/) | Apply DoD STIGs via LGPO | `DoDSTIGGPOPackage`, `LGPO` |
| [DoD-Windows11-STIG-Intune-Delta](DoD-Windows11-STIG-Intune-Delta/) | Windows 11 STIG delta settings for Intune-managed devices | — |
| [Enable-CertPaddingCheck](Enable-CertPaddingCheck/) | Enable certificate padding check registry key | — |
| [Git-for-Windows](Git-for-Windows/) | Git for Windows | `GitForWindows` |
| [Google-Chrome-Enterprise](Google-Chrome-Enterprise/) | Google Chrome Enterprise MSI | `GoogleChromeEnterprise` |
| [LGPO](LGPO/) | Microsoft LGPO tool (Local Group Policy Object) | `LGPO` |
| [Microsoft-AVD-Multimedia-Redirection](Microsoft-AVD-Multimedia-Redirection/) | AVD multimedia redirection service and browser extensions (Azure Commercial only) | `AVDMultimediaRedirection` |
| [Microsoft-AzCLI](Microsoft-AzCLI/) | Azure CLI | `AzCli` |
| [Microsoft-Defender-VDI-Onboarding](Microsoft-Defender-VDI-Onboarding/) | Stage one-time Microsoft Defender for Endpoint non-persistent VDI onboarding | - (tenant package is manually staged) |
| [Microsoft-Edge-Enterprise](Microsoft-Edge-Enterprise/) | Microsoft Edge Enterprise MSI | `MicrosoftEdgeEnterprise` |
| [Microsoft-FSLogix](Microsoft-FSLogix/) | FSLogix Apps | `FSLogix` |
| [Microsoft-Power-BI-Desktop](Microsoft-Power-BI-Desktop/) | Power BI Desktop | `PowerBIDesktop` |
| [Microsoft-PowerShell-7](Microsoft-PowerShell-7/) | PowerShell 7 | `PowerShell7` |
| [Microsoft-VSCode](Microsoft-VSCode/) | Visual Studio Code | `VSCode` |
| [Notepad-PlusPlus](Notepad-PlusPlus/) | Notepad++ | `NotepadPlusPlus` |
| [PuTTY](PuTTY/) | PuTTY SSH client | `PuTTY` |
| [Use-KeyVault-Secret](Use-KeyVault-Secret/) | Retrieve an Azure Key Vault secret from a Run Command using a user-assigned managed identity | — |
| [Windows-Catalog-Updates](Windows-Catalog-Updates/) | Windows patches from Microsoft Update Catalog (air-gapped) | — (manually staged) |
