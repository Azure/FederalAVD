import { functionAppNames, resourceNameForType, privateEndpointName, privateEndpointVnetToken, shortScopedUnique, fslogixStoragePrefix } from '../../deployments/shared/modules/orchestration/naming/naming.bicep'
import { functionAppNames as compatibilityNames } from '../../deployments/shared/modules/orchestration/naming/functions.bicep'

var policy = loadJsonContent('../../deployments/shared/data/namingPolicy.json')
var context = {
  subscriptionId: '00000000-1111-2222-3333-444444444444'
  resourceGroupName: 'rg-addons'
  location: 'eastus'
  cloud: 'AzureCloud'
}
var types = map(items(policy.resourceTypes), type => type.key)
var profiles = [
  { label: 'default', convention: {}, identifier: 'inventory' }
  { label: 'type-last', convention: { components: ['workload', 'purpose', 'location', 'resourceType'] }, identifier: 'inventory' }
  { label: 'underscore', convention: { delimiter: '_' }, identifier: 'inventory' }
  { label: 'dot', convention: { delimiter: '.' }, identifier: 'inventory' }
  { label: 'empty-delimiter', convention: { delimiter: '' }, identifier: 'inventory' }
  { label: 'no-location', convention: { components: ['resourceType', 'workload', 'purpose', 'none'] }, identifier: 'inventory' }
  { label: 'purpose-only', convention: { components: ['purpose'] }, identifier: 'inventory' }
  { label: 'partial-code', convention: { resourceTypeCodes: { functionApps: 'func', storageAccounts: 'st' } }, identifier: 'inventory' }
  { label: 'repeated-type', convention: { components: ['resourceType', 'resourceType', 'workload', 'purpose', 'location'] }, identifier: 'inventory' }
  { label: 'long-identifier', convention: {}, identifier: 'inventory-abcdefghijklmnopqrstuvwxyz-abcdefghijklmnopqrstuvwxyz-abcdefghijklmnopqrstuvwxyz' }
  { label: 'identifier-separators', convention: {}, identifier: 'Inventory_App.v2' }
  { label: 'custom-components', convention: { components: ['freeform1', 'environment', 'purpose', 'freeform2', 'resourceType'], freeform1: 'org', environment: 'prod', freeform2: 'x' }, identifier: 'inventory' }
  { label: 'single-character-budget', convention: { workload: 'avdxx' }, identifier: 'inventory' }
  { label: 'location-override', convention: { locationAbbreviation: 'e1' }, identifier: 'inventory' }
]

