[CmdletBinding(SupportsShouldProcess = $true)]
param (
    # Agent Installation Parameters
    [Parameter(Mandatory = $false)]
    [string]$ApiVersion,
    
    [Parameter(Mandatory = $false)]
    [string]$StorageSuffix,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$RegistrationToken,
    
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$AgentBootLoaderUrl,
    
    [Parameter(Mandatory = $false)]
    [string]$AgentUrl,

    [Parameter(Mandatory = $false)]
    [string]$FallbackUrl,

    [Parameter(Mandatory = $false)]
    [ValidateSet('true', 'false', '')]
    [string]$AADJoin,

    [Parameter(Mandatory = $false)]
    [string]$MdmId,
    
    [Parameter(Mandatory = $false)]
    [string]$UserAssignedIdentityClientId,

    # Session Host Configuration Parameters
    [Parameter(Mandatory = $true)]
    [string]$TimeZone,

    [Parameter(Mandatory = $false)]
    [string]$AmdVmSize = 'false',

    [Parameter(Mandatory = $false)]
    [string]$NvidiaVmSize = 'false',

    [Parameter(Mandatory = $false)]
    [string]$DisableUpdates = 'false',

    [Parameter(Mandatory = $false)]
    [string]$ConfigureFSLogix = 'false',

    [Parameter(Mandatory = $false)]
    [string]$CloudCache = 'false',

    [Parameter(Mandatory = $false)]
    [string]$IdentitySolution = '',

    [Parameter(Mandatory = $false)]
    [string]$LocalNetAppServers = '[]',

    [Parameter(Mandatory = $false)]
    [string]$LocalStorageAccountNames = '[]',

    [Parameter(Mandatory = $false)]
    [string]$LocalStorageAccountKeys = '[]',

    [Parameter(Mandatory = $false)]
    [string]$OSSGroups = '[]',

    [Parameter(Mandatory = $false)]
    [string]$RemoteNetAppServers = '[]',

    [Parameter(Mandatory = $false)]
    [string]$RemoteStorageAccountNames = '[]',

    [Parameter(Mandatory = $false)]
    [string]$RemoteStorageAccountKeys = '[]',

    [Parameter(Mandatory = $false)]
    [string]$Shares = '[]',

    [Parameter(Mandatory = $false)]
    [string]$SizeInMBs = '30000',

    [Parameter(Mandatory = $false)]
    [string]$StorageService = ''
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12


$Script:Name = 'Initialize-SessionHost'
$Script:LogPath = Join-Path -Path $env:SystemRoot -ChildPath "Logs\$Script:Name.log"

# Convert string parameters to boolean for internal use
$AADJoinBool = if ([string]::IsNullOrEmpty($AADJoin)) { $false } else { [System.Convert]::ToBoolean($AADJoin) }

#region Helper Functions

function Write-Log {
    Param (
        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateSet("Info", "Warning", "Error")]
        $Category = 'Info',
        [Parameter(Mandatory = $true, Position = 1)]
        $Message
    )

    $DateTime = Get-Date -Format 'MM-dd-yyyy HH:mm:ss'
    $Content = "[$DateTime]`t$Category`t`t$Message`n" 
    Add-Content $Script:LogPath $content -ErrorAction Stop

    Switch ($Category) {
        'Info' { Write-Host $content }
        'Error' { Write-Error $Content }
        'Warning' { Write-Warning $Content }
    }
}

