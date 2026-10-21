metadata name = 'Diagnostic settings input types'
metadata description = 'Exports log category and diagnostic destination input shapes for shared modules; consumers choose supported categories and provision diagnostic settings.'

// Shared type definitions for diagnostic settings.
// Import in resource modules with:
//   import { diagnosticSettingsType } from '../types/diagnosticSettings.bicep'

@export()
@description('Diagnostic log selection using an individual category or category group, with enabled state and optional retention settings.')
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
@description('Optional diagnostic setting name, existing destination resource IDs and log category selections interpreted by the consuming module.')
type diagnosticSettingsType = {
  // Consuming modules choose a fallback name when this is omitted; naming may use multiple destinations.
  @description('Optional. Explicit diagnostic setting resource name.')
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
