@description('Name of the parent AVD host pool.')
param hostPoolName string

type HostPoolUpdateConfigurationProperties = {
  deleteOriginalVm: bool?
  logOffDelayMinutes: int
  logOffMessage: string?
  maxVmsRemoved: int
}

type SessionHostManagementProvisioningProperties = {
  canaryPolicy: string?
  instanceCount: int?
  setDrainMode: bool?
}

type SessionHostManagementProperties = {
  failedSessionHostCleanupPolicy: string?
  provisioning: SessionHostManagementProvisioningProperties?
  scheduledDateTime: string?
  scheduledDateTimeZone: string
  update: HostPoolUpdateConfigurationProperties
}

@description('Session host management properties.')
param properties SessionHostManagementProperties

resource hostpool 'Microsoft.DesktopVirtualization/hostPools@2025-11-01-preview' existing = {
  name: hostPoolName
}

resource sessionHostManagement 'Microsoft.DesktopVirtualization/hostPools/sessionHostManagements@2025-11-01-preview' = {
  name: 'default'
  parent: hostpool
  properties: any(properties)
}

output resourceId string = sessionHostManagement.id
output name string = sessionHostManagement.name
