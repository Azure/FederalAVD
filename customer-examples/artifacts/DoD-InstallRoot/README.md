# Deploy-InstallRoot.ps1

## Overview

This PowerShell script automates the installation of DoD InstallRoot certificates on Windows systems. InstallRoot installs the DoD PKI (Public Key Infrastructure) certificate chain, which is required for accessing DoD and other government websites that use CAC (Common Access Card) certificates.

## Purpose

- Install DoD PKI root and intermediate certificates
- Enable access to DoD websites requiring CAC authentication
- Support Federal/DoD compliance requirements
- Automate certificate installation in AVD environments
- Ensure proper certificate chain validation

## Parameters

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `DeploymentType` | String | `Install` | Runs the `Install` or `Uninstall` lifecycle. |
| `SuccessExitCodes` | Integer array | `0, 3010` | MSI exit codes accepted as successful for installation and removal. |

## Usage

### Basic Usage

```powershell
.\Deploy-InstallRoot.ps1
```

### Uninstall

```powershell
.\Deploy-InstallRoot.ps1 -DeploymentType Uninstall
```

## What the Script Does

### Installation Process

1. **Find the Installer**
   - Requires exactly one MSI file in the artifact folder
   - The artifact update workflow downloads the MSI before packaging

2. **Install InstallRoot**
   - Executes MSI installer with silent parameters
   - Parameters: `/i <msi file> /qn /norestart`
   - Waits for installation to complete
   - Captures and logs exit code
   - Retries only when Windows Installer returns exit code 1618

3. **Verification**
   - Checks installation success via exit code
   - Logs installation completion

### Uninstall Process

1. Finds the installed MSI registration for InstallRoot.
2. Runs `msiexec /x <product-code> /quiet /qn /norestart`.
3. Applies the same success-code and exit-code-1618 retry handling used by installation.

## Installation Details

### Download Source

**URL:** https://dl.dod.cyber.mil/wp-content/uploads/pki-pke/msi/InstallRoot_5.6x64.msi  
**Website:** DoD Cyber Exchange PKI/PKE page  
**File Type:** MSI (Microsoft Installer)  
**Architecture:** x64  
**Size:** ~5-10 MB  

### Current Version

- **Version:** 5.6 (as of URL reference)
- **Note:** Check DoD Cyber Exchange for latest version

### Certificates Installed

InstallRoot installs the following certificate types:

- **DoD Root CA Certificates:** Root certificates for DoD PKI
- **DoD Intermediate CA Certificates:** Intermediate certificates in the PKI chain
- **ECA (External Certificate Authority) Roots:** For external partners
- **Federal Bridge CA:** For cross-certification with other federal agencies

### Certificate Stores

Certificates are installed to:

```text
Trusted Root Certification Authorities
Intermediate Certification Authorities
```

## Use Cases

### DoD/Federal Environments

- Access DoD websites (.mil domains)
- CAC authentication for web applications
- PKI-enabled email (S/MIME)
- Code signing verification

### Government Contractors

- Access government customer portals
- Collaborate with DoD partners
- Meet contractual PKI requirements

### Azure Virtual Desktop

- Enable CAC authentication in AVD
- Support government users accessing DoD resources
- Comply with security requirements

## Exit Codes

| Exit Code | Meaning |
| --- | --- |
| **0** | Success |
| **3010** | Success - Reboot required |
| **1638** | Already installed (another version) |
| **Other** | Error occurred (see logs for details) |

## Certificates Installed

After installation, the following certificate chains are available:

### DoD PKI Hierarchy

```text
DoD Root CA 3
├── DoD Interoperability Root CA 2
├── DoD ID CA-59
├── DoD ID CA-62
└── (Additional intermediate CAs)
```

### Access Verification

Test certificate installation:

```powershell
# View installed root certificates
Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -like "*DoD*" }

# View installed intermediate certificates
Get-ChildItem Cert:\LocalMachine\CA | Where-Object { $_.Subject -like "*DoD*" }

# Test DoD website access
Invoke-WebRequest -Uri "https://www.dmdc.osd.mil" -UseBasicParsing
```

## Logging

Logs are created in:

```text
C:\Windows\Logs\Deploy-InstallRoot-<timestamp>.log
```

Log entries include:

- Existing installation detection
- Download progress
- Installation execution
- Exit codes
- Error messages

## Functions

| Function | Description |
| --- | --- |
| `Remove-MSIApplication` | Finds and removes the installed MSI application |
| `Invoke-MsiProcess` | Runs MSI operations and retries exit code 1618 contention |
| `New-Log` | Initializes logging infrastructure |
| `Write-Log` | Writes formatted log entries |

## Requirements

