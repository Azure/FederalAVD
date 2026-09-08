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
$RunCommandTargets = @(
    [pscustomobject]@{
        VmName = $ImageVmName
        RunCommandsUri = $VirtualMachineUri + $ImageVmName + '/runCommands?api-version=2024-03-01'
        ExcludedRunCommandName = ''
    }
    [pscustomobject]@{
        VmName = $OrchestrationVmName
        RunCommandsUri = $VirtualMachineUri + $OrchestrationVmName + '/runCommands?api-version=2024-03-01'
        ExcludedRunCommandName = $CurrentRunCommandName
    }
)

foreach ($Target in $RunCommandTargets) {
    $RunCommands = Get-RunCommands `
        -RunCommandsUri $Target.RunCommandsUri `
        -ExcludedRunCommandName $Target.ExcludedRunCommandName

    foreach ($RunCommand in $RunCommands) {
        $DeleteUri = $VirtualMachineUri + $Target.VmName + '/runCommands/' + $RunCommand.name + '?api-version=2024-03-01'
        Invoke-RestMethod `
            -Headers $AzureManagementHeader `
            -Method 'DELETE' `
            -Uri $DeleteUri | Out-Null
    }
}

$DeleteDeadline = (Get-Date).AddMinutes(10)
Do {
    $RemainingRunCommands = @(
        foreach ($Target in $RunCommandTargets) {
            Get-RunCommands `
                -RunCommandsUri $Target.RunCommandsUri `
                -ExcludedRunCommandName $Target.ExcludedRunCommandName |
                ForEach-Object {
                    [pscustomobject]@{
                        VmName = $Target.VmName
                        Name = $_.name
                    }
                }
        }
    )
    if ($RemainingRunCommands.Count -gt 0) {
        Start-Sleep -Seconds 5
    }
} Until ($RemainingRunCommands.Count -eq 0 -or (Get-Date) -ge $DeleteDeadline)

if ($RemainingRunCommands.Count -gt 0) {
    $RemainingRunCommandNames = $RemainingRunCommands | ForEach-Object { "$($_.VmName)/$($_.Name)" }
    throw "Timed out waiting for Run Commands to be removed. Remaining commands: $($RemainingRunCommandNames -join ', ')"
}