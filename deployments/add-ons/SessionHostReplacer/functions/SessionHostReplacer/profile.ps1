<#
.SYNOPSIS
    Azure Function Profile for AVD Session Host Replacer

.DESCRIPTION
    This profile contains all functions required for automated Azure Virtual Desktop (AVD) session host
    lifecycle management. It handles deployment, monitoring, and removal of session hosts based on age
    and image version criteria using native Azure REST APIs and Microsoft Graph APIs.

.NOTES
    File Name      : profile.ps1
    Author         : FederalAVD Team
    Prerequisite   : Azure Function App with Managed Identity
    Required Permissions:
        Azure RBAC:
            - Desktop Virtualization Contributor (Host Pool RG)
            - Virtual Machine Contributor (Session Host RG)
            - Tag Contributor (Session Host RG)
            - Reader (Template Spec RG)
        Microsoft Graph API:
            - Device.ReadWrite.All
            - DeviceManagementManagedDevices.ReadWrite.All

.LINK
    https://github.com/Azure/FederalAVD

.EXAMPLE
    # This file is loaded automatically by Azure Function App
    # Functions are called from TimerTrigger/run.ps1
#>

#Region Token Cache Variables

# Global token cache to reduce token acquisition calls
$Script:AccessTokenCache = @{
    Token     = $null
    ExpiresOn = [DateTime]::MinValue
}

$Script:GraphTokenCache = @{
    Token     = $null
    ExpiresOn = [DateTime]::MinValue
}

#EndRegion Token Cache Variables

#Region Authentication Functions

function Get-AccessToken {
    <#
    .SYNOPSIS
        Retrieves Azure Resource Manager access token using Managed Identity.
    .DESCRIPTION
        Acquires an access token from the Azure Instance Metadata Service (IMDS) using
        the function app's managed identity for authenticating ARM API calls.
    .PARAMETER ResourceManagerUrl
        The Azure Resource Manager endpoint URL (e.g., https://management.azure.com/).
    .PARAMETER ClientId
        Optional. The client ID of the user-assigned managed identity. If not specified, uses system-assigned identity.
    .EXAMPLE
        $token = Get-AccessToken -ResourceManagerUrl 'https://management.azure.com/'
    .EXAMPLE
        $token = Get-AccessToken -ResourceManagerUrl 'https://management.azure.com/' -ClientId 'abc123...'
    #>
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [string]$ResourceManagerUrl,
        
        [parameter(Mandatory = $false)]
        [string]$ClientId
    )
    
    $TokenAuthURI = $env:IDENTITY_ENDPOINT + '?resource=' + $ResourceManagerUrl + '&api-version=2019-08-01'
    
    # Add client_id parameter if using user-assigned identity
    if ($ClientId) {
        $TokenAuthURI += "&client_id=$ClientId"
    }
    
    $TokenResponse = Invoke-RestMethod -Method Get -Headers @{"X-IDENTITY-HEADER" = "$env:IDENTITY_HEADER" } -Uri $TokenAuthURI
    $AccessToken = $TokenResponse.access_token
    Return $AccessToken
}

#EndRegion Authentication Functions

#Region Configuration Functions

function Read-FunctionAppSetting {
    <#
    .SYNOPSIS
        Retrieves configuration values from Azure Function App Settings (environment variables).
    .DESCRIPTION
        Reads configuration values from environment variables set in the Azure Function App Settings.
        This is the local implementation matching the AzureFunctionConfiguration module behavior.
    .PARAMETER ConfigKey
        The name of the configuration key to retrieve from environment variables.
    .EXAMPLE
        $hostPoolName = Read-FunctionAppSetting HostPoolName
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $ConfigKey
    )
    
    # Get the value from environment variable
    $value = [System.Environment]::GetEnvironmentVariable($ConfigKey)
    
    # Convert JSON strings to hashtables for complex configurations
    if ($value -and $value.StartsWith('{')) {
        try {
            $value = $value | ConvertFrom-Json -AsHashtable -Depth 99
        }
        catch {
            # If JSON conversion fails, return the raw string
            Write-HostDetailed -Message "Warning: Could not convert $ConfigKey to JSON object" -Level Warning
        }
    }
    
    # Convert boolean strings to actual boolean values
    if ($value -eq 'true' -or $value -eq 'True') {
        $value = $true
    }
    elseif ($value -eq 'false' -or $value -eq 'False') {
        $value = $false
    }
    
    # Convert numeric strings to integers where appropriate
    if ($value -match '^\d+$') {
        $value = [int]$value
    }
    
    return $value
}

#EndRegion Configuration Functions

#Region Logging and Error Handling

function Write-HostDetailed {
    <#
    .SYNOPSIS
        Enhanced logging function with timestamp and level support.
    .DESCRIPTION
        Writes detailed log messages with timestamps and severity levels.
    .PARAMETER Message
        The message to log.
    .PARAMETER Level
        The severity level (Information, Warning, Error, Host).
    .PARAMETER StringValues
        Array of values to format into the message using -f operator.
    .EXAMPLE
        Write-HostDetailed -Message "Processing {0} items" -StringValues 10 -Level Host
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $Message,
        
        [Parameter()]
        [ValidateSet('Information', 'Warning', 'Error', 'Host', 'Verbose')]
        [string] $Level = 'Information',
        
        [Parameter()]
        [string[]] $StringValues
    )
    
    # Format message with string values if provided
    if ($StringValues -and $StringValues.Count -gt 0) {
        try {
            $formattedMessage = $Message -f $StringValues
        }
        catch {
            $formattedMessage = $Message
            Write-Warning "Failed to format message with provided string values"
        }
    }
    else {
        $formattedMessage = $Message
    }
    
    # Add timestamp
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $output = "[$timestamp] [$Level] $formattedMessage"
    
    # Output based on level
    switch ($Level) {
        'Error' {
            Write-Error $output
        }
        'Warning' {
            Write-Warning $output
        }
        'Host' {
            Write-Host $output -ForegroundColor Cyan
        }
        'Verbose' {
            Write-Verbose $output
        }
        default {
            Write-Information $output -InformationAction Continue
        }
    }
}