- **OS:** Windows 10 or Windows 11
- **Permissions:** Administrator / SYSTEM
- **PowerShell:** 5.1 or higher
- **Network Access:** Not required at installation time when the MSI is pre-staged

## Troubleshooting

### Common Issues

**Issue:** Installation fails

- **Solution:** Check logs; ensure administrator privileges; verify no Group Policy conflicts

**Issue:** Download fails

- **Solution:** Check connectivity to dl.dod.cyber.mil; verify firewall/proxy settings

**Issue:** DoD websites still show certificate errors

- **Solution:** Restart browser; clear SSL state; verify certificate installation

**Issue:** CAC authentication not working

- **Solution:** Ensure CAC middleware is installed; verify smart card reader drivers

### Verification

Check if InstallRoot is installed:

```powershell
# Check installed application
Get-WmiObject -Class Win32_Product | Where-Object { $_.Name -like "*InstallRoot*" }

# Check certificate count
(Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -like "*DoD*" }).Count

# Test specific certificate
Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -like "*DoD Root CA*" }
```

## Certificate Management

### Updating Certificates

DoD PKI certificates have expiration dates. Update InstallRoot regularly:

```powershell
# Check certificate expiration
Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -like "*DoD*" } | 
    Select-Object Subject, NotAfter | Sort-Object NotAfter
```

### Removing Old Certificates

InstallRoot may not automatically remove expired certificates:

```powershell
# View expired DoD certificates
Get-ChildItem Cert:\LocalMachine\Root | Where-Object { 
    $_.Subject -like "*DoD*" -and $_.NotAfter -lt (Get-Date) 
}

# Remove expired certificate (example - be cautious)
# Get-ChildItem Cert:\LocalMachine\Root\<Thumbprint> | Remove-Item
```

## Offline Usage

The artifact update workflow normally downloads the MSI before packaging. To stage it manually in
a connected environment, run this command from the repository root:

```powershell
Invoke-WebRequest `
    -Uri 'https://dl.dod.cyber.mil/wp-content/uploads/pki-pke/msi/InstallRoot_5.6x64.msi' `
    -OutFile 'customer-examples\artifacts\DoD-InstallRoot\InstallRoot.msi'
```

For an air-gapped environment:

1. **Download InstallRoot MSI:**
   - Download from the URL above on an approved connected workstation.
   - Validate the file according to organizational software-transfer procedures.
   - Transfer the MSI through the approved cross-domain or offline transfer process.

2. **Place in Script Directory:**

```text
   Deploy-InstallRoot.ps1
   InstallRoot.msi
   ```

3. **Run Script:**

   ```powershell
   .\Deploy-InstallRoot.ps1
   ```

## CAC Authentication

After InstallRoot installation, CAC authentication requires:

### Additional Components

1. **CAC Middleware:**
   - ActivClient (DoD standard)
   - OpenSC (open source alternative)

2. **Smart Card Reader:**
   - USB smart card reader
   - Built-in laptop reader

3. **Browser Configuration:**
   - Enable smart card authentication
   - Configure certificate selection

### Testing CAC Access

```powershell
# Test DoD CAC-enabled website
Start-Process "https://www.dmdc.osd.mil"

# Check smart card reader
Get-PnpDevice -Class SmartCardReader
```

## Group Policy Considerations

In domain environments, certificate installation may be managed via Group Policy:

- **Computer Configuration > Policies > Windows Settings > Security Settings > Public Key Policies**
- Verify InstallRoot doesn't conflict with GPO-deployed certificates

## Security Considerations

1. **Certificate Validation:** Always download InstallRoot from official DoD sources
2. **Regular Updates:** Keep InstallRoot updated to receive new/renewed certificates
3. **Expiration Monitoring:** Monitor certificate expiration dates
4. **Removal of Old Certs:** Remove expired certificates to avoid confusion
5. **Audit Logging:** Enable audit logging for certificate operations

## Best Practices

1. **Regular Updates:** Update InstallRoot quarterly or when DoD releases new versions
2. **Testing:** Test DoD website access after installation
3. **Documentation:** Document installation for compliance audits
4. **Automation:** Include in AVD image build process for government cloud
5. **Verification:** Verify certificate installation in production and test environments

## References

- [DoD Cyber Exchange PKI/PKE](https://public.cyber.mil/pki-pke/)
- [InstallRoot Download](https://dl.dod.cyber.mil/wp-content/uploads/pki-pke/msi/)
- [DoD PKI Documentation](https://public.cyber.mil/pki-pke/end-users/)
- [CAC Information](https://www.cac.mil/)

## Support

For issues or questions related to this script, refer to the main repository documentation or contact your IT support team. For DoD PKI support, contact the DoD PKI office.
