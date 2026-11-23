metadata name = 'FederalAVD centralized naming'
metadata description = 'Public naming interface. Deployment bundles own role names, location lookup and uniqueness; new resources use identifier-based naming.'

import {
  hostPoolNames as internalHostPoolNames
  fslogixNames as internalFslogixNames
  functionAppNames as internalFunctionAppNames
  resourceNameForType as internalResourceNameForType
  sharedServicesNames as internalSharedServicesNames
  imageManagementNames as internalImageManagementNames
  namingConventionConfig as internalNamingConventionConfig
  hostPoolNamingContext
  hostPoolNamingResult
  fslogixNamingContext
  fslogixNamingResult
  namingContext
  functionAppNameOverrides
  functionAppNamingResult
  sharedServicesNameOverrides
  sharedServicesNamingResult
  imageManagementNamingResult
} from './internal.bicep'

@export()
@description('Optional shared convention properties, including customToken1/customToken2 and their legacy freeform aliases. Partial overrides are supported; unknown properties and wrong value types are rejected.')
type namingConventionConfig = internalNamingConventionConfig

@export()
@description('Names host-pool compute, control-plane and shared FSLogix resources using explicit target locations and subscriptions.')
func hostPoolNames(convention namingConventionConfig, identifier string, context hostPoolNamingContext) hostPoolNamingResult =>
  internalHostPoolNames(convention, identifier, context)

@export()
@description('Names standalone FSLogix resources without a host-pool dependency, using the common owning-scope hash.')
func fslogixNames(convention namingConventionConfig, identifier string, context fslogixNamingContext) fslogixNamingResult =>
  internalFslogixNames(convention, identifier, context)

@export()
@description('Names per-application Function App infrastructure, applying explicit overrides before generated defaults.')
func functionAppNames(convention namingConventionConfig, identifier string, context namingContext, overrides functionAppNameOverrides) functionAppNamingResult =>
  internalFunctionAppNames(convention, identifier, context, overrides)

@export()
@description('Names an official Azure resource type without an API version. Ambiguous types require context.namingVariant. Retains the complete identifier and fails on overlength names.')
func resourceNameForType(convention namingConventionConfig, resourceType string, identifier string, context namingContext) string =>
  internalResourceNameForType(convention, resourceType, identifier, context)

@export()
@description('Names Shared Services resources using the effective owning scope and explicit name overrides. Shared vaults never depend on a host-pool identifier.')
func sharedServicesNames(convention namingConventionConfig, context fslogixNamingContext, overrides sharedServicesNameOverrides) sharedServicesNamingResult =>
  internalSharedServicesNames(convention, context, overrides)

@export()
@description('Names Image Management resources, including both storage accounts and gallery encryption resources, using the common owning-scope hash.')
func imageManagementNames(convention namingConventionConfig, context fslogixNamingContext, galleryKeyManagement string) imageManagementNamingResult =>
  internalImageManagementNames(convention, context, galleryKeyManagement)
