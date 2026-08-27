# FSLogix Form Parity Notes

Use these notes when changing the standard host-pool or standalone FSLogix Storage forms.

## Current Decisions

- The standalone add-on uses the shared orchestration default of `AES256`; it does not expose RC4
  or a Kerberos encryption selector.
- The standard host-pool Bicep entry point retains
  `fslogixStorageKerberosEncryptionType` for compatibility, but its portal form does not expose it.
- The add-on only consumes an existing Recovery Services vault and Azure Files backup policy. It
  does not create either resource.

## Remaining Differences

The add-on can create Azure NetApp Files volumes beneath a new or existing account and capacity
pool. The host-pool form creates the account, pool, and volumes together, or configures session
hosts to use entirely existing volumes. It cannot create new volumes beneath an existing account
or capacity pool.

The add-on can deploy storage into an existing resource group. The host-pool workflow owns and
creates its generated storage resource group.

Treat these as ownership-model decisions, not automatic parity defects. Before adding either
capability to the host-pool form, confirm that the host-pool deployment should own resources below
an existing parent or inside an externally managed resource group.

## Workflow Boundaries

| Difference | Reason |
| --- | --- |
| Add-on selects an existing or future host-pool association | Storage deployment is independent of host-pool creation. |
| Add-on selects storage subscription, location, resource group, VNet, and subnet | It has no parent host-pool deployment from which to derive them. |
| Host pool reuses the session-host subnet for its temporary deployment VM | The subnet is already selected and must reach the same identity and storage endpoints. |
| Add-on selects machine identity and storage authentication | It must model consumers of the standalone storage. |
| Host pool derives compatible identity choices from session-host identity | Session-host identity is already known. |
| Host pool can configure existing storage without deploying it | It also owns session-host registry configuration. |
| Add-on does not configure session hosts | It only deploys and initializes storage. |
