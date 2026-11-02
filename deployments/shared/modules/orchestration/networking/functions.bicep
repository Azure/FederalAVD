metadata name = 'PaaS public network access policy'
metadata description = 'Resolves explicit public-access modes independently of private endpoints, with a compatibility mode for existing callers. Service-specific rules and exceptions remain caller-owned.'

@export()
@description('Public endpoint mode. Auto preserves legacy private-endpoint/firewall inference and is not offered in Portal forms.')
type publicNetworkAccessMode = 'Auto' | 'Disabled' | 'EnabledWithRestrictions' | 'Enabled'

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
