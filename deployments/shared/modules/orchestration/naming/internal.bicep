metadata name = 'FederalAVD internal naming implementation'
metadata description = 'Internal policy, scope-based naming and resource-module helpers. Deployment callers use the public naming.bicep interface.'

@export()
@description('Default OS disk pattern. Import this scalar when no other naming rules are needed.')
var osDiskNamePattern string = 'SHNAME-osdisk'

@export()
@description('Authoritative naming defaults, resource roles, patterns and length limits.')
var namingPolicy object = {
  defaults: { components: ['resourceType', 'workload', 'purpose', 'location'], delimiter: '-', workload: 'avd' }
  identifiers: { imageManagement: 'image-management', sessionHostReplacer: 'shr', sharedFslogix: 'fslogix' }
  limits: {
    deploymentVm: 15
    fslogixProfileStoragePrefix: 13
    uniqueSuffix: 6
    defaultUniqueLength: 6
    imageManagementStoragePrefix: 5
    imageManagementStorageLocation: 4
  }
  resourceTypes: {
    functionApps: { azureResourceType: 'Microsoft.Web/sites', namingVariant: 'functionapp', lengthLimit: 60, format: 'hyphen', globallyUnique: true }
    storageAccounts: { azureResourceType: 'Microsoft.Storage/storageAccounts', lengthLimit: 24, format: 'storage', globallyUnique: true }
    applicationInsights: { azureResourceType: 'Microsoft.Insights/components', lengthLimit: 260, format: 'hyphen' }
    appServicePlans: { azureResourceType: 'Microsoft.Web/serverfarms', lengthLimit: 60, format: 'hyphen' }
    userAssignedIdentities: { azureResourceType: 'Microsoft.ManagedIdentity/userAssignedIdentities', lengthLimit: 128, format: 'hyphen' }
    automationAccounts: { azureResourceType: 'Microsoft.Automation/automationAccounts', lengthLimit: 50, format: 'hyphen', startWithLetter: true }
    availabilitySets: { azureResourceType: 'Microsoft.Compute/availabilitySets', lengthLimit: 80, format: 'hyphen' }
    computeGalleries: { azureResourceType: 'Microsoft.Compute/galleries', lengthLimit: 80, format: 'gallery' }
    dataCollectionEndpoints: { azureResourceType: 'Microsoft.Insights/dataCollectionEndpoints', lengthLimit: 44, format: 'hyphen' }
    dataCollectionRules: { azureResourceType: 'Microsoft.Insights/dataCollectionRules', lengthLimit: 64, format: 'hyphen' }
    desktopApplicationGroups: { azureResourceType: 'Microsoft.DesktopVirtualization/applicationGroups', namingVariant: 'Desktop', lengthLimit: 64, format: 'hyphen' }
    remoteApplicationGroups: { azureResourceType: 'Microsoft.DesktopVirtualization/applicationGroups', namingVariant: 'RemoteApp', lengthLimit: 64, format: 'hyphen' }
    diskAccesses: { azureResourceType: 'Microsoft.Compute/diskAccesses', lengthLimit: 64, format: 'hyphen' }
    diskEncryptionSets: { azureResourceType: 'Microsoft.Compute/diskEncryptionSets', lengthLimit: 80, format: 'hyphen' }
    hostPools: { azureResourceType: 'Microsoft.DesktopVirtualization/hostPools', lengthLimit: 64, format: 'hyphen' }
    keyVaults: { azureResourceType: 'Microsoft.KeyVault/vaults', lengthLimit: 24, format: 'hyphen', globallyUnique: true, uniqueLength: 6, startWithLetter: true, noConsecutiveHyphens: true }
    logAnalyticsWorkspaces: { azureResourceType: 'Microsoft.OperationalInsights/workspaces', lengthLimit: 63, format: 'hyphen' }
    natGateways: { azureResourceType: 'Microsoft.Network/natGateways', lengthLimit: 80, format: 'hyphen' }
    netAppAccounts: { azureResourceType: 'Microsoft.NetApp/netAppAccounts', lengthLimit: 128, format: 'hyphen' }
    netAppCapacityPools: { azureResourceType: 'Microsoft.NetApp/netAppAccounts/capacityPools', lengthLimit: 64, format: 'hyphen' }
    networkInterfaces: { azureResourceType: 'Microsoft.Network/networkInterfaces', lengthLimit: 80, format: 'hyphen' }
    networkSecurityGroups: { azureResourceType: 'Microsoft.Network/networkSecurityGroups', lengthLimit: 80, format: 'hyphen' }
    osdisks: { azureResourceType: 'Microsoft.Compute/disks', lengthLimit: 80, format: 'hyphen' }
    privateEndpoints: { azureResourceType: 'Microsoft.Network/privateEndpoints', lengthLimit: 64, format: 'hyphen' }
    privateLinkScopes: { azureResourceType: 'Microsoft.Insights/privateLinkScopes', lengthLimit: 64, format: 'hyphen' }
    publicIPAddresses: { azureResourceType: 'Microsoft.Network/publicIPAddresses', lengthLimit: 80, format: 'hyphen' }
    recoveryServicesVaults: { azureResourceType: 'Microsoft.RecoveryServices/vaults', lengthLimit: 50, format: 'hyphen', startWithLetter: true }
    resourceGroups: { azureResourceType: 'Microsoft.Resources/resourceGroups', lengthLimit: 90, format: 'hyphen' }
    routeTables: { azureResourceType: 'Microsoft.Network/routeTables', lengthLimit: 80, format: 'hyphen' }
    scalingPlans: { azureResourceType: 'Microsoft.DesktopVirtualization/scalingPlans', lengthLimit: 63, format: 'hyphen' }
    templateSpecs: { azureResourceType: 'Microsoft.Resources/templateSpecs', lengthLimit: 90, format: 'hyphen' }
    virtualMachines: { azureResourceType: 'Microsoft.Compute/virtualMachines', lengthLimit: 64, format: 'hyphen' }
    virtualNetworks: { azureResourceType: 'Microsoft.Network/virtualNetworks', lengthLimit: 64, format: 'hyphen' }
    subnets: { azureResourceType: 'Microsoft.Network/virtualNetworks/subnets', lengthLimit: 80, format: 'hyphen' }
    workspaces: { azureResourceType: 'Microsoft.DesktopVirtualization/workspaces', lengthLimit: 64, format: 'hyphen' }
    imageDefinitions: { azureResourceType: 'Microsoft.Compute/galleries/images', lengthLimit: 80, format: 'hyphen' }
  }
  resources: {
    operationsResourceGroup: { type: 'resourceGroups', purpose: ['operations'] }
    monitoringResourceGroup: { type: 'resourceGroups', purpose: ['monitoring'] }
    controlPlaneResourceGroup: { type: 'resourceGroups', purpose: ['control', 'plane'] }
    globalFeedResourceGroup: { type: 'resourceGroups', purpose: ['global', 'feed'] }
    globalFeedWorkspace: { type: 'workspaces', purpose: ['global', 'feed'] }
    workspace: { type: 'workspaces', purpose: [] }
    hostWorkspace: { type: 'workspaces', purpose: ['{identifier}'] }
    deploymentResourceGroup: { type: 'resourceGroups', purpose: ['{identifier}', 'deployment'] }
    deploymentVm: { type: '', purpose: ['{identifier}'] }
    consolidatedResourceGroup: { type: 'resourceGroups', purpose: ['{identifier}'] }
    hostsResourceGroup: { type: 'resourceGroups', purpose: ['{identifier}', 'hosts'] }
    storageResourceGroup: { type: 'resourceGroups', purpose: ['{identifier}', 'storage'] }
    secretsKeyVault: { type: 'keyVaults', purpose: ['sec', '{unique}'] }
    encryptionKeyVault: { type: 'keyVaults', purpose: ['enc', '{unique}'] }
    dataCollectionEndpoint: { type: 'dataCollectionEndpoints', purpose: [] }
    logAnalyticsWorkspace: { type: 'logAnalyticsWorkspaces', purpose: [] }
    hostPool: { type: 'hostPools', purpose: ['{identifier}'] }
    desktopApplicationGroup: { type: 'desktopApplicationGroups', purpose: ['{identifier}'] }
    scalingPlan: { type: 'scalingPlans', purpose: ['{identifier}'] }
    vmBackupVault: { type: 'recoveryServicesVaults', purpose: ['{identifier}'] }
    filesBackupVault: { type: 'recoveryServicesVaults', purpose: ['files'] }
    identityPattern: { type: 'userAssignedIdentities', purpose: ['{identifier}', 'TOKEN'] }
    availabilitySet: { type: 'availabilitySets', purpose: ['{identifier}'] }
    diskAccess: { type: 'diskAccesses', purpose: ['{identifier}'] }
    diskEncryptionSetPattern: { type: 'diskEncryptionSets', purpose: ['{identifier}', 'TOKEN'] }
    netAppAccount: { type: 'netAppAccounts', purpose: ['{identifier}'] }
    netAppCapacityPool: { type: 'netAppCapacityPools', purpose: ['{identifier}'] }
    imageManagementResourceGroup: { type: 'resourceGroups', purpose: ['{identifier}'] }
    imageGallery: { type: 'computeGalleries', purpose: ['{identifier}'] }
    imageBlobIdentity: { type: 'userAssignedIdentities', purpose: ['{identifier}-blob-access'] }
    imageStorageEncryptionIdentity: { type: 'userAssignedIdentities', purpose: ['{identifier}-storage-cmk'] }
    imageBuildResourceGroup: { type: 'resourceGroups', purpose: ['image-builds'] }
    imageGalleryCustomerKeys: { type: 'diskEncryptionSets', purpose: ['{identifier}-customer-keys'] }
    imageGalleryDoubleEncryptionKeys: { type: 'diskEncryptionSets', purpose: ['{identifier}-platform-and-customer-keys'] }
    imageGalleryConfidentialKeys: { type: 'diskEncryptionSets', purpose: ['{identifier}-confidential-vm'] }
    networkNatGateway: { type: 'natGateways', purpose: [] }
    networkPublicIP: { type: 'publicIPAddresses', purpose: [] }
    networkRouteTable: { type: 'routeTables', purpose: [] }
    networkSecurityGroup: { type: 'networkSecurityGroups', purpose: [] }
    pocVirtualNetwork: { type: 'virtualNetworks', purpose: ['{identifier}'] }
    pocHostsSubnet: { type: 'subnets', purpose: ['{identifier}', 'hosts'] }
    pocNatGateway: { type: 'natGateways', purpose: ['{identifier}'] }
    pocPublicIP: { type: 'publicIPAddresses', purpose: ['{identifier}'] }
    pocSecurityGroup: { type: 'networkSecurityGroups', purpose: ['{identifier}'] }
    alertsAutomation: { type: 'automationAccounts', purpose: ['alerts'] }
    quotaAutomation: { type: 'automationAccounts', purpose: ['sqm', '{identifier}'], omitWorkload: true, omitEmptyPurposeParts: true }
    routesAutomation: { type: 'automationAccounts', purpose: ['urt', '{unique}'], omitWorkload: true }
  }
  patterns: {
    virtualMachine: 'SHNAME'
    osDisk: osDiskNamePattern
    nic: 'SHNAME-nic'
    standaloneAvailabilitySet: 'avset-##'
    privateEndpointFirst: '{privateEndpoints}-RESOURCE-SUBRESOURCE-VNETID'
    privateEndpointLast: 'RESOURCE-SUBRESOURCE-VNETID-{privateEndpoints}'
    privateEndpointNicFirst: '{networkInterfaces}-{endpoint}'
    privateEndpointNicLast: '{endpoint}-{networkInterfaces}'
    deploymentDisk: '{vm}-{osdisks}'
    deploymentNic: '{vm}-{networkInterfaces}'
    availabilitySet: '{name}{delimiter}##'
    policyIdentityPurpose: 'policy{delimiter}remediation'
    deploymentIdentityPurpose: 'deployment'
    monitorIdentityPurpose: 'ama'
    confidentialDiskPurpose: 'confvm{delimiter}customer{delimiter}keys'
    customerDiskPurpose: 'customer{delimiter}keys'
    doubleEncryptionDiskPurpose: 'platform{delimiter}and{delimiter}customer{delimiter}keys'
    fslogixProfileStoragePrefix: 'fslpc{unique}'
    fslogixOfficeStoragePrefix: 'fsloc{unique}'
    fslogixKey: '{identifier}-{storagePrefix}##-cmk'
    vmKey: '{identifier}-vm-cmk'
    confidentialVmKey: '{identifier}-cvm-cmk'
    recoveryServicesKey: '{identifier}-rsv-cmk'
    imageStorageKey: '{identifier}-storage-cmk'
    storageCmkKey: '{identifier}-storage-cmk'
    imageGalleryKey: '{identifier}-gallery-cmk'
    imageGalleryConfidentialKey: '{identifier}-gallery-cvm-cmk'
    imageStorageFirst: '{storageAccounts}{purpose}{unique}{location}'
    imageStorageLast: '{purpose}{unique}{location}{storageAccounts}'
    imageStorageCustomPrefix: '{prefix}{purpose}{unique}{location}'
    imageBuildResourceGroup: '{resourceGroups}-{prefix}{workload}-image-builds-{location}-{timestamp}-{unique}'
    imageBuildCustomResourceGroup: '{name}-{timestamp}-{unique}'
    imageBuildVm: '{prefix}img-{unique}'
    imageBuildOrchestrationVm: '{prefix}orc-{unique}'
    deploymentPrefix: '{prefix}-'
    imageDefinition: '{imageDefinitions}-{publisher}-{offer}-{sku}'
  }
  imageStoragePurposes: { artifacts: 'imgassets', logs: 'imglogs' }
  templateSpecs: {
    sharedServices: 'shared-services'
    networking: 'networking'
    imageBuild: 'custom-image'
    hostPool: 'hostpool'
    hostPoolPoc: 'hostpool-poc'
    automatedHostPool: 'automated-hostpool'
    runCommandsOnVms: 'run-commands-on-vms'
    updateStorageAccountKeyOnSessionHosts: 'update-storage-account-key-on-session-hosts'
    fslogixStorage: 'fslogix-storage'
    storageQuotaManager: 'storage-quota-manager'
    sessionHostReplacer: 'session-host-replacer'
    sessionHosts: 'session-hosts'
    sessionHostPolicy: 'session-host-policy'
  }
}