var cases = flatten(map(profiles, profile => map(types, type => {
  profile: profile.label
  type: type
  identifier: profile.identifier
  actual: resourceNameForType(profile.convention, type, profile.identifier, context)
  hash: take(uniqueString(toLower(context.subscriptionId), toLower(type) == 'resourcegroups' ? '' : toLower(context.resourceGroupName), toLower(context.location), toLower(context.cloud), toLower(profile.identifier), toLower(type)), policy.resourceTypes[type].?uniqueLength ?? 13)
})))
var bundle = functionAppNames({}, 'inventory', context)
var identityExpected = resourceNameForType({}, 'userAssignedIdentities', 'inventory-storage-cmk', context)
var seeds = map([
  context
  union(context, { subscriptionId: '00000000-1111-2222-3333-555555555555' })
  union(context, { resourceGroupName: 'rg-other' })
  union(context, { location: 'westus2' })
  union(context, { location: 'usgovvirginia', cloud: 'AzureUSGovernment' })
], target => {
  name: resourceNameForType({}, 'functionApps', 'inventory', target)
  storage: resourceNameForType({}, 'storageAccounts', 'inventory', target)
  hash: uniqueString(toLower(target.subscriptionId), toLower(target.resourceGroupName), toLower(target.location), toLower(target.cloud), 'inventory', 'functionapps')
})
var caseOnly = functionAppNames({}, 'INVENTORY', {
  subscriptionId: toUpper(context.subscriptionId)
  resourceGroupName: toUpper(context.resourceGroupName)
  location: toUpper(context.location)
  cloud: toLower(context.cloud)
})
var redeployment = functionAppNames({}, 'inventory', context)
var alternateIdentifier = functionAppNames({}, 'cleanup', context)
var normalizationCollision = [
  functionAppNames({}, 'inventory_app', context)
  functionAppNames({}, 'inventory-app', context)
]
var longIdentifiers = [
  functionAppNames({}, 'inventory-abcdefghijklmnopqrstuvwxyz-abcdefghijklmnopqrstuvwxyz-first', context)
  functionAppNames({}, 'inventory-abcdefghijklmnopqrstuvwxyz-abcdefghijklmnopqrstuvwxyz-second', context)
]
var noLocation = [
  functionAppNames({ components: ['resourceType', 'workload', 'purpose'] }, 'inventory', context)
  functionAppNames({ components: ['resourceType', 'workload', 'purpose'] }, 'inventory', union(context, { location: 'westus2' }))
]
var clouds = [
  functionAppNames({}, 'inventory', union(context, { location: 'usgovvirginia', cloud: 'AzureUSGovernment' }))
  functionAppNames({}, 'inventory', union(context, { location: 'usseceast', cloud: 'USSec' }))
  functionAppNames({}, 'inventory', union(context, { location: 'usnatnorth', cloud: 'USNat' }))
]
var vnetNames = map([0, 4, 36, 37, 80], count => join(map(range(0, count), index => 'v'), ''))

output encodedResults string = base64(string({
  cases: cases
  bundle: bundle
  identityExpected: identityExpected
  seeds: seeds
  caseOnly: caseOnly
  caseOnlyTypes: map(types, type => {
    type: type
    actual: resourceNameForType({}, toUpper(type), 'INVENTORY', context)
  })
  redeployment: redeployment
  alternateIdentifier: alternateIdentifier
  normalizationCollision: normalizationCollision
  longIdentifiers: longIdentifiers
  noLocation: noLocation
  clouds: clouds
  compatibilityBundle: compatibilityNames({}, 'inventory', context)
  resourceGroups: [
    resourceNameForType({}, 'resourceGroups', 'inventory', union(context, { resourceGroupName: '' }))
    resourceNameForType({}, 'resourceGroups', 'inventory', union(context, { resourceGroupName: 'rg-orchestrator' }))
  ]
  endpointTokens: map(vnetNames, vnet => {
    actual: privateEndpointVnetToken(vnet)
    expected: length(vnet) < 37 ? vnet : uniqueString(vnet)
  })
  endpoints: flatten(map(['pe-RESOURCE-SUBRESOURCE-VNETID', 'VNETID-SUBRESOURCE-RESOURCE-nic'], pattern => map(vnetNames, vnet => {
    actual: privateEndpointName(pattern, 'sa-inventory', 'file', vnet)
    expected: replace(replace(replace(pattern, 'SUBRESOURCE', 'file'), 'RESOURCE', 'sa-inventory'), 'VNETID', length(vnet) < 37 ? vnet : uniqueString(vnet))
  })))
  prefixes: map(['', 'customer-prefix', 'CUSTOMER-LONG-STORAGE-PREFIX'], prefix => {
    actual: fslogixStoragePrefix(prefix, 'abc123')
    expected: empty(prefix) ? 'fslogixabc123' : take(toLower(replace(prefix, '-', '')), 13)
  })
  shortSeeds: [
    {
      actual: shortScopedUnique({}, context.subscriptionId, context.resourceGroupName, context.location)
      expected: take(uniqueString(context.subscriptionId, context.resourceGroupName), 6)
    }
    {
      actual: shortScopedUnique({ components: ['resourceType', 'purpose'] }, context.subscriptionId, context.resourceGroupName, context.location)
      expected: take(uniqueString(context.subscriptionId, context.resourceGroupName, context.location), 6)
    }
  ]
}))
