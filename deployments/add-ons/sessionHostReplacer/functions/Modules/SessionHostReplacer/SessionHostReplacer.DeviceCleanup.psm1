# SessionHostReplacer Device Cleanup Module
# Contains Entra ID and Intune device removal functions

#Region Device Cleanup

function Get-SessionHostVMResourceId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [hashtable]$SessionHostParameters = (Read-FunctionAppSetting SessionHostParameters | ConvertTo-CaseInsensitiveHashtable),
        [string]$SubscriptionId = (Read-FunctionAppSetting VirtualMachinesSubscriptionId),
        [string]$ResourceGroupName = (Read-FunctionAppSetting VirtualMachinesResourceGroupName)
    )

    $pattern = [string]$SessionHostParameters['virtualMachineNameConv']
    $vmName = if ([string]::IsNullOrWhiteSpace($pattern)) { $Name } else { $pattern.Replace('SHNAME', $Name) }
    return "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Compute/virtualMachines/$vmName"
}

function Test-ReplacerResourceAbsent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ARMToken,
        [Parameter(Mandatory = $true)][string]$ResourceId,
        [string]$ResourceManagerUri = (Get-ResourceManagerUri)
    )

    try {
        $resource = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get `
            -Uri "$ResourceManagerUri$($ResourceId)?api-version=2024-07-01" -ErrorAction Stop
        if ($null -eq $resource) {
            throw "Empty resource lookup response for '$ResourceId'; absence cannot be established."
        }
        return $resource.error.code -eq 'ResourceNotFound'
    }
    catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
            return $true
        }
        Write-LogEntry -Message "Unable to establish resource absence for '$ResourceId': $($_.Exception.Message)" -Level Error
        throw
    }
}

function Wait-SessionHostVMDeletions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ARMToken,
        [Parameter(Mandatory = $true)][array]$SessionHosts,
        [int]$MaxWaitMinutes = 10,
        [int]$PollIntervalSeconds = 30,
        [string]$ResourceManagerUri = (Get-ResourceManagerUri)
    )

    $deadline = (Get-Date).AddMinutes($MaxWaitMinutes)
    do {
        $remaining = @($SessionHosts | Where-Object {
            -not (Test-ReplacerResourceAbsent -ARMToken $ARMToken -ResourceId $_.ResourceId -ResourceManagerUri $ResourceManagerUri)
        })
        if ($remaining.Count -eq 0) { return }
        if ((Get-Date) -ge $deadline) {
            throw "VM deletion remains unconfirmed for '$($remaining.SessionHostName -join ', ')'; cleanup and deployment are blocked."
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    } while ($true)
}

function Get-SessionHostDirectoryDevices {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$GraphToken,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('Entra', 'Intune')][string]$Directory,
        [string]$GraphEndpoint = (Get-GraphEndpoint),
        [string]$ClientId = (Read-FunctionAppSetting UserAssignedIdentityClientId)
    )

    $collection = if ($Directory -eq 'Entra') { 'devices' } else { 'deviceManagement/managedDevices' }
    $nameProperty = if ($Directory -eq 'Entra') { 'displayName' } else { 'deviceName' }
    $filter = [Uri]::EscapeDataString("$nameProperty eq '$($Name.Replace("'", "''"))'")
    $uri = "/v1.0/$($collection)?`$filter=$filter"
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    while ($uri) {
        if (-not $seen.Add("$GraphEndpoint$uri")) {
            throw "Repeated $Directory device pagination link for '$Name'."
        }
        $page = Invoke-GraphApiWithRetry -GraphEndpoint $GraphEndpoint -GraphToken $GraphToken `
            -Method Get -Uri $uri -ClientId $ClientId
        $hasValue = if ($page -is [System.Collections.IDictionary]) {
            $page.Contains('value')
        }
        else {
            $null -ne $page -and $page.PSObject.Properties.Name -contains 'value'
        }
        if (-not $hasValue -or $page.value -isnot [System.Collections.IList]) {
            throw "Invalid $Directory device lookup response for '$Name'."
        }
        foreach ($device in $page.value) {
            if ([string]::IsNullOrWhiteSpace([string]$device.id) -or $device.$nameProperty -ine $Name) {
                throw "Invalid or mismatched $Directory device lookup result for '$Name'."
            }
            $device
        }
        $uri = $null
        if ($page.'@odata.nextLink') {
            $next = [Uri]$page.'@odata.nextLink'
            $allowedHosts = @(([Uri]$GraphEndpoint).Host)
            if (([Uri]$GraphEndpoint).Host -eq 'graph.microsoft.us') { $allowedHosts += 'dod-graph.microsoft.us' }
            if (-not $next.IsAbsoluteUri -or $next.Scheme -ne 'https' -or $next.Host -notin $allowedHosts) {
                throw "Unexpected $Directory device pagination endpoint for '$Name'."
            }
            $GraphEndpoint = $next.GetLeftPart([UriPartial]::Authority)
            $uri = $next.PathAndQuery
        }
    }
}

function Assert-SessionHostNamesAvailable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ARMToken,
        [Parameter(Mandatory = $true)][array]$SessionHosts,
        [string]$GraphToken,
        [switch]$WaitForVMDeletion,
        [hashtable]$SessionHostParameters = (Read-FunctionAppSetting SessionHostParameters | ConvertTo-CaseInsensitiveHashtable),
        [bool]$RemoveEntraDevice = (Read-FunctionAppSetting RemoveEntraDevice -AsBoolean),
        [bool]$RemoveIntuneDevice = (Read-FunctionAppSetting RemoveIntuneDevice -AsBoolean),
        [string]$HostPoolSubscriptionId = (Read-FunctionAppSetting HostPoolSubscriptionId),
        [string]$HostPoolResourceGroupName = (Read-FunctionAppSetting HostPoolResourceGroupName),
        [string]$HostPoolName = (Read-FunctionAppSetting HostPoolName),
        [string]$ResourceManagerUri = (Get-ResourceManagerUri)
    )

    try {
        if (@($SessionHosts.SessionHostName | Sort-Object -Unique).Count -ne $SessionHosts.Count) {
            throw 'Duplicate host names in deployment batch.'
        }
        foreach ($hostToDeploy in $SessionHosts) {
            if ([string]::IsNullOrWhiteSpace($hostToDeploy.SessionHostName) -or
                [string]::IsNullOrWhiteSpace($hostToDeploy.ResourceId)) {
                throw 'Every deployment host must have a name and VM resource ID.'
            }
        }
        # Wait only for deletions requested by this invocation, never an unexplained live VM.
        if ($WaitForVMDeletion) {
            Wait-SessionHostVMDeletions -ARMToken $ARMToken -SessionHosts $SessionHosts -ResourceManagerUri $ResourceManagerUri
        }
        else {
            foreach ($hostToDeploy in $SessionHosts) {
                if (-not (Test-ReplacerResourceAbsent -ARMToken $ARMToken -ResourceId $hostToDeploy.ResourceId -ResourceManagerUri $ResourceManagerUri)) {
                    throw "VM absence is not confirmed for '$($hostToDeploy.SessionHostName)'; deployment batch is blocked."
                }
            }
        }

        $isEntraJoined = $SessionHostParameters['IdentitySolution'] -in @('EntraId', 'EntraKerberos-Hybrid', 'EntraKerberos-CloudOnly')
        $RemoveEntraDevice = $RemoveEntraDevice -or $isEntraJoined
        $RemoveIntuneDevice = $RemoveIntuneDevice -or ($isEntraJoined -and [bool]$SessionHostParameters['IntuneEnrollment'])
        if ($RemoveEntraDevice -or $RemoveIntuneDevice) {
            if ([string]::IsNullOrWhiteSpace($GraphToken)) {
                $GraphToken = Get-AccessToken -ResourceUri (Get-GraphEndpoint)
            }
            if ([string]::IsNullOrWhiteSpace($graphToken)) { throw 'Required Graph token acquisition failed; deployment batch is blocked.' }
        }

        $poolPath = "/subscriptions/$HostPoolSubscriptionId/resourceGroups/$HostPoolResourceGroupName/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName"
        $registrations = @(Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get `
            -Uri "$ResourceManagerUri$poolPath/sessionHosts?api-version=2024-04-03" -RequireCollection -ErrorAction Stop)
        $staleRegistrations = @()
        foreach ($registration in $registrations) {
            if ([string]::IsNullOrWhiteSpace($registration.name)) { throw 'Invalid AVD registration lookup response.' }
            $fqdn = ([string]$registration.name).Split('/')[-1]
            $matchingHost = $SessionHosts | Where-Object { $_.SessionHostName -ieq $fqdn.Split('.')[0] }
            if ($matchingHost) {
                if ($registration.id -ine "$poolPath/sessionHosts/$fqdn") {
                    throw "Invalid AVD registration resource ID for '$fqdn'; deployment batch is blocked."
                }
                if ($registration.properties.resourceId -ine $matchingHost.ResourceId) {
                    throw "AVD registration '$fqdn' references a different VM; deployment batch is blocked."
                }
                $staleRegistrations += $registration
            }
        }

        foreach ($hostToDeploy in $SessionHosts) {
            Remove-DeviceFromDirectories -DeviceName $hostToDeploy.SessionHostName -GraphToken $graphToken `
                -RemoveEntraDevice $RemoveEntraDevice -RemoveIntuneDevice $RemoveIntuneDevice
        }
        foreach ($registration in $staleRegistrations) {
            try {
                Invoke-AzureRestMethod -ARMToken $ARMToken -Method Delete `
                    -Uri "$ResourceManagerUri$($registration.id)?api-version=2024-04-03&force=true" -ErrorAction Stop | Out-Null
            }
            catch {
                if (-not $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -ne 404) { throw }
            }
        }

        $verification = Confirm-SessionHostDeletions -ARMToken $ARMToken -GraphToken $graphToken `
            -DeletedHostNames @($SessionHosts.SessionHostName) -SessionHosts $SessionHosts `
            -RemoveEntraDevice $RemoveEntraDevice -RemoveIntuneDevice $RemoveIntuneDevice `
            -HostPoolSubscriptionId $HostPoolSubscriptionId -HostPoolResourceGroupName $HostPoolResourceGroupName `
            -HostPoolName $HostPoolName -ResourceManagerUri $ResourceManagerUri
        if ($verification.TotalHosts -ne $SessionHosts.Count -or @($verification.IncompleteHosts).Count -gt 0) {
            throw 'Required VM, AVD registration, or directory cleanup remains incomplete; deployment batch is blocked.'
        }
        foreach ($hostToDeploy in $SessionHosts) {
            if (-not (Test-ReplacerResourceAbsent -ARMToken $ARMToken -ResourceId $hostToDeploy.ResourceId -ResourceManagerUri $ResourceManagerUri)) {
                throw "VM '$($hostToDeploy.SessionHostName)' appeared during cleanup; deployment batch is blocked."
            }
        }
    }
    catch {
        Write-LogEntry -Message "DEPLOYMENT_PREFLIGHT_BLOCKED | $($_.Exception.Message) Recovery will retry on a subsequent run." -Level Error
        throw
    }
}

