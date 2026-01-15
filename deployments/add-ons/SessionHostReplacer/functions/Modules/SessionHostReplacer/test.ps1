# Azure Functions profile.ps1
#
# This profile.ps1 will get executed every "cold start" of your Function App.
# "cold start" occurs when:
#
# * A Function App starts up for the very first time
# * A Function App starts up after being de-allocated due to inactivity
#
# You can define helper functions, run commands, or specify environment variables
# NOTE: any variables defined that are not environment variables will get reset after the first execution


Set-Variable -Name useNewSSPCode -Value $true -Option Constant

If ($env:debug -eq 'true') {
    $ErrorActionPreference = 'Continue'
    $WarningPreference = 'Continue'
    $VerbosePreference = 'Continue'
    $InformationPreference = 'Continue'
    $DebugPreference = 'SilentlyContinue'
    $ProgressPreference = 'Continue'
    $LogCommandHealthEvent = $false
    $LogCommandLifecycleEvent = $false
    $LogEngineHealthEvent = $true
    $LogEngineLifecycleEvent = $true
    $LogProviderHealthEvent = $true
    $LogProviderLifecycleEvent = $true
    $MaximumHistoryCount = 4096
    $PSDefaultParameterValues = @{
        "*:Verbose"           = $true
        "*:ErrorAction"       = 'Continue'
        "*:WarningAction"     = 'Continue'
        "*:InformationAction" = 'SilentlyContinue'
    }
}
Else {
    $ErrorActionPreference = 'SilentlyContinue'
    $WarningPreference = 'SilentlyContinue'
    $VerbosePreference = 'SilentlyContinue'
    $InformationPreference = 'SilentlyContinue'
    $DebugPreference = 'SilentlyContinue'
    $ProgressPreference = 'SilentlyContinue'
    $LogCommandHealthEvent = $false
    $LogCommandLifecycleEvent = $false
    $LogEngineHealthEvent = $false
    $LogEngineLifecycleEvent = $false
    $LogProviderHealthEvent = $false
    $LogProviderLifecycleEvent = $false
    $MaximumHistoryCount = 1
    $PSDefaultParameterValues = @{
        "*:Verbose"           = $false
        "*:ErrorAction"       = 'SilentlyContinue'
        "*:WarningAction"     = 'SilentlyContinue'
        "*:InformationAction" = 'SilentlyContinue'
    }
}



#region Variables
$cloud = $env:Cloud
Set-Variable -Name landingZoneDisplayName -Value 'Landing Zone' -Option Constant
Set-Variable -Name platformGroupDisplayName -Value 'Platform' -Option Constant
Set-Variable -Name deprovisionedGroupDisplayName -value 'Deprovisioned' -Option Constant
#Set to TLS1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

switch ($cloud.tolower()) {
    'commercial' {
        Set-Variable -Name managementApiBase -Value 'management.azure.com' -Option Constant
        Set-Variable -Name TokenResourceUrl -Value 'https://management.azure.com' -Option Constant
        Set-Variable -Name StorageTokenResourceUrl -Value 'https://storage.azure.com' -Option Constant
        Set-Variable -Name LoginUrl -Value "https://login.microsoftonline.com" -Option Constant
        Set-Variable -Name GraphResourceUrl -Value "https://graph.microsoft.com" -Option Constant
        Set-Variable -Name StorageResourceUrl -Value "https://storage.azure.com" -Option Constant
        Set-Variable -Name PrivGroupUrl -Value "https://api.azrbac.mspim.azure.com" -Option Constant
        Set-Variable -Name LogAnalyticsUrl -Value "https://api.loganalytics.io" -Option Constant
        Set-Variable -Name odsEndpoint -Value 'ods.opinsights.azure.com' -Option Constant
        Set-Variable -Name SecurityCenterUrl -Value 'https://api-gcc.securitycenter.microsoft.us' -Option Constant
        Set-Variable -Name emailURI -Value 'https://uweemail-la.azurewebsites.net:443/api/UWEEmail3/triggers/When_a_HTTP_request_is_received/invoke?api-version=2022-05-01&sp=%2Ftriggers%2FWhen_a_HTTP_request_is_received%2Frun&sv=1.0&sig=IUzkRrTyWe_NT2FvkMqHEUAGUksaSgPma-0wrzVK9Cs' -Option Constant
        Set-Variable -Name emailURI2 -Value'https://uweemail-la.azurewebsites.net:443/api/EmailOnly-NoAttachment/triggers/When_a_HTTP_request_is_received/invoke?api-version=2022-05-01&sp=%2Ftriggers%2FWhen_a_HTTP_request_is_received%2Frun&sv=1.0&sig=YkMxgUl5nPiHsFuoLx_XYI-eu5dzBbDgBDun1j75Bbw' -Option Constant
        Set-Variable -Name CloudEnvironment -Value 'AzureCloud' -Option Constant
        Set-Variable -Name KeyVaultUrl -Value 'https://vault.azure.net' -Option Constant
        Set-Variable -Name storageEndpointSuffix -Value 'core.windows.net' -Option Constant
        Set-Variable -Name AzureWebsitesSuffix -Value 'azurewebsites.net' -Option Constant
        Set-Variable -Name DefenderXDRAPIUrl -Value 'https://api-gcc.security.microsoft.us' -Option Constant
        Set-Variable -Name SecurityCenterAuthURI -Value 'https://securitycenter.microsoft.com/mtp' -Option Constant
        Set-Variable -Name AppInsightsURI -Value 'https://api.applicationinsights.io' -Option Constant
    }
    'mag' {
        Set-Variable -Name managementApiBase -Value 'management.usgovcloudapi.net' -Option Constant
        Set-Variable -Name TokenResourceUrl -Value 'https://management.usgovcloudapi.net' -Option Constant
        Set-Variable -Name StorageTokenResourceUrl -Value 'https://storage.azure.com' -Option Constant
        Set-Variable -Name LoginUrl -Value "https://login.microsoftonline.us" -Option Constant
        Set-Variable -Name GraphResourceUrl -Value "https://graph.microsoft.us" -Option Constant
        Set-Variable -Name StorageResourceUrl -Value "https://storage.usgovcloudapi.net" -Option Constant
        Set-Variable -Name PrivGroupUrl -Value "https://api.azrbac.mspim.azure.us" -Option Constant
        Set-Variable -Name LogAnalyticsUrl -Value "https://api.loganalytics.us" -Option Constant
        Set-Variable -Name odsEndpoint -Value 'ods.opinsights.azure.us' -Option Constant
        Set-Variable -Name SecurityCenterUrl -Value 'https://api-gov.securitycenter.microsoft.us' -Option Constant
        #Do not define an emailURI here since MAG isn't supposed to send to email
        #Do not define an emailURI2 here since MAG isn't supposed to send to email
        Set-Variable -Name CloudEnvironment -Value 'AzureUSGovernment' -Option Constant
        Set-Variable -Name KeyVaultUrl -Value 'https://vault.usgovcloudapi.net' -Option Constant
        Set-Variable -Name storageEndpointSuffix -Value 'core.usgovcloudapi.net' -Option Constant
        Set-Variable -Name AzureWebsitesSuffix -Value 'azurewebsites.us' -Option Constant
        Set-Variable -Name DefenderXDRAPIUrl -Value 'https://api-gov.security.microsoft.us' -Option Constant
        Set-Variable -Name SecurityCenterAuthURI -Value 'https://securitycenter.microsoft.com/mtp' -Option Constant
        Set-Variable -Name AppInsightsURI -Value 'https://api.applicationinsights.us' -Option Constant
    }
    Default {
        Write-Error "The PowerShell profile failed to finish loading properly. Variables and functions are not defined as expected."
        Write-Error "Correct the variable 'Cloud' defined in the function app configuration and be sure it has a valid value of either 'commercial' or 'mag'."
        throw 'Failed PS Profile configuration'
    }
}

if ($env:MSI_SECRET) {
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity -Environment $CloudEnvironment
}

#endregion Variables

#region Functions
Function Lookup-EntraUserId{
    <#
    .SYNOPSIS
    Looks up the user ID in the Entra system.
   
    .DESCRIPTION
    This function retrieves the user information from the Entra system based on the provided user ID.
   
    .PARAMETER Id
    The user ID to lookup in the Entra system.
   
    .EXAMPLE
    Lookup-EntraUserId -Id "12345"
   
    This example demonstrates how to use the Lookup-EntraUserId function to retrieve the user information for the user with ID "12345" from the Entra system.
   
    .NOTES
    This function requires the Connect-AcquireToken function to be executed prior to calling this function in order to acquire the necessary access token.
    #>
    param(
        [parameter(Mandatory = $true)]
        [string]$Id
        )
    $graphToken = Connect-AcquireToken -TokenResourceUrl $GraphResourceUrl
    $headers = @{
        Authorization = "Bearer $graphToken"
        ConsistencyLevel = 'eventual'
    }
    $uri = "$GraphResourceUrl/v1.0/users?`$filter=Id eq '$Id'&`$count=true"
    $result = invoke-restmethod -Method Get -Uri $uri -Headers $headers 4>$Null
    $result.value
}

Function Lookup-EntraServicePrincipalAppId{
    <#
    .SYNOPSIS
    Lookup-EntraServicePrincipalAppId function retrieves the service principals with a specific App ID from the Microsoft Graph API.

    .DESCRIPTION
    The Lookup-EntraServicePrincipalAppId function queries the Microsoft Graph API to retrieve service principals that have a specific App ID. It requires an App ID as input and returns a list of service principals matching the provided App ID.

    .PARAMETER appId
    Specifies the App ID of the service principal to lookup.

    .EXAMPLE
    Lookup-EntraServicePrincipalAppId -appId "12345678-1234-1234-1234-1234567890ab"
    This example retrieves the service principals with the App ID "12345678-1234-1234-1234-1234567890ab" from the Microsoft Graph API.

    #>
    param(
        [parameter(Mandatory = $true)]
        [string]$appId
    )
    $graphToken = Connect-AcquireToken -TokenResourceUrl $GraphResourceUrl
    $headers = @{
        Authorization = "Bearer $graphToken"
        ConsistencyLevel = 'eventual'
    }
    $uri = "$GraphResourceUrl/v1.0/servicePrincipals?`$filter=appId eq '$appId'&`$count=true"
    $result = invoke-restmethod -Method Get -Uri $uri -Headers $headers 4>$Null
    $result.value
}

Function Lookup-EntraGroupId{
    param(
        [parameter(Mandatory = $true)]
        [string]$groupId
        )
    $graphToken = Connect-AcquireToken -TokenResourceUrl $GraphResourceUrl
    $headers = @{
        Authorization = "Bearer $graphToken"
    }
    $uri = "$GraphResourceUrl/v1.0/groups/$groupId"
    $result = invoke-restmethod -Method Get -Uri $uri -Headers $headers 4>$Null
    $result
}


function Connect-AcquireToken {
    <#
    .SYNOPSIS
    Connects to Azure AD and acquires an access token for the specified token resource URL.

    .DESCRIPTION
    The Connect-AcquireToken function connects to Azure AD and acquires an access token for the specified token resource URL. It supports both managed identity and service principal authentication methods.

    .PARAMETER TokenResourceUrl
    The URL of the token resource for which to acquire the access token. The default value is $GraphResourceUrl.

    .EXAMPLE
    Connect-AcquireToken -TokenResourceUrl "https://graph.microsoft.com"
    This example connects to Azure AD and acquires an access token for the Microsoft Graph API.

    .INPUTS
    None

    .OUTPUTS
    System.String

    .NOTES
    This function requires the Azure PowerShell module to be installed.

    .LINK
    https://docs.microsoft.com/en-us/powershell/azure/new-azureps-module-az?view=azps-12.0.0
    #>
    [CmdletBinding()]
    param (
        [string]$TokenResourceUrl = $GraphResourceUrl
    )

    if ($env:MSI_ENDPOINT) {
        return Connect-AcquireTokenViaManagedIdentity -TokenResourceUrl $TokenResourceUrl
    }Else{
        #(Get-AzAccessToken -ResourceUrl $TokenResourceUrl).token
        ConvertFrom-SecureString -SecureString (Get-AzAccessToken -ResourceUrl $TokenResourceUrl -AsSecureString).token -AsPlainText
    }

    #Service principals are no longer supported, allocating this for testing instead
    #return Connect-AcquireTokenViaServicePrincipal -TokenResourceUrl $TokenResourceUrl
}

#Adapting https://github.com/DanielChronlund/DCToolbox/blob/main/DCToolbox.psm1 for use in application to pull JSON
function Connect-DCMsGraphAsApplication {
    <#
        .SYNOPSIS
            Connect to Microsoft Graph with application credentials.
        .DESCRIPTION
            This CMDlet will automatically connect to Microsoft Graph using application permissions (as opposed to delegated credentials). If successfull an access token is returned that can be used with other Graph CMDlets. Make sure you store the access token in a variable according to the example.
            Before running this CMDlet, you first need to register a new application in your Azure AD according to this article:
            https://danielchronlund.com/2018/11/19/fetch-data-from-microsoft-graph-with-powershell-paging-support/
        .PARAMETER ClientID
            Client ID for your Azure AD application with Conditional Access Graph permissions.
        .PARAMETER ClientSecret
            Client secret for the Azure AD application with Conditional Access Graph permissions.
        .PARAMETER TenantName
            The name of your tenant (example.onmicrosoft.com).
        .INPUTS
            None
        .OUTPUTS
            None
        .NOTES
            Author:   Daniel Chronlund
            GitHub:   https://github.com/DanielChronlund/DCToolbox
            Blog:     https://danielchronlund.com/
        .EXAMPLE
            $AccessToken = Connect-DCMsGraphAsApplication -ClientID '8a85d2cf-17c7-4ecd-a4ef-05b9a81a9bba' -ClientSecret 'j[BQNSi29Wj4od92' -TenantName 'example.onmicrosoft.com'
    #>
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [string]$ClientID,
        [parameter(Mandatory = $true)]
        [string]$ClientSecret,
        [parameter(Mandatory = $true)]
        [string]$TenantName,
        [string]$TokenResourceUrl = $GraphResourceUrl
    )
    # Force TLS 1.2.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    #kevinka - Build Request URI
    $OAuthUri = "$($LoginUrl)/$($TenantName)/oauth2/v2.0/token"
    # Compose REST request.
    $Body = @{ grant_type = "client_credentials"; scope = "$($TokenResourceUrl)/.default"; client_id = $ClientID; client_secret = $ClientSecret }
    $OAuth = Invoke-RestMethod -Method Post -Uri $OAuthUri -Body $Body 4>$Null
    # Return the access token.
    $OAuth.access_token
}

function Connect-AcquireTokenViaServicePrincipal {
    [CmdletBinding()]
    param (
        [string]$TokenResourceUrl = $GraphResourceUrl
    )

    $ClientID = $env:PolicyExportID
    $ClientSecret = $env:PolicyExportSecret    
    $ClientTenant = $env:PolicyExportTenant

    return Connect-DCMsGraphAsApplication -ClientID $ClientID -ClientSecret $ClientSecret -TenantName $ClientTenant -TokenResourceUrl $TokenResourceUrl
}

function Connect-AcquireTokenViaManagedIdentity {
    [CmdletBinding()]
    param (
        [string]$TokenResourceUrl = $GraphResourceUrl
    )
    $endpoint = $env:MSI_ENDPOINT
    $secret = $env:MSI_SECRET
   
    $accessTokenHeader = @{
        Secret = $secret
    }
    $OAuthUri = "$($endpoint)?api-version=2017-09-01&resource=$($TokenResourceUrl)"
   
    $OAuth = Invoke-RestMethod -Method Get -Uri $OAuthUri -Headers $accessTokenHeader 4>$Null

    # Return the access token.
    $OAuth.access_token
}

function Invoke-DCMsGraphQuery {
    <#
        .SYNOPSIS
            Run a Microsoft Graph query.
        .DESCRIPTION
            This CMDlet will run a query against Microsoft Graph and return the result. It will connect using an access token generated by Connect-DCMsGraphAsDelegated or Connect-DCMsGraphAsApplication (depending on what permissions you use in Graph).
            Before running this CMDlet, you first need to register a new application in your Azure AD according to this article:
            https://danielchronlund.com/2018/11/19/fetch-data-from-microsoft-graph-with-powershell-paging-support/
           
        .PARAMETER AccessToken
                An access token generated by Connect-DCMsGraphAsDelegated or Connect-DCMsGraphAsApplication (depending on what permissions you use in Graph).
        .PARAMETER GraphMethod
                The HTTP method for the Graph call, like GET, POST, PUT, PATCH, DELETE. Default is GET.
        .PARAMETER GraphUri
                The Microsoft Graph URI for the query. Example: https://graph.microsoft.com/v1.0/users/
        .PARAMETER GraphBody
                The request body of the Graph call. This is often used with methids like POST, PUT and PATCH. It is not used with GET.
           
        .INPUTS
            None
        .OUTPUTS
            None
        .NOTES
            Author:   Daniel Chronlund
            GitHub:   https://github.com/DanielChronlund/DCToolbox
            Blog:     https://danielchronlund.com/
       
        .EXAMPLE
            Invoke-DCMsGraphQuery -AccessToken $AccessToken -GraphMethod 'GET' -GraphUri 'https://graph.microsoft.com/v1.0/users/'
    #>

    param (
        [parameter(Mandatory = $true)]
        [string]$AccessToken,

        [parameter(Mandatory = $false)]
        [string]$GraphMethod = 'GET',

        [parameter(Mandatory = $true)]
        [string]$GraphUri,

        [parameter(Mandatory = $false)]
        [string]$GraphBody = '',

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
        If($AdditionalHeaders){
            $HeaderParams += $AdditionalHeaders
        }

        # Create an empty array to store the result.
        $QueryRequest = @()
        $QueryResult = @()

        # Run the first query.
        if ($GraphMethod -eq 'GET') {
            $QueryRequest = Invoke-RestMethod -Headers $HeaderParams -Uri $GraphUri -UseBasicParsing -Method $GraphMethod -ContentType "application/json" 4>$Null
        }else {
            $QueryRequest = Invoke-RestMethod -Headers $HeaderParams -Uri $GraphUri -UseBasicParsing -Method $GraphMethod -ContentType "application/json" -Body $GraphBody 4>$Null
        }
        if ($QueryRequest.value) {
            $QueryResult += $QueryRequest.value
        }elseIf($QueryRequest.data){
            $QueryResult += $QueryRequest.data
        }else {
            $QueryResult += $QueryRequest
        }

        # Invoke REST methods and fetch data until there are no pages left.
        if ($GraphUri -notlike "*`$top*") {
            while ($QueryRequest.'@odata.nextLink' -and $QueryRequest.'@odata.nextLink' -is [string]) {
                $QueryRequest = Invoke-RestMethod -Headers $HeaderParams -Uri $QueryRequest.'@odata.nextLink' -UseBasicParsing -Method $GraphMethod -ContentType "application/json"  4>$Null
                $QueryResult += $QueryRequest.value
            }
            While($QueryRequest.nextLink -and $QueryRequest.nextLink -is [string]){
                $QueryRequest = Invoke-RestMethod -Headers $HeaderParams -Uri $QueryRequest.'nextLink' -UseBasicParsing -Method $GraphMethod -ContentType "application/json"  4>$Null
                $QueryResult += $QueryRequest.value
            }
            While($QueryRequest.'$skipToken' -and $QueryRequest.'$skipToken' -is [string] -and $GraphBody -ne ''){
                $tempBody = $GraphBody | ConvertFrom-Json -AsHashtable | select -ExcludeProperty '$skipToken'
                $tempBody | Add-Member -MemberType NoteProperty -Value @{'$skipToken' = $($QueryRequest.'$skipToken')} -Name 'options'
                #$tempBody.options.'$skipToken' = $QueryRequest.'$skipToken'
                $GraphBody = $tempBody | ConvertTo-Json -Depth 99
                $QueryRequest = Invoke-RestMethod -Headers $HeaderParams -Uri $GraphUri -UseBasicParsing -Method $GraphMethod -ContentType "application/json" -Body $GraphBody  4>$Null
                If($QueryRequest.data){
                    $QueryResult += $QueryRequest.data
                }else {
                    $QueryResult += $QueryRequest
                }
            }
        }
       
        $QueryResult
    }
    else {
        Write-Error "No Access Token"
    }
}

function uploadResult3 {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)]
        [string]
        $ConnectionStringURI,
        [parameter(Mandatory = $false)]
        [string]
        $Path = {
            $myUTC = ([datetime]::UtcNow).tostring('yyyy-MM-ddTHH:mm:ss')
            $tzUTC = [system.timezoneinfo]::GetSystemTimeZones() | Where-Object { $_.id -eq 'UTC' }
            $tzEST = [system.timezoneinfo]::GetSystemTimeZones() | Where-Object { $_.id -eq 'US Eastern Standard Time' }
            $now = [System.TimeZoneInfo]::ConvertTime($myUTC, $tzUTC, $tzEST)
            "y=$($now.tostring('yyyy'))/m=$($now.tostring('MM'))/d=$($now.tostring('dd'))/h=$($now.tostring('HH'))/m=$($now.tostring('mm'))"
        },
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $filename,
        [parameter(Mandatory = $false)]
        [string]
        $timestamp = [datetime]::UtcNow.tostring('yyyy-MM-dd_HHmmss'),
        [parameter(Mandatory = $false)]
        $queryResult = '',
        [parameter(Mandatory = $false)]
        $infile = '',
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $storageToken,
        [parameter(Mandatory = $false)]
        [ValidateSet('json', 'csv', 'zip', 'txt')]
        [string]
        $extension = 'json',
        [parameter(Mandatory = $false)]
        [switch]
        $CleanUpFiles, #this switch is no longer needed or supported, but kept to avoid causing errors from calls still specifying it
        [parameter(Mandatory = $false)]
        [hashtable]
        $metadata
    )
   
    If ([string]::IsNullOrEmpty($queryResult)) { $queryResult = ' ' }
    $filename = Remove-InvalidFileNameChars -Name $filename
    $blobname = "$Path/$($filename)_$timestamp.$extension"
    $filestring = "$($timestamp)_$filename.$extension"
   
    If ($extension -eq 'csv') {
        $ContentType = 'text/csv; charset=UTF-8'
        If ([string]::IsNullOrEmpty($queryResult)) {
            Write-Warning "No results - so no CSV created"
        }
        Else {
            $body = ($queryResult | ConvertTo-Csv -NoTypeInformation) -join "`n"
        }
    }ElseIf($extension -eq 'txt'){
        $ContentType = 'text/plain; charset=UTF-8'
        If ([string]::IsNullOrEmpty($queryResult)){
            Write-Warning "No results - so no txt file created."
        }Else{
            $body = $queryResult
        }

    } ElseIf($extension -eq 'zip'){
        $ContentType = 'application/zip'
        $body = $queryResult
    }
    Else {
        $ContentType = 'application/json; charset=UTF-8'
        $body = $queryResult | ConvertTo-Json -Depth 99
    }
    #Upload to storage
    Write-Verbose -Message "$filename : Uploading $filestring to $ConnectionStringURI" -Verbose:$VerbosePreference
    $ConnectionStringAll = $ConnectionStringURI + "/" + $blobname
    $headers = @{
        'Content-Type'   = $ContentType
        'x-ms-blob-type' = 'BlockBlob'
        'authorization'  = "Bearer $storageToken"
        'x-ms-version'   = '2020-04-08'
        'x-ms-date'      = $([datetime]::UtcNow.tostring('ddd, dd MMM yyyy HH:mm:ss ') + 'GMT')
    }
    Write-Verbose -Message "Uploading $filename to $ConnectionStringURI"
    If($infile){
        $body = [System.IO.File]::ReadAllBytes($infile)
        $headers.Remove('Content-Type')
        $headers.Add('Content-Length', $body.Length)
        $Null = Invoke-WebRequest -Uri $ConnectionStringAll -Method PUT -Headers $headers -Body $body -InFile $infile  -UseBasicParsing 4>$Null
    }Else{
        $Null = Invoke-WebRequest -Uri $ConnectionStringAll -Method PUT -Headers $headers -Body $body -ContentType $ContentType -UseBasicParsing 4>$Null
    }
   
    <# the sidecar isn't being used right now, but it's here in case we need it later. I've validated it works, yay.
    If($metadata){
        #If metadata is defined, then output the data as JSON to the filename.meta file wherever the original file is being written to
        $ConnectionStringAll = $ConnectionStringURI + "/" + $blobname + '.meta'
        $headers = @{
            'Content-Type'   = 'application/json; charset=UTF-8'
            'x-ms-blob-type' = 'BlockBlob'
            'authorization'  = "Bearer $storageToken"
            'x-ms-version'   = '2020-04-08'
            'x-ms-date'      = $([datetime]::UtcNow.tostring('ddd, dd MMM yyyy HH:mm:ss ') + 'GMT')
        }
        #$Null = Invoke-WebRequest -Uri $ConnectionStringAll -Method PUT -Headers $headers -Body $($metadata | ConvertTo-Json) -ContentType 'application/json; charset=UTF-8'
    }
    #>
}

Function Remove-InvalidFileNameChars {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true,
            Position = 0,
            ValueFromPipeline = $true,
            ValueFromPipelineByPropertyName = $true)]
        [string]$Name
    )
    $invalidChars = [IO.Path]::GetInvalidFileNameChars() -join ''
    $invalidChars += ' '
    $re = '[{0}]' -f [regex]::escape($invalidChars)
    return ($Name -replace $re)
}

Function Write-LogAnalytics {
    <#
.SYNOPSIS
    This function sends data to Log Analytics using the Data Collector REST API
.DESCRIPTION
    This function sends data to Log Analytics using the Data Collector REST API
.PARAMETER WorkspaceId
    Specifies the WorkspaceId of the Log Analytics workspace to send the data to.
.PARAMETER SharedKey
    Specifies the SharedKey of the Log Analytics workspace to send the data to.
.PARAMETER LogType
    Specifies the LogType data to send to Log Analytics.
.PARAMETER TimeStampField
    Specifies the optional TimeStampField.
.PARAMETER json
    Specifies the json data to send to Log Analytics. The JSON should have 50 or fewer fields.
.EXAMPLE
    $json = @"
    [{  "StringValue": "MyString1",
        "NumberValue": 42,
        "BooleanValue": true,
        "DateValue": "2019-09-12T20:00:00.625Z",
        "GUIDValue": "9909ED01-A74C-4874-8ABF-D2678E3AE23D"
    },
    {   "StringValue": "MyString2",
        "NumberValue": 43,
        "BooleanValue": false,
        "DateValue": "2019-09-12T20:00:00.625Z",
        "GUIDValue": "8809ED01-A74C-4874-8ABF-D2678E3AE23D"
    }]
"@
    Write-AHLogAnalytics -WorkspaceId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' -SharedKey 'MySharedKeyGoesHere' -LogType 'MyLogType' -json $json
.EXAMPLE
    Write-AHLogAnalytics -WorkspaceId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' -SharedKey 'MySharedKeyGoesHere' -LogType 'MyLogType' -json $json -TimeStampField $MyDateTimeObject
.NOTES
    Author: #Credit to https://learn.microsoft.com/en-us/azure/azure-monitor/logs/data-collector-api?tabs=powershell
    I took what they had, validated it, and included it here with minor changes to make it even easier
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkspaceId,
        [Parameter(Mandatory = $true)]
        [string]$SharedKey,
        [Parameter(Mandatory = $true)]
        [string]$LogType,
        [Parameter(Mandatory = $false)]
        [datetime]$TimeStampInput = [datetime]::UtcNow,
        [Parameter(Mandatory = $true)]
        [ValidateScript({
            ((($_ | ConvertFrom-Json -Depth 99) | Get-Member -MemberType NoteProperty).count -le 50) -and `
                ([system.text.asciiEncoding]::Unicode.GetByteCount($_) -lt 32MB) -and `
                ([system.text.asciiEncoding]::Unicode.GetByteCount((($_ | ConvertFrom-Json -Depth 99) | Get-Member -MemberType NoteProperty).Name) -lt 32KB)
            })]
        [string]$json
    )

    $TimeStampField = Get-Date $($TimeStampInput.ToUniversalTime()) -Format "o"
    $CustomerId = $WorkspaceId

    # Create the function to create the authorization signature
    Function Build-Signature ($customerId, $sharedKey, $date, $contentLength, $method, $contentType, $resource) {
        $xHeaders = "x-ms-date:" + $date
        $stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource

        $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
        $keyBytes = [Convert]::FromBase64String($sharedKey)

        $sha256 = New-Object System.Security.Cryptography.HMACSHA256
        $sha256.Key = $keyBytes
        $calculatedHash = $sha256.ComputeHash($bytesToHash)
        $encodedHash = [Convert]::ToBase64String($calculatedHash)
        $authorization = 'SharedKey {0}:{1}' -f $customerId, $encodedHash
        return $authorization
    }

    # Create the function to create and post the request
    Function Post-LogAnalyticsData($customerId, $sharedKey, $body, $logType, $TimeStampField) {
        $method = "POST"
        $contentType = "application/json"
        $resource = "/api/logs"
        $rfc1123date = [DateTime]::UtcNow.ToString("r")
        $contentLength = $body.Length
        $signature = Build-Signature `
            -customerId $customerId `
            -sharedKey $sharedKey `
            -date $rfc1123date `
            -contentLength $contentLength `
            -method $method `
            -contentType $contentType `
            -resource $resource
        $uri = "https://" + $customerId + '.' + $odsEndpoint + $resource + "?api-version=2016-04-01"

        $headers = @{
            "Authorization"        = $signature;
            "Log-Type"             = $logType;
            "x-ms-date"            = $rfc1123date;
            "time-generated-field" = $TimeStampField;
        }

        $response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $body -UseBasicParsing 4>$Null
        return $response.StatusCode

    }

    # Submit the data to the API endpoint
    Post-LogAnalyticsData -customerId $customerId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($json)) -logType $logType -TimeStampField $TimeStampField
}

Function GetTenantDisplayName {
    [CmdletBinding()]
    $tenantId = $env:PolicyExportTenant

    $token = Connect-AcquireToken -TokenResourceUrl $GraphResourceUrl
    #$token = (Get-AzAccessToken -ResourceUrl $GraphResourceUrl).token
    $header = @{Authorization = "Bearer $token" }
    $uri = "$GraphResourceUrl/v1.0/organization/$tenantId"
    $tenantResult = Invoke-RestMethod -Method Get -Uri $uri -Headers $header -ContentType 'application/json' 4>$Null
   
    $tenantResult.displayName
}

Function GetSubscriptionsToReportOn {
    [CmdletBinding()]

    $token = Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl
    #$token = (get-azaccesstoken -ResourceUrl $TokenResourceUrl).token
    $header = @{Authorization = "Bearer $token" }
    $uri = "https://$managementApiBase/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01"
    $body = @{
        query = 'resourcecontainers | where type == "microsoft.resources/subscriptions"'
    } | ConvertTo-Json -Depth 99
    $result = Invoke-RestMethod -Method Post -Uri $uri -Body $body -Headers $header -ContentType 'application/json' 4>$Null
    $allSubs = $result.data | ForEach-Object { [pscustomobject]@{displayName = $_.name; SubscriptionId = $_.subscriptionId ; SSP = $_.tags.ssp} }

    #Narrow down based on the DisableReporting tag
    $reportingSubIDs = ForEach ($subscriptionID in $allSubs.SubscriptionId) {
        $uri = "https://$managementApiBase/subscriptions/$subscriptionID/providers/Microsoft.Resources/tags/default?api-version=2021-04-01"
        $result = Invoke-RestMethod -Method Get -Uri $uri -Headers $header -ContentType 'application/json' 4>$Null
        If ($result.properties.tags.DisableReporting -eq "true") {

        }
        Else {
            $subscriptionID
        }
    }
    $allSubs | Where-Object { $_.SubscriptionId -in $reportingSubIDs }
}

Function SendFileAsEmail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$attachmentName,
        [Parameter(Mandatory = $true)]
        [string]$body,
        [Parameter(Mandatory = $true)]
        $fileContent,
        [Parameter(Mandatory = $true)]
        [string]$emailSubject,
        [Parameter(Mandatory = $true)]
        [string]$emailTo
    )

    If ($fileContent -is [system.array]) {
        $fileContent = $fileContent -join ("`n")
    }

    $restBody = @{
        attachmentName = $attachmentName
        body           = $body
        fileContent    = $fileContent
        emailSubject   = $emailSubject
        emailTo        = $emailTo
    } | ConvertTo-Json -Depth 99

    $result = Invoke-RestMethod -Method Post -Uri $emailURI -Body $restBody -ContentType 'application/json' 4>$Null
}

