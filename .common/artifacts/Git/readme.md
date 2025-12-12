# Install-GitForWindows.ps1

## Overview

This PowerShell script automates the installation of Git for Windows on Windows systems. It downloads the latest version from the official Git for Windows website and performs a silent installation.

## Purpose

- Install Git for Windows automatically
- Download latest version from official source
- Silent installation for automation scenarios
- Integration with AVD image building processes
- Support developer workstation configurations

## Parameters

None - This script runs with default settings.

## Usage

### Basic Usage

```powershell
.\Install-GitForWindows.ps1
```

## What the Script Does

### Installation Process

1. **Extract Download URL**
   - Scrapes Git for Windows website
   - Identifies latest 64-bit installer URL
   - Handles dynamic versioning

2. **Download Installer**
   - Downloads Git installer (EXE format)
   - Saves to temporary directory
   - Logs download progress and file size

3. **Install Git**
   - Executes installer with silent parameters
   - Parameters: `/VERYSILENT /NORESTART /NOCANCEL /SP- /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS`
   - Waits for installation to complete
   - Captures and logs exit code

4. **Verification**
   - Checks installation success via exit code
   - Logs installation completion

## Installation Details

### Download Source

**Website:** https://git-scm.com/download/win  
**File Type:** EXE (Executable Installer)  
**Architecture:** x64  
**Size:** ~50-60 MB  

### Default Installation Location

```
C:\Program Files\Git\
```

### Components Installed

- Git command-line tools
- Git Bash (Unix-style shell)
- Git GUI
- Shell integration (context menus)

### Installation Parameters

```
/VERYSILENT       - No UI, completely silent installation
/NORESTART        - Do not restart after installation
/NOCANCEL         - No cancel button in progress dialog
/SP-              - Disable "This will install..." message
/CLOSEAPPLICATIONS - Close applications using files being updated
/RESTARTAPPLICATIONS - Restart applications after installation
```

## Command-Line Access

After installation, Git is accessible via:

```powershell
# Check Git version
git --version

# Configure Git
git config --global user.name "Your Name"
git config --global user.email "your.email@example.com"

# Use Git Bash
& "C:\Program Files\Git\bin\bash.exe"
```

## Use Cases

### Developer Workstations

- Provide Git for source control operations
- Enable command-line Git access
- Support development workflows

### Image Customization

- Include Git in AVD developer images
- Pre-install for development teams
- Support automation scripts

### CI/CD Integration

- Install Git for build agents
- Enable repository cloning
- Support automated deployments

## Logging

Logs are created in:

```
C:\Windows\Logs\Install-GitforWindows-<timestamp>.log
```

Log entries include:

- URL extraction from website
- Download progress
- Installation execution
- Exit codes
- Error messages

## Functions

| Function | Description |
|----------|-------------|
| `Get-InternetUrl` | Extracts download URLs from web pages |
| `Get-InternetFile` | Downloads files from URLs with progress tracking |
| `New-Log` | Initializes logging infrastructure |
| `Write-Log` | Writes formatted log entries |

## Requirements

- **OS:** Windows 10 or Windows 11
- **Permissions:** Administrator / SYSTEM
- **PowerShell:** 5.1 or higher
- **Network Access:** Required for downloading installer

## Troubleshooting

### Common Issues

**Issue:** Download fails

- **Solution:** Check internet connectivity; verify firewall allows git-scm.com

**Issue:** Installation fails

- **Solution:** Check logs; ensure administrator privileges; verify no conflicting Git installations

**Issue:** 'git' command not found after installation

- **Solution:** Restart PowerShell session; verify PATH environment variable

**Issue:** URL extraction fails

- **Solution:** Check Git for Windows website availability; verify web scraping logic

### Verification

Check if Git is installed:

```powershell
# Check Git command
Get-Command git -ErrorAction SilentlyContinue

# Check version
git --version

# Check installation directory
Test-Path "C:\Program Files\Git\bin\git.exe"

# View environment PATH
$env:PATH -split ';' | Select-String -Pattern 'Git'
```

## Post-Installation Configuration

### Initial Git Configuration

```powershell
# Set user identity
git config --global user.name "John Doe"
git config --global user.email "john.doe@example.com"

# Set default branch name
git config --global init.defaultBranch main

# Configure line endings (Windows)
git config --global core.autocrlf true

# Set default editor
git config --global core.editor "code --wait"

# Enable credential helper
git config --global credential.helper wincred
```

### Common Git Commands

```powershell
# Initialize repository
git init

# Clone repository
git clone https://github.com/user/repo.git

# Check status
git status

# Stage files
git add .

# Commit changes
git commit -m "Commit message"

# Push changes
git push origin main
```

## Git Bash Access

Git for Windows includes Git Bash, providing a Unix-like environment:

```powershell
# Launch Git Bash
& "C:\Program Files\Git\bin\bash.exe"

# Common Bash commands
ls -la
cd /c/Users/
pwd
grep "pattern" file.txt
```

## Integration with Visual Studio Code

After installation, Git integrates with VS Code:

```powershell
# Install VS Code extension for Git
code --install-extension eamodio.gitlens

# Open Git Bash in VS Code terminal
# Terminal > New Terminal > Select Git Bash
```

## Security Considerations

1. **Credential Management:** Use Windows Credential Manager or SSH keys
2. **Repository Access:** Configure appropriate authentication methods
3. **SSL Verification:** Ensure SSL certificate verification is enabled
4. **Code Signing:** Verify Git installer signature before installation
5. **Access Control:** Limit Git installation to authorized users

## Best Practices

1. **Configuration:** Configure Git globally during image preparation
2. **Credentials:** Use SSH keys or credential managers (not plain text passwords)
3. **Updates:** Keep Git updated to latest version
4. **Documentation:** Document Git workflows for team consistency
5. **Training:** Provide Git training for users unfamiliar with version control

## Offline Usage

For air-gapped environments, pre-download the installer:

1. **Download Git Installer:**
   - URL: https://github.com/git-for-windows/git/releases/latest
   - Download: `Git-<version>-64-bit.exe`

2. **Place in Script Directory:**
   ```
   Install-GitForWindows.ps1
   Git-2.43.0-64-bit.exe
   ```

3. **Modify Script:** Update to use local installer instead of downloading

## References

- [Git for Windows](https://git-scm.com/download/win)
- [Git Documentation](https://git-scm.com/doc)
- [Pro Git Book](https://git-scm.com/book/en/v2)
- [Git Bash Documentation](https://gitforwindows.org/)

## Support

For issues or questions related to this script, refer to the main repository documentation or contact your IT support team.
