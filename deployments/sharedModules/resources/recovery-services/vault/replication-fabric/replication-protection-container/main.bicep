metadata name = 'Recovery Services Vault Replication Fabric Replication Protection Containers'
metadata description = '''This module deploys a Recovery Services Vault Replication Protection Container.

> **Note**: this version of the module only supports the `instanceType: 'A2A'` scenario.'''
metadata owner = 'Azure/module-maintainers'

@description('Conditional. The name of the parent Azure Recovery Service Vault. Required if the template is used in a standalone deployment.')
param recoveryVaultName string

@description('Conditional. The name of the parent Replication Fabric. Required if the template is used in a standalone deployment.')
param replicationFabricName string

@description('Required. The name of the replication container.')
param name string

@description('Optional. Replication containers mappings to create.')
param replicationContainerMappings array = []

resource replicationContainer 'Microsoft.RecoveryServices/vaults/replicationFabrics/replicationProtectionContainers@2022-10-01' = {
  name: '${recoveryVaultName}/${replicationFabricName}/${name}'
  properties: {
    providerSpecificInput: [
      {
        instanceType: 'A2A'
      }
    ]
  }
}

module fabric_container_containerMappings 'replication-protection-container-mapping/main.bicep' = [for (mapping, index) in replicationContainerMappings: {
  name: 'Map-${index}-${deployment().name}'
  params: {
    name: mapping.?name ?? ''
    policyId: mapping.?policyId ?? ''
    policyName: mapping.?policyName ?? ''
    recoveryVaultName: recoveryVaultName
    replicationFabricName: replicationFabricName
    sourceProtectionContainerName: name
    targetProtectionContainerId: mapping.?targetProtectionContainerId ?? ''
    targetContainerFabricName: mapping.?targetContainerFabricName ?? replicationFabricName
    targetContainerName: mapping.?targetContainerName ?? ''
  }
  dependsOn: [
    replicationContainer
  ]
}]

@description('The name of the replication container.')
output name string = replicationContainer.name

@description('The resource ID of the replication container.')
output resourceId string = replicationContainer.id

@description('The name of the resource group the replication container was created in.')
output resourceGroupName string = resourceGroup().name