function Invoke-AzureRestMethodWithRetry {
    <#
    .SYNOPSIS
        Invokes Azure REST API with automatic retry logic for transient failures.
    .DESCRIPTION
        Wraps Invoke-AzureRestMethod with exponential backoff retry for 429 and 5xx errors.
    .PARAMETER AccessToken
        Azure access token for authentication.
    .PARAMETER Method
        HTTP method (GET, POST, PUT, PATCH, DELETE).
    .PARAMETER Uri
        The REST API endpoint URI.
    .PARAMETER Body
        Optional request body.
    .PARAMETER MaxRetries
        Maximum number of retry attempts (default: 3).
    .PARAMETER RetryDelaySeconds
        Initial retry delay in seconds (default: 5).
    .EXAMPLE
        Invoke-AzureRestMethodWithRetry -AccessToken $token -Method Get -Uri $uri -MaxRetries 5
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $AccessToken,
        
        [Parameter(Mandatory = $true)]
        [ValidateSet('Get', 'Post', 'Put', 'Patch', 'Delete')]
        [string] $Method,
        
        [Parameter(Mandatory = $true)]
        [string] $Uri,
        
        [Parameter()]
        [string] $Body,
        
        [Parameter()]
        [int] $MaxRetries = 3,
        
        [Parameter()]
        [int] $RetryDelaySeconds = 5
    )
    
    $attempt = 0
    $success = $false
    $result = $null
    
    while (-not $success -and $attempt -lt $MaxRetries) {
        $attempt++
        try {
            $params = @{
                AccessToken = $AccessToken
                Method      = $Method
                Uri         = $Uri
            }
            
            if ($Body) {
                $params['Body'] = $Body
            }
            
            $result = Invoke-AzureRestMethod @params
            $success = $true
        }
        catch {
            $statusCode = $null
            if ($_.Exception.Response) {
                $statusCode = $_.Exception.Response.StatusCode.value__
            }
            
            # Retry on transient errors (429 Too Many Requests, 5xx Server Errors)
            if ($statusCode -eq 429 -or ($statusCode -ge 500 -and $statusCode -lt 600)) {
                if ($attempt -lt $MaxRetries) {
                    # Exponential backoff with jitter
                    $delay = $RetryDelaySeconds * [Math]::Pow(2, $attempt - 1)
                    $jitter = Get-Random -Minimum 0 -Maximum 2
                    $totalDelay = $delay + $jitter
                    
                    Write-HostDetailed -Message "Request failed with status $statusCode. Retrying in $totalDelay seconds... (Attempt $attempt/$MaxRetries)" -Level Warning
                    Start-Sleep -Seconds $totalDelay
                }
                else {
                    Write-HostDetailed -Message "Request failed after $MaxRetries attempts: $_" -Level Error
                    throw
                }
            }
            else {
                # Don't retry on client errors (4xx except 429) or unknown errors
                Write-HostDetailed -Message "Request failed with non-retryable error (Status: $statusCode): $_" -Level Error
                throw
            }
        }
    }
    
    return $result
}

#EndRegion Logging and Error Handling

#Region Core Helper Functions

function Invoke-AzureRestMethod {
    <#
        .SYNOPSIS
            Run an Azure REST call with paging support.           
        .PARAMETER AccessToken
            An access token generated by Connect-DCMsGraphAsDelegated or Connect-DCMsGraphAsApplication (depending on what permissions you use in Graph).
        .PARAMETER Method
            The HTTP method for the Graph call, like GET, POST, PUT, PATCH, DELETE. Default is GET.
        .PARAMETER Uri
            The Microsoft Graph URI for the query. Example: https://graph.microsoft.com/v1.0/users/
        .PARAMETER Body
            The request body of the Graph call. This is often used with methids like POST, PUT and PATCH. It is not used with GET.
        .EXAMPLE
            Invoke-AzureRestMethod -AccessToken $AccessToken -Method 'GET' -Uri 'https://graph.microsoft.com/v1.0/users/'
    #>

    param (
        [parameter(Mandatory = $true)]
        [string]$AccessToken,

        [parameter(Mandatory = $false)]
        [string]$Method = 'GET',

        [parameter(Mandatory = $true)]
        [string]$Uri,

        [parameter(Mandatory = $false)]
        [string]$Body = '',

        [parameter(Mandatory = $false)]
        [hashtable]$AdditionalHeaders
    )

    # Check if authentication was successfull.
    if ($AccessToken) {
        # Format headers.
        $HeaderParams = @{
            'Content-Type'  = "application\json"
            'Authorization' = "Bearer $AccessToken"
        }
        If ($AdditionalHeaders) {
            $HeaderParams += $AdditionalHeaders
        }

        # Create an empty array to store the result.
        $QueryRequest = @()
        $dataToUpload = @()

        # Run the first query.
        if ($Method -eq 'GET') {
            $QueryRequest = Invoke-RestMethod -Headers $HeaderParams -Uri $Uri -UseBasicParsing -Method $Method -ContentType "application/json" -Verbose:$false
        }
        else {
            $QueryRequest = Invoke-RestMethod -Headers $HeaderParams -Uri $Uri -UseBasicParsing -Method $Method -ContentType "application/json" -Body $Body -Verbose:$false
        }
        if ($QueryRequest.value) {
            $dataToUpload += $QueryRequest.value
        }
        else {
            $dataToUpload += $QueryRequest
        }

        # Invoke REST methods and fetch data until there are no pages left.
        if ($Uri -notlike "*`$top*") {
            while ($QueryRequest.'@odata.nextLink' -and $QueryRequest.'@odata.nextLink' -is [string]) {
                $QueryRequest = Invoke-RestMethod -Headers $HeaderParams -Uri $QueryRequest.'@odata.nextLink' -UseBasicParsing -Method $Method -ContentType "application/json" -Verbose:$false
                $dataToUpload += $QueryRequest.value
            }
            While ($QueryRequest.nextLink -and $QueryRequest.nextLink -is [string]) {
                $QueryRequest = Invoke-RestMethod -Headers $HeaderParams -Uri $QueryRequest.'nextLink' -UseBasicParsing -Method $Method -ContentType "application/json" -Verbose:$false #4>$null
                $dataToUpload += $QueryRequest.value
            }
            While ($QueryRequest.'$skipToken' -and $QueryRequest.'$skipToken' -is [string] -and $Body -ne '') {
                $tempBody = $Body | ConvertFrom-Json -AsHashtable
                $tempBody.'$skipToken' = $QueryRequest.'$skipToken'
                $Body = $tempBody | ConvertTo-Json -Depth 99
                $QueryRequest = Invoke-RestMethod -Headers $HeaderParams -Uri $Uri -UseBasicParsing -Method $Method -ContentType "application/json" -Body $Body -Verbose:$false #4>$null
                $dataToUpload += $QueryRequest.data
            }
        }
        $dataToUpload
    }
    else {
        Write-Error "No Access Token"
    }
}

#EndRegion Configuration and Utility Functions

#Region Session Host Lifecycle Functions

