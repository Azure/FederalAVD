# Update FSLogix Storage Account Key On Hosts

This solution will update the FSLogix Storage Account Key on Session Hosts to support Entra ID only identities with FSLogix. This solution is intended to provide a measure of security by allowing you to easily rotate the storage account keys on a regular basis.

## Requirements

- Permissions: below are the minimum required permissions to deploy this solution
  - Virtual Machine Contributor - to execute Run Commands on the Virtual Machines  
  - Reader and Data Access - to list the storage account keys.
  - Storage Account Key Operator Service Role - if you are rotating the keys via the portal or other mechanisms before executing this solution.

## Credential Storage and Rotation Safety

This add-on distributes the selected existing key; it does not regenerate a storage account key.
Its self-contained script defines a native `CredWriteW` function, not `cmdkey /pass`.
Session-host initialization contains an identical function, kept aligned by regression tests.
Keys beginning with `/`, and other valid Base64 characters, are passed as credential data rather
than parsed as command-line switches. A credential-write failure terminates Run Command instead
of prompting for a password or reporting success.

The credential target remains `<account>.file.<cloud storage suffix>`, with user
`localhost\<account>`, domain-password type, and local-machine persistence for SYSTEM. Test through
Run Command: running the helper interactively as an administrator writes a different identity's
credential set. The complete script is embedded unchanged in the ARM template with
`loadTextContent()`; there is no sibling helper file, ARM string replacement or internet download.
PowerShell must permit `Add-Type`. Existing local security-policy setup remains, but effective
domain/MDM policy and any required restart must permit Credential Manager storage.

Use the [two-key rotation process](https://learn.microsoft.com/en-us/azure/storage/common/storage-account-keys-manage):
distribute a verified alternate key to every consumer before regenerating the old key. Account-key
regeneration can disrupt other clients and invalidate SAS tokens signed with that key.
Initialization still selects key1; this add-on can distribute key1 or key2.

### Live Validation

Use an isolated session host and run the native credential function through Azure Run Command under SYSTEM.
Start with a unique dummy target ending in `.invalid` and dummy passwords covering:

- Leading slash: `/abc123+xyz==`
- Slash in the middle: `abc/123+xyz==`
- No slash: `abc123+xyz==`
- A second write to the same target, to verify replacement during rotation.

Copy only the `Set-StorageAccountCredential` function from
`deployments/shared/scripts/Update-StorageAccountCredential.ps1` into the Run Command test script
before calling `Set-StorageAccountCredential -TargetName <dummy target> -UserName localhost\test
-Password <dummy value>`. Confirm each write returns without a prompt, then remove only that
dummy target with `cmdkey /delete:<dummy target>`. Do not put real keys into test script literals
or diagnostic output.

Then validate a fresh EntraId/AzureFiles host deployment and profile attachment using an actual
leading-slash key, including Cloud Cache remote storage when used. Verify registration, attachment
after reboot/policy refresh, and selected-key redistribution to existing hosts. Confirm native
errors fail the Run Command clearly on a disposable VM whose credential-storage policy disallows
the operation. Review process-creation telemetry with dummy values, not real secrets.
Offline tests verify marshaling, failure handling and embedded script composition; they do not
prove effective Windows policy, SMB authentication, or deployment success.

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
