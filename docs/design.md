[**Home**](../README.md) | [**Features**](features.md) | [**Get Started**](quickStart.md) | [**Artifacts Guide**](artifacts-guide.md) | [**Limitations**](limitations.md) | [**Troubleshooting**](troubleshooting.md) | [**Parameters**](parameters.md) | [**Zero Trust Framework**](zeroTrustFramework.md)

# Design

This Azure Virtual Desktop (AVD) solution will deploy fully operational AVD hostpool(s) to an Azure subscription.

The deployment utilizes the Cloud Adoption Framework naming conventions and organizes resources and resource groups in accordance with several available parameters:

- Persona Identifier (***identifier***): This parameter is used to uniquely identify the persona of the host pool(s). Each persona, or each group of users with distinct business functions and technical requirements, would require a specific host-pool configuration and thus we use the persona term to identify the host pool. For more information about personas see [User Personas | AVD Cloud Adoption Framework](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/scenarios/azure-virtual-desktop/migrate-assess#user-personas).

- Host Pool Index (***index***): This *optional* parameter is used when we must shard the unique persona across multiple host pools. For more information, see [Sharding Pattern](https://docs.microsoft.com/en-us/azure/architecture/patterns/sharding).

- Name Convention Reversed (***nameConvResTypeAtEnd***): This bolean parameter, which is by default 'false', will move the resource type abbreviation to the end of the resource names effectively reversing the CAF naming standard.

The diagram below highlights how the resource groups are created based on the parameters.

```mermaid
graph TB
    subgraph Tenant["Azure Tenant"]
        GF[Global Feed<br/>rg-avd-global-feed]
        
        subgraph Region1["Region 1 (e.g., USGovVirginia)"]
            MON1[Monitoring<br/>rg-avd-monitoring-va<br/>Log Analytics, DCR, DCE]
            MGT1[Management<br/>rg-avd-management-va<br/>Key Vault, App Service Plan]
            CP1[Control Plane<br/>rg-avd-control-plane-va<br/>Workspace, App Groups, Host Pools]
            
            subgraph HP1["Host Pool 1 (Identifier: hr, Index: 01)"]
                direction LR
                HOSTS1[Hosts<br/>rg-hr-01-hosts-va<br/>VMs, Backup, Encryption]
                STORAGE1[Storage<br/>rg-hr-01-storage-va<br/>Storage Accounts, NetApp, Functions]
            end
            
            subgraph HP2["Host Pool 2 (Identifier: hr, Index: 02)"]
                direction LR
                HOSTS2[Hosts<br/>rg-hr-02-hosts-va<br/>VMs, Backup, Encryption]
                STORAGE2[Storage<br/>rg-hr-02-storage-va<br/>Storage Accounts, NetApp, Functions]
            end
            
            CP1 --> HP1
            CP1 --> HP2
            MON1 -.monitors.-> HOSTS1
            MON1 -.monitors.-> HOSTS2
            MGT1 -.manages.-> HP1
            MGT1 -.manages.-> HP2
        end
        
        subgraph Region2["Region 2 (e.g., USGovTexas)"]
            MON2[Monitoring<br/>rg-avd-monitoring-tx<br/>Log Analytics, DCR, DCE]
            MGT2[Management<br/>rg-avd-management-tx<br/>Key Vault, App Service Plan]
            CP2[Control Plane<br/>rg-avd-control-plane-tx<br/>Workspace, App Groups, Host Pools]
            
            subgraph HP3["Host Pool 3 (Identifier: finance, Index: 01)"]
                direction LR
                HOSTS3[Hosts<br/>rg-finance-01-hosts-tx<br/>VMs, Backup, Encryption]
                STORAGE3[Storage<br/>rg-finance-01-storage-tx<br/>Storage Accounts, NetApp, Functions]
            end
            
            CP2 --> HP3
            MON2 -.monitors.-> HOSTS3
            MGT2 -.manages.-> HP3
        end
        
        GF -.connects to.-> CP1
        GF -.connects to.-> CP2
    end
    
    %% Define styles for different resource group types
    classDef globalFeed fill:#e1f5ff,stroke:#0288d1,stroke-width:2px
    classDef monitoring fill:#fff4e1,stroke:#f57c00,stroke-width:2px
    classDef management fill:#f3e5f5,stroke:#7b1fa2,stroke-width:2px
    classDef controlPlane fill:#e8f5e9,stroke:#388e3c,stroke-width:2px
    classDef hosts fill:#ffebee,stroke:#c62828,stroke-width:2px
    classDef storage fill:#f1f8e9,stroke:#689f38,stroke-width:2px
    classDef hostPool fill:#e3f2fd,stroke:#1976d2,stroke-width:2px
    classDef region fill:#f5f5f5,stroke:#616161,stroke-width:3px
    classDef tenant fill:#fafafa,stroke:#424242,stroke-width:4px
    
    %% Apply styles to nodes
    class GF globalFeed
    class MON1,MON2 monitoring
    class MGT1,MGT2 management
    class CP1,CP2 controlPlane
    class HOSTS1,HOSTS2,HOSTS3 hosts
    class STORAGE1,STORAGE2,STORAGE3 storage
    class HP1,HP2,HP3 hostPool
    class Region1,Region2 region
    class Tenant tenant
```

The diagram illustrates the following resource group distribution. In the table below, the example names are utilizing the following parameter values:

- **identifier**: 'hr'
- **index**: '01', '02'
- locationVirtualMachines (determined by **virtualMachineSubnetResourceId** location): 'USGovVirginia'
- **locationControlPlane**: 'USGovVirginia'
- **nameConvResTypeAtEnd**: false

| Purpose | Resources | Example Name | Notes |
| ------- | :-------: | ------------ | ----- |
| Global Feed | global feed workspace | rg-avd-global-feed | One per Tenant |
| Monitoring | Log Analytics Workspace<br>Data Collection Rules<br>Data Collection Endpoint | rg-avd-monitoring-va | One per region |
| Management | key vault(s)<br>app service plan  | rg-avd-management-va | One per region |
| Control Plane | feed workspace<br>application groups<br>hostpools<br>scaling plans | rg-avd-control-plane-va | One per region |
| Hosts | virtual machines<br>recovery service vault<br>disk encryption set<br>key vault | rg-hr-01-hosts-va<br>rg-hr-02-hosts-va | One per identifier or per index (if specified) |
| Storage | NetApp Storage Accounts<br>Storage Account(s)<br>function app<br>key vault(s) | rg-hr-01-storage-va<br>rg-hr-02-storage-va | One per identifier or per index (if specified) |

The code is idempotent, allowing you to scale storage and sessions hosts, but the core management resources will persist and update for any subsequent deployments. Some of those resources are the host pool, application group, and log analytics workspace.

Both a personal or pooled host pool can be deployed with this solution. Either option will deploy a desktop application group with a role assignment. You can also deploy the required resources and configurations to fully enable FSLogix. This solution also automates many of the [features](features.md) that are usually enabled manually after deploying an AVD host pool.