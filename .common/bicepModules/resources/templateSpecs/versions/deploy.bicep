param templateSpecName string

@description('Version name (e.g. "1.0.0").')
param name string = '1.0.0'

param location string = resourceGroup().location
param tags object = {}

@description('The ARM template content as an object.')
param mainTemplate object

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
  }
}

output resourceId string = templateSpecVersion.id
output name string = templateSpecVersion.name
