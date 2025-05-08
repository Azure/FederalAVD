# Run Commands on Virtual Machines

This solution will allow you to run one or multiple scripts on selected virtual machines from a resource group.

## Requirements

- Permissions: below are the minimum required permissions to deploy this solution
  - Virtual Machine Contributor - to execute Run Commands on the Virtual Machines  

## Deployment Options

### Azure portal UI

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2Ffederalavd%2Fmain%2Fdeployments%2Fadd-ons%2FRunCommandsOnVms%2Fmain.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2Ffederalavd%2Fmain%2Fdeployments%2Fadd-ons%2FRunCommandsOnVms%2FuiFormDefinition.json) [![Deploy to Azure Gov](https://aka.ms/deploytoazuregovbutton)](https://portal.azure.us/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2Ffederalavd%2Fmain%2Fdeployments%2Fadd-ons%2FRunCommandsOnVms%2Fmain.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2Ffederalavd%2Fmain%2Fdeployments%2Fadd-ons%2FRunCommandsOnVms%2FuiFormDefinition.json)

### PowerShell

```powershell
New-AzResourceGroupDeployment `
    -Location '<Azure location>' `
    -TemplateFile 'https://raw.githubusercontent.com/Azure/federalavd/main/deployments/add-ons/RunCommandsOnVms/main.json' `
    -scriptUri 'Valid URL'
    -vmNames @(comma separated list of Virtual Machines) `
    -ResourceGroupName 'compute resource group'
    -Verbose
```
