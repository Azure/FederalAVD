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
                HOSTS1[Hosts<br/>rg-hr-01-hosts-va<br/>VMs, Backup, Encryption]
                STORAGE1[Storage<br/>rg-hr-01-storage-va<br/>Storage Accounts, NetApp, Functions]
            end
            
            subgraph HP2["Host Pool 2 (Identifier: hr, Index: 02)"]
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
    
    style GF fill:#e1f5ff
    style MON1 fill:#fff4e1
    style MON2 fill:#fff4e1
    style MGT1 fill:#f3e5f5
    style MGT2 fill:#f3e5f5
    style CP1 fill:#e8f5e9
    style CP2 fill:#e8f5e9
    style HOSTS1 fill:#ffebee
    style HOSTS2 fill:#ffebee
    style HOSTS3 fill:#ffebee
    style STORAGE1 fill:#f1f8e9
    style STORAGE2 fill:#f1f8e9
    style STORAGE3 fill:#f1f8e9
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