metadata name = 'Function App hosting plan'
metadata description = 'Creates or updates an App Service plan in the deployment resource group. The caller decides whether to invoke this module or use an existing plan; it does not deploy Function Apps or code.'

// Required. Legacy scale-setting selector, not the SKU family. Values containing Consumption omit
// maximumElasticWorkerCount; FunctionsPremium sets it to 20; other values set it to 1. The planPricing
// SKU determines the hosting model.
@description('Required. Legacy elastic-worker limit selector, not the hosting SKU. planPricing selects the tier/SKU; see source comments for selector-specific limits.')
param hostingPlanType string
@description('Required. Azure region for the plan. Must be compatible with the Function Apps that will use it and support the selected SKU and zone configuration.')
param location string
@description('Required. App kind used to select the plan operating system. A value containing linux sets reserved to true; other values create a Windows plan.')
param functionAppKind string
@description('Required. Name of the plan to create or update in the deployment resource group. Reusing a name manages that plan rather than creating an independently owned plan.')
param name string
@description('Required. Tier and SKU joined by an underscore, for example PremiumV3_P0v3. PremiumV3 SKUs provide Dedicated App Service hosting, not Functions Elastic Premium EP SKUs.')
param planPricing string
@description('Required. Tags keyed by resource type. Applies the Microsoft.Web/serverfarms entry when present.')
param tags object
@description('Required. Enables zone redundancy and requests three workers when true; otherwise requests one worker. Verify SKU, region, and scale-unit support before enabling.')
param zoneRedundant bool

var sku = {
  name: split(planPricing, '_')[1]
  tier: split(planPricing, '_')[0]
  capacity: zoneRedundant ? 3 : 1
}

resource hostingPlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: name
  location: location
  sku: sku
  tags: tags[?'Microsoft.Web/serverfarms'] ?? {}
  properties: {
    maximumElasticWorkerCount: contains(hostingPlanType, 'Consumption') ? null : hostingPlanType == 'FunctionsPremium' ? 20 : 1
    reserved: contains(functionAppKind, 'linux') ? true : false
    zoneRedundant: zoneRedundant
  }
}

@description('Resource ID of the managed App Service plan. Pass to functionApp.bicep as serverFarmId; creating the plan alone does not deploy an app.')
output hostingPlanId string = hostingPlan.id