function Deploy-SessionHosts {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string[]] $ExistingSessionHostNames = @(),

        [Parameter(Mandatory = $true)]
        [int] $NewSessionHostsCount,

        [Parameter(Mandatory = $false)]
        [string] $HostPoolResourceGroupName = (Read-FunctionAppSetting HostPoolResourceGroupName),

        [Parameter(Mandatory = $true)]
        [string] $VirtualMachinesResourceGroupName,

        [Parameter()]
        [string] $HostPoolName = (Read-FunctionAppSetting HostPoolName),

        [Parameter()]
        [string] $SessionHostNamePrefix = (Read-FunctionAppSetting SessionHostNamePrefix),

        [Parameter()]
        [int] $SessionHostInstanceNumberPadding = (Read-FunctionAppSetting SessionHostInstanceNumberPadding),

        [Parameter()]
        [string] $DeploymentPrefix = (Read-FunctionAppSetting SHRDeploymentPrefix),

        [Parameter()]
        [hashtable] $SessionHostParameters = (Read-FunctionAppSetting SessionHostParameters | ConvertTo-CaseInsensitiveHashtable)

        [Parameter()]
        [string] $SessionHostTemplate = (Read-FunctionAppSetting SessionHostTemplate),

        [Parameter()]
        [string] $TagIncludeInAutomation = (Read-FunctionAppSetting Tag_IncludeInAutomation),

        [Parameter()]
        [string] $TagDeployTimestamp = (Read-FunctionAppSetting Tag_DeployTimestamp)
    )

    Write-HostDetailed -Message "Generating new token for the host pool $HostPoolName in Resource Group $HostPoolResourceGroupName"
    $Body = @{
        properties = @{
            registrationInfo = @{
                expirationTime             = (Get-Date).AddHours(8)
                registrationTokenOperation = 'Update'
            }
        }
    }
    Invoke-AzureRestMethod `
        -AccessToken $AccessToken `
        -Body ($Body | ConvertTo-Json -depth 10) `
        -Method Patch `
        -Uri ($ResourceManagerUrl + '/subscriptions/' + $SubscriptionId + '/resourceGroups/' + $HostPoolResourceGroupName + '/providers/Microsoft.DesktopVirtualization/hostPools/' + $HostPoolName + '?api-version=2024-04-03') | Out-Null
    
    # Calculate Session Host Names
    Write-HostDetailed -Level Host -Message "Existing session host VM names: {0}" -StringValues ($ExistingSessionHostNames -join ',')
    [array] $sessionHostNames = for ($i = 0; $i -lt $NewSessionHostsCount; $i++) {
        $shNumber = 1
        While (("$SessionHostNamePrefix{0:d$SessionHostInstanceNumberPadding}" -f $shNumber) -in $ExistingSessionHostNames) {
            $shNumber++
        }
        $shName = "$SessionHostNamePrefix{0:d$SessionHostInstanceNumberPadding}" -f $shNumber
        $ExistingSessionHostNames += $shName
        $shName
    }
    Write-HostDetailed -Message "Creating session host(s) " + ($sessionHostNames -join ', ')

    # Update Session Host Parameters
    $sessionHostParameters['sessionHostNames'] = $sessionHostNames
    $sessionHostParameters['Tags'][$TagIncludeInAutomation] = $true
    $sessionHostParameters['Tags'][$TagDeployTimestamp] = (Get-Date -AsUTC -Format 'o')
    $deploymentTimestamp = Get-Date -AsUTC -Format 'FileDateTime'
    $deploymentName = "{0}_{1}_Count_{2}_VMs" -f $DeploymentPrefix, $deploymentTimestamp, $sessionHostNames.count
    
    Write-HostDetailed -Message "Deployment name: $deploymentName"
    Write-HostDetailed -Message "Deploying using Template Spec: $sessionHostTemplate"
    $templateSpecVersionResourceId = Get-TemplateSpecVersionResourceId -ResourceId $SessionHostTemplate

    Write-HostDetailed -Message "Deploying $NewSessionHostCount session host(s) to resource group $VirtualMachinesResourceGroupName" 
    
    $Body = @{
        properties = @{
            parameters   = $sessionHostParameters
            templateLink = @{
                id = $templateSpecVersionResourceId
            }
        }
    }
    $Uri = $ResourceManagerUrl + '/subscriptions/' + $SubscriptionId + '/resourceGroups/' + $VirtualMachinesResourceGroupName + '/providers/Microsoft.Resources/deployments/' + $deploymentName + '?api-version=2021-04-01'
    $DeploymentJob = Invoke-AzureRestMethod `
        -AccessToken $AccessToken `
        -Body ($Body | ConvertTo-Json -depth 20) `
        -Method Put `
        -Uri $Uri
    #TODO: Add logic to test if deployment is running (aka template is accepted) then finish running the function and let the deployment run in the background.
    Write-HostDetailed -Message 'Pausing for 30 seconds to allow deployment to start'
    Start-Sleep -Seconds 30
    # Check deployment status, if any has failed we report an error
    if ($deploymentJob.Error) {
        Write-HostDetailed "DeploymentFailed"
        throw $deploymentJob.Error
    }
}

function Get-LatestImageVersion {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $ResourceManagerUrl,

        [Parameter(Mandatory = $true)]
        [string] $SubscriptionId,

        # An Image reference object. Can be from Marketplace or Shared Image Gallery.
        [Parameter()]
        [hashtable] $ImageReference,

        [Parameter()]
        [string] $Location
    )

    # Marketplace image
    if ($ImageReference.publisher) {
        #TODO Do we need to change location here?
        if ($ImageReference.version -ne 'latest') {
            Write-HostDetailed  "Image version is not set to latest. Returning version '$($ImageReference.version)'"
            $azImageVersion = $ImageReference.version
        }
        else {
            # Get the Images and select the latest version.           
            Write-HostDetailed "Getting latest version of image publisher: $($ImageReference.publisher), offer: $($ImageReference.offer), sku: $($ImageReference.sku) in region: $($Location)"
                      
            $Uri = $ResourceManagerUrl + "/subscriptions/$SubscriptionId/providers/Microsoft.Compute/locations/$Location/publishers/$($ImageReference.publisher)/artifacttypes/vmimage/offers/$($ImageReference.offer)/skus/$($ImageReference.sku)/versions?api-version=2024-07-01"
            
            $Versions = Invoke-AzureRestMethod -AccessToken $AccessToken -Uri $Uri -Method Get

            $azImageVersion = ($Versions | Sort-Object -Property { [version] $_.Name } -Descending | Select-Object -First 1).Name
            Write-HostDetailed  "Latest version of image is $azImageVersion"

            if ($azImageVersion -match "\d+\.\d+\.(?<Year>\d{2})(?<Month>\d{2})(?<Day>\d{2})") {
                $azImageDate = Get-Date -Date ("20{0}-{1}-{2}" -f $Matches.Year, $Matches.Month, $Matches.Day)
                Write-HostDetailed  "Image date is $azImageDate"
            }
            else {
                throw "Image version does not match expected format. Could not extract image date."
            }
        }
    }
    elseif ($ImageReference.Id) {
        # Shared Image Gallery
        Write-HostDetailed "Image is from Shared Image Gallery: $($ImageReference.Id)"
        $imageDefinitionResourceIdPattern = '^\/subscriptions\/(?<subscription>[a-z0-9\-]+)\/resourceGroups\/(?<resourceGroup>[^\/]+)\/providers\/Microsoft\.Compute\/galleries\/(?<gallery>[^\/]+)\/images\/(?<image>[^\/]+)$'
        $imageVersionResourceIdPattern = '^\/subscriptions\/(?<subscription>[a-z0-9\-]+)\/resourceGroups\/(?<resourceGroup>[^\/]+)\/providers\/Microsoft\.Compute\/galleries\/(?<gallery>[^\/]+)\/images\/(?<image>[^\/]+)\/versions\/(?<version>[^\/]+)$'
        if ($ImageReference.Id -match $imageDefinitionResourceIdPattern) {
            Write-HostDetailed 'Image reference is an Image Definition resource.'
            $imageSubscriptionId = $Matches.subscription
            $imageResourceGroup = $Matches.resourceGroup
            $imageGalleryName = $Matches.gallery
            $imageDefinitionName = $Matches.image

            # Get the latest version of the image
            $Uri = $ResourceManagerUri + "/subscriptions/$imageSubscriptionId/resourceGroups/$imageResourceGroup/providers/Microsoft.Compute/galleries/$imageGalleryName/images/$imageDefinitionName/versions?api-version=2023-07-03"
            $latestImageVersion = Invoke-AzureRestMethod -AccessToken $AccessToken -Method Get -Uri $Uri |
            Where-Object { $_.PublishingProfile.ExcludeFromLatest -eq $false } |
            Sort-Object -Property { $_.PublishingProfile.PublishedDate } -Descending |
            Select-Object -First 1
            if (-not $latestImageVersion) {
                throw "No available image versions found."
            }
            Write-HostDetailed "Selected image version with resource Id {0}" -StringValues $latestImageVersion.Id
            $azImageVersion = $latestImageVersion.Name
            $azImageDate = $latestImageVersion.PublishingProfile.PublishedDate
            Write-HostDetailed "Image version is {0} and date is {1}" -StringValues $azImageVersion, $azImageDate.ToString('o')
        }
        elseif ($ImageReference.Id -match $imageVersionResourceIdPattern ) {
            Write-HostDetailed 'Image reference is an Image Version resource.'
            $Uri = $ResourceManagerUri + "$($ImageReference.Id)?api-version=2023-07-03"
            $azImageVersion = Invoke-AzureRestMethod -AccessToken $AccessToken -Method Get -Uri $Uri
            $azImageVersion = $imageVersion.Name
            $azImageDate = $imageVersion.PublishingProfile.PublishedDate
            Write-HostDetailed "Image version is {0} and date is {1}" -StringValues $azImageVersion, $azImageDate.ToString('o')
        }
        else {
            throw "Image reference Id does not match expected format for an Image Definition resource."
        }
    }
    else {
        throw "Image reference does not contain a publisher or Id property. ImageReference, publisher, and Id are case sensitive!!"
    }
    #return output
    [PSCustomObject]@{
        Version = $azImageVersion
        Date    = $azImageDate
    }
}

