param location string
param templateSpecName string
param templateSpecVersion string
param tags object

resource sessionHostTemplateSpec 'Microsoft.Resources/templateSpecs@2022-02-01' = {
  name: templateSpecName
  location: location
  tags: tags
  properties: {
    description: 'Template Spec for AVD Session Host deployment used by Session Host Replacer'
    displayName: 'AVD Session Host Template'
  }
}

resource sessionHostTemplateSpecVersion 'Microsoft.Resources/templateSpecs/versions@2022-02-01' = {
  parent: sessionHostTemplateSpec
  name: templateSpecVersion
  location: location
  tags: tags
  properties: {
    mainTemplate: loadJsonContent('sessionHosts.json')
  }
}

output templateSpecResourceId string = sessionHostTemplateSpec.id
output templateSpecVersionResourceId string = sessionHostTemplateSpecVersion.id
