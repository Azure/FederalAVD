param name string
param location string = resourceGroup().location
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

output resourceId string = scheduledQueryRule.id
output name string = scheduledQueryRule.name