function Get-HostPoolDecisions {
    <#
    .SYNOPSIS
        This function will decide how many session hosts to deploy and if we should decommission any session hosts.
    #>
    [CmdletBinding()]
    param (
        # Session hosts to consider
        [Parameter()]
        [array] $SessionHosts = @(),

        # Running deployments
        [Parameter()]
        $RunningDeployments,

        # Target age of session hosts in days - after this many days we consider a session host for replacement.
        [Parameter()]
        [int] $TargetVMAgeDays = (Read-FunctionAppSetting TargetVMAgeDays),

        # Target number of session hosts in the host pool. If we have more than or equal to this number of session hosts we will decommission some.
        [Parameter()]
        [int] $TargetSessionHostCount = (Read-FunctionAppSetting TargetSessionHostCount),

        [Parameter()]
        [int] $TargetSessionHostBuffer = (Read-FunctionAppSetting TargetSessionHostBuffer),

        # Latest image version
        [Parameter()]
        [PSCustomObject] $LatestImageVersion,

        # Should we replace session hosts on new image version
        [Parameter()]
        [bool] $ReplaceSessionHostOnNewImageVersion = (Read-FunctionAppSetting ReplaceSessionHostOnNewImageVersion),

        # Delay days before replacing session hosts on new image version
        [Parameter()]
        [int] $ReplaceSessionHostOnNewImageVersionDelayDays = (Read-FunctionAppSetting ReplaceSessionHostOnNewImageVersionDelayDays),

        # Maximum number of session hosts to replace in a single execution (safety throttle)
        [Parameter()]
        [int] $MaxSessionHostsToReplace = (Read-FunctionAppSetting MaxSessionHostsToReplace)
    )
    # Basic Info
    Write-HostDetailed "We have $($SessionHosts.Count) session hosts (included in Automation)"
    # Identify Session hosts that should be replaced
    if ($TargetVMAgeDays -gt 0) {
        $targetReplacementDate = (Get-Date).AddDays(-$TargetVMAgeDays)
        [array] $sessionHostsOldAge = $SessionHosts | Where-Object { $_.DeployTimestamp -lt $targetReplacementDate }
        Write-HostDetailed "Found $($sessionHostsOldAge.Count) hosts to replace due to old age. $($($sessionHostsOldAge.SessionHostName) -join ',')"

    }

    if ($ReplaceSessionHostOnNewImageVersion) {
        $latestImageAge = (New-TimeSpan -Start $LatestImageVersion.Date -End (Get-Date -AsUTC)).TotalDays
        Write-HostDetailed "Latest Image $($LatestImageVersion.Version) is $latestImageAge days old."
        if ($latestImageAge -ge $ReplaceSessionHostOnNewImageVersionDelayDays) {
            Write-HostDetailed "Latest Image age is older than (or equal) New Image Delay value $ReplaceSessionHostOnNewImageVersionDelayDays"
            [array] $sessionHostsOldVersion = $sessionHosts | Where-Object { $_.ImageVersion -ne $LatestImageVersion.Version }
            Write-HostDetailed "Found $($sessionHostsOldVersion.Count) session hosts to replace due to new image version. $($($sessionHostsOldVersion.SessionHostName) -Join ',')"
        }
    }

    [array] $sessionHostsToReplace = ($sessionHostsOldAge + $sessionHostsOldVersion) | Select-Object -Property * -Unique
    Write-HostDetailed "Found $($sessionHostsToReplace.Count) session hosts to replace in total. $($($sessionHostsToReplace.SessionHostName) -join ',')"

    # Good Session Hosts
    $goodSessionHosts = $SessionHosts | Where-Object { $_.SessionHostName -notin $sessionHostsToReplace.SessionHostName }
    $sessionHostsCurrentTotal = ([array]$goodSessionHosts.SessionHostName + [array]$runningDeployments.SessionHostNames ) | Select-Object -Unique
    Write-HostDetailed "We have $($sessionHostsCurrentTotal.Count) good session hosts including $($runningDeployments.SessionHostName.Count) session hosts being deployed"
    Write-HostDetailed "We target having $TargetSessionHostCount session hosts in good shape"
    Write-HostDetailed "We have a buffer of $TargetSessionHostBuffer session hosts more than the target."
    $weCanDeployUpTo = $TargetSessionHostCount + $TargetSessionHostBuffer - $SessionHosts.count - $RunningDeployments.SessionHostNames.Count
    if ($weCanDeployUpTo -ge 0) {
        Write-HostDetailed "We can deploy up to $weCanDeployUpTo session hosts" 

        $weNeedToDeploy = $TargetSessionHostCount - $sessionHostsCurrentTotal.Count
        if ($weNeedToDeploy -gt 0) {
            Write-HostDetailed "We need to deploy $weNeedToDeploy new session hosts"
            $weCanDeploy = if ($weNeedToDeploy -gt $weCanDeployUpTo) { $weCanDeployUpTo } else { $weNeedToDeploy } # If we need to deploy 10 machines, and we can deploy 5, we should only deploy 5.
            Write-HostDetailed "Buffer allows deploying $weCanDeploy session hosts"
        }
        else {
            $weCanDeploy = 0
            Write-HostDetailed "We have enough session hosts in good shape."
        }
    }
    else {
        Write-HostDetailed "Buffer is full. We can not deploy more session hosts"
        $weCanDeploy = 0
    }
    $weCanDelete = $SessionHosts.Count - $TargetSessionHostCount
    if ($weCanDelete -gt 0) {
        Write-HostDetailed "We need to delete $weCanDelete session hosts"
        if ($weCanDelete -gt $sessionHostsToReplace.Count) {
            Write-HostDetailed "Host pool is over populated"

            $goodSessionHostsToDeleteCount = $weCanDelete - $sessionHostsToReplace.Count
            Write-HostDetailed "We will delete $goodSessionHostsToDeleteCount good session hosts"

            $selectedGoodHostsTotDelete = [array] ($goodSessionHosts | Sort-Object -Property Session | Select-Object -First $goodSessionHostsToDeleteCount)
            Write-HostDetailed "Selected the following good session hosts to delete: $($($selectedGoodHostsTotDelete.VMName) -join ',')"
        }
        else {
            $selectedGoodHostsTotDelete = @()
            Write-HostDetailed "Host pool is not over populated"
        }
        $sessionHostsPendingDelete = ($sessionHostsToReplace + $selectedGoodHostsTotDelete) | Select-Object -First $weCanDelete
        
        # Apply MaxSessionHostsToReplace safety limit
        if ($MaxSessionHostsToReplace -gt 0 -and $sessionHostsPendingDelete.Count -gt $MaxSessionHostsToReplace) {
            Write-HostDetailed "Applying MaxSessionHostsToReplace limit: capping $($sessionHostsPendingDelete.Count) pending deletions to $MaxSessionHostsToReplace"
            $sessionHostsPendingDelete = $sessionHostsPendingDelete | Select-Object -First $MaxSessionHostsToReplace
        }
        
        Write-HostDetailed "The following Session Hosts are now pending delete: $($($SessionHostsPendingDelete.SessionHostName) -join ',')"
    }
    elseif ($sessionHostsToReplace.Count -gt 0) {
        Write-HostDetailed "We need to delete $($sessionHostsToReplace.Count) session hosts but we don't have enough session hosts in the host pool."
    }
    else { Write-HostDetailed "We do not need to delete any session hosts" }

    [PSCustomObject]@{
        PossibleDeploymentsCount       = $weCanDeploy
        PossibleSessionHostDeleteCount = $weCanDelete
        SessionHostsPendingDelete      = $sessionHostsPendingDelete
        ExistingSessionHostNames       = ([array]$SessionHosts.SessionHostName + [array]$runningDeployments.SessionHostNames) | Select-Object -Unique
    }
}