function Invoke-MsiWithRetry {
    param (
        [Parameter(Mandatory = $true)]
        [string]$DisplayName,
        
        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList,
        
        [Parameter(Mandatory = $true)]
        [string]$LogPath    
    )

    $ArgumentList += "/liwemo+! `"$LogPath`""
   
    $MaxRetries = 20
    $RetryDelay = 30
    $RetryCount = 0
    $ExitCode = $null
    
    do {        
        if ($RetryCount -gt 0) {
            Write-Log -Message "Retrying Install $DisplayName in $RetryDelay seconds (Exit code: $ExitCode) - Retry $RetryCount"
            Start-Sleep -Seconds $RetryDelay
        }
        Write-Log -Message "Installing $DisplayName"
        $Process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $ArgumentList -Wait -PassThru -NoNewWindow
        $ExitCode = $Process.ExitCode        
        $RetryCount++
    } while ($ExitCode -eq 1618 -and $RetryCount -lt $MaxRetries) # 1618 = ERROR_INSTALL_ALREADY_RUNNING
    
    if ($ExitCode -eq 1618) {
        $ErrorMsg = "Install $DisplayName failed after $MaxRetries retries with Exit code $ExitCode (ERROR_INSTALL_ALREADY_RUNNING)"
        Write-Log -Category Error -Message $ErrorMsg
        throw $ErrorMsg
    }
    
    Write-Log -Message "Install $DisplayName finished with Exit code: $ExitCode"
    
    # Exit codes: 0 = success, 3010 = success but restart required
    if ($ExitCode -notin @(0, 3010)) {
        Write-Log -Category Warning -Message "$DisplayName installation completed with Exit code: $ExitCode"
    }
    
    return $ExitCode
}

function Get-RegistrationTokenClaims {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Token
    )
    
    try {
        $ClaimsSection = $Token.Split('.')[1].Replace('-', '+').Replace('_', '/')
        
        # Pad with '=' to make it valid base64
        while ($ClaimsSection.Length % 4) {
            $ClaimsSection += '='
        }
        
        $ClaimsByteArray = [System.Convert]::FromBase64String($ClaimsSection)
        $ClaimsJson = [System.Text.Encoding]::ASCII.GetString($ClaimsByteArray)
        $Claims = $ClaimsJson | ConvertFrom-Json
        
        return $Claims
    }
    catch {
        Write-Log -Category Error -Message "Failed to parse registration token: $($_.Exception.Message)"
        throw
    }
}

function Get-AgentDownloadUrl {
    param (
        [Parameter(Mandatory = $true)]
        [string]$BrokerAgentApi
    )
    
    try {
        Write-Log -Message "Querying broker for agent download URL: $BrokerAgentApi"
        
        $Response = Invoke-WebRequest -Uri $BrokerAgentApi -UseBasicParsing
        $ResponseJson = $Response.Content | ConvertFrom-Json
        
        Write-Log -Message "Obtained agent endpoint: $($ResponseJson.agentEndpoint)"
        
        return $ResponseJson.agentEndpoint
    }
    catch {
        Write-Log -Category Error -Message "Failed to get agent download URL: $($_.Exception.Message)"
        return $null
    }
}

function Get-LatestAgentInstaller {
    param (
        [Parameter(Mandatory = $true)]
        [string]$RegistrationToken,
        
        [Parameter(Mandatory = $true)]
        [string]$DownloadFolder
    )
    
    try {
        # Parse the registration token to get broker endpoint
        $Claims = Get-RegistrationTokenClaims -Token $RegistrationToken
        
        if (-not $Claims.GlobalBrokerResourceIdUri) {
            Write-Log -Message "Unable to obtain broker endpoint from registration token"
            return $null
        }
        
        # Build the agent API URL
        $BrokerUri = [System.UriBuilder]$Claims.GlobalBrokerResourceIdUri
        $BrokerUri.Path = 'api/agentMsi/v1/agentVersion'
        $BrokerAgentApi = $BrokerUri.Uri.AbsoluteUri
        
        Write-Log -Message "Broker agent API: $BrokerAgentApi"
        
        # Get the agent download URL
        $AgentDownloadUrl = Get-AgentDownloadUrl -BrokerAgentApi $BrokerAgentApi
        
        if (-not $AgentDownloadUrl) {
            Write-Log -Message "Unable to obtain agent download URL from broker"
            return $null
        }
        
        # Create download folder
        if (-not (Test-Path $DownloadFolder)) {
            New-Item -Path $DownloadFolder -ItemType Directory -Force | Out-Null
        }
        
        $AgentPath = Join-Path $DownloadFolder 'RDAgent.msi'
        
        # Try primary endpoint
        try {
            Write-Log -Message "Downloading agent from: $AgentDownloadUrl"
            Invoke-WebRequest -Uri $AgentDownloadUrl -OutFile $AgentPath -UseBasicParsing
            Write-Log -Message "Successfully downloaded agent to: $AgentPath"
            return $AgentPath
        }
        catch {
            Write-Log -Message "Failed to download from primary endpoint: $($_.Exception.Message)"
        }
        
        # Try private link endpoint
        try {
            $PrivateLinkUri = [System.UriBuilder]$AgentDownloadUrl
            $PrivateLinkUri.Host = "$($Claims.EndpointPoolId).$($PrivateLinkUri.Host)"
            $PrivateLinkUrl = $PrivateLinkUri.Uri.AbsoluteUri
            
            Write-Log -Message "Trying private link endpoint: $PrivateLinkUrl"
            Invoke-WebRequest -Uri $PrivateLinkUrl -OutFile $AgentPath -UseBasicParsing
            Write-Log -Message "Successfully downloaded agent from private link endpoint"
            return $AgentPath
        }
        catch {
            Write-Log -Category Error -Message "Failed to download from private link endpoint: $($_.Exception.Message)"
        }
        
        return $null
    }
    catch {
        Write-Log -Category Error -Message "Error getting latest agent installer: $($_.Exception.Message)"
        return $null
    }
}

function Get-InstallerFromUrl {
    param (
        [string]$ApiVersion = $script:ApiVersion,
        [string]$StorageSuffix = $script:StorageSuffix,
        [string]$ClientId = $script:UserAssignedIdentityClientId,
        [string]$Url,
        [string]$DestinationPath,
        [string]$DisplayName
    )
    
    try {
        $WebClient = New-Object System.Net.WebClient
        
        # If URL is Azure Storage and we have a managed identity, authenticate
        if (-not [string]::IsNullOrEmpty($StorageSuffix) -and $Url -match $StorageSuffix -and -not [string]::IsNullOrEmpty($ClientId)) {
            Write-Log -Message "Authenticating to Azure Storage using managed identity"
            $StorageEndpoint = ($Url -split "://")[0] + "://" + ($Url -split "/")[2] + "/"
            $TokenUri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=$ApiVersion&resource=$StorageEndpoint&client_id=$ClientId"
            $AccessToken = ((Invoke-WebRequest -Headers @{Metadata = $true } -Uri $TokenUri -UseBasicParsing).Content | ConvertFrom-Json).access_token
            $WebClient.Headers.Add('x-ms-version', '2017-11-09')
            $WebClient.Headers.Add("Authorization", "Bearer $AccessToken")
        }

        Write-Log -Message "Downloading $DisplayName from: $Url"
        $WebClient.DownloadFile("$Url", "$DestinationPath")
        $WebClient = $null
        Write-Log -Message "Successfully downloaded $DisplayName to: $DestinationPath"
        return $true
    }
    catch {
        Write-Log -Category Error -Message "Failed to download $DisplayName : $($_.Exception.Message)"
        $WebClient = $null
        return $false
    }
}

function Wait-ForBootLoaderService {
    $ServiceName = 'RDAgentBootLoader'
    $MaxRetries = 6
    $RetryDelay = 30
    $RetryCount = 0
    
    while (-not (Get-Service $ServiceName -ErrorAction SilentlyContinue)) {
        if ($RetryCount -ge $MaxRetries) {
            $ErrorMsg = "Service $ServiceName not found after $MaxRetries retries"
            Write-Log -Category Error -Message $ErrorMsg
            throw $ErrorMsg
        }
        
        Write-Log -Message "Service $ServiceName not found. Retrying in $RetryDelay seconds (Retry $RetryCount of $MaxRetries)"
        Start-Sleep -Seconds $RetryDelay
        $RetryCount++
    }
    
    Write-Log -Message "Starting service: $ServiceName"
    Start-Service $ServiceName
    
    Write-Log -Message "Service $ServiceName started successfully"
}

function Get-SessionHostName {
    $Wmi = Get-WmiObject win32_computersystem
    
    if ($Wmi.Domain -eq 'WORKGROUP') {
        return $Wmi.DNSHostName
    }
    
    return "$($Wmi.DNSHostName).$($Wmi.Domain)"
}

Function ConvertFrom-JsonString {
    [CmdletBinding()]
    param (
        [string]$JsonString,
        [string]$Name,
        [switch]$SensitiveValues      
    )
    If ($JsonString -ne '[]' -and $null -ne $JsonString) {
        [array]$Array = $JsonString.replace('\', '') | ConvertFrom-Json
        If ($Array.Length -gt 0) {
            If ($SensitiveValues) { Write-Log -message "Array '$Name' has $($Array.Length) members" } Else { Write-Log -message "$($Name): '$($Array -join "', '")'" }
            Return $Array
        }
        Else {
            Return $null
        }            
    }
    Else {
        Return $null
    }    
}

Function Convert-GroupToSID {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)]
        [string]$DomainName,

        [Parameter(Mandatory = $true)]
        [string]$GroupName
    )
    Begin {
        [string]$groupSID = ''
    }
    Process {
        Try {
            $groupSID = (New-Object System.Security.Principal.NTAccount("$GroupName")).Translate([System.Security.Principal.SecurityIdentifier]).Value
        }
        Catch {
            Try {
                $groupSID = (New-Object System.Security.Principal.NTAccount($DomainName, "$GroupName")).Translate([System.Security.Principal.SecurityIdentifier]).Value
            }
            Catch {
                Write-Error -Message "Failed to convert group name '$GroupName' to SID."
            }
        }
        Write-Output -InputObject $groupSID
    }
}

Function Set-RegistryValue {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]$Name,
        [Parameter()]
        [string]$Path,
        [Parameter()]
        [string]$PropertyType,
        [Parameter()]
        $Value
    )
    If (!(Test-Path -Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    $RemoteValue = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    If ($RemoteValue) {
        $CurrentValue = Get-ItemPropertyValue -Path $Path -Name $Name
        If ($Value -ne $CurrentValue) {
            Write-Log -message "Registry update: $Name = $Value (was: $CurrentValue)"
            Set-ItemProperty -Path $Path -Name $Name -Value $Value -Force | Out-Null
        }
    }
    Else {
        Write-Log -message "Registry create: $Name = $Value"
        New-ItemProperty -Path $Path -Name $Name -PropertyType $PropertyType -Value $Value -Force | Out-Null
    }
    Start-Sleep -Milliseconds 500
}

function Get-AgentInstallersFromFallbackUrl {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FallbackUrl,
        
        [Parameter(Mandatory = $true)]
        [string]$DownloadFolder
    )
    
    try {
        Write-Log -Message "Extracting agent installers from fallback URL: $FallbackUrl"
        
        # Create fallback extraction location
        $FallbackExtractPath = Join-Path -Path $DownloadFolder -ChildPath 'FallbackExtract'
        New-Item -Path $FallbackExtractPath -ItemType Directory -Force | Out-Null
        
        # Download and extract configuration.zip
        $ConfigZipPath = Join-Path -Path $FallbackExtractPath -ChildPath 'configuration.zip'
        $Success = Get-InstallerFromUrl -Url $FallbackUrl -DestinationPath $ConfigZipPath -DisplayName 'Configuration Package'
        
        if (-not $Success) {
            Write-Log -Category Error -Message "Failed to download configuration.zip from: $FallbackUrl"
            return $null
        }
        
        $ConfigExtractPath = Join-Path -Path $FallbackExtractPath -ChildPath 'ConfigExtracted'
        Expand-Archive -Path $ConfigZipPath -DestinationPath $ConfigExtractPath -Force
        
        # Look for DeployAgent.zip inside the extracted configuration
        $DeployAgentZip = Get-ChildItem -Path $ConfigExtractPath -Filter 'DeployAgent.zip' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        
        if (-not $DeployAgentZip) {
            Write-Log -Category Error -Message "DeployAgent.zip not found in configuration.zip"
            return $null
        }
        
        $DeployAgentExtractPath = Join-Path -Path $FallbackExtractPath -ChildPath 'DeployAgent'
        Expand-Archive -Path $DeployAgentZip.FullName -DestinationPath $DeployAgentExtractPath -Force
        
        # Locate the MSI files
        $BootLoaderMsi = Get-ChildItem -Path $DeployAgentExtractPath -Filter '*.msi' -Recurse | Where-Object { $_.Name -like '*BootLoader*' -or $_.Directory.Name -like '*BootLoader*' } | Select-Object -First 1
        $AgentMsi = Get-ChildItem -Path $DeployAgentExtractPath -Filter '*.msi' -Recurse | Where-Object { $_.Name -notlike '*BootLoader*' -and $_.Directory.Name -notlike '*BootLoader*' -and ($_.Name -like '*Agent*' -or $_.Directory.Name -like '*Agent*') } | Select-Object -First 1
        
        if (-not $BootLoaderMsi) {
            Write-Log -Category Error -Message "RDAgentBootLoader MSI not found in DeployAgent.zip"
            return $null
        }
        
        if (-not $AgentMsi) {
            Write-Log -Category Error -Message "RDAgent MSI not found in DeployAgent.zip"
            return $null
        }
        
        # Copy MSIs to download folder for installation
        $BootLoaderDestination = Join-Path -Path $DownloadFolder -ChildPath 'RDAgentBootLoader.msi'
        $AgentDestination = Join-Path -Path $DownloadFolder -ChildPath 'RDAgent.msi'
        
        Copy-Item -Path $BootLoaderMsi.FullName -Destination $BootLoaderDestination -Force
        Copy-Item -Path $AgentMsi.FullName -Destination $AgentDestination -Force
        
        # Clean up extraction folder
        try {
            Remove-Item -Path $FallbackExtractPath -Force -Recurse -ErrorAction SilentlyContinue
        }
        catch {
            Write-Log -Category Warning -Message "Failed to clean up fallback extract folder: $($_.Exception.Message)"
        }
        
        return @{
            AgentPath = $AgentDestination
            BootLoaderPath = $BootLoaderDestination
        }
    }
    catch {
        Write-Log -Category Error -Message "Failed to extract agent installers from fallback URL: $($_.Exception.Message)"
        Write-Log -Category Error -Message "Stack trace: $($_.ScriptStackTrace)"
        return $null
    }
}

#endregion Helper Functions

#region FSLogix Redirections XML Templates

$redirectionsXMLStart = @'
<?xml version="1.0" encoding="UTF-8"?>
<FrxProfileFolderRedirection ExcludeCommonFolders="0">
<Excludes>
'@

$redirectionsXMLExcludesTeams = @'
<Exclude Copy="0">AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Logs</Exclude>
<Exclude Copy="0">AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\PerfLog</Exclude>
<Exclude Copy="0">AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\WV2Profile_tfw\GPUCache</Exclude>
<Exclude Copy="0">AppData\Local\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\TempState</Exclude>
'@

$redirectionsXMLExcludesAzCLI = @'
<Exclude Copy="0">.Azure</Exclude>
'@

$redirectionsXMLEnd = @'
</Excludes>
<Includes>
</Includes>
</FrxProfileFolderRedirection>
'@

#endregion FSLogix Redirections XML Templates

#region Main Script

try {
    Write-Log -Message '========================================='
    Write-Log -Message 'AVD Session Host Initialization Starting'
    Write-Log -Message '========================================='
    
    Write-Log -Message "TimeZone=$TimeZone | ConfigureFSLogix=$ConfigureFSLogix | DisableUpdates=$DisableUpdates | AmdVmSize=$AmdVmSize | NvidiaVmSize=$NvidiaVmSize"
    Write-Log -Message "AADJoin=$AADJoin | AgentBootLoaderUrl=$AgentBootLoaderUrl$(if ($AgentUrl) { " | AgentUrl=$AgentUrl" })$(if ($MdmId) { " | MdmId=$MdmId" })"
    
    #region Phase 1: Session Host Configuration
    
    Write-Log -Message ''
    Write-Log -Message '========================================='
    Write-Log -Message 'Phase 1: Session Host Configuration'
    Write-Log -Message '========================================='
    
    # Configure Time Zone
    Set-TimeZone -Id "$TimeZone"
    Write-Log -Message "Time Zone set to: $TimeZone"
    
    # Initialize registry settings array
    $RegSettings = New-Object System.Collections.ArrayList
    
    # Convert boolean parameters
    [bool]$ConfigureFSLogixBool = [System.Convert]::ToBoolean($ConfigureFSLogix)
    
    # Disable Updates if specified
    If ($DisableUpdates -eq 'true') {
        Write-Log -Message "Adding registry settings to disable automatic updates"
        # Disable Automatic Updates
        $RegSettings.Add(@{Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; Name = 'NoAutoUpdate'; PropertyType = 'DWORD'; Value = 1 })
        # Disable Edge Updates
        $RegSettings.Add(@{Path = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'; Name = 'UpdateDefault'; PropertyType = 'DWORD'; Value = 0 })
        # Set the OneDrive Update Ring to Deferred
        $RegSettings.Add(@{Path = 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive'; Name = 'GPOSetUpdateRing'; PropertyType = 'DWORD'; Value = 0 })
        
        If (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'Microsoft 365 Apps' } | Select-Object -First 1) {
            Write-Log -Message "Microsoft 365 Apps detected, disabling Office updates"
            $RegSettings.Add(@{Path = 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate'; Name = 'hideupdatenotifications'; PropertyType = 'DWORD'; Value = 1 })
            $RegSettings.Add(@{Path = 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate'; Name = 'hideenabledisableupdates'; PropertyType = 'DWORD'; Value = 1 })
        }
        
        $TeamsInstalled = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq 'MSTeams' }
        If ($TeamsInstalled) {
            Write-Log -Message "Teams detected, disabling Teams auto-update"
            $RegSettings.Add(@{Path = 'HKLM:\SOFTWARE\Microsoft\Teams'; Name = 'disableAutoUpdate'; PropertyType = 'DWORD'; Value = 1 })
        }
    }
    
    # Enable Time Zone Redirection
    $RegSettings.Add(@{Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'; Name = 'fEnableTimeZoneRedirection'; PropertyType = 'DWORD'; Value = 1 })
    
    # Add GPU Settings if applicable
    if ($AmdVmSize -eq 'true' -or $NvidiaVmSize -eq 'true') {
        Write-Log -Message "Adding GPU Settings"
        $RegSettings.Add(@{Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'; Name = 'bEnumerateHWBeforeSW'; PropertyType = 'DWORD'; Value = 1 })
        $RegSettings.Add(@{Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'; Name = 'AVC444ModePreferred'; PropertyType = 'DWORD'; Value = 1 })
    }
    
    if ($NvidiaVmSize -eq 'true') {
        Write-Log -Message "Adding Nvidia GPU Settings"
        $RegSettings.Add(@{Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'; Name = 'AVChardwareEncodePreferred'; PropertyType = 'DWORD'; Value = 1 })
    }
    
    # Configure FSLogix if specified
    If ($ConfigureFSLogixBool) {
        Write-Log -Message ''
        Write-Log -Message 'Configuring FSLogix'
        Write-Log -Message "IdentitySolution: $IdentitySolution"
        
        # Convert parameters
        $CloudCacheBool = [System.Convert]::ToBoolean($CloudCache)
        Write-Log -Message "CloudCache: $CloudCacheBool"
        
        [array]$SharesArray = ConvertFrom-JsonString -JsonString $Shares -Name 'Shares'
        $ProfileShareName = $SharesArray[0]
        if ($SharesArray.Count -gt 1) {
            $OfficeShareName = $SharesArray[1]
        }
        Else {
            $OfficeShareName = $null
        }
        
        Write-Log -message "ProfileShareName: $ProfileShareName"
        Write-Log -message "OfficeShareName: $OfficeShareName"
        Write-Log -message "StorageService: $StorageService"
        
        if ($SizeInMBs -ne '' -and $null -ne $SizeInMBs) {
            [int]$SizeInMBsInt = $SizeInMBs
            Write-Log -message "SizeInMBs: $SizeInMBsInt"
        }
        Else {
            [int]$SizeInMBsInt = 30000
            Write-Log -message "SizeInMBs not specified. Defaulting to: $SizeInMBsInt"
        }
        
        $AzCLIInstalled = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'Azure CLI' } | Select-Object -First 1
        $TeamsInstalled = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq 'MSTeams' }
        
        # Create Array Lists for storage paths
        [System.Collections.ArrayList]$LocalProfileContainerPaths = @()
        [System.Collections.ArrayList]$LocalCloudCacheProfileContainerPaths = @()
        [System.Collections.ArrayList]$LocalOfficeContainerPaths = @()
        [System.Collections.ArrayList]$LocalCloudCacheOfficeContainerPaths = @()
        [System.Collections.ArrayList]$RemoteProfileContainerPaths = @()
        [System.Collections.ArrayList]$RemoteCloudCacheProfileContainerPaths = @()
        [System.Collections.ArrayList]$RemoteOfficeContainerPaths = @()
        [System.Collections.ArrayList]$RemoteCloudCacheOfficeContainerPaths = @()
        
        # Process storage accounts based on service type
        switch ($StorageService) {
            'AzureFiles' {
                Write-Log -message "Gathering Azure Files Storage Account Parameters"
                [array]$OSSGroupsArray = ConvertFrom-JsonString -JsonString $OSSGroups -Name 'OSSGroups'
                [array]$LocalStorageAccountNamesArray = ConvertFrom-JsonString -JsonString $LocalStorageAccountNames -Name 'LocalStorageAccountNames'
                [array]$LocalStorageAccountKeysArray = ConvertFrom-JsonString -JsonString $LocalStorageAccountKeys -Name 'LocalStorageAccountKeys' -SensitiveValues
                [array]$RemoteStorageAccountNamesArray = ConvertFrom-JsonString -JsonString $RemoteStorageAccountNames -Name 'RemoteStorageAccountNames'
                [array]$RemoteStorageAccountKeysArray = ConvertFrom-JsonString -JsonString $RemoteStorageAccountKeys -Name 'RemoteStorageAccountKeys' -SensitiveValues
                
                # Process Local Storage Accounts
                Write-Log -message "Processing Local Storage Accounts"
                For ($i = 0; $i -lt $LocalStorageAccountNamesArray.Count; $i++) {
                    $SAFQDN = "$($LocalStorageAccountNamesArray[$i]).file.$StorageSuffix"
                    Write-Log -message "Local storage [$i]: $SAFQDN"
                    
                    If ($LocalStorageAccountKeysArray.Count -gt 0 -and $LocalStorageAccountKeysArray[$i]) {
                        Write-Log -message "Adding storage key for '$SAFQDN' to Credential Manager"
                        Start-Process -FilePath 'cmdkey.exe' -ArgumentList "/add:$SAFQDN /user:localhost\$($LocalStorageAccountNamesArray[$i]) /pass:$($LocalStorageAccountKeysArray[$i])" -NoNewWindow -Wait
                    }
                    
                    If ($OfficeShareName) {
                        $LocalOfficeContainerPaths.Add("\\$SAFQDN\$OfficeShareName") | Out-Null
                        $LocalCloudCacheOfficeContainerPaths.Add("type=smb,connectionString=\\$($SAFQDN)\$($OfficeShareName)") | Out-Null
                    }
                    $LocalProfileContainerPaths.Add("\\$($SAFQDN)\$($ProfileShareName)") | Out-Null
                    $LocalCloudCacheProfileContainerPaths.Add("type=smb,connectionString=\\$($SAFQDN)\$($ProfileShareName)") | Out-Null
                }
                
                # Process Remote Storage Accounts
                If ($RemoteStorageAccountNamesArray.Count -gt 0) {
                    Write-Log -message "Processing Remote Storage Accounts"
                    For ($i = 0; $i -lt $RemoteStorageAccountNamesArray.Count; $i++) {
                        $SAFQDN = "$($RemoteStorageAccountNamesArray[$i]).file.$StorageSuffix"
                        Write-Log -message "Remote storage [$i]: $SAFQDN"
                        
                        If ($RemoteStorageAccountKeysArray.Count -gt 0 -and $RemoteStorageAccountKeysArray[$i]) {
                            Write-Log -message "Adding storage key for '$SAFQDN' to Credential Manager"
                            Start-Process -FilePath 'cmdkey.exe' -ArgumentList "/add:$($SAFQDN) /user:localhost\$($RemoteStorageAccountNamesArray[$i]) /pass:$($RemoteStorageAccountKeysArray[$i])" -NoNewWindow -Wait
                        }
                        
                        If ($OfficeShareName) {
                            $RemoteOfficeContainerPaths.Add("\\$($SAFQDN)\$($OfficeShareName)") | Out-Null
                            $RemoteCloudCacheOfficeContainerPaths.Add("type=smb,connectionString=\\$($SAFQDN)\$($OfficeShareName)") | Out-Null
                        }
                        $RemoteProfileContainerPaths.Add("\\$($SAFQDN)\$($ProfileShareName)") | Out-Null
                        $RemoteCloudCacheProfileContainerPaths.Add("type=smb,connectionString=\\$($SAFQDN)\$($ProfileShareName)") | Out-Null
                    }
                }
            }
            'AzureNetAppFiles' {
                Write-Log -message "Gathering Azure NetApp Files Storage Account Parameters"
                [array]$LocalNetAppServersArray = ConvertFrom-JsonString -JsonString $LocalNetAppServers -Name 'LocalNetAppServers'
                [array]$RemoteNetAppServersArray = ConvertFrom-JsonString -JsonString $RemoteNetAppServers -Name 'RemoteNetAppServers'
                
                Write-Log -message "Local NetApp: $($LocalNetAppServersArray[0])"
                $LocalProfileContainerPaths.Add("\\$($LocalNetAppServersArray[0])\$($ProfileShareName)") | Out-Null
                $LocalCloudCacheProfileContainerPaths.Add("type=smb,connectionString=\\$($LocalNetAppServersArray[0])\$($ProfileShareName)") | Out-Null
                
                If ($LocalNetAppServersArray.Length -gt 1 -and $OfficeShareName) {            
                    $LocalOfficeContainerPaths.Add("\\$($LocalNetAppServersArray[1])\$($OfficeShareName)") | Out-Null
                    $LocalCloudCacheOfficeContainerPaths.Add("type=smb,connectionString=\\$($LocalNetAppServersArray[1])\$($OfficeShareName)") | Out-Null
                }
                
                If ($RemoteNetAppServersArray.Count -gt 0) {
                    Write-Log -message "Remote NetApp: $($RemoteNetAppServersArray[0])"
                    $RemoteProfileContainerPaths.Add("\\$($RemoteNetAppServersArray[0])\$($ProfileShareName)") | Out-Null
                    $RemoteCloudCacheProfileContainerPaths.Add("type=smb,connectionString=\\$($RemoteNetAppServersArray[0])\$($ProfileShareName)") | Out-Null
                    
                    If ($RemoteNetAppServersArray.Length -gt 1 -and $OfficeShareName) {
                        $RemoteOfficeContainerPaths.Add("\\$($RemoteNetAppServersArray[1])\$($OfficeShareName)") | Out-Null
                        $RemoteCloudCacheOfficeContainerPaths.Add("type=smb,connectionString=\\$($RemoteNetAppServersArray[1])\$($OfficeShareName)") | Out-Null
                    }        
                }
            }
        }
        
        # Add Common FSLogix Registry Settings
        $RegSettings.Add([PSCustomObject]@{ Name = 'CleanupInvalidSessions'; Path = 'HKLM:\SOFTWARE\FSLogix\Apps'; PropertyType = 'DWord'; Value = 1 })
        $RegSettings.Add([PSCustomObject]@{ Name = 'Enabled'; Path = 'HKLM:\SOFTWARE\Fslogix\Profiles'; PropertyType = 'DWord'; Value = 1 })
        $RegSettings.Add([PSCustomObject]@{ Name = 'DeleteLocalProfileWhenVHDShouldApply'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'DWord'; Value = 1 })
        $RegSettings.Add([PSCustomObject]@{ Name = 'FlipFlopProfileDirectoryName'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'DWord'; Value = 1 })
        $RegSettings.Add([PSCustomObject]@{ Name = 'PreventLoginWithFailure'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'DWord'; Value = 1 })
        $RegSettings.Add([PSCustomObject]@{ Name = 'PreventLoginWithTempProfile'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'DWord'; Value = 1 })
        $RegSettings.Add([PSCustomObject]@{ Name = 'ReAttachIntervalSeconds'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'DWord'; Value = 15 })
        $RegSettings.Add([PSCustomObject]@{ Name = 'ReAttachRetryCount'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'DWord'; Value = 3 })
        $RegSettings.Add([PSCustomObject]@{ Name = 'SizeInMBs'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'DWord'; Value = $SizeInMBsInt })
        $RegSettings.Add([PSCustomObject]@{ Name = 'VolumeType'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'String'; Value = 'VHDX' })
        
        If ($LocalStorageAccountKeysArray.Count -gt 0) {
            $RegSettings.Add([PSCustomObject]@{Name = 'AccessNetworkAsComputerObject'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'DWord'; Value = 1 })
        }
        
        if ($CloudCacheBool -eq $True) {
            $RegSettings.Add([PSCustomObject]@{ Name = 'ClearCacheOnLogoff'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'DWord'; Value = 1 })
        }
        
        # Office Container Settings
        If ($LocalOfficeContainerPaths.Count -gt 0) {
            $RegSettings.Add([PSCustomObject]@{ Name = 'Enabled'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'DWord'; Value = 1 })   
            $RegSettings.Add([PSCustomObject]@{ Name = 'FlipFlopProfileDirectoryName'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'DWord'; Value = 1 })
            $RegSettings.Add([PSCustomObject]@{ Name = 'LockedRetryCount'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'DWord'; Value = 3 })
            $RegSettings.Add([PSCustomObject]@{ Name = 'LockedRetryInterval'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'DWord'; Value = 15 })
            $RegSettings.Add([PSCustomObject]@{ Name = 'PreventLoginWithFailure'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'DWord'; Value = 1 })
            $RegSettings.Add([PSCustomObject]@{ Name = 'PreventLoginWithTempProfile'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'DWord'; Value = 1 })    
            $RegSettings.Add([PSCustomObject]@{ Name = 'ReAttachIntervalSeconds'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'DWord'; Value = 15 })
            $RegSettings.Add([PSCustomObject]@{ Name = 'ReAttachRetryCount'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'DWord'; Value = 3 })
            $RegSettings.Add([PSCustomObject]@{ Name = 'SizeInMBs'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'DWord'; Value = $SizeInMBsInt })
            $RegSettings.Add([PSCustomObject]@{ Name = 'VolumeType'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'String'; Value = 'VHDX' })
            
            If ($LocalStorageAccountKeysArray.Count -gt 0) {
                $RegSettings.Add([PSCustomObject]@{ Name = 'AccessNetworkAsComputerObject'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'DWord'; Value = 1 })
            }
            
            If ($CloudCacheBool -eq $True) {
                $RegSettings.Add([PSCustomObject]@{ Name = 'ClearCacheOnLogoff'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'DWord'; Value = 1 })
            }   
        }
        
        # Object Specific Settings or Standard VHDLocations/CCDLocations
        If ($OSSGroupsArray.Count -gt 0) {
            Write-Log -message "Adding Object Specific Settings"
            $DomainName = Get-CimInstance -ClassName Win32_ComputerSystem | Select-Object -ExpandProperty Domain
            Write-Log -message "DomainName: $DomainName"
            
            For ($i = 0; $i -lt $OSSGroupsArray.Count; $i++) {
                Write-Log -message "Getting SID for $($OSSGroupsArray[$i])"        
                $OSSGroupSID = Convert-GroupToSID -DomainName $DomainName -GroupName $OSSGroupsArray[$i]
                [string]$LocalProfileContainerPath = $LocalProfileContainerPaths[$i]
                [string]$LocalCloudCacheProfileContainerPath = $LocalCloudCacheProfileContainerPaths[$i]

                If ($RemoteStorageAccountNamesArray) {
                    [string]$RemoteProfileContainerPath = $RemoteProfileContainerPaths[$i]
                    [string]$RemoteCloudCacheProfileContainerPath = $RemoteCloudCacheProfileContainerPaths[$i]
                    [array]$ProfileContainerPathsForGroup = @($LocalProfileContainerPath, $RemoteProfileContainerPath)
                    [array]$CloudCacheProfileContainerPathsForGroup = @($LocalCloudCacheProfileContainerPath, $RemoteCloudCacheProfileContainerPath)
                }
                Else {
                    [array]$ProfileContainerPathsForGroup = @($LocalProfileContainerPath)
                    [array]$CloudCacheProfileContainerPathsForGroup = @($LocalCloudCacheProfileContainerPath)
                }

                If ($CloudCacheBool -eq $True) {
                    Write-Log -message "Adding Cloud Cache Profile Container Settings: $OSSGroupSID : '$($CloudCacheProfileContainerPathsForGroup -join "', '")'"
                    $RegSettings.Add([PSCustomObject]@{ Name = 'CCDLocations'; Path = "HKLM:\SOFTWARE\FSLogix\Profiles\ObjectSpecific\$OSSGroupSID"; PropertyType = 'MultiString'; Value = $CloudCacheProfileContainerPathsForGroup })
                }
                Else {
                    Write-Log -message "Adding Profile Container Settings: $OSSGroupSID : '$($ProfileContainerPathsForGroup -join "', '")'"
                    $RegSettings.Add([PSCustomObject]@{ Name = 'VHDLocations'; Path = "HKLM:\SOFTWARE\FSLogix\Profiles\ObjectSpecific\$OSSGroupSID"; PropertyType = 'MultiString'; Value = $ProfileContainerPathsForGroup })
                }   

                If ($LocalOfficeContainerPaths.Count -gt 0) {
                    [string]$LocalOfficeContainerPath = $LocalOfficeContainerPaths[$i]
                    [string]$LocalCloudCacheOfficeContainerPath = $LocalCloudCacheOfficeContainerPaths[$i]
                    
                    If ($RemoteStorageAccountNamesArray) {
                        [string]$RemoteOfficeContainerPath = $RemoteOfficeContainerPaths[$i]
                        [string]$RemoteCloudCacheOfficeContainerPath = $RemoteCloudCacheOfficeContainerPaths[$i]
                        [array]$OfficeContainerPathsForGroup = @($LocalOfficeContainerPath, $RemoteOfficeContainerPath)
                        [array]$CloudCacheOfficeContainerPathsForGroup = @($LocalCloudCacheOfficeContainerPath, $RemoteCloudCacheOfficeContainerPath)
                    }
                    Else {
                        [array]$OfficeContainerPathsForGroup = @($LocalOfficeContainerPath)
                        [array]$CloudCacheOfficeContainerPathsForGroup = @($LocalCloudCacheOfficeContainerPath)
                    }
                    
                    If ($CloudCacheBool -eq $True) {
                        Write-Log -message "Adding Cloud Cache Office Container Settings: $OSSGroupSID : '$($CloudCacheOfficeContainerPathsForGroup -join "', '")'"
                        $RegSettings.Add([PSCustomObject]@{ Name = 'CCDLocations'; Path = "HKLM:\SOFTWARE\Policies\FSLogix\ODFC\ObjectSpecific\$OSSGroupSID"; PropertyType = 'MultiString'; Value = $CloudCacheOfficeContainerPathsForGroup })
                    }
                    Else {
                        Write-Log -message "Adding Office Container Settings: $OSSGroupSID : '$($OfficeContainerPathsForGroup -join "', '")'"
                        $RegSettings.Add([PSCustomObject]@{ Name = 'VHDLocations'; Path = "HKLM:\SOFTWARE\Policies\FSLogix\ODFC\ObjectSpecific\$OSSGroupSID"; PropertyType = 'MultiString'; Value = $OfficeContainerPathsForGroup })
                    }
                }  
            }          
        }
        Else {
            # No OSS Groups, use standard VHDLocations/CCDLocations
            If ($RemoteStorageAccountNamesArray.Count -gt 0) {
                $ProfileContainerPaths = $LocalProfileContainerPaths + $RemoteProfileContainerPaths
                $CloudCacheProfileContainerPaths = $LocalCloudCacheProfileContainerPaths + $RemoteCloudCacheProfileContainerPaths
            }
            Else {
                $ProfileContainerPaths = $LocalProfileContainerPaths
                $CloudCacheProfileContainerPaths = $LocalCloudCacheProfileContainerPaths
            }
            
            If ($CloudCacheBool -eq $True) {
                Write-Log -message "Adding Cloud Cache Profile Container Settings: '$($CloudCacheProfileContainerPaths -join "', '")'"   
                $RegSettings.Add([PSCustomObject]@{ Name = 'CCDLocations'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'MultiString'; Value = $CloudCacheProfileContainerPaths })             
            }
            Else {
                Write-Log -message "Adding Profile Container Settings: '$($ProfileContainerPaths -join "', '")'"
                $RegSettings.Add([PSCustomObject]@{ Name = 'VHDLocations'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'MultiString'; Value = $ProfileContainerPaths })
            }
            
            If ($LocalOfficeContainerPaths.Count -gt 0) {
                If ($RemoteStorageAccountNamesArray.Count -gt 0) {
                    $OfficeContainerPaths = $LocalOfficeContainerPaths + $RemoteOfficeContainerPaths
                    $CloudCacheOfficeContainerPaths = $LocalCloudCacheOfficeContainerPaths + $RemoteCloudCacheOfficeContainerPaths
                }
                Else {
                    $OfficeContainerPaths = $LocalOfficeContainerPaths
                    $CloudCacheOfficeContainerPaths = $LocalCloudCacheOfficeContainerPaths
                }
                
                If ($CloudCacheBool -eq $True) {
                    Write-Log -message "Adding Cloud Cache Office Container Settings: '$($CloudCacheOfficeContainerPaths -join "', '")'"
                    $RegSettings.Add([PSCustomObject]@{ Name = 'CCDLocations'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'MultiString'; Value = $CloudCacheOfficeContainerPaths })
                }
                Else {
                    Write-Log -message "Adding Office Container Settings: '$($OfficeContainerPaths -join "', '")'"
                    $RegSettings.Add([PSCustomObject]@{ Name = 'VHDLocations'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'MultiString'; Value = $OfficeContainerPaths })
                }
            }    
        }
        
        # FSLogix Redirections for Teams and Az CLI
        If ($TeamsInstalled -or $AzCLIInstalled) {
            $customRedirFolder = "$env:ProgramData\FSLogix_CustomRedirections"
            Write-Log -message "Creating custom redirections.xml file in $customRedirFolder"
            If (-not (Test-Path $customRedirFolder )) {
                New-Item -Path $customRedirFolder -ItemType Directory -Force | Out-Null
            }
            $customRedirFilePath = "$customRedirFolder\redirections.xml"
            $redirectionsXMLContent = $redirectionsXMLStart
            if ($AzCLIInstalled) {
                $redirectionsXMLContent = $redirectionsXMLContent + "`n" + $redirectionsXMLExcludesAzCLI
            }
            if ($TeamsInstalled) {
                $redirectionsXMLContent = $redirectionsXMLContent + "`n" + $redirectionsXMLExcludesTeams
            }
            $redirectionsXMLContent = $redirectionsXMLContent + "`n" + $redirectionsXMLEnd
            $redirectionsXMLContent | Out-File -FilePath $customRedirFilePath -Encoding unicode
            
            $RegSettings.Add([PSCustomObject]@{ Name = 'RedirXMLSourceFolder'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'String'; Value = $customRedirFolder })
        }
        
        # Entra Kerberos Cloud Kerberos Ticket Retrieval
        If ($IdentitySolution -match 'EntraKerberos') {
            Write-Log -message "Adding Entra Kerberos Cloud Kerberos Ticket Retrieval Setting"
            $RegSettings.Add([PSCustomObject]@{ Name = 'CloudKerberosTicketRetrievalEnabled'; Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters'; PropertyType = 'DWord'; Value = 1 })
        }

        # Windows Defender Exclusions for FSLogix
        $LocalPathExclusions = @(
            "$env:ProgramData\FSLogix",
            "$env:ProgramData\FSLogix\Cache",
            "$env:ProgramData\FSLogix\Proxy",
            "$env:ProgramFiles\FSLogix\Apps",
            "$env:SystemDrive\Users\*\AppData\Local\FSLogix",
            "$env:SystemRoot\Temp\*\*.vhdx",
            "$env:SystemDrive\users\*\AppData\Local\Temp\*.vhdx"
        )
        
        # Build UNC Path Exclusions from storage account paths
        $UncPathExclusions = @()
        $UncPathExclusions += $LocalProfileContainerPaths | ForEach-Object { "$_\*\*.vhdx" }
        $UncPathExclusions += $LocalOfficeContainerPaths | ForEach-Object { "$_\*\*.vhdx" }
        $UncPathExclusions += $RemoteProfileContainerPaths | ForEach-Object { "$_\*\*.vhdx" }
        $UncPathExclusions += $RemoteOfficeContainerPaths | ForEach-Object { "$_\*\*.vhdx" }
        $UncPathExclusions = $UncPathExclusions | Where-Object { $_ }

        $PathExclusions = $LocalPathExclusions + $UncPathExclusions

        $ProcessExclusions = @(
            "$env:ProgramFiles\FSLogix\Apps\frxsvc.exe",
            "$env:ProgramFiles\FSLogix\Apps\frxccds.exe",
            "$env:ProgramFiles\FSLogix\Apps\frxdrv.sys",
            "$env:ProgramFiles\FSLogix\Apps\frxdrvvt.sys",
            "$env:ProgramFiles\FSLogix\Apps\frxccd.sys"
        )

        Try {
            ForEach ($Path in $PathExclusions) {
                Add-MpPreference -ExclusionPath $Path -ErrorAction SilentlyContinue
            }
            ForEach ($Process in $ProcessExclusions) {
                Add-MpPreference -ExclusionProcess $Process -ErrorAction SilentlyContinue
            }
            Write-Log -message "Added $($PathExclusions.Count) Defender path exclusions and $($ProcessExclusions.Count) process exclusions"
        }
        Catch {
            Write-Log -Category Warning -Message "Failed to add Windows Defender exclusions: $_"
        }

        # Add local administrator to FSLogix exclude lists
        $LocalAdministrator = (Get-LocalUser | Where-Object { $_.SID -like '*-500' }).Name
        $LocalGroups = 'FSLogix Profile Exclude List', 'FSLogix ODFC Exclude List'
        ForEach ($Group in $LocalGroups) {
            If (-not (Get-LocalGroupMember -Group $Group -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$LocalAdministrator" })) {
                Write-Log -message "Adding $LocalAdministrator to $Group"
                Add-LocalGroupMember -Group $Group -Member $LocalAdministrator -ErrorAction SilentlyContinue
            }
        }
    }
    
    # Apply all registry settings
    ForEach ($Setting in $RegSettings) {
        Set-RegistryValue -Name $Setting.Name -Path $Setting.Path -PropertyType $Setting.PropertyType -Value $Setting.Value
    }
    
    # Resize OS Disk
    Write-Log -Message "Resizing OS Disk"
    try {
        $driveLetter = $env:SystemDrive.Substring(0, 1)
        $currentPartition = Get-Partition -DriveLetter $driveLetter -ErrorAction Stop
        $currentSizeGB = [math]::Round($currentPartition.Size / 1GB, 2)
        Write-Log -Message "Current partition size: $currentSizeGB GB (drive: $driveLetter)"

        $size = Get-PartitionSupportedSize -DriveLetter $driveLetter -ErrorAction Stop
        $maxSizeGB = [math]::Round($size.SizeMax / 1GB, 2)
        $minSizeGB = [math]::Round($size.SizeMin / 1GB, 2)
        Write-Log -Message "Partition supported size range: Min=$minSizeGB GB, Max=$maxSizeGB GB"

        if ($null -eq $size -or $size.SizeMax -eq 0) {
            Write-Log -Message "Get-PartitionSupportedSize returned null or zero SizeMax. Skipping resize." -Category 'Warning'
        }
        elseif ($currentPartition.Size -ge $size.SizeMax) {
            Write-Log -Message "OS Disk partition ($currentSizeGB GB) is already at or above maximum supported size ($maxSizeGB GB). No resize needed."
        }
        else {
            Resize-Partition -DriveLetter $driveLetter -Size $size.SizeMax -ErrorAction Stop
            Write-Log -Message "OS Disk resized successfully from $currentSizeGB GB to $maxSizeGB GB"
        }
    }
    catch {
        if ($_.Exception.Message -like "*already the requested size*") {
            Write-Log -Message "OS Disk is already at maximum size. No resize needed."
        }
        else {
            Write-Log -Message "Failed to resize OS Disk: $($_.Exception.Message)" -Category 'Warning'
            Write-Log -Message "Continuing with deployment..."
        }
    }
    
    Write-Log -Message "Phase 1: Session Host Configuration Complete"
    
    #endregion Phase 1: Session Host Configuration
    
    #region Phase 2: AVD Agent Installation and Registration
    
    Write-Log -Message ''
    Write-Log -Message '========================================='
    Write-Log -Message 'Phase 2: AVD Agent Installation'
    Write-Log -Message '========================================='
    
    # Install RDS-RD-Server feature if this is a Server OS
    $IsServer = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).InstallationType -eq 'Server'
    Write-Log -Message "Operating System Type: $(if ($IsServer) { 'Server' } else { 'Client' })"
    if ($IsServer) {
        $rdFeature = Get-WindowsFeature -Name 'RDS-RD-Server' -ErrorAction SilentlyContinue
        if ($rdFeature -and -not $rdFeature.Installed) {
            Write-Log -Message 'Installing RDS-RD-Server feature'
            Install-WindowsFeature -Name 'RDS-RD-Server' -ErrorAction Stop | Out-Null
            Write-Log -Message 'RDS-RD-Server feature installed successfully'
        }
    }
    
    # Check if already registered
    $RDInfraReg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent' -ErrorAction SilentlyContinue
    
    if ($RDInfraReg -and $RDInfraReg.IsRegistered -eq 1 -and $RDInfraReg.RegistrationToken -eq '') {
        Write-Log -Message 'VM is already registered with RDInfraAgent. Skipping installation.'
        exit 0
    }
    
    Write-Log -Message 'VM is not registered. Proceeding with agent installation...'
    
    # Create temporary download folder
    $DownloadFolder = Join-Path -Path $env:TEMP -ChildPath "AVDAgentInstall_$(Get-Date -Format 'yyyyMMddHHmmss')"
    New-Item -Path $DownloadFolder -ItemType Directory -Force | Out-Null
    
    # Get Agent Installer with endpoint-first, URL-fallback logic
    $AgentInstallerPath = $null
    $BootLoaderInstallerPath = $null
    
    # Try endpoint first
    Write-Log -Message 'Attempting to download latest agent from Azure endpoint'
    $AgentInstallerPath = Get-LatestAgentInstaller -RegistrationToken $RegistrationToken -DownloadFolder $DownloadFolder
        
    # If endpoint failed and we have a URL, fall back to URL
    if (-not $AgentInstallerPath -and -not [string]::IsNullOrEmpty($AgentUrl)) {
        Write-Log -Message 'Endpoint download failed. Falling back to provided AgentUrl'
        $AgentInstallerPath = Join-Path -Path $DownloadFolder -ChildPath 'RDAgent.msi'
        $Success = Get-InstallerFromUrl -Url $AgentUrl -DestinationPath $AgentInstallerPath -DisplayName 'RD Agent'            
        if (-not $Success) {
            $AgentInstallerPath = $null
            Write-Log -Category Warning -Message "Failed to download RD Agent from fallback URL: $AgentUrl"
        }
    }
    
    # If both endpoint and AgentUrl failed (or AgentUrl wasn't provided), try extracting from FallbackUrl
    if (-not $AgentInstallerPath -and -not [string]::IsNullOrEmpty($FallbackUrl)) {
        Write-Log -Message 'Attempting to extract installers from fallback package...'
        
        $FallbackInstallers = Get-AgentInstallersFromFallbackUrl -FallbackUrl $FallbackUrl -DownloadFolder $DownloadFolder
        
        if ($FallbackInstallers) {
            $AgentInstallerPath = $FallbackInstallers.AgentPath
            $BootLoaderInstallerPath = $FallbackInstallers.BootLoaderPath
            Write-Log -Message 'Successfully extracted agent installers from fallback package'
        }
        else {
            Write-Log -Category Error -Message 'Failed to extract installers from fallback package'
        }
    }
    
    # Final check - if we still don't have the agent installer, fail
    if (-not $AgentInstallerPath) {
        throw 'Failed to obtain RD Agent installer from all available sources (Azure endpoint, AgentUrl, and FallbackUrl)'
    }
    
    # Get Agent Boot Loader Installer (if not already obtained from fallback)
    if (-not $BootLoaderInstallerPath) {
        Write-Log -Message 'Downloading agent boot loader from provided URL'
        $BootLoaderInstallerPath = Join-Path -Path $DownloadFolder -ChildPath 'RDAgentBootLoader.msi'
        $Success = Get-InstallerFromUrl -Url $AgentBootLoaderUrl -DestinationPath $BootLoaderInstallerPath -DisplayName 'RD Agent Boot Loader'
        
        if (-not $Success) {
            $BootLoaderInstallerPath = $null
            Write-Log -Category Warning -Message 'Failed to download RD Agent Boot Loader from provided URL'
            
            # If BootLoader download fails and we have FallbackUrl, try extracting from there
            if (-not [string]::IsNullOrEmpty($FallbackUrl)) {
                Write-Log -Message 'Attempting to extract boot loader from fallback package...'
                
                $FallbackInstallers = Get-AgentInstallersFromFallbackUrl -FallbackUrl $FallbackUrl -DownloadFolder $DownloadFolder
                
                if ($FallbackInstallers -and $FallbackInstallers.BootLoaderPath) {
                    $BootLoaderInstallerPath = $FallbackInstallers.BootLoaderPath
                    # Also update agent path if we didn't have it
                    if (-not $AgentInstallerPath) {
                        $AgentInstallerPath = $FallbackInstallers.AgentPath
                    }
                    Write-Log -Message 'Successfully extracted boot loader installer from fallback package'
                }
            }
            
            if (-not $BootLoaderInstallerPath) {
                throw 'Failed to download or extract RD Agent Boot Loader from all available sources'
            }
        }
    }
    
    # Final verification that we have both installers
    if (-not $AgentInstallerPath -or -not $BootLoaderInstallerPath) {
        throw 'Failed to obtain required installers. Agent: ' + $(if ($AgentInstallerPath) { 'OK' } else { 'FAILED' }) + ', BootLoader: ' + $(if ($BootLoaderInstallerPath) { 'OK' } else { 'FAILED' })
    }
    
    # Install RD Infra Agent
    Write-Log -Message "Installing RD Infra Agent from: $AgentInstallerPath"
    
    Invoke-MsiWithRetry `
        -DisplayName 'RD Infra Agent' `
        -ArgumentList @("/i", $AgentInstallerPath, "/quiet", "/qn", "/norestart", "/passive", "REGISTRATIONTOKEN=$RegistrationToken") `
        -LogPath "$env:TEMP\RDAgentInstall.log"
    
    # Install RD Agent Boot Loader
    Write-Log -Message "Installing RD Agent Boot Loader from: $BootLoaderInstallerPath"
    
    Invoke-MsiWithRetry `
        -DisplayName 'RD Agent Boot Loader' `
        -ArgumentList @("/i", $BootLoaderInstallerPath, "/quiet", "/qn", "/norestart", "/passive") `
        -LogPath "$env:TEMP\RDAgentBootLoaderInstall.log"
    
    # Wait for and start the boot loader service
    Wait-ForBootLoaderService
    
    # Clean up download folder
    try {
        Write-Log -Message "Cleaning up download folder: $DownloadFolder"
        Remove-Item -Path $DownloadFolder -Force -Recurse -ErrorAction SilentlyContinue
    }
    catch {
        Write-Log -Message "Warning: Failed to clean up download folder: $($_.Exception.Message)"
    }
      
    # Get and log the session host name
    $SessionHostName = Get-SessionHostName
    Write-Log -Message "Successfully registered session host: $SessionHostName"
    
    Write-Log -Message "Phase 2: AVD Agent Installation Complete"
    
    #endregion Phase 2: AVD Agent Installation and Registration
    
    Write-Log -Message ''
    Write-Log -Message '========================================='
    Write-Log -Message 'Session Host Initialization Complete'
    Write-Log -Message '========================================='
    Write-Log -Message "Log file location: $Script:LogPath"    
    exit 0
}
catch {
    Write-Log -Category Error -Message "Initialization failed: $($_.Exception.Message)"
    Write-Log -Category Error -Message "Stack Trace: $($_.ScriptStackTrace)"
    Write-Log -Message "Log file location: $Script:LogPath"    
    exit 1
}

#endregion Main Script
