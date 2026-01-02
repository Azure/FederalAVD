# Get your managed identity
$functionAppName = "fa-test-13-shr-u6dsn7-use2"
$resourceGroup = "rg-avd-management-use2"
$functionApp = Get-AzFunctionApp -ResourceGroupName $resourceGroup -Name $functionAppName

# For user-assigned identity, get it from the identity resource IDs
$userAssignedIdentities = $functionApp.IdentityUserAssignedIdentity
if ($userAssignedIdentities) {
    # Get the first user-assigned identity
    $identityResourceId = ($userAssignedIdentities.Keys | Select-Object -First 1)
    Write-Host "User-assigned identity resource ID: $identityResourceId"
    
    # Get the user-assigned identity details
    $identity = Get-AzUserAssignedIdentity -ResourceGroupName $resourceGroup -Name ($identityResourceId -split '/')[-1]
    $identityId = $identity.PrincipalId
} else {
    # Fallback to system-assigned identity
    $identityId = $functionApp.IdentityPrincipalId
}

Write-Host "Managed Identity Principal ID: $identityId"

# Check what permissions it has
Connect-MgGraph -Scopes "Application.Read.All"
$sp = Get-MgServicePrincipal -ServicePrincipalId $identityId
Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $identityId | 
    Select-Object AppRoleId, ResourceDisplayName, @{N='Permission';E={
        $roleId = $_.AppRoleId
        (Get-MgServicePrincipal -ServicePrincipalId $_.ResourceId).AppRoles | 
            Where-Object Id -eq $roleId | Select-Object -ExpandProperty Value
    }}