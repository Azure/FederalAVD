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

var alertActions = {
  actionGroups: [
    {
      actionGroupId: actionGroupResourceId
    }
  ]
}


// ========== //
// Resources  //
// ========== //

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
