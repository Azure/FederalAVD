targetScope = 'subscription'

import { resolveConvention, resourceTypeFirst, resourceName, privateEndpointPattern, privateEndpointNicPattern } from '../../../shared/modules/orchestration/naming/functions.bicep'

metadata name = 'Session Host Replacer naming'
metadata description = 'Computes Replacer infrastructure names using the shared naming functions and host-pool convention. Deploys no resources; explicit brownfield overrides are applied by the caller.'

// ============================================================================
// Session Host Replacer Naming Module
// Computes infrastructure resource names for a Session Host Replacer deployment.
// No resources are deployed - this module is purely for name resolution.
// ============================================================================

// Naming convention controlling how infrastructure resources are named.
// Should match the convention used when deploying the host pool. Pre-populated from the
// hpNamingComponents, hpNamingDelimiter, and hpNamingWorkload tags on the hosts resource group.
@description('Optional. Infrastructure naming convention matching the host pool. The Portal derives it from naming tags on the hosts resource group.')
// naming-policy: defaults
param namingConvention object = {
  components: ['resourceType', 'workload', 'purpose', 'location']
  delimiter: '-'
  workload: 'avd'
}

@description('The host pool base name / identifier (e.g. desktop-01). Pre-populated from the hpIdentifier tag on the hosts resource group.')
param identifier string

@description('The pre-computed region abbreviation for the function app deployment location.')
param locationAbbreviation string

@description('A 6-character unique string scoped to the virtual machines subscription and resource group.')
param uniqueString string

var cnv_rtCodes = resolveConvention(namingConvention).resourceTypeCodes
var loc            = !empty(namingConvention.?vmsLocationAbbreviation ?? '') ? namingConvention.vmsLocationAbbreviation : locationAbbreviation

var rtFirst = resourceTypeFirst(namingConvention)
var functionAppName = resourceName(namingConvention, 'replacerFunctionApp', loc, identifier, uniqueString)

@description('Function App name, limited to 60 characters. The caller can replace it with a brownfield override.')
output functionAppName string = functionAppName
@description('Lowercase storage account name without the convention delimiter, limited to 24 characters.')
output storageAccountName string = resourceName(namingConvention, 'replacerStorage', loc, identifier, uniqueString)
@description('Name of the dedicated storage CMK identity; creating the identity and key is the caller responsibility.')
output storageEncryptionIdentityName string = resourceName(namingConvention, 'replacerStorageIdentity', loc, identifier, '')
@description('Plan name without a host-pool-specific purpose, allowing shared naming within the chosen scope. The caller selects new or existing plan ownership.')
output appServicePlanName string = resourceName(namingConvention, 'replacerHostingPlan', loc, identifier, '')
@description('Host-pool-scoped Application Insights name. The caller adjusts it when overriding the Function App name.')
output appInsightsName string = resourceName(namingConvention, 'replacerInsights', loc, identifier, uniqueString)
@description('Name for the session-host deployment Template Spec; the caller can use an existing Template Spec instead.')
output templateSpecName string = resourceName(namingConvention, 'sessionHostsTemplateSpec', loc, identifier, '')
@description('Private endpoint pattern containing RESOURCE, SUBRESOURCE, and VNETID placeholders for the consuming module.')
output privateEndpointNameConv string = privateEndpointPattern(rtFirst, cnv_rtCodes.privateEndpoints)
@description('Private endpoint NIC pattern containing RESOURCE, SUBRESOURCE, and VNETID placeholders.')
output privateEndpointNICNameConv string = privateEndpointNicPattern(rtFirst, cnv_rtCodes.privateEndpoints, cnv_rtCodes.networkInterfaces)
