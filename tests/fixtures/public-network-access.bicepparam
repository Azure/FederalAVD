using './public-network-access.bicep'

// Auto exercises only the retained helper; the fixture passes resolved explicit family policies.
// Each explicit policy covers every PE/IP/Storage-subnet combination.
var modes = ['Auto', 'Disabled', 'EnabledWithRestrictions', 'Enabled']

param cases = concat(map(range(0, 32), i => {
  mode: modes[i / 8]
  privateEndpoint: i % 8 >= 4
  ipRules: i % 4 >= 2
  vnetRules: i % 2 == 1
}), [
  { mode: 'Auto', privateEndpoint: false, ipRules: false, vnetRules: true, functionAppVnetRules: false }
  { mode: 'Auto', privateEndpoint: false, ipRules: false, vnetRules: false, functionAppVnetRules: true }
])
