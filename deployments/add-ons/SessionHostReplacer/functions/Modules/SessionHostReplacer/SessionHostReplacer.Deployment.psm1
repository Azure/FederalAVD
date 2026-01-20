# SessionHostReplacer Deployment Module
# Contains deployment and progressive scale-up functions

# Import Core utilities
Import-Module "$PSScriptRoot\SessionHostReplacer.Core.psm1" -Force

#Region Progressive Scale-Up State Management

function Get-DeploymentState {
    <#
    .SYNOPSIS
        Retrieves the deployment state from Azure Table Storage for progressive scale-up tracking.
    .DESCRIPTION
        Reads deployment history from the function app's storage account table to track
        consecutive successful deployments and current scale-up percentage.
    .PARAMETER HostPoolName
        Name of the host pool to retrieve state for.
    .PARAMETER StorageAccountName
        Name of the storage account containing the state table.
    .EXAMPLE
        $state = Get-DeploymentState -HostPoolName 'hp-prod-001'
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        [string] $HostPoolName = (Read-FunctionAppSetting HostPoolName),
        
        [Parameter()]
        [string] $StorageAccountName,

        [Parameter()]
        [string] $ClientId = (Read-FunctionAppSetting UserAssignedIdentityClientId)
    )
    
    try {
        # Parse storage account name from AzureWebJobsStorage if not provided
        if (-not $StorageAccountName) {
            $storageUri = $env:AzureWebJobsStorage__blobServiceUri
            if ($storageUri -match 'https://([^.]+)\.') {
                $StorageAccountName = $Matches[1]
            }
            else {
                throw "Unable to determine storage account name from environment variables"
            }
        }
        
        $tableName = 'sessionHostDeploymentState'
        $partitionKey = $HostPoolName
        $rowKey = 'DeploymentState'
        $storageSuffix = $env:StorageSuffix
        $tableEndpoint = "https://$StorageAccountName.table.$storageSuffix"
        
        # Get storage access token using user-assigned managed identity
        # Storage tokens should NOT have trailing slash (fixed from original code which had trailing slash)
        $storageToken = Get-AccessToken -ResourceUri "https://$StorageAccountName.table.$storageSuffix" -ClientId $ClientId
        
        $headers = @{
            'Authorization'  = "Bearer $storageToken"
            'Accept'         = 'application/json;odata=nometadata'
            'x-ms-version'   = '2019-02-02'
            'x-ms-date'      = [DateTime]::UtcNow.ToString('R')
        }
        
        # Check if table exists, create if not
        $tablesUri = "$tableEndpoint/Tables"
        try {
            $existingTables = Invoke-RestMethod -Uri $tablesUri -Headers $headers -Method Get -ContentType 'application/json' -ErrorAction SilentlyContinue
            $tableExists = $existingTables.value | Where-Object { $_.TableName -eq $tableName }
            
            if (-not $tableExists) {
                Write-LogEntry -Message "Creating deployment state table '$tableName'" -Level Trace
                $createTableBody = @{ TableName = $tableName } | ConvertTo-Json
                $headers['Content-Type'] = 'application/json'
                Invoke-RestMethod -Uri $tablesUri -Headers $headers -Method Post -Body $createTableBody -ErrorAction Stop | Out-Null
            }
        }
        catch {
            Write-LogEntry -Message "Error checking/creating table: $_" -Level Warning
        }
        
        # Query entity
        $entityUri = "$tableEndpoint/$tableName(PartitionKey='$partitionKey',RowKey='$rowKey')"
        
        try {
            $entity = Invoke-RestMethod -Uri $entityUri -Headers $headers -Method Get -ContentType 'application/json' -ErrorAction Stop
            
            Write-LogEntry -Message "Retrieved deployment state: ConsecutiveSuccesses=$($entity.ConsecutiveSuccesses), CurrentPercentage=$($entity.CurrentPercentage)%" -Level Trace
            return [PSCustomObject]@{
                LastDeploymentName       = $entity.LastDeploymentName
                LastDeploymentCount      = [int]$entity.LastDeploymentCount
                LastDeploymentNeeded     = [int]$entity.LastDeploymentNeeded
                LastDeploymentPercentage = [int]$entity.LastDeploymentPercentage
                LastStatus               = $entity.LastStatus
                LastTimestamp            = $entity.LastTimestamp
                ConsecutiveSuccesses     = [int]$entity.ConsecutiveSuccesses
                CurrentPercentage        = [int]$entity.CurrentPercentage
                TargetSessionHostCount   = [int]$entity.TargetSessionHostCount
                LastImageVersion         = $entity.LastImageVersion
                LastTotalToReplace       = [int]$entity.LastTotalToReplace
                PendingHostMappings      = if ($entity.PendingHostMappings) { $entity.PendingHostMappings } else { '{}' }
            }
        }
        catch {
            if ($_.Exception.Response.StatusCode -eq 404) {
                Write-LogEntry -Message "No deployment state found, initializing new state" -Level Trace
                return [PSCustomObject]@{
                    LastDeploymentName       = ''
                    LastDeploymentCount      = 0
                    LastDeploymentNeeded     = 0
                    LastDeploymentPercentage = 0
                    LastStatus               = 'None'
                    LastTimestamp            = (Get-Date -AsUTC -Format 'o')
                    ConsecutiveSuccesses     = 0
                    CurrentPercentage        = (Read-FunctionAppSetting InitialDeploymentPercentage)
                    TargetSessionHostCount   = 0
                    LastImageVersion         = ''
                    LastTotalToReplace       = 0
                    PendingHostMappings      = '{}'
                }
            }
            else {
                throw $_
            }
        }
    }
    catch {
        Write-LogEntry -Message "Failed to retrieve deployment state: $_" -Level Error
        # Return default state on error
        return [PSCustomObject]@{
            LastDeploymentName       = ''
            LastDeploymentCount      = 0
            LastDeploymentNeeded     = 0
            LastDeploymentPercentage = 0
            LastStatus               = 'Error'
            LastTimestamp            = (Get-Date -AsUTC -Format 'o')
            ConsecutiveSuccesses     = 0
            CurrentPercentage        = (Read-FunctionAppSetting InitialDeploymentPercentage)
            TargetSessionHostCount   = 0
            LastImageVersion         = ''
            LastTotalToReplace       = 0
            PendingHostMappings      = '{}'
        }
    }
}

