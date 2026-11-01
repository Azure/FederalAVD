metadata name = 'Triggered Function definition'
metadata description = 'Deploys a timer- or queue-triggered function and code into an existing Function App. App, hosting plan, identity, storage, and binding extensions remain caller-owned.'

@description('Required. Function-level file-name/content mapping, including the entry-point script. This is not an app-level host.json deployment; the caller is responsible for code and dependencies.')
param files object
@description('Required. Name of the existing Function App in the deployment resource group. Its runtime, identity, storage, and permissions must already be configured by the caller.')
param functionAppName string
@description('Required. Child function name to create or update within the app.')
param functionName string
@description('Optional. Trigger type. Timer callers retain the Timer binding; queue callers receive WorkItem and must configure a supported storage queue extension.')
@allowed([
  'timerTrigger'
  'queueTrigger'
])
param triggerType string = 'timerTrigger'

@description('Required for timerTrigger. Timer schedule in Functions NCRONTAB format, including seconds, or a supported schedule setting reference. The app owns the time-zone configuration.')
param schedule string = ''

@description('Required for queueTrigger. Existing or runtime-created Azure Storage queue name.')
param queueName string = ''

@description('Optional. Queue binding connection setting prefix. Identity-based connections require endpoint, credential, and optional client ID settings on the app.')
param connection string = 'AzureWebJobsStorage'

var triggerBinding = triggerType == 'timerTrigger' ? {
  type: 'timerTrigger'
  direction: 'in'
  name: 'Timer'
  schedule: !empty(trim(schedule)) ? schedule : fail('A timerTrigger requires a nonempty schedule.')
} : {
  type: 'queueTrigger'
  direction: 'in'
  name: 'WorkItem'
  queueName: !empty(trim(queueName)) ? queueName : fail('A queueTrigger requires a nonempty queueName.')
  connection: connection
}
resource functionApp 'Microsoft.Web/sites@2024-11-01' existing = {
  name: functionAppName
}

resource function 'Microsoft.Web/sites/functions@2024-11-01' = {
  parent: functionApp
  name: functionName
  properties: {
    config: {
      disabled: false
      bindings: [
        triggerBinding
      ]
    }
    files: files
  }
}
