param templateSpecName string

@description('Version name (e.g. "1.0.0").')
param name string = '1.0.0'

param location string = resourceGroup().location
param tags object = {}

@description('The ARM template content as an object.')
param mainTemplate object

@sys.description('Optional. The UI form definition object to attach to the template spec version. When provided, enables the guided portal deployment experience.')
param uiFormDefinition object = {}

resource templateSpec 'Microsoft.Resources/templateSpecs@2022-02-01' existing = {
  name: templateSpecName
}

resource templateSpecVersion 'Microsoft.Resources/templateSpecs/versions@2022-02-01' = {
  parent: templateSpec
  name: name
  location: location
  tags: tags
  properties: {
    mainTemplate: mainTemplate
    uiFormDefinition: !empty(uiFormDefinition) ? uiFormDefinition : null
  }
}

output resourceId string = templateSpecVersion.id
output name string = templateSpecVersion.name
