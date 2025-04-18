@description('Required. Name of the solution. For Microsoft published gallery solution the target solution resource name will be composed as `{name}({logAnalyticsWorkspaceName})`.')
param name string

@description('Required. Name of the Log Analytics workspace where the solution will be deployed/enabled.')
param logAnalyticsWorkspaceName string

@description('Optional. Location for all resources.')
param location string = resourceGroup().location

@description('Optional. The product of the deployed solution. For Microsoft published gallery solution it should be `OMSGallery` and the target solution resource product will be composed as `OMSGallery/{name}`. For third party solution, it can be anything. This is case sensitive.')
param product string = 'OMSGallery'

@description('Optional. The publisher name of the deployed solution. For Microsoft published gallery solution, it is `Microsoft`.')
param publisher string = 'Microsoft'

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2021-06-01' existing = {
  name: logAnalyticsWorkspaceName
}

var solutionName = publisher == 'Microsoft' ? '${name}(${logAnalyticsWorkspace.name})' : name

var solutionProduct = publisher == 'Microsoft' ? 'OMSGallery/${name}' : product

resource solution 'Microsoft.OperationsManagement/solutions@2015-11-01-preview' = {
  name: solutionName
  location: location
  properties: {
    workspaceResourceId: logAnalyticsWorkspace.id
  }
  plan: {
    name: solutionName
    promotionCode: ''
    product: solutionProduct
    publisher: publisher
  }
}

@description('The name of the deployed solution.')
output name string = solution.name

@description('The resource ID of the deployed solution.')
output resourceId string = solution.id

@description('The resource group where the solution is deployed.')
output resourceGroupName string = resourceGroup().name

@description('The location the resource was deployed into.')
output location string = solution.location
