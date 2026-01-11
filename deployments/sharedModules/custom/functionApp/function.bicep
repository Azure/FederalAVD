param files object
param functionAppName string
param functionName string
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
