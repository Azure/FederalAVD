# Update FSLogix Storage Account Key On Hosts

This solution will update the FSLogix Storage Account Key on Session Hosts to support Entra ID only identities with FSLogix. This solution is intended to provide a measure of security by allowing you to easily rotate the storage account keys on a regular basis.

## Requirements

- Permissions: below are the minimum required permissions to deploy this solution
  - Virtual Machine Contributor - to execute Run Commands on the Virtual Machines  
  - Reader and Data Access - to list the storage account keys.
  - Storage Account Key Operator Service Role - if you are rotating the keys via the portal or other mechanisms before executing this solution.

## Deployment Options

### Template Spec Portal Form (First Deployment)

Publish the add-on Template Specs with
[`New-TemplateSpecs.ps1`](../../../tools/New-TemplateSpecs.ps1), then open **Template Specs** in the
Azure portal and deploy **AVD Update Storage Account Key on Session Hosts**. On **Review + create**,
select **Create**. After the deployment is submitted, select **Download template and parameters**
and retain the working parameter file for subsequent rotations.

### Blue Button (Azure Commercial / Government Alternative)

[![Deploy to Azure](../../../docs/images/deploytoazurebutton.png)](https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2Ffederalavd%2Fmain%2Fdeployments%2Fadd-ons%2FupdateStorageAccountKeyOnSessionHosts%2Fmain.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2Ffederalavd%2Fmain%2Fdeployments%2Fadd-ons%2FupdateStorageAccountKeyOnSessionHosts%2FuiFormDefinition.json) [![Deploy to Azure Gov](../../../docs/images/deploytoazuregovbutton.png)](https://portal.azure.us/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2Ffederalavd%2Fmain%2Fdeployments%2Fadd-ons%2FupdateStorageAccountKeyOnSessionHosts%2Fmain.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2Ffederalavd%2Fmain%2Fdeployments%2Fadd-ons%2FupdateStorageAccountKeyOnSessionHosts%2FuiFormDefinition.json)

### PowerShell (Subsequent Deployments)

```powershell
New-AzResourceGroupDeployment `
    -Location '<Azure location>' `
    -TemplateFile 'https://raw.githubusercontent.com/Azure/federalavd/main/deployments/add-ons/updateStorageAccountKeyOnSessionHosts/main.json' `
    -storageAccountResourceId '<FSLogix Storage Account Resource ID' `
    -storageAccountKey <Key - Either 1 or 2> `
    -vmNames @(comma separated list of Virtual Machines) `
    -ResourceGroupName 'compute resource group'
    -Verbose
```
