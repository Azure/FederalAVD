# SessionHostReplacer PowerShell Module
# This module contains all helper functions for AVD Session Host Replacer

# Import Core utilities module
Import-Module "$PSScriptRoot\SessionHostReplacer.Core.psm1" -Force

#Region Progressive Scale-Up State Management

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
        Write-LogEntry -Message "Checking status of previous deployment: $DeploymentName" -Level Verbose
        
        $deployment = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $Uri
        
        if ($deployment) {
            $provisioningState = $deployment.properties.provisioningState
            Write-LogEntry -Message "Previous deployment status: $provisioningState" -Level Verbose
            
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
                Write-LogEntry -Message "Creating deployment state table '$tableName'" -Level Verbose
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
            
            Write-LogEntry -Message "Retrieved deployment state: ConsecutiveSuccesses=$($entity.ConsecutiveSuccesses), CurrentPercentage=$($entity.CurrentPercentage)%" -Level Verbose
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
                Write-LogEntry -Message "No deployment state found, initializing new state" -Level Verbose
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
                Write-LogEntry -Message "Creating deployment state table '$tableName'" -Level Verbose
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
        
        Write-LogEntry -Message "Saved deployment state: Status=$($DeploymentState.LastStatus), ConsecutiveSuccesses=$($DeploymentState.ConsecutiveSuccesses), NextPercentage=$($DeploymentState.CurrentPercentage)%" -Level Verbose
    }
    catch {
        Write-LogEntry -Message "Failed to save deployment state: $_" -Level Error
    }
}

#EndRegion Progressive Scale-Up State Management

#Region Utility Functions

function ConvertTo-CaseInsensitiveHashtable {
    <#
    .SYNOPSIS
        Converts objects to case-insensitive hashtables.
    .DESCRIPTION
        Converts hashtables, PSCustomObjects, OrderedDictionaries, and JSON strings to case-insensitive hashtables.
    .PARAMETER InputObject
        The object to convert.
    .EXAMPLE
        $params = @{Name='Test'; Value='123'} | ConvertTo-CaseInsensitiveHashtable
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        $InputObject
    )
    
    process {
        if ($null -eq $InputObject) {
            return $null
        }
        
        # If already a hashtable, convert to case-insensitive
        if ($InputObject -is [hashtable]) {
            $ciHashtable = New-Object 'System.Collections.Hashtable' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($key in $InputObject.Keys) {
                $value = $InputObject[$key]
                # Recursively convert nested hashtables
                if ($value -is [hashtable] -or $value -is [PSCustomObject]) {
                    $ciHashtable[$key] = ConvertTo-CaseInsensitiveHashtable -InputObject $value
                }
                else {
                    $ciHashtable[$key] = $value
                }
            }
            return $ciHashtable
        }
        
        # If PSCustomObject or OrderedDictionary, convert to case-insensitive hashtable
        if ($InputObject -is [PSCustomObject] -or $InputObject -is [System.Collections.Specialized.OrderedDictionary]) {
            $ciHashtable = New-Object 'System.Collections.Hashtable' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($property in $InputObject.PSObject.Properties) {
                $value = $property.Value
                # Recursively convert nested objects
                if ($value -is [hashtable] -or $value -is [PSCustomObject]) {
                    $ciHashtable[$property.Name] = ConvertTo-CaseInsensitiveHashtable -InputObject $value
                }
                else {
                    $ciHashtable[$property.Name] = $value
                }
            }
            return $ciHashtable
        }
        
        # If JSON string, parse and convert
        if ($InputObject -is [string]) {
            try {
                $parsed = $InputObject | ConvertFrom-Json
                return ConvertTo-CaseInsensitiveHashtable -InputObject $parsed
            }
            catch {
                Write-Error "Unable to parse string as JSON: $_"
                return $null
            }
        }
        
        # Return as-is if cannot convert
        Write-Warning "InputObject type [$($InputObject.GetType().Name)] cannot be converted to case-insensitive hashtable"
        return $InputObject
    }
}

#EndRegion Utility Functions

#Region Session Host Lifecycle Functions

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
        [string] $TagDeployTimestamp = (Read-FunctionAppSetting Tag_DeployTimestamp)
    )

    Write-LogEntry -Message "Generating new token for the host pool $HostPoolName in Resource Group $HostPoolResourceGroupName"
    $Body = @{
        properties = @{
            registrationInfo = @{
                expirationTime             = (Get-Date).AddHours(8)
                registrationTokenOperation = 'Update'
            }
        }
    }
    Invoke-AzureRestMethod `
        -ARMToken $ARMToken `
        -Body ($Body | ConvertTo-Json -depth 10) `
        -Method Patch `
        -Uri ("$ResourceManagerUri/subscriptions/$HostPoolSubscriptionId/resourceGroups/$HostPoolResourceGroupName/providers/Microsoft.DesktopVirtualization/hostPools/$($HostPoolName)?api-version=2024-04-03") | Out-Null
    
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
                Write-LogEntry -Message "Applying dedicated host properties to {0}: HostId={1}, HostGroupId={2}, Zones={3}" -StringValues $vmName, $props.HostId, $props.HostGroupId, ($props.Zones -join ', ') -Level Verbose
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
            Write-LogEntry -Message "Set per-VM dedicatedHostResourceIds: {0}" -StringValues ($dedicatedHostIds -join ', ') -Level Verbose
        }
        if ($hasHostGroupIds) {
            $sessionHostParameters['dedicatedHostGroupResourceIds'] = $dedicatedHostGroupIds
            Write-LogEntry -Message "Set per-VM dedicatedHostGroupResourceIds: {0}" -StringValues ($dedicatedHostGroupIds -join ', ') -Level Verbose
        }
        if ($hasZones) {
            $sessionHostParameters['preferredZones'] = $preferredZones
            Write-LogEntry -Message "Set per-VM preferredZones: {0}" -StringValues (($preferredZones | ForEach-Object { "[$($_ -join ',')]" }) -join ', ') -Level Verbose
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
    
    $deploymentTimestamp = Get-Date -AsUTC -Format 'yyyyMMddHHmmss'
    $deploymentName = "{0}_Count_{1}_VMs_{2}" -f $DeploymentPrefix, $sessionHostNames.count, $deploymentTimestamp
    
    Write-LogEntry -Message "Deployment name: $deploymentName"
    Write-LogEntry -Message "Deploying using Template Spec: $sessionHostTemplate"
    $templateSpecVersionResourceId = Get-TemplateSpecVersionResourceId -ARMToken $ARMToken -ResourceId $SessionHostTemplate

    Write-LogEntry -Message "Deploying $NewSessionHostCount session host(s) to resource group $VirtualMachinesResourceGroupName" 
    
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
    
    Write-LogEntry -Message "Deployment submitted successfully. Deployment name: $deploymentName" -Level Verbose
    
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

function Compare-ImageVersion {
    <#
    .SYNOPSIS
    Compares two image versions to determine their relative order.
    
    .DESCRIPTION
    Compares two image versions using semantic versioning rules (major.minor.patch).
    Returns:
        -1 if version1 < version2
         0 if version1 = version2
         1 if version1 > version2
    
    .PARAMETER Version1
    The first version to compare.
    
    .PARAMETER Version2
    The second version to compare.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $Version1,
        
        [Parameter(Mandatory = $true)]
        [string] $Version2
    )
    
    # If versions are identical strings, return equal
    if ($Version1 -eq $Version2) {
        return 0
    }
    
    try {
        # Try to parse as semantic versions (e.g., 1.0.0, 2.1.3)
        $v1Parts = $Version1 -split '\.' | ForEach-Object { 
            $num = 0
            if ([int]::TryParse($_, [ref]$num)) { $num } else { 0 }
        }
        $v2Parts = $Version2 -split '\.' | ForEach-Object { 
            $num = 0
            if ([int]::TryParse($_, [ref]$num)) { $num } else { 0 }
        }
        
        # Pad arrays to same length with zeros
        $maxLength = [Math]::Max($v1Parts.Count, $v2Parts.Count)
        while ($v1Parts.Count -lt $maxLength) { $v1Parts += 0 }
        while ($v2Parts.Count -lt $maxLength) { $v2Parts += 0 }
        
        # Compare each part
        for ($i = 0; $i -lt $maxLength; $i++) {
            if ($v1Parts[$i] -lt $v2Parts[$i]) {
                return -1
            }
            elseif ($v1Parts[$i] -gt $v2Parts[$i]) {
                return 1
            }
        }
        
        # All parts equal
        return 0
    }
    catch {
        # If parsing fails, fall back to string comparison
        Write-LogEntry -Message "Failed to parse versions as semantic versions, using string comparison: $_" -Level Warning
        if ($Version1 -lt $Version2) { return -1 }
        elseif ($Version1 -gt $Version2) { return 1 }
        else { return 0 }
    }
}