var resourceAbbreviations object = loadJsonContent('../../../data/resourceAbbreviations.json')
var locationDefinitions object = loadJsonContent('../../../data/locations.json')
var azureResourceTypeKeys object = toObject(items(namingPolicy.resourceTypes), rule => '${toLower(rule.value.azureResourceType)}|${toLower(rule.value.?namingVariant ?? '')}', rule => rule.key)

@export()
@sealed()
@description('Shared optional convention settings. Custom tokens can appear anywhere in components; freeform1/freeform2 remain supported aliases. Explicit resource-name patterns are not reformatted.')
type namingConventionConfig = {
  components: ('resourceType' | 'workload' | 'purpose' | 'location' | 'environment' | 'customToken1' | 'customToken2' | 'freeform1' | 'freeform2' | 'none')[]?
  delimiter: string?
  workload: string?
  environment: string?
  customToken1: string?
  customToken2: string?
  freeform1: string?
  freeform2: string?
  resourceTypeCodes: { *: string }?
  locationAbbreviation: string?
  cpLocationAbbreviation: string?
  vmsLocationAbbreviation: string?
  fslogixProfileStoragePrefix: string?
  fslogixOfficeStoragePrefix: string?
  imageManagementStoragePrefix: string?
  secretsKeyVaultNameOverride: string?
  encryptionKeyVaultNameOverride: string?
  virtualMachineNameConvOverride: string?
  virtualMachineDiskNameConvOverride: string?
  virtualMachineNicNameConvOverride: string?
}

