metadata name = 'FederalAVD centralized naming'
metadata description = 'Authoritative FederalAVD naming policy implementation. Resource roles, defaults, patterns and limits come from namingPolicy.json; callers supply deployment context and apply explicit existing-resource overrides.'

@export()
@description('Authoritative naming defaults, resource roles, patterns and length limits. Edit the shared data file rather than copying rules into consumers.')
var namingPolicy object = loadJsonContent('../../../data/namingPolicy.json')

@export()
@description('Default OS disk pattern from the authoritative policy. Import this scalar when no other naming rules are needed.')
var osDiskNamePattern string = loadJsonContent('../../../data/namingPolicy.json', '$.patterns.osDisk')

var resourceAbbreviations object = loadJsonContent('../../../data/resourceAbbreviations.json')
var locationDefinitions object = loadJsonContent('../../../data/locations.json')

func resolveComponent(comp string, rtCode string, component string, loc string, ff1 string, env string, ff2 string, workload string) string =>
  comp == 'resourceType' ? rtCode
    : comp == 'purpose' ? component
    : comp == 'location' ? loc
    : comp == 'freeform1' ? ff1
    : comp == 'environment' ? env
    : comp == 'freeform2' ? ff2
    : comp == 'workload' ? workload
    : ''

@export()
@description('Joins the selected component values in order, omitting empty values and unknown component names. Does not sanitize, truncate, or add uniqueness.')
func buildCustomName(components array, delimiter string, rtCode string, component string, loc string, ff1 string, env string, ff2 string, workload string) string =>
  join(
    filter(
      map(components, comp => resolveComponent(comp, rtCode, component, loc, ff1, env, ff2, workload)),
      s => !empty(s)
    ),
    delimiter
  )

@export()
@description('Builds a convention-based name after excluding none components. Uses the same argument order as buildCustomName.')
func cnv(components array, delimiter string, rtCode string, component string, loc string, ff1 string, env string, ff2 string, workload string) string =>
  buildCustomName(filter(components, s => s != 'none'), delimiter, rtCode, component, loc, ff1, env, ff2, workload)

@export()
@description('Removes hyphens, underscores, and dots. Callers separately enforce case, length, uniqueness, and the remaining resource naming rules.')
func stripSeps(s string) string =>
  replace(replace(replace(s, '-', ''), '_', ''), '.', '')

@export()
@description('Replaces underscores and dots with hyphens for Key Vault naming. Does not truncate or validate the complete name.')
func kvSanitize(s string) string =>
  replace(replace(s, '_', '-'), '.', '-')

@export()
@description('Resolves shared defaults and merges partial abbreviation overrides. Explicit empty delimiters are preserved; an empty workload retains the existing default-workload behavior.')
func resolveConvention(convention object) object => union(namingPolicy.defaults, convention, {
  components: convention.?components ?? namingPolicy.defaults.components
  delimiter: convention.?delimiter ?? namingPolicy.defaults.delimiter
  workload: !empty(convention.?workload ?? '') ? convention.workload : namingPolicy.defaults.workload
  freeform1: convention.?freeform1 ?? ''
  environment: convention.?environment ?? ''
  freeform2: convention.?freeform2 ?? ''
  resourceTypeCodes: union(resourceAbbreviations, convention.?resourceTypeCodes ?? {})
})

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
    storageIdentifier: replace(identifier, '-', '')
    unique: unique
  })), part => !(rule.?omitEmptyPurposeParts ?? false) || !empty(part)), delimiter)

func formatName(name string, rule object, delimiter string) string =>
  rule.type == 'keyVaults' ? take(kvSanitize(name), namingPolicy.limits.keyVault)
    : rule.type == 'computeGalleries' ? replace(name, '-', '_')
    : rule.type == 'functionApps' ? take(name, namingPolicy.limits.functionApp)
    : (rule.?format ?? '') == 'storage' ? take(toLower(empty(delimiter) ? name : replace(name, delimiter, '')), namingPolicy.limits.storageAccount)
    : name

func resolvedResourceName(convention object, rule object, region string, identifier string, unique string) string =>
  formatName(cnv(
    (rule.?omitWorkload ?? false) ? filter(convention.components, component => component != 'workload') : convention.components,
    convention.delimiter,
    empty(rule.type) ? '' : convention.resourceTypeCodes[rule.type],
    resourcePurpose(rule, convention.delimiter, identifier, unique),
    region,
    convention.freeform1,
    convention.environment,
    convention.freeform2,
    convention.workload
  ), rule, convention.delimiter)

