import { namingPolicy as policy, functionAppNames, resourceNameForType, privateEndpointName, shortScopedUnique, fslogixNames } from '../../deployments/shared/modules/orchestration/naming/naming.bicep'

var context = {
  subscriptionId: '00000000-1111-2222-3333-444444444444'
  resourceGroupName: 'rg-addons'
  location: 'eastus'
  cloud: 'AzureCloud'
}
var types = map(items(policy.resourceTypes), type => type.key)
var profiles = [
  { label: 'default', convention: {}, identifier: 'fin' }
  { label: 'type-last', convention: { components: ['workload', 'purpose', 'location', 'resourceType'] }, identifier: 'fin' }
  { label: 'underscore', convention: { delimiter: '_' }, identifier: 'fin' }
  { label: 'dot', convention: { delimiter: '.' }, identifier: 'fin' }
  { label: 'empty-delimiter', convention: { delimiter: '' }, identifier: 'fin' }
  { label: 'no-location', convention: { components: ['resourceType', 'workload', 'purpose', 'none'] }, identifier: 'fin' }
  { label: 'purpose-only', convention: { components: ['purpose'] }, identifier: 'fin' }
  { label: 'partial-code', convention: { resourceTypeCodes: { functionApps: 'func', storageAccounts: 'st' } }, identifier: 'fin' }
  { label: 'repeated-type', convention: { components: ['resourceType', 'resourceType', 'workload', 'purpose', 'location'] }, identifier: 'fin' }
  { label: 'identifier-separators', convention: {}, identifier: 'Fin_01' }
  { label: 'custom-components', convention: { components: ['freeform1', 'environment', 'purpose', 'freeform2', 'resourceType'], freeform1: 'org', environment: 'prod', freeform2: 'x' }, identifier: 'fin' }
  { label: 'expanded-workload', convention: { workload: 'avdxx' }, identifier: 'fin' }
  { label: 'location-override', convention: { locationAbbreviation: 'e1' }, identifier: 'fin' }
]

var cases = flatten(map(profiles, profile => map(types, type => {
  profile: profile.label
  type: type
  identifier: profile.identifier
  actual: resourceNameForType(profile.convention, type, profile.identifier, context)
  hash: (policy.resourceTypes[type].?globallyUnique ?? false)
    ? take(uniqueString(toLower(context.subscriptionId), toLower(context.resourceGroupName), toLower(context.location), toLower(context.cloud), toLower(profile.identifier)), policy.resourceTypes[type].?uniqueLength ?? policy.limits.defaultUniqueLength)
    : ''
})))
var abbreviations = loadJsonContent('../../deployments/shared/data/resourceAbbreviations.json')
var boundaries = map(types, type => {
  type: type
  actual: resourceNameForType({}, type, join(map(range(0, policy.resourceTypes[type].lengthLimit - (type == 'storageAccounts'
    ? length('${abbreviations[type]}avduse') + (policy.resourceTypes[type].?uniqueLength ?? policy.limits.defaultUniqueLength)
    : length('${abbreviations[type]}-avd--use') + ((policy.resourceTypes[type].?globallyUnique ?? false) ? 1 + (policy.resourceTypes[type].?uniqueLength ?? policy.limits.defaultUniqueLength) : 0))), index => 'a'), ''), context)
})
var bundle = functionAppNames({}, 'inventory', context, {})
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
  hash: take(uniqueString(toLower(target.subscriptionId), toLower(target.resourceGroupName), toLower(target.location), toLower(target.cloud), 'inventory'), policy.limits.defaultUniqueLength)
})
var caseOnly = functionAppNames({}, 'INVENTORY', {
  subscriptionId: toUpper(context.subscriptionId)
  resourceGroupName: toUpper(context.resourceGroupName)
  location: toUpper(context.location)
  cloud: toLower(context.cloud)
}, {})
var redeployment = functionAppNames({}, 'inventory', context, {})
var alternateIdentifier = functionAppNames({}, 'cleanup', context, {})
var normalizationCollision = [
  functionAppNames({}, 'inv_app', context, {})
  functionAppNames({}, 'inv-app', context, {})
]
var longOverride = functionAppNames({}, 'finance-long-shr', context, {
  storageAccountName: 'CUSTOMSHRSTORAGE'
})
var overrides = functionAppNames({}, 'finance-shr', context, {
  functionAppName: 'custom-function'
  storageAccountName: 'CUSTOMSTORAGE'
  storageEncryptionIdentityName: 'custom-storage-identity'
})
var noLocation = [
  functionAppNames({ components: ['resourceType', 'workload', 'purpose'] }, 'inventory', context, {})
  functionAppNames({ components: ['resourceType', 'workload', 'purpose'] }, 'inventory', union(context, { location: 'westus2' }), {})
]
var clouds = [
  functionAppNames({}, 'inventory', union(context, { location: 'usgovvirginia', cloud: 'AzureUSGovernment' }), {})
  functionAppNames({}, 'inventory', union(context, { location: 'usseceast', cloud: 'USSec' }), {})
  functionAppNames({}, 'inventory', union(context, { location: 'usnatnorth', cloud: 'USNat' }), {})
]
var vnetNames = map([0, 4, 36, 37, 80], count => join(map(range(0, count), index => 'v'), ''))

