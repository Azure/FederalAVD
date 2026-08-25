Param(
    [string]$ResourceManagerUri,
    [string]$SubscriptionId,
    [string]$UserAssignedIdentityClientId,
    [string]$ImageVmName,
    [string]$ImageVmResourceGroup
)

$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'

$ResourceManagerUriFixed = if($ResourceManagerUri[-1] -eq '/'){$ResourceManagerUri.Substring(0,$ResourceManagerUri.Length - 1)} else {$ResourceManagerUri}

$TokenUri = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=' + $ResourceManagerUriFixed
if (-not [string]::IsNullOrEmpty($UserAssignedIdentityClientId)) { $TokenUri += '&client_id=' + $UserAssignedIdentityClientId }
$AzureManagementAccessToken = (Invoke-RestMethod -Headers @{Metadata="true"} -Uri $TokenUri).access_token

$AzureManagementHeader = @{
    'Content-Type'='application/json'
    'Authorization'='Bearer ' + $AzureManagementAccessToken
}

$ResourceGroupId = '/subscriptions/' + $SubscriptionId + '/resourceGroups/' + $ImageVmResourceGroup
$RunCommandsUri = $ResourceManagerUriFixed + $ResourceGroupId + '/providers/Microsoft.Compute/virtualMachines/' + $ImageVmName + '/runCommands?api-version=2024-03-01'
$RunCommands = (Invoke-RestMethod `
                    -Headers $AzureManagementHeader `
                    -Method 'GET' `
                    -Uri $RunCommandsUri).value.name

ForEach ($RunCommand in $RunCommands) {
    Invoke-RestMethod `
        -Headers $AzureManagementHeader `
        -Method 'DELETE' `
        -Uri $($ResourceManagerUriFixed + $ResourceGroupId + '/providers/Microsoft.Compute/virtualMachines/' + $ImageVmName + '/runCommands/' + $RunCommand + '?api-version=2024-03-01') | Out-Null
}

$DeleteDeadline = (Get-Date).AddMinutes(10)
Do {
    $RemainingRunCommands = @(Invoke-RestMethod `
                                -Headers $AzureManagementHeader `
                                -Method 'GET' `
                                -Uri $RunCommandsUri).value
    if ($RemainingRunCommands.Count -gt 0) {
        Start-Sleep -Seconds 5
    }
} Until ($RemainingRunCommands.Count -eq 0 -or (Get-Date) -ge $DeleteDeadline)

if ($RemainingRunCommands.Count -gt 0) {
    throw "Timed out waiting for Run Commands to be removed from image VM '$ImageVmName'. Remaining commands: $($RemainingRunCommands.name -join ', ')"
}