func resolveComponent(comp string, rtCode string, component string, loc string, ff1 string, env string, ff2 string, workload string) string =>
  comp == 'resourceType' ? rtCode
    : comp == 'purpose' ? component
    : comp == 'location' ? loc
    : contains(['freeform1', 'customToken1'], comp) ? ff1
    : comp == 'environment' ? env
    : contains(['freeform2', 'customToken2'], comp) ? ff2
    : comp == 'workload' ? workload
    : ''

@description('Joins the selected component values in order, omitting empty values and unknown component names. Does not sanitize, truncate, or add uniqueness.')
func buildCustomName(components array, delimiter string, rtCode string, component string, loc string, ff1 string, env string, ff2 string, workload string) string =>
  join(
    filter(
      map(components, comp => resolveComponent(comp, rtCode, component, loc, ff1, env, ff2, workload)),
      s => !empty(s)
    ),
    delimiter
  )

@description('Builds a convention-based name after excluding none components. Uses the same argument order as buildCustomName.')
func cnv(components array, delimiter string, rtCode string, component string, loc string, ff1 string, env string, ff2 string, workload string) string =>
  buildCustomName(filter(components, s => s != 'none'), delimiter, rtCode, component, loc, ff1, env, ff2, workload)

@description('Removes hyphens, underscores, and dots. Callers separately enforce case, length, uniqueness, and the remaining resource naming rules.')
func stripSeps(s string) string =>
  replace(replace(replace(s, '-', ''), '_', ''), '.', '')

@description('Replaces underscores and dots with hyphens for Key Vault naming. Does not truncate or validate the complete name.')
func kvSanitize(s string) string =>
  replace(replace(s, '_', '-'), '.', '-')

@export()
@description('Resolves shared defaults, custom-token aliases and partial abbreviation overrides. Conflicting alias values fail; explicit empty delimiters and existing default-workload behavior are preserved.')
func resolveConvention(convention object) object => union(namingPolicy.defaults, convention, {
  components: map(convention.?components ?? namingPolicy.defaults.components, component => component == 'customToken1' ? 'freeform1' : component == 'customToken2' ? 'freeform2' : component)
  delimiter: convention.?delimiter ?? namingPolicy.defaults.delimiter
  workload: !empty(convention.?workload ?? '') ? convention.workload : namingPolicy.defaults.workload
  freeform1: resolveCustomToken(convention, 'customToken1', 'freeform1')
  environment: convention.?environment ?? ''
  freeform2: resolveCustomToken(convention, 'customToken2', 'freeform2')
  resourceTypeCodes: union(resourceAbbreviations, convention.?resourceTypeCodes ?? {})
})

func resolveCustomToken(convention object, preferred string, legacy string) string =>
  convention[?preferred] != null && convention[?legacy] != null && convention[preferred] != convention[legacy]
    ? fail('namingConvention.${preferred} and ${legacy} are aliases and must agree when both are supplied.')
    : convention[?preferred] ?? convention[?legacy] ?? ''

@export()
@description('Tests the final selected component, ignoring none entries. Empty component selections use resource-type-first patterns.')
func resourceTypeFirst(convention object) bool =>
  empty(filter(resolveConvention(convention).components, component => component != 'none')) || last(filter(resolveConvention(convention).components, component => component != 'none')) != 'resourceType'

@export()
@description('Resolves the target-cloud location abbreviation. Callers apply their existing explicit location-abbreviation overrides before using this result.')
func regionAbbreviation(region string, cloud string) string =>
  locationDefinitions[startsWith(toLower(cloud), 'us') ? 'other' : cloud][startsWith(toLower(cloud), 'us') ? substring(region, 5, max(length(region) - 5, 0)) : region].abbreviation

func render(pattern string, context object) string =>
  reduce(items(context), pattern, (result, item) => replace(result, '{${item.key}}', string(item.value)))

@export()
@description('Renders one centrally defined name pattern with caller-supplied context. Literal Azure-required names and explicit customer names are not convention-generated.')
func namePattern(pattern string, context object) string =>
  render(namingPolicy.patterns[pattern], union({ delimiter: namingPolicy.defaults.delimiter }, context))

func resourcePurpose(rule object, delimiter string, identifier string, unique string) string =>
  join(filter(map(rule.purpose, part => render(part, {
    identifier: identifier
    unique: unique
  })), part => !(rule.?omitEmptyPurposeParts ?? false) || !empty(part)), delimiter)

func resolvedResourceName(convention object, rule object, region string, identifier string, unique string) string =>
  resolvedTypeName(
    union(validateConvention(convention, !empty(rule.purpose)), {
      components: (rule.?omitWorkload ?? false) ? filter(convention.components, component => component != 'workload') : convention.components
    }),
    empty(rule.type) ? { format: 'literal', fragment: true } : union(namingPolicy.resourceTypes[rule.type], {
      format: contains(['keyVaults', 'computeGalleries'], rule.type) ? namingPolicy.resourceTypes[rule.type].format : 'literal'
      preserveCase: true
    }),
    empty(rule.type) ? '' : requireNamingToken(convention.resourceTypeCodes[rule.type], 'Resource type abbreviation'),
    empty(region) ? '' : requireNamingToken(region, 'Location abbreviation'),
    resourcePurpose(rule, convention.delimiter, empty(identifier) ? '' : requireNamingToken(identifier, 'Resource identifier'), unique),
    ''
  )

@export()
@description('Internal role adapter to the common naming engine. Roles supply purpose, workload exceptions and established casing/formatting; all actual resource names use the shared convention and type validators.')
func resourceName(convention object, role string, region string, identifier string, unique string) string =>
  resolvedResourceName(resolveConvention(convention), namingPolicy.resources[role], region, identifier, unique)

// Identifier-based naming for new resources and add-ons.
@export()
@description('Actual target context for identifier-based naming. Globally named types hash the subscription, owning resource group and location; cloud selects the region map only. Resource groups accept an empty resourceGroupName; scope-local names do not add a hash.')
type namingContext = {
  subscriptionId: string
  resourceGroupName: string
  location: string
  cloud: string
  namingVariant: string?
}

@export()
@description('Per-application Function App, storage, Insights, storage-CMK identity names and private-endpoint patterns. Shared hosting plans are named separately by their owner.')
type functionAppNamingResult = {
  functionAppName: string
  storageAccountName: string
  applicationInsightsName: string
  storageEncryptionIdentityName: string
  privateEndpointNameConv: string
  privateEndpointNICNameConv: string
}