function Get-RunningDeployments {
    <#
    .SYNOPSIS
        This function gets status of all AVD Session Host Replacer deployments in the target resource group.
    .DESCRIPTION
        The function will fail if there are any failed deployments. These should be cleaned up before automation can resume.
        This behavior is to avoid compounding issues due to failing deployments.
        Ideally, the AVD administrator should setup a notification (alert action) when there are failing deployments. # TODO: Add alert setup.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $ResourceGroupName,

        [Parameter()]
        [string] $DeploymentPrefix = (Read-FunctionAppSetting SHRDeploymentPrefix)
    )

    Write-HostDetailed -Message "Getting deployments for resource group '$ResourceGroupName'"
    $Uri = $ResourceManagerUri + "/subscriptions/" + $SubscriptionId + '/resourceGroups/' + $ResourceGroupName + '/providers/Microsoft.Resources/deployments/?api-version=2021-04-01'
    $deployments = Invoke-AzureRestMethod -AccessToken $AccessToken -Method Get -Uri $Uri
    $deployments = Get-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -ErrorAction Stop
    $deployments = $deployments | Where-Object { $_.DeploymentName -like "$DeploymentPrefix*" }
    Write-HostDetailed -Message "Found $($deployments.Count) deployments marked with $DeploymentPrefix."
    # Check for failed deployments
    $failedDeployments = $deployments | Where-Object { $_.ProvisioningState -eq 'Failed' }
    # Terminate if there are any failed deployments
    if ($failedDeployments) {
        Write-HostDetailed -Err -Message "Found $($failedDeployments.Count) failed deployments. These should be cleaned up before automation can resume."
        throw "Found {0} failed deployments. These should be cleaned up before automation can resume." -f $failedDeployments.Count
    }
    # Check for running deployments
    $runningDeployments = $deployments | Where-Object { $_.ProvisioningState -eq 'Running' }
    Write-HostDetailed -Message "Found $($runningDeployments.Count) running deployments."
    # Check for long running deployments
    $warningThreshold = (Get-Date -AsUTC).AddHours(-2)
    $longRunningDeployments = $runningDeployments | Where-Object { $_.Timestamp -lt $warningThreshold }
    if ($longRunningDeployments) {
        Write-HostDetailed -Warn -Message "Found $($longRunningDeployments.Count) deployments that have been running for more than 2 hours. This could block future deployments"
    }

    # Parse deployment names to get VM name
    $output = foreach ($deployment in $runningDeployments) {
        $parameters = $deployment.Parameters | ConvertTo-CaseInsensitiveHashtable
        Write-HostDetailed -Message "Deployment $($deployment.DeploymentName) is running and deploying: $(($parameters['sessionHostNames'].Value -join ','))"
        [PSCustomObject]@{
            DeploymentName   = $deployment.DeploymentName
            SessionHostNames = $parameters['sessionHostNames'].Value
            Timestamp        = $deployment.Timestamp
            Status           = $deployment.ProvisioningState
        }
    }
    $output
}

