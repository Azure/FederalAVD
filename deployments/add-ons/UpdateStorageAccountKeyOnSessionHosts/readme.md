# Update FSLogix Storage Account Key On Hosts

This solution will update the FSLogix Storage Account Key on Session Hosts to support Entra ID only identities with FSLogix. This solution is intended to provide a measure of security by allowing you to easily rotate the storage account keys on a regular basis.

## Requirements

- Permissions: below are the minimum required permissions to deploy this solution
  - Virtual Machine Contributor - to execute Run Commands on the Virtual Machines  
  - Reader and Data Access - to list the storage account keys.
  - Storage Account Key Operator Service Role - if you are rotating the keys via the portal or other mechanisms before executing this solution.

## Deployment Options

### Azure portal UI

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2Ffederalavd%2Fmain%2Fdeployments%2Fadd-ons%2FUpdateStorageAccountKeyOnSessionHosts%2FUpdateStorageAccountKeyOnSessionHosts.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2Ffederalavd%2Fmain%2Fdeployments%2Fadd-ons%2FUpdateStorageAccountKeyOnSessionHosts%2FuiFormDefinition.json) [![Deploy to Azure Gov](https://portal.azure.us/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2Ffederalavd%2Fmain%2Fdeployments%2Fadd-ons%2FUpdateStorageAccountKeyOnSessionHosts%2FUpdateStorageAccountKeyOnSessionHosts.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2Ffederal%2Fmain%2Fdeployments%2Fadd-ons%2FUpdateStorageAccountKeyOnSessionHosts%2FuiFormDefinition.json)

### PowerShell

```powershell
New-AzResourceGroupDeployment `
    -Location '<Azure location>' `
    -TemplateFile 'https://raw.githubusercontent.com/Azure/federalavd/main/deployments/add-ons/UpdateStorageAccountKeyOnSessionHosts/UpdateStorageAccountKeyOnSessionHosts.json' `
    -storageAccountResourceId '<FSLogix Storage Account Resource ID' `
    -storageAccountKey <Key - Either 1 or 2> `
    -vmNames @(comma separated list of Virtual Machines) `
    -ResourceGroupName 'compute resource group'
    -Verbose
```
