[**Home**](../README.md) | [**Quick Start**](quick-start.md) | [**Add-Ons**](add-ons.md) | [**Host Pool Deployment**](hostpool-deployment.md) | [**Image Build**](image-build.md) | [**Artifacts**](artifacts-guide.md) | [**Features**](features.md) | [**Parameters**](parameters.md) | [**Compliance**](compliance.md) | [**BCDR**](bcdr.md)

# M365 Route Table Updater Add-On For complete deployment instructions, parameter reference, redeployment guidance, and troubleshooting, see the **[M365 Route Table Updater Add-On Documentation](../deployments/add-ons/updateRouteTableWithM365Routes/README.md)**.

## Overview

The M365 Route Table Updater is an Azure Automation runbook that automatically keeps an Azure Route Table current with the latest Microsoft 365 IP address ranges. It is designed for environments that use force tunneling — where a default route sends all internet-bound traffic through an on-premises gateway or Network Virtual Appliance — and need to exempt Microsoft 365 traffic from that path.

## The Problem

In many federal and enterprise Azure deployments, virtual networks are configured with a **forced tunnel default route (0.0.0.0/0)** pointing to an on-premises firewall or NVA. This is a common requirement for inspection, audit, and policy enforcement.

The problem for AVD environments is **Microsoft 365 traffic**. Session hosts communicate continuously with Exchange Online, SharePoint, Teams, and OneDrive. When that traffic is forced on-premises:

- It exits the Microsoft backbone and re-enters it at the service edge, adding round-trip latency.
- It consumes VPN or ExpressRoute bandwidth with high-volume M365 data flows.
- Real-time workloads like Teams audio and video degrade or break entirely.

The solution is to add **more-specific host routes** for M365 IP prefixes with a Next Hop Type of Internet. These override the default forced-tunnel route and allow M365 traffic to leave Azure directly onto the Microsoft global backbone, where it stays for the entire journey to the service edge.

Microsoft publishes updated M365 IP ranges regularly. This add-on automates the download, reconciliation, and application of those routes on a configurable schedule.

## Key Features

- **Automated reconciliation**: Downloads current M365 IP ranges from the Microsoft 365 IP/URL web service and updates the route table. Routes prefixed with `M365-` (instance-specific) are fully managed; all other routes are untouched.
- **Version-gated updates**: Compares the published M365 endpoint version against a tag on the route table. If unchanged, the runbook exits without modifying anything.
- **Multi-instance support**: Supports all four M365 endpoint instances — worldwide, GCC High, DoD, and China. Multiple instances can coexist in the same route table using non-overlapping prefix namespaces.
- **Zero credential storage**: Authenticates to Azure using the Automation Account's system-assigned managed identity with Network Contributor scoped to the route table's resource group only.
- **Air-gapped support**: The runbook URI is configurable so the script can be hosted internally for Secret and Top Secret cloud deployments.

## Architecture

An Azure Automation Account is deployed with a PowerShell 7.2 runbook and a recurring schedule. The Automation Account uses a system-assigned managed identity that is granted Network Contributor on the route table's resource group. Three Automation Variables hold the runbook's configuration (route table resource ID, M365 instance, and ARM endpoint URI).

## Prerequisites

- An existing Azure Route Table used by the AVD subnet
- Resource group where the Automation Account will be deployed
- Permission to deploy resources and assign RBAC roles (Network Contributor) at resource group scope

## Deployment

### Blue Button (Azure Commercial / Government)

[![Deploy to Azure](images/deploytoazurebutton.png)](https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fadd-ons%2FupdateRouteTableWithM365Routes%2Fmain.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fadd-ons%2FupdateRouteTableWithM365Routes%2FuiFormDefinition.json) [![Deploy to Azure Gov](images/deploytoazuregovbutton.png)](https://portal.azure.us/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fadd-ons%2FupdateRouteTableWithM365Routes%2Fmain.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fadd-ons%2FupdateRouteTableWithM365Routes%2FuiFormDefinition.json)

### Template Spec (All Clouds Including Air-Gapped)

```powershell
.\tools\New-TemplateSpecs.ps1 `
  -ResourceGroupName 'rg-avd-operations-p-eus2' `
  -Location 'eastus2' `
  -CreateAddOns $true
```

Then open `ts-m365-route-{region}` in the Azure Portal.

### PowerShell

```powershell
New-AzResourceGroupDeployment `
  -ResourceGroupName 'rg-avd-networking-p-eus2' `
  -TemplateFile '.\deployments\add-ons\updateRouteTableWithM365Routes\main.json' `
  -routeTableResourceId '/subscriptions/{sub-id}/resourceGroups/{rg}/providers/Microsoft.Network/routeTables/{rt-name}' `
  -m365Instance 'Worldwide'
```

## Zero Trust Alignment

| Control | Implementation |
|---------|----------------|
| No public inbound access | `publicNetworkAccess: false` on the Automation Account |
| No stored credentials | System-assigned managed identity; `disableLocalAuth: true` |
| Least-privilege RBAC | Network Contributor scoped to the route table's resource group only |
| Diagnostic logging | Automation Account job logs → Log Analytics workspace |

> **No Private Link or Hybrid Worker required.** This runbook communicates exclusively with Azure Resource Manager (to update route table entries) and the Microsoft 365 endpoints API (a public HTTPS endpoint) using its managed identity. ARM endpoints are identity-gated, TLS-protected, and FedRAMP High authorized. Blocking inbound public access is the only required network control. See [add-ons.md — Zero Trust Alignment](add-ons.md#zero-trust-alignment) for the NIST control mapping and full rationale.

## Redeployment

Normal incremental redeployments work correctly — ARM handles the job schedule idempotently when the automation account already exists. Leave `createJobSchedule = true` for all standard deployments.

Set `createJobSchedule = false` **only** if you receive a `Conflict / A jobSchedule with same id already exists` error. This error occurs specifically when the automation account was previously **deleted from ARM** and is being recreated with the same name. Azure Automation's backend cache persists through ARM deletion and is restored the moment an account with the same name is created again, causing the create call to conflict.

For full details see the [add-on README](../deployments/add-ons/updateRouteTableWithM365Routes/README.md#redeployment).