function Get-SessionHosts {
    [CmdletBinding()]
    param (
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
        [switch] $FixSessionHostTags,
        
        [Parameter()]
        [bool] $IncludePreExistingSessionHosts = (Read-FunctionAppSetting IncludePreExistingSessionHosts)
    )
    
    # Get current session hosts
    Write-HostDetailed -Message "Getting current session hosts in host pool $HostPoolName"
    $Uri = $ResourceManagerUri + '/subscriptions/' + $subscriptionId + '/resourceGroups/' + $ResourceGroupName + '/providers/Microsoft.DesktopVirtualization/hostPools/' + $HostPoolName + '/sessionHosts?api-version=2024-04-03'
    $sessionHosts = Invoke-AzureRestMethod -AccessToken $AccessToken -Method Get -Uri $Uri | Select-Object Name, ResourceId, Session, AllowNewSession, Status
    Write-HostDetailed -Message "Found $($sessionHosts.Count) session hosts"
    # For each session host, get the VM details
    $result = foreach ($sh in $sessionHosts) {
        Write-HostDetailed -Message "Getting VM details for $($sh.Name)"
        $Uri = $ResourceManagerUri + $sh.ResourceId + '?api-version=2024-03-01'
        $vm = Invoke-AzureRestMethod -AccessToken $AccessToken -Method Get -Uri $Uri | Select-Object Name, TimeCreated, StorageProfile
        Write-HostDetailed -Message "VM was created on $($vm.TimeCreated)"
        Write-HostDetailed -Message "VM exact version is $($vm.StorageProfile.ImageReference.ExactVersion)"
        Write-HostDetailed -Message 'Getting VM tags'
        $Uri = $ResourceManagerUri + $sh.ResourceId + '/providers/Microsoft.Resources/tags/default?api-version=2021-04-01'
        $vmTags = Invoke-AzureRestMethod -AccessToken $AccessToken -Method Get -Uri $Uri
        $vmDeployTimeStamp = $vmTags.Properties.TagsProperty[$TagDeployTimestamp]
        try {
            $vmDeployTimeStamp = [DateTime]::Parse($vmDeployTimeStamp)
            Write-HostDetailed -Message "VM has a tag $TagDeployTimestamp with value $vmDeployTimeStamp"
        }
        catch {
            $value = if ($null -eq $vmDeployTimeStamp) { 'null' } else { $vmDeployTimeStamp }
            Write-HostDetailed -Message "VM tag $TagDeployTimestamp with value $value is not a valid date"
            if ($FixSessionHostTags) {
                Write-HostDetailed -Message "Copying VM CreateTime to tag $TagDeployTimestamp with value $($vm.TimeCreated.ToString('o'))"
                $Body = @{
                    operation  = 'Merge'
                    properties = @{
                        $TagDeployTimestamp = $vm.TimeCreated.ToString('o')
                    }
                }
                Invoke-AzureRestMethod -AccessToken $AccessToken -Body ($Body | ConvertTo-Json -Depth 10) -Method PATCH -Uri $Uri
            }
            $vmDeployTimeStamp = $vm.TimeCreated
        }
        $vmIncludeInAutomation = $vmTags.Properties.TagsProperty[$TagIncludeInAutomation]
        if ($vmIncludeInAutomation -eq "True") {
            Write-HostDetailed -Message "VM has a tag $TagIncludeInAutomation with value $vmIncludeInAutomation" 
            $vmIncludeInAutomation = $true
        }
        elseif ($vmIncludeInAutomation -eq "False") {
            Write-HostDetailed -Message "VM has a tag $TagIncludeInAutomation with value $vmIncludeInAutomation"
            $vmIncludeInAutomation = $false
        }
        else {
            $value = if ($null -eq $vmIncludeInAutomation) { 'null' } else { $vmIncludeInAutomation }
            Write-HostDetailed -Message "VM tag with $TagIncludeInAutomation value $value is not set to True/False"
            if ($FixSessionHostTags) {
                Write-HostDetailed -Message "Setting tag $TagIncludeInAutomation to $IncludePreExistingSessionHosts"
                $Body = @{
                    operation  = 'Merge'
                    properties = @{
                        $TagIncludeInAutomation = $IncludePreExistingSessionHosts
                    }
                }
                Invoke-AzureRestMethod -AccessToken $AccessToken -Body ($Body | ConvertTo-Json -Depth 10) -Method PATCH -Uri $Uri
            }
            $vmIncludeInAutomation = $IncludePreExistingSessionHosts
        }
        $vmPendingDrainTimeStamp = $vmTags.Properties.TagsProperty[$TagPendingDrainTimeStamp]
        try {
            $vmPendingDrainTimeStamp = [DateTime]::Parse($vmPendingDrainTimeStamp)
            Write-OutputDetailed -Message "VM has a tag $TagPendingDrainTimeStamp with value $vmPendingDrainTimeStamp" 
        }
        catch {
            Write-OutputDetailed -Message "VM tag $TagPendingDrainTimeStamp is not set." 
            $vmPendingDrainTimeStamp = $null
        }

        # Extract FQDN and session host name (hostname without domain)
        $fqdn = $sh.Name -replace ".+\/(.+)", '$1'
        $sessionHostName = $fqdn -replace '\..*$', ''  # Remove domain, keep only hostname
        
        $hostOutput = @{ # We are combining the VM details and SessionHost objects into a single PS Custom Object
            VMName                = $vm.Name
            SessionHostName       = $sessionHostName
            FQDN                  = $fqdn
            DeployTimestamp       = $vmDeployTimeStamp
            IncludeInAutomation   = $vmIncludeInAutomation
            PendingDrainTimeStamp = $vmPendingDrainTimeStamp
            ImageVersion          = $vm.StorageProfile.ImageReference.ExactVersion
        }
        $sh.PSObject.Properties.ForEach{ $hostOutput[$_.Name] = $_.Value }
        [PSCustomObject]$hostOutput
    }
    $result
}

#EndRegion Session Host Lifecycle Functions

#Region Session Host Helper Functions

function Get-SessionHostParameters {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string] $SessionHostParameters = (Read-FunctionAppSetting SessionHostParameters)
    )
    $paramsHash = ConvertFrom-Json $SessionHostParameters -Depth 99 -AsHashtable
    Write-HostDetailed -Message "Session host parameters: $($paramsHash | Out-String)"
    $paramsHash
}

function Get-TemplateSpecVersionResourceId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceId
    )
    $Uri = $ResourceManagerUri + $ResourceId + '?api-version=2021-04-01'    
    $azResourceType = (Invoke-AzureRestMethod -AccessToken $AccessToken -Method Get -Uri $Uri).ResourceType
    Write-HostDetailed -Message "Resource type: $azResourceType"
    switch ($azResourceType) {
        'Microsoft.Resources/templateSpecs' {
            # Get resource Id of the latest version of the template spec
            $Uri = $ResourceManagerUri + $ResourceId + '?$expand=versions&api-version=2021-05-01'
            $templateSpecVersions = (Invoke-AzureRestMethod -AccessToken $AccessToken -Method Get -Uri $Uri).Versions
            Write-HostDetailed -Message "Template Spec has $($templateSpecVersions.count) versions"
            $latestVersion = $templateSpecVersions | Sort-Object -Property CreationTime -Descending -Top 1
            Write-HostDetailed -Message "Latest version: $($latestVersion.Name) Created at $($latestVersion.CreationTime.ToString('o')) - Returning Resource Id $($latestVersion.Id)"
            $latestVersion.Id
        }
        'Microsoft.Resources/templateSpecs/versions' {
            # Return the resource Id as is, since supplied value is already a version.
            $ResourceId
        }
        Default {
            throw ("Supplied value has type '{0}' is not a valid Template Spec or Template Spec version resource Id." -f $azResourceType)
        }
    }
}

#EndRegion Session Host Helper Functions

#Region Session Host Removal Functions