@export()
@description('Optional explicit names applied before generating per-application defaults, allowing an override to bypass an overlength generated name. Empty values use the common naming rules.')
type functionAppNameOverrides = {
  functionAppName: string?
  storageAccountName: string?
  storageEncryptionIdentityName: string?
}

func isNamingToken(value string) bool =>
  !empty(value) && contains('abcdefghijklmnopqrstuvwxyz0123456789', toLower(first(value))) && contains('abcdefghijklmnopqrstuvwxyz0123456789', toLower(last(value))) && empty(filter(map(range(0, length(value)), i => toLower(substring(value, i, 1))), character => !contains('abcdefghijklmnopqrstuvwxyz0123456789-_.', character)))

func requireNamingToken(value string, label string) string =>
  isNamingToken(value) ? value : fail('${label} must contain only ASCII letters, numbers, hyphens, underscores or dots, and start and end with a letter or number.')

func validateNamingContext(context namingContext, resourceType string) namingContext =>
  !empty(filter([context.subscriptionId, context.location, context.cloud], value => empty(trim(value)) || value != trim(value))) || context.resourceGroupName != trim(context.resourceGroupName) || (empty(context.resourceGroupName) && toLower(resourceType) != 'microsoft.resources/resourcegroups')
    ? fail('Naming context requires subscriptionId, location and cloud without surrounding whitespace, plus resourceGroupName for resources below subscription scope.')
    : union(context, { cloud: canonicalNamingCloud(context.cloud) })

func validateConvention(convention object, requirePurpose bool) object =>
  (requirePurpose && length(filter(convention.components, component => component == 'purpose')) != 1) || length(filter(convention.components, component => component == 'purpose')) > 1
    ? fail('Naming requires exactly one purpose component for resources with a purpose.')
    : empty(filter(convention.components, component => component != 'none'))
      ? fail('Naming requires at least one non-none component.')
    : !empty(filter(convention.components, component => !contains(['resourceType', 'purpose', 'location', 'workload', 'environment', 'freeform1', 'freeform2', 'none'], component)))
      ? fail('Naming contains an unsupported naming-convention component.')
      : length(convention.delimiter) > 3 || !empty(filter(map(range(0, length(convention.delimiter)), i => substring(convention.delimiter, i, 1)), character => !contains('-_.', character)))
        ? fail('Naming delimiter must be empty or contain at most three hyphens, underscores or dots.')
        : !empty(filter(['workload', 'environment', 'freeform1', 'freeform2'], component => contains(convention.components, component) && !empty(convention[component]) && !isNamingToken(convention[component])))
          ? fail('Selected naming-convention values must contain only ASCII letters, numbers, hyphens, underscores or dots, and start and end with a letter or number.')
          : convention

func canonicalNamingCloud(cloud string) string =>
  toLower(cloud) == 'azurecloud' ? 'AzureCloud'
    : toLower(cloud) == 'azureusgovernment' ? 'AzureUSGovernment'
    : startsWith(toLower(cloud), 'us') ? cloud
    : fail('Identifier-based naming supports AzureCloud, AzureUSGovernment and US-prefixed air-gapped cloud environments.')

func typeLocationAbbreviation(convention object, context namingContext) string =>
  requireNamingToken(!empty(convention.?locationAbbreviation ?? '')
    ? convention.locationAbbreviation
    : !empty(convention.?vmsLocationAbbreviation ?? '')
      ? convention.vmsLocationAbbreviation
      : regionAbbreviation(toLower(context.location), context.cloud), 'Location abbreviation')

func formatTypeName(value string, rule object) string =>
  (rule.?preserveCase ?? false) || rule.format == 'literal'
    ? applyTypeFormat(value, rule)
    : toLower(applyTypeFormat(value, rule))

func applyTypeFormat(value string, rule object) string =>
  rule.format == 'storage' ? stripSeps(value)
    : rule.format == 'gallery' ? replace(value, '-', '_')
    : rule.format == 'hyphen' ? kvSanitize(value)
    : rule.format == 'literal' ? value
    : fail('Unsupported resource-type naming format.')

func validateTypeName(name string, rule object) string =>
  (rule.?fragment ?? false) ? name
    : empty(name) ? fail('Generated name must not be empty.')
    : length(name) > rule.lengthLimit
    ? fail('Generated name exceeds the ${rule.lengthLimit}-character limit. Shorten the identifier or naming-convention values.')
    : (rule.?startWithLetter ?? false) && !contains('abcdefghijklmnopqrstuvwxyz', toLower(first(name)))
      ? fail('This resource type requires a name starting with a letter. Change the first selected component.')
      : (rule.?noConsecutiveHyphens ?? false) && contains(name, '--')
        ? fail('This resource type does not allow consecutive hyphens. Change the identifier, delimiter or selected values.')
        : name

func composeTypeName(convention object, rule object, code string, region string, identifier string, unique string) string =>
  formatTypeName(cnv(
    convention.components,
    convention.delimiter,
    code,
    empty(unique) ? identifier : '${identifier}${convention.delimiter}${unique}',
    region,
    convention.freeform1,
    convention.environment,
    convention.freeform2,
    convention.workload
  ), rule)

func resolvedTypeName(convention object, rule object, code string, region string, identifier string, unique string) string =>
  validateTypeName(composeTypeName(convention, rule, code, region, identifier, unique), rule)

func scopedTypeName(convention object, resourceType string, identifier string, context namingContext) string =>
  !contains(namingPolicy.resourceTypes, resourceType)
    ? fail('Unsupported identifier-based resource type. Use a resource type registered in namingPolicy.resourceTypes.')
    : resolvedTypeName(
      convention,
      namingPolicy.resourceTypes[resourceType],
      requireNamingToken(convention.resourceTypeCodes[resourceType], 'Resource type abbreviation'),
      typeLocationAbbreviation(convention, context),
      requireNamingToken(identifier, 'Add-on identifier'),
      (namingPolicy.resourceTypes[resourceType].?globallyUnique ?? false)
        ? take(scopeUnique(context), namingPolicy.resourceTypes[resourceType].?uniqueLength ?? namingPolicy.limits.defaultUniqueLength)
        : ''
    )

func azureResourceTypeKey(resourceType string, variant string) string =>
  azureResourceTypeKeys[?'${toLower(resourceType)}|${toLower(variant)}'] ?? fail('Unsupported Azure resource type or namingVariant: ${resourceType} (${variant}). Use a registered official resource type without an API version. Microsoft.Web/sites requires namingVariant functionapp; Microsoft.DesktopVirtualization/applicationGroups requires Desktop or RemoteApp. Legacy naming keys are not accepted.')

@export()
@description('Names an official Azure resource type without an API version. Ambiguous types require context.namingVariant. Globally named types share a scope hash independent of purpose; scope-local types have no hash. Overlength names fail.')
func resourceNameForType(convention object, resourceType string, identifier string, context namingContext) string =>
  scopedTypeName(validateConvention(resolveConvention(convention), true), azureResourceTypeKey(resourceType, context.?namingVariant ?? ''), identifier, validateNamingContext(context, resourceType))

