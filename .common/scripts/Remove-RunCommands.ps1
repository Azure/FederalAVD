Param(    
    [string]$ResourceManagerUri,
    [string]$SubscriptionId,
    [string]$UserAssignedIdentityClientId,
    [string]$VirtualMachineNames,
    [string]$VirtualMachinesResourceGroup
)

$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'

[array]$VirtualMachineNames = $VirtualMachineNames.replace('\"', '"') | ConvertFrom-Json

# Fix the resource manager URI since only AzureCloud contains a trailing slash
$ResourceManagerUriFixed = if($ResourceManagerUri[-1] -eq '/'){$ResourceManagerUri.Substring(0,$ResourceManagerUri.Length - 1)} else {$ResourceManagerUri}

# Get an access token — use UAI client_id when provided, otherwise fall back to system-assigned identity
$TokenUri = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=' + $ResourceManagerUriFixed
if (-not [string]::IsNullOrEmpty($UserAssignedIdentityClientId)) { $TokenUri += '&client_id=' + $UserAssignedIdentityClientId }
$AzureManagementAccessToken = (Invoke-RestMethod -Headers @{Metadata="true"} -Uri $TokenUri).access_token

# Set header for Azure Management API
$AzureManagementHeader = @{
    'Content-Type'='application/json'
    'Authorization'='Bearer ' + $AzureManagementAccessToken
}

$ResourceGroupId = '/subscriptions/' + $SubscriptionId + '/resourceGroups/' + $VirtualMachinesResourceGroup

ForEach ($VMName in $VirtualMachineNames) {
    $RunCommands = (Invoke-RestMethod `
                        -Headers $AzureManagementHeader `
                        -Method 'GET' `
                        -Uri $($ResourceManagerUriFixed + $ResourceGroupId + '/providers/Microsoft.Compute/virtualMachines/' + $VMName + '/runCommands?api-version=2024-03-01')).value.name
    ForEach ($RunCommand in $RunCommands) {
        Invoke-RestMethod `
            -Headers $AzureManagementHeader `
            -Method 'DELETE' `
            -Uri $($ResourceManagerUriFixed + $ResourceGroupId + '/providers/Microsoft.Compute/virtualMachines/' + $VmName + '/runCommands/' + $RunCommand + '?api-version=2024-03-01') | Out-Null
    }
}