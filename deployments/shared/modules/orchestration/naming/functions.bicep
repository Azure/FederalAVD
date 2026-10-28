metadata name = 'FederalAVD naming compatibility imports'
metadata description = 'Compatibility facade for existing external imports. Repository deployments use naming.bicep; all naming rules and calculations live there.'

import {
  namingPolicy as coreNamingPolicy
  osDiskNamePattern as coreOsDiskNamePattern
  namingContext as coreNamingContext
  functionAppNamingResult as coreFunctionAppNamingResult
  buildCustomName as coreBuildCustomName
  cnv as coreCnv
  stripSeps as coreStripSeps
  kvSanitize as coreKvSanitize
  resolveConvention as coreResolveConvention
  resourceTypeFirst as coreResourceTypeFirst
  regionAbbreviation as coreRegionAbbreviation
  namePattern as coreNamePattern
  resourceName as coreResourceName
  resourceNameForType as coreResourceNameForType
  functionAppNames as coreFunctionAppNames
  deploymentVmName as coreDeploymentVmName
  scopedUnique as coreScopedUnique
  privateEndpointPattern as corePrivateEndpointPattern
  privateEndpointNicPattern as corePrivateEndpointNicPattern
  validateImageStoragePrefix as coreValidateImageStoragePrefix
  imageStorageName as coreImageStorageName
  legacyConvention as coreLegacyConvention
  scopeIdUnique as coreScopeIdUnique
  imageBuildRunId as coreImageBuildRunId
} from './naming.bicep'

@export()
@description('Compatibility alias for the authoritative naming policy.')
var namingPolicy object = coreNamingPolicy

@export()
@description('Compatibility alias for the narrow OS disk pattern export.')
var osDiskNamePattern string = coreOsDiskNamePattern

@export()
@description('Compatibility alias for target naming context.')
type namingContext = coreNamingContext

@export()
@description('Compatibility alias for the Function App naming result.')
type functionAppNamingResult = coreFunctionAppNamingResult

@export()
@description('Compatibility forwarder; import buildCustomName from naming.bicep for new code.')
func buildCustomName(components array, delimiter string, rtCode string, component string, loc string, ff1 string, env string, ff2 string, workload string) string =>
  coreBuildCustomName(components, delimiter, rtCode, component, loc, ff1, env, ff2, workload)

@export()
@description('Compatibility forwarder; import cnv from naming.bicep for new code.')
func cnv(components array, delimiter string, rtCode string, component string, loc string, ff1 string, env string, ff2 string, workload string) string =>
  coreCnv(components, delimiter, rtCode, component, loc, ff1, env, ff2, workload)

@export()
@description('Compatibility forwarder; import stripSeps from naming.bicep for new code.')
func stripSeps(s string) string => coreStripSeps(s)

@export()
@description('Compatibility forwarder; import kvSanitize from naming.bicep for new code.')
func kvSanitize(s string) string => coreKvSanitize(s)

@export()
@description('Compatibility forwarder; import resolveConvention from naming.bicep for new code.')
func resolveConvention(convention object) object => coreResolveConvention(convention)

@export()
@description('Compatibility forwarder; import resourceTypeFirst from naming.bicep for new code.')
func resourceTypeFirst(convention object) bool => coreResourceTypeFirst(convention)

@export()
@description('Compatibility forwarder; import regionAbbreviation from naming.bicep for new code.')
func regionAbbreviation(region string, cloud string) string => coreRegionAbbreviation(region, cloud)

@export()
@description('Compatibility forwarder; import namePattern from naming.bicep for new code.')
func namePattern(pattern string, context object) string => coreNamePattern(pattern, context)

@export()
@description('Compatibility forwarder preserving the deployed role naming contract.')
func resourceName(convention object, role string, region string, identifier string, unique string) string =>
  coreResourceName(convention, role, region, identifier, unique)

@export()
@description('Compatibility forwarder for identifier-based resource naming.')
func resourceNameForType(convention object, resourceType string, identifier string, context namingContext) string =>
  coreResourceNameForType(convention, resourceType, identifier, context)

@export()
@description('Compatibility forwarder for the optional Function App bundle.')
func functionAppNames(convention object, identifier string, context namingContext) functionAppNamingResult =>
  coreFunctionAppNames(convention, identifier, context)

@export()
@description('Compatibility forwarder preserving temporary deployment VM names.')
func deploymentVmName(convention object, region string, identifier string) string =>
  coreDeploymentVmName(convention, region, identifier)

@export()
@description('Compatibility forwarder preserving existing scope uniqueness recipes.')
func scopedUnique(convention object, subscriptionId string, resourceGroupName string, region string) string =>
  coreScopedUnique(convention, subscriptionId, resourceGroupName, region)

@export()
@description('Compatibility forwarder for private endpoint patterns.')
func privateEndpointPattern(first bool, privateEndpointCode string) string =>
  corePrivateEndpointPattern(first, privateEndpointCode)

@export()
@description('Compatibility forwarder for private endpoint NIC patterns.')
func privateEndpointNicPattern(first bool, privateEndpointCode string, networkInterfaceCode string) string =>
  corePrivateEndpointNicPattern(first, privateEndpointCode, networkInterfaceCode)

@export()
@description('Compatibility forwarder for Image Management prefix validation.')
func validateImageStoragePrefix(prefix string, region string) string => coreValidateImageStoragePrefix(prefix, region)

@export()
@description('Compatibility forwarder preserving Image Management storage names.')
func imageStorageName(convention object, kind string, abbreviation string, subscriptionId string, resourceGroupName string, region string, prefix string) string =>
  coreImageStorageName(convention, kind, abbreviation, subscriptionId, resourceGroupName, region, prefix)

@export()
@description('Compatibility forwarder for the legacy resource-type placement switch.')
func legacyConvention(resourceTypeAtEnd bool) object => coreLegacyConvention(resourceTypeAtEnd)

@export()
@description('Compatibility forwarder for short two-scope uniqueness.')
func scopeIdUnique(firstScope string, secondScope string) string => coreScopeIdUnique(firstScope, secondScope)

@export()
@description('Compatibility forwarder for per-run image-build identities.')
func imageBuildRunId(subscriptionId string, deploymentName string, timestamp string) string =>
  coreImageBuildRunId(subscriptionId, deploymentName, timestamp)
