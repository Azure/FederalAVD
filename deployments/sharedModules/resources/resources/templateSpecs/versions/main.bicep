param location string
param templateSpecName string
param name string
param description string = ''
param linkedTemplates array = []
param mainTemplate object
param metadata object = {}
param uiFormDefinition object = {}
param tags object

resource templateSpec 'Microsoft.Resources/templateSpecs@2022-02-01' existing = {
  name: templateSpecName
}

resource version 'Microsoft.Resources/templateSpecs/versions@2022-02-01' = {
  parent: templateSpec
  location: location
  name: name
  properties: {
    description: description
    linkedTemplates: linkedTemplates
    mainTemplate: mainTemplate
    metadata: metadata
    uiFormDefinition: uiFormDefinition
  }
  tags: tags
}

output resourceId string = version.id
