targetScope = 'subscription'

param diskAccessId string
param location string
param resourceGroupName string

var parameters = !empty(diskAccessId) ? {
  diskAccessId: {
    type: 'String'
    metadata: {
      displayName: 'Disk Access Resource Id'
      description: 'The resource Id of the Disk Access to associate to the managed disks.'
    }
  }
} : {}

var operations = !empty(diskAccessId)
  ? [
      {
        operation: 'addOrReplace'
        field: 'Microsoft.Compute/disks/networkAccessPolicy'
        value: 'AllowPrivate'
      }
      {
        operation: 'addOrReplace'
        field: 'Microsoft.Compute/disks/publicNetworkAccess'
        value: 'Disabled'
      }
      {
        operation: 'addOrReplace'
        field: 'Microsoft.Compute/disks/diskAccessId'
        value: '[parameters(\'diskAccessId\')]'
      }
    ]
  : [
      {
        operation: 'addOrReplace'
        field: 'Microsoft.Compute/disks/networkAccessPolicy'
        value: 'DenyAll'
      }
      {
        operation: 'addOrReplace'
        field: 'Microsoft.Compute/disks/publicNetworkAccess'
        value: 'Disabled'
      }
    ]

var policyName = !empty(diskAccessId) ? 'DisableDisksPublicNetworkAccess' : 'DisableDisksAllNetworkAccess'
var policyDescription = !empty(diskAccessId) ? 'Disable public network access to managed disks' : 'Disable public network access to managed disks, but allow private network access.'
var policyDisplayName = !empty(diskAccessId) ? 'Disable public network access to managed disks' : 'Disable all network access to managed disks'

resource policyDefinition 'Microsoft.Authorization/policyDefinitions@2021-06-01' = {
  name: policyName
  properties: {
    description: policyDescription
    displayName: policyDisplayName
    mode: 'All'
    parameters: parameters
    policyRule: {
      if: {
        field: 'type'
        equals: 'Microsoft.Compute/disks'
      }
      then: {
        effect: 'modify'
        details: {
          roleDefinitionIds: [
            '/providers/Microsoft.Authorization/roleDefinitions/60fc6e62-5479-42d4-8bf4-67625fcc2840'
          ]
          operations: operations
        }
      }
    }
    policyType: 'Custom'
  }
}

module policyAssignment 'diskNetworkAccessPolicyAssignment.bicep' = {
  name: 'DiskNetworkAccess'
  scope: resourceGroup(resourceGroupName)
  params: {
    location: location
    diskAccessId: diskAccessId
    policyDefinitionId: policyDefinition.id
    policyDisplayName: policyDefinition.properties.displayName
    policyName: policyDefinition.properties.displayName
  }
}
