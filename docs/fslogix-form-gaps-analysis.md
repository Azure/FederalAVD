# FSLogix Form Feature Parity Review

## Scope

This review compares the FSLogix capabilities exposed by:

- `deployments/hostpools/uiFormDefinition.json`
- `deployments/add-ons/fslogixStorage/uiFormDefinition.json`

The forms serve different workflows. The host-pool form deploys an AVD host pool, session hosts,
and optionally FSLogix storage. The add-on deploys standalone FSLogix storage for an existing or
future host pool, or as shared storage. Differences required by those workflows are not parity
gaps.

## Current Decision

Kerberos ticket encryption is not a user-selectable add-on setting. The standalone add-on omits
the parameter and uses the shared FSLogix orchestration default of `AES256`, which configures
`AES-256;` on Azure Files. RC4 is not offered by the add-on form or add-on template.

The standard host-pool Bicep entry point still has an advanced
`fslogixStorageKerberosEncryptionType` parameter for compatibility, but its portal form does not
expose that parameter.

## Equivalent Capabilities

| Capability | Host-pool form | FSLogix add-on | Status |
| --- | --- | --- | --- |
| Azure Files and Azure NetApp Files | Yes | Yes | Equivalent |
| Standard and Premium storage service levels | Yes | Yes | Equivalent |
| Azure Files LRS and ZRS | Yes | Yes | Equivalent |
| Profile, Office, and Cloud Cache container layouts | Yes | Yes | Equivalent |
| Cloud Cache remote storage resource discovery | Yes | Yes | Equivalent |
| Profile VHD size and storage share or volume size | Yes | Yes | Equivalent |
| Azure Files storage index | Yes | Yes | Equivalent |
| Least-privilege NTFS access | Yes | Yes | Equivalent |
| Permission and object-specific-settings sharding | Yes | Yes | Equivalent where supported by identity type |
| User and administrator group selection | Blade picker | Blade picker | Equivalent |
| Identity-aware group filtering | Yes | Yes | Equivalent |
| Entra Kerberos application automation identity | Yes | Yes | Equivalent |
| Storage customer-managed keys | Yes | Yes | Equivalent |
| Private endpoints and Azure Files private DNS | Yes | Yes | Equivalent |
| Permitted public IP ranges | Yes | Yes | Equivalent |
| Log Analytics diagnostics for Azure Files | Yes | Yes | Equivalent when a workspace is selected |
| Temporary deployment VM size | Yes | Yes | Equivalent |
| Advanced naming and tags | Yes | Yes | Equivalent for resources owned by each deployment |

## Host-Pool Form Omissions

### Reuse Azure NetApp Files Parents While Creating Volumes

The add-on can create new FSLogix volumes in:

- A new NetApp account and capacity pool
- An existing NetApp account with a new capacity pool
- An existing NetApp account and existing capacity pool

When the host-pool form deploys storage, it creates the NetApp account, capacity pool, and volumes.
It can configure session hosts to use entirely existing volumes when storage deployment is
disabled, but it cannot create new volumes beneath an existing account or capacity pool.

**Recommendation:** Consider adding the add-on's three NetApp deployment modes to the host-pool
form. This is the clearest remaining host-pool feature gap.

### Deploy New Storage Into an Existing Resource Group

The add-on can deploy storage into an existing resource group or create a new one. The host-pool
workflow owns and creates its generated storage resource group.

**Recommendation:** Treat this as optional parity. Supporting an existing storage resource group
would help centralized resource-group designs, but it also weakens the host-pool deployment's
current ownership and lifecycle boundary.

## Add-On Form Omissions

### Backup Vault Creation and Retention

The host-pool form can:

- Enable or disable Azure Files backup
- Create a Recovery Services vault or select an existing vault
- Set retention from 1 through 200 days when creating the Azure Files backup policy
- Select supported vault redundancy when creating a vault

The add-on can only select an existing vault and provide an existing Azure Files backup policy
name. It cannot create the vault or policy and does not expose retention.

**Recommendation:** This is the highest-priority add-on gap. Either compose the shared backup-vault
orchestration used by host pools, or state clearly that the vault and policy are prerequisites.

## Intentional Workflow Differences

| Difference | Reason |
| --- | --- |
| Add-on selects an existing or future host-pool association | The storage deployment is independent of host-pool creation |
| Add-on selects its storage subscription, location, and resource group | It has no parent host-pool deployment to provide scope |
| Add-on selects a temporary deployment VM VNet and subnet | It has no session-host subnet to reuse |
| Host pool reuses the session-host subnet for its temporary deployment VM | The subnet is already selected and must reach the same identity and storage endpoints |
| Add-on selects machine identity and storage authentication | It must model the consumers of the standalone storage |
| Host pool derives compatible FSLogix identity choices from session-host identity | Session-host identity is already known |
| Host pool can configure existing storage without deploying storage | It also owns session-host registry configuration |
| Add-on does not configure session hosts | It only deploys and initializes storage |

## Recommended Order

1. Decide whether host pools should create NetApp volumes in existing accounts or pools.
2. Decide whether the add-on should compose shared Recovery Services vault and policy creation.
3. Decide whether existing storage resource groups belong in the host-pool ownership model.