function Get-LatestImageVersion {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $ARMToken,

        [Parameter()]
        [string] $ResourceManagerUri = (Get-ResourceManagerUri),

        [Parameter()]
        [string] $SubscriptionId = (Read-FunctionAppSetting VirtualMachinesSubscriptionId),

        [Parameter()]
        [hashtable] $ImageReference,

        [Parameter()]
        [string] $Location
    )

    # Initialize variables
    $azImageVersion = $null
    $azImageDate = $null
    $azImageDefinition = $null
    
    # Marketplace image
    if ($ImageReference.publisher) {
        # Set marketplace image definition for both latest and specific versions
        $azImageDefinition = "marketplace:$($ImageReference.publisher)/$($ImageReference.offer)/$($ImageReference.sku)"
        
        if ($null -ne $ImageReference.version -and $ImageReference.version -ne 'latest') {
            Write-LogEntry  "Image version is not set to latest. Returning version '$($ImageReference.version)'"
            $azImageVersion = $ImageReference.version
            # For specific marketplace versions, use current date as fallback since we can't determine actual publish date
            $azImageDate = Get-Date -AsUTC
        }
        else {
            Write-LogEntry -Message "Getting latest version of image publisher: $($ImageReference.publisher), offer: $($ImageReference.offer), sku: $($ImageReference.sku) in region: $($Location)"
                      
            $Uri = "$ResourceManagerUri/subscriptions/$SubscriptionId/providers/Microsoft.Compute/locations/$Location/publishers/$($ImageReference.publisher)/artifacttypes/vmimage/offers/$($ImageReference.offer)/skus/$($ImageReference.sku)/versions?api-version=2024-07-01"
            
            $response = Invoke-AzureRestMethod -ARMToken $ARMToken -Uri $Uri -Method Get
            $Versions = @($response)
            
            if (-not $Versions -or $Versions.Count -eq 0) {
                throw "No image versions found for publisher: $($ImageReference.publisher), offer: $($ImageReference.offer), sku: $($ImageReference.sku)"
            }
            
            Write-LogEntry -Message "Found $($Versions.Count) image versions"
            
            # Sort versions and get the latest (sort by name as string since version format may have 4 components)
            $latestVersion = $Versions | Sort-Object -Property name -Descending | Select-Object -First 1
            
            if ($null -eq $latestVersion) {
                throw "Failed to sort and select latest version from API response"
            }
            
            $azImageVersion = $latestVersion.name
            
            if (-not $azImageVersion) {
                throw "Could not extract version name from latest image version object"
            }
            
            Write-LogEntry -Message "Latest version of image is $azImageVersion" -Level Verbose

            if ($azImageVersion -match "\d+\.\d+\.(?<Year>\d{2})(?<Month>\d{2})(?<Day>\d{2})") {
                $azImageDate = Get-Date -Date ("20{0}-{1}-{2}" -f $Matches.Year, $Matches.Month, $Matches.Day)
                Write-LogEntry  "Image date is $azImageDate"
            }
            else {
                throw "Image version does not match expected format. Could not extract image date."
            }
        }
    }
    elseif ($ImageReference.id) {
        Write-LogEntry -Message "Image is from Shared Image Gallery: $($ImageReference.id)"
        $imageDefinitionResourceIdPattern = '^\/subscriptions\/(?<subscription>[a-z0-9\-]+)\/resourceGroups\/(?<resourceGroup>[^\/]+)\/providers\/Microsoft\.Compute\/galleries\/(?<gallery>[^\/]+)\/images\/(?<image>[^\/]+)$'
        $imageVersionResourceIdPattern = '^\/subscriptions\/(?<subscription>[a-z0-9\-]+)\/resourceGroups\/(?<resourceGroup>[^\/]+)\/providers\/Microsoft\.Compute\/galleries\/(?<gallery>[^\/]+)\/images\/(?<image>[^\/]+)\/versions\/(?<version>[^\/]+)$'
        if ($ImageReference.id -match $imageDefinitionResourceIdPattern) {
            Write-LogEntry 'Image reference is an Image Definition resource.'
            $imageSubscriptionId = $Matches.subscription
            $imageResourceGroup = $Matches.resourceGroup
            $imageGalleryName = $Matches.gallery
            $imageDefinitionName = $Matches.image
            
            # Store the image definition resource ID for tracking
            $azImageDefinition = $ImageReference.id

            $Uri = "$ResourceManagerUri/subscriptions/$imageSubscriptionId/resourceGroups/$imageResourceGroup/providers/Microsoft.Compute/galleries/$imageGalleryName/images/$imageDefinitionName/versions?api-version=2023-07-03"
            $imageVersions = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $Uri
            
            if (-not $imageVersions -or $imageVersions.Count -eq 0) {
                throw "No image versions found in gallery '$imageGalleryName' for image '$imageDefinitionName'."
            }
            
            Write-LogEntry -Message "Found $($imageVersions.Count) total image versions in gallery" -Level Verbose
            
            # Normalize location for comparison (Azure returns full names like "East US 2")
            $normalizedLocation = $Location -replace '\s', ''
            
            # Filter out versions marked as excluded from latest (checking both global AND regional flags)
            # Azure VM deployments respect the regional flag when using image definition without version
            $validVersions = $imageVersions |
            Where-Object { 
                $globalExclude = $_.properties.publishingProfile.excludeFromLatest
                $regionalExclude = $false
                
                # Check if this version is excluded in the target region
                $targetRegion = $_.properties.publishingProfile.targetRegions | Where-Object { 
                    ($_.name -replace '\s', '') -eq $normalizedLocation 
                }
                if ($targetRegion) {
                    $regionalExclude = $targetRegion.excludeFromLatest
                }
                
                # Include only if NOT excluded globally AND NOT excluded regionally AND has published date
                -not $globalExclude -and -not $regionalExclude -and $_.properties.publishingProfile.publishedDate
            }
            
            if (-not $validVersions -or $validVersions.Count -eq 0) {
                # Fallback: if no versions have dates, just get the first non-excluded version
                $latestImageVersion = $imageVersions |
                Where-Object { -not $_.properties.publishingProfile.excludeFromLatest } |
                Select-Object -First 1
                
                if (-not $latestImageVersion) {
                    throw "No available image versions found (all versions are marked as excluded from latest)."
                }
                
                Write-LogEntry -Message "Selected image version (no published dates available) with resource Id {0}" -StringValues $latestImageVersion.id -Level Warning
                $azImageVersion = $latestImageVersion.name
                $azImageDate = Get-Date -AsUTC
            }
            else {
                # Sort by published date and select latest
                $latestImageVersion = $validVersions |
                Sort-Object -Property { [DateTime]$_.properties.publishingProfile.publishedDate } -Descending |
                Select-Object -First 1
                
                Write-LogEntry -Message "Selected image version with resource Id {0} (most recent non-excluded version)" -StringValues $latestImageVersion.id
                $azImageVersion = $latestImageVersion.name
                $azImageDate = [DateTime]$latestImageVersion.properties.publishingProfile.publishedDate
                Write-LogEntry -Message "Image version is {0} and date is {1}" -StringValues $azImageVersion, $azImageDate.ToString('o')
            }
        }
        elseif ($ImageReference.id -match $imageVersionResourceIdPattern ) {
            Write-LogEntry 'Image reference is an Image Version resource.'
            # Extract image definition path (without version)
            if ($ImageReference.id -match '^(?<definition>.+)/versions/[^/]+$') {
                $azImageDefinition = $Matches['definition']
            }
            $Uri = "$ResourceManagerUri$($ImageReference.id)?api-version=2023-07-03"
            $imageVersion = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $Uri
            $azImageVersion = $imageVersion.name
            
            # Parse published date with null check
            if ($imageVersion.properties.publishingProfile.publishedDate) {
                $azImageDate = [DateTime]$imageVersion.properties.publishingProfile.publishedDate
                Write-LogEntry -Message "Image version is {0} and date is {1}" -StringValues $azImageVersion, $azImageDate.ToString('o')
            } else {
                # Fallback to current date if published date not available
                $azImageDate = Get-Date -AsUTC
                Write-LogEntry -Message "Image version is {0} (published date not available, using current date)" -StringValues $azImageVersion -Level Warning
            }
        }
        else {
            throw "Image reference id does not match expected format for an Image Definition resource."
        }
    }
    else {
        throw "Image reference does not contain a publisher or id property. ImageReference, publisher, and id are case sensitive!!"
    }
    return [PSCustomObject]@{
        Version    = $azImageVersion
        Date       = $azImageDate
        Definition = $azImageDefinition
    }
}

