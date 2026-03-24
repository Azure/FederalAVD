<#
.SYNOPSIS
Simplified script to install AVD RD Agent and RD Agent Bootloader as a RunCommand

.DESCRIPTION
This script downloads and installs the AVD RD Infra Agent and RD Agent Bootloader.
It can download the latest agent from Azure or use provided URLs.
Designed to run as a single RunCommand script without DSC dependencies.

.PARAMETER RegistrationToken
Required. The host pool registration token for joining the session host.

.PARAMETER AgentBootLoaderUrl
Required. Direct URL to download the RDAgent BootLoader MSI. 

.PARAMETER AgentUrl
Optional. Direct URL to download the RD Infra Agent MSI. If not provided the script will download the latest from the api endpoint.

.PARAMETER AADJoin
Optional. Set to 'true' if the VM should be Azure AD joined. Default is 'false'. Accepts 'true' or 'false'.

.PARAMETER AADJoinPreview
Optional. Set to 'true' to enable Azure AD join preview features. Default is 'false'. Accepts 'true' or 'false'.

.PARAMETER MdmId
Optional. MDM enrollment ID for Intune enrollment with AAD join.

.EXAMPLE
.\Add-SessionHost.ps1 -RegistrationToken "eyJ0eXAiOi..." -UseLatestAgent 'true'

.EXAMPLE
.\Add-SessionHost.ps1 -RegistrationToken "eyJ0eXAiOi..." -AgentUrl "https://..." -AgentBootLoaderUrl "https://..." -AADJoin 'true' -MdmId "0000000a-0000-0000-c000-000000000000"
#>

[CmdletBinding()]
param (
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
    [ValidateSet('true', 'false', '')]
    [string]$AADJoin,

    [Parameter(Mandatory = $false)]
    [ValidateSet('true', 'false', '')]
    [string]$AADJoinPreview = 'false',

    [Parameter(Mandatory = $false)]
    [string]$MdmId,
    
    [Parameter(Mandatory = $false)]
    [string]$UserAssignedIdentityClientId

)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Script:LogPath = "$env:TEMP\AVDSessionHostInstall.log"

# Convert string parameters to boolean for internal use
$AADJoinBool = [System.Convert]::ToBoolean($AADJoin)
$AADJoinPreviewBool = [System.Convert]::ToBoolean($AADJoinPreview)

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

function Test-IsServer {
    $OSVersionInfo = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    
    if ($null -ne $OSVersionInfo -and $null -ne $OSVersionInfo.InstallationType) {
        return $OSVersionInfo.InstallationType -eq 'Server'
    }
    
    return $false
}

function Install-WindowsFeature {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FeatureName
    )
    
    Write-Log -Message "Installing Windows Feature: $FeatureName"
    
    try {
        $feature = Get-WindowsFeature -Name $FeatureName -ErrorAction SilentlyContinue
        
        if ($null -eq $feature) {
            Write-Log -Message "Feature $FeatureName not found, skipping installation"
            return
        }
        
        if ($feature.Installed) {
            Write-Log -Message "Feature $FeatureName is already installed"
            return
        }
        
        $result = Install-WindowsFeature -Name $FeatureName -ErrorAction Stop
        
        if ($result.Success) {
            Write-Log -Message "Successfully installed feature: $FeatureName"
            
            if ($result.RestartNeeded -eq 'Yes') {
                Write-Log -Message "WARNING: A restart is required after installing $FeatureName"
            }
        }
        else {
            Write-Log -Category Error -Message "Failed to install feature: $FeatureName"
        }
    }
    catch {
        Write-Log -Category Error -Message "Error installing feature $FeatureName : $($_.Exception.Message)"
        throw
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
        [string]$ApiVersion = $APIVersion,
        [string]$StorageSuffix = $StorageSuffix,
        [string]$ClientId = $UserAssignedIdentityClientId,
        [string]$Url,
        [string]$DestinationPath,
        [string]$DisplayName
    )
    
    try {
        $WebClient = New-Object System.Net.WebClient
        if (-not [string]::IsNullOrEmpty($StorageSuffix) -and $Url -match $StorageSuffix -and -not [string]::IsNullOrEmpty($ClientId)) {
            If ($Url -match $StorageSuffix -and $ClientId -ne '') {
                $StorageEndpoint = ($Url -split "://")[0] + "://" + ($Uri -split "/")[2] + "/"
                $TokenUri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=$ApiVersion&resource=$StorageEndpoint&client_id=$ClientId"
                $AccessToken = ((Invoke-WebRequest -Headers @{Metadata = $true } -Uri $TokenUri -UseBasicParsing).Content | ConvertFrom-Json).access_token
                $WebClient.Headers.Add('x-ms-version', '2017-11-09')
                $webClient.Headers.Add("Authorization", "Bearer $AccessToken")
            }
        }

        Write-Log -Message "Downloading $DisplayName from: $Url"
        $webClient.DownloadFile("$Url", "$DestinationPath")
        $WebClient - $null
        Write-Log -Message "Successfully downloaded $DisplayName to: $DestinationPath"
        return $true
    }
    catch {
        Write-Log -Category Error -Message "Failed to download $DisplayName : $($_.Exception.Message)"
        $webClient = $null
        return $false
    }
}

