# Run Commands on Virtual Machines

This solution will allow you to run one or multiple scripts on selected virtual machines from a resource group.

## Requirements

- **Deployment user or service principal**
  - **Virtual Machine Contributor** on the resource group containing the target VMs. This permits the deployment to create Run Command resources and update the VMs when managed identities are attached.
  - **Managed Identity Operator** on each user-assigned managed identity supplied for scripts or logging. The deployment attaches those identities to the target VMs. This role is not needed when no user-assigned identity is supplied.
- **Managed identities used by the deployment** (these are runtime permissions, not permissions for the deployment user)
  - **Storage Blob Data Reader** on the scripts container for an identity used to download scripts from private Blob Storage.
  - **Storage Blob Data Contributor** on the logs container for an identity used to write Run Command output and error logs.
- **Azure portal form users**
  - The form queries storage accounts and containers to populate its selectors. Portal users need read access to the selected storage account and its container resources, and read access to any selected user-assigned identity. This is Azure Resource Manager access for the form; it does not grant blob data access.

> **Note:** No subscription-level role is required when the deployment and target VMs are in the specified resource group. If a supplied identity or storage account is in another resource group, grant the required permissions at that resource's scope. VMs in different Azure regions within the target resource group are supported.

## Deployment Options

### Template Spec Portal Form (First Deployment)

Publish the add-on Template Specs with
[`New-TemplateSpecs.ps1`](../../../tools/New-TemplateSpecs.ps1), then open **Template Specs** in the
Azure portal and deploy **Run Commands on VMs**. On **Review + create**, select **Create**. After the
deployment is submitted, select **Download template and parameters** and retain the working
parameter file for subsequent runs.

### Blue Button (Azure Commercial / Government Alternative)

[![Deploy to Azure](../../../docs/images/deploytoazurebutton.png)](https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2Ffederalavd%2Fmain%2Fdeployments%2Fadd-ons%2FrunCommandsOnVms%2Fmain.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2Ffederalavd%2Fmain%2Fdeployments%2Fadd-ons%2FrunCommandsOnVms%2FuiFormDefinition.json) [![Deploy to Azure Gov](../../../docs/images/deploytoazuregovbutton.png)](https://portal.azure.us/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2Ffederalavd%2Fmain%2Fdeployments%2Fadd-ons%2FrunCommandsOnVms%2Fmain.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2Ffederalavd%2Fmain%2Fdeployments%2Fadd-ons%2FrunCommandsOnVms%2FuiFormDefinition.json)

### PowerShell (Subsequent Deployments)

#### Example 1: Single Script from URI

Run a single PowerShell script from a public URI on selected VMs. This is the simplest approach when your script is hosted at an accessible URL.

```powershell
New-AzResourceGroupDeployment `
    -ResourceGroupName 'rg-avd-sessionhosts-usgv' `
    -TemplateFile 'https://raw.githubusercontent.com/Azure/federalavd/main/deployments/add-ons/runCommandsOnVms/main.json' `
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
New-AzResourceGroupDeployment `
    -ResourceGroupName 'rg-avd-sessionhosts-usgv' `
    -TemplateFile 'https://raw.githubusercontent.com/Azure/federalavd/main/deployments/add-ons/runCommandsOnVms/main.json' `
    -vmNames @('avd-vm-01', 'avd-vm-02', 'avd-vm-03') `
    -scripts $scripts `
    -scriptsStorageAccountName 'sastorageaccountusgv' `
    -scriptsContainerName 'scripts' `
    -scriptsUserAssignedIdentityResourceId '/subscriptions/SUB-ID/resourceGroups/rg-identity/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uai-scripts' `
    -Verbose
```

**Note:** The identity used to download scripts needs **Storage Blob Data Reader** on the scripts
container. If logging is enabled, the identity used for logs needs **Storage Blob Data Contributor**
on the logs container. The same identity can be used for both when it has the required read and
write data-plane permissions. When either identity is supplied, the deployment user also needs
**Managed Identity Operator** on that identity so it can be attached to the VMs.

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
New-AzResourceGroupDeployment `
    -ResourceGroupName 'rg-avd-sessionhosts-usgv' `
    -TemplateFile 'https://raw.githubusercontent.com/Azure/federalavd/main/deployments/add-ons/runCommandsOnVms/main.json' `
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

## Troubleshooting

### Run Commands Stuck or Causing Deployment Conflicts

Run Command resources are persistent ARM objects that remain on the VM after execution. If a deployment fails or is interrupted, orphaned run commands can block redeployment (name conflict) or accumulate toward the per-VM limit (~25).

See [Run Commands Stuck or Blocking Redeployment](../../../docs/troubleshooting.md#run-commands-stuck-or-blocking-redeployment) in the troubleshooting guide for PowerShell, CLI, and portal removal steps.
