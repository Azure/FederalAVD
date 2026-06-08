@description('Name of the parent AVD host pool.')
param hostPoolName string

@export()
type HostPoolUpdateConfigurationProperties = {
  deleteOriginalVm: bool?
  logOffDelayMinutes: int
  logOffMessage: string?
  @minValue(1)
  maxVmsRemoved: int
}

@export()
type SessionHostManagementProvisioningProperties = {
  canaryPolicy: ('Auto' | 'Never' | 'Always')?
  @minValue(1)
  instanceCount: int?
  setDrainMode: bool?
}

@export()
type SessionHostManagementProperties = {
  failedSessionHostCleanupPolicy: ('KeepAll' | 'KeepOne' | 'KeepNone')?
  provisioning: SessionHostManagementProvisioningProperties?
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
  properties: properties
}

output resourceId string = sessionHostManagement.id
output name string = sessionHostManagement.name