function Set-AADJoinRegistryKeys {
    param (       
        [Parameter(Mandatory = $true)]
        [string]$MdmId
    )
      
    Write-Log -Message "Configuring Azure AD Join preview registry keys"
    
    $RegistryPath = 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent\AzureADJoin'
    
    try {
        if (-not (Test-Path $RegistryPath)) {
            Write-Log -Message "Creating registry path: $RegistryPath"
            New-Item -Path $RegistryPath -Force | Out-Null
        }
        
        Write-Log -Message "Setting JoinAzureAD registry value"
        New-ItemProperty -Path $RegistryPath -Name 'JoinAzureAD' -PropertyType DWord -Value 1 -Force | Out-Null
        
        if (-not [string]::IsNullOrEmpty($MdmId)) {
            Write-Log -Message "Setting MDMEnrollmentId registry value: $MdmId"
            New-ItemProperty -Path $RegistryPath -Name 'MDMEnrollmentId' -PropertyType String -Value $MdmId -Force | Out-Null
        }
        
        Write-Log -Message "Successfully configured Azure AD Join registry keys"
    }
    catch {
        Write-Log -Category Error -Message "Failed to set Azure AD Join registry keys: $($_.Exception.Message)"
        throw
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
            Write-Log -Err $ErrorMsg
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

#endregion

#region Main Script

try {
    Write-Log -Message '========================================='
    Write-Log -Message 'AVD Session Host Installation Starting'
    Write-Log -Message '========================================='
    
    # Log parameters (excluding sensitive data)
    Write-Log -Message "Parameters:"
    Write-Log -Message "  AADJoin: $AADJoin (Converted: $AADJoinBool)"
    Write-Log -Message "  AADJoinPreview: $AADJoinPreview (Converted: $AADJoinPreviewBool)"
    Write-Log -Message "  MdmId: $(if (-not [string]::IsNullOrEmpty($MdmId)) { $MdmId } else { '(not set)' })"
    Write-Log -Message "  AgentUrl: $(if ($AgentUrl) { $AgentUrl } else { '(will download latest from endpoint)' })"
    Write-Log -Message "  AgentBootLoaderUrl: $AgentBootLoaderUrl"   
  
    # Check if this is a Server OS
    $IsServer = Test-IsServer
    Write-Log -Message "Operating System Type: $(if ($IsServer) { 'Server' } else { 'Client' })"
    
    # Install RDS-RD-Server feature if it's a Server OS
    if ($IsServer) {
        Install-WindowsFeature -FeatureName 'RDS-RD-Server'
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
    Write-Log -Message "Download folder: $DownloadFolder"
    
    # Get Agent Installer    
    if (-not [string]::IsNullOrEmpty($AgentUrl)) {
        # Use provided AgentUrl
        Write-Log -Message 'Downloading agent from provided URL'
        $AgentInstallerPath = Join-Path -Path $DownloadFolder -ChildPath 'RDAgent.msi'
        $Success = Get-InstallerFromUrl -Url $AgentUrl -DestinationPath $AgentInstallerPath -DisplayName 'RD Agent'
        
        if (-not $Success) {
            throw 'Failed to download RD Agent from provided URL'
        }
    }
    else {
        # AgentUrl not provided, download latest from Azure endpoint
        Write-Log -Message 'AgentUrl not provided. Downloading latest agent from Azure endpoint'
        $AgentInstallerPath = Get-LatestAgentInstaller -RegistrationToken $RegistrationToken -DownloadFolder $DownloadFolder
        
        if (-not $AgentInstallerPath) {
            throw 'Failed to download latest RD Agent from Azure endpoint. Please provide -AgentUrl as an alternative.'
        }
    }
    
    # Get Agent Boot Loader Installer
    Write-Log -Message 'Downloading agent boot loader from provided URL'
    $BootLoaderInstallerPath = Join-Path -Path $DownloadFolder -ChildPath 'RDAgentBootLoader.msi'
    $Success = Get-InstallerFromUrl -Url $AgentBootLoaderUrl -DestinationPath $BootLoaderInstallerPath -DisplayName 'RD Agent Boot Loader'
        
    if (-not $Success) {
        throw 'Failed to download RD Agent Boot Loader from provided URL'
    }
    
    # Set Azure AD Join registry keys if needed
    if ($AADJoinPreviewBool) {
        Set-AADJoinRegistryKeys -AADJoinPreview $AADJoinPreviewBool -MdmId $MdmId
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
    
    # If AAD Join with Intune enrollment (non-preview), sleep for 6 minutes to ensure Intune metadata logging
    if ($AADJoinBool -and -not [string]::IsNullOrEmpty($MdmId) -and -not $AADJoinPreviewBool) {
        Write-Log -Message 'AAD Join with Intune enrollment detected (non-preview). Sleeping for 6 minutes to ensure Intune metadata logging...'
        Start-Sleep -Seconds 360
        Write-Log -Message 'Completed 6 minute wait for Intune metadata logging'
    }
    
    # Get and log the session host name
    $SessionHostName = Get-SessionHostName
    Write-Log -Message "Successfully registered session host: $SessionHostName"
    
    Write-Log -Message '========================================='
    Write-Log -Message 'AVD Session Host Installation Complete'
    Write-Log -Message '========================================='
    Write-Log -Message "Log file location: $Script:LogPath"    
    exit 0
}
catch {
    Write-Log -Category Error -Message "Installation failed: $($_.Exception.Message)"
    Write-Log -Category Error -Message "Stack Trace: $($_.ScriptStackTrace)"
    Write-Log -Message "Log file location: $Script:LogPath"    
    exit 1
}

#endregion
