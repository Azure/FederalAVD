metadata name = 'Timer-triggered Function definition'
metadata description = 'Deploys a timer-triggered function and its code files into an existing Function App in the deployment resource group. Does not create or configure the app, hosting plan, identity, or storage.'

@description('Required. Function-level file-name/content mapping, including the entry-point script. This is not an app-level host.json deployment; the caller is responsible for code and dependencies.')
param files object
@description('Required. Name of the existing Function App in the deployment resource group. Its runtime, identity, storage, and permissions must already be configured by the caller.')
param functionAppName string
@description('Required. Child function name to create or update within the app.')
param functionName string
@description('Required. Timer schedule in Functions NCRONTAB format, including seconds, or a supported schedule setting reference. The app owns the time-zone configuration.')
param schedule string
/*
var functionJson = '''
{
  "bindings": [
    {
      "type": "timerTrigger",
      "direction": "in",
      "name": "Timer",
      "schedule": "<schedule>"
    }
  ]
}
'''

var filesWithFunctionJson = union(files, {
  'function.json': replace(functionJson, '<schedule>', schedule)
})
*/
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
        {
          type: 'timerTrigger'
          direction: 'in'
          name: 'Timer'
          schedule: schedule
        }
      ]
    }
    files: files
  }
}
