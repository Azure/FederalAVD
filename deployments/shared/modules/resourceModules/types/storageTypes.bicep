// Storage-specific shared type definitions.
// Import in storage modules with:
//   import { networkAclsType, smbSettingsType } from '../types/storageTypes.bicep'

@export()
type networkAclsType = {
  @description('Services allowed to bypass network rules. Comma-separated: AzureServices, Logging, Metrics, None.')
  bypass: string?
  @description('Default action when no rule matches.')
  defaultAction: 'Allow' | 'Deny'
  virtualNetworkRules: { id: string, action: ('Allow')? }[]?
  ipRules: { value: string, action: ('Allow')? }[]?
}

@export()
type smbSettingsType = {
  @description('SMB protocol versions. E.g. "SMB3.0;SMB3.1.1;"')
  versions: string?
  @description('Authentication methods. E.g. "NTLMv2;Kerberos;"')
  authenticationMethods: string?
  @description('Kerberos ticket encryption. E.g. "AES-256;" or "RC4-HMAC;"')
  kerberosTicketEncryption: string?
  @description('Channel encryption. E.g. "AES-128-GCM;AES-256-GCM;"')
  channelEncryption: string?
  @description('SMB Multichannel settings. For Premium file shares only.')
  multichannel: {
    enabled: bool?
  }?
}
