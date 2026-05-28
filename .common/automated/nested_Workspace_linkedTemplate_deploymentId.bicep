param variables_applicationGroupReferencesArr ? /* TODO: fill in correct type */
param variables_workspacePublicNetworkAccess ? /* TODO: fill in correct type */

@description('AVD api version')
param apiVersion string

@description('The name of the workspace to be attach to new Applicaiton Group.')
param workSpaceName string

@description('The location of the workspace.')
param workspaceLocation string

@description('True if the workspace is new. False if there is no workspace added or adding to an existing workspace.')
param isNewWorkspace bool

resource workSpace 'Microsoft.DesktopVirtualization/workspaces@[parameters(\'apiVersion\')]' = {
  name: workSpaceName
  location: workspaceLocation
  properties: {
    applicationGroupReferences: variables_applicationGroupReferencesArr
    publicNetworkAccess: (isNewWorkspace ? variables_workspacePublicNetworkAccess : null)
  }
}

