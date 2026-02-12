# AVD Networking Infrastructure Template

> **📖 User Guide:** For deployment instructions and scenarios, see the [Quick Start Guide - Networking](../../docs/quickStart.md#step-0-deploy-networking-infrastructure-greenfield)

## Overview

This Azure Bicep template deploys a complete networking infrastructure for Azure Virtual Desktop (AVD) deployments. It creates a hub-spoke or standalone network architecture with security controls, routing options, and Azure service private endpoints.

## Purpose

Provide a production-ready network foundation for AVD with:

- Virtual network with customizable address space and subnets
- Network security groups (NSGs) for traffic control
- Routing options (NAT gateway or NVA force-tunnel)
- Optional hub peering for hybrid connectivity
- Private DNS zones for Azure services
- DDoS Network Protection (optional)
- NSG diagnostic logging

## Architecture

### Deployed Resources

```
Subscription
├── Resource Group (VNet)
│   ├── Virtual Network
│   │   ├── Session Hosts Subnet (with NSG)
│   │   ├── Private Endpoints Subnet (with NSG, optional)
│   │   └── Function App Subnet (with NSG, optional)
│   ├── Network Security Groups (NSGs)
│   ├── NAT Gateway (optional)
│   ├── Public IP Address (for NAT gateway)
│   ├── Route Table (for NVA routing, optional)
│   ├── DDoS Protection Plan (optional)
│   └── VNet Peering to Hub (optional)
└── Resource Group (Private DNS Zones, optional)
    ├── privatelink.blob.core.windows.net (or .usgovcloudapi.net)
    ├── privatelink.file.core.windows.net (or .usgovcloudapi.net)
    ├── privatelink.queue.core.windows.net (or .usgovcloudapi.net)
    ├── privatelink.table.core.windows.net (or .usgovcloudapi.net)
    ├── privatelink.vaultcore.azure.net (or .usgovcloudapi.net)
    ├── privatelink.wvd.microsoft.com (or .azure.us)
    ├── privatelink-global.wvd.microsoft.com (or .azure.us)
    ├── privatelink.{region}.backup.windowsazure.com (or .us)
    └── privatelink.azurewebsites.net (or .us)
```

### Routing Options

| Option | Description | Use Case |
|--------|-------------|----------|
| **NAT Gateway** (default) | Outbound internet via NAT gateway | Simplest option, Azure-managed outbound connectivity |
| **NVA Force-Tunnel** | All traffic routed through Network Virtual Appliance | Centralized inspection, hub-spoke with firewall |
| **NVA + AVD Bypass** | NVA routing with AVD service traffic bypass routes | Hybrid: Firewall for internet, direct AVD service connectivity |

## Prerequisites

### Required Information

- **Subscription ID** - Where to deploy the network
- **Location** - Azure region (e.g., `usgovvirginia`, `eastus2`)
- **Address Space** - CIDR range for VNet (e.g., `10.0.0.0/16`)
- **Subnet Ranges** - CIDR ranges for each subnet

### Optional Prerequisites

- **Hub VNet Resource ID** - For hub peering (hybrid connectivity)
- **Log Analytics Workspace Resource ID** - For NSG flow logs
- **NVA IP Address** - When using NVA routing

## Parameters

### Core Settings

#### `location`
- **Type:** String
- **Default:** `deployment().location`
- **Description:** Azure region for network resources

#### `deployVnet`
- **Type:** Boolean
- **Default:** `false`
- **Description:** Whether to deploy the virtual network

#### `deployVnetResourceGroup`
- **Type:** Boolean
- **Default:** `false`
- **Description:** Whether to deploy the VNet resource group

#### `vnetResourceGroupName`
- **Type:** String
- **Required when:** `deployVnet` is `true`
- **Description:** Resource group name for VNet

#### `vnetName`
- **Type:** String
- **Required when:** `deployVnet` is `true`
- **Description:** Virtual network name

#### `vnetAddressPrefixes`
- **Type:** Array
- **Required when:** `deployVnet` is `true`
- **Description:** Address prefixes for VNet
- **Example:** `["10.0.0.0/16"]`

### Subnet Configuration

#### `hostsSubnet`
- **Type:** Object
- **Required when:** `deployVnet` is `true`
- **Description:** Session hosts subnet configuration
- **Schema:**
  ```json
  {
    "name": "string",
    "addressPrefix": "string"
  }
  ```
- **Example:**
  ```json
  {
    "name": "snet-avd-hosts",
    "addressPrefix": "10.0.0.0/24"
  }
  ```

#### `privateEndpointsSubnet`
- **Type:** Object
- **Optional**
- **Description:** Private endpoints subnet configuration (for Zero Trust)
- **Example:**
  ```json
  {
    "name": "snet-avd-endpoints",
    "addressPrefix": "10.0.1.0/24"
  }
  ```

#### `functionAppSubnet`
- **Type:** Object
- **Optional**
- **Description:** Function app subnet configuration (for Storage Quota Manager)
- **Example:**
  ```json
  {
    "name": "snet-avd-functions",
    "addressPrefix": "10.0.2.0/24"
  }
  ```

### Routing & Connectivity

#### `defaultRouting`
- **Type:** String
- **Default:** `nat`
- **Allowed Values:** `nat`, `nva`
- **Description:** Routing method for subnet traffic
  - `nat` - NAT gateway for outbound connectivity
  - `nva` - Route through Network Virtual Appliance (firewall)

#### `includeAvdBypassRoutes`
- **Type:** Boolean
- **Default:** `false`
- **Description:** When using NVA routing, adds AVD service bypass routes to allow direct AVD service connectivity
- **Use when:** NVA force-tunnel with optimized AVD service traffic

#### `nvaIPAddress`
- **Type:** String
- **Required when:** `defaultRouting` is `nva`
- **Description:** IP address of the Network Virtual Appliance
- **Example:** `10.1.0.4`

#### `customDNSServers`
- **Type:** Array
- **Optional**
- **Description:** Custom DNS server IP addresses
- **Example:** `["10.1.0.10", "10.1.0.11"]`

### Hub Peering

#### `hubVnetResourceId`
- **Type:** String
- **Optional**
- **Description:** Resource ID of hub VNet for peering
- **Example:** `/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Network/virtualNetworks/{vnet}`

#### `virtualNetworkGatewayOnHub`
- **Type:** Boolean
- **Default:** `false`
- **Description:** Whether hub VNet has a virtual network gateway (VPN/ExpressRoute)

### Security & Monitoring

#### `deployDDoSNetworkProtection`
- **Type:** Boolean
- **Default:** `false`
- **Description:** Deploy DDoS Network Protection plan

#### `logAnalyticsWorkspaceResourceId`
- **Type:** String
- **Optional**
- **Description:** Log Analytics workspace resource ID for NSG flow logs
- **Example:** `/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.OperationalInsights/workspaces/{workspace}`

### Private DNS Zones

#### `privateDNSZonesSubscriptionId`
- **Type:** String
- **Default:** Current subscription
- **Description:** Subscription for private DNS zones deployment

#### `deployPrivateDNSZonesResourceGroup`
- **Type:** Boolean
- **Default:** `false`
- **Description:** Deploy resource group for private DNS zones

#### `privateDNSZonesResourceGroupName`
- **Type:** String
- **Required when:** Any DNS zone is created
- **Description:** Resource group name for private DNS zones

#### Private DNS Zone Creation Flags

| Parameter | Service | When to Create |
|-----------|---------|----------------|
| `createAzureBlobZone` | Blob Storage | Using private endpoints for storage accounts |
| `createAzureFilesZone` | Files Storage | Using private endpoints for FSLogix profiles |
| `createAzureQueueZone` | Queue Storage | Using private endpoints for storage queues |
| `createAzureTableZone` | Table Storage | Using private endpoints for storage tables |
| `createAzureKeyVaultZone` | Key Vault | Using private endpoints for Key Vault |
| `createAvdFeedZone` | AVD Feed | Zero Trust AVD with private links |
| `createAvdGlobalFeedZone` | AVD Global Feed | Zero Trust AVD with private links |
| `createAzureBackupZone` | Azure Backup | Using Azure Backup with private endpoints |
| `createAzureWebAppZone` | Web Apps | Using private endpoints for Function Apps |

#### Existing Private DNS Zone IDs

If zones already exist, provide their resource IDs:

- `azureBlobZoneId`
- `azureFilesZoneId`
- `azureQueueZoneId`
- `azureTableZoneId`
- `azureKeyVaultZoneId`
- `avdFeedZoneId`
- `avdGlobalFeedZoneId`
- `azureBackupZoneId`
- `azureWebAppZoneId`

#### `linkPrivateDnsZonesToNewVnet`
- **Type:** Boolean
- **Default:** `false`
- **Description:** Link DNS zones to the newly created VNet

#### `privateDnsZonesVnetId`
- **Type:** String
- **Required when:** `linkPrivateDnsZonesToNewVnet` is `false` and DNS zones are used
- **Description:** Existing VNet resource ID to link DNS zones to

### Naming & Tagging

#### `nameConvResTypeAtEnd`
- **Type:** Boolean
- **Default:** `false`
- **Description:** Resource naming convention (CAF-style)
  - `false` - `rg-avd-networking-use2`
  - `true` - `avd-networking-use2-rg`

#### `tags`
- **Type:** Object
- **Optional**
- **Description:** Tags to apply to resources
- **Example:**
  ```json
  {
    "Environment": "Production",
    "Owner": "AVD-Team",
    "CostCenter": "IT-12345"
  }
  ```

#### `timeStamp`
- **Type:** String
- **Default:** `utcNow('yyyyMMddhhmmss')`
- **Description:** Timestamp for deployment uniqueness (DO NOT MODIFY)

### Air-Gapped Cloud Specific

#### `azureRecoveryServicesGeoCode`
- **Type:** String
- **Optional**
- **Description:** Recovery Services geo code for air-gapped clouds (e.g., `USN` for USNat)

## Usage Examples

### Example 1: Basic VNet with NAT Gateway (Default)

```powershell
New-AzSubscriptionDeployment `
  -Location "usgovvirginia" `
  -TemplateFile ".\networking.bicep" `
  -deployVnet $true `
  -deployVnetResourceGroup $true `
  -vnetResourceGroupName "rg-avd-networking-usgv" `
  -vnetName "vnet-avd-usgv" `
  -vnetAddressPrefixes @("10.100.0.0/16") `
  -hostsSubnet @{name="snet-avd-hosts"; addressPrefix="10.100.0.0/24"} `
  -defaultRouting "nat" `
  -Name "avd-networking-$(Get-Date -Format 'yyyyMMddHHmm')"
```

### Example 2: VNet with Private Endpoints

```powershell
New-AzSubscriptionDeployment `
  -Location "usgovvirginia" `
  -TemplateFile ".\networking.bicep" `
  -deployVnet $true `
  -deployVnetResourceGroup $true `
  -vnetResourceGroupName "rg-avd-networking-usgv" `
  -vnetName "vnet-avd-usgv" `
  -vnetAddressPrefixes @("10.100.0.0/16") `
  -hostsSubnet @{name="snet-avd-hosts"; addressPrefix="10.100.0.0/24"} `
  -privateEndpointsSubnet @{name="snet-avd-endpoints"; addressPrefix="10.100.1.0/24"} `
  -defaultRouting "nat" `
  -createAzureBlobZone $true `
  -createAzureFilesZone $true `
  -deployPrivateDNSZonesResourceGroup $true `
  -privateDNSZonesResourceGroupName "rg-avd-privatedns-usgv" `
  -linkPrivateDnsZonesToNewVnet $true `
  -Name "avd-networking-$(Get-Date -Format 'yyyyMMddHHmm')"
```

### Example 3: NVA Force-Tunnel with AVD Bypass

```powershell
New-AzSubscriptionDeployment `
  -Location "usgovvirginia" `
  -TemplateFile ".\networking.bicep" `
  -deployVnet $true `
  -deployVnetResourceGroup $true `
  -vnetResourceGroupName "rg-avd-networking-usgv" `
  -vnetName "vnet-avd-usgv" `
  -vnetAddressPrefixes @("10.100.0.0/16") `
  -hostsSubnet @{name="snet-avd-hosts"; addressPrefix="10.100.0.0/24"} `
  -defaultRouting "nva" `
  -nvaIPAddress "10.1.0.4" `
  -includeAvdBypassRoutes $true `
  -Name "avd-networking-$(Get-Date -Format 'yyyyMMddHHmm')"
```

### Example 4: Hub-Spoke with Peering

```powershell
New-AzSubscriptionDeployment `
  -Location "usgovvirginia" `
  -TemplateFile ".\networking.bicep" `
  -deployVnet $true `
  -deployVnetResourceGroup $true `
  -vnetResourceGroupName "rg-avd-networking-usgv" `
  -vnetName "vnet-avd-spoke-usgv" `
  -vnetAddressPrefixes @("10.100.0.0/16") `
  -hostsSubnet @{name="snet-avd-hosts"; addressPrefix="10.100.0.0/24"} `
  -defaultRouting "nva" `
  -nvaIPAddress "10.1.0.4" `
  -hubVnetResourceId "/subscriptions/{sub}/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub" `
  -virtualNetworkGatewayOnHub $true `
  -privateDnsZonesVnetId "/subscriptions/{sub}/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub" `
  -Name "avd-networking-$(Get-Date -Format 'yyyyMMddHHmm')"
```

### Example 5: Using Parameter File

```powershell
New-AzSubscriptionDeployment `
  -Location "usgovvirginia" `
  -TemplateFile ".\networking.bicep" `
  -TemplateParameterFile ".\parameters\prod.networking.parameters.json" `
  -Name "avd-networking-$(Get-Date -Format 'yyyyMMddHHmm')"
```

### Azure CLI

```bash
az deployment sub create \
  --location usgovvirginia \
  --template-file ./networking.bicep \
  --parameters \
    deployVnet=true \
    deployVnetResourceGroup=true \
    vnetResourceGroupName="rg-avd-networking-usgv" \
    vnetName="vnet-avd-usgv" \
    vnetAddressPrefixes='["10.100.0.0/16"]' \
    hostsSubnet='{"name":"snet-avd-hosts","addressPrefix":"10.100.0.0/24"}' \
    defaultRouting="nat" \
  --name avd-networking-$(date +%Y%m%d%H%M)
```

## Outputs

### `vnetResourceId`
- **Type:** String
- **Description:** Resource ID of the deployed virtual network
- **Example:** `/subscriptions/{sub}/resourceGroups/rg-avd-networking-usgv/providers/Microsoft.Network/virtualNetworks/vnet-avd-usgv`

## Security Considerations

### Network Segmentation
- **Separate subnets** for different workload types
- **NSGs** provide traffic filtering at subnet level
- **Private endpoints** eliminate public exposure of Azure services

### Routing Security
- **NAT Gateway** - Azure-managed, no inbound internet access
- **NVA Force-Tunnel** - All traffic inspected by firewall
- **AVD Bypass Routes** - Optimized AVD service connectivity while maintaining firewall for internet

### DNS Security
- **Private DNS zones** ensure Azure services resolve to private endpoints
- **Custom DNS** for integration with on-premises DNS servers

### Monitoring
- **NSG flow logs** capture all network traffic for auditing
- **Log Analytics** centralized log storage and analysis
- **DDoS Protection** mitigates volumetric attacks (optional)

## Cost Optimization

### Network Costs

| Resource | Cost Driver | Optimization |
|----------|-------------|--------------|
| **NAT Gateway** | Per gateway-hour, data processed | Use single NAT for multiple subnets |
| **Public IP** | Static IP reservation | Standard SKU for NAT gateway |
| **VNet Peering** | Data transfer between VNets | Peer only when needed (hub-spoke) |
| **Private Endpoints** | Per endpoint-hour | Consolidate where possible |
| **DDoS Protection** | Per protection plan | Share across multiple VNets |
| **NSG Flow Logs** | Log Analytics ingestion | Enable only for production |

### Right-Sizing
- Use appropriate address spaces (avoid over-provisioning)
- Create only needed private DNS zones
- Deploy DDoS protection only for production workloads

## Troubleshooting

### Common Issues

**VNet deployment fails with "address space overlap"**
- Ensure `vnetAddressPrefixes` don't overlap with hub VNet or other spokes
- Verify subnet ranges are within VNet address space

**Peering fails with "remote gateway" error**
- Set `virtualNetworkGatewayOnHub` to `true` when hub has VPN/ExpressRoute gateway
- Verify hub VNet resource ID is correct

**Private DNS zone creation fails**
- Verify `privateDNSZonesResourceGroupName` is provided when creating zones
- Check `deployPrivateDNSZonesResourceGroup` is `true` for new resource group

**NSG flow logs not appearing**
- Verify`logAnalyticsWorkspaceResourceId` is valid
- Check workspace is in same or paired region

**NVA routing not working**
- Verify `nvaIPAddress` is correct and NVA is operational
- Check route table is associated with subnet
- Verify NVA has IP forwarding enabled

## Additional Resources

- 📖 [Quick Start Guide - Networking](../../docs/quickStart.md#step-0-deploy-networking-infrastructure-greenfield)
- 📖 [Host Pool Deployment Guide](../../docs/hostpoolDeployment.md)
- 🔧 [Azure Virtual Network Documentation](https://learn.microsoft.com/azure/virtual-network/)
- 🔧 [Azure Private Link Documentation](https://learn.microsoft.com/azure/private-link/)
- 🔧 [Azure NAT Gateway Documentation](https://learn.microsoft.com/azure/nat-gateway/)

## Support

For issues, questions, or contributions:
- **GitHub Issues:** [Azure/FederalAVD/issues](https://github.com/Azure/FederalAVD/issues)
- **Documentation:** [docs/](../../docs/)

## License

This project is licensed under the MIT License - see the [LICENSE](../../LICENSE) file for details.