@export()
@description('Names per-application Function App infrastructure with common explicit overrides. App and storage share a hash; Insights and the storage-CMK identity retain the purpose and region without a hash. Hosting plans have separate ownership.')
func functionAppNames(convention object, identifier string, context namingContext, overrides functionAppNameOverrides) functionAppNamingResult => {
  functionAppName: !empty(overrides.?functionAppName ?? '') ? overrides.?functionAppName ?? '' : resourceNameForType(convention, 'Microsoft.Web/sites', identifier, union(context, { namingVariant: 'functionapp' }))
  storageAccountName: !empty(overrides.?storageAccountName ?? '') ? toLower(overrides.?storageAccountName ?? '') : resourceNameForType(convention, 'Microsoft.Storage/storageAccounts', identifier, context)
  applicationInsightsName: resourceNameForType(convention, 'Microsoft.Insights/components', identifier, context)
  storageEncryptionIdentityName: !empty(overrides.?storageEncryptionIdentityName ?? '') ? overrides.?storageEncryptionIdentityName ?? '' : resourceNameForType(convention, 'Microsoft.ManagedIdentity/userAssignedIdentities', '${identifier}-storage-cmk', context)
  privateEndpointNameConv: privateEndpointPattern(resourceTypeFirst(convention), requireNamingToken(resolveConvention(convention).resourceTypeCodes.privateEndpoints, 'Private endpoint abbreviation'))
  privateEndpointNICNameConv: privateEndpointNicPattern(resourceTypeFirst(convention), requireNamingToken(resolveConvention(convention).resourceTypeCodes.privateEndpoints, 'Private endpoint abbreviation'), requireNamingToken(resolveConvention(convention).resourceTypeCodes.networkInterfaces, 'Network interface abbreviation'))
}

func temporaryVmName(raw string) string =>
  take('${raw}${uniqueString(raw)}', namingPolicy.limits.deploymentVm)

@description('Names the temporary deployment VM using the existing separator-removal, uniqueness and Windows computer-name length rule.')
func deploymentVmName(convention object, region string, identifier string) string =>
  temporaryVmName(stripSeps(resourceName(convention, 'deploymentVm', region, identifier, '')))

@export()
@description('One stable resource-scope hash: lowercase subscription, owning resource group and full location. Cloud, purpose, resource type and naming-convention choices never participate. Callers apply their suffix budget.')
func scopeUnique(context namingContext) string =>
  uniqueString(toLower(context.subscriptionId), toLower(context.resourceGroupName), toLower(context.location))

@export()
@description('Builds the shared private endpoint pattern; the consuming module replaces RESOURCE, SUBRESOURCE and VNETID.')
func privateEndpointPattern(first bool, privateEndpointCode string) string =>
  namePattern(first ? 'privateEndpointFirst' : 'privateEndpointLast', { privateEndpoints: privateEndpointCode })

@export()
@description('Builds the shared private endpoint NIC pattern with the same resource-type placement as the endpoint.')
func privateEndpointNicPattern(first bool, privateEndpointCode string, networkInterfaceCode string) string =>
  namePattern(first ? 'privateEndpointNicFirst' : 'privateEndpointNicLast', {
    networkInterfaces: networkInterfaceCode
    endpoint: privateEndpointPattern(first, privateEndpointCode)
  })

// Specialized image and identity formatting.
@export()
@description('Validates the Image Management storage prefix and its location budget before constructing either account name.')
func validateImageStoragePrefix(prefix string, region string) string =>
  !empty(prefix) && (length(prefix) > namingPolicy.limits.imageManagementStoragePrefix || prefix != toLower(prefix) || !empty(filter(map(range(0, length(prefix)), i => substring(prefix, i, 1)), character => !contains('abcdefghijklmnopqrstuvwxyz0123456789', character))))
    ? fail('namingConvention.imageManagementStoragePrefix must contain no more than ${namingPolicy.limits.imageManagementStoragePrefix} lowercase letters or numbers.')
    : !empty(prefix) && length(region) > namingPolicy.limits.imageManagementStorageLocation
      ? fail('The location abbreviation must contain no more than ${namingPolicy.limits.imageManagementStorageLocation} characters when namingConvention.imageManagementStoragePrefix is specified.')
      : prefix

func imageStorageNameResolved(convention object, kind string, abbreviation string, unique string, prefix string) string =>
  namePattern(!empty(prefix) ? 'imageStorageCustomPrefix' : resourceTypeFirst(convention) ? 'imageStorageFirst' : 'imageStorageLast', {
    storageAccounts: toLower(convention.resourceTypeCodes.storageAccounts)
    purpose: namingPolicy.imageStoragePurposes[kind]
    location: abbreviation
    prefix: prefix
    unique: take(unique, namingPolicy.limits.uniqueSuffix)
  })

@export()
@description('Names Image Management artifacts/log accounts using the common scope hash and storage formatting. The prefix must first pass validateImageStoragePrefix.')
func imageStorageName(convention object, kind string, abbreviation string, context namingContext, prefix string) string =>
  validateTypeName(imageStorageNameResolved(resolveConvention(convention), kind, abbreviation, scopeUnique(validateNamingContext(context, 'storageAccounts')), prefix), namingPolicy.resourceTypes.storageAccounts)

@export()
@description('Applies the shared short uniqueness length to the existing two-scope identity recipe used by Replacer and route-table automation.')
func scopeIdUnique(firstScope string, secondScope string) string =>
  take(uniqueString(firstScope, secondScope), namingPolicy.limits.uniqueSuffix)

@export()
@description('Preserves the full build-run identity seeded by subscription, deployment name and timestamp.')
func imageBuildRunId(subscriptionId string, deploymentName string, timestamp string) string =>
  uniqueString(subscriptionId, deploymentName, timestamp)

@description('Resolves the existing VNETID private-endpoint token: retain names shorter than 37 characters, otherwise use their stable hash. Preserves deployed endpoint names.')
func privateEndpointVnetToken(vnetName string) string =>
  length(vnetName) < 37 ? vnetName : uniqueString(vnetName)

@export()
@description('Resolves existing private-endpoint name/NIC patterns in substitution order, including the shared VNETID token. Explicit patterns are preserved.')
func privateEndpointName(pattern string, resourceName string, subresource string, vnetName string) string =>
  replace(replace(replace(pattern, 'SUBRESOURCE', subresource), 'RESOURCE', resourceName), 'VNETID', privateEndpointVnetToken(vnetName))

@description('Preserves FSLogix domain-compatible storage-prefix normalization and length budgeting, or uses the central default pattern.')
func fslogixProfileStoragePrefix(prefix string, unique string) string =>
  !empty(prefix) ? take(toLower(replace(prefix, '-', '')), namingPolicy.limits.fslogixProfileStoragePrefix)
    : namePattern('fslogixProfileStoragePrefix', { unique: unique })

func fslogixOfficeStoragePrefix(prefix string, unique string) string =>
  !empty(prefix) ? take(toLower(replace(prefix, '-', '')), namingPolicy.limits.fslogixProfileStoragePrefix)
    : namePattern('fslogixOfficeStoragePrefix', { unique: unique })

// FSLogix bundle, shared with host pools.
@export()
@description('Explicit subscription, cloud and deployment location for legacy FSLogix naming. Existing resource-group overrides are applied after naming and do not change its uniqueness seed.')
type fslogixNamingContext = {
  subscriptionId: string
  cloud: string
  location: string
}