function Remove-DeviceFromDirectories {
    <#
    .SYNOPSIS
    Removes a device from Entra ID and/or Intune based on configuration.
    
    .DESCRIPTION
    Helper function to handle device cleanup from identity directories.
    Called by both Remove-SessionHosts and Remove-ExpiredShutdownVMs.
    
    .PARAMETER DeviceName
    The name of the device to remove
    
    .PARAMETER GraphToken
    Graph access token for API calls
    
    .PARAMETER RemoveEntraDevice
    Whether to remove from Entra ID
    
    .PARAMETER RemoveIntuneDevice
    Whether to remove from Intune
    
    .PARAMETER ClientId
    Client ID for Graph API calls
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $DeviceName,
        [Parameter()]
        [string] $GraphToken,
        [Parameter()]
        [bool] $RemoveEntraDevice = (Read-FunctionAppSetting RemoveEntraDevice -AsBoolean),
        [Parameter()]
        [bool] $RemoveIntuneDevice = (Read-FunctionAppSetting RemoveIntuneDevice -AsBoolean),
        [Parameter()]
        [string] $ClientId = (Read-FunctionAppSetting UserAssignedIdentityClientId)
    )
    
    if (-not $RemoveEntraDevice -and -not $RemoveIntuneDevice) {
        return
    }
    if ([string]::IsNullOrWhiteSpace($GraphToken)) {
        throw "Graph token is required for device cleanup of '$DeviceName'."
    }
    
    if ($RemoveEntraDevice) {
        Write-LogEntry -Message "Deleting $DeviceName from Entra ID" -Level Trace
        try {
            Remove-EntraDevice -GraphToken $GraphToken -Name $DeviceName -ClientId $ClientId
        }
        catch {
            Write-LogEntry -Message "Failed to remove $DeviceName from Entra ID: $($_.Exception.Message)" -Level Error
            throw
        }
    }
    
    if ($RemoveIntuneDevice) {
        Write-LogEntry -Message "Deleting $DeviceName from Intune" -Level Trace
        try {
            Remove-IntuneDevice -GraphToken $GraphToken -Name $DeviceName -ClientId $ClientId
        }
        catch {
            Write-LogEntry -Message "Failed to remove $DeviceName from Intune: $($_.Exception.Message)" -Level Error
            throw
        }
    }
}

