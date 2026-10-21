metadata name = 'FederalAVD naming functions'
metadata description = 'Authoritative FederalAVD naming policy implementation. Resource roles, defaults, patterns and limits come from namingPolicy.json; callers supply deployment context and apply explicit existing-resource overrides.'

@export()
@description('Authoritative naming defaults, resource roles, patterns and length limits. Edit the shared data file rather than copying rules into consumers.')
var namingPolicy object = loadJsonContent('../../../data/namingPolicy.json')

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