Function ConvertUnixTimestampToDateTime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int32]$time
    )
    [datetime]"1/1/1970" + [system.timespan]::FromSeconds($time)
}


Function CopyBlob {
    <#
    .SYNOPSIS
        This function copies a blob from one location to another.

    .DESCRIPTION
        The CopyBlob function is used to copy a blob from a source location to a destination location. It can be used to copy blobs within the same storage account or across different storage accounts.

    .PARAMETER SourceBlobUrl
        Specifies the source blob that needs to be copied.

    .PARAMETER DestinationBlobUrl
        Specifies the destination blob where the source blob will be copied to.

    .EXAMPLE
        $storageToken = (Get-AzAccessToken -ResourceTypeName Storage).Token
        CopyBlob -SourceBlobUrl $sourceBlobUrl -DestinationBlobUrl $destinationBlobUrl -StorageToken $storageToken

        Copies the file from $sourceBlobUrl to $destinationBlobUrl. The same token must work for both source and destination.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]
        $SourceBlobUrl,
        [Parameter(Mandatory = $true)]
        [string]
        $DestinationBlobUrl,
        [Parameter(Mandatory = $true)]
        [string]
        $StorageToken
    )

    $headers = @{
        'x-ms-blob-type' = 'BlockBlob'
        'authorization'  = "Bearer $storageToken"
        'x-ms-copy-source-authorization' = "Bearer $storageToken"
        'x-ms-version'   = '2020-10-02'
        "x-ms-copy-source"=$sourceBlobUrl
        'x-ms-date'      = $([datetime]::UtcNow.tostring('ddd, dd MMM yyyy HH:mm:ss ') + 'GMT')
    }
   
    # Send the PUT request to start the copy operation
    Invoke-RestMethod -Uri $destinationBlobUrl -Method Put -Headers $headers 4>$null
}

Function GetDatePrefixes{
    param(
        [Parameter(Mandatory=$true)]
        [ValidateRange(1,60)]
        [int]$DaysToGoBack = 30
    )
    #Generates an array of prefixes in the format y=yyyy/m=MM for the range specified
    $prefixes = @()
    $xDaysAgo = (Get-Date).AddDays(-$DaysToGoBack)
    $prefixes += "y=$($xDaysAgo.ToString('yyyy'))/m=$($xDaysAgo.ToString('MM'))/d=$($xDaysAgo.ToString('dd'))"
    For($i = 1; $i -lt $DaysToGoBack + 1; $i++){ #+1 to get stuff today too
        $xDaysAgo = $xDaysAgo.AddDays(1)
        $prefix = "y=$($xDaysAgo.ToString('yyyy'))/m=$($xDaysAgo.ToString('MM'))/d=$($xDaysAgo.ToString('dd'))"
        if ($prefix -notin $prefixes) {
            $prefixes += $prefix
        }
    }
    $prefixes
}
Function GetRecentBlobs{
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$StorageAccountName,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$ContainerName,
        [Parameter(Mandatory=$false)]
        [ValidateRange(1,60)]
        [int]$DaysToGoBack = 10,
        [Parameter(Mandatory=$false)]
        [string]$ContainsString #= "DeployExportToLogAnalyticsSummary"
    )
    $tempBlobs = $null
    $xDaysAgo = (Get-Date).AddDays(-$DaysToGoBack)
    $token = Connect-AcquireToken -TokenResourceUrl $StorageTokenResourceUrl
    #$token = (Get-AzAccessToken -ResourceUrl $StorageTokenResourceUrl).Token
   
    $prefixes = GetDatePrefixes -DaysToGoBack $DaysToGoBack
    ForEach($prefix in $prefixes){
        Do{
            $uri = "https://$($StorageAccountName).blob.$($storageEndpointSuffix)/$($ContainerName)?restype=container&comp=list&prefix=$prefix&select=Name&orderby=Creation-Time desc"
            $rfc1123date = [DateTime]::UtcNow.ToString("r")
            $additionalHeaders = @{
                'x-ms-date' = $rfc1123date
                'x-ms-version' = '2020-04-08'
            }
            If($tempBlobs.EnumerationResults.NextMarker){
                $uri += "&marker=$($tempBlobs.EnumerationResults.NextMarker)"
            }
            $blobsText = Invoke-DCMsGraphQuery -AccessToken $token -GraphMethod Get -GraphUri $uri -AdditionalHeaders $additionalHeaders -ErrorVariable myError

            $split = $blobstext.split('>')
            [xml]$tempBlobs = $split[1..$($split.count)] -join('>')
            $formattedBlobs = ForEach($blob in $tempBlobs.EnumerationResults.Blobs.blob){
                [pscustomobject]@{
                    ServiceEndpoint = $tempBlobs.EnumerationResults.ServiceEndpoint
                    ContainerName = $tempBlobs.EnumerationResults.ContainerName
                    Name = $blob.Name
                    Etag = [string]$blob.Properties.Etag
                    'Creation-Time' = [datetime]($blob.Properties.'Creation-Time')
                    'LastModified' = [datetime]($blob.Properties.'Last-Modified')
                    'Content-Length' = [int]($blob.Properties.'Content-Length')
                    'Content-Encoding' = [string]($blob.Properties.'Content-Encoding')
                    'Content-MD5' = [string]($blob.Properties.'Content-MD5')
                    BlobType = [string]($blob.Properties.BlobType)
                }
            }
            If($ContainsString){
                $formattedBlobs | where{$_.Name -like "*$ContainsString*" -and $_.'Creation-Time' -gt $xDaysAgo}
            }Else{
                $formattedBlobs | where{$_.'Creation-Time' -gt $xDaysAgo}
            }
        }While($tempBlobs.EnumerationResults.NextMarker)
    }
}
Function CompressBlobs{
    <#
    .SYNOPSIS
        This function zips contents of a directory within a storage account container, then writes that zip out to a blob in the container, then cleans up the temp drive.

    .DESCRIPTION
        The CompressBlob function copies everything that is a child of the SourceBlobUrl recursively into a temporary file share, then zips the contents on the file share, then copies the zipped file to the DestinationBlobURL. Right now the source, destination, and temp location have to all be in the same SA.

    .PARAMETER SourceBlobUrl
        Specifies the source blob directory that needs to be copied.

    .PARAMETER DestinationBlobUrl
        Specifies the destination blob where the compressed data will be copied to.

    .EXAMPLE
        $storageToken = (Get-AzAccessToken -ResourceTypeName Storage).Token
        CompressBlobs -SourceBlobUrl $sourceBlobUrl -DestinationBlobUrl $destinationBlobUrl -StorageToken $storageToken -zipFileName $zipFileName

        Copies the file from $sourceBlobUrl to $destinationBlobUrl. The same token must work for both source and destination.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]
        $SourceBlobUrl,
        [Parameter(Mandatory = $true)]
        [string]
        $DestinationBlobUrl,
        [Parameter(Mandatory = $true)]
        [string]
        $zipFileName,
        [Parameter(Mandatory = $true)]
        [string]
        $StorageToken
    )
    Write-Verbose -Message "Compressing blobs from $SourceBlobUrl to $DestinationBlobUrl as $zipFileName"

    #now zip everything up into a single file and store it in the xxevidencepackages container
        #mount the temp file share so that there is a writable temp disk
        $connectionString = $env:WEBSITE_CONTENTAZUREFILECONNECTIONSTRING
        $websiteContentShare = $env:WEBSITE_CONTENTSHARE
        $accountKey = $connectionString.split(';')[2].replace('AccountKey=','')
        $accountName = $connectionString.split(';')[1].replace('AccountName=','')
        $endpointSuffix = $connectionString.split(';')[3].replace('EndpointSuffix=','')
        $fileshareFqdn = $accountName + '.file.' + $endpointSuffix

        $tempDir = [system.io.path]::GetTempPath()
        $tempSubDir = [system.io.path]::GetRandomFileName()
        mkdir -Path $tempDir -Name $tempSubDir
        $tempLocation = Join-Path $tempDir $tempSubDir

        #Write-Warning "test-path returned $(Test-Path $tempLocation -PathType Container) for $tempLocation"
        #copy the files to the temp location
       
        #write-warning "SourceBlobUrl = $SourceBlobUrl"
        #Write-Warning "DestinationBlobUrl = $DestinationBlobUrl"
        $storageContext = New-AzStorageContext -StorageAccountName $accountName -StorageAccountKey $accountKey #-UseConnectedAccount
        $container = $SourceBlobUrl.split('/')[3]
        $pathLike = $SourceBlobUrl.split('/')[4..($SourceBlobUrl.split('/').count - 1)] -join('/')
        $problemPath = $pathLike + '\'
        $pathLike = $pathLike + '*'

        #$blobs = Get-AzStorageBlob -Container $container -Blob * -Context $storageContext 4>$null | where{$_.Name -like $pathLike}
        $blobs = GetRecentBlobs -StorageAccountName $accountName -ContainerName $container -DaysToGoBack 1 | where{$_.Name -like $pathLike}
        Write-Verbose "$($blobs.count) blobs found in $container"

        #Write-Verbose "Getting contents of the blobs now..."
        ForEach($blob in $blobs){
            Write-Verbose "Found blob: $($blob.Name)"
        }

        <#
        $count = 0
        ForEach($blob in $blobs) {
            $count++
            #Write-Host "Getting blob content for $($blob.Name) from $SourceBlobUrl and writing to $(join-path $tempLocation $blob.Name)"
            $blobUri = $($blob.Context.BlobEndPoint + $container + "/" + $blob.Name)
            $betterPath = ($(Join-Path $tempLocation $blob.Name) -split '\\' | where{$_ -notmatch "="}) -join('\')
            Write-Host "Getting blob ($count/$($blobs.count)) content for $($blob.Name.split('/')[-1]) from $blobUri and writing to $betterPath"
            # Get blob content using the GetBlobContent function
            $blobContent = GetBlobContent -BlobURI $blobUri #($SourceBlobUrl + '/' + $blob.Name)
            # Create necessary directories
            $parentPath = Split-Path $betterPath -Parent
            if ($parentPath -and !(Test-Path $parentPath)) {
                New-Item -Path $parentPath -ItemType Directory -Force | Out-Null
            }
            # Write blob content to the better path
            $blobContent | Out-File -FilePath $betterPath -Force
            # Clean up any leftover year-based directories
            Get-ChildItem -Path $tempLocation | Where-Object {$_.Name -like "y=*"} | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
            #>
       
        $blobcount = 0
        ForEach($blob in $blobs) {
            $blobcount++
            $blobUri = $($blob.ServiceEndpoint + $container + "/" + $blob.Name)
            $betterPath = ($(Join-Path $tempLocation $blob.Name) -split '\\' | where{$_ -notmatch "="}) -join('\')
            Write-Host "Getting blob ($blobcount/$($blobs.count)) content for $($blob.Name.split('/')[-1]) from $blobUri and writing to $betterPath"
            # Get blob content using the GetBlobContent function
            $blobContent = GetBlobContent -BlobURI $blobUri
            # Create necessary directories
            $parentPath = Split-Path $betterPath -Parent
            if ($parentPath -and !(Test-Path $parentPath)) {
                New-Item -Path $parentPath -ItemType Directory -Force | Out-Null
            }
            # Write blob content to the better path
            $blobContent | Out-File -FilePath $betterPath -Force
            # Clean up any leftover year-based directories
            Get-ChildItem -Path $tempLocation | Where-Object {$_.Name -like "y=*"} | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }

<#
        $blobs | %{
            Get-AzStorageBlobContent -Container $container -Blob $_.Name -Destination $tempLocation -Context $storageContext -Force #4>$null
            write-host "Getting blob content for $($_.Name) from $SourceBlobUrl and writing to $(join-path $tempLocation $_.Name)"
            $betterPath = ($(Join-Path $tempLocation $_.Name) -split '\\' | where{$_ -notmatch "="}) -join('\')
            mkdir $(split-path $betterPath) -ErrorAction SilentlyContinue
            #GetBlobContent -BlobURI $($SourceBlobUrl + '\' +  $_.Name) > $(join-path $tempLocation $_.Name)
            move-item -Path $(Join-Path $tempLocation $_.Name) -Destination $betterPath -Force
            gci -Path $tempLocation | where {$_.Name -like "y=*"} | remove-item -Recurse -Force
            #remove-item -Path $(Join-Path $tempLocation $_.Name) -Recurse -Force
        }#| Out-Null}
#>

        #compress the files
        $zipPath = $tempLocation + '\' + "$zipFileName"
        write-verbose "working on zip file $zipPath"
        #ls $tempLocation | %{Compress-Archive -Path $_.FullName -DestinationPath $zipPath -Update}
        $fileCount = 0
        ForEach($file in (ls $tempLocation)) {
            #Write-Warning "Compressing $($file.FullName)"
            #write-verbose "Adding file $($file.FullName) to $zipPath"
            Compress-Archive -Path $file.FullName -DestinationPath $zipPath -Update
            $fileCount++
            #$zipArchive = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Update)
            #[System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zipArchive, $file.FullName, $file.Name, [System.IO.Compression.CompressionLevel]::Optimal)
            #$zipArchive.Dispose()
        }
        #Write-Warning "$count files compressed to $zipPath"

        #write-warning "the zip file hopefully exits:"

        #(ls $tempDir -Recurse).FullName | %{Write-Verbose "Files include: $_"}

        #Compress-Archive -Path $tempLocation -DestinationPath $zipPath -Force
        #upload the files to the storage account
        $myPath = GetTenantDisplayName
        $myPath = Remove-InvalidFileNameChars -Name $myPath
        $myPath = $myPath -replace ' ',''
        $myPath += '.zip'

        $myPath = Remove-InvalidFileNameChars -Name $zipFileName
        Write-Information "Uploading $zipPath to $DestinationBlobUrl"
        #$Null = uploadResult3 -ConnectionStringURI $DestinationBlobUrl -Path $myPath -filename $zipFileName -storageToken $StorageToken -extension 'zip' -queryResult $(gc $zipPath -Raw)


        $ConnectionStringAll = $DestinationBlobUrl + '/' + $myPath #$ConnectionStringURI + "/" + $blobname
        $headers = @{
            'Content-Type'   = 'application/zip'
            'x-ms-blob-type' = 'BlockBlob'
            'authorization'  = "Bearer $storageToken"
            'x-ms-version'   = '2020-04-08'
            'x-ms-date'      = $([datetime]::UtcNow.tostring('ddd, dd MMM yyyy HH:mm:ss ') + 'GMT')
        }
        $Null = Invoke-WebRequest -Uri $ConnectionStringAll -Method PUT -Headers $headers -InFile $zipPath 4>$null
}

Function DownloadBlob{
    <#add help eventually#>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]
        $SourceBlobUrl,
        [Parameter(Mandatory = $true)]
        [string]
        $DestinationPath,
        [Parameter(Mandatory = $true)]
        [string]
        $StorageToken
    )

    $headers = @{
        'x-ms-blob-type' = 'BlockBlob'
        'authorization'  = "Bearer $storageToken"
        'x-ms-copy-source-authorization' = "Bearer $storageToken"
        'x-ms-version'   = '2020-10-02'
        "x-ms-copy-source"=$sourceBlobUrl
        'x-ms-date'      = $([datetime]::UtcNow.tostring('ddd, dd MMM yyyy HH:mm:ss ') + 'GMT')
    }
   
    # Send the PUT request to start the copy operation
    Invoke-RestMethod -Uri $SourceBlobUrl -Method Get -Headers $headers -OutFile $DestinationPath 4>$Null
}

Function GetNewestBlobs{
    <#
    .DESCRIPTION
        This function gets the newest blobs in a container based on the LastModified property then returns metadata about every blob in the same directory as the newest blob.
    .PARAMETER ContainerUri
        The URI of the container to get the blobs from.
    .EXAMPLE
        GetNewestBlobs -ContainerUri 'https://mystorageaccount.blob.core.windows.net/mycontainer'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $ContainerUri
    )

    $token = Connect-AcquireToken -TokenResourceUrl $StorageTokenResourceUrl
    #$token = (Get-AzAccessToken -ResourceUrl $StorageTokenResourceUrl).Token
    $ContainerUri = $ContainerUri + '?restype=container&comp=list'
    $rfc1123date = [DateTime]::UtcNow.ToString("r")
    $additionalHeaders = @{
        'x-ms-date' = $rfc1123date
        'x-ms-version' = '2020-04-08'
    }
    $blobsText = Invoke-DCMsGraphQuery -AccessToken $token -GraphMethod Get -GraphUri $ContainerUri -AdditionalHeaders $additionalHeaders -ErrorVariable myError
    $split = $blobstext.split('>')
    [xml]$tempBlobs = $split[1..$($split.count)] -join('>')
    $blobs = ForEach($blob in $tempBlobs.EnumerationResults.Blobs.blob){
        [pscustomobject]@{
            ServiceEndpoint = $tempBlobs.EnumerationResults.ServiceEndpoint
            ContainerName = $tempBlobs.EnumerationResults.ContainerName
            Name = $blob.Name
            Etag = [string]$blob.Properties.Etag
            'Creation-Time' = [datetime]($blob.Properties.'Creation-Time')
            'LastModified' = [datetime]($blob.Properties.'Last-Modified')
            'Content-Length' = [int]($blob.Properties.'Content-Length')
            'Content-Encoding' = [string]($blob.Properties.'Content-Encoding')
            'Content-MD5' = [string]($blob.Properties.'Content-MD5')
            BlobType = [string]($blob.Properties.BlobType)
        }
    }
    If($blobs){
        $tempPath = ($blobs | Sort-Object LastModified -Descending )[0].name.split('/')
        $tempPath = $tempPath[0..$($tempPath.count - 2)] -join ('/')
        $blobs | Where-Object { $_.Name -like "$tempPath*" }
    }
}

Function GetBlobContent{
    <#
    .DESCRIPTION
        This function gets the content of a blob.
    .PARAMETER BlobUri
        The URI of the blob to get the content from.
    .EXAMPLE
        GetBlobContent -BlobUri 'https://mystorageaccount.blob.core.windows.net/mycontainer/myblob'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $BlobURI
    )
    $token = Connect-AcquireToken -TokenResourceUrl $StorageTokenResourceUrl
    #$token = (Get-AzAccessToken -ResourceUrl $StorageTokenResourceUrl).Token
    $rfc1123date = [DateTime]::UtcNow.ToString("r")
    $additionalHeaders = @{
        'Authorization' = "Bearer $token"
        'x-ms-date' = $rfc1123date
        'x-ms-version' = '2020-04-08'
    }
    Write-Verbose -Message "Getting blob content from $BlobURI"
    #invoke-RestMethod -Method Get -Uri $BlobURI -Headers $additionalHeaders -UseBasicParsing 4>$Null #don't use Invoke-DCMsGraphQuery here because it doesn't handle this request properly
    (Invoke-WebRequest -Method Get -Uri $BlobURI -Headers $additionalHeaders -UseBasicParsing 4>$Null).Content
    sleep -Milliseconds 50
}

Function UpdateAzureWorkbook{
    <#
    .DESCRIPTION
        This function updates an Azure workbook.
    .PARAMETER WorkbookUri
        The URI of the workbook to update.
    .PARAMETER WorkbookContent
        The content of the workbook to update.
    .EXAMPLE
        UpdateAzureWorkbook -WorkbookUri 'https://management.azure.com/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/MyResourceGroup/providers/Microsoft.OperationalInsights/workspaces/MyWorkspace/providers/Microsoft.Insights/workbooks/MyWorkbook' -WorkbookContentUnencoded $workbookContentAsJSON
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $WorkbookUri,
        [Parameter(Mandatory = $true)]
        [string]
        $WorkbookContentUnencoded
    )
    Begin{
        $apiversion = '2021-08-01'
    }
    Process{

    $token = Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl
    #$token = (Get-AzAccessToken -ResourceUrl $TokenResourceUrl).Token
   
    #get the old workbook content so that we can update It
    $oldWorkbook = Invoke-DCMsGraphQuery -AccessToken $token -GraphMethod Get -GraphUri $($WorkbookUri  + "?canFetchContent=true" + "&api-version=$apiversion")
    $oldContent = $oldWorkbook.properties.serializedData | ConvertFrom-Json -Depth 99
   
    $oldContent.items.content.parameters | where{$_.Name -eq 'myjson'}

    #build the body for the update to the workbook
    $body = @{
        tags = $oldWorkbook.tags
        kind = $oldWorkbook.kind
        properties = @{
            displayName = $oldWorkbook.properties.displayName
            description = $oldWorkbook.properties.displayName
            serializedData = $workbookContentAsJSON #.replace('"','\"')
            tags = $oldWorkbook.properties.tags
            revision = $((new-guid).guid.replace('-',''))
            category = $oldWorkbook.properties.category

        }
    } | ConvertTo-Json -Depth 99
   
    $headers = @{
        'Authorization' = "Bearer $token"
        'Content-Type' = 'application/json'
    }
    $result = Invoke-RestMethod -Method Patch -Uri $($WorkbookUri + "?api-version=$apiversion") -Headers $headers -Body $body -UseBasicParsing 4>$Null
    }
    End{}
}

Function UpdateAzureWorkbook{
    <#
    .SYNOPSIS
        This function updates an Azure workbook.
    .DESCRIPTION
        This function updates an Azure workbook. The parameter names in the workbook must be unique.
    .PARAMETER WorkbookUri
        The URI of the workbook to update.
    .PARAMETER ParametersToUpdate
        A hashtable of the parameter name and the new value.
    .EXAMPLE
        $ParametersToUpdate = @{
            'key1Json' = $key1Json,
            'key2Json' = $key2Json,
            'key3Json' = $key3Json
        }
        UpdateAzureWorkbook -WorkbookUri 'https://management.azure.com/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/MyResourceGroup/providers/Microsoft.Insights/myworkbookId' -ParametersToUpdate $ParametersToUpdate
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $WorkbookUri,
        [Parameter(Mandatory = $true)]
        [hashtable]
        $ParametersToUpdate,
        [Parameter(Mandatory = $false)]
        [string]
        $apiversion = '2021-08-01'
    )
    Begin{
       
    }
    Process{
        $token = Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl
        #$token = (Get-AzAccessToken -ResourceUrl $TokenResourceUrl).Token
       
        #get the old workbook content so that we can update It
        $oldWorkbook = Invoke-DCMsGraphQuery -AccessToken $token -GraphMethod Get -GraphUri $($WorkbookUri  + "?canFetchContent=true" + "&api-version=$apiversion")
        $oldContent = $oldWorkbook.properties.serializedData | ConvertFrom-Json -Depth 99
       
        ForEach($key in $ParametersToUpdate.Keys){
            ($oldContent.items.content.parameters | where{$_.Name -eq $key}).Value = $ParametersToUpdate[$key]
        }

        #This is the correct format for the Patch request
        $body = @{
            tags = $oldWorkbook.tags
            kind = $oldWorkbook.kind
            #location = $oldWorkbook.location
            properties = @{
                displayName = $oldWorkbook.properties.displayName
                description = $oldWorkbook.properties.displayName
                serializedData = $($oldContent | ConvertTo-Json -Depth 99 -Compress) #This way it gets encoded properly with proper double-json encoding
                tags = $oldWorkbook.properties.tags
                revision = $((new-guid).guid.replace('-',''))
                category = $oldWorkbook.properties.category
            }
        } | ConvertTo-Json -Depth 99 -Compress

$newWorkbookGuid = (New-Guid).Guid
        #This is the correct body for the Put request
        $body = @{
            location = $oldWorkbook.location
            tags = $oldWorkbook.tags #@{'hidden-title'=$newWorkbookGuid}#$oldWorkbook.tags
            kind = $oldWorkbook.kind
            #location = $oldWorkbook.location
            properties = @{
                displayName = $newWorkbookGuid #$oldWorkbook.properties.displayName
                description = $oldWorkbook.properties.displayName
                serializedData = $($oldContent | ConvertTo-Json -Depth 99 -Compress) #This way it gets encoded properly with proper double-json encoding
                tags = $oldWorkbook.properties.tags
                revision = $((new-guid).guid.replace('-',''))
                category = $oldWorkbook.properties.category
            }
        } | ConvertTo-Json -Depth 99 -Compress

        $headers = @{
            'Authorization' = "Bearer $token"
            #'Content-Type' = 'application/json'
        }
        #Write-Host "URI to send patch to: " + $($WorkbookUri + "?api-version=$apiversion")
#patch test
        $myResult = Invoke-RestMethod -Method Patch -Uri $($WorkbookUri + "?api-version=$apiversion") -Headers $headers -Body $body -UseBasicParsing -ContentType 'application/json' 4>$Null

#Put test - if I do this then I should delete the old workbook
        #$WorkbookUri = ($workbookUri.split('/')[0..$($workbookUri.split('/').count - 2)] -join('/')) + '/' + $newWorkbookGuid #$((New-Guid).Guid)
        #Invoke-RestMethod -Method Put -Uri $($WorkbookUri + "?api-version=$apiversion") -Headers $headers -Body $body -UseBasicParsing -ContentType 'application/json'

    }
    End{}
}

