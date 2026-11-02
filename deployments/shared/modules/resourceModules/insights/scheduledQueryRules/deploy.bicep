metadata name = 'Scheduled query alert rule'
metadata description = 'Deploys an Azure Monitor log alert with caller-supplied scopes and query criteria; referenced data sources and optional action groups must already exist.'

@sys.description('Required. Name of the scheduled query alert rule to deploy.')
param name string
@sys.description('Optional. Azure region for the scheduled query alert rule; defaults to the deployment resource group region.')
param location string = resourceGroup().location
@sys.description('Optional. Tags applied to the scheduled query alert rule.')
param tags object = {}

@sys.description('Resource IDs of the resources to evaluate.')
param scopes array

@sys.description('Alert severity (0=Critical, 1=Error, 2=Warning, 3=Informational, 4=Verbose).')
@minValue(0)
@maxValue(4)
param severity int = 2

@sys.description('Whether the alert rule is enabled.')
param enabled bool = true

@sys.description('Optional. Description of the rule.')
param description string = ''

@sys.description('Evaluation frequency (ISO 8601 duration, e.g. PT5M).')
param evaluationFrequency string = 'PT5M'

@sys.description('Time window for evaluation (ISO 8601 duration, e.g. PT15M).')
param windowSize string = 'PT15M'

@sys.description('Alert criteria.')
param criteria object

@sys.description('Action groups to trigger.')
param actions array = []

resource scheduledQueryRule 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: name
  location: location
  tags: tags
  properties: {
    description: !empty(description) ? description : null
    enabled: enabled
    severity: severity
    scopes: scopes
    evaluationFrequency: evaluationFrequency
    windowSize: windowSize
    criteria: criteria
    actions: !empty(actions) ? { actionGroups: actions } : null
  }
}

@sys.description('Resource ID of the scheduled query alert rule.')
output resourceId string = scheduledQueryRule.id
@sys.description('Azure resource name of the scheduled query alert rule.')
output name string = scheduledQueryRule.name