function Remove-SessionHosts {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        $SessionHostsPendingDelete,

        [Parameter()]
        [string] $ResourceGroupName = (Read-FunctionAppSetting HostPoolResourceGroupName),

        [Parameter()]
        [string] $HostPoolName = (Read-FunctionAppSetting HostPoolName),

        [Parameter()]
        [int] $DrainGracePeriodHours = (Read-FunctionAppSetting DrainGracePeriodHours),

        [Parameter()]
        [string] $TagPendingDrainTimeStamp = (Read-FunctionAppSetting Tag_PendingDrainTimestamp),

        [Parameter()]
        [string] $TagScalingPlanExclusionTag = (Read-FunctionAppSetting Tag_ScalingPlanExclusionTag),

        [Parameter()]
        [bool] $RemoveEntraDevice,

        [Parameter()]
        [bool] $RemoveIntuneDevice
    )

    foreach ($sessionHost in $SessionHostsPendingDelete) {
        # Does the session host currently have sessions?
        # No sessions => Delete + Remove from host pool
        # Is the session host in drain mode?
        # Yes => Is the drain grace period tag old? => Delete + Remove from host pool
        # NO => Set drain mode + Message users + Set tag

        $drainSessionHost = $false
        $deleteSessionHost = $false

        if ($sessionHost.Session -eq 0) {
            #Does the session host currently have sessions?
            # No sessions => Delete + Remove from host pool
            Write-HostDetailed -Message "Session host $($sessionHost.FQDN) has no sessions." 
            $deleteSessionHost = $true
        }
        else {
            Write-HostDetailed -Message "Session host $($sessionHost.FQDN) has $($sessionHost.Session) sessions." 
            if (-Not $sessionHost.AllowNewSession) {
                # Is the session host in drain mode?
                Write-HostDetailed -Message "Session host $($sessionHost.FQDN) is in drain mode."
                if ($sessionHost.PendingDrainTimeStamp) {
                    #Session host has a drain timestamp
                    Write-HostDetailed -Message "Session Host $($sessionHost.FQDN) drain timestamp is $($sessionHost.PendingDrainTimeStamp)"
                    $maxDrainGracePeriodDate = $sessionHost.PendingDrainTimeStamp.AddHours($DrainGracePeriodHours)
                    Write-HostDetailed -Message "Session Host $($sessionHost.FQDN) can stay in grace period until $($maxDrainGracePeriodDate.ToUniversalTime().ToString('o'))" 
                    if ($maxDrainGracePeriodDate -lt (Get-Date)) {
                        Write-HostDetailed -Message "Session Host $($sessionHost.FQDN) has exceeded the drain grace period."
                        $deleteSessionHost = $true
                    }
                    else {
                        Write-HostDetailed -Message "Session Host $($sessionHost.FQDN) has not exceeded the drain grace period."
                    }
                }
                else {
                    Write-HostDetailed -Message "Session Host $($sessionHost.FQDN) does not have a drain timestamp."
                    $drainSessionHost = $true
                }
            }
            else {
                Write-HostDetailed -Message "Session host $($sessionHost.Name) in not in drain mode. Turning on drain mode." 
                $drainSessionHost = $true
            }
        }

        if ($drainSessionHost) {
            Write-HostDetailed -Message 'Turning on drain mode.'
            $Uri = $ResourceManagerUri + '/subscriptions/' + $SubscriptionId + '/resourceGroups/' + $ResourceGroupName + '/providers/Microsoft.DesktopVirtualization/hostPools/' + $HostPoolName + '/sessionHosts/' + $sessionHost.FQDN + '?api-version=2024-04-03'
            Invoke-AzureRestMethod `
                -AccessToken $AccessToken `
                -Body (@{properties = @{allowNewSession = $false } } | ConvertTo-Json) `
                -Method 'PATCH' `
                -Uri $Uri
            $drainTimestamp = (Get-Date).ToUniversalTime().ToString('o')
            Write-HostDetailed -Message "Setting drain timestamp on tag $TagPendingDrainTimeStamp to $drainTimestamp."
            $Uri = $ResourceManagerUri + $sessionHost.ResourceId + '/providers/Microsoft.Resources/tags/default?api-version=2021-04-01'
            $Body = @{
                operation  = 'Merge'
                properties = @{
                    $TagPendingDrainTimeStamp = $drainTimestamp
                }
            }
            Invoke-AzureRestMethod -AccessToken $AccessToken -Body ($Body | ConvertTo-Json -Depth 5) -Method PATCH -Uri $Uri
            
            if ($TagScalingPlanExclusionTag -ne ' ') {
                # This is string with a single space.
                Write-HostDetailed -Message "Setting scaling plan exclusion tag $TagScalingPlanExclusionTag to $true."
                $Body = @{
                    operation  = 'Merge'
                    properties = @{
                        $TagScalingPlanExclusionTag = $true
                    }
                }
                Invoke-AzureRestMethod -AccessToken $AccessToken -Body ($Body | ConvertTo-Json -Depth 5) -Method PATCH -Uri $Uri
            }

            Write-HostDetailed -Message 'Notifying Users'
            Send-DrainNotification -SessionHostName ($sessionHost.FQDN)
        }

        if ($deleteSessionHost) {
            Write-HostDetailed -Message "Deleting session host $($SessionHost.SessionHostName)..."
            if ($RemoveEntraDevice) {
                Write-HostDetailed -Message 'Deleting device from Entra ID'
                Remove-EntraDevice -Name $sessionHost.SessionHostName
            }
            if ($RemoveIntuneDevice) {
                Write-HostDetailed -Message 'Deleting device from Intune'
                Remove-IntuneDevice -Name $sessionHost.SessionHostName
            }
            Write-HostDetailed -Message "Removing Session Host from Host Pool $HostPoolName"
            $Uri = $ResourceManagerUri + '/subscriptions/' + $SubscriptionId + '/resourceGroups/' + $ResourceGroupName + '/providers/Microsoft.DesktopVirtualization/hostPools/' + $HostPoolName + '/sessionHosts/' + $sessionHost.FQDN + '?api-version=2024-04-03'
            Invoke-AzureRestMethod -AccessToken $AccessToken -Method DELETE -Uri $Uri            
            Write-HostDetailed -Message "Deleting VM: $($sessionHost.ResourceId)..."
            $Uri = $ResourceManagerUri + $sessionHost.ResourceId + '?forceDeletion=true&api-version=2024-07-01'
            Invoke-AzureRestMethod -AccessToken $AccessToken -Method 'DELETE' -Uri $Uri
            # We are not deleting Disk and NIC as the template should mark the delete option for these resources.
        }
    }
}

function Remove-EntraDevice {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        $GraphEndpoint = $env:GraphEndpoint,
        [Parameter(Mandatory = $true)]
        $GraphToken,
        [Parameter(Mandatory = $true)]
        [string] $Name
    )
    $Headers = @{
        'Authorization' = "Bearer $GraphToken"
    }
    $Device = Invoke-RestMethod -Method Get -Uri ($GraphEndpoint + "/v1.0/devices?`$filter=displayName eq '$Name'") -Headers $Headers
    If ($Device) {
        $Id = $Device.id
        Write-HostDetailed -Message "Removing session host $Name from Entra ID"
        Invoke-RestMethod -Method Delete -Uri $GraphEndpoint + '/v1.0/devices/' + $Id -Headers $Headers
    }    
}

function Remove-IntuneDevice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        $GraphEndpoint = $env:GraphEndpoint,
        [Parameter(Mandatory = $true)]
        $GraphToken,
        [Parameter(Mandatory = $true)]
        [string] $Name
    )
    $Headers = @{
        'Authorization' = "Bearer $GraphToken"
    }
    $Device = Invoke-RestMethod -Method Get -Uri ($GraphEndpoint + "/v1.0/deviceManagement/managedDevices?`$filter=deviceName eq '$Name'") -Headers $Headers
    If ($Device) {
        $Id = $Device.id
        Write-HostDetailed -Message "Removing session host '$Name' device from Intune"
        Invoke-RestMethod -Method Delete -Uri $GraphEndpoint + '/v1.0/deviceManagement/managedDevices/' + $Id -Headers $Headers
    }
}

#EndRegion Session Host Removal Functions

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

#Region Notification Functions