Function Import-LogAnalyticsWorkbookREST{
    <#
    .SYNOPSIS
        This function imports an Azure workbook using the REST API.
    .DESCRIPTION
        This function imports an Azure workbook using the REST API.
    .PARAMETER WorkbookContent
        The content of the workbook to import.
    .EXAMPLE
        Import-AzureWorkbookREST -WorkbookContent $workbookContentAsJSON
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $WorkbookTemplate,
        [Parameter(Mandatory = $false)]
        [string]
        $WorkbookID = [guid]::NewGuid().guid,
        [Parameter(Mandatory = $true)]
        [string]
        $LogAnalyticsWorkspaceID,
        [Parameter(Mandatory=$true)]
        [string]
        $Location,
        [Parameter(Mandatory = $false)]
        [string]
        $Category = 'sentinel',
        [Parameter(Mandatory = $true)]
        [string]
        $DisplayName
    )
    Begin{
        $apiversion = '2021-08-01'
    }
    Process{
        $token = Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl
        #$token = (Get-AzAccessToken -ResourceUrl $TokenResourceUrl).Token
       
        $body = @{
            location = $location
            kind = 'shared'
            properties = @{
                category = $category
                displayName = $DisplayName
                serializedData = $WorkbookTemplate
            }
        } | ConvertTo-Json -Depth 99

#        $headers = @{
#            'Authorization' = "Bearer $token"
#            'Content-Type' = 'application/json'
#        }
#        $LogAnalyticsWorkspaceId.replace('/Microsoft.OperationalInsights','Microsoft.Insights')
        $uri = $TokenResourceUrl + $($LogAnalyticsWorkspaceId.split('/')[0..4] -join ('/')) + "/providers/Microsoft.Insights/workbooks/$($workbookID)?api-version=$apiversion"
        $result = Invoke-DCMsGraphQuery -AccessToken $token -GraphMethod Put -GraphUri $uri -GraphBody $body
        $result
    }
    End{}
}

Function Import-LogAnalyticsWorkbookREST{
    <#
    .SYNOPSIS
        This function imports an Azure workbook using the REST API.
    .DESCRIPTION
        This function imports an Azure workbook using the REST API.
    .PARAMETER WorkbookContent
        The content of the workbook to import.
    .EXAMPLE
        Import-AzureWorkbookREST -WorkbookContent $workbookContentAsJSON
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $WorkbookTemplate,
        [Parameter(Mandatory = $false)]
        [string]
        $WorkbookID = [guid]::NewGuid().guid,
        [Parameter(Mandatory = $true)]
        [string]
        $SubscriptionId,
        [Parameter(Mandatory = $true)]
        [string]
        $ResourceGroupName,
        [Parameter(Mandatory = $true)]
        [string]
        $LogAnalyticsWorkspaceID,
        [Parameter(Mandatory=$true)]
        [string]
        $Location,
        [Parameter(Mandatory = $false)]
        [string]
        $Category = 'sentinel',
        [Parameter(Mandatory = $true)]
        [string]
        $DisplayName
    )
    Begin{
        $apiversion = '2021-08-01'
    }
    Process{
        $token = Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl
        #$token = (Get-AzAccessToken -ResourceUrl $TokenResourceUrl).Token
       
        $body = @{
            location = $location
            kind = 'shared'
            properties = @{
                category = $category
                displayName = $DisplayName
                serializedData = $WorkbookTemplate
                version = $($WorkbookTemplate | ConvertFrom-Json).version
                #sourceId = $($WorkbookTemplate | ConvertFrom-Json).properties.sourceId
            }
        } | ConvertTo-Json -Depth 99

#        $headers = @{
#            'Authorization' = "Bearer $token"
#            'Content-Type' = 'application/json'
#        }
#        $LogAnalyticsWorkspaceId.replace('/Microsoft.OperationalInsights','Microsoft.Insights')
        $uri = $TokenResourceUrl + '/subscriptions/' + $subscriptionId + '/resourceGroups/' + $resourceGroupName + "/providers/Microsoft.Insights/workbooks/$($workbookID)?api-version=$apiversion" + "&SourceId=$LogAnalyticsWorkspaceID"
        $result = Invoke-DCMsGraphQuery -AccessToken $token -GraphMethod Put -GraphUri $uri -GraphBody $body
        $result
    }
    End{}
}


Function ConvertTo-FlatObject {
    <#
    .SYNOPSIS
    Flattends a nested object into a single level object.
    .DESCRIPTION
    Flattends a nested object into a single level object.
    .PARAMETER Objects
    The object (or objects) to be flatten.
    .PARAMETER Separator
    The separator used between the recursive property names
    .PARAMETER Base
    The first index name of an embedded array:
    - 1, arrays will be 1 based: <Parent>.1, <Parent>.2, <Parent>.3, …
    - 0, arrays will be 0 based: <Parent>.0, <Parent>.1, <Parent>.2, …
    - "", the first item in an array will be unnamed and than followed with 1: <Parent>, <Parent>.1, <Parent>.2, …
    .PARAMETER Depth
    The maximal depth of flattening a recursive property.
    .EXAMPLE
    $Object3 = [PSCustomObject] @{
        "Name"    = "Przemyslaw Klys"
        "Age"     = "30"
        "Address" = @{
            "Street"  = "Kwiatowa"
            "City"    = "Warszawa"
            "Country" = [ordered] @{
                "Name" = "Poland"
            }
            List      = @(
                [PSCustomObject] @{
                    "Name" = "Adam Klys"
                    "Age"  = "32"
                }
                [PSCustomObject] @{
                    "Name" = "Justyna Klys"
                    "Age"  = "33"
                }
                [PSCustomObject] @{
                    "Name" = "Justyna Klys"
                    "Age"  = 30
                }
                [PSCustomObject] @{
                    "Name" = "Justyna Klys"
                    "Age"  = $null
                }
            )
        }
        ListTest  = @(
            [PSCustomObject] @{
                "Name" = "Sława Klys"
                "Age"  = "33"
            }
        )
    }
    $Object3 | ConvertTo-FlatObject
    .NOTES
    From https://evotec.xyz/powershell-converting-advanced-object-to-flat-object/
    Based on https://powersnippets.com/convertto-flatobject/
    #>
    [CmdletBinding()]
    Param (
        [Parameter(ValueFromPipeLine)][Object[]]$Objects,
        [String]$Separator = ".",
        [ValidateSet("", 0, 1)]$Base = 1,
        [Parameter(Mandatory = $false)]
        [ValidateScript({ $_ -ge 0 })]
        [int]
        $Depth = 5,
        #[int]$Depth = 5,
        [Parameter(DontShow)][String[]]$Path,
        [Parameter(DontShow)][System.Collections.IDictionary] $OutputObject
    )
    Begin {
        $InputObjects = [System.Collections.Generic.List[Object]]::new()
    }
    Process {
        foreach ($O in $Objects) {
            $InputObjects.Add($O)
        }
    }
    End {
        If ($PSBoundParameters.ContainsKey("OutputObject")) {
            $Object = $InputObjects[0]
            $Iterate = [ordered] @{}
            if ($null -eq $Object) {
                #Write-Verbose -Message "ConvertTo-FlatObject - Object is null"
            }
            elseif ($Object.GetType().Name -in 'String', 'DateTime', 'TimeSpan', 'Version', 'Enum') {
                $Object = $Object.ToString()
            }
            elseif ($Depth) {
                $Depth--
                If ($Object -is [System.Collections.IDictionary]) {
                    $Iterate = $Object
                }
                elseif ($Object -is [Array] -or $Object -is [System.Collections.IEnumerable]) {
                    $i = $Base
                    foreach ($Item in $Object.GetEnumerator()) {
                        $Iterate["$i"] = $Item
                        $i += 1
                    }
                }
                else {
                    foreach ($Prop in $Object.PSObject.Properties) {
                        if ($Prop.IsGettable) {
                            $Iterate["$($Prop.Name)"] = $Object.$($Prop.Name)
                        }
                    }
                }
            }
            If ($Iterate.Keys.Count) {
                foreach ($Key in $Iterate.Keys) {
                    ConvertTo-FlatObject -Objects @(, $Iterate["$Key"]) -Separator $Separator -Base $Base -Depth $Depth -Path ($Path + $Key) -OutputObject $OutputObject
                }
            }
            else {
                $Property = $Path -Join $Separator
                $OutputObject[$Property] = $Object
            }
        }
        elseif ($InputObjects.Count -gt 0) {
            foreach ($ItemObject in $InputObjects) {
                $OutputObject = [ordered]@{}
                ConvertTo-FlatObject -Objects @(, $ItemObject) -Separator $Separator -Base $Base -Depth $Depth -Path $Path -OutputObject $OutputObject
                [PSCustomObject] $OutputObject
            }
        }
    }
}

Function ConvertTo-FlatNormalizedObject {
    <#
        .SYNOPSIS
        Flattends a nested object into a single level object then normalizes the output so that all objects have the same properties.
        .DESCRIPTION
        Flattends a nested object into a single level object then normalizes the output so that all objects have the same properties.
        .PARAMETER Objects
        The object (or objects) to be flatten.
        .PARAMETER Separator
        The separator used between the recursive property names
        .PARAMETER Base
        The first index name of an embedded array:
        - 1, arrays will be 1 based: <Parent>.1, <Parent>.2, <Parent>.3, …
        - 0, arrays will be 0 based: <Parent>.0, <Parent>.1, <Parent>.2, …
        - "", the first item in an array will be unnamed and than followed with 1: <Parent>, <Parent>.1, <Parent>.2, …
        .PARAMETER Depth
        The maximal depth of flattening a recursive property. Any negative value will result in an unlimited depth and could cause a infinitive loop.
        .EXAMPLE
           $Object2 = [PSCustomObject] @{
        "Name"    = "John Smith"
        "Age"     = "99"
        "Address" = @{
            "Street"  = "Main"
            "City"    = "New York"
            "Country" = [ordered] @{
                "Name" = "Fish"
            }
            "PaulTest" = 'Test'
        }
        ListTest  = @(
            [PSCustomObject] @{
                "Name" = "ASDF"
                "Age"  = "33"
            }
        )
    }
        $Object3 = [PSCustomObject] @{
        "Name"    = "Przemyslaw Klys"
        "Age"     = "30"
        "Address" = @{
            "Street"  = "Kwiatowa"
            "City"    = "Warszawa"
            "Country" = [ordered] @{
                "Name" = "Poland"
            }
            List      = @(
                [PSCustomObject] @{
                    "Name" = "Adam Klys"
                    "Age"  = "32"
                }
                [PSCustomObject] @{
                    "Name" = "Justyna Klys"
                    "Age"  = "33"
                }
                [PSCustomObject] @{
                    "Name" = "Justyna Klys"
                    "Age"  = 30
                }
                [PSCustomObject] @{
                    "Name" = "Justyna Klys"
                    "Age"  = $null
                }
            )
        }
        ListTest  = @(
            [PSCustomObject] @{
                "Name" = "Sława Klys"
                "Age"  = "33"
            }
        )
    }
    $AllObjects = @($Object2,$Object3)
    #>
    [CmdletBinding()]
    Param (
        [Parameter(ValueFromPipeLine)][Object[]]$Objects,
        [String]$Separator = ".",
        [ValidateSet("", 0, 1)]$Base = 1,
        [Parameter(Mandatory = $false)]
        [ValidateScript({ $_ -ge 0 })]
        [int]$Depth = 5,
        [Parameter(DontShow)][String[]]$Path,
        [Parameter(DontShow)][System.Collections.IDictionary] $OutputObject
    )
    Begin {
        $AllProperties = @()
        $AllFlattened = @()
    }
    Process {
        $Flattened = ConvertTo-FlatObject -Objects $Objects -Separator $Separator -Base $Base -Depth $Depth -Path $Path
        $Flattened | ForEach-Object { $_ | Get-Member -MemberType Properties | ForEach-Object { if ($_.Name -notin $AllProperties) { $AllProperties += $_.Name } } } #get all properties for all objects
        $AllFlattened += $Flattened
    }
    End {
        $selectSplat = @{Property = $AllProperties | Where-Object { $_[0] -notin @('@', '$') } } #PS doesn't like properties that start with @ or $, if I find others later then I'll also ignore those or find a way to fix it
        $NormalizedFlattened = $AllFlattened | ForEach-Object { $_ | Select-Object @selectSplat } #"normalize" all values in the array by making it so that all of them have all properties that any other object has. The value will be $Null if it wasn't defined previously. This makes it so that export-csv works. There will be too many properties, but we can select the ones we want.
        $NormalizedFlattened
    }
}

Function GetMgEnvironment{
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $ContextEnvironment
    )
    Switch ($ContextEnvironment){
        'AzureCloud' {'Global'}
        'AzureUSGovernment' {'USGov'}
        'USNAT' {'USNAT'}
    }
}

