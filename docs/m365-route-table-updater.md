[**Home**](../README.md) | [**Quick Start**](quick-start.md) | [**Host Pool Deployment**](hostpool-deployment.md) | [**Image Build**](image-build.md) | [**Artifacts**](artifacts-guide.md) | [**Features**](features.md) | [**Parameters**](parameters.md) | [**Compliance**](compliance.md) | [**BCDR**](bcdr.md)

# M365 Route Table Updater Add-On

> **Note:** For complete deployment instructions, parameter reference, redeployment guidance, and troubleshooting, see the **[M365 Route Table Updater Add-On Documentation](../deployments/add-ons/updateRouteTableWithM365Routes/README.md)**.

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

## Redeployment Notice

Azure Automation caches the runbook-to-schedule association by automation account name. This cache survives deletion of the account itself. ARM cannot create a job schedule resource that already exists, causing a `Conflict` error on redeployment.

The template includes a `createJobSchedule` parameter (default `true`) to control this:

- **First deployment**: leave `createJobSchedule = true`.
- **Every redeployment**: set `createJobSchedule = false` (uncheck **"Create Job Schedule Link"** in the Advanced tab of the Template Spec form).

For full details see the [add-on README](../deployments/add-ons/updateRouteTableWithM365Routes/README.md#redeployment).
