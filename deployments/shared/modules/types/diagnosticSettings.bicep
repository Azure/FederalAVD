// Shared type definitions for diagnostic settings.
// Import in resource modules with:
//   import { diagnosticSettingsType } from '../types/diagnosticSettings.bicep'

@export()
type logCategoryType = {
  @description('Category group name, e.g. "allLogs". Use either categoryGroup or category, not both.')
  categoryGroup: string?
  @description('Individual log category name. Use either categoryGroup or category, not both.')
  category: string?
  enabled: bool
  retentionPolicy: {
    days: int
    enabled: bool
  }?
}

@export()
type diagnosticSettingsType = {
  @description('Optional. Override name for the diagnostic setting resource. If omitted, a deterministic name is generated from the workspace ID.')
  name: string?
  @description('Resource ID of the Log Analytics workspace to send logs to.')
  workspaceId: string?
  @description('Resource ID of the storage account to archive logs to.')
  storageAccountId: string?
  @description('Resource ID of the Event Hub authorization rule.')
  eventHubAuthorizationRuleId: string?
  @description('Name of the Event Hub. If omitted, a hub is created for each log category.')
  eventHubName: string?
  @description('Log categories to stream. Defaults to allLogs when omitted.')
  logCategories: logCategoryType[]?
}
