targetScope = 'local'

import { namingPolicy, resourceName, resolveConvention, resourceTypeFirst, regionAbbreviation, scopeUnique, scopeIdUnique, fslogixNames, imageStorageName, imageBuildRunId, privateEndpointPattern, privateEndpointNicPattern, namePattern } from '../../deployments/shared/modules/orchestration/naming/internal.bicep'

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
var subscriptionId = '00000000-1111-2222-3333-444444444444'

func referencePurpose(rule object, delimiter string) string =>
  join(filter(map(rule.purpose, part => replace(replace(part, '{identifier}', 'finance-01'), '{unique}', 'abc123')), part => !(rule.?omitEmptyPurposeParts ?? false) || !empty(part)), delimiter)

func referenceRoleName(convention object, rule object) string =>
  join(filter(map(filter(convention.components, component => !(rule.?omitWorkload ?? false) || component != 'workload'), component => {
    resourceType: empty(rule.type) ? '' : convention.resourceTypeCodes[rule.type]
    purpose: referencePurpose(rule, convention.delimiter)
    location: 'use2'
    workload: convention.workload
    environment: convention.environment
    freeform1: convention.freeform1
    freeform2: convention.freeform2
  }[?component] ?? ''), token => !empty(token)), convention.delimiter)

func referenceFormattedRoleName(convention object, rule object) string =>
  rule.type == 'keyVaults' ? replace(replace(referenceRoleName(convention, rule), '_', '-'), '.', '-')
    : rule.type == 'computeGalleries' ? replace(referenceRoleName(convention, rule), '-', '_')
    : referenceRoleName(convention, rule)

// Invalid/overlength conventions are exercised as failures, not truncated success vectors.
var roleNames = flatten(map(filter(range(0, length(conventions)), index => !contains([7, 10, 11], index)), index => map(filter(items(namingPolicy.resources), role => role.value.type != 'keyVaults' || !contains([6, 9, 12], index)), role => {
  scenario: index
  role: role.key
  actual: resourceName(conventions[index], role.key, 'use2', 'finance-01', 'abc123')
  expected: referenceFormattedRoleName(resolveConvention(conventions[index]), role.value)
})))
var emptyIdentifierNames = {
  deploymentResourceGroup: resourceName({}, 'deploymentResourceGroup', 'use2', '', 'abc123')
  hostsResourceGroup: resourceName({}, 'hostsResourceGroup', 'use2', '', 'abc123')
  storageResourceGroup: resourceName({}, 'storageResourceGroup', 'use2', '', 'abc123')
  identityPattern: resourceName({}, 'identityPattern', 'use2', '', 'abc123')
  diskEncryptionSetPattern: resourceName({}, 'diskEncryptionSetPattern', 'use2', '', 'abc123')
  quotaAutomation: resourceName({}, 'quotaAutomation', 'use2', '', 'abc123')
}
var storageNames = flatten(map(conventions, convention => flatten(map(['artifacts', 'logs'], kind => map(['', 'cont1'], prefix => {
  actual: imageStorageName(convention, kind, 'use2', { subscriptionId: subscriptionId, resourceGroupName: 'rg-avd-image-management-use2', location: 'eastus2', cloud: 'AzureCloud' }, prefix)
})))))
var scopedSeeds = {
  actual: take(scopeUnique({ subscriptionId: subscriptionId, resourceGroupName: 'rg-avd-operations-use2', location: 'eastus2', cloud: 'AzureCloud' }), 6)
  expected: take(uniqueString(toLower(subscriptionId), 'rg-avd-operations-use2', 'eastus2'), 6)
}
var defaultConvention = resolveConvention({})
var partialCodes = resolveConvention({ resourceTypeCodes: { keyVaults: 'vault' } }).resourceTypeCodes
var emptyDelimiter = resourceName({ delimiter: '' }, 'secretsKeyVault', 'va', '', 'abc123')
var governmentLocation = regionAbbreviation('usgovvirginia', 'AzureUSGovernment')
var commercialLocation = regionAbbreviation('eastus', 'AzureCloud')
var regionChecks = map(items(loadJsonContent('../../deployments/shared/data/locations.json')), cloud => map(items(cloud.value), region => {
  actual: regionAbbreviation(cloud.key == 'other' ? 'ussec${region.key}' : region.key, cloud.key == 'other' ? 'USSec' : cloud.key)
  expected: region.value.abbreviation
}))
var shortSeed = scopeIdUnique(subscriptionId, 'rg-hosts')
var expectedShortSeed = take(uniqueString(subscriptionId, 'rg-hosts'), 6)
var runId = imageBuildRunId(subscriptionId, 'build-a', '202610181234')
var expectedRunId = uniqueString(subscriptionId, 'build-a', '202610181234')
var temporaryVm = fslogixNames({}, 'finance-01', { subscriptionId: subscriptionId, cloud: 'AzureCloud', location: 'eastus2' }).depVirtualMachineName
var expectedTemporaryVm = take('${replace(replace(replace('avd-finance-01-use2', '-', ''), '_', ''), '.', '')}${uniqueString(replace(replace(replace('avd-finance-01-use2', '-', ''), '_', ''), '.', ''))}', 15)
var endpointFirst = privateEndpointPattern(true, 'pe')
var endpointLast = privateEndpointNicPattern(false, 'pe', 'nic')
var networkLast = resourceName({ components: ['workload', 'purpose', 'location', 'resourceType'] }, 'networkNatGateway', 'use2', '', '')
var quotaEmpty = resourceName({}, 'quotaAutomation', 'va', '', '')
var resourceTypeFlags = map(conventions, convention => resourceTypeFirst(convention))
var patterns = {
  vm: namePattern('virtualMachine', {})
  disk: namePattern('osDisk', {})
  nic: namePattern('nic', {})
  key: namePattern('storageCmkKey', { identifier: 'finance-shr' })
  buildGroup: namePattern('imageBuildResourceGroup', { resourceGroups: 'rg', prefix: 'dev-', workload: 'avd', location: 'va', timestamp: '202610181234', unique: 'abc123' })
  definition: namePattern('imageDefinition', { imageDefinitions: 'vmid', publisher: 'MicrosoftWindowsDesktop', offer: 'windows11', sku: 'win1125h2avd' })
}

@description('Base64 transport preserves exact policy vectors through the local CLI renderer.')
output encodedResults string = base64(string({
  roleNames: roleNames
  emptyIdentifierNames: emptyIdentifierNames
  storageNames: storageNames
  scopedSeeds: scopedSeeds
  defaultConvention: defaultConvention
  partialCodes: partialCodes
  emptyDelimiter: emptyDelimiter
  governmentLocation: governmentLocation
  commercialLocation: commercialLocation
  regionChecks: regionChecks
  shortSeed: shortSeed
  expectedShortSeed: expectedShortSeed
  runId: runId
  expectedRunId: expectedRunId
  temporaryVm: temporaryVm
  expectedTemporaryVm: expectedTemporaryVm
  endpointFirst: endpointFirst
  endpointLast: endpointLast
  networkLast: networkLast
  quotaEmpty: quotaEmpty
  resourceTypeFlags: resourceTypeFlags
  patterns: patterns
}))