Function Write-AHLogAnalytics {
    <#
    .SYNOPSIS
        This function sends data to Log Analytics using the Data Collector REST API
    .DESCRIPTION
        This function sends data to Log Analytics using the Data Collector REST API
    .PARAMETER WorkspaceId
        Specifies the WorkspaceId of the Log Analytics workspace to send the data to.
    .PARAMETER SharedKey
        Specifies the SharedKey of the Log Analytics workspace to send the data to.
    .PARAMETER LogName
        Specifies the LogName data to send to Log Analytics.
    .PARAMETER TimeStampInput
        Specifies the optional TimeStampInput.
    .PARAMETER json
        Specifies the json data to send to Log Analytics. The JSON should have 50 or fewer fields.
    .PARAMETER odsEndpoint
        Specifies the optional custom odsEndpointURI for other environments I'm not aware of. If not specified, the default is used based on the Azure Environments.
        For example, if you are using Azure Commercial and wanted to specify your odsEndpointUri, you would specify: 'ods.opinsights.azure.com', do not include the https://, or a trailing slash.
    .EXAMPLE
        $json = @"
        [{  "StringValue": "MyString1",
            "NumberValue": 42,
            "BooleanValue": true,
            "DateValue": "2019-09-12T20:00:00.625Z",
            "GUIDValue": "9909ED01-A74C-4874-8ABF-D2678E3AE23D"
        },
        {   "StringValue": "MyString2",
            "NumberValue": 43,
            "BooleanValue": false,
            "DateValue": "2019-09-12T20:00:00.625Z",
            "GUIDValue": "8809ED01-A74C-4874-8ABF-D2678E3AE23D"
        }]
        "@
        Write-AHLogAnalytics -WorkspaceId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' -SharedKey 'MySharedKeyGoesHere' -LogName 'MyLogName' -json $json
    .EXAMPLE
        Write-AHLogAnalytics -WorkspaceId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' -SharedKey 'MySharedKeyGoesHere' -LogName 'MyLogName' -json $json -TimeStampField $MyDateTimeObject
    .NOTES
        Author: #Credit to https://learn.microsoft.com/en-us/azure/azure-monitor/logs/data-collector-api?tabs=powershell
        I took what they had, validated it, and included it here with minor changes to make it even easier
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkspaceId,
        [Parameter(Mandatory = $true)]
        [string]$SharedKey,
        [Parameter(Mandatory = $true)]
        [string]$LogName,
        [Parameter(Mandatory = $false)]
        [datetime]$TimeStampInput = [datetime]::UtcNow,
        [Parameter(Mandatory = $true)]
        [ValidateScript({
            ((($_ | ConvertFrom-Json -Depth 99) | Get-Member -MemberType NoteProperty).count -le 50) -and `
                ([system.text.asciiEncoding]::Unicode.GetByteCount($_) -lt 32MB) -and `
                ([system.text.asciiEncoding]::Unicode.GetByteCount((($_ | ConvertFrom-Json -Depth 99) | Get-Member -MemberType NoteProperty).Name) -lt 32KB)
            })]
        [string]$json#,
        #[Parameter(Mandatory = $false)]
        #[string]$odsEndpoint #odsEndpoint is now defined in the profile
    )

    begin {            
        # Create the function to create and post the request
        Function Post-LogAnalyticsData($customerId, $sharedKey, $body, $LogName, $TimeStampField) {
            $method = "POST"
            $contentType = "application/json"
            $resource = "/api/logs"
            $rfc1123date = [DateTime]::UtcNow.ToString("r")
            $contentLength = $body.Length
            $signature = Build-Signature `
                -customerId $customerId `
                -sharedKey $sharedKey `
                -date $rfc1123date `
                -contentLength $contentLength `
                -method $method `
                -contentType $contentType `
                -resource $resource
            $uri = "https://" + $customerId + '.' + $odsEndpoint + $resource + "?api-version=2016-04-01"

            $headers = @{
                "Authorization"        = $signature;
                "Log-Type"             = $LogName;
                "x-ms-date"            = $rfc1123date;
                "time-generated-field" = $TimeStampField;
            }
            $response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $body -UseBasicParsing 4>$Null
            return $response.StatusCode

        }
       
        # Create the function to create the authorization signature
        Function Build-Signature ($customerId, $sharedKey, $date, $contentLength, $method, $contentType, $resource) {
            $xHeaders = "x-ms-date:" + $date
            $stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource

            $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
            $keyBytes = [Convert]::FromBase64String($sharedKey)

            $sha256 = New-Object System.Security.Cryptography.HMACSHA256
            $sha256.Key = $keyBytes
            $calculatedHash = $sha256.ComputeHash($bytesToHash)
            $encodedHash = [Convert]::ToBase64String($calculatedHash)
            $authorization = 'SharedKey {0}:{1}' -f $customerId, $encodedHash
            return $authorization
        }
    }

    Process {
        $TimeStampField = Get-Date $($TimeStampInput.ToUniversalTime()) -Format "o"
        $CustomerId = $WorkspaceId

        $result = Post-LogAnalyticsData -customerId $customerId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($json)) -LogName $LogName -TimeStampField $TimeStampField
        If ($result -ne 200) {
            Write-Error "Error writing to log analytics: $result"
        }
    }
    End {

    }
}

Function Write-CustomLog{
    param(
        [Parameter(Mandatory = $true)]
        [string]$TableName,
        [Parameter(Mandatory = $true)]
        [string]$SharedKey,
        [Parameter(Mandatory = $true)]
        [string]$WorkspaceId,
        [Parameter(Mandatory = $true)]
        [ValidateScript({
            ([system.text.asciiEncoding]::Unicode.GetByteCount($($_ | ConvertTo-Json -depth 99 -Compress)) -lt 31KB)
        })]
        [array]$data,
        [datetime]$TimeStampInput = [datetime]::UtcNow,
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$EventName
    )
 <#
    $json = [pscustomobject]@{
            'EventName'=$EventName
            'message'=$($data | ConvertTo-Json -Depth 99 -Compress)
            'batchTime'=$TimeStampInput.ToFileTime()
        } | convertto-json -depth 2 -Compress
    Write-AHLogAnalytics -SharedKey $SharedKey -WorkspaceId $WorkspaceId -LogName $TableName -TimeStampInput $TimeStampInput -json $json #-Verbose
#>
}

Function Write-CustomLogForEachItem{
    param(
        [Parameter(Mandatory = $true)]
        [string]$TableName,
        [Parameter(Mandatory = $true)]
        [string]$SharedKey,
        [Parameter(Mandatory = $true)]
        [string]$WorkspaceId,
        $data,
        [datetime]$TimeStampInput = [datetime]::UtcNow,
        [Parameter(Mandatory = $true)]
        [string]$EventName
    )
    #cleanup Data
<#
    $data = $data | where{$null -ne $_}
    If($null -eq $data -or $data.count -eq 0){
        $data = [array]@{'NoItemsFound' = 'No items found'}
    }

    ForEach($item in $data){
        Write-CustomLog -TableName $AtoTableName -SharedKey $sharedKey -WorkspaceId $workspaceId -data $item -EventName $EventName -TimeStampInput $now
    }
#>
}

Function Get-StringSizeInBytes{
    param(
        [Parameter(Mandatory = $true)]
        [string]$object
    )
    ([system.text.asciiEncoding]::Unicode.GetByteCount($object))
}

Function Get-WorkloadGroupsAndSubs{
    [CmdletBinding(DefaultParameterSetName='All')]
    param(
        [Parameter(Mandatory = $false,parameterSetName='WorkloadOnly')]
        [switch]$WorkloadOnly,
        [Parameter(Mandatory = $false,parameterSetName='PlatformOnly')]
        [switch]$PlatformOnly,
        [Parameter(Mandatory = $false,parameterSetName='All')]
        [switch]$All,
        [Parameter(Mandatory = $false,parameterSetName='nonCompliant')]
        [switch]$nonCompliant
    )
    begin{
        #$managementGroupWorkloadSearch = $landingZoneDisplayName #"Landing Zone"
    }
    process{
        $subQuery = @'
resourcecontainers
| where type =~ "microsoft.resources/subscriptions"
| extend managementGroupAncestorsChain = tostring(parse_json(properties).managementGroupAncestorsChain)
| project subscriptionName = name, subscriptionId, managementGroupAncestorsChain
'@
        $token = Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl
        #$token = (Get-AzAccessToken -ResourceUrl $TokenResourceUrl).token
        $uri = "https://$managementApiBase/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01"
        $body = @{
            query = $subQuery
        } | ConvertTo-Json -Depth 99
        $subResultTemp = (Invoke-DCMsGraphQuery -AccessToken $token -GraphMethod Post -GraphUri $uri -GraphBody $body) #.data

        $allResults=ForEach($result in $subResultTemp){
                $temp=($result.managementGroupAncestorsChain | ConvertFrom-Json).displayName
                [array]::reverse($temp)
                $ManagementGroupAncestorsChainDisplayName = $temp -join('\')
                $temp=($result.managementGroupAncestorsChain | ConvertFrom-Json).Name
                [array]::reverse($temp)
                $ManagementGroupAncestorsChainId = $temp -join('\')
                $isWorkloadSub = $ManagementGroupAncestorsChainDisplayName -like "*\$landingZoneDisplayName*"
                $isPlatformSub = $ManagementGroupAncestorsChainDisplayName -like "*\$platformGroupDisplayName*"
                $isDeprovisionedSub = $ManagementGroupAncestorsChainDisplayName -like "*\$deprovisionedGroupDisplayName*"
                $WorkloadManagementGroupDisplayName = If($isWorkloadSub){
                    $ManagementGroupAncestorsChainDisplayName.split("\$landingZoneDisplayName")[1].split('\')[1]
                }ElseIf($isPlatformSub){
                    $platformGroupDisplayName
                }else{
                    write-warning "This subscription is not in a workload or platform management group"
                    $null
                }
                if($WorkloadManagementGroupDisplayName){
                    $index = [array]::IndexOf($ManagementGroupAncestorsChainDisplayName.split('\'),$WorkloadManagementGroupDisplayName)
                    $WorkloadManagementGroupId = $ManagementGroupAncestorsChainId.split('\')[$index]
                }else{
                    $WorkloadManagementGroupId = $Null
                }
                write-verbose "WorkloadManagementGroupDisplayName = $WorkloadManagementGroupDisplayName - platformGroupDisplayName = $platformGroupDisplayName"
                [pscustomobject]@{
                    subscriptionName = $result.subscriptionName;
                    subscriptionId = $result.subscriptionId;
                    ManagementGroupAncestorsChainDisplayName = $ManagementGroupAncestorsChainDisplayName
                    ManagementGroupAncestorsChainId = $ManagementGroupAncestorsChainId
                    isWorkloadSub = $isWorkloadSub
                    isPlatformSub = $isPlatformSub
                    WorkloadManagementGroupDisplayName = $WorkloadManagementGroupDisplayName
                    WorkloadManagementGroupId = $WorkloadManagementGroupId
                }
        }
        If($WorkloadOnly){
            $allResults | where{$_.isWorkloadSub}
        }elseif($PlatformOnly){
            $allResults | where{$_.isPlatformSub}
        }elseif($All){
            $allResults
        }elseif($nonCompliant){
            $allResults | where{!($_.isWorkloadSub) -and !($_.isPlatformSub) -and $_.ManagementGroupAncestorsChainDisplayName -notlike "*\Deprovisioned*"}
        }
        Else{
            $allResults
        }
    }
    end{}
}

Function Get-SSPsAndSubs{
    [CmdletBinding(DefaultParameterSetName='All')]
    param(
        [Parameter(Mandatory = $false,parameterSetName='WorkloadOnly')]
        [switch]$WorkloadOnly,
        [Parameter(Mandatory = $false,parameterSetName='PlatformOnly')]
        [switch]$PlatformOnly,
        [Parameter(Mandatory = $false,parameterSetName='All')]
        [switch]$All,
        [Parameter(Mandatory = $false,parameterSetName='nonCompliant')]
        [switch]$nonCompliant
    )
    begin{
        #$managementGroupWorkloadSearch = $landingZoneDisplayName #"Landing Zone"
    }
    process{
        $subQuery = @'
resourcecontainers
| where type =~ "microsoft.resources/subscriptions"
| extend managementGroupAncestorsChain = tostring(parse_json(properties).managementGroupAncestorsChain)
| project subscriptionName = name, subscriptionId, managementGroupAncestorsChain
'@
        $token = Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl
        #$token = (Get-AzAccessToken -ResourceUrl $TokenResourceUrl).token
        $uri = "https://$managementApiBase/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01"
        $body = @{
            query = $subQuery
        } | ConvertTo-Json -Depth 99
        $subResultTemp = (Invoke-DCMsGraphQuery -AccessToken $token -GraphMethod Post -GraphUri $uri -GraphBody $body) #.data

        $allResults = ForEach($result in $subResultTemp){
            $temp=($result.managementGroupAncestorsChain | ConvertFrom-Json).displayName
            [array]::reverse($temp)
            $ManagementGroupAncestorsChainDisplayName = $temp -join('\')
            $temp=($result.managementGroupAncestorsChain | ConvertFrom-Json).Name
            [array]::reverse($temp)
            $ManagementGroupAncestorsChainId = $temp -join('\')
            $isWorkloadSub = $ManagementGroupAncestorsChainDisplayName -like "*\$landingZoneDisplayName*"
            $isPlatformSub = $ManagementGroupAncestorsChainDisplayName -like "*\$platformGroupDisplayName*"
            $isDeprovisionedSub = $ManagementGroupAncestorsChainDisplayName -like "*\$deprovisionedGroupDisplayName*"
            $WorkloadManagementGroupDisplayName = If($isWorkloadSub){
                $ManagementGroupAncestorsChainDisplayName.split("\$landingZoneDisplayName")[1].split('\')[1]
            }ElseIf($isPlatformSub){
                $platformGroupDisplayName
            }else{
                write-warning "This subscription is not in a workload or platform management group"
                $null
            }
            if($WorkloadManagementGroupDisplayName){
                $index = [array]::IndexOf($ManagementGroupAncestorsChainDisplayName.split('\'),$WorkloadManagementGroupDisplayName)
                $WorkloadManagementGroupId = $ManagementGroupAncestorsChainId.split('\')[$index]
            }else{
                $WorkloadManagementGroupId = $Null
            }
            $SSP = $SubIdToSSP.$($result.subscriptionId)
            write-verbose "WorkloadManagementGroupDisplayName = $WorkloadManagementGroupDisplayName - platformGroupDisplayName = $platformGroupDisplayName"
            write-verbose "SSP = $SSP"
            [pscustomobject]@{
                subscriptionName = $result.subscriptionName;
                subscriptionId = $result.subscriptionId;
                ManagementGroupAncestorsChainDisplayName = $ManagementGroupAncestorsChainDisplayName
                ManagementGroupAncestorsChainId = $ManagementGroupAncestorsChainId
                isWorkloadSub = $isWorkloadSub
                isPlatformSub = $isPlatformSub
                #WorkloadManagementGroupDisplayName = $WorkloadManagementGroupDisplayName
                #WorkloadManagementGroupId = $WorkloadManagementGroupId
                SSP = $SSP
            }
        }

        If($WorkloadOnly){
            $allResults | where{$_.isWorkloadSub}
        }elseif($PlatformOnly){
            $allResults | where{$_.isPlatformSub}
        }elseif($All){
            $allResults
        }elseif($nonCompliant){
            $allResults | where{!($_.isWorkloadSub) -and !($_.isPlatformSub) -and $_.ManagementGroupAncestorsChainDisplayName -notlike "*\Deprovisioned*"}
        }
        Else{
            $allResults
        }
    }
    end{        
    }
}
Function GenerateSidecarMetadata{
    param(
        [Parameter(Mandatory = $false)]
        [switch]$isTenantFile,
        [Parameter(Mandatory = $false)]
        [string]$subscriptionId
    )
    if($isTenantFile){
        @{'isTenantFile' = $true;
          'isWorkloadFile' = $false
        }
    }Else{
        $isWorkloadFile = $(if($subscriptionId -in [array]($WorkloadGroupsAndSubs | where{$_.isWorkloadSub}).subscriptionId){$true}Else{$false})
        $workloadGroupId = 'something'
        $workloadGroupDisplayName = If($subscriptionId){($WorkloadGroupsAndSubs | where{$_.subscriptionId -eq $subscriptionId}).WorkloadManagementGroupDisplayName}Else{$null}
        @{  'isTenantFile' = $false;
            'isWorkloadFile' = $isWorkloadFile;
            'workloadGroupId' = $workloadGroupId;
            'workloadGroupDisplayName' = $workloadGroupDisplayName
        }
    }
}

Function UploadFilesByWorkload{
    <#
    .SYNOPSIS
        Uploads files with only the data relevant to workload management groups and automatically grouped into directory structures based on workload management groups
    .PARAMETER ConnectionStringURI
        Specifies the connection string URI for the storage account where the files will be uploaded.
    .PARAMETER Path
        Specifies the path where the files will be stored in the storage account. If not specified, a default path will be used based on the current date and time.
    .PARAMETER filename
        Specifies the name of the file to be uploaded.
    .PARAMETER timestamp
        Specifies the timestamp to be appended to the filename. If not specified, the current date and time will be used.
    .PARAMETER dataToUpload
        Specifies the data as a [array]pscustomobject to be included in the file.
    .PARAMETER infile
        Specifies the input file to be uploaded.
    .PARAMETER storageToken
        Specifies the storage token for authentication to the storage account.
    .PARAMETER extension
        Specifies the file extension for the uploaded file. Default value is 'json'.
    .PARAMETER metadata
        Specifies the metadata to be associated with the uploaded file.
    .PARAMETER subscriptionProperty
        Specifies the subscription property in dataToUpload that has subscriptionId data so that it can be parsed and used to determine workload groups.
    .EXAMPLE
        UploadFilesByWorkload -ConnectionStringURI "your_connection_string_uri" -Path "your_path" -filename "your_filename" -timestamp "your_timestamp" -dataToUpload $dataToUpload -infile "your_input_file" -storageToken "your_storage_token" -extension "your_extension" -metadata @{"key1"="value1"; "key2"="value2"} -subscriptionProperty "your_subscription_property"
    #>
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)]
        [string]
        $ConnectionStringURI,
        [parameter(Mandatory = $false)]
        [string]
        $Path = {
            $myUTC = ([datetime]::UtcNow).tostring('yyyy-MM-ddTHH:mm:ss')
            $tzUTC = [system.timezoneinfo]::GetSystemTimeZones() | Where-Object { $_.id -eq 'UTC' }
            $tzEST = [system.timezoneinfo]::GetSystemTimeZones() | Where-Object { $_.id -eq 'US Eastern Standard Time' }
            $now = [System.TimeZoneInfo]::ConvertTime($myUTC, $tzUTC, $tzEST)
            "y=$($now.tostring('yyyy'))/m=$($now.tostring('MM'))/d=$($now.tostring('dd'))/h=$($now.tostring('HH'))/m=$($now.tostring('mm'))"
        },
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $filename,
        [parameter(Mandatory = $false)]
        [string]
        $timestamp = [datetime]::UtcNow.tostring('yyyy-MM-dd_HHmmss'),
        [parameter(Mandatory = $false)]
        $dataToUpload = '',
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $storageToken,
        [parameter(Mandatory = $false)]
        [ValidateSet('json', 'csv')]
        [string]
        $extension = 'json',
        [parameter(Mandatory = $false)]
        [hashtable]
        $metadata = @{},
        [parameter(Mandatory = $true)]
        [string]
        $subscriptionProperty,
        [parameter(Mandatory = $false)]
        [switch]
        $PlatformOnly,
        [parameter(Mandatory = $false)]
        [switch]
        $LandingZoneOnly,
        [parameter(Mandatory = $false)]
        [switch]
        $IncludeNonWorkload
    )

    $uploadResultSplat = @{
        'ConnectionStringURI' = $ConnectionStringURI;
        'Path' = $Path;
        'timestamp' = $timestamp;
        'storageToken' = $storageToken;
        'extension' = $extension;
    }
    If($metadata){
        $uploadResultSplat.Add('metadata',$metadata)
    }

    # loop through every workload
        # loop through every sub in the workload
            # get the relevant bits of the file based on the subscriptionProperty property
        # combine the relevant data into a single properly structured variable, then upload it

    $targetWorkloads = @()
    If($PlatformOnly){
        If($useNewSSPCode){
            $targetWorkloads += $SSPsAndSubs | where{$_.isPlatformSub} | group SSP
        }Else{
            $targetWorkloads += $WorkloadGroupsAndSubs | where{$_.isPlatformSub} | group WorkloadManagementGroupDisplayName
        }
    }
    If($LandingZoneOnly){
        If($useNewSSPCode){
            $targetWorkloads += $SSPsAndSubs | where{$_.isWorkloadSub} | group SSP
        }Else{
            $targetWorkloads += $WorkloadGroupsAndSubs | where{$_.isWorkloadSub} | group WorkloadManagementGroupDisplayName
        }
#        $targetWorkloads += $WorkloadGroupsAndSubs | where{$_.isWorkloadSub} | group WorkloadManagementGroupDisplayName
    }
    If(!(($PlatformOnly -or $LandingZoneOnly))){
        If($useNewSSPCode){
            $targetWorkloads = $SSPsAndSubs | group SSP
        }Else{
            $targetWorkloads = $WorkloadGroupsAndSubs | group WorkloadManagementGroupDisplayName
        }
#        $targetWorkloads = $WorkloadGroupsAndSubs | group WorkloadManagementGroupDisplayName
    }
   

    ForEach($workload in $targetWorkloads){
        $workloadData = $dataToUpload | where{$_."$subscriptionProperty" -in $workload.Group.subscriptionId}

        Write-Verbose "workload = $($workload.Name)"
        #update metadata if necessary. This overwrites existing values if there were any but preserves any that don't conflict
        $metadata.'isWorkloadFile' = If($PlatformOnly){$false}Else{$true}
        $metadata.'isTenantFile'   = If($PlatformOnly){$true}Else{$false}
        If($useNewSSPCode){
            $metadata.'SSP' = $workload.Name
        }Else{
            $metadata.'workloadGroupDisplayName' = $workload.Name
            $metadata.'workloadGroupId' = ($WorkloadGroupsAndSubs | where{$_.WorkloadManagementGroupDisplayName -eq $workload.Name})[0].WorkloadManagementGroupId
        }
        $uploadResultSplat.'filename' = $(Remove-InvalidFileNameChars $("$filename"+"_$($workload.Name)_$tenantDisplayName"))
        $uploadResultSplat.'queryResult' = $workloadData
        $uploadResultSplat.'metadata' = $metadata
        #Write-Verbose "uploadResultSplat = $($uploadResultSplat | ConvertTo-Json -Depth 9)"
        uploadResult3 @uploadResultSplat
    }
    If($IncludeNonWorkload){
        $workloadData = $dataToUpload | where{$Null -eq $_.SSPID}
        $metadata.'isWorkloadFile' = $false
        $metadata.'isTenantFile'   = $false
        If($useNewSSPCode){
            $metadata.'SSP' = $workload.Name
        }Else{
            $metadata.'workloadGroupDisplayName' = $null
            $metadata.'workloadGroupId' = $null
        }
        $uploadResultSplat.'filename' = $(Remove-InvalidFileNameChars $("$filename"+"_NonWorkload_$tenantDisplayName"))
        $uploadResultSplat.'queryResult' = $workloadData
        $uploadResultSplat.'metadata' = $metadata
        uploadResult3 @uploadResultSplat
    }
}

Function GetSSPID{
    param(
        # Parameter help description
        [Parameter(Mandatory = $true,ParameterSetName = 'resourceId')]
        [Alias("Id")]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({
            $_.split('/')[1] -eq 'subscriptions'
        })]
        [string]
        $resourceId,
        [Parameter(Mandatory = $false,ParameterSetName = 'subscriptionId')]
        [ValidateNotNullOrEmpty()]
        [string]
        $subscriptionId,
        [Parameter(Mandatory = $false)]
        [switch]
        $DisplayName
    )
    If($resourceId){
        $subTemp = $resourceId.split('/')[2]
    }ElseIf($subscriptionId){
        $subTemp = $subscriptionId
    }

    If($DisplayName){
        $SubIdToSSPManagementGroup."$($subTemp)"
    }Else{
        $SubIdToSSPId."$($subTemp)"
    }
}

Function GetSSP{
    param(
        # Parameter help description
        [Parameter(Mandatory = $true,ParameterSetName = 'resourceId')]
        [Alias("Id")]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({
            $_.split('/')[1] -eq 'subscriptions'
        })]
        [string]
        $resourceId,
        [Parameter(Mandatory = $false,ParameterSetName = 'subscriptionId')]
        [ValidateNotNullOrEmpty()]
        [string]
        $subscriptionId
    )

    If($resourceId){
        $subTemp = $resourceId.split('/')[2]
    }ElseIf($subscriptionId){
        $subTemp = $subscriptionId
    }

#    ($SSPsandSubs | where{$_.subscriptionId -eq $subTemp}).ssp
    $SubIdToSSP."$($subTemp)"
}

Function Add-SSPID{
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [pscustomobject]
        $object,
        [Parameter(Mandatory = $true, ParameterSetName = 'SubscriptionId')]
        [ValidateNotNullOrEmpty()]
        [string]
        $subscriptionIdProperty,
        [Parameter(Mandatory = $true, ParameterSetName = 'resourceId')]
        [ValidateNotNullOrEmpty()]
        [string]
        $resourceIdProperty,
        [Parameter(Mandatory = $false)]
        [switch]
        $DisplayName
    )
    If($DisplayName){
        $AddMemberName = 'SSPManagementGroup'
        $GetSSPIDSplat = @{'DisplayName' = $true}
    }Else{
        $AddMemberName = 'SSPID'
        $GetSSPIDSplat = @{}
    }
    If($subscriptionIdProperty){
        If($object."$subscriptionIdProperty"){
            $object | Add-Member -Name $AddMemberName -MemberType NoteProperty -Value $(GetSSPID @GetSSPIDSplat -subscriptionId $($object."$subscriptionIdProperty"))
        }Else{
            $object | Add-Member -Name $AddMemberName -MemberType NoteProperty -Value 'unknown'
        }
    }ElseIf($resourceIdProperty){
        If($object."$resourceIdProperty"){
            $object | Add-Member -Name $AddMemberName -MemberType NoteProperty -Value $(GetSSPID @GetSSPIDSplat -resourceId $($object."$resourceIdProperty")) #-PassThru
        }Else{
            $object | Add-Member -Name $AddMemberName -MemberType NoteProperty -Value 'unknown'
        }
    }Else{
        throw "Invalid parameters"
    }
}

Function Add-SSP{
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [pscustomobject]
        $object,
        [Parameter(Mandatory = $true, ParameterSetName = 'SubscriptionId')]
        [ValidateNotNullOrEmpty()]
        [string]
        $subscriptionIdProperty,
        [Parameter(Mandatory = $true, ParameterSetName = 'resourceId')]
        [ValidateNotNullOrEmpty()]
        [string]
        $resourceIdProperty
    )
    $AddMemberName = 'SSPID'

    If($subscriptionIdProperty){
        If($object."$subscriptionIdProperty"){
            $object | Add-Member -Name $AddMemberName -MemberType NoteProperty -Value $(GetSSP -subscriptionId $($object."$subscriptionIdProperty")) -EA 0 -Force
        }Else{
            $object | Add-Member -Name $AddMemberName -MemberType NoteProperty -Value 'unknown' -EA 0 -Force
        }
    }ElseIf($resourceIdProperty){
        If($object."$resourceIdProperty"){
            $object | Add-Member -Name $AddMemberName -MemberType NoteProperty -Value $(GetSSP -resourceId $($object."$resourceIdProperty")) -EA 0 -Force
        }Else{
            $object | Add-Member -Name $AddMemberName -MemberType NoteProperty -Value 'unknown' -EA 0 -Force
        }
    }Else{
        throw "Invalid parameters"
    }
}

Function Add-AllSSPIDs{
    param(
        [Parameter(Mandatory = $true)]
        $arrayOfObjects,
        [Parameter(Mandatory = $true, ParameterSetName = 'SubscriptionId')]
        [ValidateNotNullOrEmpty()]
        [string]
        $subscriptionIdProperty,
        [Parameter(Mandatory = $true, ParameterSetName = 'resourceId')]
        [ValidateNotNullOrEmpty()]
        [string]
        $resourceIdProperty,
        [Parameter(Mandatory = $false)]
        [switch]
        $DisplayName
    )

    If($subscriptionIdProperty){
        $idData = @{'subscriptionIdProperty' = $subscriptionIdProperty}
    }ElseIf($resourceIdProperty){
        $idData = @{'resourceIdProperty' = $resourceIdProperty}
    }Else{
        throw "invalid parameters"
    }
    If($useNewSSPCode){
        ForEach($object in $arrayOfObjects){
            $addSSPSplat = @{'object' = $object}
            $addSSPSplat += $idData
            Add-SSP @addSSPSplat -EA 0
        }
    }Else{
        ForEach($object in $arrayOfObjects){
            $addSSPIDSplat = @{'object' = $object}
            If($DisplayName){$addSSPIDSplat += @{'DisplayName'=$true}}
            $addSSPIDSplat += $idData
            Add-SSPID @addSSPIDSplat
        }
    }
}

Function Add-AllSSPs{
    param(
        [Parameter(Mandatory = $true)]
        $arrayOfObjects,
        [Parameter(Mandatory = $true, ParameterSetName = 'SubscriptionId')]
        [ValidateNotNullOrEmpty()]
        [string]
        $subscriptionIdProperty,
        [Parameter(Mandatory = $true, ParameterSetName = 'resourceId')]
        [ValidateNotNullOrEmpty()]
        [string]
        $resourceIdProperty
    )

    If($subscriptionIdProperty){
        $idData = @{'subscriptionIdProperty' = $subscriptionIdProperty}
    }ElseIf($resourceIdProperty){
        $idData = @{'resourceIdProperty' = $resourceIdProperty}
    }Else{
        throw "invalid parameters"
    }
    ForEach($object in $arrayOfObjects){
        $addSSPSplat = @{'object' = $object}
        $addSSPSplat += $idData
        Add-SSP @addSSPSplat
    }
}
Function Get-AzurePolicyDefinitionTargetedResourceTypes{
    param(
        [parameter(Mandatory = $true)]
        [pscustomobject]$JSON
    )
    begin{
        $sameLevelTypes = @('equal')
        $childLevelTypes = @('in','allOf','anyOf', 'oneOf')
    }
    process{
        $resourceTypes = ForEach($chunk in $($JSON | get-member -MemberType NoteProperty)){
            If($JSON.field -contains 'type'){
                ForEach($valueAtField in $(($json | get-Member -MemberType 'NoteProperty' | where{$_.Name -ne 'field'})).Name){
                    (($JSON | where{$_.field -eq 'type'}) | select equals) | %{($_ | get-member -MemberType NoteProperty).definition.split('=')[1]} | where {'null' -ne $_} #this returns all items, I may want to join them
                    ((($JSON | where{$_.field -eq 'type'}) | select in).in | where {'null' -ne $_}) #-join(';')
                }
            }
            Get-AzurePolicyDefinitionTargetedResourceTypes -JSON $JSON."$($chunk.Name)" | select -Unique
        }
        $resourceTypes | where{$null -ne $_} | select -unique
    }
    end{
        $resourceTypes
    }
}

Function Get-GroupEntraRolesRest{
    <#
        .DESCRIPTION
            This function gets all roles for a group using the Graph API
        .PARAMETER groupId
            The group ID to get the roles for
        .PARAMETER graphToken
            The token to use to authenticate to the Graph API
        .EXAMPLE
            Get-GroupEntraRoles -groupId '00000000-0000-0000-0000-000000000000' -graphToken $graphToken
    #>
    Param(
        [Parameter(Mandatory=$true)]
        [string]$groupId,
        [Parameter(Mandatory=$true)]
        [string]$graphToken
    )
    #Get all roles so that we can make the results later human readable
    $uri = "$GraphResourceUrl/v1.0/roleManagement/directory/roleDefinitions"
    $roleDefinitions = Invoke-DCMsGraphQuery -GraphMethod 'Get' -GraphUri $uri -AccessToken $graphToken

    $uri = "$GraphResourceUrl/v1.0/roleManagement/directory/roleAssignments?`$filter=principalId eq '$groupId'"
    $GroupRoles = Invoke-DCMsGraphQuery -GraphMethod 'Get' -GraphUri $uri -AccessToken $graphToken | where{$_.id}
   
    $GroupRolesPretty = ForEach($role in $GroupRoles){
        $roleName = $roleDefinitions | where{$_.id -eq $role.roleDefinitionId} | select -ExpandProperty displayName
        #$principalUPN = $UserIdToUPNLookup."$($role.principalId)"
        [pscustomobject]@{
            RoleName = $roleName
            RoleDefinitionId = $role.roleDefinitionId
            #Scope = $role.directoryScopeId
        }
    }
    $GroupRolesPretty
}

Function Get-AzureRoleAssignmentsRest{
    <#
        .DESCRIPTION
            This function gets all Azure role assignments for a group using the Graph API
        .PARAMETER groupId
            The group ID to get the roles for
        .PARAMETER graphToken
            The token to use to authenticate to the Graph API
        .EXAMPLE
            Get-AzureRoleAssignmentsRest -groupId '00000000-0000-0000-0000-000000000000' -graphToken $graphToken
    #>
    Param(
        [Parameter(Mandatory=$true)]
        [string]$groupId,
        [Parameter(Mandatory=$true)]
        [string]$managementToken
    )
    $tenantId = $env:PolicyExportTenant
    $managementGroupId = $env:PolicyManagementGroupId
    $AzureRoles = @()
    $uri = "$TokenResourceUrl/providers/Microsoft.Management/managementGroups/$ManagementGroupId/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=assignedTo('$groupId')"
    $AzureRoles += Invoke-DCMsGraphQuery -GraphMethod 'Get' -GraphUri $uri -AccessToken $managementToken | where{$_.properties}
    ForEach($sub in $allSubs){
        $uri = "$TokenResourceUrl/subscriptions/$($sub.subscriptionId)/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=assignedTo('$groupId')"
        $AzureRoles += Invoke-DCMsGraphQuery -GraphMethod 'Get' -GraphUri $uri -AccessToken $managementToken | where{$_.properties}
    }

    $AzureRolesPretty = ForEach($role in $AzureRoles){
        $roleName = $AzureRoleNameToDisplayName."$($role.properties.roleDefinitionId.split('/')[-1])"
        If($null -eq $roleName){
            $uri = "$tokenResourceUrl/$($role.properties.roleDefinitionId)?disambiguration_dummy&api-version=2022-04-01"
            $roleName = (Invoke-DCMsGraphQuery -GraphMethod 'Get' -GraphUri $uri -AccessToken $managementToken).properties.roleName
        }
        $ScopeName = If($role.properties.scope -like '/subscriptions/*'){
            #"Subscription: $($_.properties.scope.split('/')[2])"
            $subLookup."$($role.properties.scope.split('/')[2])"
        }Elseif($role.properties.scope -like '/providers/Microsoft.Management/managementGroups/*'){
            #"Management Group: $($_.properties.scope.split('/')[2])"
            $managementGroupLookup."$($role.properties.scope.split('/')[4])"
        }Else{
            ''
        }
        [pscustomobject]@{
            RoleName = $roleName
            RoleDefinitionId = $role.properties.roleDefinitionId
            Scope = $role.properties.scope
            ScopeName = $ScopeName
        }
    }
    $AzureRolesPretty
}

Function Convert-ISO8601ToTimeSpan{
    <#
        .DESCRIPTION
            This function converts an ISO8601 formatted string to a TimeSpan object
        .PARAMETER iso8601
            The ISO8601 formatted string to convert
        .EXAMPLE
            Convert-ISO8601ToTimeSpan -iso8601 'P1Y2M3DT4H5M6S'
    #>
    Param(
        [Parameter(Mandatory=$true)]
        [string]$iso8601
    )
    [System.Xml.XmlConvert]::ToTimeSpan($iso8601)
}

Function Parse-PIMPolicies{
    param(
        [array]$Policies,
        [switch]$OnlyNotificationsWithAdditionalRecipients
    )
    $policyCounter = 0
    $ParsedPolicies = [pscustomobject]@{
        'Member' = [pscustomobject]@{
            'Activation' = @()
            'Assignment' = @()
            'Send notifications when members are assigned as eligible to this role' = @() #Send notifications when members are assigned as eligible to this role
            'Send notifications when members are assigned as active to this role' = @() #Send notifications when members are assigned as active to this role
            'Send notifications when eligible members activate this role' = @() #Send notifications when members activate this role
        }
        'Owner' = [pscustomobject]@{
            'Activation' = @()
            'Assignment' = @()
            'Send notifications when members are assigned as eligible to this role' = @() #Send notifications when members are assigned as eligible to this role
            'Send notifications when members are assigned as active to this role' = @() #Send notifications when members are assigned as active to this role
            'Send notifications when eligible members activate this role' = @() #Send notifications when members activate this role
        }
    }
    ForEach($policy in $Policies){
        $memberOrOwner = If($policyCounter -eq 0){"Member"}ElseIf($policyCounter -eq 1){"Owner"}Else{"Unknown"}
        $parsedRules = Parse-PIMPolicyRules -rules $policy.rules -OnlyNotificationsWithAdditionalRecipients:$OnlyNotificationsWithAdditionalRecipients
        $ParsedPolicies."$memberOrOwner" = $parsedRules
        $policyCounter += 1
    }
    $ParsedPolicies
}

Function Parse-PIMPolicyRules{
    param(
        [array]$rules,
        [switch]$OnlyNotificationsWithAdditionalRecipients
    )

    #Expiration_Admin_Eligibility Rule
    $expiration_Admin_EligibilityRule = $rules | where{$_.id -eq 'Expiration_Admin_Eligibility'}
    $expirationRequired = [bool]($Expiration_Admin_EligibilityRule.isExpirationRequired)
    $allowPermanentEligibleAssignment = !$expirationRequired
    $PermanentEligibilityExpiresAfter = If($expirationRequired){$rule.maximumDuration}else{"N/A"}

    #Notification_Admin_Admin_Eligibility Rule
    $Notification_Admin_Admin_EligibilityRule = $rules | where{$_.id -eq 'Notification_Admin_Admin_Eligibility'}
    $AssignedEligibleNotificationsRoleAssignment = $Notification_Admin_Admin_EligibilityRule.isDefaultRecipientsEnabled

    #Notification_Requestor_Admin_Eligibility Rule
    $Notification_Requestor_Admin_EligibilityRule = $rules | where{$_.id -eq 'Notification_Requestor_Admin_Eligibility'}
    $AssignedEligibleNotificationsAssigneeDefaultRecipientsEnabled = $Notification_Requestor_Admin_EligibilityRule.isDefaultRecipientsEnabled
    $AssignedEligibleNotificationsAssigneeNotificationLevel = $Notification_Requestor_Admin_EligibilityRule.notificationLevel
    $AssignedEligibleNotificationsAssigneeNotificationType = $Notification_Requestor_Admin_EligibilityRule.notificationType
    $AssignedEligibleNotificationsAssigneeAdditionalRecipients = $Notification_Requestor_Admin_EligibilityRule.notificationRecipients
    $AssignedEligibleNotificationsAssigneeTargetOperations = $Notification_Requestor_Admin_EligibilityRule.target.operations -join(';')

    #Notification_Approver_Admin_Eligibility Rule
    $Notification_Approver_Admin_EligibilityRule = $rules | where{$_.id -eq 'Notification_Approver_Admin_Eligibility'}
    $AssignedEligibleNotificationsRenewalDefaultRecipientsEnabled = $Notification_Approver_Admin_EligibilityRule.isDefaultRecipientsEnabled
    $AssignedEligibleNotificationsRenewalNotificationLevel = $Notification_Approver_Admin_EligibilityRule.notificationLevel
    $AssignedEligibleNotificationsRenewalNotificationType = $Notification_Approver_Admin_EligibilityRule.notificationType
    $AssignedEligibleNotificationsRenewalAdditionalRecipients = $Notification_Approver_Admin_EligibilityRule.notificationRecipients
    $AssignedEligibleNotificationsRenewalTargetOperations = $Notification_Approver_Admin_EligibilityRule.target.operations -join(';')

    #Enablement_Admin_Eligibility Rule - Not currently used
   
    #Expiration_Admin_Assignment Rule
    $Expiration_Admin_AssignmentRule = $rules | where{$_.id -eq 'Expiration_Admin_Assignment'}
    $expirationRequired = [bool]($Expiration_Admin_AssignmentRule.isExpirationRequired)
    $allowPermanentActiveAssignment = !$expirationRequired
    $expirePermanentAssignmentsAfter = If($expirationRequired){$Expiration_Admin_AssignmentRule.maximumDuration}else{"N/A"}

    #Enablement_Admin_Assignment Rule
    $Enablement_Admin_AssignmentRule = $rules | where{$_.id -eq 'Enablement_Admin_Assignment'}
    $requireJustificationOnActiveAssignment = [bool]($Enablement_Admin_AssignmentRule.enabledRules -contains 'Justification')

    #Notification_Admin_Admin_Assignment Rule
    $Notification_Admin_Admin_AssignmentRule = $rules | where{$_.id -eq 'Notification_Admin_Admin_Assignment'}
    $AssignedActiveNotificationsRoleAssignmentDefaultRecipientsEnabled = $Notification_Admin_Admin_AssignmentRule.isDefaultRecipientsEnabled
    $AssignedActiveNotificationsRoleAssignmentNotificationLevel = $Notification_Admin_Admin_AssignmentRule.notificationLevel
    $AssignedActiveNotificationsRoleAssignmentNotificationType = $Notification_Admin_Admin_AssignmentRule.notificationType
    $AssignedActiveNotificationsRoleAssignmentAdditionalRecipients = $Notification_Admin_Admin_AssignmentRule.notificationRecipients
    $AssignedActiveNotificationsRoleAssignmentTargetOperations = $Notification_Admin_Admin_AssignmentRule.target.operations -join(';')

    #Notification_Requestor_Admin_Assignment Rule
    $Notification_Requestor_Admin_AssignmentRule = $rules | where{$_.id -eq 'Notification_Requestor_Admin_Assignment'}
    $AssignedActiveNotificationsAssigneeDefaultRecipientsEnabled = $Notification_Requestor_Admin_AssignmentRule.isDefaultRecipientsEnabled
    $AssignedActiveNotificationsAssigneeNotificationLevel = $Notification_Requestor_Admin_AssignmentRule.notificationLevel
    $AssignedActiveNotificationsAssigneeNotificationType = $Notification_Requestor_Admin_AssignmentRule.notificationType
    $AssignedActiveNotificationsAssigneeAdditionalRecipients = $Notification_Requestor_Admin_AssignmentRule.notificationRecipients
    $AssignedActiveNotificationsAssigneeTargetOperations = $Notification_Requestor_Admin_AssignmentRule.target.operations -join(';')

    #Notification_Approver_Admin_Assignment Rule
    $Notification_Approver_Admin_AssignmentRule = $rules | where{$_.id -eq 'Notification_Approver_Admin_Assignment'}
    $AssignedActiveNotificationsRenewalDefaultRecipientsEnabled = $Notification_Approver_Admin_AssignmentRule.isDefaultRecipientsEnabled
    $AssignedActiveNotificationsRenewalNotificationLevel = $Notification_Approver_Admin_AssignmentRule.notificationLevel
    $AssignedActiveNotificationsRenewalNotificationType = $Notification_Approver_Admin_AssignmentRule.notificationType
    $AssignedActiveNotificationsRenewalAdditionalRecipients = $Notification_Approver_Admin_AssignmentRule.notificationRecipients
    $AssignedActiveNotificationsRenewalTargetOperations = $Notification_Approver_Admin_AssignmentRule.target.operations -join(';')

    #Expiration_EndUser_Assignment Rule
    $Expiration_EndUser_AssignmentRule = $rules | where{$_.id -eq 'Expiration_EndUser_Assignment'}
    $activationMaximumDuration = $Expiration_EndUser_AssignmentRule.maximumDuration

    #Enablement_EndUser_Assignment Rule - Not currently used

    #Approval_EndUser_Assignment Rule
    $Approval_EndUser_AssignmentRule = $rules | where{$_.id -eq 'Approval_EndUser_Assignment'}
    $requireApprovalToActivate = [bool]($Approval_EndUser_AssignmentRule.setting.isApprovalRequired)
    $requireApproverJustification = If($requireApprovalToActivate){[bool]($Approval_EndUser_AssignmentRule.setting.approvalStages.isApproverJustificationRequired -join(';'))}else{'N/A'}
    $requireRequestorJustification = [bool]($Approval_EndUser_AssignmentRule.setting.isRequestorJustificationRequired)

    #AuthenticationContext_EndUser_Assignment Rule - Not currently used

    #Notification_Admin_EndUser_Assignment Rule
    $Notification_Admin_EndUser_AssignmentRule = $rules | where{$_.id -eq 'Notification_Admin_EndUser_Assignment'}
    $ActivateNotificationsRoleAssignmentDefaultRecipientsEnabled = $Notification_Admin_EndUser_AssignmentRule.isDefaultRecipientsEnabled
    $ActivateNotificationsRoleAssignmentNotificationLevel = $Notification_Admin_EndUser_AssignmentRule.notificationLevel
    $ActivateNotificationsRoleAssignmentNotificationType = $Notification_Admin_EndUser_AssignmentRule.notificationType
    $ActivateNotificationsRoleAssignmentAdditionalRecipients = $Notification_Admin_EndUser_AssignmentRule.notificationRecipients
    $ActivateNotificationsRoleAssignmentTargetOperations = $Notification_Admin_EndUser_AssignmentRule.target.operations -join(';')

    #Notification_Requestor_EndUser_Assignment Rule
    $Notification_Requestor_EndUser_AssignmentRule = $rules | where{$_.id -eq 'Notification_Requestor_EndUser_Assignment'}
    $ActivateNotificationsAssigneeDefaultRecipientsEnabled = $Notification_Requestor_EndUser_AssignmentRule.isDefaultRecipientsEnabled
    $ActivateNotificationsAssigneeNotificationLevel = $Notification_Requestor_EndUser_AssignmentRule.notificationLevel
    $ActivateNotificationsAssigneeNotificationType = $Notification_Requestor_EndUser_AssignmentRule.notificationType
    $ActivateNotificationsAssigneeAdditionalRecipients = $Notification_Requestor_EndUser_AssignmentRule.notificationRecipients
    $ActivateNotificationsAssigneeTargetOperations = $Notification_Requestor_EndUser_AssignmentRule.target.operations -join(';')

    #Notification_Approver_EndUser_Assignment Rule
    $Notification_Approver_EndUser_AssignmentRule = $rules | where{$_.id -eq 'Notification_Approver_EndUser_Assignment'}
    $ActivateNotificationsRenewalDefaultRecipientsEnabled = $Notification_Approver_EndUser_AssignmentRule.isDefaultRecipientsEnabled
    $ActivateNotificationsRenewalNotificationLevel = $Notification_Approver_EndUser_AssignmentRule.notificationLevel
    $ActivateNotificationsRenewalNotificationType = $Notification_Approver_EndUser_AssignmentRule.notificationType
    $ActivateNotificationsRenewalAdditionalRecipients = $Notification_Approver_EndUser_AssignmentRule.notificationRecipients
    $ActivateNotificationsRenewalTargetOperations = $Notification_Approver_EndUser_AssignmentRule.target.operations -join(';')

    $AssignedEligibleNotificationsAssignee = [pscustomobject]@{
        'Default Recipients Enabled' = $AssignedEligibleNotificationsAssigneeDefaultRecipientsEnabled
        'Notification Level' = $AssignedEligibleNotificationsAssigneeNotificationLevel
        'Notification Type' = $AssignedEligibleNotificationsAssigneeNotificationType
        'Additional Recipients' = $AssignedEligibleNotificationsAssigneeAdditionalRecipients
        'Target operations' = $AssignedEligibleNotificationsAssigneeTargetOperations
    }

    $AssignedEligibleNotificationsRenewal = [pscustomobject]@{
        'Default Recipients Enabled' = $AssignedEligibleNotificationsRenewalDefaultRecipientsEnabled
        'Notification Level' = $AssignedEligibleNotificationsRenewalNotificationLevel
        'Notification Type' = $AssignedEligibleNotificationsRenewalNotificationType
        'Additional Recipients' = $AssignedEligibleNotificationsRenewalAdditionalRecipients
        'Target operations' = $AssignedEligibleNotificationsRenewalTargetOperations
    }

    $Activation = [pscustomobject]@{
        'Activation maximum duration' = $ActivationMaximumDuration
        'Require justification on activation' = $requireRequestorJustification
        'Require approval to activate' = $requireApprovalToActivate
        'Require approver justification' = $requireApproverJustification
        'Permanent eligibility expires after' = $PermanentEligibilityExpiresAfter
        'Expire permanent assignments after' = $expirePermanentAssignmentsAfter
    }

    #Assignment Section
    $Assignment = [pscustomobject]@{
        'Allow permanent eligible assignment' = $allowPermanentEligibleAssignment
        'Allow permanent active assignment' = $allowPermanentActiveAssignment
        'Require justification on active assignment' = $requireJustificationOnActiveAssignment
    }

    $AssignedActiveNotificationsRoleAssignment = [pscustomobject]@{
        'Default Recipients Enabled' = $AssignedActiveNotificationsRoleAssignmentDefaultRecipientsEnabled
        'Notification Level' = $AssignedActiveNotificationsRoleAssignmentNotificationLevel
        'Notification Type' = $AssignedActiveNotificationsRoleAssignmentNotificationType
        'Additional Recipients' = $AssignedActiveNotificationsRoleAssignmentAdditionalRecipients
        'Target operations' = $AssignedActiveNotificationsRoleAssignmentTargetOperations
    }
    $AssignedActiveNotificationsAssignee = [pscustomobject]@{
        'Default Recipients Enabled' = $AssignedActiveNotificationsAssigneeDefaultRecipientsEnabled
        'Notification Level' = $AssignedActiveNotificationsAssigneeNotificationLevel
        'Notification Type' = $AssignedActiveNotificationsAssigneeNotificationType
        'Additional Recipients' = $AssignedActiveNotificationsAssigneeAdditionalRecipients
        'Target operations' = $AssignedActiveNotificationsAssigneeTargetOperations
    }
    $AssignedActiveNotificationsRenewal = [pscustomobject]@{
        'Default Recipients Enabled' = $AssignedActiveNotificationsRenewalDefaultRecipientsEnabled
        'Notification Level' = $AssignedActiveNotificationsRenewalNotificationLevel
        'Notification Type' = $AssignedActiveNotificationsRenewalNotificationType
        'Additional Recipients' = $AssignedActiveNotificationsRenewalAdditionalRecipients
        'Target operations' = $AssignedActiveNotificationsRenewalTargetOperations
    }
    $ActivateNotificationsRoleAssignment = [pscustomobject]@{
        'Default Recipients Enabled' = $ActivateNotificationsRoleAssignmentDefaultRecipientsEnabled
        'Notification Level' = $ActivateNotificationsRoleAssignmentNotificationLevel
        'Notification Type' = $ActivateNotificationsRoleAssignmentNotificationType
        'Additional Recipients' = $ActivateNotificationsRoleAssignmentAdditionalRecipients
        'Target operations' = $ActivateNotificationsRoleAssignmentTargetOperations
    }
    $ActivateNotificationsAssignee = [pscustomobject]@{
        'Default Recipients Enabled' = $ActivateNotificationsAssigneeDefaultRecipientsEnabled
        'Notification Level' = $ActivateNotificationsAssigneeNotificationLevel
        'Notification Type' = $ActivateNotificationsAssigneeNotificationType
        'Additional Recipients' = $ActivateNotificationsAssigneeAdditionalRecipients
        'Target operations' = $ActivateNotificationsAssigneeTargetOperations
    }
    $ActivateNotificationsRenewal = [pscustomobject]@{
        'Default Recipients Enabled' = $ActivateNotificationsRenewalDefaultRecipientsEnabled
        'Notification Level' = $ActivateNotificationsRenewalNotificationLevel
        'Notification Type' = $ActivateNotificationsRenewalNotificationType
        'Additional Recipients' = $ActivateNotificationsRenewalAdditionalRecipients
        'Target operations' = $ActivateNotificationsRenewalTargetOperations
    }


    If($OnlyNotificationsWithAdditionalRecipients){
        If('' -eq $AssignedActiveNotificationsRoleAssignmentAdditionalRecipients){
            $AssignedActiveNotificationsRoleAssignment = $null    
        }
        If('' -eq $AssignedActiveNotificationsAssigneeAdditionalRecipients){
            $AssignedActiveNotificationsAssignee = $null    
        }
        If('' -eq $AssignedActiveNotificationsRenewalAdditionalRecipients){
            $AssignedActiveNotificationsRenewal = $null    
        }
        If('' -eq $ActivateNotificationsRoleAssignmentAdditionalRecipients){
            $ActivateNotificationsRoleAssignment = $null    
        }
        If('' -eq $ActivateNotificationsAssigneeAdditionalRecipients){
            $ActivateNotificationsAssignee = $null    
        }
        If('' -eq $ActivateNotificationsRenewalAdditionalRecipients){
            $ActivateNotificationsRenewal = $null    
        }
        If('' -eq $AssignedEligibleNotificationsAssigneeAdditionalRecipients){
            $AssignedEligibleNotificationsAssignee = $null    
        }
        If('' -eq $AssignedEligibleNotificationsRenewalAdditionalRecipients){
            $AssignedEligibleNotificationsRenewal = $null    
        }
        If('' -eq $AssignedEligibleNotificationsRoleAssignmentAdditionalRecipients){
            $AssignedEligibleNotificationsRoleAssignment = $null    
        }
    }

    $AssignedEligibleNotifications = [pscustomobject]@{
        'Role assignment alert' = $AssignedEligibleNotificationsRoleAssignment
        'Notification to the assigned user (assignee)' = $AssignedEligibleNotificationsAssignee
        'Request to approve a role assignment renewal/extension' = $AssignedEligibleNotificationsRenewal
    }
    $AssignedActiveNotifications = [pscustomobject]@{
        'Role assignment alert' = $AssignedActiveNotificationsRoleAssignment
        'Notification to the assigned user (assignee)' = $AssignedActiveNotificationsAssignee
        'Request to approve a role assignment renewal/extension' = $AssignedActiveNotificationsRenewal
    }
    $ActivateNotifications = [pscustomobject]@{
        'Role activation alert' = $ActivateNotificationsRoleAssignment
        'Notification to the activated user (assignee)' = $ActivateNotificationsAssignee
        'Request to approve an activation' = $ActivateNotificationsRenewal
    }
   

    [pscustomobject]@{
        Activation = $Activation
        Assignment = $Assignment
        'Send notifications when members are assigned as eligible to this role' = $AssignedEligibleNotifications
        'Send notifications when members are assigned as active to this role' = $AssignedActiveNotifications
        'Send notifications when eligible members activate this role' = $ActivateNotifications
    }
}

Function Get-AppRoleAssignmentsREST{
    param(
        [Parameter(Mandatory=$true)][string]$graphToken,
        [Parameter(Mandatory=$true, ParameterSetName = 'ServicePrincipal')][string]$servicePrincipalId,
        [Parameter(Mandatory=$true, ParameterSetName = 'User')][string]$userId,
        [Parameter(Mandatory=$true, ParameterSetName = 'Group')][string]$groupId
    )
    If($servicePrincipalId){
        $uri = "$($GraphResourceUrl)/v1.0/servicePrincipals/$servicePrincipalId/appRoleAssignments" #the ones in the "Admin Consent" section
    }ElseIf($userId){
        $uri = "$($GraphResourceUrl)/v1.0/users/$userId/appRoleAssignments" #the ones in the "Admin Consent" section
    }ElseIf($groupId){
        $uri = "$($GraphResourceUrl)/v1.0/groups/$groupId/appRoleAssignments" #the ones in the "Admin Consent" section
    }
    $adminAssignments = Invoke-DCMsGraphQuery -AccessToken $graphToken -GraphMethod Get -GraphUri $uri
    If(1 -eq $adminAssignments.count -and $adminAssignments.'@odata.context'){
        $adminAssignments = $null
    }

    #ignoring user assignments for now since it isn't the main concern
    #$uri = "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$top=999&`$filter=consentType eq 'Principal' and clientId eq '$servicePrincipalId'" #the ones in the "User Consent" section
    #$userAssignments = Invoke-DCMsGraphQuery -AccessToken $graphToken -GraphMethod Get -GraphUri $uri

    #now make it pretty by getting the app role display name and description
    $apps = @()
    ForEach($resourceId in ($adminAssignments.resourceId | select -unique)){
        $apps += Get-EnterpriseApplicationRoleDefinitionsREST -graphToken $graphToken -EnterpriseApplicationObjectId $resourceId #admin grants
    }
    #make pretty output
    $adminAssignmentsPretty = ForEach($assignment in $adminAssignments){
        $app = $apps | where{$_.id -eq $assignment.resourceId}
        #$assignment | Add-Member -MemberType NoteProperty -Name 'appRoleDisplayName' -Value $appRole.appDisplayName
        #$assignment | Add-Member -MemberType NoteProperty -Name 'appRoleDescription' -Value $appRole.appRoles.description
       
        $role = ($apps.appRoles | where{$_.id -eq $assignment.appRoleId})
       
        [pscustomobject]@{
            ApplicationDisplayName = $assignment.resourceDisplayName
            ClaimValue = $role.value
            Permission = $role.displayName
            Type = $role.allowedMemberTypes -join(';')
            GrantedThrough = 'Admin Consent'
        }
    }

    #$userAssignmentsPretty = $userAssignments.value.scope -join(';')

    #we don't really care about user assignments right now so I'm going to ignore them for now
    #[pscustomobject]@{
    #    AdminConsent = $adminAssignmentsPretty
    #    UserConsent = $userAssignmentsPretty
    #}
    $adminAssignmentsPretty
}

Function Get-EnterpriseApplicationRoleDefinitionsREST{
    param(
        [string]$graphToken,
        [string]$EnterpriseApplicationObjectId
    )
    $uri = "$GraphResourceUrl/v1.0/servicePrincipals/$($EnterpriseApplicationObjectId)?`$select=id,appDisplayName,displayName,appRoles,oauth2PermissionScopes,resourceSpecificApplicationPermissions,alternativeNames,accountEnabled,appId,appOwnerOrganizationId,servicePrincipalNames,servicePrincipalType,signInAudience"
    $appRoleDefinitions = Invoke-DCMsGraphQuery -AccessToken $graphToken -GraphMethod Get -GraphUri $uri
    $appRoleDefinitions
}

Function Get-VMsWithHeartbeat{
    <#
        .SYNOPSIS
        Get VMs with heartbeat which is created by the AMA agent
        .DESCRIPTION
        This function gets the VMs with heartbeats. It looks back timeRange and checks if the VM has a heartbeat within the unhealthCriteria period, if so, it is considered health with a heartbeat.
        .PARAMETER timeRange
        The time range to query in the format of "ago(1h)". Default is "ago(1h)"
        .PARAMETER unhealthCriteria
        The criteria to determine if a VM is unhealthy. Default is "30m" without a heartbeat.
        .PARAMETER LogAnalyticsToken
        The Log Analytics token to use. Default is to acquire a token.
        .PARAMETER resourceGraphToken
        The Resource Graph token to use. Default is to acquire a token.
        .PARAMETER workspaceId
        The Log Analytics workspace ID to use. Default is to use the environment variable $env:TenantMonitoringLogAnalyticsWorkspaceID
    #>
    param(
    [Parameter(Mandatory=$false)]
        [string]$timeRange = 'ago(1h)',
    [Parameter(Mandatory=$false)]
        [string]$unhealthCriteria = '30m',
    [Parameter(Mandatory=$false)]
        [string]$LogAnalyticsToken = $(Connect-AcquireToken -TokenResourceUrl $LogAnalyticsUrl),
    [Parameter(Mandatory=$false)]
        [string]$resourceGraphToken = $(Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl),
    [Parameter(Mandatory=$false)]
        [string]$workspaceId = $env:TenantMonitoringLogAnalyticsWorkspaceID
    )

    $VmWithHeartbeatQuery = @"
let HaveHeartbeat = Heartbeat
| where TimeGenerated > $timeRange
| summarize LastHeartbeat = max(TimeGenerated) by Computer
| extend State = iff(LastHeartbeat < ago($unhealthCriteria), 'Unhealthy', 'Healthy')
| extend TimeFromNow = now() - LastHeartbeat
| extend ["TimeAgo"] = strcat(case(TimeFromNow < 2m, strcat(toint(TimeFromNow / 1m), ' seconds'), TimeFromNow < 2h, strcat(toint(TimeFromNow / 1m), ' minutes'), TimeFromNow < 2d, strcat(toint(TimeFromNow / 1h), ' hours'), strcat(toint(TimeFromNow / 1d), ' days')), ' ago')
| join (
Heartbeat
| where TimeGenerated > $timeRange
//| extend Packed = pack_all()
) on Computer
| where TimeGenerated == LastHeartbeat
| join (
Heartbeat
| where TimeGenerated > $timeRange
| make-series InternalTrend=iff(count() > 0, 1, 0) default = 0 on TimeGenerated from $timeRange to ago(0m) step $unhealthCriteria by Computer
| extend Trend=array_slice(InternalTrend, array_length(InternalTrend) - 30, array_length(InternalTrend)-1)
| extend (s_min, s_minId, s_max, s_maxId, s_avg, s_var, s_stdev) = series_stats(Trend)
| project Computer, Trend, s_avg
) on Computer
| order by State, s_avg asc, TimeAgo;
//| project ["_ComputerName_"] = Computer, ["Computer"]=strcat('🖥️ ', Computer), State, ["Environment"] = iff(ComputerEnvironment == "Azure", ComputerEnvironment, Category), ["OS"]=iff(isempty(OSName), OSType, OSName), ["Azure Resource"]=ResourceId, Version, ["Time"]=strcat('🕒 ', TimeAgo), ["Heartbeat Trend"]=Trend, ["Details"]=Packed;
HaveHeartbeat //resourceId is available to compare
"@

    $uri = "$LogAnalyticsUrl/v1/workspaces/$workspaceId/query"
    $body = @{
        query = $VmWithHeartbeatQuery
    } | ConvertTo-Json -Depth 99 -Compress
    #Write-Warning "URI = $uri"
    $result = Invoke-DCMsGraphQuery -GraphMethod Post -GraphUri $uri -AccessToken $LogAnalyticsToken -GraphBody $body
    $headers = $result.tables.columns.name
    $VMsWithHeartbeat = ForEach ($row in $result.tables.rows) {
        $myValues = @{}
        $count = 0
        ForEach ($name in $headers) {
            $myValues.Add($name, $row[$count])
            $count += 1
        }
        [pscustomobject]$myValues
    }
    $VMsWithHeartbeat
}

Function Get-PoweredOnVMsWithoutHeartbeat{
    <#
        .SYNOPSIS
        Get VMs without heartbeat. It only looks at powered on VMs.
        .DESCRIPTION
        This function gets the VMs without heartbeats. It looks back timeRange and checks if the VM has a heartbeat within the unhealthCriteria period, if not, it is considered unhealthy without a heartbeat.
        .PARAMETER timeRange
        The time range to query in the format of "ago(1h)". Default is "ago(1h)"
        .PARAMETER unhealthCriteria
        The criteria to determine if a VM is unhealthy. Default is "30m" without a heartbeat.
        .PARAMETER LogAnalyticsToken
        The Log Analytics token to use. Default is to acquire a token.
        .PARAMETER resourceGraphToken
        The Resource Graph token to use. Default is to acquire a token.
        .PARAMETER workspaceId
        The Log Analytics workspace ID to use. Default is to use the environment variable $env:TenantMonitoringLogAnalyticsWorkspaceID
    #>
    param(
    [Parameter(Mandatory=$false)]
        [string]$timeRange = 'ago(1h)',
    [Parameter(Mandatory=$false)]
        [string]$unhealthCriteria = '30m',
    [Parameter(Mandatory=$false)]
        [string]$LogAnalyticsToken = $(Connect-AcquireToken -TokenResourceUrl $LogAnalyticsUrl),
    [Parameter(Mandatory=$false)]
        [string]$resourceGraphToken = $(Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl),
    [Parameter(Mandatory=$false)]
        [string]$workspaceId = $env:TenantMonitoringLogAnalyticsWorkspaceID
    )

    $VMsWithHeartbeat = Get-VMsWithHeartbeat -timeRange $timeRange -unhealthCriteria $unhealthCriteria -LogAnalyticsToken $LogAnalyticsToken -resourceGraphToken $resourceGraphToken -workspaceId $workspaceId


$allVMsQuery = @'
resources
| where type == "microsoft.compute/virtualmachines"
//| extend propertiesParsed = parse_json(properties)
| extend PowerCode = tostring(parse_json(properties).extended.instanceView.powerState.code)
| extend PowerStatus = tostring(parse_json(properties).extended.instanceView.powerState.displayStatus)
'@
    $uri = "https://$managementApiBase/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01"
    $body = @{
        query = $allVMsQuery
    } | ConvertTo-Json -Depth 99
    $allVMsResult = Invoke-DCMsGraphQuery -AccessToken $resourceGraphToken -GraphMethod Post -GraphUri $uri -GraphBody $body

    $VMsWithoutHeartbeat = $allVMsResult <#.data#> | where{$_.id -notin $VMsWithHeartbeat.ResourceId}
}

Function Get-PolicyComplianceAtManagementGroupScopeREST{
    <#
        .SYNOPSIS
        Get policy compliance at the management group scope
        .DESCRIPTION
        This function gets the policy compliance at the management group scope
        .PARAMETER managementGroupId
        The management group ID to query. Default is the environment variable $env:PolicyManagementGroupId
        .PARAMETER policyDefinitionId
        The policy definition ID to query. Default is all policy definitions
        .PARAMETER resourceManagerToken
        The Resource Manager token to use. Default is to acquire a token.
        .EXAMPLE
        Get-PolicyComplianceAtManagementGroupScopeREST -managementGroupId "00000000-0000-0000-0000-000000000000" -policyDefinitionId "/providers/Microsoft.Authorization/policyDefinitions/00000000-0000-0000-0000-000000000000" -resourceManagerToken $((Get-AzAccessToken -ResourceTypeName ResourceManager).token)
    #>
    param(
        [Parameter(Mandatory=$false)][string]$managementGroupId = $env:PolicyManagementGroupId,
        [Parameter(Mandatory=$true)][string]$policyDefinitionId,
        [Parameter(Mandatory=$true)][string]$resourceManagerToken
        )
    $uri = "$TokenResourceUrl/providers/Microsoft.Management/managementGroups/$managementGroupId/providers/Microsoft.PolicyInsights/policyStates/latest/queryResults?api-version=2019-10-01"
    If($policyDefinitionId){
        $uri += "&`$filter=policyDefinitionId eq '$policyDefinitionId'"
    }
    $result = Invoke-DCMsGraphQuery -AccessToken $resourceManagerToken -GraphMethod Post -GraphUri $uri
   
    If(0 -eq $result.'@odata.count'){
        $result = $null
    }
    $result
}

Function Invoke-ResourceGraphQueryREST{
    <#
        .SYNOPSIS
        Invoke a Resource Graph query
        .DESCRIPTION
        This function invokes a Resource Graph query
        .PARAMETER query
        The Resource Graph query to run
        .PARAMETER resourceGraphToken
        The Resource Graph token to use. Default is to acquire a token.
        .EXAMPLE
        Invoke-ResourceGraphQueryREST -query "resources | where type == 'microsoft.compute/virtualmachines' | project name, location" -resourceGraphToken $((Get-AzAccessToken -ResourceTypeName ResourceManager).token)
    #>
    param(
        [Parameter(Mandatory=$true)][string]$query,
        [Parameter(Mandatory=$false)][string]$resourceGraphToken
        )
    If(!$resourceGraphToken){
        $resourceGraphToken = Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl
    }
    $uri = "https://$managementApiBase/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01"
    $body = @{
        query = $query
    } | ConvertTo-Json -Depth 99
    $result = Invoke-DCMsGraphQuery -AccessToken $resourceGraphToken -GraphMethod Post -GraphUri $uri -GraphBody $body
    $result #.data
}

Function Get-AllAzureFirewallsRest{
    <#
        .SYNOPSIS
        Get all Azure Firewalls
        .DESCRIPTION
        This function gets all Azure Firewalls
        .PARAMETER resourceGraphToken
        The Resource Graph token to use. Default is to acquire a token.
        .EXAMPLE
        Get-AllAzureFirewallsRest -resourceGraphToken $((Get-AzAccessToken -ResourceTypeName ResourceManager).token)
    #>
    param(
        [Parameter(Mandatory=$true)][string]$resourceGraphToken
        )
    $query = "resources | where type == 'microsoft.network/azurefirewalls'"
    $result = Invoke-ResourceGraphQueryREST -query $query -resourceGraphToken $resourceGraphToken
    $result
}

function Get-LogAnalyticsWorkspacesRest {
    <#
        .DESCRIPTION
            Get a list of Log Analytics workspaces using the REST API.
        .PARAMETER SubscriptionId
            The subscription ID for the Sentinel workspace.
        .EXAMPLE
            Get-LogAnalyticsWorkspacesRest -SubscriptionId $SubscriptionId
    #>
    param(
        [parameter(Mandatory = $false)]
        [string]$SubscriptionId = (Get-AzContext).Subscription.Id
    )
    begin {
        $managementUri = $TokenResourceUrl
    }
    process {
        $uri = "$TokenResourceUrl/subscriptions/$($SubscriptionId)/providers/Microsoft.OperationalInsights/workspaces?api-version=2023-09-01"
        $token = Connect-AcquireToken -TokenResourceUrl $managementUri
        $result = Invoke-DCMsGraphQuery -AccessToken $token -GraphMethod 'GET' -GraphUri $uri
        $result
    }
    end {}
}

Function Get-LogAnalyticsWorspaceWorkbooksREST{
    <#
        .SYNOPSIS
        Get all workbooks in a Log Analytics workspace
        .DESCRIPTION
        This function gets all workbooks in a Log Analytics workspace
        .PARAMETER workspaceId
        The workspace ID to query. Default is the environment variable $env:TenantMonitoringLogAnalyticsWorkspaceID
        .PARAMETER LogAnalyticsToken
        The Log Analytics token to use. Default is to acquire a token.
        .EXAMPLE
        Get-LogAnalyticsWorspaceWorkbooksREST -workspaceId "00000000-0000-0000-0000-000000000000" -LogAnalyticsToken $((Get-AzAccessToken -ResourceTypeName LogAnalytics).token)
    #>
    param(
        [Parameter(Mandatory=$false)][string]$workspaceId = $env:TenantMonitoringLogAnalyticsWorkspaceID,
        [Parameter(Mandatory=$true)][string]$SubscriptionId,
        [Parameter(Mandatory=$true)][string]$ResourceGroupName,
        [Parameter(Mandatory=$false)][switch]$FetchContent = $false,
        [Parameter(Mandatory=$false)][switch]$IsSentinel = $false
    )  
    begin{
        $apiVersion = '2018-06-17-preview'
    }
    process{
        $managementToken = Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl
        $uri = $tokenResourceUrl + '/subscriptions/' + $($SubscriptionId) + '/resourceGroups/' + $($ResourceGroupName) + '/providers/Microsoft.Insights/workbooks?api-version='+ $apiversion + '&canFetchContent=' + $(If($FetchContent){'true'}else{'false'}) + '&filter=sourceId eq ' + "'" + $($WorkspaceId) + "'"
        If($IsSentinel){
            $uri += '&category=sentinel'
        }  
        #    $uri = $tokenResourceUrl + $($targetLAW.id.split('/')[0..5] -join '/') + '/Microsoft.Insights/workbooks?api-version=2018-06-17-preview&canFetchContent=true&filter=sourceId eq ' + "'" + $($targetLAW.id) + "'"+ '&category=sentinel'
        $workbooks = Invoke-DCMsGraphQuery -AccessToken $managementToken -GraphMethod 'GET' -GraphUri $uri
        $workbooks
    }
}

function New-AzSentinelAlertRuleRest {
    <#
        .DESCRIPTION
            Create a new Azure Sentinel Alert Rule using the REST API.
        .PARAMETER jsonObject
            The JSON object output from a list of Sentinel Alert rules.
        .PARAMETER SubscriptionId
            The subscription ID for the Sentinel workspace.
        .PARAMETER ResourceGroupName
            The resource group name for the Sentinel workspace.
        .PARAMETER WorkspaceName
            The workspace name for the Log Analytics workspace.
        .EXAMPLE
            New-AzSentinelAlertRuleRest -jsonObject $jsonObject -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName
    #>
    param(
        [parameter(Mandatory = $true)]
        $jsonObject,
        [parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        [parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [parameter(Mandatory = $true)]
        [string]$WorkspaceName
    )
    begin {
        $managementUri = $TokenResourceUrl
    }
    process {

        $body = switch ($jsonObject.kind) {
            'Scheduled' {
                $temp = @{properties = @{} }
                $temp.kind = 'Scheduled'
                $temp.properties.displayName = $jsonObject.properties.displayName
                $temp.properties.query = $jsonObject.properties.query
                $temp.properties.queryPeriod = $jsonObject.properties.queryPeriod
                $temp.properties.queryFrequency = $jsonObject.properties.queryFrequency
                $temp.properties.triggerThreshold = $jsonObject.properties.triggerThreshold
                $temp.properties.severity = $jsonObject.properties.severity
                $temp.properties.suppressionDuration = $jsonObject.properties.suppressionDuration
                $temp.properties.triggerOperator = $jsonObject.properties.triggerOperator
                $temp.properties.enabled = [bool]$jsonObject.properties.enabled
                $temp.properties.suppressionEnabled = [bool]$jsonObject.properties.suppressionEnabled
                If ($jsonObject.etag) { $temp.etag = $jsonObject.etag }
                If ($jsonObject.properties.alertDetailsOverride) { $temp.properties.alertDetailsOverride = $jsonObject.properties.alertDetailsOverride }
                If ($jsonObject.properties.alertRuleTemplateName) { $temp.properties.alertRuleTemplateName = $jsonObject.properties.alertRuleTemplateName }
                If ($jsonObject.properties.customDetails) { $temp.properties.customDetails = $jsonObject.properties.customDetails }
                If ($jsonObject.properties.description) { $temp.properties.description = $jsonObject.properties.description }
                If ($jsonObject.properties.entityMappings) { $temp.properties.entityMappings = $jsonObject.properties.entityMappings }
                If ($jsonObject.properties.eventGroupSettings) { $temp.properties.eventGroupSettings = $jsonObject.properties.eventGroupSettings }
                If ($jsonObject.properties.incidentConfiguration) { $temp.properties.incidentConfiguration = $jsonObject.properties.incidentConfiguration }
                If ($jsonObject.properties.Tactics) { $temp.properties.Tactics = $jsonObject.properties.Tactics }
                If ($jsonObject.properties.techniques) { $temp.properties.techniques = $jsonObject.properties.techniques }
                If ($jsonObject.properties.templateVersion) { $temp.properties.templateVersion = $jsonObject.properties.templateVersion }
                $temp
            }
            'Fusion' {
                $temp = @{properties = @{} }
                $temp.kind = 'Fusion'
                $temp.properties.alertRuleTemplateName = $jsonObject.properties.alertRuleTemplateName
                $temp.properties.enabled = [bool]$jsonObject.properties.enabled
                If ($jsonObject.etag) { $temp.etag = $jsonObject.etag }
                $temp
            }
            'MicrosoftSecurityIncidentCreation' {
                $temp = @{properties = @{} }
                $temp.kind = 'MicrosoftSecurityIncidentCreation'
                $temp.properties.displayName = $jsonObject.properties.displayName
                $temp.properties.enabled = [bool]$jsonObject.properties.enabled
                $temp.properties.productFilter = $jsonObject.properties.productFilter
                If ($jsonObject.etag) { $temp.etag = $jsonObject.etag }
                If ($jsonObject.properties.description) { $temp.properties.description = $jsonObject.properties.description }
                If ($jsonObject.properties.displayNamesExcludeFilter) { $temp.properties.displayNamesExcludeFilter = $jsonObject.properties.displayNamesExcludeFilter }
                If ($jsonObject.properties.displayNamesFilter) { $temp.properties.displayNamesFilter = $jsonObject.properties.displayNamesFilter }
                If ($jsonObject.properties.severitiesFilter) { $temp.properties.severitiesFilter = $jsonObject.properties.severitiesFilter }
                $temp
            }
        }
        $uri = "$managementUri/subscriptions/$($SubscriptionId)/resourceGroups/$($ResourceGroupName)/providers/Microsoft.OperationalInsights/workspaces/$($WorkspaceName)/providers/Microsoft.SecurityInsights/alertRules/$([guid]::NewGuid().tostring())?api-version=2024-01-01-preview"#?api-version=2024-03-01"
        Write-Verbose "Creating $($body.kind) rule $($body.properties.displayName)"
        $body = $body | ConvertTo-Json -Depth 99 -Compress
        #Write-Verbose "body = $body `n`n"
        $token = (Get-AzAccessToken -ResourceUrl $managementUri).Token
        #$result = Invoke-RestMethod -Uri $uri -Method Put -Headers @{ Authorization = "Bearer $token" } -Body $body -ContentType "application/json" -UseBasicParsing -ErrorVariable myError

        $result = Invoke-DCMsGraphQuery -AccessToken $token -GraphMethod 'PUT' -GraphUri $uri -GraphBody $body
    }
    end {}
}

function Get-AzSentinelAlertRulesRest {
    param(
        [parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        [parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [parameter(Mandatory = $true)]
        [string]$WorkspaceName
    )
    begin {
        $managementUri = $TokenResourceUrl
    }
    process {
        $uri = "$managementUri/subscriptions/$($SubscriptionId)/resourceGroups/$($ResourceGroupName)/providers/Microsoft.OperationalInsights/workspaces/$($WorkspaceName)/providers/Microsoft.SecurityInsights/alertRules?api-version=2024-03-01"
        $token = (Get-AzAccessToken -ResourceUrl $managementUri).Token
        $result = Invoke-DCMsGraphQuery -AccessToken $token -GraphMethod 'GET' -GraphUri $uri
        $result
    }
    end {}
}

Function Remove-AzSentinelAlertRuleRest {
    <#
        .DESCRIPTION
            Remove an Azure Sentinel Alert Rule using the REST API.
        .PARAMETER RuleId
            The ID of the rule to remove.
        .PARAMETER SubscriptionId
            The subscription ID for the Sentinel workspace.
        .PARAMETER ResourceGroupName
            The resource group name for the Sentinel workspace.
        .PARAMETER WorkspaceName
            The workspace name for the Log Analytics workspace.
        .EXAMPLE
            Remove-AzSentinelAlertRuleRest -RuleId $RuleId -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName
    #>
    param(
        [parameter(Mandatory = $true)]
        [string]$Id
    )
    begin {
        $managementUri = $TokenResourceUrl
    }
    process {
        $uri = $managementUri + $Id + "?api-version=2024-03-01"
        $token = (Get-AzAccessToken -ResourceUrl $managementUri).Token
        $result = Invoke-DCMsGraphQuery -AccessToken $token -GraphMethod 'DELETE' -GraphUri $uri
    }
    end {}
}

Function Get-ResourcesREST {
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        [parameter(Mandatory = $false)]
        [string]$ResourceGroupName
    )

    $resourceManagerToken = Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl
    #$resourceManagerToken = (Get-AzAccessToken -ResourceUrl $TokenResourceUrl).token
    If ($ResourceGroupName) {
        $uri = "$TokenResourceUrl/subscriptions/$SubscriptionId/resourceGroups/$($ResourceGroupName)/resources?api-version=2016-09-01"
    }
    Else {
        $uri = "$TokenResourceUrl/subscriptions/$SubscriptionId/resources?api-version=2016-09-01"
    }
    $resources = Invoke-DCMsGraphQuery -AccessToken $resourceManagerToken -GraphUri $uri -GraphMethod Get
    $resources
}

Function Get-ResourceGroupREST {
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        [parameter(Mandatory = $false)]
        [string]$ResourceGroupName
    )

    $resourceManagerToken = Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl
    #$resourceManagerToken = (Get-AzAccessToken -ResourceUrl $TokenResourceUrl).token
    If ($ResourceGroupName) {
        $uri = "$TokenResourceUrl/subscriptions/$SubscriptionId/resourceGroups/$($ResourceGroupName)?api-version=2014-04"
    }
    Else {
        $uri = "$TokenResourceUrl/subscriptions/$SubscriptionId/resourceGroups?api-version=2014-04"
    }
    #    $uri = "$TokenResourceUrl/subscriptions/$SubscriptionId/resourceGroups/$($ResourceGroupName)?api-version=2014-04"
    $resourceGroup = Invoke-DCMsGraphQuery -AccessToken $resourceManagerToken -GraphUri $uri -GraphMethod Get
    $resourceGroup
}

Function Get-SubscriptionsREST {
    [CmdletBinding()]
    param ()

    $resourceManagerToken = Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl
    #$resourceManagerToken = (Get-AzAccessToken -ResourceUrl $TokenResourceUrl).token
    $uri = "$TokenResourceUrl/subscriptions?api-version=2016-06-01"
    $subscriptions = Invoke-DCMsGraphQuery -AccessToken $resourceManagerToken -GraphUri $uri -GraphMethod Get
    $subscriptions
}

Function Get-ResourcesREST {
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        [parameter(Mandatory = $false)]
        [string]$ResourceGroupName
    )

    $resourceManagerToken = Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl
    #$resourceManagerToken = (Get-AzAccessToken -ResourceUrl $TokenResourceUrl).token
    If ($ResourceGroupName) {
        $uri = "$TokenResourceUrl/subscriptions/$SubscriptionId/resourceGroups/$($ResourceGroupName)/resources?api-version=2016-09-01"
    }
    Else {
        $uri = "$TokenResourceUrl/subscriptions/$SubscriptionId/resources?api-version=2016-09-01"
    }
    $resources = Invoke-DCMsGraphQuery -AccessToken $resourceManagerToken -GraphUri $uri -GraphMethod Get
    $resources
}

function Get-RoleAssignmentsREST {
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        [parameter(Mandatory = $false)]
        [string]$ResourceGroupName
    )

    $resourceManagerToken = Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl
    #$resourceManagerToken = (Get-AzAccessToken -ResourceUrl $TokenResourceUrl).token
    If ($ResourceGroupName) {
        $uri = "$TokenResourceUrl/subscriptions/$SubscriptionId/resourceGroups/$($ResourceGroupName)/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01"
    }
    Else {
        $uri = "$TokenResourceUrl/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/roleAssignments?api-version=2015-07-01"
    }
    $roleAssignments = Invoke-DCMsGraphQuery -AccessToken $resourceManagerToken -GraphUri $uri -GraphMethod Get
    $roleAssignments
}

Function Get-TemplateForResourcesREST {
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        [parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [parameter(Mandatory = $false)]
        [array]$Resources
    )

    $resourceManagerToken = Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl
    #$resourceManagerToken = (Get-AzAccessToken -ResourceUrl $TokenResourceUrl).token
    If ($Resources -eq $null) {
        $Resources = @('*')
    }
   
    $body = @{
        options   = 'IncludeParameterDefaultValue'
        resources = $Resources
    } | ConvertTo-Json
    $uri = "$TokenResourceUrl/subscriptions/$SubscriptionId/resourcegroups/$ResourceGroupName/exportTemplate?api-version=2018-08-01"
    $template = Invoke-DCMsGraphQuery -GraphUri $uri -GraphMethod Post -GraphBody $body -AccessToken $resourceManagerToken  
    $template
}

Function Get-PrivateDNSZonesREST{
    <#
        .SYNOPSIS
        Get all Private DNS Zones
        .DESCRIPTION
        This function gets all Private DNS Zones
        .EXAMPLE
        Get-PrivateDNSZonesREST
    #>
    param()
    $resourceGraphToken = Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl
    $query = "resources | where type == 'microsoft.network/privatednszones'"
    $result = Invoke-ResourceGraphQueryREST -query $query -resourceGraphToken $resourceGraphToken
    $result
}

Function Get-DNSRecordSetsREST{
    <#
        .SYNOPSIS
        Get all DNS Records
        .DESCRIPTION
        This function gets all DNS Records
        .PARAMETER zoneId
        The zone ID to query
        .EXAMPLE
        Get-DNSRecordSetsREST -zoneId "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/privateDnsZones/zone"
    #>
    param(
        [Parameter(Mandatory=$true)][string]$zoneId
        )
    $resourceGraphToken = Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl
    $uri = $TokenResourceUrl + $zoneId + '/all?api-version=2018-09-01'
    $result = Invoke-DCMsGraphQuery -AccessToken $resourceGraphToken -GraphMethod Get -GraphUri $uri
    $result
}

Function Get-DNSZoneVNetLinksREST{
    <#
        .SYNOPSIS
        Get all DNS Records
        .DESCRIPTION
        This function gets all DNS Records
        .PARAMETER zoneId
        The zone ID to query
        .EXAMPLE
        Get-DNSZoneVNetLinksREST -zoneId "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/privateDnsZones/zone"
    #>
    param(
        [Parameter(Mandatory=$true)][string]$zoneId
        )
    $resourceGraphToken = Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl
    $uri = $TokenResourceUrl + $zoneId + '/virtualNetworkLinks?api-version=2018-09-01'
    $result = Invoke-DCMsGraphQuery -AccessToken $resourceGraphToken -GraphMethod Get -GraphUri $uri
    $result
}

Function Get-AzurePolicyAssignmentAtManagementGroupScopeRest{
    param(
        [string]$ManagementGroupId = $env:PolicyManagementGroupId,
        [string]$ManagementToken = $(Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl)
    )
    $uri = "$TokenResourceUrl/providers/Microsoft.Management/managementGroups/$ManagementGroupId/providers/Microsoft.Authorization/policyAssignments?`$filter=atExactScope()&api-version=2022-06-01" #2023-04-01 is too new for some clouds
    $result = Invoke-DCMsGraphQuery -GraphMethod 'Get' -GraphUri $uri -AccessToken $ManagementToken
    $result
}

Function Get-AzurePolicyAssignmentAtSubscriptionScopeRest{
    #have a separate parameter sets to sepecify either a single subscription ID or all subscriptions
    param(
        [Parameter(Mandatory = $true,ParameterSetName = 'SingleSubscription')]
        [string]$SubscriptionId,
        [Parameter(Mandatory = $false,ParameterSetName = 'AllSubscriptions')]
        [switch]$AllSubscriptions,
        [Parameter(Mandatory = $false,ParameterSetName = 'SingleSubscription')]
        [Parameter(Mandatory = $false,ParameterSetName = 'AllSubscriptions')]
        [string]$ManagementToken = $(Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl)
    )
    If($PSCmdlet.ParameterSetName -eq 'SingleSubscription'){
        $uri = "$TokenResourceUrl/subscriptions/$($SubscriptionId)/providers/Microsoft.Authorization/policyAssignments?api-version=2022-06-01" #2023-04-01 is too new for some clouds
        $result = Invoke-DCMsGraphQuery -GraphMethod 'Get' -GraphUri $uri -AccessToken $ManagementToken
        $result
    }ElseIf($PSCmdlet.ParameterSetName -eq 'AllSubscriptions'){
        ForEach($subscription in GetSubscriptionsToReportOn){
            Write-Verbose "Getting policy assignments for subscription $($subscription.SubscriptionId)"
            $uri = "$TokenResourceUrl/subscriptions/$($subscription.SubscriptionId)/providers/Microsoft.Authorization/policyAssignments?api-version=2022-06-01" #2023-04-01 is too new for some clouds
            $result = Invoke-DCMsGraphQuery -GraphMethod 'Get' -GraphUri $uri -AccessToken $ManagementToken
            $result
        }
    }
}

Function Get-AzurePolicyAssignmentDetailsRest{
    param(
        [Parameter(Mandatory = $true)]
        [string]$PolicyAssignmentId,
        [string]$ManagementToken = $(Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl)
    )
    $uri = "$($TokenResourceUrl)$($PolicyAssignmentId)?api-version=2021-06-01"#2023-04-01 is too new for some clouds
    $result = Invoke-DCMsGraphQuery -GraphMethod 'Get' -GraphUri $uri -AccessToken $ManagementToken
    $result
}

Function Get-AzurePolicyInitiativeDefinitionRest{
    param(
        [Parameter(Mandatory = $true)]
        [string]$InitiativeDefinitionId,
        [string]$ManagementToken = $(Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl)
    )
    $uri = "$($TokenResourceUrl)$($InitiativeDefinitionId)?api-version=2021-06-01"#2023-04-01 is too new for some clouds
    $result = Invoke-DCMsGraphQuery -GraphMethod 'Get' -GraphUri $uri -AccessToken $ManagementToken
    $result
}

Function Get-AzurePolicyExemptionsAtSubscriptionScopeRest{
    param(
        [Parameter(Mandatory = $true,ParameterSetName = 'SingleSubscription')]
        [string]$SubscriptionId,
        [Parameter(Mandatory = $false,ParameterSetName = 'AllSubscriptions')]
        [switch]$AllSubscriptions,
        [Parameter(Mandatory = $false,ParameterSetName = 'SingleSubscription')]
        [Parameter(Mandatory = $false,ParameterSetName = 'AllSubscriptions')]
        [string]$ManagementToken = $(Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl)
    )
    If($PSCmdlet.ParameterSetName -eq 'SingleSubscription'){
        $uri = "$TokenResourceUrl/subscriptions/$($SubscriptionId)/providers/Microsoft.Authorization/policyExemptions?api-version=2022-07-01-preview" #2023-04-01 is too new for some clouds
        $result = Invoke-DCMsGraphQuery -GraphMethod 'Get' -GraphUri $uri -AccessToken $ManagementToken
        $result
    }ElseIf($PSCmdlet.ParameterSetName -eq 'AllSubscriptions'){
        ForEach($subscription in GetSubscriptionsToReportOn){
            Write-Verbose "Getting policy exemptions for subscription $($subscription.SubscriptionId)"
            $uri = "$TokenResourceUrl/subscriptions/$($subscription.SubscriptionId)/providers/Microsoft.Authorization/policyExemptions?api-version=2022-07-01-preview" #2023-04-01 is too new for some clouds
            $result = Invoke-DCMsGraphQuery -GraphMethod 'Get' -GraphUri $uri -AccessToken $ManagementToken
            $result
        }
        $result
    }
}

Function Get-AzurePolicyExemptionsAtManagementGroupScopeRest{
    param(
        [string]$ManagementGroupId = $env:PolicyManagementGroupId,
        [string]$ManagementToken = $(Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl)
    )
    $uri = "$TokenResourceUrl/providers/Microsoft.Management/managementGroups/$ManagementGroupId/providers/Microsoft.Authorization/policyExemptions?`$filter=atScope()&api-version=2022-07-01-preview" #2023-04-01 is too new for some clouds
    $result = Invoke-DCMsGraphQuery -GraphMethod 'Get' -GraphUri $uri -AccessToken $ManagementToken
    $result
}

Function Get-AllManagementGroupsRest{
    param(
        [string]$ManagementToken = $(Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl)
    )
    $uri = "$TokenResourceUrl/providers/Microsoft.Management/managementGroups?api-version=2021-04-01"
    $result = Invoke-DCMsGraphQuery -GraphMethod 'Get' -GraphUri $uri -AccessToken $ManagementToken
    $result
}

Function Get-SubscriptionsAndParentManagementGroupRest{
    param(
        [string]$ManagementToken = $(Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl)
    )
    $query = @'
ResourceContainers
| where type =~ 'microsoft.management/managementGroups'
| project ResourceId = name, DisplayName = tostring(properties.displayName), ParentDisplayName = tostring(properties.details.parent.displayName), HierarchyLevel = array_length(properties.details.managementGroupAncestorsChain), ParentId = tostring(properties.details.parent.name), type, tenantId
| extend hasDirectAccess = 1
| join kind=fullouter (
    resourcecontainers| where type == 'microsoft.management/managementgroups'
    | project tenantId, type, original = properties.details.managementGroupAncestorsChain, mgChain = properties.details.managementGroupAncestorsChain
    | mv-expand with_itemindex= MGIndex mgChain
    | project ResourceId = tostring(mgChain.name), DisplayName = tostring(mgChain.displayName), tenantId, HierarchyLevel = array_length(original) - MGIndex - 1, ParentId = tostring(original[MGIndex + 1].name), ParentDisplayName = tostring(original[MGIndex + 1].displayName)
    | summarize DisplayName = any(DisplayName), tenantId = any(tenantId), HierarchyLevel = any(HierarchyLevel), ParentId = any(ParentId), ParentDisplayName = any(ParentDisplayName) by ResourceId
) on ResourceId
| project ResourceId = iff(isempty(ResourceId), ResourceId1, ResourceId), DisplayName = iff(isempty(DisplayName), DisplayName1, DisplayName),ParentDisplayName = iff(isempty(ParentDisplayName), ParentDisplayName1, ParentDisplayName),HierarchyLevel = iff(isempty(HierarchyLevel), HierarchyLevel1, HierarchyLevel), ParentId = iff(isempty(ParentId), ParentId1, ParentId),hasDirectAccess = iff(isnull(hasDirectAccess), int(null), 1),type, tenantId
| join kind=fullouter (
    Resourcecontainers
    | where type == 'microsoft.resources/subscriptions'
    | extend selfAsMg = pack_array(pack('displayName', name, 'name', subscriptionId))
    | project id, type, tenantId, mgChain = array_concat(selfAsMg, properties.managementGroupAncestorsChain), SSPTag = tostring(tags.SSP)
    | extend original = mgChain
    | mv-expand with_itemindex=MGIndex mgChain
    | extend IsImmediateChild = (MGIndex == 1)
    | extend HierarchyLevel = array_length(original) - MGIndex - 1, ResourceId = tostring(mgChain.name), DisplayName = tostring(mgChain.displayName), ParentId = tostring(original[MGIndex + 1].name), ParentDisplayName = tostring(original[MGIndex + 1].displayName)
    | summarize totalSubCount = countif(MGIndex > 0), immediateChildSubCount = countif(IsImmediateChild), HierarchyLevel = any(HierarchyLevel), ParentId = any(ParentId), type = anyif(type, MGIndex == 0), DisplayName = any(DisplayName), ParentDisplayName = any(ParentDisplayName), hasDirectAccess = anyif(1, MGIndex == 0), tenantId = any(tenantId), SSPTag = anyif(SSPTag, MGIndex == 0) by ResourceId
) on ResourceId
| project ResourceId = iff(isempty(ResourceId), ResourceId1, ResourceId), DisplayName = iff(isempty(DisplayName), DisplayName1, DisplayName), HierarchyLevel = iff(isnull(HierarchyLevel), HierarchyLevel1, HierarchyLevel), ParentId = iff(isempty(ParentId), ParentId1, ParentId), ParentDisplayName = iff(isempty(ParentDisplayName), ParentDisplayName1, ParentDisplayName), totalSubCount = iff(isnull(totalSubCount), 0, totalSubCount), immediateChildSubCount = iff(isnull(immediateChildSubCount), 0, immediateChildSubCount), type = iff(isempty(type), iff(isempty(type1), 'microsoft.management/managementGroups', type1), type), hasDirectAccess = iff(isnull(hasDirectAccess) and isnull(hasDirectAccess1) , 'false', 'true'), tenantId = iff(isempty(tenantId), tenantId1, tenantId), SSPTag = iff(isempty(SSPTag), "UNDEFINED", SSPTag)
| where type == "microsoft.resources/subscriptions"
| project Subscription = ResourceId, DisplayName, ManagementGroup = ParentDisplayName, SSPTag
'@
    $uri = "$TokenResourceUrl/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01"
    $result = Invoke-DCMsGraphQuery -GraphMethod 'POST' -GraphUri $uri -AccessToken $ManagementToken -GraphBody (@{query=$query} | ConvertTo-Json -Depth 10)
    $result
}

function Get-ManagementGroupsAndChildSubSSPs{
    param(
        [string]$ManagementToken = $(Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl)
    )
    $query = @'
ResourceContainers
| where type =~ 'microsoft.management/managementGroups'
| project ResourceId = name, DisplayName = tostring(properties.displayName), ParentDisplayName = tostring(properties.details.parent.displayName), HierarchyLevel = array_length(properties.details.managementGroupAncestorsChain), ParentId = tostring(properties.details.parent.name), type, tenantId
| extend hasDirectAccess = 1
| join kind=fullouter (
    resourcecontainers| where type == 'microsoft.management/managementgroups'
    | project tenantId, type, original = properties.details.managementGroupAncestorsChain, mgChain = properties.details.managementGroupAncestorsChain
    | mv-expand with_itemindex= MGIndex mgChain
    | project ResourceId = tostring(mgChain.name), DisplayName = tostring(mgChain.displayName), tenantId, HierarchyLevel = array_length(original) - MGIndex - 1, ParentId = tostring(original[MGIndex + 1].name), ParentDisplayName = tostring(original[MGIndex + 1].displayName)
    | summarize DisplayName = any(DisplayName), tenantId = any(tenantId), HierarchyLevel = any(HierarchyLevel), ParentId = any(ParentId), ParentDisplayName = any(ParentDisplayName) by ResourceId
) on ResourceId
| project ResourceId = iff(isempty(ResourceId), ResourceId1, ResourceId), DisplayName = iff(isempty(DisplayName), DisplayName1, DisplayName),ParentDisplayName = iff(isempty(ParentDisplayName), ParentDisplayName1, ParentDisplayName),HierarchyLevel = iff(isempty(HierarchyLevel), HierarchyLevel1, HierarchyLevel), ParentId = iff(isempty(ParentId), ParentId1, ParentId),hasDirectAccess = iff(isnull(hasDirectAccess), int(null), 1),type, tenantId
| join kind=leftouter (
    Resourcecontainers
    | where type == 'microsoft.resources/subscriptions'
    | extend selfAsMg = pack_array(pack('displayName', name, 'name', subscriptionId))
    | project id, type, tenantId, mgChain = array_concat(selfAsMg, properties.managementGroupAncestorsChain), SSPTag = tostring(tags.SSP)
    | extend original = mgChain
    | mv-expand with_itemindex=MGIndex mgChain
    | where MGIndex > 0  // Only get management groups, not the subscription itself
    | extend ResourceId = tostring(mgChain.name)
    | where isnotempty(SSPTag)
    | summarize SSPTags = make_set(SSPTag) by ResourceId
) on ResourceId
| where type == 'microsoft.management/managementgroups'
| project ManagementGroup = DisplayName, ResourceId, SSPTags = iff(isnull(SSPTags), dynamic([]), SSPTags)
'@
    $uri = "$TokenResourceUrl/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01"
    $result = Invoke-DCMsGraphQuery -GraphMethod 'POST' -GraphUri $uri -AccessToken $ManagementToken -GraphBody (@{query=$query} | ConvertTo-Json -Depth 10)
    $result = $result | %{$_ | Add-Member -MemberType NoteProperty -Name SSPTag -Value ($_.SSPTags -join '/') -Force; $_ | Select-Object ManagementGroup, SSPTag, resourceId}
    write-host "$($result.count) management groups found"
    $tenantSSP = ($result | where{$_.ManagementGroup -eq 'Management'}).SSPTag
    foreach($item in $result){
        If($item.ManagementGroup -eq 'Enterprise Policy' -or $item.ManagementGroup -eq 'EnterprisePolicy' -or $item.ManagementGroup -eq 'Identity' -or $item.ManagementGroup -eq 'Deprovisioned' -or $item.ManagementGroup -eq 'Landing Zone'){
            $item.SSPTag = $tenantSSP
        }
    }
    $result
}

Function Get-AzurePolicyExemptionsAtManagementGroupScopeRest{
    param(
        [Parameter(Mandatory = $false,ParameterSetName = 'ManagementGroup')]
        [string]$ManagementGroupId = $env:PolicyManagementGroupId,
        [Parameter(Mandatory = $false,ParameterSetName = 'AllManagementGroups')]
        [switch]$AllManagementGroups,
        [Parameter(Mandatory = $false,ParameterSetName = 'ManagementGroup')]
        [Parameter(Mandatory = $false,ParameterSetName = 'AllManagementGroups')]
        [string]$ManagementToken = $(Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl)
    )
    If($PSCmdlet.ParameterSetName -eq 'ManagementGroup'){
        $uri = "$TokenResourceUrl/providers/Microsoft.Management/managementGroups/$ManagementGroupId/providers/Microsoft.Authorization/policyExemptions?`$filter=atScope()&api-version=2022-07-01-preview" #2023-04-01 is too new for some clouds
        $result = Invoke-DCMsGraphQuery -GraphMethod 'Get' -GraphUri $uri -AccessToken $ManagementToken
        $result
    }ElseIf($PSCmdlet.ParameterSetName -eq 'AllManagementGroups'){
        ForEach($managementGroup in (Get-AllManagementGroupsRest).name){
            Write-Verbose "Getting policy exemptions for management group $managementGroup"
            $uri = "$TokenResourceUrl/providers/Microsoft.Management/managementGroups/$managementGroup/providers/Microsoft.Authorization/policyExemptions?`$filter=atScope()&api-version=2022-07-01-preview" #2023-04-01 is too new for some clouds
            $result = Invoke-DCMsGraphQuery -GraphMethod 'Get' -GraphUri $uri -AccessToken $ManagementToken
            $result
        }
    }
}

Function Get-AzurePolicyDefinitionByIDRest{
    param(
        [string]$PolicyDefinitionId,
        [string]$ManagementToken = $(Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl)
    )

    $uri = "$($TokenResourceUrl)$($PolicyDefinitionId)?api-version=2021-06-01"#2023-04-01 is too new for some clouds
    $result = Invoke-DCMsGraphQuery -GraphMethod 'Get' -GraphUri $uri -AccessToken $ManagementToken
    $result
}

Function Get-DFCBuiltinControls{
    param(
        [string]$ControlFilter = "NIST_SP_800-53_Rev4*"
    )
   
    $managementToken = Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl
    $uri = "$tokenResourceUrl/providers/Microsoft.PolicyInsights/policyMetadata?api-version=2019-10-01"
    $policyMetadata = Invoke-DCMsGraphQuery -AccessToken $managementToken -GraphMethod Get -GraphUri $uri
    $relevantControls = $policyMetadata.properties.metadata.frameworkControlsMappings | where{$_ -like $ControlFilter}
    $relevantControls
}

Function Get-DFCBuiltinControlsDetails{
    param(
        [string]$ControlFilter = "NIST_SP_800-53_Rev4*",
        $filterConversionHash = @{
            'Rev4' = 'R4'
            ' ' = ''
        }
    )

    $relevantControls = Get-DFCBuiltinControls -ControlFilter $ControlFilter
    $managementToken = Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl

    ForEach($conversionItem in ([array]($filterConversionHash).Keys)){
        $relevantControls = $relevantControls | %{$_.replace($conversionItem,$($filterConversionHash.$conversionItem))}
    }

    ForEach($control in $relevantControls){
        $uri = "$tokenResourceUrl/providers/Microsoft.PolicyInsights/policyMetadata/$($control)?api-version=2019-10-01"
        $controlDetails = Invoke-DCMsGraphQuery -AccessToken $managementToken -GraphMethod Get -GraphUri $uri
    }
}

Function Get-80053R4CSPData{
    $token = Connect-AcquireToken -TokenResourceUrl $tokenResourceUrl
    $uri = "$tokenResourceUrl/providers/Microsoft.PolicyInsights/policyMetadata?api-version=2019-10-01"
    $result = Invoke-DCMsGraphQuery -AccessToken $token -GraphMethod Get -GraphUri $uri -ErrorVariable myError

    $80053R4 = $result.properties.metadata.frameworkControlsMappings | where{$_ -like "NIST_SP_800-53_Rev4*"} | select -Unique

    $80053R4ForQuery = $80053R4 | %{$_.replace('Rev4','R4').replace(' ','')}
    $count = 0
    $additionalData = ForEach($control in $80053R4ForQuery){
        Write-Verbose "query $count of $($80053R4ForQuery.count) for 80053R4CSPData"
        $uri = "$tokenResourceUrl/providers/Microsoft.PolicyInsights/policyMetadata/$($control)?api-version=2019-10-01"
        $result = Invoke-DCMsGraphQuery -AccessToken $token -GraphMethod Get -GraphUri $uri -ErrorVariable myError
        $result
        $count++
        Sleep -Milliseconds 500
    }
    $additionalData
}

Function Get-LogAnalyticsQueryResult{
    <#
        .SYNOPSIS
        Queries Log Analytics and returns the result
        .DESCRIPTION
        Queries Log Analytics and returns the result
        .PARAMETER KQLQuery
        The KQL query to run.
        .PARAMETER LogAnalyticsToken
        The Log Analytics token to use. Default is to acquire a token.
        .PARAMETER resourceGraphToken
        The Resource Graph token to use. Default is to acquire a token.
        .PARAMETER workspaceId
        The Log Analytics workspace ID to use. Default is to use the environment variable $env:TenantMonitoringLogAnalyticsWorkspaceID
    #>
    param(
    [Parameter(Mandatory=$true)]
        [string]$KQLQuery,
    [Parameter(Mandatory=$false)]
        [string]$LogAnalyticsToken = $(Connect-AcquireToken -TokenResourceUrl $LogAnalyticsUrl),
    [Parameter(Mandatory=$false)]
        [string]$workspaceId = $env:TenantMonitoringLogAnalyticsWorkspaceID
    )

    $uri = "$LogAnalyticsUrl/v1/workspaces/$workspaceId/query"
    $body = @{
        query = $KQLQuery
    } | ConvertTo-Json -Depth 99 -Compress
    #Write-Warning "URI = $uri"
    $result = Invoke-DCMsGraphQuery -GraphMethod Post -GraphUri $uri -AccessToken $LogAnalyticsToken -GraphBody $body
    $headers = $result.tables.columns.name
    $finalResult = ForEach ($row in $result.tables.rows) {
        $myValues = @{}
        $count = 0
        ForEach ($name in $headers) {
            $myValues.Add($name, $row[$count])
            $count += 1
        }
        [pscustomobject]$myValues
    }
    $finalResult
}

Function Test-IsPrivateIP{
    param(
        [Parameter(Mandatory=$true)]
        [string]$ipAddress
    )
    $ip = [system.net.ipaddress]::Parse($ipAddress)
    If($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6){
        $family = 'IPv6'
        $ipArray = $ipAddress.Split(':')
        If($ipArray[0] -eq 'fc00' -or $ipArray[0] -eq 'fd00' -or $ipArray[0] -eq 'fe80') {
            $isPrivate = $true
        }Else{
            $isPrivate = $false
        }
    }
    Elseif($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork){
        $family = 'IPv4'
        $ipArray = $ipAddress.Split('.')
        if($ipArray[0] -eq '10' -or ($ipArray[0] -eq '172' -and $ipArray[1] -ge 16 -and $ipArray[1] -le 31) -or ($ipArray[0] -eq '192' -and $ipArray[1] -eq '168')) {
            $isPrivate = $true
        }Else{
            $isPrivate = $false
        }
    }Else{
        write-error 'not a valid IP address'
        ''
    }
    $isPrivate
}
 

Function Get-SNOWResourceIPs{
    <#
        SYNOPSIS
        Get the IP addresses of all resources that will be reported to ServiceNow
        DESCRIPTION
        Get the IP addresses of all resources that will be reported to ServiceNow
    #>
    param(
        [Parameter(Mandatory=$false)]
        [array]$SnowResourceTypes = @(
            'microsoft.compute/virtualmachines',
            'microsoft.containerregistry/registries',
            'microsoft.containerservice/managedclusters', #AKS
            'microsoft.keyvault/vaults',
            'microsoft.network/bastionhosts',
            'microsoft.storage/storageaccounts',
            'microsoft.network/networksecuritygroups',
            'microsoft.network/applicationgateways',
            'Microsoft.Network/applicationGateways/frontendIPConfigurations',
            'microsoft.network/localnetworkgateways',
            'microsoft.network/virtualnetworkgateways',
            'microsoft.network/p2svpngateways',
            'microsoft.network/networkinterfaces',
            'microsoft.network/publicipaddresses',
            'microsoft.network/expressroutecircuits',
            'microsoft.network/azurefirewalls',
            'microsoft.cognitiveservices/accounts',
            'microsoft.network/privateendpoints'
        )
    )
    begin{
       
        #region define helper functions
        Function Parse-StorageAccounts{
            param(
                [pscustomobject[]]$resources
            )
            $resources = $resources | where{$_.type -eq 'microsoft.storage/storageaccounts'}
            ForEach($resource in $resources){
                $privateEndpoints = $resource.properties.privateEndpointConnections.properties.privateEndpoint.id
                $nicIDs = $privateEndpoints | %{$privateEndpointToNICMap."$_"}
                $publicNetworkAccess = $resource.properties.publicNetworkAccess
                [pscustomobject]@{
                    id = $resource.id
                    name = $resource.name
                    type = $resource.type
                    privateEndpoints = $privateEndpoints -join(';')
                    nicIds = $nicIDs -join(';')
                    fqdns = ((($resource.Properties.primaryEndpoints | Get-Member -MemberType NoteProperty).definition) | %{$_.split('=')[1]}) -join (';')
                    privateIPs = ($nicIDs | %{$nicToPrivateIPMap."$($_)"}).privateIPAddress -join(';')
                    privateIPAllocationMethod = ($nicIDs | %{$nicToPrivateIPMap."$($_)"}).privateIPAllocationMethod -join(';')
                    publicNetworkAccess = $publicNetworkAccess
                    publicIpIds = If($publicNetworkAccess -eq 'Enabled'){'Azure fabric public endpoints'}else{''}
                    publicIps = If($publicNetworkAccess -eq 'Enabled'){'Azure fabric public endpoints'}else{''}
                    publicIPAllocationMethod = If($publicNetworkAccess -eq 'Enabled'){'Azure fabric public endpoints'}else{''}
                    subscriptionName = $subscriptionLookup."$($resource.id.split('/')[2])"
                    subscriptionId = $resource.id.split('/')[2]
                    resourceGroupName = $resource.id.split('/')[4]
                    location = $resource.location
                }
            }
        }

        Function Parse-KeyVaults{
            param(
                [pscustomobject[]]$resources
            )
            $resources = $resources | where{$_.type -eq 'microsoft.keyvault/vaults'}
            ForEach($resource in $resources){
                $privateEndpoints = $resource.properties.privateEndpointConnections.properties.privateEndpoint.id
                $nicIDs = $privateEndpoints | %{$privateEndpointToNICMap."$_"}
                $publicNetworkAccess = $resource.properties.publicNetworkAccess
                [pscustomobject]@{
                    id = $resource.id
                    name = $resource.name
                    type = $resource.type
                    privateEndpoints = $privateEndpoints -join(';')
                    nicIds = $nicIDs -join(';')
                    fqdns = $resource.Properties.vaultUri
                    privateIPs = ($nicIDs | %{$nicToPrivateIPMap."$($_)"}).privateIPAddress -join(';')
                    privateIPAllocationMethod = ($nicIDs | %{$nicToPrivateIPMap."$($_)"}).privateIPAllocationMethod -join(';')
                    publicNetworkAccess = $publicNetworkAccess
                    publicIpIds = If($publicNetworkAccess -eq 'Enabled'){'Azure fabric public endpoints'}else{''}
                    publicIps = If($publicNetworkAccess -eq 'Enabled'){'Azure fabric public endpoints'}else{''}
                    publicIPAllocationMethod = If($publicNetworkAccess -eq 'Enabled'){'Azure fabric public endpoints'}else{''}
                    subscriptionName = $subscriptionLookup."$($resource.id.split('/')[2])"
                    subscriptionId = $resource.id.split('/')[2]
                    resourceGroupName = $resource.id.split('/')[4]
                    location = $resource.location
                }
            }
        }

        Function Parse-ContainerRegistries{
            param(
                [pscustomobject[]]$resources
            )
            $resources = $resources | where{$_.type -eq 'microsoft.containerregistry/registries'}
            ForEach($resource in $resources){
                $privateEndpoints = $resource.properties.privateEndpointConnections.properties.privateEndpoint.id
                $nicIDs = $privateEndpoints | %{$privateEndpointToNICMap."$_"}
                $publicNetworkAccess = $resource.properties.publicNetworkAccess
                [pscustomobject]@{
                    id = $resource.id
                    name = $resource.name
                    type = $resource.type
                    privateEndpoints = $privateEndpoints -join(';')
                    nicIds = $nicIDs -join(';')
                    fqdns = ($resource.properties.dataEndpointHostNames + $resource.properties.loginServer) -join(';')
                    privateIPs = ($nicIDs | %{$nicToPrivateIPMap."$($_)"}).privateIPAddress -join(';')
                    privateIPAllocationMethod = ($nicIDs | %{$nicToPrivateIPMap."$($_)"}).privateIPAllocationMethod -join(';')
                    publicNetworkAccess = $publicNetworkAccess
                    publicIpIds = If($publicNetworkAccess -eq 'Enabled'){'Azure fabric public endpoints'}else{''}
                    publicIps = If($publicNetworkAccess -eq 'Enabled'){'Azure fabric public endpoints'}else{''}
                    publicIPAllocationMethod = If($publicNetworkAccess -eq 'Enabled'){'Azure fabric public endpoints'}else{''}
                    subscriptionName = $subscriptionLookup."$($resource.id.split('/')[2])"
                    subscriptionId = $resource.id.split('/')[2]
                    resourceGroupName = $resource.id.split('/')[4]
                    location = $resource.location
                }
            }
        }

        Function Parse-BastionHosts{
            param(
                [pscustomobject[]]$resources
            )
            $resources = $resources | where{$_.type -eq 'microsoft.network/bastionhosts'}
            ForEach($resource in $resources){
                $publicIpIds = $resource.properties.ipConfigurations.properties.publicIPAddress.id #-join(';')
                [pscustomobject]@{
                    id = $resource.id
                    name = $resource.name
                    type = $resource.type
                    privateEndpoints = '' #$privateEndpoints -join(';')
                    nicIds = ''#$nicIDs -join(';')
                    fqdns = $resource.properties.dnsName
                    privateIPs = '' #($nicIDs | %{$nicToPrivateIPMap."$($_)"}).privateIPAddress -join(';')
                    privateIPAllocationMethod = $resource.properties.ipConfigurations.properties.privateIpAllocationMethod -join(';')
                    publicNetworkAccess = '' #$resource.properties.publicNetworkAccess
                    publicIpIds = $publicIpIds -join(';')
                    publicIps = ($publicIpIds | %{$pipIdToIpAddressMap."$_"}).ipAddress -join(';')
                    publicIPAllocationMethod = ($publicIpIds | %{$pipIdToIpAddressMap."$_"}).publicIPAllocationMethod -join(';')
                    subscriptionName = $subscriptionLookup."$($resource.id.split('/')[2])"
                    subscriptionId = $resource.id.split('/')[2]
                    resourceGroupName = $resource.id.split('/')[4]
                    location = $resource.location
                }
            }
        }
       
        Function Parse-ApplicationGateways{
            param(
                [pscustomobject[]]$resources
            )
            $resources = $resources | where{$_.type -eq 'microsoft.network/applicationgateways'}
            ForEach($resource in $resources){
                $publicIpIds = $resource.properties.frontendIPConfigurations.properties.publicIPAddress.id -join(';')
                [pscustomobject]@{
                    id = $resource.id
                    name = $resource.name
                    type = $resource.type
                    privateEndpoints = ''#$privateEndpoints -join(';')
                    nicIds = ''#$nicIDs -join(';')
                    fqdns = $resource.properties.backendAddressPools.properties.backendAddresses.fqdn -join(';')
                    privateIPs = '' #($nicIDs | %{$nicToPrivateIPMap."$($_)"}).privateIPAddress -join(';')
                    privateIPAllocationMethod = $resource.properties.frontendIPConfigurations.properties.privateIPAllocationMethod #$resource.properties.ipConfigurations.properties.privateIpAllocationMethod -join(';')
                    publicNetworkAccess = 'the application gateway parser needs more work to catch all possible cases' #$resource.properties.publicNetworkAccess
                    publicIpIds = $publicIpIds
                    publicIps = ($publicIpIds | %{$pipIdToIpAddressMap."$_"}).ipAddress -join(';')
                    publicIPAllocationMethod = ($publicIpIds | %{$pipIdToIpAddressMap."$_"}).publicIPAllocationMethod -join(';')
                    subscriptionName = $subscriptionLookup."$($resource.id.split('/')[2])"
                    subscriptionId = $resource.id.split('/')[2]
                    resourceGroupName = $resource.id.split('/')[4]
                    location = $resource.location
                }
            }
        }

        Function Parse-LocalNetworkGateways{
            param(
                [pscustomobject[]]$resources
            )
            $resources = $resources | where{$_.type -eq 'microsoft.network/localnetworkgateways'}
            ForEach($resource in $resources){
                $ipAddress = $resource.properties.gatewayIpAddress
                If(Test-IsPrivateIP -ipAddress $ipAddress){
                    $privateIPs = $ipAddress
                    $publicIPs = ''
                }Else{
                    $privateIPs = ''
                    $publicIPs = $ipAddress
                }
                $publicIpIds = $resource.properties.frontendIPConfigurations.properties.publicIPAddress.id -join(';')
                [pscustomobject]@{
                    id = $resource.id
                    name = $resource.name
                    type = $resource.type
                    privateEndpoints = ''#$privateEndpoints -join(';')
                    nicIds = ''#$nicIDs -join(';')
                    fqdns = ''
                    privateIPs = $privateIPs
                    privateIPAllocationMethod = ''
                    publicNetworkAccess = ''
                    publicIpIds = ''
                    publicIps = $publicIPs
                    publicIPAllocationMethod = ''
                    subscriptionName = $subscriptionLookup."$($resource.id.split('/')[2])"
                    subscriptionId = $resource.id.split('/')[2]
                    resourceGroupName = $resource.id.split('/')[4]
                    location = $resource.location
                }
            }
        }

        Function Parse-VirtualNetworkGateways{
            param(
                [pscustomobject[]]$resources
            )
            $resources = $resources | where{$_.type -eq 'microsoft.network/virtualnetworkgateways'}
            ForEach($resource in $resources){
                $publicIPIds = $resource.properties.ipConfigurations.properties.publicIPAddress.id #-join(';')
                $privateIPs = $resource.properties.ipConfigurations.properties.privateIPAddress
                [pscustomobject]@{
                    id = $resource.id
                    name = $resource.name
                    type = $resource.type
                    privateEndpoints = ''
                    nicIds = ''
                    fqdns = ''
                    privateIPs = $privateIPs -join(';')
                    privateIPAllocationMethod = $resource.properties.ipConfigurations.properties.privateIPAllocationMethod -join(';')
                    publicNetworkAccess = ''
                    publicIpIds = $publicIPIds -join(';')
                    publicIps = ($publicIpIds | %{$pipIdToIpAddressMap."$_"}).ipAddress -join(';')
                    publicIPAllocationMethod = ($publicIpIds | %{$pipIdToIpAddressMap."$_"}).publicIPAllocationMethod -join(';')
                    subscriptionName = $subscriptionLookup."$($resource.id.split('/')[2])"
                    subscriptionId = $resource.id.split('/')[2]
                    resourceGroupName = $resource.id.split('/')[4]
                    location = $resource.location
                }
            }
        }

        Function Parse-VirtualMachines{
            param(
                [pscustomobject[]]$resources
            )
            $resources = $resources | where{$_.type -eq 'microsoft.compute/virtualmachines'}
            ForEach($resource in $resources){
                #$privateEndpoints = $resource.properties.networkProfile.networkInterfaces.id
                $nicIDs = $resource.properties.networkProfile.networkInterfaces.id
                $publicNetworkAccess = If(($nicIDs | %{$pipIdToIpAddressMap."$($_.Name)"}).count -gt 0){'Enabled'}Else{'Disabled'}
                $fqdns = '' <#
                    Get all private DNS Zones
                        Get the vnet links for each private DNS zone
                            If "Auto-Registration" is enabled, then the VM will auth-register if it is on this vnet

                    [
                        {
                            'VnetId' = '',
                            'PrivateDNSZoneName' = '',
                            'AutoRegistrationEnabled' = $true/false,
                        }
                    ]
                    To determine the FQDN:
                        - get the NIC on the VM
                        - check the subnet the NIC is on
                        - The subnet resource ID includes the vnet ID
                        - check the list generated above for the vnet ID
                        - for all places the vnet ID is in the list, check if AutoRegistrationEnabled is true
                        - for all places where AutoRegistrationEnabled is true, get the PrivateDNSZoneName
                        - the FQDN is then the VM's name + '.' + PrivateDNSZoneName
                #>
                [pscustomobject]@{
                    id = $resource.id
                    name = $resource.name
                    type = $resource.type
                    privateEndpoints = ''#$privateEndpoints -join(';')
                    nicIds = $nicIDs -join(';')
                    fqdns = '' #($nicIDs | %{$nicToPrivateIPMap."$($_)"}).fqdns -join(';') #FQDNs are far more difficult. They are also not available when powered off.
                    privateIPs = ($nicIDs | %{$nicToPrivateIPMap."$($_)"}).privateIPAddress -join(';')
                    privateIPAllocationMethod = ($nicIDs | %{$nicToPrivateIPMap."$($_)"}).privateIPAllocationMethod -join(';')
                    publicNetworkAccess = $publicNetworkAccess
                    publicIpIds = ($nicIDs | %{$pipIdToIpAddressMap."$($_.Name)"}).Name -join(';')
                    publicIps = ($nicIDs | %{$pipIdToIpAddressMap."$($_.Name)"}).ipAddress -join(';')
                    publicIPAllocationMethod = ($nicIDs | %{$pipIdToIpAddressMap."$($_.Name)"}).publicIPAllocationMethod -join(';')
                    subscriptionName = $subscriptionLookup."$($resource.id.split('/')[2])"
                    subscriptionId = $resource.id.split('/')[2]
                    resourceGroupName = $resource.id.split('/')[4]
                    location = $resource.location
                }
            }
        }
        #endregion define helper functions
    }
    process{
        $allResourcesQuery = "resources | where tolower(type) in ('" + ($SnowResourceTypes -join "','") + "') | project id, name, type, location, properties"
        $uri = "https://$managementApiBase/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01"
        $allResourcesBody = @{
            query = $allResourcesQuery
        } | ConvertTo-Json -Depth 99
        $resourceGraphToken = Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl
        $result = Invoke-DCMsGraphQuery -AccessToken $resourceGraphToken -GraphMethod Post -GraphUri $uri -GraphBody $allResourcesBody
        $allResources = $result

        $privateEndpointToNICMap = $allResources | where{$_.type -eq 'microsoft.network/privateendpoints'} | %{@{$_.id = $_.properties.networkInterfaces.id}}
        $nicToPrivateIPMap = $allResources | where{$_.type -eq 'microsoft.network/networkinterfaces'} | %{
            @{
                $_.id = [pscustomobject]@{
                    privateIPAddress = $_.properties.ipConfigurations.properties.privateIPAddress
                    privateIPAllocationMethod = $_.properties.ipConfigurations.properties.privateIPAllocationMethod
                    fqdns = $_.properties.ipConfigurations.properties.privateLinkConnectionProperties.fqdns -join(';')
                }
            }
        }
        $pipIdToIpAddressMap = $allResources | where{$_.type -eq 'microsoft.network/publicipaddresses'} | %{
            @{
                $_.id = [pscustomobject]@{
                    publicIPAllocationMethod = $_.properties.publicIPAllocationMethod
                    ipAddress = $_.properties.ipAddress
                }
            }
        }

        $SnowIPData = @()
        $SnowIPData += Parse-StorageAccounts -resources $allResources
        $SnowIPData += Parse-KeyVaults -resources $allResources
        $SnowIPData += Parse-ContainerRegistries -resources $allResources
        $SnowIPData += Parse-BastionHosts -resources $allResources
        $SnowIPData += Parse-ApplicationGateways -resources $allResources
        $SnowIPData += Parse-LocalNetworkGateways -resources $allResources
        $SnowIPData += Parse-VirtualNetworkGateways -resources $allResources
        $SnowIPData += Parse-VirtualMachines -resources $allResources
        $SnowIPData
    }
    end{}
}

<#
//gets all private endpoints and their related NIC
resources
| where type == 'microsoft.network/privateendpoints'
| mv-expand properties.networkInterfaces
| extend nicId = tostring(parse_json(properties_networkInterfaces).id)
| project privateEndpointId = ['id'], nicId

//gets all NICs, their IP, fqdns, and managedBy
resources
| where type == 'microsoft.network/networkinterfaces'
| mv-expand properties.ipConfigurations
| extend privateIPAddress = parse_json(properties_ipConfigurations).properties.privateIPAddress
| extend fqdns = parse_json(properties_ipConfigurations).properties.privateLinkConnectionProperties.fqdns
| project nicId = id, privateIPAddress, fqdns, managedBy


//gets all private endpoints and their related NIC, privateIP, fqdns
resources
| where type == 'microsoft.network/privateendpoints'
| mv-expand properties.networkInterfaces
| extend nicId = tostring(parse_json(properties_networkInterfaces).id)
| project privateEndpointId = ['id'], nicId
| join kind = leftouter(
     resources
    | where type == 'microsoft.network/networkinterfaces'
    | mv-expand properties.ipConfigurations
    | extend privateIPAddress = parse_json(properties_ipConfigurations).properties.privateIPAddress
    | extend fqdns = parse_json(properties_ipConfigurations).properties.privateLinkConnectionProperties.fqdns
    | project nicId = id, privateIPAddress, fqdns//, managedBy
) on $left.nicId == $right.nicId
| project-away nicId1


//every storage account and the associated privateEndpoint, NIC, privateIPAddress, and FQDNs
resources
| where type == 'microsoft.storage/storageaccounts'
| mv-expand properties.privateEndpointConnections
| project storageAccountId = id, privateEndpointId = tostring(parse_json(properties_privateEndpointConnections).properties.privateEndpoint.id)
| join kind=leftouter (
    resources
        | where type == 'microsoft.network/privateendpoints'
        | mv-expand properties.networkInterfaces
        | extend nicId = tostring(parse_json(properties_networkInterfaces).id)
        | project privateEndpointId = tostring(['id']), nicId
        | join kind = leftouter(
             resources
            | where type == 'microsoft.network/networkinterfaces'
            | mv-expand properties.ipConfigurations
            | extend privateIPAddress = parse_json(properties_ipConfigurations).properties.privateIPAddress
            | extend fqdns = parse_json(properties_ipConfigurations).properties.privateLinkConnectionProperties.fqdns
            | project nicId = id, privateIPAddress, fqdns//, managedBy
        ) on $left.nicId == $right.nicId
        | project-away nicId1
    ) on $left.privateEndpointId == $right.privateEndpointId
    | project-away privateEndpointId1



//every storage account and the associated privateEndpoint, NIC, privateIPAddress, and FQDNs
resources
| where type == 'microsoft.storage/storageaccounts'
| mv-expand properties.privateEndpointConnections
| extend storageAccountId = id, privateEndpointId = tostring(parse_json(properties_privateEndpointConnections).properties.privateEndpoint.id)
| join kind=leftouter (
    resources
        | where type == 'microsoft.network/privateendpoints'
        | mv-expand properties.networkInterfaces
        | extend nicId = tostring(parse_json(properties_networkInterfaces).id)
        | project privateEndpointId = tostring(['id']), nicId
        | join kind = leftouter(
            resources
            | where type == 'microsoft.network/networkinterfaces'
            | mv-expand properties.ipConfigurations
            | extend privateIPAddress = parse_json(properties_ipConfigurations).properties.privateIPAddress
            | extend fqdns = parse_json(properties_ipConfigurations).properties.privateLinkConnectionProperties.fqdns
            | extend privateIPAllocationMethod = parse_json(properties_ipConfigurations).properties.privateIPAllocationMethod
            | project nicId = id, privateIPAddress, fqdns, managedBy, privateIPAllocationMethod
        ) on $left.nicId == $right.nicId
        | project-away nicId1
    ) on $left.privateEndpointId == $right.privateEndpointId
    | project-away privateEndpointId1
    | project storageAccountId, privateEndpointId, nicId, fqdns, privateIPAddress, privateIPAllocationMethod
    //| extend SAName = split(storageAccountId,"/")[-1]


    //every storage account and the associated privateEndpoint, NIC, privateIPAddress, and FQDNs
resources
| where type == 'microsoft.storage/storageaccounts'
| mv-expand properties.privateEndpointConnections
| extend storageAccountId = id, privateEndpointId = tostring(parse_json(properties_privateEndpointConnections).properties.privateEndpoint.id), publicNetworkAccess = tostring(parse_json(properties.publicNetworkAccess)), primaryEndpoints = tostring(parse_json(properties.primaryEndpoints))
| join kind=leftouter (
    resources
        | where type == 'microsoft.network/privateendpoints'
        | mv-expand properties.networkInterfaces
        | extend nicId = tostring(parse_json(properties_networkInterfaces).id)
        | project privateEndpointId = tostring(['id']), nicId
        | join kind = leftouter(
            resources
            | where type == 'microsoft.network/networkinterfaces'
            | mv-expand properties.ipConfigurations
            | extend privateIPAddress = parse_json(properties_ipConfigurations).properties.privateIPAddress
            | extend fqdns = parse_json(properties_ipConfigurations).properties.privateLinkConnectionProperties.fqdns
            | extend privateIPAllocationMethod = parse_json(properties_ipConfigurations).properties.privateIPAllocationMethod
            | project nicId = id, privateIPAddress, fqdns, managedBy, privateIPAllocationMethod
        ) on $left.nicId == $right.nicId
        | project-away nicId1
    ) on $left.privateEndpointId == $right.privateEndpointId
    | project storageAccountId, privateEndpointId, nicId, fqdns, privateIPAddress, privateIPAllocationMethod, publicNetworkAccess, primaryEndpoints

resources
| where type == 'microsoft.storage/storageaccounts'
| mv-expand properties.privateEndpointConnections
| extend storageAccountId = id, privateEndpointId = tostring(parse_json(properties_privateEndpointConnections).properties.privateEndpoint.id), publicNetworkAccess = tostring(parse_json(properties.publicNetworkAccess)), primaryEndpoints = tostring(parse_json(properties.primaryEndpoints))
| summarize make_list_with_nulls(privateEndpointId) by id
| join (
    resources
    | extend storageAccountId = id, publicNetworkAccess = tostring(parse_json(properties.publicNetworkAccess)), primaryEndpoints = tostring(parse_json(properties.primaryEndpoints))
) on ['id']
| project storageAccountId, privateEndpoints = list_privateEndpointId, primaryEndpoints, publicNetworkAccess


//All SAs without mv_expand
resources
| where type == 'microsoft.storage/storageaccounts'
| mv-expand properties.privateEndpointConnections
| extend storageAccountId = id, privateEndpointId = tostring(parse_json(properties_privateEndpointConnections).properties.privateEndpoint.id), publicNetworkAccess = tostring(parse_json(properties.publicNetworkAccess)), primaryEndpoints = tostring(parse_json(properties.primaryEndpoints))
| summarize make_list_with_nulls(privateEndpointId) by id
| join (
    resources
    | extend storageAccountId = id, publicNetworkAccess = tostring(parse_json(properties.publicNetworkAccess)), primaryEndpoints = tostring(parse_json(properties.primaryEndpoints))
) on ['id']
| project storageAccountId, privateEndpoints = list_privateEndpointId, primaryEndpoints, publicNetworkAccess


resources
| where type == 'microsoft.storage/storageaccounts'
| mv-expand properties.privateEndpointConnections
| extend storageAccountId = id, privateEndpointId = tostring(parse_json(properties_privateEndpointConnections).properties.privateEndpoint.id), publicNetworkAccess = tostring(parse_json(properties.publicNetworkAccess)), primaryEndpoints = tostring(parse_json(properties.primaryEndpoints))
| join kind=leftouter (
    resources
        | where type == 'microsoft.network/privateendpoints'
        | mv-expand properties.networkInterfaces
        | extend nicId = tostring(parse_json(properties_networkInterfaces).id)
        | project privateEndpointId = tostring(['id']), nicId
        | join kind = leftouter(
            resources
            | where type == 'microsoft.network/networkinterfaces'
            | mv-expand properties.ipConfigurations
            | extend privateIPAddress = parse_json(properties_ipConfigurations).properties.privateIPAddress
            | extend fqdns = parse_json(properties_ipConfigurations).properties.privateLinkConnectionProperties.fqdns
            | extend privateIPAllocationMethod = parse_json(properties_ipConfigurations).properties.privateIPAllocationMethod
            | project nicId = id, privateIPAddress, fqdns, managedBy, privateIPAllocationMethod
        ) on $left.nicId == $right.nicId
        | project-away nicId1
    ) on $left.privateEndpointId == $right.privateEndpointId
    | project Id = storageAccountId, type, privateEndpointId, nicId, fqdns, privateIPAddress, privateIPAllocationMethod, publicNetworkAccess, primaryEndpoints

#all KVs, SAs, and container registries
resources
| where type in~ ('microsoft.keyvault/vaults','microsoft.storage/storageaccounts','microsoft.containerregistry/registries')
| mv-expand properties.privateEndpointConnections
| extend id, privateEndpointId = tostring(parse_json(properties_privateEndpointConnections).properties.privateEndpoint.id), publicNetworkAccess = tostring(parse_json(properties.publicNetworkAccess)), primaryEndpoints = tostring(parse_json(properties.primaryEndpoints))
| join kind=leftouter (
    resources
        | where type == 'microsoft.network/privateendpoints'
        | mv-expand properties.networkInterfaces
        | extend nicId = tostring(parse_json(properties_networkInterfaces).id)
        | project privateEndpointId = tostring(['id']), nicId
        | join kind = leftouter(
            resources
            | where type == 'microsoft.network/networkinterfaces'
            | mv-expand properties.ipConfigurations
            | extend privateIPAddress = parse_json(properties_ipConfigurations).properties.privateIPAddress
            | extend fqdns = parse_json(properties_ipConfigurations).properties.privateLinkConnectionProperties.fqdns
            | extend privateIPAllocationMethod = parse_json(properties_ipConfigurations).properties.privateIPAllocationMethod
            | project nicId = id, privateIPAddress, fqdns, managedBy, privateIPAllocationMethod
        ) on $left.nicId == $right.nicId
        | project-away nicId1
    ) on $left.privateEndpointId == $right.privateEndpointId
    | project id, type, privateEndpointId, nicId, fqdns, privateIPAddress, privateIPAllocationMethod, publicNetworkAccess, primaryEndpoints

#all Firewalls
resources
| where type == 'microsoft.network/azurefirewalls'
| mv-expand properties.ipConfigurations
| extend privateIPAllocationMethod = properties_ipConfigurations.properties.privateIPAllocationMethod
| extend privateIPAddress = properties_ipConfigurations.properties.privateIPAddress
| extend publicIPAddressId = tostring(properties_ipConfigurations.properties.publicIPAddress.id)
| project id, type, privateIPAddress, privateIPAllocationMethod, publicIPAddressId
| join (
    resources
    | where type == 'microsoft.network/publicipaddresses'
    | extend publicIPAllocationMethod = parse_json(properties).publicIPAllocationMethod
    | extend ipAddress = parse_json(properties).ipAddress
    | project id, publicIPAllocationMethod, ipAddress
) on $left.publicIPAddressId == $right.['id']
| project-away id1

#all VMs
resources
| where type == 'microsoft.compute/virtualmachines'
| mv-expand properties.networkProfile.networkInterfaces
| project id, type, nicId = tostring(properties_networkProfile_networkInterfaces.id)
| join kind = leftouter(
            resources
            | where type == 'microsoft.network/networkinterfaces'
            | mv-expand properties.ipConfigurations
            | extend privateIPAddress = parse_json(properties_ipConfigurations).properties.privateIPAddress
            | extend fqdns = parse_json(properties_ipConfigurations).properties.privateLinkConnectionProperties.fqdns
            | extend privateIPAllocationMethod = tostring(parse_json(properties_ipConfigurations).properties.privateIPAllocationMethod)
            | project nicId = id, privateIPAddress, privateIPAllocationMethod
        ) on $left.nicId == $right.nicId
        | project-away nicId1


#all VMs - with public IPs too
resources
| where type == 'microsoft.compute/virtualmachines'
| mv-expand properties.networkProfile.networkInterfaces
| project id, type, nicId = tostring(properties_networkProfile_networkInterfaces.id)
| join kind = leftouter(
            resources
            | where type == 'microsoft.network/networkinterfaces'
            | mv-expand properties.ipConfigurations
            | extend privateIPAddress = parse_json(properties_ipConfigurations).properties.privateIPAddress
            | extend fqdns = parse_json(properties_ipConfigurations).properties.privateLinkConnectionProperties.fqdns
            | extend privateIPAllocationMethod = tostring(parse_json(properties_ipConfigurations).properties.privateIPAllocationMethod)
            | extend publicIpAddressId = tostring(parse_json(properties_ipConfigurations).properties.publicIPAddress.id)
            | project nicId = id, privateIPAddress, privateIPAllocationMethod, publicIpAddressId
        ) on $left.nicId == $right.nicId
        | project-away nicId1
    | join kind = leftouter(
        resources
        | where type == 'microsoft.network/publicipaddresses'
        | extend publicIPAllocationMethod = tostring(parse_json(properties).publicIPAllocationMethod)
        | extend ipAddress = tostring(parse_json(properties).ipAddress)
        | project id, publicIPAllocationMethod, ipAddress
        ) on $left.publicIpAddressId == $right.['id']
    | project-away id1

#container registries
resources
| where type == 'microsoft.containerregistry/registries'
| mv-expand properties.privateEndpointConnections
| extend privateEndpointId = tostring(parse_json(properties_privateEndpointConnections).properties.privateEndpoint.id)
| join kind=leftouter (
    resources
        | where type == 'microsoft.network/privateendpoints'
        | mv-expand properties.networkInterfaces
        | extend nicId = tostring(parse_json(properties_networkInterfaces).id)
        | project privateEndpointId = tostring(['id']), nicId
        | join kind = leftouter(
            resources
            | where type == 'microsoft.network/networkinterfaces'
            | mv-expand properties.ipConfigurations
            | extend privateIPAddress = parse_json(properties_ipConfigurations).properties.privateIPAddress
            | extend fqdns = parse_json(properties_ipConfigurations).properties.privateLinkConnectionProperties.fqdns
            | extend privateIPAllocationMethod = parse_json(properties_ipConfigurations).properties.privateIPAllocationMethod
            | project nicId = id, privateIPAddress, fqdns, managedBy, privateIPAllocationMethod
        ) on $left.nicId == $right.nicId
        | project-away nicId1
    ) on $left.privateEndpointId == $right.privateEndpointId

        #>

Function Get-VnetGatewayLearnedRoutes{
    <#
        SYNOPSIS
        Get the learned routes for a vnet gateway
        DESCRIPTION
        Get the learned routes for a vnet gateway
    #>
    param(
        [Parameter(Mandatory = $true,ParameterSetName = 'singlevNetGateway')]
        [string]$vnetGatewayId,
        [Parameter(Mandatory = $false)]
        [string]$managementToken,
        [Parameter(Mandatory = $true,ParameterSetName = 'allvNetGateways')]
        [switch]$allVnetGateways
    )

    If(!$managementToken){
        $managementToken = Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl
    }

    #If($allVnetGateways){
    $allVnetGatewaysQuery = "resources | where type == 'microsoft.network/virtualnetworkgateways'"
    $allVnetGatewaysArray = Invoke-ResourceGraphQueryREST -query $allVnetGatewaysQuery -resourceGraphToken $managementToken
    sleep -seconds 1
    #$allVnetGatewayIds = $allVnetGateways.id
    #}Else{
    #    $allVnetGateways =
        #$allVnetGatewayIds = @($vnetGatewayId)
    #}
    If($vnetGatewayId){
        [array]$allVnetGateways = $allVnetGateways | where{$_.id -eq $vnetGatewayId}
    }
   
    $allResultsForAllVNGs = @()
    ForEach($vnetGateway in $allVnetGatewaysArray){
        $uri = "$($tokenResourceUrl)$($vnetGateway.Id)/getLearnedRoutes?api-version=2024-05-01"
        $response = Invoke-RestMethod -Uri $uri -Method Post -Headers @{'Authorization' = "Bearer $($managementToken)"} -ResponseHeadersVariable responseHeaders -StatusCodeVariable statusCode 4>$Null
        sleep -Seconds 5
        $allResultsForVNG = @()
        if ($statusCode -eq 200) {
            $allResultsForVNG += $response.value
        }ElseIf($statusCode -eq 202){
            $uris = $responseHeaders.Location
            ForEach($uri in $uris){
                $response = Invoke-RestMethod -Uri $uri -Method Get -Headers @{'Authorization' = "Bearer $($managementToken)"} -ResponseHeadersVariable responseHeaders -StatusCodeVariable statusCode 4>$Null
                if ($statusCode -eq 200 -or $statusCode -eq 202) {
                    $allResultsForVNG += $response.value
                }Else{
                    Write-Error "0Failed to get learned routes for $($vnetGateway.id). Status code: $statusCode"
                    #return $null
                }
            }
        }Else{
            Write-Error "1Failed to get learned routes for $($vnetGateway.Id). Status code: $statusCode"
            #return $null
        }
        $allResultsForAllVNGs += [pscustomobject]@{
            vnetGateway = $vnetGateway
            learnedRoutes = $allResultsForVNG
        }
    }
    $allResultsForAllVNGs
}

Function Get-VnetGatewayBgpPeeringStatus{
    <#
        SYNOPSIS
        Get the BGP peering status for a vnet gateway
        DESCRIPTION
        Get the BGP peering status for a vnet gateway
    #>
    param(
        [Parameter(Mandatory = $true,ParameterSetName = 'singlevNetGateway')]
        [string]$vnetGatewayId,
        [Parameter(Mandatory = $false)]
        [string]$managementToken,
        [Parameter(Mandatory = $true,ParameterSetName = 'allvNetGateways')]
        [switch]$allVnetGateways
    )

    If(!$managementToken){
        $managementToken = Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl
    }

    #If($allVnetGateways){
    $allVnetGatewaysQuery = "resources | where type == 'microsoft.network/virtualnetworkgateways'"
    $allVnetGatewaysArray = Invoke-ResourceGraphQueryREST -query $allVnetGatewaysQuery -resourceGraphToken $managementToken
    sleep -seconds 1
    #$allVnetGatewayIds = $allVnetGateways.id
    #}Else{
    #    $allVnetGateways =
        #$allVnetGatewayIds = @($vnetGatewayId)
    #}
    If($vnetGatewayId){
        [array]$allVnetGateways = $allVnetGateways | where{$_.id -eq $vnetGatewayId}
    }
   
    $allResultsForAllVNGs = @()
    ForEach($vnetGateway in $allVnetGatewaysArray){
        $uri = "$($tokenResourceUrl)$($vnetGateway.Id)/getBgpPeerStatus?api-version=2024-05-01"
        $response = Invoke-RestMethod -Uri $uri -Method Post -Headers @{'Authorization' = "Bearer $($managementToken)"} -ResponseHeadersVariable responseHeaders -StatusCodeVariable statusCode
        sleep -Seconds 5
        $allResultsForVNG = @()
        if ($statusCode -eq 200) {
            $allResultsForVNG += $response.value
        }ElseIf($statusCode -eq 202){
            $uris = $responseHeaders.Location
            ForEach($uri in $uris){
                $response = Invoke-RestMethod -Uri $uri -Method Get -Headers @{'Authorization' = "Bearer $($managementToken)"} -ResponseHeadersVariable responseHeaders -StatusCodeVariable statusCode
                if ($statusCode -eq 200 -or $statusCode -eq 202) {
                    $allResultsForVNG += $response.value
                }Else{
                    Write-Error "0Failed to get BGP peering status for $($vnetGateway.id). Status code: $statusCode"
                    #return $null
                }
                <#
                $allResultsForAllVNGs += [pscustomobject]@{
                    vnetGateway = $vnetGateway
                    bgpPeeringStatus = $allResultsForVNG
                }
                #>
            }
            $allResultsForAllVNGs
        }
        $allResultsForAllVNGs += [pscustomobject]@{
            vnetGateway = $vnetGateway
            learnedRoutes = $allResultsForVNG
        }
    }
    $allResultsForAllVNGs
}

Function Get-PrivateEndpointDNSConfigurations{
    <#
        SYNOPSIS
        Get the DNS configurations for all private endpoints
        DESCRIPTION
        Get the DNS configurations for all private endpoints
    #>
    param(
        [Parameter(Mandatory = $true,ParameterSetName = 'singlePrivateEndpoint')]
        [string]$privateEndpointId,
        [Parameter(Mandatory = $false)]
        [string]$managementToken,
        [Parameter(Mandatory = $true,ParameterSetName = 'allPrivateEndpoints')]
        [switch]$allPrivateEndpoints
    )

    If(!$managementToken){
        $managementToken = Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl
    }

    $allPrivateEndpointsQuery = "resources | where type == 'microsoft.network/privateendpoints'"
    $allPrivateEndpointsArray = Invoke-ResourceGraphQueryREST -query $allPrivateEndpointsQuery -resourceGraphToken $managementToken
    $allPrivateEndpointsArray = $allPrivateEndpointsArray | where{$_.properties.ProvisioningState -eq 'Succeeded'}
   
    $allNICsQuery = "resources | where type == 'microsoft.network/networkinterfaces'"
    $allNICsArray = Invoke-ResourceGraphQueryREST -query $allNICsQuery -resourceGraphToken $managementToken
    $NicIdToPrivateIPMap = $allNICsArray | %{@{$_.id = $_.properties.ipConfigurations.properties.privateIPAddress}}
    $NicIdToFQDNsMAP = $allNICsArray | %{@{$_.id = $_.properties.ipConfigurations.properties.privateLinkConnectionProperties.fqdns -join ';'}}

    If($privateEndpointId){
        [array]$allPrivateEndpoints = $allPrivateEndpoints | where{$_.id -eq $privateEndpointId}
    }
   
    $dataForExport = ForEach($privateEndpoint in $allPrivateEndpointsArray){
        $NicIds = $privateEndpoint.properties.networkInterfaces.id
        ForEach($nicID in $NicIds){
            $fqdns = $NicIdToFQDNsMAP."$($nicID)"
            ForEach($fqdn in $fqdns.split(';')){
                ForEach($ip in $NicIdToPrivateIPMap."$($nicID)"){
                    [pscustomobject]@{
                        'fqdn' = $fqdn
                        'privateIP' = $ip          
                    }  
                }
            }
        }
    }
    $dataForExport | where{$_.fqdn}
}

Function Invoke-AppInsightsQueryREST{
    <#
        SYNOPSIS
        Invoke an Application Insights query using REST API
        DESCRIPTION
        Invoke an Application Insights query using REST API
        PARAMETER appId
        The Application Insights AppId, not "ApplicationId" (The "ApplicationId" is the human readable one shown in the portal, the AppId is a GUID)
        PARAMETER query
        The Kusto query to execute, be sure to include time range in the query like "where timestamp > ago(3d)"
        PARAMETER appInsightsToken
        An optional pre-acquired token for Application Insights. If not provided, the function will acquire one.
        EXAMPLES
        Example 1: Invoke-AppInsightsQueryREST -appId 'your-app-id' -query 'requests | where timestamp > ago(1d) | summarize count() by bin(timestamp, 1h)'
            This example queries the specified Application Insights instance for request counts over the past day, grouped by hour.
        Example 2: $token = Connect-AcquireToken -TokenResourceUrl 'https://api.applicationinsights.io/'
            Invoke-AppInsightsQueryREST -appId 'your-app-id' -query 'traces | where timestamp > ago(7d) | summarize count() by severityLevel' -appInsightsToken $token  
            This example first acquires a token and then uses it to query trace logs for the past week, grouped by severity level.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$appId,
        [Parameter(Mandatory = $true)]
        [string]$query,
        [Parameter(Mandatory = $false)]
        [string]$appInsightsToken
    )

    If(!$appInsightsToken){
        $appInsightsToken = Connect-AcquireToken -TokenResourceUrl $AppInsightsURI
    }

    $uri = "$AppInsightsURI/v1/apps/$appId/query?query=$([System.Web.HttpUtility]::UrlEncode($query))"
    #$response = Invoke-RestMethod -Uri $uri -Method Get -Headers @{'Authorization' = "Bearer $($appInsightsToken)"} -ResponseHeadersVariable responseHeaders -StatusCodeVariable statusCode 4>$Null
    $response = invoke-dcmsgraphquery -AccessToken $appInsightsToken -GraphMethod Get -GraphUri $uri  4>$Null
    If($response.tables.rows){
        return $response.tables.rows | ForEach-Object {
            $obj = @{}
            for ($i = 0; $i -lt $response.tables.columns.Count; $i++) {
                $obj[$response.tables.columns[$i].name] = $_[$i]
            }
            [pscustomobject]$obj
        }
    }Else{
        return $null
    }
}