@export()
@description('Storage, private-endpoint and temporary deployment-resource names shared by standalone FSLogix and host pools, including raw and effective location abbreviations.')
type fslogixNamingResult = {
  delimiter: string
  resourceGroupDeployment: string
  depVirtualMachineName: string
  depVirtualMachineDiskName: string
  depVirtualMachineNicName: string
  resourceGroupStorage: string
  netAppAccountName: string
  netAppCapacityPoolName: string
  fslogixProfileStorageAccountNamePrefix: string
  fslogixOfficeStorageAccountNamePrefix: string
  encryptionKeyNameFSLogixProfile: string
  encryptionKeyNameFSLogixOffice: string
  privateEndpointNameConv: string
  privateEndpointNICNameConv: string
  userAssignedIdentityNameConv: string
  vmsLocAbbr: string
  vmLocationAbbreviation: string
}

func fslogixNamesWithPrefix(convention object, identifier string, context fslogixNamingContext, abbreviation string, storageGroupName string, prefix string, officePrefix string, helperVmName string) fslogixNamingResult => {
  delimiter: resolveConvention(convention).delimiter
  resourceGroupDeployment: resourceName(convention, 'deploymentResourceGroup', abbreviation, identifier, '')
  depVirtualMachineName: helperVmName
  depVirtualMachineDiskName: namePattern('deploymentDisk', { vm: helperVmName, osdisks: resolveConvention(convention).resourceTypeCodes.osdisks })
  depVirtualMachineNicName: namePattern('deploymentNic', { vm: helperVmName, networkInterfaces: resolveConvention(convention).resourceTypeCodes.networkInterfaces })
  resourceGroupStorage: storageGroupName
  netAppAccountName: resourceName(convention, 'netAppAccount', abbreviation, identifier, '')
  netAppCapacityPoolName: resourceName(convention, 'netAppCapacityPool', abbreviation, identifier, '')
  fslogixProfileStorageAccountNamePrefix: prefix
  fslogixOfficeStorageAccountNamePrefix: officePrefix
  encryptionKeyNameFSLogixProfile: namePattern('fslogixKey', { identifier: identifier, storagePrefix: prefix })
  encryptionKeyNameFSLogixOffice: namePattern('fslogixKey', { identifier: identifier, storagePrefix: officePrefix })
  privateEndpointNameConv: privateEndpointPattern(resourceTypeFirst(convention), resolveConvention(convention).resourceTypeCodes.privateEndpoints)
  privateEndpointNICNameConv: privateEndpointNicPattern(resourceTypeFirst(convention), resolveConvention(convention).resourceTypeCodes.privateEndpoints, resolveConvention(convention).resourceTypeCodes.networkInterfaces)
  userAssignedIdentityNameConv: resourceName(convention, 'identityPattern', abbreviation, identifier, '')
  vmsLocAbbr: regionAbbreviation(context.location, context.cloud)
  vmLocationAbbreviation: abbreviation
}

func fslogixNamesWithSeed(convention object, identifier string, context fslogixNamingContext, abbreviation string, storageGroupName string, unique string) fslogixNamingResult =>
  fslogixNamesWithPrefix(convention, identifier, context, abbreviation, storageGroupName, fslogixProfileStoragePrefix(convention.?fslogixProfileStoragePrefix ?? '', unique), fslogixOfficeStoragePrefix(convention.?fslogixOfficeStoragePrefix ?? '', unique), deploymentVmName(convention, abbreviation, identifier))

func fslogixNamesForLocation(convention object, identifier string, context fslogixNamingContext, abbreviation string, storageGroupName string) fslogixNamingResult =>
  fslogixNamesWithSeed(convention, identifier, context, abbreviation, storageGroupName, take(scopeUnique(union(context, { resourceGroupName: storageGroupName })), namingPolicy.limits.uniqueSuffix))

func fslogixNamesForAbbreviation(convention object, identifier string, context fslogixNamingContext, abbreviation string) fslogixNamingResult =>
  fslogixNamesForLocation(convention, identifier, context, abbreviation, resourceName(convention, 'storageResourceGroup', abbreviation, identifier, ''))

@export()
@description('Returns paired Profile/Office storage names without a naming deployment or host-pool dependency. Explicit caller overrides remain outside this bundle.')
func fslogixNames(convention object, identifier string, context fslogixNamingContext) fslogixNamingResult =>
  fslogixNamesForAbbreviation(convention, identifier, context, !empty(convention.?vmsLocationAbbreviation ?? '') ? convention.vmsLocationAbbreviation : regionAbbreviation(context.location, context.cloud))

// Shared resources use their owning scope, never a consuming host-pool identifier.
@export()
@description('Internal Shared Services override contract. Empty values retain generated defaults or convention-level vault overrides.')
type sharedServicesNameOverrides = {
  consolidatedResourceGroupName: string?
  secretsKeyVaultName: string?
  encryptionKeyVaultName: string?
  controlPlaneResourceGroupName: string?
  workspaceName: string?
  globalFeedResourceGroupName: string?
  globalFeedWorkspaceName: string?
}

@export()
@description('Internal Shared Services bundle result.')
type sharedServicesNamingResult = {
  operationsResourceGroupName: string
  monitoringResourceGroupName: string
  controlPlaneResourceGroupName: string
  avdWorkspaceName: string
  globalFeedResourceGroupName: string
  globalFeedWorkspaceName: string
  secretsKeyVaultName: string
  encryptionKeyVaultName: string
  fslogixBackupVaultName: string
  logAnalyticsWorkspaceName: string
  dataCollectionEndpointName: string
  privateEndpointNameConv: string
  privateEndpointNICNameConv: string
}

func sharedServicesNamesForScope(convention object, context fslogixNamingContext, overrides sharedServicesNameOverrides, abbreviation string, operationsGroup string) sharedServicesNamingResult => {
  operationsResourceGroupName: operationsGroup
  monitoringResourceGroupName: !empty(overrides.?consolidatedResourceGroupName ?? '') ? overrides.consolidatedResourceGroupName! : resourceName(convention, 'monitoringResourceGroup', abbreviation, '', '')
  controlPlaneResourceGroupName: !empty(overrides.?consolidatedResourceGroupName ?? '') ? overrides.consolidatedResourceGroupName! : !empty(overrides.?controlPlaneResourceGroupName ?? '') ? overrides.controlPlaneResourceGroupName! : resourceName(convention, 'controlPlaneResourceGroup', abbreviation, '', '')
  avdWorkspaceName: !empty(overrides.?workspaceName ?? '') ? overrides.workspaceName! : resourceName(convention, 'workspace', abbreviation, '', '')
  globalFeedResourceGroupName: !empty(overrides.?globalFeedResourceGroupName ?? '') ? overrides.globalFeedResourceGroupName! : resourceName(convention, 'globalFeedResourceGroup', '', '', '')
  globalFeedWorkspaceName: !empty(overrides.?globalFeedWorkspaceName ?? '') ? overrides.globalFeedWorkspaceName! : resourceName(convention, 'globalFeedWorkspace', '', '', '')
  secretsKeyVaultName: !empty(overrides.?secretsKeyVaultName ?? '') ? overrides.secretsKeyVaultName! : sharedVaultName(convention, 'secretsKeyVault', abbreviation, union(context, { resourceGroupName: operationsGroup }))
  encryptionKeyVaultName: !empty(overrides.?encryptionKeyVaultName ?? '') ? overrides.encryptionKeyVaultName! : sharedVaultName(convention, 'encryptionKeyVault', abbreviation, union(context, { resourceGroupName: operationsGroup }))
  fslogixBackupVaultName: resourceName(convention, 'filesBackupVault', abbreviation, '', '')
  logAnalyticsWorkspaceName: resourceName(convention, 'logAnalyticsWorkspace', abbreviation, '', '')
  dataCollectionEndpointName: resourceName(convention, 'dataCollectionEndpoint', abbreviation, '', '')
  privateEndpointNameConv: privateEndpointPattern(resourceTypeFirst(convention), resolveConvention(convention).resourceTypeCodes.privateEndpoints)
  privateEndpointNICNameConv: privateEndpointNicPattern(resourceTypeFirst(convention), resolveConvention(convention).resourceTypeCodes.privateEndpoints, resolveConvention(convention).resourceTypeCodes.networkInterfaces)
}