function Remove-EntraDevice {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string] $GraphEndpoint = (Get-GraphEndpoint),
        
        [Parameter(Mandatory = $true)]
        $GraphToken,
        
        [Parameter(Mandatory = $true)]
        [string] $Name,
        
        [Parameter(Mandatory = $false)]
        [string] $ClientId = (Read-FunctionAppSetting UserAssignedIdentityClientId)
    )
    
    try {
        $devices = @(Get-SessionHostDirectoryDevices -GraphEndpoint $GraphEndpoint -GraphToken $GraphToken -Name $Name -Directory Entra -ClientId $ClientId)
        if ($devices.Count -gt 1) { throw "Multiple Entra devices match '$Name'; resolve ambiguous ownership before retrying." }
        
        If ($devices.Count -eq 1) {
            $Id = $devices[0].id
            Write-LogEntry -Message "Removing session host $Name from Entra ID"
            Write-LogEntry -Message "Device ID: $Id" -Level Trace
            
            try {
                Invoke-GraphApiWithRetry -GraphEndpoint $GraphEndpoint -GraphToken $GraphToken `
                    -Method Delete -Uri "/v1.0/devices/$Id" -ClientId $ClientId | Out-Null
            }
            catch {
                if (-not $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -ne 404) { throw }
            }
            
            Write-LogEntry -Message "Successfully removed device $Name from Entra ID"
        }
        else {
            Write-LogEntry -Message "Device $Name not found in Entra ID"
        }
    }
    catch {
        Write-LogEntry -Message "Failed to remove Entra device $Name : $($_.Exception.Message)" -Level Error
        throw
    }
}

function Remove-IntuneDevice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string] $GraphEndpoint = (Get-GraphEndpoint),

        [Parameter(Mandatory = $true)]
        $GraphToken,

        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $false)]
        [string] $ClientId = (Read-FunctionAppSetting UserAssignedIdentityClientId)
    )
    
    try {
        $devices = @(Get-SessionHostDirectoryDevices -GraphEndpoint $GraphEndpoint -GraphToken $GraphToken -Name $Name -Directory Intune -ClientId $ClientId)
        if ($devices.Count -gt 1) { throw "Multiple Intune devices match '$Name'; resolve ambiguous ownership before retrying." }
        
        If ($devices.Count -eq 1) {
            $Id = $devices[0].id
            Write-LogEntry -Message "Removing session host '$Name' device from Intune"
            Write-LogEntry -Message "Device ID: $Id" -Level Trace
            
            try {
                Invoke-GraphApiWithRetry -GraphEndpoint $GraphEndpoint -GraphToken $GraphToken `
                    -Method Delete -Uri "/v1.0/deviceManagement/managedDevices/$Id" -ClientId $ClientId | Out-Null
            }
            catch {
                if (-not $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -ne 404) { throw }
            }
            
            Write-LogEntry -Message "Successfully removed device $Name from Intune"
        }
        else {
            Write-LogEntry -Message "Device $Name not found in Intune"
        }
    }
    catch {
        Write-LogEntry -Message "Failed to remove Intune device $Name : $($_.Exception.Message)" -Level Error
        throw
    }
}