Function Start-AzurePolicyRemediationREST{
    param(
        [Parameter(Mandatory = $true)]
        [string]$PolicyAssignmentId,
        [Parameter(Mandatory = $true)]
        [string]$remediationScope,
        [Parameter(Mandatory = $false)]
        [string]$PolicyDefinitionReferenceId, #required for policy sets, not allowed for single policies
        [Parameter(Mandatory = $false)]
        [string]$Name = "Function App Triggered Remediation $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        [Parameter(Mandatory = $false)]
        [ValidateSet('ExistingNonCompliant','ReEvaluateCompliance')]
        [string]$resourceDiscoveryMode = 'ExistingNonCompliant',
        [Parameter(Mandatory = $false)]
        [int]$ParalellDeployments = 30
    )
    $uri = "$($TokenResourceUrl)$($remediationScope)/providers/Microsoft.PolicyInsights/remediations/$($Name)?api-version=2021-10-01"
    $body = @{
        properties = @{
            policyAssignmentId = $PolicyAssignmentId
            policyDefinitionReferenceId = $PolicyDefinitionReferenceId
            resourceDiscoveryMode = $resourceDiscoveryMode
        }
    } | ConvertTo-Json

    $token = Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl
    $response = Invoke-DCMsGraphQuery -AccessToken $token -GraphMethod Put -GraphUri $uri -GraphBody $body
#    $response = Invoke-RestMethod -Uri $uri -Method Post -Body $body -Headers $header -ContentType 'application/json' 4>$Null
    return $response
}

