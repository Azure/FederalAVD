metadata name = 'PaaS public network access policy'
metadata description = 'Resolves explicit public-access modes independently of private endpoints, with a compatibility mode for existing callers. Service-specific rules and exceptions remain caller-owned.'

@export()
@description('Public endpoint mode. Auto preserves legacy private-endpoint/firewall inference and is not offered in Portal forms.')
type publicNetworkAccessMode = 'Auto' | 'Disabled' | 'EnabledWithRestrictions' | 'Enabled'

@export()
@description('Explicit service-family public endpoint policy. Independent of private endpoints and allowlists.')
type servicePublicNetworkAccessMode = 'Disabled' | 'EnabledWithRestrictions' | 'Enabled'

@export()
@description('Resolves legacy private/public/service topology unless an explicit public-access mode is supplied.')
func endpointTypePublicNetworkAccess(mode publicNetworkAccessMode, endpointType string, hasRules bool) publicNetworkAccessMode => mode != 'Auto'
  ? mode
  : endpointType == 'private'
    ? 'Disabled'
    : endpointType == 'service' || hasRules
      ? 'EnabledWithRestrictions'
      : 'Enabled'

@export()
@description('Validates subnet resource IDs and deduplicates them case-insensitively. Does not enable service endpoints or change subnets.')
func serviceEndpointSubnetIds(ids string[]) string[] => union(map(ids, id => length(split(trim(id), '/')) == 11 && startsWith(toLower(trim(id)), '/subscriptions/') && toLower(split(trim(id), '/')[?3] ?? '') == 'resourcegroups' && toLower(split(trim(id), '/')[?5] ?? '') == 'providers' && toLower(split(trim(id), '/')[?6] ?? '') == 'microsoft.network' && toLower(split(trim(id), '/')[?7] ?? '') == 'virtualnetworks' && toLower(split(trim(id), '/')[?9] ?? '') == 'subnets' && !empty(split(trim(id), '/')[?2] ?? '') && !empty(split(trim(id), '/')[?4] ?? '') && !empty(split(trim(id), '/')[?8] ?? '') && !empty(split(trim(id), '/')[?10] ?? '')
  ? toLower(trim(id))
  : fail('Service endpoint allowlists require complete Microsoft.Network/virtualNetworks/subnets resource IDs.')
), [])

// Disabled retains firewall rules but does not use their presence to enable the public endpoint.
// Enabled uses Allow even when rules remain configured. This is a network setting, not authorization.
// Trusted-service bypasses and App Service restriction lists must be handled by each service.
@export()
@description('Resolves publicNetworkAccess and firewall defaultAction without modifying configured rules or service exceptions.')
func resolveNetworkAccess(mode publicNetworkAccessMode, privateEndpoint bool, hasRules bool) object => {
  publicNetworkAccess: mode == 'Disabled' || (mode == 'Auto' && privateEndpoint && !hasRules)
    ? 'Disabled'
    : 'Enabled'
  defaultAction: mode == 'Enabled' || (mode == 'Auto' && !privateEndpoint && !hasRules)
    ? 'Allow'
    : 'Deny'
}
