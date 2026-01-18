<#
https://aka.microsoft.scloud/avdRDAgentBootLoader
https://aka.microsoft.scloud/avdRDAgent
public bootloader: https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrxrH


.SYNOPSIS
Installs AVD RDAgent and registers session host with hostpool using direct installation (no DSC).

.DESCRIPTION
This script replaces the DSC extension for AVD agent installation, providing:
- Faster execution (2-4 minutes vs 5-50 minutes with DSC)
- Immediate status reporting to ARM
- Option to download latest agents from Microsoft's CDN
- No DSC state machine overhead
- Direct logging and error reporting

.PARAMETER HostPoolName
Name of the AVD hostpool to register with

.PARAMETER RegistrationToken
Registration token for the hostpool (passed as secure parameter)

.PARAMETER AadJoin
Whether this is an AAD-joined session host

.PARAMETER UseAgentDownloadEndpoint
If true, downloads latest agents from Microsoft's CDN. If false, uses bundled agents.

.PARAMETER MdmId
MDM enrollment ID for Intune (typically '0000000a-0000-0000-c000-000000000000')

.PARAMETER SessionHostConfigurationLastUpdateTime
Timestamp for session host configuration tracking

.EXAMPLE
.\Install-AVDAgent.ps1 -HostPoolName "mypool" -RegistrationToken "xxx" -AadJoin $true -UseAgentDownloadEndpoint $true

#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$HostPoolName,

    [Parameter(Mandatory = $true)]
    [string]$RegistrationToken,

    [Parameter(Mandatory = $false)]
    [bool]$AadJoin = $false,

    [Parameter(Mandatory = $false)]
    [string]$MdmId = "",

    [Parameter(Mandatory = $false)]
    [string]$SessionHostConfigurationLastUpdateTime = "",    

    [Parameter(Mandatory = $true)]
    [string]$BootLoaderDownloadUrl
)

$ErrorActionPreference = "Stop"
$ScriptPath = $PSScriptRoot

# Setting to Tls12 due to Azure web app security requirements
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

#region Helper Functions

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [switch]$Err
    )
     
    try {
        $DateTime = Get-Date -Format "MM-dd-yy HH:mm:ss"
        $Invocation = "$($MyInvocation.MyCommand.Source):$($MyInvocation.ScriptLineNumber)"

        if ($Err) {
            $Message = "[ERROR] $Message"
            Write-Error $Message
        }
        else {
            Write-Host $Message
        }
        
        Add-Content -Value "$DateTime - $Invocation - $Message" -Path "$([environment]::GetEnvironmentVariable('TEMP', 'Machine'))\AVDAgentInstall.log"
    }
    catch {
        throw [System.Exception]::new("Some error occurred while writing to log file with message: $Message", $PSItem.Exception)
    }
}

function GetAvdSessionHostName {
    $Wmi = (Get-WmiObject win32_computersystem)
    
    if ($Wmi.Domain -eq "WORKGROUP") {
        return "$($Wmi.DNSHostName)"
    }

    return "$($Wmi.DNSHostName).$($Wmi.Domain)"
}

function ParseRegistrationToken {
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Token
    )
 
    $ClaimsSection = $Token.Split(".")[1].Replace('-', '+').Replace('_', '/')
    while ($ClaimsSection.Length % 4) { 
        $ClaimsSection += "=" 
    }
    
    $ClaimsByteArray = [System.Convert]::FromBase64String($ClaimsSection)
    $ClaimsArray = [System.Text.Encoding]::ASCII.GetString($ClaimsByteArray)
    $Claims = $ClaimsArray | ConvertFrom-Json
    return $Claims
}

function GetAgentMSIEndpoint {
    Param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $BrokerAgentApi
    )

    try {
        Write-Log -Message "Invoking broker agent api $BrokerAgentApi to get msi endpoint"
        $result = Invoke-WebRequest -Uri $BrokerAgentApi -UseBasicParsing
        $responseJson = $result.Content | ConvertFrom-Json
    }
    catch {
        $responseBody = $_.ErrorDetails.Message
        Write-Log -Err $responseBody
        return $null
    }

    Write-Log -Message "Obtained agent msi endpoint: $($responseJson.agentEndpoint)"
    return $responseJson.agentEndpoint
}