function Get-LastDeploymentStatus {
    <#
    .SYNOPSIS
        Checks the status of the last deployment from the previous function run.
    .DESCRIPTION
        Queries Azure Resource Manager to determine if the deployment from the previous
        run succeeded or failed. This allows the function to track deployment outcomes
        without polling synchronously, avoiding function timeout issues.
    .PARAMETER DeploymentName
        Name of the deployment to check.
    .PARAMETER ARMToken
        Azure Resource Manager access token.
    .PARAMETER ResourceManagerUri
        Resource Manager URI.
    .PARAMETER SubscriptionId
        Subscription ID containing the deployment.
    .PARAMETER ResourceGroupName
        Resource group name containing the deployment.
    .EXAMPLE
        $status = Get-LastDeploymentStatus -DeploymentName 'shr-abc123-20231230-120000' -ARMToken $token
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $DeploymentName,

        [Parameter(Mandatory = $true)]
        [string] $ARMToken,

        [Parameter()]
        [string] $ResourceManagerUri = (Get-ResourceManagerUri),

        [Parameter()]
        [string] $SubscriptionId = (Read-FunctionAppSetting VirtualMachinesSubscriptionId),

        [Parameter()]
        [string] $ResourceGroupName = (Read-FunctionAppSetting VirtualMachinesResourceGroupName)
    )

    if ([string]::IsNullOrEmpty($DeploymentName)) {
        Write-LogEntry -Message "No previous deployment name provided"
        return $null
    }

    try {
        $Uri = "$ResourceManagerUri/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Resources/deployments/$DeploymentName`?api-version=2021-04-01"
        Write-LogEntry -Message "Checking status of previous deployment: $DeploymentName" -Level Trace
        
        $deployment = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $Uri
        
        if ($deployment) {
            $provisioningState = $deployment.properties.provisioningState
            Write-LogEntry -Message "Previous deployment status: $provisioningState" -Level Trace
            
            $result = [PSCustomObject]@{
                DeploymentName   = $DeploymentName
                ProvisioningState = $provisioningState
                Succeeded        = $provisioningState -eq 'Succeeded'
                Failed           = $provisioningState -eq 'Failed'
                Running          = $provisioningState -in @('Running', 'Accepted')
                ErrorMessage     = $deployment.properties.error.message
                Timestamp        = $deployment.properties.timestamp
            }
            
            if ($result.Failed) {
                Write-LogEntry -Message "Previous deployment failed with error: $($result.ErrorMessage)" -Level Error
            }
            elseif ($result.Running) {
                Write-LogEntry -Message "Previous deployment is still running" -Level Warning
            }
            
            return $result
        }
        else {
            Write-LogEntry -Message "Previous deployment not found: $DeploymentName" -Level Warning
            return $null
        }
    }
    catch {
        Write-LogEntry -Message "Failed to check previous deployment status: $_" -Level Warning
        return $null
    }
}


function Save-DeploymentState {
    <#
    .SYNOPSIS
        Saves the deployment state to Azure Table Storage for progressive scale-up tracking.
    .DESCRIPTION
        Writes deployment history to the function app's storage account table to track
        consecutive successful deployments and update scale-up percentage.
    .PARAMETER DeploymentState
        The deployment state object to save.
    .PARAMETER HostPoolName
        Name of the host pool.
    .PARAMETER StorageAccountName
        Name of the storage account.
    .EXAMPLE
        Save-DeploymentState -DeploymentState $state -HostPoolName 'hp-prod-001'
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [PSCustomObject] $DeploymentState,
        
        [Parameter()]
        [string] $HostPoolName = (Read-FunctionAppSetting HostPoolName),
        
        [Parameter()]
        [string] $StorageAccountName,

        [Parameter()]
        [string] $ClientId = (Read-FunctionAppSetting UserAssignedIdentityClientId)
    )
    
    try {
        # Parse storage account name from AzureWebJobsStorage if not provided
        if (-not $StorageAccountName) {
            $storageUri = $env:AzureWebJobsStorage__blobServiceUri
            if ($storageUri -match 'https://([^.]+)\.') {
                $StorageAccountName = $Matches[1]
            }
            else {
                throw "Unable to determine storage account name from environment variables"
            }
        }
        
        $tableName = 'sessionHostDeploymentState'
        $partitionKey = $HostPoolName
        $rowKey = 'DeploymentState'
        $storageSuffix = $env:StorageSuffix
        $tableEndpoint = "https://$StorageAccountName.table.$storageSuffix"
        
        # Get storage access token using user-assigned managed identity
        # Storage tokens should NOT have trailing slash (fixed from original code which had trailing slash)
        $storageToken = Get-AccessToken -ResourceUri "https://$StorageAccountName.table.$storageSuffix" -ClientId $ClientId
        
        $headers = @{
            'Authorization'  = "Bearer $storageToken"
            'Accept'         = 'application/json;odata=nometadata'
            'x-ms-version'   = '2019-02-02'
            'x-ms-date'      = [DateTime]::UtcNow.ToString('R')
            'Content-Type'   = 'application/json'
        }
        
        # Check if table exists, create if not
        $tablesUri = "$tableEndpoint/Tables"
        try {
            $existingTables = Invoke-RestMethod -Uri $tablesUri -Headers $headers -Method Get -ContentType 'application/json' -ErrorAction SilentlyContinue
            $tableExists = $existingTables.value | Where-Object { $_.TableName -eq $tableName }
            
            if (-not $tableExists) {
                Write-LogEntry -Message "Creating deployment state table '$tableName'" -Level Trace
                $createTableBody = @{ TableName = $tableName } | ConvertTo-Json
                Invoke-RestMethod -Uri $tablesUri -Headers $headers -Method Post -Body $createTableBody -ErrorAction Stop | Out-Null
            }
        }
        catch {
            Write-LogEntry -Message "Error checking/creating table: $_" -Level Warning
        }
        
        # Prepare entity data
        $entityData = @{
            PartitionKey             = $partitionKey
            RowKey                   = $rowKey
            LastDeploymentName       = $DeploymentState.LastDeploymentName
            LastDeploymentCount      = $DeploymentState.LastDeploymentCount
            LastDeploymentNeeded     = $DeploymentState.LastDeploymentNeeded
            LastDeploymentPercentage = $DeploymentState.LastDeploymentPercentage
            LastStatus               = $DeploymentState.LastStatus
            LastTimestamp            = $DeploymentState.LastTimestamp
            ConsecutiveSuccesses     = $DeploymentState.ConsecutiveSuccesses
            CurrentPercentage        = $DeploymentState.CurrentPercentage
            TargetSessionHostCount   = $DeploymentState.TargetSessionHostCount
            PendingHostMappings      = if ($DeploymentState.PendingHostMappings) { $DeploymentState.PendingHostMappings } else { '{}' }
        }
        
        # Check if entity exists
        $entityUri = "$tableEndpoint/$tableName(PartitionKey='$partitionKey',RowKey='$rowKey')"
        $entityExists = $false
        
        try {
            Invoke-RestMethod -Uri $entityUri -Headers $headers -Method Get -ErrorAction Stop | Out-Null
            $entityExists = $true
        }
        catch {
            if ($_.Exception.Response.StatusCode -ne 404) {
                throw $_
            }
        }
        
        if ($entityExists) {
            # Update existing entity using MERGE
            $updateHeaders = $headers.Clone()
            $updateHeaders['If-Match'] = '*'
            $body = $entityData | ConvertTo-Json
            Invoke-RestMethod -Uri $entityUri -Headers $updateHeaders -Method Merge -Body $body -ErrorAction Stop | Out-Null
        }
        else {
            # Insert new entity
            $insertUri = "$tableEndpoint/$tableName"
            $body = $entityData | ConvertTo-Json
            Invoke-RestMethod -Uri $insertUri -Headers $headers -Method Post -Body $body -ErrorAction Stop | Out-Null
        }
        
        Write-LogEntry -Message "Saved deployment state: Status=$($DeploymentState.LastStatus), ConsecutiveSuccesses=$($DeploymentState.ConsecutiveSuccesses), NextPercentage=$($DeploymentState.CurrentPercentage)%" -Level Trace
    }
    catch {
        Write-LogEntry -Message "Failed to save deployment state: $_" -Level Error
    }
}

