param imageDefinitionName string
param location string
param templateSpecName string

// The Template Spec is deployed by the Automation Runbook to create the virtual machine and run the tool
resource templateSpec 'Microsoft.Resources/templateSpecs@2021-05-01' = {
  name: templateSpecName
  location: location
  properties: {
    description: 'Deploys a virtual machine to validate a new image version.'
    displayName: 'Image Validation for ${imageDefinitionName}'
  }
}

resource templateSpecVersion 'Microsoft.Resources/templateSpecs/versions@2021-05-01' = {
  parent: templateSpec
  name: '1.0'
  location: location
  properties: {
    mainTemplate: loadJsonContent('templateSpecVersion.json')
  }
}

output VersionResourceId string = templateSpecVersion.id