Function Start-AzurePolicySetRemediationREST{
    param(
        [Parameter(Mandatory = $true)]
        [string]$PolicySetAssignmentId,
        [Parameter(Mandatory = $true)]
        [string]$remediationScope,
        [Parameter(Mandatory = $false)]
        [ValidateSet('ExistingNonCompliant','ReEvaluateCompliance')]
        [string]$resourceDiscoveryMode = 'ExistingNonCompliant',
        [Parameter(Mandatory = $false)]
        [int]$ParalellDeployments = 30
    )
    #Find all DINE policies in the policy set, then get their PolicyDefinitionReferenceIds
        #technically a remediation task can be created for a non-DINE policy, so it may be easier to just kick off a remediation task for every PolicyDefinitionReferenceId in the set
   
    If($PolicySetAssignmentId -like '/subscriptions/*/resourcegroups/*/providers/microsoft.authorization/policyassignments/*'){
        #$policyDefinitions =
    }ElseIf($PolicySetAssignmentId -like '/providers/microsoft.management/managementgroups/*/providers/microsoft.authorization/policyassignments/*'){
        #$PolicySetAssignment = Get-AzurePolicyAssignmentAtManagementGroupScopeRest -ManagementGroupId
        #$policySetDefinition = Get-AzurePolicySetDefinitionREST -PolicyDefinitionId $PolicySetAssignmentId
    }Else{

    }
   
        $roleDefinitionIds = get-azure
    #Loop through generating them with Start-AzurePolicyRemediationREST

}