@export()
@description('Generates a resource name from its authoritative role definition, shared convention and deployment context. Applies the resource-specific gallery, Key Vault, Function App or Replacer-storage formatting rule.')
func resourceName(convention object, role string, region string, identifier string, unique string) string =>
  resolvedResourceName(resolveConvention(convention), namingPolicy.resources[role], region, identifier, unique)

@export()
@description('Actual target scope for identifier-based resource naming. Use the owning subscription/resource group, full Azure location and environment name; resourceGroups accepts an empty resourceGroupName and seeds at subscription scope.')
type namingContext = {
  subscriptionId: string
  resourceGroupName: string
  location: string
  cloud: string
}

@export()
@description('Generated Function App infrastructure names and shared private-endpoint patterns. Names are not resource IDs and do not create or adopt resources.')
type functionAppNamingResult = {
  functionAppName: string
  storageAccountName: string
  applicationInsightsName: string
  appServicePlanName: string
  storageEncryptionIdentityName: string
  privateEndpointNameConv: string
  privateEndpointNICNameConv: string
}

func isNamingToken(value string) bool =>
  !empty(value) && contains('abcdefghijklmnopqrstuvwxyz0123456789', toLower(first(value))) && contains('abcdefghijklmnopqrstuvwxyz0123456789', toLower(last(value))) && empty(filter(map(range(0, length(value)), i => toLower(substring(value, i, 1))), character => !contains('abcdefghijklmnopqrstuvwxyz0123456789-_.', character)))

func requireNamingToken(value string, label string) string =>
  isNamingToken(value) ? value : fail('${label} must contain only ASCII letters, numbers, hyphens, underscores or dots, and start and end with a letter or number.')

func validateNamingContext(context namingContext, resourceType string) namingContext =>
  !empty(filter([context.subscriptionId, context.location, context.cloud], value => empty(trim(value)) || value != trim(value))) || context.resourceGroupName != trim(context.resourceGroupName) || (empty(context.resourceGroupName) && toLower(resourceType) != 'resourcegroups')
    ? fail('Naming context requires subscriptionId, location and cloud without surrounding whitespace, plus resourceGroupName for resources below subscription scope.')
    : union(context, { cloud: canonicalNamingCloud(context.cloud) })

func validateTypeConvention(convention object) object =>
  length(filter(convention.components, component => component == 'purpose')) != 1
    ? fail('Identifier-based naming requires exactly one purpose component so the identifier and uniqueness hash cannot be omitted.')
    : !empty(filter(convention.components, component => !contains(['resourceType', 'purpose', 'location', 'workload', 'environment', 'freeform1', 'freeform2', 'none'], component)))
      ? fail('Identifier-based naming contains an unsupported naming-convention component.')
      : length(convention.delimiter) > 3 || !empty(filter(map(range(0, length(convention.delimiter)), i => substring(convention.delimiter, i, 1)), character => !contains('-_.', character)))
        ? fail('Identifier-based naming delimiter must be empty or contain at most three hyphens, underscores or dots.')
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
    : regionAbbreviation(toLower(context.location), context.cloud), 'Location abbreviation')

func formatTypeName(value string, rule object) string =>
  toLower(rule.format == 'storage' ? stripSeps(value)
    : rule.format == 'gallery' ? replace(value, '-', '_')
    : rule.format == 'hyphen' ? kvSanitize(value)
    : fail('Unsupported resource-type naming format.'))

func validateTypeName(name string, rule object) string =>
  (rule.?startWithLetter ?? false) && !contains('abcdefghijklmnopqrstuvwxyz', first(name))
    ? fail('This resource type requires a name starting with a letter. Change the first selected component.')
    : (rule.?noConsecutiveHyphens ?? false) && contains(name, '--')
      ? fail('This resource type does not allow consecutive hyphens. Change the identifier, delimiter or selected values.')
      : name

func composeTypeName(convention object, rule object, code string, region string, identifier string, unique string) string =>
  formatTypeName(cnv(
    convention.components,
    convention.delimiter,
    code,
    '${identifier}${convention.delimiter}${unique}',
    region,
    convention.freeform1,
    convention.environment,
    convention.freeform2,
    convention.workload
  ), rule)

