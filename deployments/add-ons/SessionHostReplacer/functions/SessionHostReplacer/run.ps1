# Input bindings are passed in via param block.
param($Timer)

# Get the current universal time in the default string format
$currentUTCtime = (Get-Date).ToUniversalTime()

# The 'IsPastDue' property is 'true' when the current function invocation is later than scheduled.
if ($Timer.IsPastDue) {
    Write-Host "PowerShell timer is running late!"
}

# Initialize environment-agnostic variables from Function App Configuration
$Script:SubscriptionId = $env:SubscriptionId
$Script:AccessToken = Get-AccessToken -ResourceManagerUrl $env:ResourceManagerUrl -ClientId $env:UserAssignedIdentityClientId

Write-HostDetailed -Message "ResourceManagerUrl: {0}" -StringValues $env:ResourceManagerUrl -Level Host
Write-HostDetailed -Message "SubscriptionId: {0}" -StringValues $Script:SubscriptionId -Level Host

# Decide which Resource group to use for Session Hosts
$Script:HostPoolResourceGroupName = Read-FunctionAppSetting HostPoolResourceGroupName
if ([string]::IsNullOrEmpty((Read-FunctionAppSetting VirtualMachinesResourceGroupName))) {
    $Script:VirtualMachinesResourceGroupName = $hostPoolResourceGroupName
}
else {
    $Script:VirtualMachinesResourceGroupName = Read-FunctionAppSetting VirtualMachinesResourceGroupName
}
Write-HostDetailed -Message "Using resource group {0} for session hosts" -StringValues $Script:VirtualMachinesResourceGroupName -Level Host

# Get session hosts and update tags if needed.
$sessionHosts = Get-SessionHosts -FixSessionHostTags (Read-FunctionAppSetting FixSessionHostTags)
Write-HostDetailed -Message "Found {0} session hosts" -StringValues $sessionHosts.Count -Level Host

# Filter to Session hosts that are included in auto replace
$sessionHostsFiltered = $sessionHosts | Where-Object { $_.IncludeInAutomation }
Write-HostDetailed -Message "Filtered to {0} session hosts enabled for automatic replacement: {1}" -StringValues $sessionHostsFiltered.Count, ($sessionHostsFiltered.SessionHostName -join ',') -Level Host

# Get running deployments, if any
$runningDeployments = Get-RunningDeployments -ResourceGroupName $Script:VirtualMachinesResourceGroupName
Write-HostDetailed -Message "Found {0} running deployments" -StringValues $runningDeployments.Count -Level Host

# Load session host parameters
$sessionHostParameters = [hashtable]::new([System.StringComparer]::InvariantCultureIgnoreCase)
$sessionHostParameters += (Read-FunctionAppSetting SessionHostParameters)

# Get latest version of session host image
Write-HostDetailed -Message "Getting latest image version using Image Reference: {0}" -StringValues ($sessionHostParameters.ImageReference | Out-String) -Level Host
$latestImageVersion = Get-LatestImageVersion -ImageReference $sessionHostParameters.ImageReference -Location $sessionHostParameters.Location

# Get number session hosts to deploy
$hostPoolDecisions = Get-HostPoolDecisions -SessionHosts $sessionHostsFiltered -RunningDeployments $runningDeployments -LatestImageVersion $latestImageVersion

# Deploy new session hosts
if ($hostPoolDecisions.PossibleDeploymentsCount -gt 0) {
    Write-HostDetailed -Message "We will deploy {0} session hosts" -StringValues $hostPoolDecisions.PossibleDeploymentsCount -Level Host
    # Deploy session hosts - use SessionHostName (hostname from FQDN) not VMName (Azure VM resource name)
    $existingSessionHostNames = (@($sessionHosts.SessionHostName) + @($hostPoolDecisions.ExistingSessionHostNames)) | Sort-Object | Select-Object -Unique
    Deploy-SessionHosts -VirtualMachinesResourceGroupName $Script:VirtualMachinesResourceGroupName -NewSessionHostsCount $hostPoolDecisions.PossibleDeploymentsCount -ExistingSessionHostNames $existingSessionHostNames
}

# Delete session hosts
if ($hostPoolDecisions.PossibleSessionHostDeleteCount -gt 0 -and $hostPoolDecisions.SessionHostsPendingDelete.Count -gt 0) {
    Write-HostDetailed -Message "We will decommission {0} session hosts from this list: {1}" -StringValues $hostPoolDecisions.SessionHostsPendingDelete.Count, ($hostPoolDecisions.SessionHostsPendingDelete.SessionHostName -join ',') -Level Host
    # Decommission session hosts
    $removeEntraDevice = Read-FunctionAppSetting RemoveEntraDevice
    $removeIntuneDevice = Read-FunctionAppSetting RemoveIntuneDevice
    Remove-SessionHosts -SessionHostsPendingDelete $hostPoolDecisions.SessionHostsPendingDelete -RemoveEntraDevice $removeEntraDevice -RemoveIntuneDevice $removeIntuneDevice
}

# Write an information log with the current time.
Write-Host "PowerShell timer trigger function finished! TIME: $currentUTCtime"

