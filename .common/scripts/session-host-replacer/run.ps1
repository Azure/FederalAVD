# Input bindings are passed in via param block.
param($Timer)

# Get the current universal time in the default string format
$currentUTCtime = (Get-Date).ToUniversalTime()

# The 'IsPastDue' property is 'true' when the current function invocation is later than scheduled.
if ($Timer.IsPastDue) {
    Write-Host "PowerShell timer is running late!"
}

# Decide which Resource group to use for Session Hosts
$hostPoolResourceGroupName = Get-FunctionConfig _HostPoolResourceGroupName
if ([string]::IsNullOrEmpty((Get-FunctionConfig _SessionHostResourceGroupName))) {
    $sessionHostResourceGroupName = $hostPoolResourceGroupName
}
else {
    $sessionHostResourceGroupName = Get-FunctionConfig _SessionHostResourceGroupName
}
Write-HostDetailed -Message "Using resource group {0} for session hosts" -StringValues $sessionHostResourceGroupName -Level Host

# Get session hosts and update tags if needed.
$sessionHosts = Get-SessionHost -FixSessionHostTags:(Get-FunctionConfig _FixSessionHostTags)
Write-HostDetailed -Message "Found {0} session hosts" -StringValues $sessionHosts.Count -Level Host

# Filter to Session hosts that are included in auto replace
$sessionHostsFiltered = $sessionHosts | Where-Object { $_.IncludeInAutomation }
Write-HostDetailed -Message "Filtered to {0} session hosts enabled for automatic replacement: {1}" -StringValues $sessionHostsFiltered.Count, ($sessionHostsFiltered.VMName -join ',') -Level Host

# Get running deployments, if any
$runningDeployments = Get-RunningDeployment -ResourceGroupName $sessionHostResourceGroupName
Write-HostDetailed -Message "Found {0} running deployments" -StringValues $runningDeployments.Count -Level Host

# Load session host parameters
$sessionHostParameters = [hashtable]::new([System.StringComparer]::InvariantCultureIgnoreCase)
$sessionHostParameters += (Get-FunctionConfig _SessionHostParameters)

# Get latest version of session host image
Write-HostDetailed -Message "Getting latest image version using Image Reference: {0}" -StringValues ($sessionHostParameters.ImageReference | Out-String) -Level Host
$latestImageVersion = Get-LatestImageVersion -ImageReference $sessionHostParameters.ImageReference -Location $sessionHostParameters.Location

# Get number session hosts to deploy
$hostPoolDecisions = Get-HostPoolDecision -SessionHosts $sessionHostsFiltered -RunningDeployments $runningDeployments -LatestImageVersion $latestImageVersion

# Deploy new session hosts
if ($hostPoolDecisions.PossibleDeploymentsCount -gt 0) {
    Write-HostDetailed -Message "We will deploy {0} session hosts" -StringValues $hostPoolDecisions.PossibleDeploymentsCount -Level Host
    # Deploy session hosts
    $existingSessionHostVMNames = (@($sessionHosts.VMName) + @($hostPoolDecisions.ExistingSessionHostVMNames)) | Sort-Object | Select-Object -Unique
    Deploy-SessionHost -SessionHostResourceGroupName $sessionHostResourceGroupName -NewSessionHostsCount $hostPoolDecisions.PossibleDeploymentsCount -ExistingSessionHostVMNames $existingSessionHostVMNames
}

# Delete session hosts
if ($hostPoolDecisions.PossibleSessionHostDeleteCount -gt 0 -and $hostPoolDecisions.SessionHostsPendingDelete.Count -gt 0) {
    Write-HostDetailed -Message "We will decommission {0} session hosts from this list: {1}" -StringValues $hostPoolDecisions.SessionHostsPendingDelete.Count, ($hostPoolDecisions.SessionHostsPendingDelete.VMName -join ',') -Level Host
    # Decommission session hosts
    $removeEntraDevice = Get-FunctionConfig _RemoveEntraDevice
    $removeIntuneDevice = Get-FunctionConfig _RemoveIntuneDevice
    Remove-SessionHost -SessionHostsPendingDelete $hostPoolDecisions.SessionHostsPendingDelete -RemoveEntraDevice $removeEntraDevice -RemoveIntuneDevice $removeIntuneDevice
}

# Write an information log with the current time.
Write-Host "PowerShell timer trigger function finished! TIME: $currentUTCtime"
