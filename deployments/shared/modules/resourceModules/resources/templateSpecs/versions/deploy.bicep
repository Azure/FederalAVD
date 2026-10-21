metadata name = 'Template Spec version'
metadata description = 'Publishes caller-supplied ARM template content and an optional portal form as a version of an existing Template Spec in the deployment resource group.'

@description('Required. Name of the existing parent Template Spec in the deployment resource group.')
param templateSpecName string

@description('Version name (e.g. "1.0.0").')
param name string = '1.0.0'

@description('Optional. Azure region for the template Spec version; defaults to the deployment resource group region.')
param location string = resourceGroup().location
@description('Optional. Tags applied to the template Spec version.')
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

@description('Resource ID of the template Spec version.')
output resourceId string = templateSpecVersion.id
@description('Azure resource name of the template Spec version.')
output name string = templateSpecVersion.name
