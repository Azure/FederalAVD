metadata name = 'Central naming bundle regression vectors'
metadata description = 'Evaluates centralized host-pool and FSLogix functions against frozen outputs captured from the former naming deployment.'

import { hostPoolNames, fslogixNames } from '../../deployments/shared/modules/orchestration/naming/naming.bicep'

@description('Optional. Selects an invalid workspace-subscription case for local runtime validation.')
param invalidCase string = ''

var profiles = loadJsonContent('./naming-bundles-legacy.json')
var cases = map(profiles, profile => {
  name: profile.name
  hostPool: hostPoolNames(profile.convention, profile.identifier, union(profile.context, {
    existingFeedWorkspaceResourceId: invalidCase == 'workspace-subscription'
      ? '/subscriptions/other-subscription/resourceGroups/existing/providers/Microsoft.DesktopVirtualization/workspaces/feed'
      : profile.context.existingFeedWorkspaceResourceId
  }))
  fslogix: fslogixNames(profile.convention, profile.identifier, {
    subscriptionId: profile.context.subscriptionId
    cloud: profile.context.cloud
    location: profile.context.virtualMachinesLocation
  })
})

@description('Base64 transport preserves exact strings through the local CLI console renderer.')
output encodedResults string = base64(string(cases))