func sharedServicesNamesForAbbreviation(convention object, context fslogixNamingContext, overrides sharedServicesNameOverrides, abbreviation string) sharedServicesNamingResult =>
  sharedServicesNamesForScope(convention, context, overrides, abbreviation, !empty(overrides.?consolidatedResourceGroupName ?? '') ? overrides.consolidatedResourceGroupName! : resourceName(convention, 'operationsResourceGroup', abbreviation, '', ''))

@export()
@description('Internal Shared Services bundle implementation; public callers use naming.bicep.')
func sharedServicesNames(convention object, context fslogixNamingContext, overrides sharedServicesNameOverrides) sharedServicesNamingResult =>
  sharedServicesNamesForAbbreviation(convention, context, overrides, !empty(convention.?locationAbbreviation ?? '') ? convention.locationAbbreviation : regionAbbreviation(context.location, context.cloud))

@export()
@description('Internal Image Management bundle result.')
type imageManagementNamingResult = {
  resourceGroupName: string
  imageBuildResourceGroupName: string
  galleryName: string
  identityName: string
  storageEncryptionIdentityName: string
  artifactsStorageAccountName: string
  logsStorageAccountName: string
  storageEncryptionKeyName: string
  galleryDiskEncryptionSetName: string
  galleryDiskEncryptionKeyName: string
  galleryConfidentialVmDiskEncryptionSetName: string
  galleryConfidentialVmDiskEncryptionKeyName: string
  privateEndpointNameConv: string
  privateEndpointNICNameConv: string
}

func imageManagementNamesForScope(convention object, context fslogixNamingContext, galleryKeyManagement string, abbreviation string, identifier string, groupName string, prefix string) imageManagementNamingResult => {
  resourceGroupName: groupName
  imageBuildResourceGroupName: resourceName(convention, 'imageBuildResourceGroup', abbreviation, identifier, '')
  galleryName: resourceName(convention, 'imageGallery', abbreviation, identifier, '')
  identityName: resourceName(convention, 'imageBlobIdentity', abbreviation, identifier, '')
  storageEncryptionIdentityName: resourceName(convention, 'imageStorageEncryptionIdentity', abbreviation, identifier, '')
  artifactsStorageAccountName: imageStorageName(convention, 'artifacts', abbreviation, union(context, { resourceGroupName: groupName }), prefix)
  logsStorageAccountName: imageStorageName(convention, 'logs', abbreviation, union(context, { resourceGroupName: groupName }), prefix)
  storageEncryptionKeyName: namePattern('imageStorageKey', { identifier: identifier })
  galleryDiskEncryptionSetName: resourceName(convention, contains(galleryKeyManagement, 'Platform') ? 'imageGalleryDoubleEncryptionKeys' : 'imageGalleryCustomerKeys', abbreviation, identifier, '')
  galleryDiskEncryptionKeyName: namePattern('imageGalleryKey', { identifier: identifier })
  galleryConfidentialVmDiskEncryptionSetName: resourceName(convention, 'imageGalleryConfidentialKeys', abbreviation, identifier, '')
  galleryConfidentialVmDiskEncryptionKeyName: namePattern('imageGalleryConfidentialKey', { identifier: identifier })
  privateEndpointNameConv: privateEndpointPattern(resourceTypeFirst(convention), resolveConvention(convention).resourceTypeCodes.privateEndpoints)
  privateEndpointNICNameConv: privateEndpointNicPattern(resourceTypeFirst(convention), resolveConvention(convention).resourceTypeCodes.privateEndpoints, resolveConvention(convention).resourceTypeCodes.networkInterfaces)
}

func imageManagementNamesForLocation(convention object, context fslogixNamingContext, galleryKeyManagement string, abbreviation string, identifier string) imageManagementNamingResult =>
  imageManagementNamesForScope(convention, context, galleryKeyManagement, abbreviation, identifier, resourceName(convention, 'imageManagementResourceGroup', abbreviation, identifier, ''), validateImageStoragePrefix(string(convention.?imageManagementStoragePrefix ?? ''), abbreviation))

@export()
@description('Internal Image Management bundle implementation; public callers use naming.bicep.')
func imageManagementNames(convention object, context fslogixNamingContext, galleryKeyManagement string) imageManagementNamingResult =>
  imageManagementNamesForLocation(convention, context, galleryKeyManagement, !empty(convention.?locationAbbreviation ?? '') ? convention.locationAbbreviation : regionAbbreviation(context.location, context.cloud), namingPolicy.identifiers.imageManagement)

// Host-pool bundle: FSLogix names plus compute and control-plane names.
@export()
@description('Parameter-only VM, control-plane, feed and subscription context for host-pool naming. Empty globalFeedLocation disables the feed group; an existing workspace must belong to sharedServicesSubscriptionId.')
type hostPoolNamingContext = {
  subscriptionId: string
  cloud: string
  virtualMachinesLocation: string
  controlPlaneLocation: string
  globalFeedLocation: string
  existingFeedWorkspaceResourceId: string
  sharedServicesSubscriptionId: string
}

@export()
@description('Host-pool naming contract containing consumed names and the shared FSLogix bundle. Retained names and uniqueness seeds are preserved for identical context and convention inputs.')
type hostPoolNamingResult = {
  delimiter: string
  resourceGroupDeployment: string
  depVirtualMachineName: string
  depVirtualMachineDiskName: string
  depVirtualMachineNicName: string
  resourceGroupStorage: string
  netAppAccountName: string
  netAppCapacityPoolName: string
  fslogixProfileStorageAccountNamePrefix: string
  fslogixOfficeStorageAccountNamePrefix: string
  encryptionKeyNameFSLogixProfile: string
  encryptionKeyNameFSLogixOffice: string
  privateEndpointNameConv: string
  privateEndpointNICNameConv: string
  userAssignedIdentityNameConv: string
  vmsLocAbbr: string
  vmLocationAbbreviation: string
  resourceGroupOperations: string
  resourceGroupConsolidated: string
  sharedResourceGroupOperations: string
  sharedResourceGroupMonitoring: string
  sharedResourceGroupControlPlane: string
  sharedKeyVaultNameSecrets: string
  sharedKeyVaultNameEncryption: string
  sharedRecoveryServicesVaultNameFSLogix: string
  sharedDataCollectionEndpointName: string
  sharedLogAnalyticsWorkspaceName: string
  globalFeedResourceGroupName: string
  globalFeedWorkspaceName: string
  resourceGroupControlPlane: string
  workspaceName: string
  sharedWorkspaceName: string
  desktopApplicationGroupName: string
  hostPoolName: string
  scalingPlanName: string
  recoveryServicesVaultNameVMs: string
  policyRemediationIdentityName: string
  resourceGroupHosts: string
  availabilitySetNameConv: string
  virtualMachineNameConv: string
  virtualMachineDiskNameConv: string
  virtualMachineNicNameConv: string
  diskAccessName: string
  diskEncryptionSetNameConfidentialVMs: string
  diskEncryptionSetNameCustomerManaged: string
  diskEncryptionSetNamePlatformAndCustomerManaged: string
  encryptionKeyNameVMs: string
  encryptionKeyNameConfidentialVMs: string
  encryptionKeyNameRecoveryServices: string
}

