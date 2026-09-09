Param(
    [string]$ResourceManagerUri,
    [string]$SubscriptionId,
    [string]$UserAssignedIdentityClientId,
    [string]$ImageVmName,
    [string]$ImageBuildResourceGroup,
    [string]$OrchestrationVmName,
    [string]$CurrentRunCommandName
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

function Get-RunCommands {
    param(
        [string]$RunCommandsUri,
        [string]$ExcludedRunCommandName = ''
    )

    return @(
        (Invoke-RestMethod `
            -Headers $AzureManagementHeader `
            -Method 'GET' `
            -Uri $RunCommandsUri).value |
            Where-Object { [string]::IsNullOrEmpty($ExcludedRunCommandName) -or $_.name -ne $ExcludedRunCommandName }
    )
}

$ResourceGroupId = '/subscriptions/' + $SubscriptionId + '/resourceGroups/' + $ImageBuildResourceGroup
$VirtualMachineUri = $ResourceManagerUriFixed + $ResourceGroupId + '/providers/Microsoft.Compute/virtualMachines/'
$ImageRunCommandsUri = $VirtualMachineUri + $ImageVmName + '/runCommands?api-version=2024-03-01'
$OrchestrationRunCommandsUri = $VirtualMachineUri + $OrchestrationVmName + '/runCommands?api-version=2024-03-01'

$ImageRunCommands = Get-RunCommands -RunCommandsUri $ImageRunCommandsUri
foreach ($RunCommand in $ImageRunCommands) {
    $DeleteUri = $VirtualMachineUri + $ImageVmName + '/runCommands/' + $RunCommand.name + '?api-version=2024-03-01'
    Invoke-RestMethod `
        -Headers $AzureManagementHeader `
        -Method 'DELETE' `
        -Uri $DeleteUri | Out-Null
}

$DeleteDeadline = (Get-Date).AddMinutes(10)
Do {
    $RemainingImageRunCommands = Get-RunCommands -RunCommandsUri $ImageRunCommandsUri
    if ($RemainingImageRunCommands.Count -gt 0) {
        Start-Sleep -Seconds 5
    }
} Until ($RemainingImageRunCommands.Count -eq 0 -or (Get-Date) -ge $DeleteDeadline)

if ($RemainingImageRunCommands.Count -gt 0) {
    $RemainingRunCommandNames = $RemainingImageRunCommands | ForEach-Object { $_.name }
    throw "Timed out waiting for image VM Run Commands to be removed. Remaining commands: $($RemainingRunCommandNames -join ', ')"
}

$OrchestrationRunCommands = Get-RunCommands `
    -RunCommandsUri $OrchestrationRunCommandsUri `
    -ExcludedRunCommandName $CurrentRunCommandName

foreach ($RunCommand in $OrchestrationRunCommands) {
    $DeleteUri = $VirtualMachineUri + $OrchestrationVmName + '/runCommands/' + $RunCommand.name + '?api-version=2024-03-01'
    Invoke-RestMethod `
        -Headers $AzureManagementHeader `
        -Method 'DELETE' `
        -Uri $DeleteUri | Out-Null
}