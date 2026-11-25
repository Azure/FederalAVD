// Deploy separately into an approved monitoring resource group. Reuses an existing Action Group.
// This alerts on the first ingested failure, even when cleanup/retry makes the invocation succeed.
targetScope = 'resourceGroup'

@description('Required. Exact SHR Function App name as reported in cloud_RoleName.')
@minLength(2)
@maxLength(60)
param functionAppName string

@description('Required. Resource ID of the SHR workspace-based Application Insights component.')
param applicationInsightsResourceId string

@description('Required. Existing approved Action Group resource ID for operator notifications.')
param actionGroupResourceId string

@description('Optional. Alert rule location. Use a region supporting log search alerts in the target cloud.')
param location string = resourceGroup().location

@description('Optional. Enable the rule after verifying telemetry and Action Group routing.')
param enabled bool = true

@description('Optional. Resource tags.')
param tags object = {}

var query = '''
traces
| where timestamp > ago(2h)
| where cloud_RoleName == base64_decode_tostring('${base64(functionAppName)}')
| where message contains "SHR_EVENT |"
| extend Data = parse_json(extract(@"SHR_EVENT \| (\{.*\})$", 1, message))
| where toint(Data.SchemaVersion) == 1 and tostring(Data.Event) == "DeploymentFailed"
| extend FunctionApp = cloud_RoleName, FailureCategory = tostring(Data.FailureCategory),
         CycleId = tostring(Data.CycleId), FailureId = tostring(Data.FailureId),
         FailureCode = tostring(Data.FailureCode), FailureResourceId = tostring(Data.FailureResourceId),
         DeploymentName = tostring(Data.FailureDeploymentName)
| where isnotempty(FailureId)
| summarize arg_max(timestamp, *) by FunctionApp, FailureCategory
| project FunctionApp, FailureCategory, LastDetectedUtc = timestamp, CycleId, FailureId,
          FailureCode, FailureResourceId, DeploymentName
'''

resource failureAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: 'shr-${functionAppName}-deployment-failed'
  location: location
  tags: tags
  properties: {
    displayName: 'SHR - Session-host deployment failed'
    description: 'First observed deployment/initialization failure. For DomainJoinCredentials, correct the account/secret and use checked recovery with -AcknowledgeCredentialFix. Event expiry is not proof of recovery.'
    enabled: enabled
    severity: 1
    scopes: [
      applicationInsightsResourceId
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT2H'
    overrideQueryTimeRange: 'PT2H'
    criteria: {
      allOf: [
        {
          query: query
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
          dimensions: [
            {
              name: 'FunctionApp'
              operator: 'Include'
              values: ['*']
            }
            {
              name: 'FailureCategory'
              operator: 'Include'
              values: ['*']
            }
          ]
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroupResourceId
      ]
      customProperties: {
        Runbook: 'SHR Operator Quick Guide - deployment and credential failures'
      }
    }
    autoMitigate: true
  }
}

output alertRuleResourceId string = failureAlert.id
