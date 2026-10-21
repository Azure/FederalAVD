import { cnv } from '../../deployments/shared/modules/orchestration/naming/functions.bicep'

var abbreviations = loadJsonContent('../../deployments/shared/data/resourceAbbreviations.json')

func legacyPurpose(rule object, delimiter string, identifier string, unique string) string =>
  rule.purpose == 'sqm{delimiter}{identifier}' && empty(identifier)
    ? 'sqm'
    : replace(replace(replace(replace(rule.purpose, '{delimiter}', delimiter), '{identifier}', identifier), '{unique}', unique), '{storageIdentifier}', replace(identifier, '-', ''))

func legacyRaw(convention object, rule object, region string, identifier string, unique string) string =>
  cnv(
    (rule.?omitWorkload ?? false) ? filter(convention.?components ?? ['resourceType', 'workload', 'purpose', 'location'], component => component != 'workload') : convention.?components ?? ['resourceType', 'workload', 'purpose', 'location'],
    convention.?delimiter ?? '-',
    empty(rule.type) ? '' : union(abbreviations, convention.?resourceTypeCodes ?? {})[rule.type],
    legacyPurpose(rule, convention.?delimiter ?? '-', identifier, unique),
    region,
    convention.?freeform1 ?? '',
    convention.?environment ?? '',
    convention.?freeform2 ?? '',
    !empty(convention.?workload ?? '') ? convention.workload : 'avd'
  )

func legacyFormat(name string, convention object, rule object) string =>
  rule.type == 'keyVaults' ? take(replace(replace(name, '_', '-'), '.', '-'), 24)
    : rule.type == 'computeGalleries' ? replace(name, '-', '_')
    : rule.type == 'functionApps' ? take(name, 60)
    : (rule.?format ?? '') == 'storage' ? take(toLower(empty(convention.?delimiter ?? '-') ? name : replace(name, convention.?delimiter ?? '-', '')), 24)
    : name

@export()
func legacyName(convention object, rule object, region string, identifier string, unique string) string =>
  legacyFormat(legacyRaw(convention, rule, region, identifier, unique), convention, rule)

@export()
func legacyScopedUnique(convention object, subscriptionId string, group string, region string) string =>
  !contains(convention.?components ?? ['resourceType', 'workload', 'purpose', 'location'], 'location') ? uniqueString(subscriptionId, group, region) : uniqueString(subscriptionId, group)

func legacyResourceTypeFirst(convention object) bool =>
  empty(filter(convention.?components ?? ['resourceType', 'workload', 'purpose', 'location'], component => component != 'none')) || last(filter(convention.?components ?? ['resourceType', 'workload', 'purpose', 'location'], component => component != 'none')) != 'resourceType'

@export()
func legacyStorage(convention object, kind string, location string, subscriptionId string, group string, region string, prefix string) string =>
  !empty(prefix)
    ? '${prefix}${legacyStoragePurpose(kind)}${location}${take(uniqueString(subscriptionId, group, region), 6)}'
    : legacyResourceTypeFirst(convention)
      ? '${legacyStorageCode(convention)}${legacyStoragePurpose(kind)}${location}${take(legacyScopedUnique(convention, subscriptionId, group, region), legacyStorageBudget(convention, location))}'
      : '${legacyStoragePurpose(kind)}${location}${take(legacyScopedUnique(convention, subscriptionId, group, region), legacyStorageBudget(convention, location))}${legacyStorageCode(convention)}'

func legacyStorageCode(convention object) string =>
  toLower(union(abbreviations, convention.?resourceTypeCodes ?? {}).storageAccounts)

func legacyStoragePurpose(kind string) string => kind == 'artifacts' ? 'imgassets' : 'imglogs'

func legacyStorageBudget(convention object, location string) int =>
  max(24 - length(union(abbreviations, convention.?resourceTypeCodes ?? {}).storageAccounts) - length('imgassets') - length(location), 1)