func budgetedTypeName(convention object, rule object, code string, region string, identifier string, unique string, budget int) string =>
  budget < 1
    ? fail('Naming-convention values leave no room for an identifier and the full uniqueness hash. Shorten static values or remove optional components.')
    : validateTypeName(composeTypeName(convention, rule, code, region, take(identifier, budget), unique), rule)

func resolvedTypeName(convention object, rule object, code string, region string, identifier string, unique string) string =>
  budgetedTypeName(
    convention, rule, code, region, formatTypeName(identifier, rule), unique,
    namingPolicy.limits[rule.lengthLimit] - length(composeTypeName(convention, rule, code, region, '', unique))
  )

func scopedTypeName(convention object, resourceType string, identifier string, context namingContext) string =>
  !contains(namingPolicy.resourceTypes, resourceType)
    ? fail('Unsupported identifier-based resource type. Use a resource type registered in namingPolicy.resourceTypes.')
    : resolvedTypeName(
      convention,
      namingPolicy.resourceTypes[resourceType],
      requireNamingToken(convention.resourceTypeCodes[resourceType], 'Resource type abbreviation'),
      typeLocationAbbreviation(convention, context),
      requireNamingToken(identifier, 'Add-on identifier'),
      take(uniqueString(toLower(context.subscriptionId), toLower(resourceType) == 'resourcegroups' ? '' : toLower(context.resourceGroupName), toLower(context.location), toLower(context.cloud), toLower(identifier), toLower(resourceType)), namingPolicy.resourceTypes[resourceType].?uniqueLength ?? 13)
    )

@export()
@description('Names a supported resource type from caller-supplied purpose/identifier and actual target context, with an automatic type-specific stable suffix. Only the readable identifier is shortened; selected static components and the configured suffix are preserved. Legacy role names are unchanged.')
func resourceNameForType(convention object, resourceType string, identifier string, context namingContext) string =>
  scopedTypeName(validateTypeConvention(resolveConvention(convention)), resourceType, identifier, validateNamingContext(context, resourceType))

@export()
@description('Returns Function App, runtime storage, Insights, dedicated plan, storage CMK identity and private-endpoint patterns from one add-on identifier and target context. Does not deploy resources or replace caller-owned explicit overrides.')
func functionAppNames(convention object, identifier string, context namingContext) functionAppNamingResult => {
  functionAppName: resourceNameForType(convention, 'functionApps', identifier, context)
  storageAccountName: resourceNameForType(convention, 'storageAccounts', identifier, context)
  applicationInsightsName: resourceNameForType(convention, 'applicationInsights', identifier, context)
  appServicePlanName: resourceNameForType(convention, 'appServicePlans', identifier, context)
  storageEncryptionIdentityName: resourceNameForType(convention, 'userAssignedIdentities', '${identifier}-storage-cmk', context)
  privateEndpointNameConv: privateEndpointPattern(resourceTypeFirst(convention), requireNamingToken(resolveConvention(convention).resourceTypeCodes.privateEndpoints, 'Private endpoint abbreviation'))
  privateEndpointNICNameConv: privateEndpointNicPattern(resourceTypeFirst(convention), requireNamingToken(resolveConvention(convention).resourceTypeCodes.privateEndpoints, 'Private endpoint abbreviation'), requireNamingToken(resolveConvention(convention).resourceTypeCodes.networkInterfaces, 'Network interface abbreviation'))
}

func temporaryVmName(raw string) string =>
  take('${raw}${uniqueString(raw)}', namingPolicy.limits.deploymentVm)

@export()
@description('Names the temporary deployment VM using the existing separator-removal, uniqueness and Windows computer-name length rule.')
func deploymentVmName(convention object, region string, identifier string) string =>
  temporaryVmName(stripSeps(resourceName(convention, 'deploymentVm', region, identifier, '')))

@export()
@description('Computes the shared subscription/resource-group uniqueness seed, adding the region when location is omitted from the selected naming components. Returns the full hash so resource-specific length budgets can be applied separately.')
func scopedUnique(convention object, subscriptionId string, resourceGroupName string, region string) string =>
  !contains(resolveConvention(convention).components, 'location')
    ? uniqueString(subscriptionId, resourceGroupName, region)
    : uniqueString(subscriptionId, resourceGroupName)

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