#EndRegion Progressive Scale-Up State Management

#Region Deployment Operations

function Deploy-SessionHosts {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $ARMToken,

        [Parameter()]
        [string] $ResourceManagerUri = (Get-ResourceManagerUri),

        [Parameter()]
        [string[]] $ExistingSessionHostNames = @(),

        [Parameter()]
        [string[]] $PreferredSessionHostNames = @(),

        [Parameter()]
        [hashtable] $PreferredHostProperties = @{},

        [Parameter(Mandatory = $true)]
        [int] $NewSessionHostsCount,

        [Parameter(Mandatory = $false)]
        [string] $HostPoolResourceGroupName = (Read-FunctionAppSetting HostPoolResourceGroupName),

        [Parameter()]
        [string] $HostPoolSubscriptionId = (Read-FunctionAppSetting HostPoolSubscriptionId),

        [Parameter()]
        [string] $VirtualMachinesSubscriptionId = (Read-FunctionAppSetting VirtualMachinesSubscriptionId),

        [Parameter()]
        [string] $VirtualMachinesResourceGroupName = (Read-FunctionAppSetting VirtualMachinesResourceGroupName),

        [Parameter()]
        [string] $HostPoolName = (Read-FunctionAppSetting HostPoolName),

        [Parameter()]
        [string] $SessionHostNamePrefix = (Read-FunctionAppSetting SessionHostNamePrefix),

        [Parameter()]
        [int] $SessionHostNameIndexLength = (Read-FunctionAppSetting SessionHostNameIndexLength),

        [Parameter()]
        [int] $MinimumHostIndex = (Read-FunctionAppSetting MinimumHostIndex),

        [Parameter()]
        [string] $DeploymentPrefix = (Read-FunctionAppSetting DeploymentPrefix),

        [Parameter()]
        [hashtable] $SessionHostParameters = (Read-FunctionAppSetting SessionHostParameters | ConvertTo-CaseInsensitiveHashtable),

        [Parameter()]
        [string] $SessionHostTemplate = (Read-FunctionAppSetting SessionHostTemplate),

        [Parameter()]
        [string] $TagIncludeInAutomation = (Read-FunctionAppSetting Tag_IncludeInAutomation),

        [Parameter()]
        [string] $TagDeployTimestamp = (Read-FunctionAppSetting Tag_DeployTimestamp),

        [Parameter()]
        [string] $TagScalingPlanExclusionTag = (Read-FunctionAppSetting Tag_ScalingPlanExclusionTag)
    )

    # Check if we have a valid token with sufficient time remaining
    Write-LogEntry -Message "Checking existing registration token for host pool $HostPoolName" -Level Trace
    
    try {
        $existingTokens = Invoke-AzureRestMethod `
            -ARMToken $ARMToken `
            -Method Post `
            -Uri ("$ResourceManagerUri/subscriptions/$HostPoolSubscriptionId/resourceGroups/$HostPoolResourceGroupName/providers/Microsoft.DesktopVirtualization/hostPools/$($HostPoolName)/listRegistrationTokens?api-version=2024-04-03")
        
        if ($existingTokens -and $existingTokens.expirationTime) {
            # Parse expiration time - Azure returns UTC datetime strings
            # Use RoundtripKind to properly parse timezone info (e.g., "2026-01-19T05:20:00.0000000Z")
            $tokenExpiration = [DateTime]::Parse($existingTokens.expirationTime, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
            
            # If timezone info wasn't in the string, assume UTC (Azure always returns UTC)
            if ($tokenExpiration.Kind -eq [System.DateTimeKind]::Unspecified) {
                $tokenExpiration = [DateTime]::SpecifyKind($tokenExpiration, [System.DateTimeKind]::Utc)
            }
            
            # Get current time in UTC
            $currentTimeUtc = [DateTime]::UtcNow
            
            # Calculate remaining time (both times now in UTC)
            $hoursRemaining = ($tokenExpiration - $currentTimeUtc).TotalHours
            
            if ($hoursRemaining -ge 2) {
                Write-LogEntry -Message "Existing registration token is valid for {0:F1} more hours - reusing token" -StringValues $hoursRemaining
                $skipTokenGeneration = $true
            }
            else {
                Write-LogEntry -Message "Existing token expires in {0:F1} hours (less than 2 hours) - generating new token" -StringValues $hoursRemaining -Level Trace
                $skipTokenGeneration = $false
            }
        }
        else {
            Write-LogEntry -Message "No valid token found - generating new token" -Level Trace
            $skipTokenGeneration = $false
        }
    }
    catch {
        Write-LogEntry -Message "Could not retrieve existing token: $($_.Exception.Message) - generating new token" -Level Trace
        $skipTokenGeneration = $false
    }
    
    # Generate new token if needed
    if (-not $skipTokenGeneration) {
        Write-LogEntry -Message "Generating new registration token for host pool $HostPoolName in Resource Group $HostPoolResourceGroupName"
        $Body = @{
            properties = @{
                registrationInfo = @{
                    expirationTime             = (Get-Date).AddHours(8)
                    registrationTokenOperation = 'Update'
                }
            }
        }
        
        try {
            $tokenResponse = Invoke-AzureRestMethod `
                -ARMToken $ARMToken `
                -Body ($Body | ConvertTo-Json -depth 10) `
                -Method Patch `
                -Uri ("$ResourceManagerUri/subscriptions/$HostPoolSubscriptionId/resourceGroups/$HostPoolResourceGroupName/providers/Microsoft.DesktopVirtualization/hostPools/$($HostPoolName)?api-version=2024-04-03")
            
            Write-LogEntry -Message "Successfully generated new registration token (expires in 8 hours)"
        }
        catch {
            Write-LogEntry -Message "Failed to generate registration token: $($_.Exception.Message)" -Level Error
            throw "Failed to generate registration token for host pool $HostPoolName. Error: $($_.Exception.Message)"
        }
    }
    
    # Calculate Session Host Names
    Write-LogEntry -Message "Existing session host VM names: {0}" -StringValues ($ExistingSessionHostNames -join ',')
    
    if ($PreferredSessionHostNames -and $PreferredSessionHostNames.Count -gt 0) {
        Write-LogEntry -Message "Preferred session host names for reuse: {0}" -StringValues ($PreferredSessionHostNames -join ',')
    }
    
    [array] $sessionHostNames = @()
    [array] $remainingPreferredNames = $PreferredSessionHostNames | Where-Object { $_ -notin $ExistingSessionHostNames }
    
    for ($i = 0; $i -lt $NewSessionHostsCount; $i++) {
        if ($remainingPreferredNames.Count -gt 0) {
            # Use preferred name first (from deleted hosts)
            $shName = $remainingPreferredNames[0]
            $remainingPreferredNames = $remainingPreferredNames | Select-Object -Skip 1
        }
        else {
            # Fall back to gap-filling logic starting from MinimumHostIndex
            $shNumber = $MinimumHostIndex
            While (("$SessionHostNamePrefix{0:d$SessionHostNameIndexLength}" -f $shNumber) -in $ExistingSessionHostNames) {
                $shNumber++
            }
            $shName = "$SessionHostNamePrefix{0:d$SessionHostNameIndexLength}" -f $shNumber
        }
        
        $ExistingSessionHostNames += $shName
        $sessionHostNames += $shName
    }
    
    Write-LogEntry -Message "Creating session host(s) $($sessionHostNames -join ', ')"

    # Update Session Host Parameters
    $sessionHostParameters['sessionHostNames'] = $sessionHostNames
    
    # Apply per-VM dedicated host properties if provided
    # Build arrays for dedicatedHostResourceId and dedicatedHostGroupResourceId indexed by VM
    if ($PreferredHostProperties.Count -gt 0) {
        Write-LogEntry -Message "Applying per-VM dedicated host properties from mapping"
        
        $dedicatedHostIds = @()
        $dedicatedHostGroupIds = @()
        $preferredZones = @()
        
        foreach ($vmName in $sessionHostNames) {
            if ($PreferredHostProperties.ContainsKey($vmName)) {
                $props = $PreferredHostProperties[$vmName]
                $dedicatedHostIds += if ($props.HostId) { $props.HostId } else { '' }
                $dedicatedHostGroupIds += if ($props.HostGroupId) { $props.HostGroupId } else { '' }
                $preferredZones += if ($props.Zones) { ,$props.Zones } else { ,@() }
                Write-LogEntry -Message "Applying dedicated host properties to {0}: HostId={1}, HostGroupId={2}, Zones={3}" -StringValues $vmName, $props.HostId, $props.HostGroupId, ($props.Zones -join ', ') -Level Trace
            }
            else {
                # Use empty string/array for VMs without specific assignments (will use template default)
                $dedicatedHostIds += ''
                $dedicatedHostGroupIds += ''
                $preferredZones += ,@()
            }
        }
        
        # Only set these parameters if we have at least one non-empty value
        $hasHostIds = $dedicatedHostIds | Where-Object { -not [string]::IsNullOrEmpty($_) }
        $hasHostGroupIds = $dedicatedHostGroupIds | Where-Object { -not [string]::IsNullOrEmpty($_) }
        $hasZones = $preferredZones | Where-Object { $_.Count -gt 0 }
        
        if ($hasHostIds) {
            $sessionHostParameters['dedicatedHostResourceIds'] = $dedicatedHostIds
            Write-LogEntry -Message "Set per-VM dedicatedHostResourceIds: {0}" -StringValues ($dedicatedHostIds -join ', ') -Level Trace
        }
        if ($hasHostGroupIds) {
            $sessionHostParameters['dedicatedHostGroupResourceIds'] = $dedicatedHostGroupIds
            Write-LogEntry -Message "Set per-VM dedicatedHostGroupResourceIds: {0}" -StringValues ($dedicatedHostGroupIds -join ', ') -Level Trace
        }
        if ($hasZones) {
            $sessionHostParameters['preferredZones'] = $preferredZones
            Write-LogEntry -Message "Set per-VM preferredZones: {0}" -StringValues (($preferredZones | ForEach-Object { "[$($_ -join ',')]" }) -join ', ') -Level Trace
        }
    }
    
    # Ensure Tags hashtable exists and has Microsoft.Compute/virtualMachines section
    if (-not $sessionHostParameters.ContainsKey('Tags') -or $null -eq $sessionHostParameters['Tags']) {
        $sessionHostParameters['Tags'] = @{}
    }
    if (-not $sessionHostParameters['Tags'].ContainsKey('Microsoft.Compute/virtualMachines') -or $null -eq $sessionHostParameters['Tags']['Microsoft.Compute/virtualMachines']) {
        $sessionHostParameters['Tags']['Microsoft.Compute/virtualMachines'] = @{}
    }
    
    # Add automation tags to VM resource type
    $sessionHostParameters['Tags']['Microsoft.Compute/virtualMachines'][$TagIncludeInAutomation] = $true
    $sessionHostParameters['Tags']['Microsoft.Compute/virtualMachines'][$TagDeployTimestamp] = (Get-Date -AsUTC -Format 'o')
    
    # Add scaling exclusion tag to protect newly deployed VMs from scaling plan shutdown during registration
    if ($TagScalingPlanExclusionTag -and $TagScalingPlanExclusionTag -ne ' ') {
        $sessionHostParameters['Tags']['Microsoft.Compute/virtualMachines'][$TagScalingPlanExclusionTag] = 'SessionHostReplacer'
        Write-LogEntry -Message "Setting scaling exclusion tag on newly deployed VMs to prevent scaling plan interference" -Level Trace
    }
    
    $deploymentTimestamp = Get-Date -AsUTC -Format 'yyyyMMddHHmmss'
    $deploymentName = "{0}_Count_{1}_VMs_{2}" -f $DeploymentPrefix, $sessionHostNames.count, $deploymentTimestamp
    
    Write-LogEntry -Message "Deployment name: $deploymentName"
    Write-LogEntry -Message "Deploying using Template Spec: $sessionHostTemplate"
    $templateSpecVersionResourceId = Get-TemplateSpecVersionResourceId -ARMToken $ARMToken -ResourceId $SessionHostTemplate

    Write-LogEntry -Message "Deploying $NewSessionHostsCount session host(s) to resource group $VirtualMachinesResourceGroupName" 
    
    # ARM deployment parameters need each value wrapped in a 'value' property
    $deploymentParameters = @{}
    foreach ($key in $sessionHostParameters.Keys) {
        $deploymentParameters[$key] = @{
            value = $sessionHostParameters[$key]
        }
    }
    
    $Body = @{
        properties = @{
            mode         = 'Incremental'
            parameters   = $deploymentParameters
            templateLink = @{
                id = $templateSpecVersionResourceId
            }
        }
    }
    $Uri = "$ResourceManagerUri/subscriptions/$VirtualMachinesSubscriptionId/resourceGroups/$VirtualMachinesResourceGroupName/providers/Microsoft.Resources/deployments/$($deploymentName)?api-version=2021-04-01"
    $DeploymentJob = Invoke-AzureRestMethod `
        -ARMToken $ARMToken `
        -Body ($Body | ConvertTo-Json -depth 20) `
        -Method Put `
        -Uri $Uri
    
    # Check if deployment submission was accepted
    if ($deploymentJob.Error) {
        Write-LogEntry -Message "Deployment submission failed: $($deploymentJob.Error)" -Level Error
        return [PSCustomObject]@{
            DeploymentName   = $deploymentName
            SessionHostCount = $NewSessionHostsCount
            Succeeded        = $false
            Timestamp        = $deploymentTimestamp
            ErrorMessage     = $deploymentJob.Error
        }
    }
    
    Write-LogEntry -Message "Deployment submitted successfully. Deployment name: $deploymentName" -Level Trace
    
    # Return deployment information for state tracking
    # Note: Succeeded is initially null - will be determined on next run
    return [PSCustomObject]@{
        DeploymentName   = $deploymentName
        SessionHostCount = $NewSessionHostsCount
        Succeeded        = $null  # Unknown until checked on next run
        Timestamp        = $deploymentTimestamp
        ErrorMessage     = $null
    }
}

function Get-Deployments {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $ARMToken,

        [Parameter()]
        [string] $ResourceManagerUri = (Get-ResourceManagerUri),

        [Parameter()]
        [string] $SubscriptionId = (Read-FunctionAppSetting VirtualMachinesSubscriptionId),

        [Parameter()]
        [string] $ResourceGroupName = (Read-FunctionAppSetting VirtualMachinesResourceGroupName),

        [Parameter()]
        [string] $DeploymentPrefix = (Read-FunctionAppSetting DeploymentPrefix),

        [Parameter()]
        [string] $HostPoolName = (Read-FunctionAppSetting HostPoolName)
    )

    Write-LogEntry -Message "Getting deployments for resource group '$ResourceGroupName'"
    $Uri = "$ResourceManagerUri/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Resources/deployments/?api-version=2021-04-01"
    $deployments = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $Uri
    
    # Filter by deployment prefix
    $deployments = $deployments | Where-Object { $_.name -like "$DeploymentPrefix*" }
    
    if ($deployments) {
        Write-LogEntry -Message "Deployment names: $($deployments.name -join ', ')" -Level Trace
    }
    
    # Handle failed deployments - don't block automation, but return info for cleanup
    $failedDeployments = $deployments | Where-Object { $_.properties.provisioningState -eq 'Failed' }
    if ($failedDeployments) {
        Write-LogEntry -Message "Found $($failedDeployments.Count) failed deployments. VMs from these deployments will be marked for cleanup." -Level Warning
        foreach ($failedDeploy in $failedDeployments) {
            if ($failedDeploy.properties.parameters) {
                $parameters = $failedDeploy.properties.parameters | ConvertTo-CaseInsensitiveHashtable
                $failedVMs = if ($parameters.ContainsKey('sessionHostNames')) { $parameters['sessionHostNames'].Value } else { @() }
                Write-LogEntry -Message "Failed deployment '$($failedDeploy.name)' attempted to deploy: $($failedVMs -join ',')" -Level Warning
            }
        }
    }
    
    $runningDeployments = $deployments | Where-Object { $_.properties.provisioningState -eq 'Running' }
    
    $warningThreshold = (Get-Date -AsUTC).AddHours(-2)
    $longRunningDeployments = $runningDeployments | Where-Object { 
        $_.properties.timestamp -and $_.properties.timestamp -lt $warningThreshold
    }
    if ($longRunningDeployments) {
        Write-LogEntry -Message "Found $($longRunningDeployments.Count) deployments that have been running for more than 2 hours. This could block future deployments" -Level Warning
    }

    # Return both running and failed deployments for proper handling
    $output = @{
        RunningDeployments = @()
        FailedDeployments  = @()
    }
    
    $output.RunningDeployments = foreach ($deployment in $runningDeployments) {
        if ($deployment.properties.parameters) {
            $parameters = $deployment.properties.parameters | ConvertTo-CaseInsensitiveHashtable
            Write-LogEntry -Message "Running deployment '$($deployment.name)' is deploying: $(($parameters['sessionHostNames'].Value -join ','))" -Level Trace
            [PSCustomObject]@{
                DeploymentName   = $deployment.name
                SessionHostNames = $parameters['sessionHostNames'].Value
                Timestamp        = $deployment.properties.timestamp
                Status           = $deployment.properties.provisioningState
            }
        }
        else {
            # Deployment has no parameters - still count it as running to prevent duplicates
            Write-LogEntry -Message "Running deployment '$($deployment.name)' has no parameters available - treating as running to prevent duplicate deployment"
            [PSCustomObject]@{
                DeploymentName   = $deployment.name
                SessionHostNames = @()
                Timestamp        = $deployment.properties.timestamp
                Status           = $deployment.properties.provisioningState
            }
        }
    }
    
    $output.FailedDeployments = foreach ($deployment in $failedDeployments) {
        if ($deployment.properties.parameters) {
            $parameters = $deployment.properties.parameters | ConvertTo-CaseInsensitiveHashtable
            [PSCustomObject]@{
                DeploymentName   = $deployment.name
                SessionHostNames = if ($parameters.ContainsKey('sessionHostNames')) { $parameters['sessionHostNames'].Value } else { @() }
                Timestamp        = $deployment.properties.timestamp
                Status           = $deployment.properties.provisioningState
            }
        }
        else {
            Write-LogEntry -Message "Failed deployment '$($deployment.name)' has no parameters available"
            [PSCustomObject]@{
                DeploymentName   = $deployment.name
                SessionHostNames = @()
                Timestamp        = $deployment.properties.timestamp
                Status           = $deployment.properties.provisioningState
            }
        }
    }
    
    return $output
}

function Get-TemplateSpecVersionResourceId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ARMToken,
        [Parameter()]
        [string]$ResourceManagerUri = (Get-ResourceManagerUri),
        [Parameter(Mandatory = $true)]
        [string]$ResourceId
    )
    $Uri = "$ResourceManagerUri$($ResourceId)?api-version=2022-02-01"    
    $response = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $Uri
    $azResourceType = $response.type
    Write-LogEntry -Message "Resource type: $azResourceType" -Level Trace
    switch ($azResourceType) {
        'Microsoft.Resources/templateSpecs' {
            # List all versions of the template spec
            $Uri = "$ResourceManagerUri$($ResourceId)/versions?api-version=2022-02-01"
            Write-LogEntry -Message "Calling API: $Uri" -Level Trace
            $templateSpecVersionsResponse = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $Uri
            
            # Invoke-AzureRestMethod returns an array directly (handles paging internally)
            # If there's only one version, it might be a single object; ensure it's an array
            if ($templateSpecVersionsResponse -is [array]) {
                $templateSpecVersions = $templateSpecVersionsResponse
            }
            else {
                $templateSpecVersions = @($templateSpecVersionsResponse)
            }
            
            if (-not $templateSpecVersions -or $templateSpecVersions.Count -eq 0) {
                Write-LogEntry -Message "No versions found in response" -Level Warning
                throw "No versions found for Template Spec: $ResourceId"
            }
            
            Write-LogEntry -Message "Template Spec has $($templateSpecVersions.count) versions" -Level Trace
            
            # Filter versions that have a lastModifiedAt timestamp in systemData and sort by it
            $versionsWithTime = $templateSpecVersions | Where-Object { $_.systemData.lastModifiedAt }
            
            if ($versionsWithTime -and $versionsWithTime.Count -gt 0) {
                # Sort by last modified time (most recent first)
                $latestVersion = $versionsWithTime | Sort-Object -Property { [DateTime]$_.systemData.lastModifiedAt } -Descending | Select-Object -First 1
                Write-LogEntry -Message "Latest version: $($latestVersion.name) Last modified at $($latestVersion.systemData.lastModifiedAt) - Returning Resource Id $($latestVersion.id)"
            }
            else {
                # Fallback: if no versions have lastModifiedAt, use version name sorting (assumes semantic versioning)
                Write-LogEntry -Message "No versions with systemData.lastModifiedAt found, sorting by version name" -Level Warning
                $latestVersion = $templateSpecVersions | Sort-Object -Property name -Descending | Select-Object -First 1
                Write-LogEntry -Message "Latest version: $($latestVersion.name) (sorted by name) - Returning Resource Id $($latestVersion.id)"
            }
            
            return $latestVersion.id
        }
        'Microsoft.Resources/templateSpecs/versions' {
            return $ResourceId
        }
        Default {
            throw ("Supplied value has type '{0}' is not a valid Template Spec or Template Spec version resource Id." -f $azResourceType)
        }
    }
}

function Remove-FailedDeploymentArtifacts {
    <#
    .SYNOPSIS
        Cleans up orphaned VMs and failed deployment records from previous failed deployments.
    
    .DESCRIPTION
        Checks for VMs from failed deployments that may not be registered as session hosts,
        deletes any orphaned VMs, and removes failed deployment records from ARM history.
        This prevents the function from getting stuck with repeated failures on the same VM names.
    
    .PARAMETER ARMToken
        The ARM access token for API calls.
    
    .PARAMETER GraphToken
        The Graph access token for device cleanup.
    
    .PARAMETER FailedDeployments
        Array of failed deployment objects from Get-Deployments.
    
    .PARAMETER RegisteredSessionHostNames
        Array of session host names currently registered in the host pool.
    
    .PARAMETER RemoveEntraDevice
        Whether to remove Entra device records.
    
    .PARAMETER RemoveIntuneDevice
        Whether to remove Intune device records.
    
    .EXAMPLE
        Remove-FailedDeploymentArtifacts -ARMToken $token -GraphToken $graphToken -FailedDeployments $failed -RegisteredSessionHostNames $sessionHosts.SessionHostName -RemoveEntraDevice $true -RemoveIntuneDevice $true
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $ARMToken,
        
        [Parameter()]
        [string] $GraphToken,
        
        [Parameter(Mandatory = $true)]
        [array] $FailedDeployments,
        
        [Parameter()]
        [array] $CachedVMs,
        
        [Parameter()]
        [array] $RegisteredSessionHostNames = @(),
        
        [Parameter()]
        [bool] $RemoveEntraDevice = $false,
        
        [Parameter()]
        [bool] $RemoveIntuneDevice = $false,
        
        [Parameter()]
        [string] $ResourceManagerUri = (Get-ResourceManagerUri),
        
        [Parameter()]
        [string] $VirtualMachinesSubscriptionId = (Read-FunctionAppSetting VirtualMachinesSubscriptionId),
        
        [Parameter()]
        [string] $VirtualMachinesResourceGroupName = (Read-FunctionAppSetting VirtualMachinesResourceGroupName)        
    )
    
    if ($FailedDeployments.Count -eq 0) {
        Write-LogEntry -Message "No failed deployments to clean up" -Level Trace
        return
    }
    
    Write-LogEntry -Message "Processing $($FailedDeployments.Count) failed deployments for cleanup"
    
    # Use cached VMs if provided, otherwise fetch
    if ($CachedVMs -and $CachedVMs.Count -gt 0) {
        Write-LogEntry -Message "Using cached VM data for orphaned VM check" -Level Trace
        $allVMs = $CachedVMs
    }
    else {
        $Uri = "$ResourceManagerUri/subscriptions/$VirtualMachinesSubscriptionId/resourceGroups/$VirtualMachinesResourceGroupName/providers/Microsoft.Compute/virtualMachines?api-version=2024-07-01"
        $allVMs = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $Uri
    }
    
    $orphanedVMs = @()
    $failedDeploymentNames = @()
    
    foreach ($deployment in $FailedDeployments) {
        $failedDeploymentNames += $deployment.DeploymentName
        
        foreach ($sessionHostName in $deployment.SessionHostNames) {
            # Session host name is like 'avdtest01use201', but actual VM could be:
            # - avdtest01use201 (no CAF naming)
            # - vm-avdtest01use201 (CAF prefix)
            # - avdtest01use201-vm (CAF suffix)
            # 
            # Strategy: Find VMs where the session host name is contained in the VM name
            
            $matchingVMs = $allVMs | Where-Object { $_.name -like "*$sessionHostName*" }
            
            foreach ($vm in $matchingVMs) {
                # Check if this VM is registered as a session host
                $isRegistered = $RegisteredSessionHostNames | Where-Object { $_ -like "$sessionHostName*" }
                
                if (-not $isRegistered) {
                    Write-LogEntry -Message "Found orphaned VM from failed deployment: $($vm.name) (matches session host name $sessionHostName but not registered)" -Level Warning
                    $orphanedVMs += [PSCustomObject]@{
                        Name           = $vm.name
                        ResourceId     = $vm.id
                        DeploymentName = $deployment.DeploymentName
                        SessionHostName = $sessionHostName
                    }
                }
                else {
                    Write-LogEntry -Message "VM $($vm.name) from failed deployment is registered as session host - will be handled by normal cleanup flow" -Level Trace
                }
            }
            
            if ($matchingVMs.Count -eq 0) {
                Write-LogEntry -Message "No VM found matching session host name $sessionHostName (deployment may have rolled back)" -Level Trace
            }
        }
    }
    
    # Delete orphaned VMs and their device records
    if ($orphanedVMs.Count -gt 0) {
        Write-LogEntry -Message "Deleting $($orphanedVMs.Count) orphaned VMs from failed deployments"
        
        foreach ($orphanedVM in $orphanedVMs) {
            try {
                # Delete Entra device if enabled
                if ($RemoveEntraDevice -and $GraphToken) {
                    try {
                        $graphEndpoint = Get-GraphEndpoint
                        $deviceUri = "$graphEndpoint/v1.0/devices?`$filter=displayName eq '$($orphanedVM.SessionHostName)'"
                        $device = Invoke-GraphRestMethod -GraphToken $GraphToken -Method Get -Uri $deviceUri
                        
                        if ($device -and $device.Count -gt 0) {
                            $deviceId = $device[0].id
                            $deleteDeviceUri = "$graphEndpoint/v1.0/devices/$deviceId"
                            Invoke-GraphRestMethod -GraphToken $GraphToken -Method DELETE -Uri $deleteDeviceUri
                            Write-LogEntry -Message "Successfully deleted Entra device for orphaned VM: $($orphanedVM.SessionHostName)"
                        }
                        else {
                            Write-LogEntry -Message "No Entra device found for orphaned VM: $($orphanedVM.SessionHostName)" -Level Trace
                        }
                    }
                    catch {
                        Write-LogEntry -Message "Failed to delete Entra device for $($orphanedVM.SessionHostName): $_" -Level Warning
                    }
                }
                
                # Delete Intune device if enabled
                if ($RemoveIntuneDevice -and $GraphToken) {
                    try {
                        $graphEndpoint = Get-GraphEndpoint
                        $deviceUri = "$graphEndpoint/v1.0/deviceManagement/managedDevices?`$filter=deviceName eq '$($orphanedVM.SessionHostName)'"
                        $device = Invoke-GraphRestMethod -GraphToken $GraphToken -Method Get -Uri $deviceUri
                        
                        if ($device -and $device.Count -gt 0) {
                            $deviceId = $device[0].id
                            $deleteDeviceUri = "$graphEndpoint/v1.0/deviceManagement/managedDevices/$deviceId"
                            Invoke-GraphRestMethod -GraphToken $GraphToken -Method DELETE -Uri $deleteDeviceUri
                            Write-LogEntry -Message "Successfully deleted Intune device for orphaned VM: $($orphanedVM.SessionHostName)"
                        }
                        else {
                            Write-LogEntry -Message "No Intune device found for orphaned VM: $($orphanedVM.SessionHostName)" -Level Trace
                        }
                    }
                    catch {
                        Write-LogEntry -Message "Failed to delete Intune device for $($orphanedVM.SessionHostName): $_" -Level Warning
                    }
                }
                
                # Delete the VM
                Write-LogEntry -Message "Deleting orphaned VM: $($orphanedVM.Name) (session host: $($orphanedVM.SessionHostName), from deployment: $($orphanedVM.DeploymentName))" -Level Warning
                $Uri = "$ResourceManagerUri$($orphanedVM.ResourceId)?forceDeletion=true&api-version=2024-07-01"
                Invoke-AzureRestMethod -ARMToken $ARMToken -Method DELETE -Uri $Uri
                Write-LogEntry -Message "Successfully deleted orphaned VM: $($orphanedVM.Name)"
            }
            catch {
                Write-LogEntry -Message "Failed to delete orphaned VM $($orphanedVM.Name): $_" -Level Error
            }
        }
    }
    else {
        Write-LogEntry -Message "No orphaned VMs found from failed deployments" -Level Trace
    }
    
    # Clean up failed deployment records from ARM (including nested deployments)
    Write-LogEntry -Message "Cleaning up $($failedDeploymentNames.Count) failed deployment records from ARM history"
    
    foreach ($deploymentName in $failedDeploymentNames) {
        try {
            # Recursively find all nested deployments
            function Get-NestedDeployments {
                param(
                    [string]$DeploymentName,
                    [string]$ARMToken,
                    [string]$ResourceManagerUri,
                    [string]$SubscriptionId,
                    [string]$ResourceGroupName
                )
                
                $allNested = @()
                
                try {
                    # Get this deployment's details
                    $Uri = "$ResourceManagerUri/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Resources/deployments/$DeploymentName`?api-version=2021-04-01"
                    $deployment = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $Uri
                    
                    if ($deployment -and $deployment.properties.dependencies) {
                        # Extract nested deployment names from dependencies
                        $nestedNames = $deployment.properties.dependencies | 
                            Where-Object { $_.resourceType -eq 'Microsoft.Resources/deployments' } |
                            ForEach-Object { $_.resourceName }
                        
                        if ($nestedNames) {
                            foreach ($nestedName in $nestedNames) {
                                # Add this nested deployment
                                $allNested += $nestedName
                                
                                # Recursively get its nested deployments
                                $childNested = Get-NestedDeployments -DeploymentName $nestedName -ARMToken $ARMToken -ResourceManagerUri $ResourceManagerUri -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName
                                $allNested += $childNested
                            }
                        }
                    }
                }
                catch {
                    Write-LogEntry -Message "Warning: Could not retrieve nested deployments for $DeploymentName : $_" -Level Warning
                }
                
                return $allNested
            }
            
            # Get all nested deployments recursively
            $allNestedDeployments = Get-NestedDeployments -DeploymentName $deploymentName -ARMToken $ARMToken -ResourceManagerUri $ResourceManagerUri -SubscriptionId $VirtualMachinesSubscriptionId -ResourceGroupName $VirtualMachinesResourceGroupName
            
            if ($allNestedDeployments) {
                Write-LogEntry -Message "Found $($allNestedDeployments.Count) nested deployment(s) (including recursive nesting) from parent deployment"
                
                # Delete nested deployments in reverse order (deepest first to avoid dependency issues)
                [array]::Reverse($allNestedDeployments)
                
                foreach ($nestedDeploymentName in $allNestedDeployments) {
                    try {
                        Write-LogEntry -Message "Deleting nested deployment record: $nestedDeploymentName" -Level Trace
                        $Uri = "$ResourceManagerUri/subscriptions/$VirtualMachinesSubscriptionId/resourceGroups/$VirtualMachinesResourceGroupName/providers/Microsoft.Resources/deployments/$nestedDeploymentName`?api-version=2021-04-01"
                        Invoke-AzureRestMethod -ARMToken $ARMToken -Method DELETE -Uri $Uri
                        Write-LogEntry -Message "Successfully deleted nested deployment record: $nestedDeploymentName" -Level Trace
                    }
                    catch {
                        Write-LogEntry -Message "Failed to delete nested deployment record $nestedDeploymentName`: $_" -Level Warning
                    }
                }
            }
            else {
                Write-LogEntry -Message "No nested deployments found for parent deployment" -Level Trace
            }
            
            # Delete the top-level deployment record last
            Write-LogEntry -Message "Deleting top-level deployment record: $deploymentName"
            $Uri = "$ResourceManagerUri/subscriptions/$VirtualMachinesSubscriptionId/resourceGroups/$VirtualMachinesResourceGroupName/providers/Microsoft.Resources/deployments/$deploymentName`?api-version=2021-04-01"
            Invoke-AzureRestMethod -ARMToken $ARMToken -Method DELETE -Uri $Uri
            Write-LogEntry -Message "Successfully deleted deployment record: $deploymentName"
        }
        catch {
            Write-LogEntry -Message "Failed to delete deployment record $deploymentName`: $_" -Level Warning
        }
    }
    
    Write-LogEntry -Message "Failed deployment cleanup completed"
}

#EndRegion Deployment Operations

# Export functions
Export-ModuleMember -Function Get-DeploymentState, Get-LastDeploymentStatus, Save-DeploymentState, Deploy-SessionHosts, Get-Deployments, Get-TemplateSpecVersionResourceId, Remove-FailedDeploymentArtifacts