function Send-DrainNotification {
    <#
    .SYNOPSIS
        Sends drain notifications to users on a session host pending deletion.
    .DESCRIPTION
        Retrieves all user sessions on the specified session host and sends a message
        notifying them of the pending maintenance and replacement.
    .PARAMETER SessionHostName
        The FQDN of the session host (e.g., hostpool/vmname.domain.com).
    .PARAMETER HostPoolName
        Name of the host pool.
    .PARAMETER ResourceGroupName
        Name of the resource group containing the host pool.
    .PARAMETER DrainGracePeriodHours
        Number of hours before the session host will be forcefully disconnected.
    .PARAMETER MessageTitle
        Title of the notification message.
    .PARAMETER MessageBody
        Body of the notification message. Use {0} for session host name and {1} for hours.
    .EXAMPLE
        Send-DrainNotification -SessionHostName 'hostpool/vm001.contoso.com'
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $SessionHostName,

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
        $AccessToken = Get-AccessToken
        $ResourceManagerUri = (Get-AzContext).Environment.ResourceManagerUrl
        $SubscriptionId = (Get-AzContext).Subscription.Id
        
        # Get all user sessions on the session host
        Write-HostDetailed -Message "Getting user sessions for session host $SessionHostName"
        $SessionsUri = $ResourceManagerUri + '/subscriptions/' + $SubscriptionId + '/resourceGroups/' + $ResourceGroupName + '/providers/Microsoft.DesktopVirtualization/hostPools/' + $HostPoolName + '/sessionHosts/' + $SessionHostName + '/userSessions?api-version=2024-04-03'
        
        $sessions = Invoke-AzureRestMethod -AccessToken $AccessToken -Method Get -Uri $SessionsUri
        
        if ($null -eq $sessions -or $sessions.Count -eq 0) {
            Write-HostDetailed -Message "No active sessions found on session host $SessionHostName"
            return
        }
        
        # Send message to each user session
        foreach ($session in $sessions) {
            $sessionId = $session.Name -replace '.+\/.+\/(.+)', '$1'
            $userPrincipalName = $session.Properties.UserPrincipalName
            
            if ([string]::IsNullOrWhiteSpace($sessionId)) {
                Write-HostDetailed -Message "Skipping session with invalid ID" -Level Warning
                continue
            }
            
            $formattedMessageBody = $MessageBody -f $SessionHostName, $DrainGracePeriodHours
            
            Write-HostDetailed -Message "Sending drain notification to user $userPrincipalName on session $sessionId"
            
            $MessageUri = $ResourceManagerUri + '/subscriptions/' + $SubscriptionId + '/resourceGroups/' + $ResourceGroupName + '/providers/Microsoft.DesktopVirtualization/hostPools/' + $HostPoolName + '/sessionHosts/' + $SessionHostName + '/userSessions/' + $sessionId + '/sendMessage?api-version=2024-04-03'
            
            $MessagePayload = @{
                messageTitle = $MessageTitle
                messageBody  = $formattedMessageBody
            } | ConvertTo-Json -Depth 10
            
            try {
                Invoke-AzureRestMethod -AccessToken $AccessToken -Method Post -Uri $MessageUri -Body $MessagePayload | Out-Null
                Write-HostDetailed -Message "Successfully sent message to user $userPrincipalName"
            }
            catch {
                Write-HostDetailed -Message "Failed to send message to user $userPrincipalName : $_" -Level Warning
            }
        }
    }
    catch {
        Write-HostDetailed -Message "Error in Send-DrainNotification: $_" -Level Error
    }
}

#EndRegion Session Host Removal Functions

#Region Optional Enhanced Functions (Token Caching)

function Get-GraphTokenCached {
    <#
    .SYNOPSIS
        Gets Microsoft Graph access token with caching.
    .DESCRIPTION
        Retrieves Graph token from cache if valid, otherwise acquires new token.
    .PARAMETER TenantId
        Azure AD tenant ID.
    .PARAMETER ClientId
        Service principal client ID.
    .PARAMETER ForceRefresh
        Forces token refresh even if cached token is valid.
    .EXAMPLE
        $graphToken = Get-GraphTokenCached -TenantId $tenantId -ClientId $clientId
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        [string] $TenantId,
        
        [Parameter()]
        [string] $ClientId,
        
        [Parameter()]
        [switch] $ForceRefresh
    )
    
    # Check if cached token is still valid (with 5 minute buffer)
    if (-not $ForceRefresh -and 
        $Script:GraphTokenCache.Token -and 
        $Script:GraphTokenCache.ExpiresOn -gt (Get-Date).AddMinutes(5)) {
        Write-Verbose "Using cached Graph token (expires: $($Script:GraphTokenCache.ExpiresOn))"
        return $Script:GraphTokenCache.Token
    }
    
    # Get configuration if not provided
    if ([string]::IsNullOrEmpty($TenantId)) {
        $TenantId = Read-FunctionAppSetting TenantId
    }
    if ([string]::IsNullOrEmpty($ClientId)) {
        $ClientId = Read-FunctionAppSetting UserAssignedIdentityClientId
    }
    
    # Get environment-specific Graph URL from configuration
    $graphUrl = Read-FunctionAppSetting GraphEndpoint
    if ([string]::IsNullOrEmpty($graphUrl)) {
        throw "GraphEndpoint configuration is required but not set in Function App Settings"
    }
    
    Write-Verbose "Using Graph URL: $graphUrl"
    
    # Get access token for Resource Manager to exchange for Graph token
    $resourceManagerUrl = Read-FunctionAppSetting ResourceManagerUrl
    $accessToken = Get-AccessToken -Resource $resourceManagerUrl -ClientId $ClientId
    
    $headers = @{
        'Authorization' = "Bearer $accessToken"
        'Content-Type'  = 'application/json'
    }
    
    $body = @{
        resource  = $graphUrl
        client_id = $ClientId
    } | ConvertTo-Json
    
    try {
        $response = Invoke-RestMethod -Uri "$($env:IDENTITY_ENDPOINT)?api-version=2019-08-01&client_id=$ClientId" -Method Post -Headers $headers -Body $body
        
        # Cache the token - calculate expiration (typically 3600 seconds)
        $Script:GraphTokenCache.Token = $response.access_token
        $Script:GraphTokenCache.ExpiresOn = (Get-Date).AddSeconds(3600)
        
        Write-Verbose "Retrieved new Graph token (expires: $($Script:GraphTokenCache.ExpiresOn))"
        return $response.access_token
    }
    catch {
        Write-Error "Failed to acquire Graph token: $_"
        throw
    }
}

#EndRegion Optional: Enhanced Token Caching

<#
.NOTES
    Microsoft Graph API Documentation:
    
    Environment Detection:
    https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/bicep-functions-deployment#environment
    https://learn.microsoft.com/en-us/graph/deployments
    
    Entra ID Device Management:
    https://learn.microsoft.com/en-us/graph/api/device-list?view=graph-rest-1.0&tabs=http
    https://learn.microsoft.com/en-us/graph/api/device-delete?view=graph-rest-1.0&tabs=http
    
    Intune Device Management:
    https://learn.microsoft.com/en-us/graph/api/intune-devices-manageddevice-list?view=graph-rest-1.0
    DELETE https://graph.microsoft.com/v1.0/devices/{id}
#>