function DownloadAgentMSI {
    Param(
        [Parameter(Mandatory = $true)]
        [string]$AgentEndpoint,

        [Parameter(Mandatory = $true)]
        [string]$PrivateLinkAgentEndpoint,

        [Parameter(Mandatory = $true)]
        [string]$DownloadFolder
    )
    
    $AgentInstaller = $null

    try {
        Write-Log -Message "Downloading agent MSI from: $AgentEndpoint"
        Invoke-WebRequest -Uri $AgentEndpoint -OutFile "$DownloadFolder\RDAgent.msi" -UseBasicParsing
        $AgentInstaller = Join-Path $DownloadFolder "RDAgent.msi"
        Write-Log -Message "Successfully downloaded agent MSI"
    } 
    catch {
        Write-Log -Err "Error downloading agent MSI from $AgentEndpoint : $($_.Exception.Message)"
    }

    if (-not $AgentInstaller) {
        try {
            Write-Log -Message "Trying private link endpoint: $PrivateLinkAgentEndpoint"
            Invoke-WebRequest -Uri $PrivateLinkAgentEndpoint -OutFile "$DownloadFolder\RDAgent.msi" -UseBasicParsing
            $AgentInstaller = Join-Path $DownloadFolder "RDAgent.msi"
            Write-Log -Message "Successfully downloaded agent MSI from private link"
        } 
        catch {
            Write-Log -Err "Error downloading from private link $PrivateLinkAgentEndpoint : $($_.Exception.Message)"
        }
    }

    return $AgentInstaller
}

function GetLatestAgentInstaller {
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Token,

        [Parameter(Mandatory = $true)]
        [string]$DownloadFolder
    )

    Try {
        $ParsedToken = ParseRegistrationToken $Token
        if (-not $ParsedToken.GlobalBrokerResourceIdUri) {
            Write-Log -Message "Unable to obtain broker agent endpoint from token"
            return $null
        }

        $BrokerAgentUri = [System.UriBuilder] $ParsedToken.GlobalBrokerResourceIdUri
        $BrokerAgentUri.Path = "api/agentMsi/v1/agentVersion"
        $BrokerAgentUri = $BrokerAgentUri.Uri.AbsoluteUri
        Write-Log -Message "Broker agent API: $BrokerAgentUri"

        $AgentMSIEndpointUri = [System.UriBuilder] (GetAgentMSIEndpoint $BrokerAgentUri)
        if (-not $AgentMSIEndpointUri) {
            Write-Log -Message "Unable to get Agent MSI endpoint from broker"
            return $null
        }

        $AgentDownloadFolder = New-Item -Path $DownloadFolder -Name "RDAgent" -ItemType "directory" -Force
        $PrivateLinkAgentMSIEndpointUri = [System.UriBuilder] $AgentMSIEndpointUri.Uri.AbsoluteUri
        $PrivateLinkAgentMSIEndpointUri.Host = "$($ParsedToken.EndpointPoolId).$($AgentMSIEndpointUri.Host)"

        $AgentInstaller = DownloadAgentMSI $AgentMSIEndpointUri.Uri.AbsoluteUri $PrivateLinkAgentMSIEndpointUri.Uri.AbsoluteUri $AgentDownloadFolder
        
        if (-not $AgentInstaller) {
            Write-Log -Message "Failed to download latest agent MSI"
        } 
        else {
            Write-Log "Successfully obtained latest agent MSI: $AgentInstaller"
        }

        return $AgentInstaller
    } 
    Catch {
        Write-Log -Err "Error while obtaining latest agent MSI: $($_.Exception.Message)"
        return $null
    }
}

function RunMsiWithRetry {
    param(
        [Parameter(mandatory = $true)]
        [string]$ProgramName,

        [Parameter(mandatory = $true)]
        [string[]]$ArgumentList,

        [Parameter(mandatory = $true)]
        [string]$LogPath,

        [Parameter(mandatory = $false)]
        [switch]$IsUninstall
    )

    $ArgumentList += "/liwemo+! `"$LogPath`""

    $retryCount = 0
    $maxRetries = 20
    $sts = $null
    
    do {
        $action = if ($IsUninstall) { "Uninstalling" } else { "Installing" }

        if ($retryCount -gt 0) {
            Write-Log -Message "Retry $retryCount for $action $ProgramName (previous exit code: $sts)"
            Start-Sleep -Seconds 30
        }

        Write-Log -Message "$action $ProgramName"
        $processResult = Start-Process -FilePath "msiexec.exe" -ArgumentList $ArgumentList -Wait -Passthru
        $sts = $processResult.ExitCode

        $retryCount++
    } 
    while ($sts -eq 1618 -and $retryCount -lt $maxRetries) # ERROR_INSTALL_ALREADY_RUNNING

    if ($sts -eq 1618) {
        $msg = "$action $ProgramName failed after $maxRetries retries. Exit code: $sts (ERROR_INSTALL_ALREADY_RUNNING)"
        Write-Log -Err $msg
        throw $msg
    }
    
    Write-Log -Message "$action $ProgramName completed with exit code: $sts"
    return $sts
}

function UninstallExistingAgents {
    
    $msiToUninstall = @(
        @{ Name = "Remote Desktop Services Infrastructure Agent"; DisplayName = "RD Infra Agent"; LogPath = "C:\Windows\Temp\AgentUninstall.txt" }, 
        @{ Name = "Remote Desktop Agent Boot Loader"; DisplayName = "RDAgentBootLoader"; LogPath = "C:\Windows\Temp\AgentBootLoaderUnInstall.txt" }
    )
    
    foreach ($msi in $msiToUninstall) {
        while ($true) {
            try {
                $installedMsi = Get-Package -ProviderName msi -Name $msi.Name -ErrorAction SilentlyContinue
            }
            catch {
                if ($PSItem.FullyQualifiedErrorId -eq "NoMatchFound,Microsoft.PowerShell.PackageManagement.Cmdlets.GetPackage") {
                    Write-Log -Message "No existing $($msi.DisplayName) installation found"
                    break
                }
                throw
            }

            if (-not $installedMsi) {
                break
            }
    
            $oldVersion = $installedMsi.Version
            $productCode = $installedMsi.FastPackageReference
    
            Write-Log -Message "Uninstalling existing $($msi.DisplayName) version $oldVersion"
            RunMsiWithRetry -ProgramName "$($msi.DisplayName) $oldVersion" `
                -IsUninstall `
                -ArgumentList @("/x", $productCode, "/quiet", "/qn", "/norestart", "/passive") `
                -LogPath $msi.LogPath
        }
    }
}

