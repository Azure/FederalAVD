metadata name = 'Template Spec and version'
metadata description = 'Creates or updates a Template Spec and one version in the deployment resource group, optionally attaching a Portal form. The caller supplies the compiled ARM template and any form definition.'

@sys.description('Required. Name of the Template Spec to create or update in the deployment resource group.')
param name string
@sys.description('Optional. Azure region for both the Template Spec and its version; defaults to the deployment resource group location.')
param location string = resourceGroup().location
@sys.description('Optional. Flat tag name/value object applied to the Template Spec and version, not an object keyed by resource type.')
param tags object = {}

@sys.description('Optional. Friendly display name for the template spec.')
param displayName string = ''

@sys.description('Optional. Description of the template spec.')
param description string = ''

@sys.description('Version number for the initial version.')
param version string = '1.0.0'

@sys.description('The ARM template content as an object.')
param mainTemplate object

@sys.description('Optional. The UI form definition object to attach to the template spec version. When provided, enables the guided portal deployment experience.')
param uiFormDefinition object = {}

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
    uiFormDefinition: !empty(uiFormDefinition) ? uiFormDefinition : null
  }
}

@sys.description('Resource ID of the parent Template Spec, without the version segment.')
output resourceId string = templateSpec.id
@sys.description('Name of the parent Template Spec.')
output name string = templateSpec.name
@sys.description('Resource ID of the deployed Template Spec version, suitable for version-specific deployment references.')
output versionResourceId string = templateSpecVersion.id
