// AVD Alerts Add-On - Service Health Alert Rules Module
// Deploys Azure Service Health activity log alert rules scoped to the current subscription.
//
// Alert rules:
//   - Service Issue (active incident affecting Azure services)  (Sev 0)
//   - Planned Maintenance                                       (Sev 2)
//   - Health Advisory (informational / action required)        (Sev 3)
//   - Security Advisory                                        (Sev 0)

// ========== //
// Parameters //
// ========== //

@description('Required. Resource ID of the Action Group for notifications.')
param actionGroupResourceId string

@description('Optional. Prefix prepended to all alert names.')
param alertNamePrefix string = 'AVD'

@description('Optional. When false, Azure Service Health activity log alert rules are not deployed.')
param enableServiceHealthAlerts bool = true

// ========== //
// Variables  //
// ========== //

var subscriptionResourceId = subscription().id
var descriptionHeader      = 'FederalAVD - Automated Alert\n'

// Parse the action group resource ID so we can reference it as an existing resource
var agParts          = split(actionGroupResourceId, '/')
var agSubscriptionId = agParts[2]
var agRgName         = agParts[4]
var agName           = last(agParts)

// ========== //
// Resources  //
// ========== //

// Read the caller-provided action group so we can copy its receivers into a global-location
// clone. Service Health activity log alerts require the action group to be at 'global'.
resource sourceActionGroup 'Microsoft.Insights/actionGroups@2022-06-01' existing = {
  name: agName
  scope: resourceGroup(agSubscriptionId, agRgName)
}

// Global-location action group used exclusively by Service Health alerts
resource globalActionGroup 'Microsoft.Insights/actionGroups@2022-06-01' = if (enableServiceHealthAlerts) {
  name: '${alertNamePrefix}-SvcHealth-AG'
  location: 'global'
  properties: {
    groupShortName:              take('${alertNamePrefix}-SH', 12)
    enabled:                     true
    emailReceivers:              sourceActionGroup.properties.emailReceivers
    smsReceivers:                sourceActionGroup.properties.smsReceivers
    webhookReceivers:            sourceActionGroup.properties.webhookReceivers
    armRoleReceivers:            sourceActionGroup.properties.armRoleReceivers
    azureAppPushReceivers:       sourceActionGroup.properties.azureAppPushReceivers
    logicAppReceivers:           sourceActionGroup.properties.logicAppReceivers
    automationRunbookReceivers:  sourceActionGroup.properties.automationRunbookReceivers
    azureFunctionReceivers:      sourceActionGroup.properties.azureFunctionReceivers
    itsmReceivers:               sourceActionGroup.properties.itsmReceivers
    voiceReceivers:              sourceActionGroup.properties.voiceReceivers
    eventHubReceivers:           sourceActionGroup.properties.eventHubReceivers
  }
}

var alertActions = {
  actionGroups: [
    {
      actionGroupId: enableServiceHealthAlerts ? globalActionGroup.id : ''
    }
  ]
}


// Service Issue (active incident)
resource alertServiceIssue 'Microsoft.Insights/activityLogAlerts@2020-10-01' = if (enableServiceHealthAlerts) {
  name: '${alertNamePrefix}-SvcHealth-ServiceIssue'
  location: 'global'
  properties: {
    description: '${descriptionHeader}An active Azure service incident has been detected that may be affecting AVD components in this subscription.'
    enabled: true
    scopes: [subscriptionResourceId]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'ServiceHealth'
        }
        {
          anyOf: [
            {
              field: 'properties.incidentType'
              equals: 'Incident'
            }
          ]
        }
      ]
    }
    actions: alertActions
  }
}

// Planned Maintenance
resource alertPlannedMaintenance 'Microsoft.Insights/activityLogAlerts@2020-10-01' = if (enableServiceHealthAlerts) {
  name: '${alertNamePrefix}-SvcHealth-PlannedMaintenance'
  location: 'global'
  properties: {
    description: '${descriptionHeader}Planned Azure maintenance has been scheduled that may affect AVD components in this subscription.'
    enabled: true
    scopes: [subscriptionResourceId]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'ServiceHealth'
        }
        {
          anyOf: [
            {
              field: 'properties.incidentType'
              equals: 'Maintenance'
            }
          ]
        }
      ]
    }
    actions: alertActions
  }
}

// Health Advisory (informational or action required)
resource alertHealthAdvisory 'Microsoft.Insights/activityLogAlerts@2020-10-01' = if (enableServiceHealthAlerts) {
  name: '${alertNamePrefix}-SvcHealth-HealthAdvisory'
  location: 'global'
  properties: {
    description: '${descriptionHeader}An Azure Health Advisory has been issued for services in this subscription. Review to determine if action is required for your AVD environment.'
    enabled: true
    scopes: [subscriptionResourceId]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'ServiceHealth'
        }
        {
          anyOf: [
            {
              field: 'properties.incidentType'
              equals: 'Informational'
            }
            {
              field: 'properties.incidentType'
              equals: 'ActionRequired'
            }
          ]
        }
      ]
    }
    actions: alertActions
  }
}

// Security Advisory
resource alertSecurity 'Microsoft.Insights/activityLogAlerts@2020-10-01' = if (enableServiceHealthAlerts) {
  name: '${alertNamePrefix}-SvcHealth-Security'
  location: 'global'
  properties: {
    description: '${descriptionHeader}An Azure Security Advisory has been issued for services in this subscription. Review immediately for potential security impact on your AVD environment.'
    enabled: true
    scopes: [subscriptionResourceId]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'ServiceHealth'
        }
        {
          anyOf: [
            {
              field: 'properties.incidentType'
              equals: 'Security'
            }
          ]
        }
      ]
    }
    actions: alertActions
  }
}
