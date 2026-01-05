@maxLength(24)
@description('Required. Name of the Storage Account.')
param name string

param description string = ''

param displayName string = ''

param location string = resourceGroup().location

param version object = {}
param tags object
param mainTemplate object = {}
param uiFormDefinition object = {}

resource templateSpec 'Microsoft.Resources/templateSpecs@2022-02-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    description: description
    displayName: displayName
  }
}

module templateSpecVersion 'versions/main.bicep' = {
  name: '${name}-${versionName}-${uniqueString(deployment().name, location)}'
  params: {
    location: location
    templateSpecName: name
    name: versionName
    description: description
    linkedTemplates: []
    mainTemplate: mainTemplate
    metadata: {}
    uiFormDefinition: uiFormDefinition
    tags: tags
  }
}

output resourceId string = templateSpec.id
output templateSpecVersionResourceId string = templateSpecVersion.outputs.resourceId
