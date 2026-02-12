# Run Commands on Virtual Machines

This solution will allow you to run one or multiple scripts on selected virtual machines from a resource group.

## Requirements

- Permissions: below are the minimum required permissions to deploy this solution
  - Virtual Machine Contributor - to execute Run Commands on the Virtual Machines  

## Deployment Options

### Azure portal UI

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2Ffederalavd%2Fmain%2Fdeployments%2Fadd-ons%2FRunCommandsOnVms%2Fmain.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2Ffederalavd%2Fmain%2Fdeployments%2Fadd-ons%2FRunCommandsOnVms%2FuiFormDefinition.json) [![Deploy to Azure Gov](https://aka.ms/deploytoazuregovbutton)](https://portal.azure.us/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2Ffederalavd%2Fmain%2Fdeployments%2Fadd-ons%2FRunCommandsOnVms%2Fmain.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2Ffederalavd%2Fmain%2Fdeployments%2Fadd-ons%2FRunCommandsOnVms%2FuiFormDefinition.json)

### PowerShell

#### Example 1: Single Script from URI

Run a single PowerShell script from a public URI on selected VMs. This is the simplest approach when your script is hosted at an accessible URL.

```powershell
New-AzSubscriptionDeployment `
    -Location 'usgovvirginia' `
    -TemplateFile 'https://raw.githubusercontent.com/Azure/federalavd/main/deployments/add-ons/RunCommandsOnVms/main.json' `
    -resourceGroupName 'rg-avd-sessionhosts-usgv' `
    -vmNames @('avd-vm-01', 'avd-vm-02', 'avd-vm-03') `
    -runCommandName 'InstallSoftware' `
    -scriptUri 'https://raw.githubusercontent.com/contoso/scripts/main/Install-Software.ps1' `
    -Verbose
```

#### Example 2: Multiple Scripts from Storage Account

Run multiple scripts stored in an Azure Storage Account blob container on selected VMs. Ideal for orchestrating complex configurations or software installations in sequence.

**Required format for scripts parameter:**
Each script object must contain:
- `name` - Unique identifier for the run command (alphanumeric, no spaces)
- `blobNameOrUri` - Blob name (if in container) or full URI
- `arguments` (optional) - Space-separated arguments to pass to the script

```powershell
# Define multiple scripts to run in sequence
$scripts = @(
    @{
        name = 'ConfigureFirewall'
        blobNameOrUri = 'Configure-Firewall.ps1'
        arguments = '-AllowRDP $true -AllowHTTPS $true'
    },
    @{
        name = 'InstallAVDAgents'
        blobNameOrUri = 'Install-AVDAgents.ps1'
        arguments = '-HostPoolToken "YOUR_TOKEN_HERE"'
    },
    @{
        name = 'ApplyGroupPolicies'
        blobNameOrUri = 'Apply-GPO.ps1'
        arguments = ''
    }
)

# Deploy with storage account and managed identity
New-AzSubscriptionDeployment `
    -Location 'usgovvirginia' `
    -TemplateFile 'https://raw.githubusercontent.com/Azure/federalavd/main/deployments/add-ons/RunCommandsOnVms/main.json' `
    -resourceGroupName 'rg-avd-sessionhosts-usgv' `
    -vmNames @('avd-vm-01', 'avd-vm-02', 'avd-vm-03') `
    -scripts $scripts `
    -scriptsStorageAccountName 'sastorageaccountusgv' `
    -scriptsContainerName 'scripts' `
    -scriptsUserAssignedIdentityResourceId '/subscriptions/SUB-ID/resourceGroups/rg-identity/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uai-scripts' `
    -Verbose
```

**Note:** The managed identity must have **Storage Blob Data Reader** role on the storage account.

#### Example 3: Inline Script Content

Provide PowerShell script content directly in the deployment without needing external files. Perfect for quick one-off commands or when you want to keep everything in your deployment code.

```powershell
# Define your PowerShell script as a multi-line string
$scriptContent = @'
# Configure Windows Defender exclusions for FSLogix
$exclusionPaths = @(
    'C:\Program Files\FSLogix\Apps\frxdrv.sys',
    'C:\Program Files\FSLogix\Apps\frxdrvvt.sys',
    'C:\Program Files\FSLogix\Apps\frxccd.sys',
    '%ProgramData%\FSLogix\Cache\*.VHD',
    '%ProgramData%\FSLogix\Cache\*.VHDX'
)

foreach ($path in $exclusionPaths) {
    Add-MpPreference -ExclusionPath $path
    Write-Host "Added exclusion: $path"
}

# Restart Windows Defender service
Restart-Service -Name WinDefend -Force
Write-Host "Windows Defender configured successfully"
'@

# Deploy with inline script content
New-AzSubscriptionDeployment `
    -Location 'usgovvirginia' `
    -TemplateFile 'https://raw.githubusercontent.com/Azure/federalavd/main/deployments/add-ons/RunCommandsOnVms/main.json' `
    -resourceGroupName 'rg-avd-sessionhosts-usgv' `
    -vmNames @('avd-vm-01', 'avd-vm-02', 'avd-vm-03') `
    -runCommandName 'ConfigureDefender' `
    -scriptContent $scriptContent `
    -timeoutInSeconds 300 `
    -Verbose
```

**Script content limits:**
- Maximum size: **256KB** of inline script content
- Supports multi-line scripts with special characters
- Line endings are automatically normalized