function IsRDAgentRegistered {
    $RDInfraReg = Get-ItemProperty -Path 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\RDInfraAgent' -ErrorAction SilentlyContinue
    
    if (-not $RDInfraReg) {
        return $false
    }

    if ($RDInfraReg.RegistrationToken -ne '' -or $RDInfraReg.IsRegistered -ne 1) {
        return $false
    }
    
    return $true
}

#endregion

#region Main Installation Logic

try {
    Write-Log -Message "========================================"
    Write-Log -Message "Starting AVD Agent Installation"
    Write-Log -Message "HostPool: $HostPoolName"
    Write-Log -Message "AAD Join: $AadJoin"
    Write-Log -Message "========================================"

    # Check if already registered
    if (IsRDAgentRegistered) {
        Write-Log -Message "Session host is already registered with AVD. Skipping installation."
        exit 0
    }

    # Create temp download folder
    $TempFolder = "C:\AVDAgentInstall"
    if (Test-Path $TempFolder) {
        Write-Log -Message "Cleaning up existing temp folder: $TempFolder"
        Remove-Item -Path $TempFolder -Force -Confirm:$false -Recurse -ErrorAction SilentlyContinue
    }
    New-Item -Path $TempFolder -ItemType Directory -Force | Out-Null

    # Get agent installers
    $AgentMsiPath = $null
    $BootLoaderMsiPath = "$TempFolder\RDAgentBootLoader.msi"
    Write-Log -Message "Downloading RDAgent BootLoader from: $BootLoaderDownloadUrl"
    Invoke-WebRequest -Uri $BootLoaderDownloadUrl -OutFile $BootLoaderMsiPath
    If (-not (Test-Path $BootLoaderMsiPath)) {
        throw "Failed to download RDAgent BootLoader from $BootLoaderDownloadUrl"
    }
    Write-Log -Message "Attempting to download latest agents from Microsoft CDN"
    $AgentMsiPath = GetLatestAgentInstaller -Token $RegistrationToken -DownloadFolder $TempFolder
        
    if (-not $AgentMsiPath -or -not (Test-Path $AgentMsiPath)) {
        Write-Log -Message "Failed to download latest agent, will use bundled version"
        $AgentMsiPath = $null
    }

    if (-not $AgentMsiPath) {
        throw "Could not locate RDAgent MSI installer"
    }

    Write-Log -Message "Agent MSI: $AgentMsiPath"
    Write-Log -Message "BootLoader MSI: $BootLoaderMsiPath"

    # Configure AAD Join registry if needed
    if ($AadJoin) {
        Write-Log "Configuring Azure AD Join settings"
        $registryPath = "HKLM:\SOFTWARE\Microsoft\RDInfraAgent\AzureADJoin"
        
        if (-not (Test-Path -Path $registryPath)) {
            New-Item -Path $registryPath -Force | Out-Null
        }
        
        New-ItemProperty -Path $registryPath -Name "JoinAzureAD" -PropertyType DWord -Value 0x01 -Force | Out-Null
        
        if ($MdmId) {
            Write-Log "Setting MDM Enrollment ID: $MdmId"
            New-ItemProperty -Path $registryPath -Name "MDMEnrollmentId" -PropertyType String -Value $MdmId -Force | Out-Null
        }
    }

    # Uninstall existing agents
    Write-Log -Message "Checking for existing agent installations"
    UninstallExistingAgents

    # Install RD Infra Agent
    Write-Log -Message "Installing RD Infra Agent"
    $installExitCode = RunMsiWithRetry -ProgramName "RD Infra Agent" `
        -ArgumentList @("/i", "`"$AgentMsiPath`"", "/quiet", "/qn", "/norestart", "/passive", "REGISTRATIONTOKEN=$RegistrationToken") `
        -LogPath "C:\Windows\Temp\RDAgentInstall.txt"

    if ($installExitCode -ne 0 -and $installExitCode -ne 3010) {
        throw "RD Infra Agent installation failed with exit code: $installExitCode"
    }

    # Install RDAgent BootLoader
    Write-Log -Message "Installing RDAgent BootLoader"
    $bootLoaderExitCode = RunMsiWithRetry -ProgramName "RDAgent BootLoader" `
        -ArgumentList @("/i", "`"$BootLoaderMsiPath`"", "/quiet", "/qn", "/norestart", "/passive") `
        -LogPath "C:\Windows\Temp\RDAgentBootLoaderInstall.txt"

    if ($bootLoaderExitCode -ne 0 -and $bootLoaderExitCode -ne 3010) {
        throw "RDAgent BootLoader installation failed with exit code: $bootLoaderExitCode"
    }

    # Start RDAgentBootLoader service
    $bootloaderServiceName = "RDAgentBootLoader"
    $retryCount = 0
    $maxRetries = 6
    
    Write-Log -Message "Waiting for $bootloaderServiceName service"
    while (-not (Get-Service $bootloaderServiceName -ErrorAction SilentlyContinue)) {
        if ($retryCount -ge $maxRetries) {
            throw "Service $bootloaderServiceName was not found after $maxRetries retries"
        }
        
        Write-Log -Message "Service not found, waiting... (retry $retryCount/$maxRetries)"
        Start-Sleep -Seconds 30
        $retryCount++
    }

    Write-Log -Message "Starting service: $bootloaderServiceName"
    Start-Service $bootloaderServiceName -ErrorAction Stop
    
    # Verify service is running
    $service = Get-Service $bootloaderServiceName
    if ($service.Status -ne 'Running') {
        throw "Service $bootloaderServiceName failed to start. Status: $($service.Status)"
    }
    Write-Log -Message "Service $bootloaderServiceName is running"

    # Set session host configuration timestamp
    if ($SessionHostConfigurationLastUpdateTime) {
        $rdInfraAgentRegistryPath = "HKLM:\SOFTWARE\Microsoft\RDInfraAgent"
        if (Test-Path $rdInfraAgentRegistryPath) {
            Write-Log -Message "Setting SessionHostConfigurationLastUpdateTime: $SessionHostConfigurationLastUpdateTime"
            Set-ItemProperty -Path $rdInfraAgentRegistryPath -Name "SessionHostConfigurationLastUpdateTime" -Value $SessionHostConfigurationLastUpdateTime
        }
    }

    # Wait a moment for registration to complete
    Write-Log -Message "Waiting for agent registration to complete"
    Start-Sleep -Seconds 30

    # Verify registration
    if (IsRDAgentRegistered) {
        $SessionHostName = GetAvdSessionHostName
        Write-Log -Message "========================================"
        Write-Log -Message "SUCCESS: Session host '$SessionHostName' successfully registered with hostpool '$HostPoolName'"
        Write-Log -Message "========================================"
        
        # Clean up temp folder
        try {
            Remove-Item -Path $TempFolder -Force -Confirm:$false -Recurse -ErrorAction SilentlyContinue
            Write-Log -Message "Cleaned up temporary installation files"
        }
        catch {
            Write-Log -Message "Warning: Could not clean up temp folder: $($_.Exception.Message)"
        }
        
        exit 0
    }
    else {
        throw "Agent installation completed but registration verification failed"
    }
}
catch {
    $errorMessage = $_.Exception.Message
    $errorDetails = $_ | Format-List -Force | Out-String
    
    Write-Log -Err "========================================"
    Write-Log -Err "INSTALLATION FAILED"
    Write-Log -Err "Error: $errorMessage"
    Write-Log -Err "Details: $errorDetails"
    Write-Log -Err "========================================"
    
    # Clean up on failure
    if (Test-Path $TempFolder) {
        try {
            Remove-Item -Path $TempFolder -Force -Confirm:$false -Recurse -ErrorAction SilentlyContinue
        }
        catch {
            Write-Log -Message "Could not clean up temp folder: $($_.Exception.Message)"
        }
    }
    
    exit 1
}

#endregion
