param name string
param location string = resourceGroup().location
param tags object = {}

@sys.description('Optional. Friendly display name for the template spec.')
param displayName string = ''

@sys.description('Optional. Description of the template spec.')
param description string = ''

@sys.description('Version number for the initial version.')
param version string = '1.0.0'

@sys.description('The ARM template content as an object.')
param mainTemplate object

resource templateSpec 'Microsoft.Resources/templateSpecs@2022-02-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    displayName: !empty(displayName) ? displayName : null
    description: !empty(description) ? description : null
  }
}

resource templateSpecVersion 'Microsoft.Resources/templateSpecs/versions@2022-02-01' = {
  parent: templateSpec
  name: version
  location: location
  tags: tags
  properties: {
    mainTemplate: mainTemplate
  }
}

output resourceId string = templateSpec.id
output name string = templateSpec.name
output versionResourceId string = templateSpecVersion.id
