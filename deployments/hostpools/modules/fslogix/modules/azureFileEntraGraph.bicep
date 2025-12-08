targetScope = 'subscription'
extension microsoftGraphV1
extension microsoftGraphBeta


@description('Resource Group containing the User-Assigned Managed Identity')
param miResourceGroupName string
@description('Name of the User-Assigned Managed Identity')
param miName string

// Existing Azure resources
resource miRg 'Microsoft.Resources/resourceGroups@2024-03-01' existing = {
  name: miResourceGroupName
}
resource userMi 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: miName
  scope: resourceGroup(miRg.name)
}

// Graph: resolve the MI service principal (by the MI's clientId)
resource miSp 'Microsoft.Graph/servicePrincipals@v1.0' existing = {
  appId: userMi.properties.clientId
}

// Graph: Microsoft Graph service principal in your tenant
resource graphSp 'Microsoft.Graph/servicePrincipals@v1.0' existing = {
  appId: '00000003-0000-0000-c000-000000000000' // Microsoft Graph
}

// Desired Graph application permissions (app role values)
var graphAppRolesToAssign = [
  'Application.Read.All'
  'Application.ReadUpdate.All'
]

// Assign Graph app roles to the managed identity
resource miGraphRoleAssignments 'Microsoft.Graph/appRoleAssignedTo@v1.0' = [
  for roleValue in graphAppRolesToAssign: {
    appRoleId: (filter(graphSp.appRoles, r => r.value == roleValue)[0]).id
    principalId: miSp.id
    resourceId: graphSp.id
  }
]


