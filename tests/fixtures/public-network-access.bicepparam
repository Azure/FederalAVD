using './public-network-access.bicep'

var modes = ['Auto', 'Disabled', 'EnabledWithRestrictions', 'Enabled']

param cases = map(range(0, 32), i => {
  mode: modes[i / 8]
  privateEndpoint: i % 8 >= 4
  ipRules: i % 4 >= 2
  vnetRules: i % 2 == 1
})
