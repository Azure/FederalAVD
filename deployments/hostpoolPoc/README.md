# AVD Standard PoC

The AVD Standard PoC is a purpose-built, disposable Azure Virtual Desktop deployment for
demonstrations and first-step validation. It is not a pilot or production starting point.

> [!WARNING]
> This streamlined PoC intentionally omits many enterprise and Zero Trust controls.
> Common Azure Policy guardrails may deny the deployment in federal, regulated, or centrally
> governed subscriptions, including requirements for Private Endpoints, customer-managed keys,
> approved hub networking, restricted public access, centralized diagnostics, backup, tags, or
> approved SKUs. Deploy it only in an approved evaluation subscription or with a documented policy
> exception. Do not weaken production guardrails to make this PoC deploy.

The purpose-built [uiFormDefinition.json](./uiFormDefinition.json) uses the dedicated
[hostpoolPoc.bicep](./hostpoolPoc.bicep) entry orchestrator:

1. Creates the consolidated PoC resource group.
2. Creates one standalone virtual network and private session-host subnet.
3. Associates the subnet with an NSG and a NAT Gateway backed by a Standard static public IP.
4. Composes the shared workspace, monitoring, FSLogix, control-plane, and session-host modules with
   a fixed low-complexity PoC posture.

The PoC is a separate portal, Template Spec, and Bicep deployment surface. It does not wrap the
complete standard host-pool entry template because that would create a sixth nested ARM deployment
level. Instead, both entry points compose the same lower-level orchestration and resource modules.
This keeps PoC-only networking out of the production host-pool payload while preserving shared
resource behavior.

Session-host network interfaces do not receive public IP addresses. The private subnet has
`defaultOutboundAccess` disabled, so public connectivity uses the NAT Gateway explicitly.

The optional cloud-only FSLogix path uses storage-account-key authentication. It therefore skips
identity-based NTFS ACL configuration and does not create a temporary deployment-helper VM or
deployment-helper resource group.

## Fixed network configuration

| Setting | Value |
| --- | --- |
| VNet address prefix | `10.250.0.0/16` |
| Session-host subnet | `10.250.0.0/24` |
| Default outbound access | Disabled |
| Explicit outbound method | NAT Gateway |
| Custom DNS | None; Azure-provided DNS |
| Peering | None |
| Private endpoints | None |

The address prefixes can be overridden through PowerShell or a parameter file, but the portal form
keeps them fixed to preserve the streamlined experience.

NAT Gateway incurs hourly and data-processing charges. It provides deterministic outbound
connectivity but does not inspect or filter destinations. Delete the consolidated resource group
after the demonstration to remove the VNet, subnet, NSG, NAT Gateway, public IP, AVD resources,
session hosts, and optional FSLogix and monitoring resources.

## Deploy

Use the Template Spec portal form for the guided experience. For PowerShell:

```powershell
$user = Read-Host 'Session host local admin username' -AsSecureString
$pass = Read-Host 'Session host local admin password' -AsSecureString

New-AzDeployment `
  -Location '<azure-region>' `
  -Name 'federalavd-poc' `
  -TemplateFile '.\deployments\hostpoolPoc\hostpoolPoc.json' `
  -TemplateParameterFile '.\customer\parameters\hostpoolPoc\my-poc.parameters.json' `
  -virtualMachineAdminUserName $user `
  -virtualMachineAdminPassword $pass
```

Copy the example from
`customer-examples\parameters\hostpoolPoc\poc.hostpoolPoc.parameters.json` into the git-ignored
`customer\parameters\hostpoolPoc\` folder before changing it.

After validation, tear the PoC down and start a new pilot or production design with the full AVD
Host Pool deployment.