output encodedResults string = base64(string({
  cases: cases
  boundaries: boundaries
  bundle: bundle
  identityExpected: identityExpected
  seeds: seeds
  caseOnly: caseOnly
  caseOnlyTypes: map(types, type => {
    type: type
    actual: resourceNameForType({}, toUpper(type), 'FIN', context)
  })
  redeployment: redeployment
  alternateIdentifier: alternateIdentifier
  normalizationCollision: normalizationCollision
  longOverride: longOverride
  overrides: overrides
  applications: map(['finance-shr', 'hr-shr', 'finance-job'], identifier => {
    names: functionAppNames({}, identifier, context, {})
    sharedPlan: resourceNameForType({}, 'appServicePlans', 'shr', context)
    hash: take(uniqueString(toLower(context.subscriptionId), toLower(context.resourceGroupName), toLower(context.location), toLower(context.cloud), identifier), policy.limits.defaultUniqueLength)
  })
  locationTag: functionAppNames({ vmsLocationAbbreviation: 'e1' }, 'finance-shr', context, {})
  locationPrecedence: functionAppNames({ locationAbbreviation: 'e2', vmsLocationAbbreviation: 'e1' }, 'finance-shr', context, {})
  noLocation: noLocation
  clouds: clouds
  resourceGroups: [
    resourceNameForType({}, 'resourceGroups', 'inventory', union(context, { resourceGroupName: '' }))
    resourceNameForType({}, 'resourceGroups', 'inventory', union(context, { resourceGroupName: 'rg-orchestrator' }))
  ]
  endpointTokens: map(vnetNames, vnet => {
    actual: privateEndpointName('VNETID', '', '', vnet)
    expected: length(vnet) < 37 ? vnet : uniqueString(vnet)
  })
  endpoints: flatten(map(['pe-RESOURCE-SUBRESOURCE-VNETID', 'VNETID-SUBRESOURCE-RESOURCE-nic'], pattern => map(vnetNames, vnet => {
    actual: privateEndpointName(pattern, 'sa-inventory', 'file', vnet)
    expected: replace(replace(replace(pattern, 'SUBRESOURCE', 'file'), 'RESOURCE', 'sa-inventory'), 'VNETID', length(vnet) < 37 ? vnet : uniqueString(vnet))
  })))
  prefixes: map(['', 'customer-prefix', 'CUSTOMER-LONG-STORAGE-PREFIX'], prefix => {
    actual: fslogixNames({ fslogixStoragePrefix: prefix }, 'finance', { subscriptionId: context.subscriptionId, cloud: context.cloud, location: context.location }).fslogixStorageAccountNamePrefix
    expected: empty(prefix) ? 'fslogix${take(uniqueString(context.subscriptionId, 'rg-avd-finance-storage-use'), 6)}' : take(toLower(replace(prefix, '-', '')), 13)
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
