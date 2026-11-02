using none

import { resourceName, fslogixNames } from '../../deployments/shared/modules/orchestration/naming/naming.bicep'

var groupCode = { resourceTypeCodes: { hostPools: 'rg' } }
param defaultName = resourceName(groupCode, 'hostPool', 'eus', 'desktop', '')
param reversedName = resourceName({ components: ['workload', 'purpose', 'location', 'resourceType'], resourceTypeCodes: { hostPools: 'kv' } }, 'hostPool', 'va', 'sec-abc123', '')
param omittedComponents = resourceName(union(groupCode, { components: ['none', 'unknown', 'resourceType', 'purpose', 'location'] }), 'hostPool', 'eus', '', '')
param emptyComponents = resourceName(union(groupCode, { components: [] }), 'hostPool', 'eus', 'desktop', '')
param emptyValues = resourceName({ components: ['resourceType', 'purpose', 'location'], resourceTypeCodes: { hostPools: '' } }, 'hostPool', '', '', '')
param repeatedComponents = resourceName(union(groupCode, { components: ['resourceType', 'resourceType', 'purpose'] }), 'hostPool', '', 'desktop', '')
param emptyDelimiter = resourceName({ components: ['resourceType', 'workload', 'purpose'], delimiter: '', resourceTypeCodes: { hostPools: 'st' } }, 'hostPool', '', 'images', '')
param customComponents = resourceName(union(groupCode, { components: ['freeform1', 'environment', 'workload', 'purpose', 'location', 'freeform2', 'resourceType'], delimiter: '_', freeform1: 'org', environment: 'prod', freeform2: '01' }), 'hostPool', 'eus', 'desktop', '')
param preservedWhitespace = resourceName({ components: ['purpose'] }, 'hostPool', '', ' desktop ', '')
param strippedSeparators = take(fslogixNames({ components: ['purpose'] }, 'Ab-c_d.e', { subscriptionId: '00000000-1111-2222-3333-444444444444', cloud: 'AzureCloud', location: 'eastus' }).depVirtualMachineName, 5)
param sanitizedVault = resourceName({ components: ['resourceType'], resourceTypeCodes: { keyVaults: 'Ab_c.d-e' } }, 'secretsKeyVault', '', '', '')