Write-Verbose 'Profile Functions Loaded'
#endregion Functions

#Region Useful Variables
Write-Verbose 'Loading Profile Variables'
$token = Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl
#$token = (Get-AzAccessToken -ResourceUrl $TokenResourceUrl).Token
$header = @{Authorization = "Bearer $token" }
$uri = "https://$managementApiBase/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01"
$body = @{
    query = 'resourcecontainers | where type == "microsoft.resources/subscriptions"'
} | ConvertTo-Json -Depth 99
$result = Invoke-RestMethod -Method Post -Uri $uri -Body $body -Headers $header -ContentType 'application/json' 4>$Null
$allSubs = $result.data | ForEach-Object { [pscustomobject]@{displayName = $_.name; SubscriptionId = $_.subscriptionId } }
Set-Variable -Name subscriptionLookup -Value $($result.data | ForEach-Object { @{$_.subscriptionId = $_.name } })  -Option Constant

$token = Connect-AcquireToken -TokenResourceUrl $GraphResourceUrl
#$token = (Get-AzAccessToken -ResourceUrl $GraphResourceUrl).token
$header = @{Authorization = "Bearer $token" }
$uri = "$GraphResourceUrl/v1.0/organization/$tenantId"
$tenantResult = Invoke-RestMethod -Method Get -Uri $uri -Headers $header -ContentType 'application/json' 4>$Null
Set-Variable -Name tenantDisplayName -Value $($tenantResult.value.displayName) -Option Constant #$tenantResult.value.displayName

