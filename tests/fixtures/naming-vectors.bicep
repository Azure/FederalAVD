targetScope = 'local'

import { fslogixNames } from '../../deployments/shared/modules/orchestration/naming/naming.bicep'
import { resourceName } from '../../deployments/shared/modules/orchestration/naming/internal.bicep'

var groupCode = { resourceTypeCodes: { hostPools: 'rg' } }
@description('Base64 transport preserves exact vector strings through the local CLI renderer.')
output encodedResults string = base64(string({
  defaultName: resourceName(groupCode, 'hostPool', 'eus', 'desktop', '')
  reversedName: resourceName({ components: ['workload', 'purpose', 'location', 'resourceType'], resourceTypeCodes: { hostPools: 'kv' } }, 'hostPool', 'va', 'sec-abc123', '')
  omittedComponents: resourceName(union(groupCode, { components: ['none', 'resourceType', 'purpose', 'location'] }), 'hostPool', 'eus', '', '')
  repeatedComponents: resourceName(union(groupCode, { components: ['resourceType', 'resourceType', 'purpose'] }), 'hostPool', '', 'desktop', '')
  emptyDelimiter: resourceName({ components: ['resourceType', 'workload', 'purpose'], delimiter: '', resourceTypeCodes: { hostPools: 'st' } }, 'hostPool', '', 'images', '')
  customComponents: resourceName(union(groupCode, { components: ['freeform1', 'environment', 'workload', 'purpose', 'location', 'freeform2', 'resourceType'], delimiter: '_', freeform1: 'org', environment: 'prod', freeform2: '01' }), 'hostPool', 'eus', 'desktop', '')
  preservedCase: resourceName({ components: ['purpose'] }, 'hostPool', '', 'Desktop', '')
  strippedSeparators: take(fslogixNames({ components: ['purpose'] }, 'Ab-c_d.e', { subscriptionId: '00000000-1111-2222-3333-444444444444', cloud: 'AzureCloud', location: 'eastus' }).depVirtualMachineName, 5)
  sanitizedVault: resourceName({ components: ['resourceType', 'purpose'], resourceTypeCodes: { keyVaults: 'Ab_c.d-e' } }, 'secretsKeyVault', '', '', 'abc123')
}))
