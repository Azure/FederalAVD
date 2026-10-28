using none

import { resourceName, resolveConvention, resourceTypeFirst, regionAbbreviation, scopedUnique, scopeIdUnique, deploymentVmName, imageStorageName, legacyConvention, imageBuildRunId, privateEndpointPattern, privateEndpointNicPattern, namePattern } from '../../deployments/shared/modules/orchestration/naming/naming.bicep'
import { legacyName, legacyScopedUnique, legacyStorage } from './naming-legacy.bicep'

var conventions = [
  {}
  { components: ['workload', 'purpose', 'location', 'resourceType'] }
  { delimiter: '_' }
  { delimiter: '.' }
  { delimiter: '' }
  { components: ['resourceType', 'purpose', 'none'] }
  { components: ['freeform1', 'environment', 'workload', 'purpose', 'location', 'freeform2', 'resourceType'], freeform1: 'org', environment: 'prod', workload: 'desktop', freeform2: '01' }
  { workload: 'abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789' }
  { workload: '' }
  { resourceTypeCodes: { resourceGroups: 'group', storageAccounts: 'store', keyVaults: 'vault', functionApps: 'function' } }
  { components: ['none'] }
  { components: [] }
  { delimiter: '--' }
]
var rules = loadJsonContent('./naming-legacy-rules.json')
var subscriptionId = '00000000-1111-2222-3333-444444444444'

param roleParity = flatten(map(range(0, length(conventions)), index => map(items(rules), role => {
  scenario: index
  role: role.key
  actual: resourceName(conventions[index], role.key, 'use2', 'finance-01', 'abc123')
  expected: legacyName(conventions[index], role.value, 'use2', 'finance-01', 'abc123')
})))
param emptyContextParity = flatten(map(conventions, convention => map(filter(items(rules), role => contains([
  'deploymentResourceGroup'
  'hostsResourceGroup'
  'storageResourceGroup'
  'identityPattern'
  'diskEncryptionSetPattern'
  'replacerFunctionApp'
  'replacerStorageIdentity'
  'replacerInsights'
  'quotaAutomation'
], role.key)), role => {
  role: role.key
  actual: resourceName(convention, role.key, 'use2', '', 'abc123')
  expected: legacyName(convention, role.value, 'use2', '', 'abc123')
})))
param storageParity = flatten(map(conventions, convention => flatten(map(['artifacts', 'logs'], kind => map(['', 'cont1'], prefix => {
  actual: imageStorageName(convention, kind, 'use2', subscriptionId, 'rg-avd-image-management-use2', 'eastus2', prefix)
  expected: legacyStorage(convention, kind, 'use2', subscriptionId, 'rg-avd-image-management-use2', 'eastus2', prefix)
})))))
param seedParity = map(conventions, convention => {
  actual: scopedUnique(convention, subscriptionId, 'rg-avd-operations-use2', 'eastus2')
  expected: legacyScopedUnique(convention, subscriptionId, 'rg-avd-operations-use2', 'eastus2')
})
param defaultConvention = resolveConvention({})
param partialCodes = resolveConvention({ resourceTypeCodes: { keyVaults: 'vault' } }).resourceTypeCodes
param emptyDelimiter = resourceName({ delimiter: '' }, 'secretsKeyVault', 'va', '', 'abc123')
param governmentLocation = regionAbbreviation('usgovvirginia', 'AzureUSGovernment')
param commercialLocation = regionAbbreviation('eastus', 'AzureCloud')
param regionChecks = map(items(loadJsonContent('../../deployments/shared/data/locations.json')), cloud => map(items(cloud.value), region => {
  actual: regionAbbreviation(cloud.key == 'other' ? 'ussec${region.key}' : region.key, cloud.key == 'other' ? 'USSec' : cloud.key)
  expected: region.value.abbreviation
}))
param shortSeed = scopeIdUnique(subscriptionId, 'rg-hosts')
param expectedShortSeed = take(uniqueString(subscriptionId, 'rg-hosts'), 6)
param runId = imageBuildRunId(subscriptionId, 'build-a', '202610181234')
param expectedRunId = uniqueString(subscriptionId, 'build-a', '202610181234')
param temporaryVm = deploymentVmName({}, 'use2', 'finance-01')
param expectedTemporaryVm = take('${replace(replace(replace('avd-finance-01-use2', '-', ''), '_', ''), '.', '')}${uniqueString(replace(replace(replace('avd-finance-01-use2', '-', ''), '_', ''), '.', ''))}', 15)
param endpointFirst = privateEndpointPattern(true, 'pe')
param endpointLast = privateEndpointNicPattern(false, 'pe', 'nic')
param networkLast = resourceName(legacyConvention(true), 'networkNatGateway', 'use2', '', '')
param quotaEmpty = resourceName({}, 'quotaAutomation', 'va', '', '')
param resourceTypeFlags = map(conventions, convention => resourceTypeFirst(convention))
param patterns = {
  vm: namePattern('virtualMachine', {})
  disk: namePattern('osDisk', {})
  nic: namePattern('nic', {})
  key: namePattern('replacerStorageKey', { identifier: 'finance' })
  buildGroup: namePattern('imageBuildResourceGroup', { resourceGroups: 'rg', prefix: 'dev-', workload: 'avd', location: 'va', timestamp: '202610181234', unique: 'abc123' })
  definition: namePattern('imageDefinition', { imageDefinitions: 'vmid', publisher: 'MicrosoftWindowsDesktop', offer: 'windows11', sku: 'win1125h2avd' })
}