Set-Variable -Name WorkloadGroupsAndSubs -Value $(Get-WorkloadGroupsAndSubs -All) -Option Constant


#Region prepare info to log to Log Analytics for ATO compliance
$resourceGraphToken = Connect-AcquireToken -TokenResourceUrl $TokenResourceUrl
#$resourceGraphToken = (Get-AzAccessToken -ResourceUrl $TokenResourceUrl).Token
Set-Variable -Name workspaceId -Value $env:TenantMonitoringLogAnalyticsWorkspaceID -Option Constant
Set-Variable -Name AtoTableName -Value 'ATOData' -Option Constant
$LaSubscriptionId = $env:TenantMonitoringLogAnalyticsSubscriptionID
#get the LA workspace
#GET https://management.azure.com/subscriptions/{subscriptionId}/providers/Microsoft.OperationalInsights/workspaces?api-version=2023-09-01
$uri = "$TokenResourceUrl/subscriptions/$LaSubscriptionId/providers/Microsoft.OperationalInsights/workspaces?api-version=2023-09-01"
$temp = Invoke-DCMsGraphQuery -AccessToken $resourceGraphToken -GraphMethod Get -GraphUri $uri | where{$_.properties.customerId -eq $workspaceId}
Set-Variable -Name workspace -Value $temp -Option Constant
#Get the shared key
#POST https://management.azure.com/subscriptions/{subscriptionId}/resourcegroups/{resourceGroupName}/providers/Microsoft.OperationalInsights/workspaces/{workspaceName}/sharedKeys?api-version=2020-08-01
$uri = "$TokenResourceUrl/subscriptions/$LaSubscriptionId/resourcegroups/$($workspace.id.split('/')[4])/providers/Microsoft.OperationalInsights/workspaces/$($workspace.name)/sharedKeys?api-version=2020-08-01"
$temp = Invoke-DCMsGraphQuery -AccessToken $resourceGraphToken -GraphMethod Post -GraphUri $uri | select -ExpandProperty primarySharedKey
Set-Variable -Name sharedKey -Value $temp -Option Constant
Set-Variable -Name NoItemsFound -Value @{"NoItemsFound" = "No items found"} -Option Constant
#EndRegion prepare info to log to Log Analytics for ATO compliance

#Region Create Subscription to SSPID mapping
    # Get management groups
    #$WorkloadGroupsAndSubs = Get-WorkloadGroupsAndSubs
    $subIdToSSPIdTemp = @{}
    $subIdToSSPManagementGroupTemp = @{}
    # Get all subs
    ForEach($sub in $WorkloadGroupsAndSubs){
       
        #If($sub.ManagementGroupAncestorsChainDisplayName -like "Tenant Root Group\Enterprise Policy\Landing Zone*"){        #If the subs are under $landingZoneDisplayName ("Landing Zone") and which management group under "Landing Zone" they map to
        If($sub.isWorkloadSub){
            $subIdToSSPManagementGroupTemp += @{$($sub.subscriptionId) = $($sub.WorkloadManagementGroupDisplayName)}
            $subIdToSSPIdTemp += @{$($sub.subscriptionId) = $($sub.WorkloadManagementGroupId)}
        }ElseIf($sub.isPlatformSub){#$sub.ManagementGroupAncestorsChainDisplayName -like "Tenant Root Group\Enterprise Policy\Platform*"){        #ElseIf they're under "Platform", then return the "Platform" Id
            $subIdToSSPManagementGroupTemp += @{$($sub.subscriptionId) = $platformGroupDisplayName}#GetTenantDisplayName}
            $subIdToSSPIdTemp += @{$($sub.subscriptionId) = $($sub.ManagementGroupAncestorsChainId.split('\')[2])}
        }ElseIf($sub.isDeprovisionedSub){
            $subIdToSSPManagementGroupTemp += @{$($sub.subscriptionId) = $deprovisionedGroupDisplayName}
            $subIdToSSPIdTemp += @{$($sub.subscriptionId) = $($sub.ManagementGroupAncestorsChainId.split('\')[-1])}
        }
        Else{        #Else return an error string indicating the sub is not where it should be
            $subIdToSSPManagementGroupTemp += @{$($sub.subscriptionId) = 'NonCompliantManagementGroupConfiguration'}
            $subIdToSSPIdTemp += @{$($sub.subscriptionId) = 'NonCompliantManagementGroupConfiguration'}
        }
    }
    Set-Variable -Name SubIdToSSPId -Value $subIdToSSPIdTemp -Option Constant
    Set-Variable -Name SubIdToSSPManagementGroup -Value $subIdToSSPManagementGroupTemp -Option Constant

    Set-Variable -Name SubIdToSSP -Value $(GetSubscriptionsToReportOn | %{@{$_.subscriptionId = $_.SSP}}) -Option Constant
    Set-Variable -Name SSPsandSubs -Value $(Get-SSPsAndSubs -All) -Option Constant
#EndRegion Create Subscription to SSPID mapping

#Region Lookup table from Management Group ID to DisplayName
    $uri = "$TokenResourceUrl/providers/Microsoft.Management/managementGroups?api-version=2021-04-01"
    $result = Invoke-DCMsGraphQuery -AccessToken $resourceGraphToken -GraphMethod Get -GraphUri $uri
    Set-Variable -Name ManagementGroupIDToDisplayName -Value $($result | ForEach-Object { @{$_.name = $_.properties.displayName} }) -Option Constant
#EndRegion Lookup table from Management Group ID to DisplayName

#Region Azure Role Name to Display Name lookup
    $managementGroupId = $env:PolicyManagementGroupId
    $uri = "$TokenResourceUrl/providers/Microsoft.Management/managementGroups/$managementGroupId/providers/Microsoft.Authorization/roleDefinitions?api-version=2022-04-01"
    $result = Invoke-DCMsGraphQuery -AccessToken $resourceGraphToken -GraphMethod Get -GraphUri $uri
    Set-Variable -Name AzureRoleNameToDisplayName -Value $($result | ForEach-Object { @{$_.name = $_.properties.roleName} }) -Option Constant
#EndRegion Azure Role Name to Display Name lookup

Set-Variable -Name LandingZoneSSPID -Value ($ManagementGroupIDToDisplayName.keys | %{If($ManagementGroupIDToDisplayName.$_ -eq $landingZoneDisplayName){$_}}) -Option Constant

Set-Variable -Name snowResourceTypes -Value @('Microsoft.Compute/virtualMachines','Microsoft.Network/azureFirewalls',`
    'Microsoft.Network/applicationGatewayWebApplicationFirewallPolicies','Microsoft.Network/frontdoorWebApplicationFirewallPolicies',`
    'Microsoft.Cdn/CdnWebApplicationFirewallPolicies', 'Microsoft.Sql/servers','Microsoft.DBforPostgreSQL/servers',`
    'Microsoft.DBforMySQL/servers','Microsoft.DBforMariaDB/servers','Microsoft.Network/applicationGateways',`
    'Microsoft.Network/virtualNetworks/subnets','subscriptions', 'Microsoft.Storage/storageAccounts', 'Microsoft.KeyVault/vaults',`
    'Microsoft.Network/bastionHosts', 'microsoft.containerservice/managedclusters', 'Microsoft.Network/virtualNetworkGateways',`
    'Microsoft.RecoveryServices/vaults'
    ) -Option Constant
    #Keith wanted these removed as of 2/2024: 'Microsoft.DocumentDB/databaseAccounts', 'Microsoft.Web/serverFarms/functionapp','Microsoft.Web/sites/functionapp', 'Microsoft.Web/sites'
    #Keith wanted these removed as of 2/2025: 'Microsoft.Storage/storageAccounts', 'Microsoft.KeyVault/vaults', 'Microsoft.Network/bastionHosts', 'Microsoft.Network/expressRouteCircuits','Microsoft.Network/localNetworkGateways', 'Microsoft.RecoveryServices/vaults'

Set-Variable -Name 'TenantSSPName' -Value (gc 'C:\home\site\wwwroot\CreateEvidencePackage\EvidencePackageDefinition.json' | ConvertFrom-Json).TenantSSPName -Option Constant

Set-Variable -Name 'managementGroupIdToSSP' -Value $(Get-ManagementGroupsAndChildSubSSPs | %{@{$_.ResourceId = $_.SSPTag}}) -Option Constant
Set-Variable -Name 'subscriptionIdToSSP' -Value $(Get-SubscriptionsAndParentManagementGroupRest | %{@{$_.subscription = $_.SSPTag}}) -Option Constant

#EndRegion Useful Variables

<# Check all the functions in the function app and kinda sort them by schedule
$functionDefs = (ls function.json -Recurse).fullname
$functionDefs | %{$json = gc $_ | convertfrom-json -depth 99;$schedule = $json.bindings.schedule;[pscustomobject]@{'Function'=$_.split('\')[-2];'Schedule'=$schedule}} | sort schedule
#>