function Confirm-SessionHostDeletions {
    <#
    .SYNOPSIS
    Validates complete deletion of session hosts across VM, Entra ID, and Intune.
    
    .DESCRIPTION
    Polls Azure to confirm VM deletion, then verifies Graph cleanup for Entra ID and Intune devices.
    Provides per-host validation status and comprehensive summary logging.
    
    .PARAMETER ARMToken
    ARM access token for Azure Resource Manager API calls
    
    .PARAMETER GraphToken
    Graph access token for Entra ID and Intune API calls
    
    .PARAMETER DeletedHostNames
    Array of session host names that were successfully deleted
    
    .PARAMETER SessionHosts
    Array of session host objects (to get resource IDs)
    
    .PARAMETER MaxWaitMinutes
    Maximum time to wait for deletion confirmation (default: 10)
    
    .PARAMETER PollIntervalSeconds
    Seconds between polling attempts (default: 30)
    
    .PARAMETER RemoveEntraDevice
    Whether Entra ID device deletion was performed (only validate if true)
    
    .PARAMETER RemoveIntuneDevice
    Whether Intune device deletion was performed (only validate if true)
    
    .OUTPUTS
    PSCustomObject with validation results including VM, Entra ID, and Intune confirmation counts
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $ARMToken,
        
        [Parameter()]
        [string] $GraphToken,
        
        [Parameter(Mandatory = $true)]
        [array] $DeletedHostNames,
        
        [Parameter(Mandatory = $true)]
        [array] $SessionHosts,
        
        [Parameter()]
        [int] $MaxWaitMinutes = 10,
        
        [Parameter()]
        [int] $PollIntervalSeconds = 30,
        
        [Parameter()]
        [bool] $RemoveEntraDevice = (Read-FunctionAppSetting RemoveEntraDevice -AsBoolean),
        
        [Parameter()]
        [bool] $RemoveIntuneDevice = (Read-FunctionAppSetting RemoveIntuneDevice -AsBoolean),
        
        [Parameter()]
        [string] $ResourceManagerUri = (Get-ResourceManagerUri),
        
        [Parameter()]
        [string] $ClientId = (Read-FunctionAppSetting UserAssignedIdentityClientId),
        [string] $HostPoolSubscriptionId = (Read-FunctionAppSetting HostPoolSubscriptionId),
        [string] $HostPoolResourceGroupName = (Read-FunctionAppSetting HostPoolResourceGroupName),
        [string] $HostPoolName = (Read-FunctionAppSetting HostPoolName)
    )
    
    if ($DeletedHostNames.Count -eq 0) {
        Write-LogEntry -Message "No hosts to verify - skipping validation" -Level Trace
        return [PSCustomObject]@{
            TotalHosts       = 0
            VMsConfirmed     = 0
            AVDConfirmed     = 0
            EntraIDConfirmed = 0
            IntuneConfirmed  = 0
            IncompleteHosts  = @()
        }
    }
    
    if (($RemoveEntraDevice -or $RemoveIntuneDevice) -and [string]::IsNullOrWhiteSpace($GraphToken)) {
        throw 'A Graph token is required to verify configured device cleanup.'
    }
    Write-LogEntry -Message "Verifying complete deletion for {0} host(s) (VM, AVD registration, Entra ID, Intune)..." -StringValues $DeletedHostNames.Count
    
    $startTime = Get-Date
    $timeoutTime = $startTime.AddMinutes($MaxWaitMinutes)
    
    # Build validation tracking for each deleted host
    $hostsToVerify = @()
    foreach ($deletedName in $DeletedHostNames) {
        $sessionHost = $SessionHosts | Where-Object { $_.SessionHostName -eq $deletedName } | Select-Object -First 1
        if (-not $sessionHost -or [string]::IsNullOrWhiteSpace($sessionHost.ResourceId)) {
            throw "Could not find resource ID for deleted host '$deletedName'; verification is incomplete."
        }
        
        $vmName = $sessionHost.resourceId.Split('/')[-1]
        $vmUri = "$ResourceManagerUri$($sessionHost.ResourceId)?api-version=2024-03-01"
        
        $hostsToVerify += [PSCustomObject]@{
            Name             = $deletedName
            VMName           = $vmName
            VMUri            = $vmUri
            VMConfirmed      = $false
            AVDConfirmed     = $false
            EntraIDConfirmed = $false
            IntuneConfirmed  = $false
        }
    }
    
    # Mark Entra/Intune as confirmed if not being checked
    if (-not $RemoveEntraDevice -and -not $RemoveIntuneDevice) {
        Write-LogEntry -Message "Device cleanup disabled - Entra ID and Intune validation is not applicable" -Level Trace
        foreach ($sh in $hostsToVerify) {
            $sh.EntraIDConfirmed = $true
            $sh.IntuneConfirmed = $true
        }
    }
    elseif (-not $RemoveEntraDevice) {
        foreach ($sh in $hostsToVerify) { $sh.EntraIDConfirmed = $true }
    }
    elseif (-not $RemoveIntuneDevice) {
        foreach ($sh in $hostsToVerify) { $sh.IntuneConfirmed = $true }
    }
    
    # Build verification system list for logging
    $checkSystems = @('VM', 'AVD registration')
    if ($GraphToken -and $RemoveEntraDevice) { $checkSystems += 'Entra ID' }
    if ($GraphToken -and $RemoveIntuneDevice) { $checkSystems += 'Intune' }
    Write-LogEntry -Message "Verifying deletion for {0}..." -StringValues ($checkSystems -join ', ') -Level Trace
    
    # Poll all systems until all hosts fully confirmed or timeout
    $checkCount = 0
    $incompleteHosts = $hostsToVerify | Where-Object { -not ($_.VMConfirmed -and $_.AVDConfirmed -and $_.EntraIDConfirmed -and $_.IntuneConfirmed) }
    
    while ((Get-Date) -lt $timeoutTime -and $incompleteHosts.Count -gt 0) {
        $checkCount++
        $elapsedSeconds = [Math]::Round(((Get-Date) - $startTime).TotalSeconds)
        $remainingHosts = $incompleteHosts.Count
        Write-LogEntry -Message "Deletion verification check {0} at {1}s: {2} host(s) with incomplete deletion..." -StringValues $checkCount, $elapsedSeconds, $remainingHosts -Level Trace
        
        $registrationReadSucceeded = $false
        $registeredNames = @()
        try {
            $poolPath = "/subscriptions/$HostPoolSubscriptionId/resourceGroups/$HostPoolResourceGroupName/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName"
            $registeredNames = @(Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get `
                -Uri "$ResourceManagerUri$poolPath/sessionHosts?api-version=2024-04-03" -RequireCollection -ErrorAction Stop |
                ForEach-Object {
                    if ([string]::IsNullOrWhiteSpace($_.name)) { throw 'Invalid AVD registration lookup response.' }
                    ([string]$_.name).Split('/')[-1].Split('.')[0]
                })
            $registrationReadSucceeded = $true
        }
        catch {
            Write-LogEntry -Message "Unable to verify AVD registration absence: $($_.Exception.Message)" -Level Warning
        }
        foreach ($sh in $incompleteHosts) {
            $sh.AVDConfirmed = $registrationReadSucceeded -and $sh.Name -notin $registeredNames
            # Check VM deletion
            if (-not $sh.VMConfirmed) {
                try {
                    $vmCheck = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $sh.VMUri -ErrorAction SilentlyContinue
                    
                    if ($null -ne $vmCheck -and $vmCheck.error.code -eq 'ResourceNotFound') {
                        $sh.VMConfirmed = $true
                        Write-LogEntry -Message "VM deletion confirmed: {0}" -StringValues $sh.VMName -Level Trace
                    }
                    elseif ($null -eq $vmCheck) {
                        Write-LogEntry -Message "Unable to verify VM deletion for '$($sh.VMName)': empty response." -Level Warning
                    }
                }
                catch {
                    $statusCode = if ($_.Exception.Response) {
                        [int]$_.Exception.Response.StatusCode
                    }
                    else {
                        $null
                    }

                    if ($statusCode -eq 404) {
                        $sh.VMConfirmed = $true
                        Write-LogEntry -Message "VM deletion confirmed: {0}" -StringValues $sh.VMName -Level Trace
                    }
                    else {
                        Write-LogEntry -Message "Unable to verify VM deletion for {0}: {1}" -StringValues $sh.VMName, $_.Exception.Message -Level Warning
                    }
                }
            }
            
            # Check Entra ID deletion (only if removal was enabled and Graph token available)
            if (-not $sh.EntraIDConfirmed -and $GraphToken -and $RemoveEntraDevice) {
                try {
                    $entraDevices = @(Get-SessionHostDirectoryDevices -GraphToken $GraphToken -Name $sh.Name -Directory Entra -ClientId $ClientId)
                    
                    if ($entraDevices.Count -eq 0) {
                        $sh.EntraIDConfirmed = $true
                        Write-LogEntry -Message "Entra ID deletion confirmed: {0}" -StringValues $sh.Name -Level Trace
                    }
                }
                catch {
                    Write-LogEntry -Message "Error verifying Entra ID deletion for {0}: {1}" -StringValues $sh.Name, $_.Exception.Message -Level Warning
                }
            }
            
            # Check Intune deletion (only if removal was enabled and Graph token available)
            if (-not $sh.IntuneConfirmed -and $GraphToken -and $RemoveIntuneDevice) {
                try {
                    $intuneDevices = @(Get-SessionHostDirectoryDevices -GraphToken $GraphToken -Name $sh.Name -Directory Intune -ClientId $ClientId)
                    
                    if ($intuneDevices.Count -eq 0) {
                        $sh.IntuneConfirmed = $true
                        Write-LogEntry -Message "Intune deletion confirmed: {0}" -StringValues $sh.Name -Level Trace
                    }
                }
                catch {
                    Write-LogEntry -Message "Error verifying Intune deletion for {0}: {1}" -StringValues $sh.Name, $_.Exception.Message -Level Warning
                }
            }
            
            # Log per-host status after each check
            $vmStatus = if ($sh.VMConfirmed) { 'Confirmed' } else { 'Pending' }
            $entraStatus = if ($sh.EntraIDConfirmed) { 'Confirmed' } else { 'Pending' }
            $intuneStatus = if ($sh.IntuneConfirmed) { 'Confirmed' } else { 'Pending' }
            $fullyConfirmed = $sh.VMConfirmed -and $sh.AVDConfirmed -and $sh.EntraIDConfirmed -and $sh.IntuneConfirmed
            if ($fullyConfirmed) {
                Write-LogEntry -Message "Full deletion confirmed for {0}: VM={1} AVD=True EntraID={2} Intune={3}" -StringValues $sh.Name, $vmStatus, $entraStatus, $intuneStatus -Level Trace
            }
        }
        
        # Recalculate incomplete hosts for next iteration
        $incompleteHosts = $hostsToVerify | Where-Object { -not ($_.VMConfirmed -and $_.AVDConfirmed -and $_.EntraIDConfirmed -and $_.IntuneConfirmed) }
        
        if ($incompleteHosts.Count -gt 0 -and (Get-Date) -lt $timeoutTime) {
            Start-Sleep -Seconds $PollIntervalSeconds
        }
    }

    # Calculate summary counts
    $vmsConfirmed = ($hostsToVerify | Where-Object { $_.VMConfirmed }).Count
    $avdConfirmed = ($hostsToVerify | Where-Object { $_.AVDConfirmed }).Count
    $entraIDConfirmed = ($hostsToVerify | Where-Object { $_.EntraIDConfirmed }).Count
    $intuneConfirmed = ($hostsToVerify | Where-Object { $_.IntuneConfirmed }).Count
    $totalHosts = $hostsToVerify.Count

    # Summary logging
    Write-LogEntry -Message "DELETION_VERIFICATION | VMs: {0}/{1} confirmed | AVD: {6}/{1} confirmed | EntraID: {2}/{3} confirmed | Intune: {4}/{5} confirmed" `
        -StringValues $vmsConfirmed, $totalHosts, $entraIDConfirmed, $totalHosts, $intuneConfirmed, $totalHosts, $avdConfirmed

    # Warn about any incomplete deletions
    $incompleteHosts = $hostsToVerify | Where-Object { -not ($_.VMConfirmed -and $_.AVDConfirmed -and $_.EntraIDConfirmed -and $_.IntuneConfirmed) }
    if ($incompleteHosts.Count -gt 0) {
        foreach ($sh in $incompleteHosts) {
            $failures = @()
            if (-not $sh.VMConfirmed) { $failures += "VM" }
            if (-not $sh.AVDConfirmed) { $failures += "AVD registration" }
            if (-not $sh.EntraIDConfirmed) { $failures += "EntraID" }
            if (-not $sh.IntuneConfirmed) { $failures += "Intune" }
            Write-LogEntry -Message "Warning: Incomplete deletion for {0} - unconfirmed: {1}" -StringValues $sh.Name, ($failures -join ', ') -Level Warning
        }
    }
    else {
        Write-LogEntry -Message "All deletions fully confirmed across VM, AVD registration, Entra ID, and Intune"
    }

    # Return validation results
    return [PSCustomObject]@{
        TotalHosts       = $totalHosts
        VMsConfirmed     = $vmsConfirmed
        AVDConfirmed     = $avdConfirmed
        EntraIDConfirmed = $entraIDConfirmed
        IntuneConfirmed  = $intuneConfirmed
        IncompleteHosts  = $incompleteHosts
    }
}

#EndRegion Device Cleanup

# Export functions
Export-ModuleMember -Function Get-SessionHostVMResourceId, Test-ReplacerResourceAbsent, Wait-SessionHostVMDeletions, Assert-SessionHostNamesAvailable, Get-SessionHostDirectoryDevices, Remove-DeviceFromDirectories, Remove-EntraDevice, Remove-IntuneDevice, Confirm-SessionHostDeletions