@export()
@description('Validates the Image Management storage prefix and its location budget before constructing either account name.')
func validateImageStoragePrefix(prefix string, region string) string =>
  !empty(prefix) && (length(prefix) > namingPolicy.limits.imageManagementStoragePrefix || prefix != toLower(prefix) || !empty(filter(map(range(0, length(prefix)), i => substring(prefix, i, 1)), character => !contains('abcdefghijklmnopqrstuvwxyz0123456789', character))))
    ? fail('namingConvention.imageManagementStoragePrefix must contain no more than ${namingPolicy.limits.imageManagementStoragePrefix} lowercase letters or numbers.')
    : !empty(prefix) && length(region) > namingPolicy.limits.imageManagementStorageLocation
      ? fail('The location abbreviation must contain no more than ${namingPolicy.limits.imageManagementStorageLocation} characters when namingConvention.imageManagementStoragePrefix is specified.')
      : prefix

func imageStorageNameResolved(convention object, kind string, abbreviation string, standardUnique string, customUnique string, prefix string) string =>
  namePattern(!empty(prefix) ? 'imageStorageCustomPrefix' : resourceTypeFirst(convention) ? 'imageStorageFirst' : 'imageStorageLast', {
    storageAccounts: toLower(convention.resourceTypeCodes.storageAccounts)
    purpose: namingPolicy.imageStoragePurposes[kind]
    location: abbreviation
    prefix: prefix
    unique: !empty(prefix)
      ? take(customUnique, namingPolicy.limits.uniqueSuffix)
      : take(standardUnique, max(namingPolicy.limits.storageAccount - length(convention.resourceTypeCodes.storageAccounts) - length(namingPolicy.imageStoragePurposes.artifacts) - length(abbreviation), 1))
  })

@export()
@description('Names Image Management artifacts/log accounts with their shared length budget and existing uniqueness recipes. The prefix must first pass validateImageStoragePrefix.')
func imageStorageName(convention object, kind string, abbreviation string, subscriptionId string, resourceGroupName string, region string, prefix string) string =>
  imageStorageNameResolved(resolveConvention(convention), kind, abbreviation, scopedUnique(convention, subscriptionId, resourceGroupName, region), uniqueString(subscriptionId, resourceGroupName, region), prefix)

@export()
@description('Adapts the legacy resource-type-at-end switch to the shared default convention without adding a deployment or changing its public parameter.')
func legacyConvention(resourceTypeAtEnd bool) object => union(namingPolicy.defaults, {
  components: resourceTypeAtEnd
    ? concat(filter(namingPolicy.defaults.components, component => component != 'resourceType'), ['resourceType'])
    : namingPolicy.defaults.components
})

@export()
@description('Applies the shared short uniqueness length to the existing two-scope identity recipe used by Replacer and route-table automation.')
func scopeIdUnique(firstScope string, secondScope string) string =>
  take(uniqueString(firstScope, secondScope), namingPolicy.limits.uniqueSuffix)

@export()
@description('Preserves the full build-run identity seeded by subscription, deployment name and timestamp.')
func imageBuildRunId(subscriptionId string, deploymentName string, timestamp string) string =>
  uniqueString(subscriptionId, deploymentName, timestamp)

@export()
@description('Resolves the existing VNETID private-endpoint token: retain names shorter than 37 characters, otherwise use their stable hash. Preserves deployed endpoint names.')
func privateEndpointVnetToken(vnetName string) string =>
  length(vnetName) < 37 ? vnetName : uniqueString(vnetName)

@export()
@description('Resolves existing private-endpoint name/NIC patterns in substitution order, including the shared VNETID token. Explicit patterns are preserved.')
func privateEndpointName(pattern string, resourceName string, subresource string, vnetName string) string =>
  replace(replace(replace(pattern, 'SUBRESOURCE', subresource), 'RESOURCE', resourceName), 'VNETID', privateEndpointVnetToken(vnetName))

@export()
@description('Applies the existing six-character scope uniqueness suffix without requiring adapters to own the policy limit.')
func shortScopedUnique(convention object, subscriptionId string, resourceGroupName string, region string) string =>
  take(scopedUnique(convention, subscriptionId, resourceGroupName, region), namingPolicy.limits.uniqueSuffix)

@export()
@description('Preserves FSLogix domain-compatible storage-prefix normalization and length budgeting, or uses the central default pattern.')
func fslogixStoragePrefix(prefix string, unique string) string =>
  !empty(prefix) ? take(toLower(replace(prefix, '-', '')), namingPolicy.limits.fslogixStoragePrefix)
    : namePattern('fslogixStoragePrefix', { unique: unique })