function Get-HostPoolDecisions {
    [CmdletBinding()]
    param (
        [Parameter()]
        [array] $SessionHosts = @(),
        [Parameter()]
        $RunningDeployments,
        [Parameter()]
        [string] $HostPoolName = (Read-FunctionAppSetting HostPoolName),
        [Parameter()]
        [int] $TargetSessionHostCount = (Read-FunctionAppSetting TargetSessionHostCount),
        [Parameter()]
        [PSCustomObject] $LatestImageVersion,
        [Parameter()]
        [int] $ReplaceSessionHostOnNewImageVersionDelayDays = [int]::Parse((Read-FunctionAppSetting ReplaceSessionHostOnNewImageVersionDelayDays)),
        [Parameter()]
        [bool] $AllowImageVersionRollback = $false,
        [Parameter()]
        [bool] $EnableProgressiveScaleUp = [bool]::Parse((Read-FunctionAppSetting EnableProgressiveScaleUp)),
        [Parameter()]
        [int] $InitialDeploymentPercentage = [int]::Parse((Read-FunctionAppSetting InitialDeploymentPercentage)),
        [Parameter()]
        [int] $ScaleUpIncrementPercentage = [int]::Parse((Read-FunctionAppSetting ScaleUpIncrementPercentage)),
        [Parameter()]
        [int] $MaxDeploymentBatchSize = $(
            $setting = Read-FunctionAppSetting MaxDeploymentBatchSize
            if ([string]::IsNullOrEmpty($setting)) { 100 } else { [int]::Parse($setting) }
        ),
        [Parameter()]
        [int] $SuccessfulRunsBeforeScaleUp = [int]::Parse((Read-FunctionAppSetting SuccessfulRunsBeforeScaleUp)),
        [Parameter()]
        [string] $ReplacementMode = (Read-FunctionAppSetting ReplacementMode),
        [Parameter()]
        [int] $DrainGracePeriodHours = [int]::Parse((Read-FunctionAppSetting DrainGracePeriodHours)),
        [Parameter()]
        [int] $MinimumCapacityPercentage = [int]::Parse((Read-FunctionAppSetting MinimumCapacityPercentage)),
        [Parameter()]
        [int] $MaxDeletionsPerCycle = $(
            $setting = Read-FunctionAppSetting MaxDeletionsPerCycle
            if ([string]::IsNullOrEmpty($setting)) { 5 } else { [int]::Parse($setting) }
        )
    )
    
    Write-LogEntry -Message "We have $($SessionHosts.Count) session hosts (included in Automation)"
    
    # Auto-detect target count if not specified (TargetSessionHostCount = 0)
    if ($TargetSessionHostCount -eq 0) {
        # Get deployment state to check for stored target
        try {
            $deploymentState = Get-DeploymentState -HostPoolName $HostPoolName
            
            if ($deploymentState.TargetSessionHostCount -gt 0) {
                # Use previously stored target from ongoing replacement cycle
                $TargetSessionHostCount = $deploymentState.TargetSessionHostCount
                Write-LogEntry -Message "Auto-detect mode: Using stored target count of $TargetSessionHostCount from current replacement cycle"
            } else {
                # First run of a new replacement cycle - store current count as target
                $TargetSessionHostCount = $SessionHosts.Count
                $deploymentState.TargetSessionHostCount = $TargetSessionHostCount
                Save-DeploymentState -DeploymentState $deploymentState -HostPoolName $HostPoolName
                Write-LogEntry -Message "Auto-detect mode: Detected $TargetSessionHostCount session hosts - storing as target for this replacement cycle"
            }
        }
        catch {
            # If state storage fails, fall back to current count (stateless mode)
            $TargetSessionHostCount = $SessionHosts.Count
            Write-LogEntry -Message "Auto-detect mode: Unable to access deployment state storage. Using current count of $TargetSessionHostCount. Note: Managed identity needs 'Storage Table Data Contributor' role on storage account for persistent target tracking. Error: $_" -Level Warning
        }
    }
    
    # Determine which session hosts need replacement based on image version
    [array] $sessionHostsOldVersion = @()
    
    $latestImageAge = (New-TimeSpan -Start $LatestImageVersion.Date -End (Get-Date -AsUTC)).TotalDays
    Write-LogEntry -Message "Latest Image $($LatestImageVersion.Version) is $latestImageAge days old."
    if ($latestImageAge -ge $ReplaceSessionHostOnNewImageVersionDelayDays) {
            Write-LogEntry -Message "Latest Image age is older than (or equal) New Image Delay value $ReplaceSessionHostOnNewImageVersionDelayDays"
            
            # Log each session host's image version for debugging
            foreach ($sh in $sessionHosts) {
                Write-LogEntry -Message "Session host $($sh.SessionHostName) has image version: $($sh.ImageVersion)" -Level Verbose
            }
            
            # Compare versions with rollback protection
            [array] $sessionHostsOldVersion = @()
            foreach ($sh in $sessionHosts) {
                if ($sh.ImageVersion -ne $LatestImageVersion.Version) {
                    # Check if image definition has changed
                    $imageDefinitionChanged = $false
                    if ($sh.ImageDefinition -and $LatestImageVersion.Definition) {
                        $imageDefinitionChanged = ($sh.ImageDefinition -ne $LatestImageVersion.Definition)
                        if ($imageDefinitionChanged) {
                            Write-LogEntry -Message "Session host $($sh.SessionHostName) has different image definition - VM: '$($sh.ImageDefinition)', Latest: '$($LatestImageVersion.Definition)'" -Level Verbose
                        }
                    }
                    
                    if ($imageDefinitionChanged) {
                        # Image definition changed - this is a legitimate upgrade, not a rollback
                        $sessionHostsOldVersion += $sh
                    }
                    else {
                        # Same image definition, different version - check for rollback
                        $versionComparison = Compare-ImageVersion -Version1 $sh.ImageVersion -Version2 $LatestImageVersion.Version
                        
                        if ($versionComparison -lt 0) {
                            # VM version is older than latest - safe to replace
                            $sessionHostsOldVersion += $sh
                        }
                        elseif ($versionComparison -gt 0) {
                            # VM version is NEWER than "latest" - potential rollback scenario
                            if ($AllowImageVersionRollback) {
                                Write-LogEntry -Message "Session host $($sh.SessionHostName) has NEWER version '$($sh.ImageVersion)' than latest '$($LatestImageVersion.Version)' - will replace (AllowImageVersionRollback=true)" -Level Warning
                                $sessionHostsOldVersion += $sh
                            }
                            else {
                                Write-LogEntry -Message "Session host $($sh.SessionHostName) has NEWER version '$($sh.ImageVersion)' than latest '$($LatestImageVersion.Version)' - skipping replacement (AllowImageVersionRollback=false)" -Level Warning
                            }
                        }
                        else {
                            # Versions are functionally equal but string representation differs (shouldn't happen)
                        }
                    }
                }
            }
            
            Write-LogEntry -Message "Found $($sessionHostsOldVersion.Count) session hosts to replace due to image version. $($($sessionHostsOldVersion.SessionHostName) -Join ',')"
    }
    else {
        # Latest image version delay not yet met
    }

    [array] $sessionHostsToReplace = $sessionHostsOldVersion | Select-Object -Property * -Unique
    Write-LogEntry -Message "Found $($sessionHostsToReplace.Count) session hosts to replace in total. $($($sessionHostsToReplace.SessionHostName) -join ',')"

    $goodSessionHosts = $SessionHosts | Where-Object { $_.SessionHostName -notin $sessionHostsToReplace.SessionHostName }
    
    # Count running deployment VMs - handle both ARM deployments (with SessionHostNames) and state-tracked deployments (with VirtualCount)
    $runningDeploymentVMCount = 0
    $runningDeploymentVMNames = @()
    foreach ($deployment in $runningDeployments) {
        if ($deployment.SessionHostNames -and $deployment.SessionHostNames.Count -gt 0) {
            $runningDeploymentVMCount += $deployment.SessionHostNames.Count
            $runningDeploymentVMNames += $deployment.SessionHostNames
        }
        elseif ($deployment.VirtualCount) {
            # Synthetic deployment from state - use virtual count
            $runningDeploymentVMCount += $deployment.VirtualCount
        }
    }
    
    $sessionHostsCurrentTotal = ([array]$goodSessionHosts.SessionHostName + [array]$runningDeploymentVMNames) | Select-Object -Unique
    Write-LogEntry -Message "We have $($sessionHostsCurrentTotal.Count) good session hosts including $runningDeploymentVMCount session hosts being deployed"
    Write-LogEntry -Message "We target having $TargetSessionHostCount session hosts in good shape"
    
    # Check if there are any running or recently submitted deployments - if so, don't submit new ones
    if ($runningDeployments -and $runningDeployments.Count -gt 0) {
        Write-LogEntry -Message "Found $($runningDeployments.Count) running or recently submitted deployment(s). Will not submit new deployments until these complete." -Level Warning
        $canDeploy = 0
    }
    else {
        # In DeleteFirst mode, calculate deployments based on what needs replacement (we'll delete first to make room)
        # In SideBySide mode, calculate based on buffer space (pool can temporarily double)
        if ($ReplacementMode -eq 'DeleteFirst') {
            # DeleteFirst: We can deploy as many as we need since we delete first
            $weNeedToDeploy = $TargetSessionHostCount - $sessionHostsCurrentTotal.Count
            
            if ($weNeedToDeploy -gt 0) {
                Write-LogEntry -Message "We need to deploy $weNeedToDeploy new session hosts"
                $canDeploy = $weNeedToDeploy
                Write-LogEntry -Message "DeleteFirst mode allows deploying $canDeploy session hosts (will delete first to make room)"
            }
            else {
                $canDeploy = 0
                Write-LogEntry -Message "We have enough session hosts in good shape."
            }
        }
        else {
            # SideBySide: Use buffer to allow pool to double
            $effectiveBuffer = $TargetSessionHostCount
            Write-LogEntry -Message "Automatic buffer: $effectiveBuffer session hosts (allows pool to double during rolling updates)"
            
            $canDeployUpTo = $TargetSessionHostCount + $effectiveBuffer - $SessionHosts.count - $runningDeploymentVMCount
            
            if ($canDeployUpTo -ge 0) {
                Write-LogEntry -Message "We can deploy up to $canDeployUpTo session hosts" 
                $weNeedToDeploy = $TargetSessionHostCount - $sessionHostsCurrentTotal.Count
                
                if ($weNeedToDeploy -gt 0) {
                    Write-LogEntry -Message "We need to deploy $weNeedToDeploy new session hosts"
                    $canDeploy = if ($weNeedToDeploy -gt $canDeployUpTo) { $canDeployUpTo } else { $weNeedToDeploy }
                    Write-LogEntry -Message "Buffer allows deploying $canDeploy session hosts"
                }
                else {
                    $canDeploy = 0
                    Write-LogEntry -Message "We have enough session hosts in good shape."
                }
            }
            else {
                Write-LogEntry -Message "Buffer is full. We can not deploy more session hosts"
                $canDeploy = 0
            }
        }
            
        # Apply progressive scale-up to both modes (if enabled)
        if ($EnableProgressiveScaleUp -and $canDeploy -gt 0) {
            Write-LogEntry -Message "Progressive scale-up is enabled"
            $deploymentState = Get-DeploymentState
            $currentPercentage = $InitialDeploymentPercentage
            
            if ($deploymentState.ConsecutiveSuccesses -ge $SuccessfulRunsBeforeScaleUp) {
                $scaleUpMultiplier = [Math]::Floor($deploymentState.ConsecutiveSuccesses / $SuccessfulRunsBeforeScaleUp)
                $currentPercentage = $InitialDeploymentPercentage + ($scaleUpMultiplier * $ScaleUpIncrementPercentage)
            }
            
            $currentPercentage = [Math]::Min($currentPercentage, 100)
            $percentageBasedCount = [Math]::Ceiling($canDeploy * ($currentPercentage / 100.0))
            $batchSizeLimit = if ($ReplacementMode -eq 'DeleteFirst') { $MaxDeletionsPerCycle } else { $MaxDeploymentBatchSize }
            $actualDeployCount = [Math]::Min($percentageBasedCount, $batchSizeLimit)
            $actualDeployCount = [Math]::Min($actualDeployCount, $canDeploy)
            
            Write-LogEntry -Message "Progressive scale-up: Using $currentPercentage% of $canDeploy needed = $actualDeployCount hosts (ConsecutiveSuccesses: $($deploymentState.ConsecutiveSuccesses), Max: $batchSizeLimit)"
            $canDeploy = $actualDeployCount
        }
    }
    
    # Calculate how many hosts can be deleted
    if ($ReplacementMode -eq 'DeleteFirst') {
        # DeleteFirst mode: Align deletions with deployments for predictable 1:1 replacement behavior
        # Progressive scale-up controls both deployment and deletion counts together
        $canDelete = $canDeploy
        
        # Safety floor: Never allow deletions that would drop below MinimumCapacityPercentage of target capacity
        # Use total hosts (not just "good" ones) to avoid blocking deletions when all hosts need replacement
        $minimumAbsoluteHosts = [Math]::Ceiling($TargetSessionHostCount * ($MinimumCapacityPercentage / 100.0))
        $currentTotalHosts = $SessionHosts.Count
        $maxSafeDeletions = $currentTotalHosts - $minimumAbsoluteHosts
        
        if ($canDelete -gt $maxSafeDeletions) {
            Write-LogEntry -Message "DeleteFirst mode: Safety floor triggered - limiting deletions from $canDelete to $maxSafeDeletions to maintain minimum $MinimumCapacityPercentage% capacity ($minimumAbsoluteHosts hosts)" -Level Warning
            $canDelete = $maxSafeDeletions
        }
        
        # Emergency brake: Respect the MaxDeletionsPerCycle limit
        if ($canDelete -gt $MaxDeletionsPerCycle) {
            Write-LogEntry -Message "DeleteFirst mode: MaxDeletionsPerCycle limit triggered - capping deletions from $canDelete to $MaxDeletionsPerCycle"
            $canDelete = $MaxDeletionsPerCycle
        }
        
        $canDelete = [Math]::Max($canDelete, 0)  # Ensure non-negative
        
        Write-LogEntry -Message "Delete-First mode: Will delete $canDelete hosts (aligned with $canDeploy deployments, current total: $currentTotalHosts, minimum: $minimumAbsoluteHosts at $MinimumCapacityPercentage%, max per cycle: $MaxDeletionsPerCycle)"
    }
    else {
        # SideBySide mode: Only delete when overpopulated (more hosts than target)
        $canDelete = $SessionHosts.Count - $TargetSessionHostCount
    }
    
    if ($canDelete -gt 0) {
        Write-LogEntry -Message "We need to delete $canDelete session hosts"
        if ($canDelete -gt $sessionHostsToReplace.Count) {
            Write-LogEntry -Message "Host pool is over populated"
            $goodSessionHostsToDeleteCount = $canDelete - $sessionHostsToReplace.Count
            Write-LogEntry -Message "We will delete $goodSessionHostsToDeleteCount good session hosts"
            $selectedGoodHostsTotDelete = [array] ($goodSessionHosts | Sort-Object -Property Session | Select-Object -First $goodSessionHostsToDeleteCount)
            Write-LogEntry -Message "Selected the following good session hosts to delete: $($($selectedGoodHostsTotDelete.VMName) -join ',')"
        }
        else {
            $selectedGoodHostsTotDelete = @()
            Write-LogEntry -Message "Host pool is not over populated"
        }
        $sessionHostsPendingDelete = ($sessionHostsToReplace + $selectedGoodHostsTotDelete) | Select-Object -First $canDelete
        
        # In SideBySide mode, apply progressive scale-up to deletions
        # In DeleteFirst mode, skip this - deletions are already controlled by deployment progressive scale-up (they're aligned 1:1)
        if ($ReplacementMode -ne 'DeleteFirst' -and $EnableProgressiveScaleUp -and $sessionHostsPendingDelete.Count -gt 0) {
            Write-LogEntry -Message "Progressive scale-up is enabled for deletions"
            $deploymentState = Get-DeploymentState
            $currentPercentage = $InitialDeploymentPercentage
            
            if ($deploymentState.ConsecutiveSuccesses -ge $SuccessfulRunsBeforeScaleUp) {
                $scaleUpMultiplier = [Math]::Floor($deploymentState.ConsecutiveSuccesses / $SuccessfulRunsBeforeScaleUp)
                $currentPercentage = $InitialDeploymentPercentage + ($scaleUpMultiplier * $ScaleUpIncrementPercentage)
            }
            
            $currentPercentage = [Math]::Min($currentPercentage, 100)
            $percentageBasedCount = [Math]::Ceiling($sessionHostsPendingDelete.Count * ($currentPercentage / 100.0))
            $batchSizeLimit = $MaxDeploymentBatchSize
            $actualDeleteCount = [Math]::Min($percentageBasedCount, $batchSizeLimit)
            $actualDeleteCount = [Math]::Min($actualDeleteCount, $sessionHostsPendingDelete.Count)
            
            Write-LogEntry -Message "Progressive scale-up for deletions: Using $currentPercentage% of $($sessionHostsPendingDelete.Count) pending = $actualDeleteCount hosts (ConsecutiveSuccesses: $($deploymentState.ConsecutiveSuccesses), Max: $batchSizeLimit)"
            $sessionHostsPendingDelete = $sessionHostsPendingDelete | Select-Object -First $actualDeleteCount
        }
        
        Write-LogEntry -Message "The following Session Hosts are now pending delete: $($($SessionHostsPendingDelete.SessionHostName) -join ',')"
    }
    elseif ($sessionHostsToReplace.Count -gt 0) {
        Write-LogEntry -Message "We need to delete $($sessionHostsToReplace.Count) session hosts but we don't have enough session hosts in the host pool."
    }
    else {
        Write-LogEntry -Message "We do not need to delete any session hosts"
    }
    
    # Auto-detect mode: Clear stored target when replacement cycle is complete
    $configuredTarget = Read-FunctionAppSetting TargetSessionHostCount
    if ($configuredTarget -eq 0 -and $sessionHostsToReplace.Count -eq 0 -and $sessionHostsPendingDelete.Count -eq 0) {
        # All hosts are up to date and nothing pending - clear stored target for next cycle
        try {
            $deploymentState = Get-DeploymentState -HostPoolName $HostPoolName
            if ($deploymentState.TargetSessionHostCount -gt 0) {
                Write-LogEntry -Message "Auto-detect mode: All session hosts are up to date - clearing stored target count for next replacement cycle"
                $deploymentState.TargetSessionHostCount = 0
                Save-DeploymentState -DeploymentState $deploymentState -HostPoolName $HostPoolName
            }
        }
        catch {
            Write-LogEntry -Message "Auto-detect mode: Unable to clear stored target count - will retry on next run. Error: $_" -Level Warning
        }
    }

    return [PSCustomObject]@{
        PossibleDeploymentsCount       = $canDeploy
        PossibleSessionHostDeleteCount = $canDelete
        SessionHostsPendingDelete      = $sessionHostsPendingDelete
        ExistingSessionHostNames       = ([array]$SessionHosts.SessionHostName + [array]$runningDeploymentVMNames) | Select-Object -Unique
        TargetSessionHostCount         = $TargetSessionHostCount
        TotalSessionHostsToReplace     = $sessionHostsToReplace.Count
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
        Write-LogEntry -Message "Deployment names: $($deployments.name -join ', ')" -Level Verbose
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
    Write-LogEntry -Message "Found $($runningDeployments.Count) running deployments."
    
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
            Write-LogEntry -Message "Running deployment '$($deployment.name)' is deploying: $(($parameters['sessionHostNames'].Value -join ','))" -Level Verbose
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

function Get-SessionHosts {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $ARMToken,
        [Parameter()]
        [string] $ResourceManagerUri = (Get-ResourceManagerUri),
        [Parameter()]
        [string] $HostPoolSubscriptionId = (Read-FunctionAppSetting HostPoolSubscriptionId),
        [Parameter()]
        [string] $ResourceGroupName = (Read-FunctionAppSetting HostPoolResourceGroupName),
        [Parameter()]
        [string] $HostPoolName = (Read-FunctionAppSetting HostPoolName),
        [Parameter()]
        [string] $TagIncludeInAutomation = (Read-FunctionAppSetting Tag_IncludeInAutomation),
        [Parameter()]
        [string] $TagDeployTimestamp = (Read-FunctionAppSetting Tag_DeployTimestamp),
        [Parameter()]
        [string] $TagPendingDrainTimeStamp = (Read-FunctionAppSetting Tag_PendingDrainTimestamp),
        [Parameter()]
        [switch] $FixSessionHostTags = (Read-FunctionAppSetting FixSessionHostTags),
        [Parameter()]
        [bool] $IncludePreExistingSessionHosts = (Read-FunctionAppSetting IncludePreExistingSessionHosts)
    )
    
    Write-LogEntry -Message "Getting current session hosts in host pool $HostPoolName"
    $Uri = "$ResourceManagerUri/subscriptions/$HostPoolSubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName/sessionHosts?api-version=2024-04-03"
    $sessionHostsResponse = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $Uri
    
    # Extract properties from nested structure
    $sessionHosts = $sessionHostsResponse | ForEach-Object {
        [PSCustomObject]@{
            Name            = $_.name
            ResourceId      = $_.properties.resourceId
            Sessions        = $_.properties.sessions
            AllowNewSession = $_.properties.allowNewSession
            Status          = $_.properties.status
        }
    }
    Write-LogEntry -Message "Found $($sessionHosts.Count) session hosts"
    
    $result = foreach ($sh in $sessionHosts) {
        $Uri = "$ResourceManagerUri$($sh.ResourceId)?api-version=2024-03-01"
        $vmResponse = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $Uri
        
        # Extract properties from nested structure
        $vm = [PSCustomObject]@{
            Name           = $vmResponse.name
            TimeCreated    = $vmResponse.properties.timeCreated
            StorageProfile = $vmResponse.properties.storageProfile
            HostId         = $vmResponse.properties.host.id
            HostGroupId    = $vmResponse.properties.hostGroup.id
            Zones          = $vmResponse.zones
        }
        
        # Extract image version and definition - handle both ExactVersion (specific version) and id (image definition reference)
        $vmImageVersion = $null
        $vmImageDefinition = $null
        
        if ($vm.StorageProfile.ImageReference.id) {
            # Gallery image reference (either specific version or definition for "latest")
            $imageRef = $vm.StorageProfile.ImageReference.id
            
            # Extract the image definition path (without version)
            if ($imageRef -match '^(?<definition>.+)/versions/[^/]+$') {
                $vmImageDefinition = $Matches['definition']
            }
            elseif ($imageRef -match '^(?<definition>/subscriptions/.+/images/[^/]+)$') {
                $vmImageDefinition = $Matches['definition']
            }
            
            # Get version - prefer ExactVersion if available, otherwise extract from id
            if ($vm.StorageProfile.ImageReference.ExactVersion) {
                $vmImageVersion = $vm.StorageProfile.ImageReference.ExactVersion
            }
            elseif ($imageRef -match '/versions/(?<version>[^/]+)$') {
                $vmImageVersion = $Matches['version']
            }
        }
        elseif ($vm.StorageProfile.ImageReference.publisher) {
            # Marketplace image
            $vmImageVersion = $vm.StorageProfile.ImageReference.version
            $vmImageDefinition = "marketplace:$($vm.StorageProfile.ImageReference.publisher)/$($vm.StorageProfile.ImageReference.offer)/$($vm.StorageProfile.ImageReference.sku)"
        }
        else {
            Write-LogEntry -Message "Unable to determine VM image version from StorageProfile" -Level Warning
        }
        
        $Uri = "$ResourceManagerUri$($sh.ResourceId)/providers/Microsoft.Resources/tags/default?api-version=2021-04-01"
        $vmTagsResponse = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $Uri
        
        # Convert PSCustomObject tags to hashtable for easier access
        $vmTags = @{}
        if ($vmTagsResponse.properties.tags) {
            $vmTagsResponse.properties.tags.PSObject.Properties | ForEach-Object {
                $vmTags[$_.Name] = $_.Value
            }
        }
        
        $vmDeployTimeStamp = $vmTags[$TagDeployTimestamp]
        
        try {
            $vmDeployTimeStamp = [DateTime]::Parse($vmDeployTimeStamp)
        }
        catch {
            $value = if ($null -eq $vmDeployTimeStamp) { 'null' } else { $vmDeployTimeStamp }
            Write-LogEntry -Message "VM tag $TagDeployTimestamp with value $value is not a valid date" -Level Verbose
            if ($FixSessionHostTags) {
                $Body = @{
                    properties = @{
                        tags = @{ $TagDeployTimestamp = $vm.TimeCreated.ToString('o') }
                    }
                    operation  = 'Merge'
                }
                Invoke-AzureRestMethod -ARMToken $ARMToken -Body ($Body | ConvertTo-Json -Depth 10) -Method PATCH -Uri $Uri | Out-Null
            }
            $vmDeployTimeStamp = $vm.TimeCreated
        }
        
        $vmIncludeInAutomation = $vmTags[$TagIncludeInAutomation]
        if ($vmIncludeInAutomation -eq "True") {
            $vmIncludeInAutomation = $true
        }
        elseif ($vmIncludeInAutomation -eq "False") {
            $vmIncludeInAutomation = $false
        }
        else {
            $value = if ($null -eq $vmIncludeInAutomation) { 'null' } else { $vmIncludeInAutomation }
            Write-LogEntry -Message "VM tag with $TagIncludeInAutomation value $value is not set to True/False" -Level Verbose
            if ($FixSessionHostTags) {
                $Body = @{
                    properties = @{
                        tags = @{ $TagIncludeInAutomation = $IncludePreExistingSessionHosts }
                    }
                    operation  = 'Merge'
                }
                $null = Invoke-AzureRestMethod -ARMToken $ARMToken -Body ($Body | ConvertTo-Json -Depth 10) -Method PATCH -Uri $Uri
            }
            $vmIncludeInAutomation = $IncludePreExistingSessionHosts
        }
        
        # Get drain timestamp tag
        $vmPendingDrainTimeStamp = $vmTags[$TagPendingDrainTimeStamp]
        if ($null -ne $vmPendingDrainTimeStamp) {
            try {
                # Parse as UTC time regardless of timezone indicator
                $vmPendingDrainTimeStamp = [DateTime]::Parse($vmPendingDrainTimeStamp, $null, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
            }
            catch {
                Write-LogEntry -Message "VM tag $TagPendingDrainTimeStamp could not be parsed: '$vmPendingDrainTimeStamp'" -Level Warning
                $vmPendingDrainTimeStamp = $null
            }
        }

        $fqdn = $sh.Name -replace ".+\/(.+)", '$1'
        $sessionHostName = $fqdn -replace '\..*$', ''
        
        $hostOutput = @{
            VMName                = $vm.Name
            SessionHostName       = $sessionHostName
            FQDN                  = $fqdn
            DeployTimestamp       = $vmDeployTimeStamp
            IncludeInAutomation   = $vmIncludeInAutomation
            PendingDrainTimeStamp = $vmPendingDrainTimeStamp
            ImageVersion          = $vmImageVersion
            ImageDefinition       = $vmImageDefinition
            HostId                = $vm.HostId
            HostGroupId           = $vm.HostGroupId
            Zones                 = $vm.Zones
        }
        $sh.PSObject.Properties.ForEach{ $hostOutput[$_.Name] = $_.Value }
        [PSCustomObject]$hostOutput
    }
    return $result
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
    Write-LogEntry -Message "Resource type: $azResourceType" -Level Verbose
    switch ($azResourceType) {
        'Microsoft.Resources/templateSpecs' {
            # List all versions of the template spec
            $Uri = "$ResourceManagerUri$($ResourceId)/versions?api-version=2022-02-01"
            Write-LogEntry -Message "Calling API: $Uri" -Level Verbose
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
            
            Write-LogEntry -Message "Template Spec has $($templateSpecVersions.count) versions" -Level Verbose
            
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
        Write-LogEntry -Message "No failed deployments to clean up" -Level Verbose
        return
    }
    
    Write-LogEntry -Message "Processing $($FailedDeployments.Count) failed deployments for cleanup"
    
    # Get all VMs in the resource group to check for orphaned VMs
    $Uri = "$ResourceManagerUri/subscriptions/$VirtualMachinesSubscriptionId/resourceGroups/$VirtualMachinesResourceGroupName/providers/Microsoft.Compute/virtualMachines?api-version=2024-07-01"
    $allVMs = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $Uri
    
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
                    Write-LogEntry -Message "VM $($vm.name) from failed deployment is registered as session host - will be handled by normal cleanup flow" -Level Verbose
                }
            }
            
            if ($matchingVMs.Count -eq 0) {
                Write-LogEntry -Message "No VM found matching session host name $sessionHostName (deployment may have rolled back)" -Level Verbose
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
                            Write-LogEntry -Message "No Entra device found for orphaned VM: $($orphanedVM.SessionHostName)" -Level Verbose
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
                            Write-LogEntry -Message "No Intune device found for orphaned VM: $($orphanedVM.SessionHostName)" -Level Verbose
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
        Write-LogEntry -Message "No orphaned VMs found from failed deployments" -Level Verbose
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
                        Write-LogEntry -Message "Deleting nested deployment record: $nestedDeploymentName" -Level Verbose
                        $Uri = "$ResourceManagerUri/subscriptions/$VirtualMachinesSubscriptionId/resourceGroups/$VirtualMachinesResourceGroupName/providers/Microsoft.Resources/deployments/$nestedDeploymentName`?api-version=2021-04-01"
                        Invoke-AzureRestMethod -ARMToken $ARMToken -Method DELETE -Uri $Uri
                        Write-LogEntry -Message "Successfully deleted nested deployment record: $nestedDeploymentName" -Level Verbose
                    }
                    catch {
                        Write-LogEntry -Message "Failed to delete nested deployment record $nestedDeploymentName`: $_" -Level Warning
                    }
                }
            }
            else {
                Write-LogEntry -Message "No nested deployments found for parent deployment" -Level Verbose
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

function Remove-SessionHosts {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $ARMToken,
        [Parameter()]
        [string] $GraphToken,
        [Parameter()]
        [string] $ResourceManagerUri = (Get-ResourceManagerUri),
        [Parameter(Mandatory = $true)]
        $SessionHostsPendingDelete,
        [Parameter()]
        [string] $HostPoolSubscriptionId = (Read-FunctionAppSetting HostPoolSubscriptionId),
        [Parameter()]
        [string] $ResourceGroupName = (Read-FunctionAppSetting HostPoolResourceGroupName),
        [Parameter()]
        [string] $HostPoolName = (Read-FunctionAppSetting HostPoolName),
        [Parameter()]
        [int] $DrainGracePeriodHours = [int]::Parse((Read-FunctionAppSetting DrainGracePeriodHours)),
        [Parameter()]
        [int] $MinimumDrainMinutes = [int]::Parse((Read-FunctionAppSetting MinimumDrainMinutes)),
        [Parameter()]
        [string] $TagPendingDrainTimeStamp = (Read-FunctionAppSetting Tag_PendingDrainTimestamp),
        [Parameter()]
        [string] $TagScalingPlanExclusionTag = (Read-FunctionAppSetting Tag_ScalingPlanExclusionTag),
        [Parameter()]
        [bool] $RemoveEntraDevice,
        [Parameter()]
        [bool] $RemoveIntuneDevice,
        [Parameter()]
        [string] $ClientId = (Read-FunctionAppSetting UserAssignedIdentityClientId)
    )

    # Initialize results tracking
    $successfulDeletions = @()
    $failedDeletions = @()

    foreach ($sessionHost in $SessionHostsPendingDelete) {
        $drainSessionHost = $false
        $deleteSessionHost = $false

        Write-LogEntry -Message "Evaluating session host $($sessionHost.SessionHostName): Sessions=$($sessionHost.Sessions), AllowNewSession=$($sessionHost.AllowNewSession), PendingDrainTimeStamp=$($sessionHost.PendingDrainTimeStamp)" -Level Verbose

        if ($sessionHost.Sessions -eq 0) {
            Write-LogEntry -Message "Session host $($sessionHost.FQDN) has no sessions."
            
            # Optimization: If MinimumDrainMinutes = 0, skip draining entirely and delete immediately
            if ($MinimumDrainMinutes -eq 0) {
                Write-LogEntry -Message "Session host $($sessionHost.FQDN) is idle and MinimumDrainMinutes is 0 - deleting immediately without drain period"
                $deleteSessionHost = $true
            }
            elseif (-Not $sessionHost.AllowNewSession) {
                Write-LogEntry -Message "Session host $($sessionHost.FQDN) is in drain mode with zero sessions."
                if ($sessionHost.PendingDrainTimeStamp) {
                    $elapsedMinutes = ((Get-Date).ToUniversalTime() - $sessionHost.PendingDrainTimeStamp).TotalMinutes
                    Write-LogEntry -Message "Session host $($sessionHost.FQDN) has been draining for $([Math]::Round($elapsedMinutes, 1)) minutes (minimum required: $MinimumDrainMinutes)"
                    if ($elapsedMinutes -ge $MinimumDrainMinutes) {
                        Write-LogEntry -Message "Session host $($sessionHost.FQDN) has met the minimum drain time for idle hosts."
                        $deleteSessionHost = $true
                    }
                    else {
                        Write-LogEntry -Message "Session host $($sessionHost.FQDN) has not yet met the minimum drain time."
                    }
                }
                else {
                    Write-LogEntry -Message "Session host $($sessionHost.FQDN) does not have a drain timestamp."
                    $drainSessionHost = $true
                }
            }
            else {
                Write-LogEntry -Message "Session host $($sessionHost.FQDN) is not in drain mode. Turning on drain mode."
                $drainSessionHost = $true
            }
        }
        else {
            Write-LogEntry -Message "Session host $($sessionHost.FQDN) has $($sessionHost.Sessions) sessions." 
            if (-Not $sessionHost.AllowNewSession) {
                Write-LogEntry -Message "Session host $($sessionHost.FQDN) is in drain mode."
                if ($sessionHost.PendingDrainTimeStamp) {
                    Write-LogEntry -Message "Session Host $($sessionHost.FQDN) drain timestamp is $($sessionHost.PendingDrainTimeStamp)"
                    $maxDrainGracePeriodDate = $sessionHost.PendingDrainTimeStamp.AddHours($DrainGracePeriodHours)
                    Write-LogEntry -Message "Session Host $($sessionHost.FQDN) can stay in grace period until $($maxDrainGracePeriodDate.ToUniversalTime().ToString('o'))" -Level Verbose 
                    if ($maxDrainGracePeriodDate -lt (Get-Date).ToUniversalTime()) {
                        Write-LogEntry -Message "Session Host $($sessionHost.FQDN) has exceeded the drain grace period."
                        $deleteSessionHost = $true
                    }
                    else {
                        Write-LogEntry -Message "Session Host $($sessionHost.FQDN) has not exceeded the drain grace period." -Level Verbose
                    }
                }
                else {
                    Write-LogEntry -Message "Session Host $($sessionHost.FQDN) does not have a drain timestamp." -Level Verbose
                    $drainSessionHost = $true
                }
            }
            else {
                Write-LogEntry -Message "Session host $($sessionHost.Name) in not in drain mode. Turning on drain mode."
                $drainSessionHost = $true
            }
        }

        if ($drainSessionHost) {
            try {
                Write-LogEntry -Message "Enabling drain mode for session host $($sessionHost.SessionHostName)"
                $Uri = "$ResourceManagerUri/subscriptions/$HostPoolSubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName/sessionHosts/$($sessionHost.FQDN)?api-version=2024-04-03"
                Invoke-AzureRestMethod -ARMToken $ARMToken -Body (@{properties = @{allowNewSession = $false } } | ConvertTo-Json) -Method 'PATCH' -Uri $Uri | Out-Null
                
                Write-LogEntry -Message "Drain mode enabled for $($sessionHost.SessionHostName)" -Level Verbose
                
                $drainTimestamp = (Get-Date).ToUniversalTime().ToString('o')
                Write-LogEntry -Message "Setting drain timestamp tag on $($sessionHost.SessionHostName): $drainTimestamp"
                $Uri = "$ResourceManagerUri$($sessionHost.ResourceId)/providers/Microsoft.Resources/tags/default?api-version=2021-04-01"
                $Body = @{
                    properties = @{
                        tags = @{ $TagPendingDrainTimeStamp = $drainTimestamp }
                    }
                    operation  = 'Merge'
                }
                Invoke-AzureRestMethod -ARMToken $ARMToken -Body ($Body | ConvertTo-Json -Depth 5) -Method PATCH -Uri $Uri | Out-Null
                
                Write-LogEntry -Message "Successfully tagged $($sessionHost.SessionHostName) with drain timestamp"
                
                # Update in-memory session host object so timestamp is available for deletion check in same run
                $sessionHost.PendingDrainTimeStamp = [DateTime]::Parse($drainTimestamp, $null, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
                
                # Re-evaluate deletion eligibility now that we have a timestamp (allows immediate deletion when MinimumDrainMinutes = 0)
                if ($sessionHost.Sessions -eq 0) {
                    $elapsedMinutes = ((Get-Date).ToUniversalTime() - $sessionHost.PendingDrainTimeStamp).TotalMinutes
                    if ($elapsedMinutes -ge $MinimumDrainMinutes) {
                        Write-LogEntry -Message "Session host $($sessionHost.SessionHostName) meets minimum drain time ($([Math]::Round($elapsedMinutes, 1)) >= $MinimumDrainMinutes minutes), marking for immediate deletion"
                        $deleteSessionHost = $true
                    }
                }
                
                if ($TagScalingPlanExclusionTag -ne ' ') {
                    Write-LogEntry -Message "Setting scaling plan exclusion tag on $($sessionHost.SessionHostName)" -Level Verbose
                    $Body = @{
                        properties = @{
                            tags = @{ $TagScalingPlanExclusionTag = 'SessionHostReplacer' }
                        }
                        operation  = 'Merge'
                    }
                    Invoke-AzureRestMethod -ARMToken $ARMToken -Body ($Body | ConvertTo-Json -Depth 5) -Method PATCH -Uri $Uri | Out-Null
                    
                    Write-LogEntry -Message "Successfully set scaling plan exclusion tag with value: SessionHostReplacer" -Level Verbose
                }

                Write-LogEntry -Message 'Notifying Users' -Level Verbose
                Send-DrainNotification -ARMToken $ARMToken -SessionHostName ($sessionHost.FQDN)
            }
            catch {
                Write-LogEntry -Message "Error enabling drain mode for $($sessionHost.SessionHostName): $($_.Exception.Message)" -Level Error
            }
        }

        if ($deleteSessionHost) {
            try {
                Write-LogEntry -Message "Deleting session host $($SessionHost.SessionHostName)..."
                if ($GraphToken -and $RemoveEntraDevice) {
                    Write-LogEntry -Message 'Deleting device from Entra ID' -Level Verbose
                    Remove-EntraDevice -GraphToken $GraphToken -Name $sessionHost.SessionHostName -ClientId $ClientId
                }
                if ($GraphToken -and $RemoveIntuneDevice) {
                    Write-LogEntry -Message 'Deleting device from Intune' -Level Verbose
                    Remove-IntuneDevice -GraphToken $GraphToken -Name $sessionHost.SessionHostName -ClientId $ClientId
                }
                Write-LogEntry -Message "Removing Session Host from Host Pool $HostPoolName" -Level Verbose
                $Uri = "$ResourceManagerUri/subscriptions/$HostPoolSubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName/sessionHosts/$($sessionHost.FQDN)?api-version=2024-04-03"
                [void](Invoke-AzureRestMethod -ARMToken $ARMToken -Method DELETE -Uri $Uri)            
                Write-LogEntry -Message "Deleting VM: $($sessionHost.ResourceId)..." -Level Verbose
                $Uri = "$ResourceManagerUri$($sessionHost.ResourceId)?forceDeletion=true&api-version=2024-07-01"
                [void](Invoke-AzureRestMethod -ARMToken $ARMToken -Method 'DELETE' -Uri $Uri)
                
                # Track successful deletion
                $successfulDeletions += $sessionHost.SessionHostName
                Write-LogEntry -Message "Successfully deleted session host $($sessionHost.SessionHostName)"
            }
            catch {
                # Track failed deletion
                $failedDeletions += [PSCustomObject]@{
                    SessionHostName = $sessionHost.SessionHostName
                    Reason          = $_.Exception.Message
                }
                Write-Error "Failed to delete session host $($sessionHost.SessionHostName): $($_.Exception.Message)"
            }
        }
    }

    # Return results object
    return [PSCustomObject]@{
        SuccessfulDeletions = $successfulDeletions
        FailedDeletions     = $failedDeletions
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
        $Device = Invoke-GraphApiWithRetry `
            -GraphEndpoint $GraphEndpoint `
            -GraphToken $GraphToken `
            -Method Get `
            -Uri "/v1.0/devices?`$filter=displayName eq '$Name'" `
            -ClientId $ClientId
        
        If ($Device.value -and $Device.value.Count -gt 0) {
            $Id = $Device.value[0].id
            Write-LogEntry -Message "Removing session host $Name from Entra ID"
            Write-LogEntry -Message "Device ID: $Id" -Level Verbose
            
            Invoke-GraphApiWithRetry `
                -GraphEndpoint $GraphEndpoint `
                -GraphToken $GraphToken `
                -Method Delete `
                -Uri "/v1.0/devices/$Id" `
                -ClientId $ClientId
            
            Write-LogEntry -Message "Successfully removed device $Name from Entra ID"
        }
        else {
            Write-LogEntry -Message "Device $Name not found in Entra ID"
        }
    }
    catch {
        # Check if error is 404 (device already deleted)
        $is404 = $_.Exception.Response.StatusCode.value__ -eq 404
        if ($is404) {
            Write-LogEntry -Message "Device $Name not found in Entra ID (404)"
        }
        else {
            Write-LogEntry -Message "Failed to remove Entra device $Name : $($_.Exception.Message)" -Level Error
            throw
        }
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
        $Device = Invoke-GraphApiWithRetry `
            -GraphEndpoint $GraphEndpoint `
            -GraphToken $GraphToken `
            -Method Get `
            -Uri "/v1.0/deviceManagement/managedDevices?`$filter=deviceName eq '$Name'" `
            -ClientId $ClientId
        
        If ($Device.value -and $Device.value.Count -gt 0) {
            $Id = $Device.value[0].id
            Write-LogEntry -Message "Removing session host '$Name' device from Intune"
            Write-LogEntry -Message "Device ID: $Id" -Level Verbose
            
            Invoke-GraphApiWithRetry `
                -GraphEndpoint $GraphEndpoint `
                -GraphToken $GraphToken `
                -Method Delete `
                -Uri "/v1.0/deviceManagement/managedDevices/$Id" `
                -ClientId $ClientId
            
            Write-LogEntry -Message "Successfully removed device $Name from Intune"
        }
        else {
            Write-LogEntry -Message "Device $Name not found in Intune"
        }
    }
    catch {
        # Check if error is 404 (device not enrolled or already deleted)
        $is404 = $_.Exception.Response.StatusCode.value__ -eq 404
        if ($is404) {
            Write-LogEntry -Message "Device $Name not found in Intune (404)"
        }
        else {
            Write-LogEntry -Message "Failed to remove Intune device $Name : $($_.Exception.Message)" -Level Error
            throw
        }
    }
}