func hostPoolControlPlaneGroup(convention object, identifier string, context hostPoolNamingContext, abbreviation string) string =>
  empty(context.existingFeedWorkspaceResourceId)
    ? resourceName(convention, 'controlPlaneResourceGroup', abbreviation, identifier, '')
    : toLower(split(context.existingFeedWorkspaceResourceId, '/')[2]) == toLower(context.sharedServicesSubscriptionId)
      ? split(context.existingFeedWorkspaceResourceId, '/')[4]
      : fail('The existing feed workspace subscription must match the target control-plane subscription.')

func sharedVaultName(convention object, role string, abbreviation string, context namingContext) string =>
  !empty(role == 'secretsKeyVault' ? convention.?secretsKeyVaultNameOverride ?? '' : convention.?encryptionKeyVaultNameOverride ?? '')
    ? (role == 'secretsKeyVault' ? convention.secretsKeyVaultNameOverride : convention.encryptionKeyVaultNameOverride)
    : resourceNameForType(union(convention, { locationAbbreviation: abbreviation }), 'Microsoft.KeyVault/vaults', first(namingPolicy.resources[role].purpose), context)

func hostPoolNamesWithScopes(convention object, identifier string, context hostPoolNamingContext, storage fslogixNamingResult, abbreviation string, operationsGroup string, diskEncryptionPattern string) hostPoolNamingResult =>
  union(storage, {
    resourceGroupOperations: operationsGroup
    resourceGroupConsolidated: resourceName(convention, 'consolidatedResourceGroup', storage.vmLocationAbbreviation, identifier, '')
    sharedResourceGroupOperations: operationsGroup
    sharedResourceGroupMonitoring: resourceName(convention, 'monitoringResourceGroup', storage.vmLocationAbbreviation, identifier, '')
    sharedResourceGroupControlPlane: hostPoolControlPlaneGroup(convention, identifier, context, abbreviation)
    sharedKeyVaultNameSecrets: sharedVaultName(convention, 'secretsKeyVault', storage.vmLocationAbbreviation, { subscriptionId: context.sharedServicesSubscriptionId, resourceGroupName: operationsGroup, location: context.virtualMachinesLocation, cloud: context.cloud })
    sharedKeyVaultNameEncryption: sharedVaultName(convention, 'encryptionKeyVault', storage.vmLocationAbbreviation, { subscriptionId: context.sharedServicesSubscriptionId, resourceGroupName: operationsGroup, location: context.virtualMachinesLocation, cloud: context.cloud })
    sharedRecoveryServicesVaultNameFSLogix: resourceName(convention, 'filesBackupVault', storage.vmLocationAbbreviation, identifier, '')
    sharedDataCollectionEndpointName: resourceName(convention, 'dataCollectionEndpoint', storage.vmLocationAbbreviation, identifier, '')
    sharedLogAnalyticsWorkspaceName: resourceName(convention, 'logAnalyticsWorkspace', storage.vmLocationAbbreviation, identifier, '')
    globalFeedResourceGroupName: !empty(context.globalFeedLocation) ? resourceName(convention, 'globalFeedResourceGroup', '', identifier, '') : ''
    globalFeedWorkspaceName: resourceName(convention, 'globalFeedWorkspace', '', identifier, '')
    resourceGroupControlPlane: hostPoolControlPlaneGroup(convention, identifier, context, abbreviation)
    workspaceName: empty(context.existingFeedWorkspaceResourceId) ? resourceName(convention, 'hostWorkspace', abbreviation, identifier, '') : last(split(context.existingFeedWorkspaceResourceId, '/'))
    sharedWorkspaceName: resourceName(convention, 'workspace', abbreviation, identifier, '')
    desktopApplicationGroupName: resourceName(convention, 'desktopApplicationGroup', abbreviation, identifier, '')
    hostPoolName: resourceName(convention, 'hostPool', abbreviation, identifier, '')
    scalingPlanName: resourceName(convention, 'scalingPlan', abbreviation, identifier, '')
    recoveryServicesVaultNameVMs: resourceName(convention, 'vmBackupVault', storage.vmLocationAbbreviation, identifier, '')
    policyRemediationIdentityName: replace(storage.userAssignedIdentityNameConv, 'TOKEN', namePattern('policyIdentityPurpose', { delimiter: storage.delimiter }))
    resourceGroupHosts: resourceName(convention, 'hostsResourceGroup', storage.vmLocationAbbreviation, identifier, '')
    availabilitySetNameConv: namePattern('availabilitySet', { name: resourceName(convention, 'availabilitySet', storage.vmLocationAbbreviation, identifier, ''), delimiter: storage.delimiter })
    virtualMachineNameConv: !empty(convention.?virtualMachineNameConvOverride ?? '') ? convention.virtualMachineNameConvOverride : namingPolicy.patterns.virtualMachine
    virtualMachineDiskNameConv: !empty(convention.?virtualMachineDiskNameConvOverride ?? '') ? convention.virtualMachineDiskNameConvOverride : namingPolicy.patterns.osDisk
    virtualMachineNicNameConv: !empty(convention.?virtualMachineNicNameConvOverride ?? '') ? convention.virtualMachineNicNameConvOverride : namingPolicy.patterns.nic
    diskAccessName: resourceName(convention, 'diskAccess', storage.vmLocationAbbreviation, identifier, '')
    diskEncryptionSetNameConfidentialVMs: replace(diskEncryptionPattern, 'TOKEN', namePattern('confidentialDiskPurpose', { delimiter: storage.delimiter }))
    diskEncryptionSetNameCustomerManaged: replace(diskEncryptionPattern, 'TOKEN', namePattern('customerDiskPurpose', { delimiter: storage.delimiter }))
    diskEncryptionSetNamePlatformAndCustomerManaged: replace(diskEncryptionPattern, 'TOKEN', namePattern('doubleEncryptionDiskPurpose', { delimiter: storage.delimiter }))
    encryptionKeyNameVMs: namePattern('vmKey', { identifier: identifier })
    encryptionKeyNameConfidentialVMs: namePattern('confidentialVmKey', { identifier: identifier })
    encryptionKeyNameRecoveryServices: namePattern('recoveryServicesKey', { identifier: identifier })
  })

func hostPoolNamesForLocation(convention object, identifier string, context hostPoolNamingContext, storage fslogixNamingResult, abbreviation string) hostPoolNamingResult =>
  hostPoolNamesWithScopes(convention, identifier, context, storage, abbreviation,
    resourceName(convention, 'operationsResourceGroup', storage.vmLocationAbbreviation, identifier, ''),
    resourceName(convention, 'diskEncryptionSetPattern', storage.vmLocationAbbreviation, identifier, ''))

@export()
@description('Composes host-pool names with storage, monitoring, Key Vault and backup names in the VM region and AVD control-plane names in the control-plane region.')
func hostPoolNames(convention object, identifier string, context hostPoolNamingContext) hostPoolNamingResult =>
  hostPoolNamesForLocation(convention, identifier, context, fslogixNames(convention, identifier, {
    subscriptionId: context.subscriptionId
    cloud: context.cloud
    location: context.virtualMachinesLocation
  }), !empty(convention.?cpLocationAbbreviation ?? '') ? convention.cpLocationAbbreviation : regionAbbreviation(context.controlPlaneLocation, context.cloud))
