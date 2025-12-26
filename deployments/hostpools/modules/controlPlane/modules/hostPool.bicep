param hostPoolPrivateDnsZoneResourceId string
param hostPoolRDPProperties string
param hostPoolName string
param hostPoolPublicNetworkAccess string
param hostPoolType string
param location string
param logAnalyticsWorkspaceResourceId string
param privateEndpoint bool
param privateEndpointName string
param privateEndpointNICName string
param privateEndpointSubnetResourceId string
param hostPoolMaxSessionLimit int
param startVmOnConnect bool
param enableMonitoring bool
param tags object
param deploymentSuffix string
param time string = utcNow('u')
param hostPoolValidationEnvironment bool
param virtualMachineTemplate object
param hostPoolCustomTags object

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2023-09-05' = {
  name: hostPoolName
  location: location
  tags: union(
    tags[?'Microsoft.DesktopVirtualization/hostPools'] ?? {},
    hostPoolCustomTags
  )
  properties: {
    hostPoolType: split(hostPoolType, ' ')[0]
    maxSessionLimit: hostPoolMaxSessionLimit
    loadBalancerType: contains(hostPoolType, 'Pooled') ? split(hostPoolType, ' ')[1] : 'Persistent'
    validationEnvironment: hostPoolValidationEnvironment
    registrationInfo: {
      expirationTime: dateTimeAdd(time, 'PT2H')
      registrationTokenOperation: 'Update'
    }
    preferredAppGroupType: 'Desktop'
    customRdpProperty: hostPoolRDPProperties
    personalDesktopAssignmentType: contains(hostPoolType, 'Personal') ? split(hostPoolType, ' ')[1] : null
    publicNetworkAccess: hostPoolPublicNetworkAccess
    startVMOnConnect: startVmOnConnect
    vmTemplate: string(virtualMachineTemplate)
  }
}

module hostPool_PrivateEndpoint '../../../../sharedModules/resources/network/private-endpoint/main.bicep' = if (privateEndpoint && !empty(privateEndpointSubnetResourceId)) {
  name: '${hostPoolName}-privateEndpoint-${deploymentSuffix}'
  params: {
    customNetworkInterfaceName: privateEndpointNICName
    groupIds: [
      'connection'
    ]
    location: location
    name: privateEndpointName
    privateDnsZoneGroup: empty(hostPoolPrivateDnsZoneResourceId)
      ? null
      : {
          privateDNSResourceIds: [
            hostPoolPrivateDnsZoneResourceId
          ]
        }
    serviceResourceId: hostPool.id
    subnetResourceId: privateEndpointSubnetResourceId
    tags: union(
      {
        'cm-resource-parent': hostPool.id
      },
      tags[?'Microsoft.Network/privateEndpoints'] ?? {}
    )
  }
}

resource hostPool_Diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (enableMonitoring) {
  name: 'WVDInsights'
  scope: hostPool
  properties: {
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
        retentionPolicy: {
          days: 0
          enabled: false
        }
      }
    ]
    workspaceId: logAnalyticsWorkspaceResourceId
  }
}

output resourceId string = hostPool.id