function Send-DrainNotification {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ARMToken,

        [Parameter(Mandatory = $true)]
        [string] $SessionHostName,

        [Parameter()]
        [string] $HostPoolSubscriptionId = (Read-FunctionAppSetting HostPoolSubscriptionId),

        [Parameter()]
        [string] $HostPoolName = (Read-FunctionAppSetting HostPoolName),

        [Parameter()]
        [string] $ResourceGroupName = (Read-FunctionAppSetting HostPoolResourceGroupName),

        [Parameter()]
        [int] $DrainGracePeriodHours = (Read-FunctionAppSetting DrainGracePeriodHours),

        [Parameter()]
        [string] $MessageTitle = "Automatic Session Host Maintenance",

        [Parameter()]
        [string] $MessageBody = "Your session host {0} is being replaced. Please save your work and log off. You will be disconnected in {1} hours."
    )
    
    try {       
        Write-LogEntry -Message "Getting user sessions for session host $SessionHostName"
        $SessionsUri = "$ResourceManagerUri/subscriptions/$HostPoolSubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName/sessionHosts/$SessionHostName/userSessions?api-version=2024-04-03"
        
        $sessionsResponse = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $SessionsUri
        
        # Ensure we have an array
        $sessions = @($sessionsResponse)
        
        # Filter out any empty or invalid session objects
        $sessions = $sessions | Where-Object { $_ -and $_.name }
        
        if ($sessions.Count -eq 0) {
            Write-LogEntry -Message "No active sessions found on session host $SessionHostName"
            return
        }
        
        Write-LogEntry -Message "Found $($sessions.Count) active session(s) on session host $SessionHostName"
        
        foreach ($session in $sessions) {
            $sessionId = $session.name -replace '.+\/.+\/(.+)', '$1'
            $userPrincipalName = $session.properties.userPrincipalName
            
            if ([string]::IsNullOrWhiteSpace($sessionId)) {
                Write-LogEntry -Message "Skipping session with invalid ID: $($session.name)" -Level Warning
                continue
            }
            
            $formattedMessageBody = $MessageBody -f $SessionHostName, $DrainGracePeriodHours
            
            Write-LogEntry -Message "Sending drain notification to user $userPrincipalName on session $sessionId"
            
            $MessageUri = "$ResourceManagerUri/subscriptions/$HostPoolSubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName/sessionHosts/$SessionHostName/userSessions/$sessionId/sendMessage?api-version=2024-04-03"
            
            $MessagePayload = @{
                messageTitle = $MessageTitle
                messageBody  = $formattedMessageBody
            } | ConvertTo-Json -Depth 10
            
            try {
                Invoke-AzureRestMethod -ARMToken $ARMToken -Method Post -Uri $MessageUri -Body $MessagePayload | Out-Null
                Write-LogEntry -Message "Successfully sent message to user $userPrincipalName"
            }
            catch {
                Write-LogEntry -Message "Failed to send message to user $userPrincipalName : $_" -Level Warning
            }
        }
    }
    catch {
        Write-LogEntry -Message "Error in Send-DrainNotification: $_" -Level Error
    }
}

#EndRegion Session Host Lifecycle Functions