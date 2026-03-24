<#
.SYNOPSIS
Install AVD Agent and Boot Loader via RunCommand with dynamic environment detection

.DESCRIPTION
This script detects the Azure environment, downloads the appropriate MSI files,
and installs the RD Agent and Boot Loader for AVD session hosts.

.PARAMETER RegistrationToken
The hostpool registration token (required)

.PARAMETER HostPoolName
The name of the hostpool (for logging purposes)

.PARAMETER AadJoin
Whether this is an Azure AD joined machine

.PARAMETER EnableVerboseMsiLogging
Enable verbose MSI logging for troubleshooting

.EXAMPLE
# For use in Azure RunCommand:
.\Install-AVDAgent-RunCommand.ps1 -RegistrationToken "eyJ..." -HostPoolName "myHostPool"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RegistrationToken,

    [Parameter(Mandatory = $true)]
    [string]$HostPoolName,

    [Parameter(Mandatory = $false)]
    [bool]$AadJoin = $false,

    [Parameter(Mandatory = $false)]
    [bool]$EnableVerboseMsiLogging = $false
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ============================================================================
# Logging Function
# ============================================================================
function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [switch]$Err
    )
    
    try {
        $DateTime = Get-Date -Format "MM-dd-yy HH:mm:ss"
        $LogPath = "$env:TEMP\AVDAgentInstall.log"
        
        if ($Err) {
            $Message = "[ERROR] $Message"
            Write-Error $Message
        }
        else {
            Write-Host $Message
        }
        
        Add-Content -Value "$DateTime - $Message" -Path $LogPath -ErrorAction SilentlyContinue
    }
    catch {
        Write-Warning "Failed to write to log: $_"
    }
}

# ============================================================================
# Environment Detection
# ============================================================================
function Get-AzureEnvironment {
    Write-Log "Detecting Azure environment..."
    
    try {
        # Try to get environment from IMDS
        $imdsUri = "http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01"
        $headers = @{ Metadata = "true" }
        $response = Invoke-RestMethod -Uri $imdsUri -Headers $headers -Method Get -TimeoutSec 5
        
        $location = $response.location
        Write-Log "Detected Azure location: $location"
        
        # Determine environment based on location patterns
        if ($location -match "usgov|usnat|ussec") {
            if ($location -match "ussec") {
                return "AzureUSGovernmentSecret"
            }
            elseif ($location -match "usnat") {
                return "AzureUSGovernmentTopSecret"
            }
            else {
                return "AzureUSGovernment"
            }
        }
        else {
            return "AzureCloud"
        }
    }
    catch {
        Write-Log "Could not detect environment from IMDS, parsing registration token..." -Err
        
        # Fall back to parsing registration token
        try {
            $claims = Get-RegistrationTokenClaims -RegistrationToken $RegistrationToken
            $brokerUri = $claims.GlobalBrokerResourceIdUri
            
            if ($brokerUri -match "ussec") {
                return "AzureUSGovernmentSecret"
            }
            elseif ($brokerUri -match "usnat") {
                return "AzureUSGovernmentTopSecret"
            }
            elseif ($brokerUri -match "usgov") {
                return "AzureUSGovernment"
            }
            else {
                return "AzureCloud"
            }
        }
        catch {
            Write-Log "Failed to detect environment, defaulting to AzureCloud" -Err
            return "AzureCloud"
        }
    }
}

# ============================================================================
# Get MSI Download Endpoints
# ============================================================================
function Get-MSIEndpoints {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Environment
    )
    
    Write-Log "Getting MSI endpoints for environment: $Environment"
    
    $endpoints = @{
        AzureCloud = @{
            BootLoader = "https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrmXv"
            Agent = "https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrxrH"
        }
        AzureUSGovernment = @{
            BootLoader = "https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrmXv"
            Agent = "https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrxrH"
        }
        AzureUSGovernmentSecret = @{
            # These would be the Secret-specific endpoints
            # Update with actual endpoints from your documentation
            BootLoader = "https://avd-msi-secret.blob.core.eaglex.ic.gov/msi/RDAgentBootLoader.msi"
            Agent = "https://avd-msi-secret.blob.core.eaglex.ic.gov/msi/RDAgent.msi"
        }
        AzureUSGovernmentTopSecret = @{
            # These would be the Top Secret-specific endpoints
            # Update with actual endpoints from your documentation
            BootLoader = "https://avd-msi-topsecret.blob.core.cloudapp.eaglex.ic.gov/msi/RDAgentBootLoader.msi"
            Agent = "https://avd-msi-topsecret.blob.core.cloudapp.eaglex.ic.gov/msi/RDAgent.msi"
        }
    }
    
    if (-not $endpoints.ContainsKey($Environment)) {
        throw "Unknown environment: $Environment"
    }
    
    return $endpoints[$Environment]
}

# ============================================================================
# Parse Registration Token
# ============================================================================
function Get-RegistrationTokenClaims {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RegistrationToken
    )
    
    $ClaimsSection = $RegistrationToken.Split(".")[1].Replace('-', '+').Replace('_', '/')
    while ($ClaimsSection.Length % 4) { 
        $ClaimsSection += "=" 
    }
    
    $ClaimsByteArray = [System.Convert]::FromBase64String($ClaimsSection)
    $ClaimsArray = [System.Text.Encoding]::ASCII.GetString($ClaimsByteArray)
    $Claims = $ClaimsArray | ConvertFrom-Json
    
    return $Claims
}

# ============================================================================
# Download MSI File
# ============================================================================
function Download-MSI {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,
        
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,
        
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    
    Write-Log "Downloading $Name from: $Url"
    
    try {
        $maxRetries = 3
        $retryCount = 0
        $downloaded = $false
        
        while (-not $downloaded -and $retryCount -lt $maxRetries) {
            try {
                Invoke-WebRequest -Uri $Url -OutFile $OutputPath -UseBasicParsing -TimeoutSec 300
                
                if (Test-Path $OutputPath) {
                    $fileSize = (Get-Item $OutputPath).Length
                    Write-Log "Successfully downloaded $Name ($fileSize bytes)"
                    $downloaded = $true
                }
            }
            catch {
                $retryCount++
                if ($retryCount -lt $maxRetries) {
                    Write-Log "Download attempt $retryCount failed, retrying in 10 seconds..." -Err
                    Start-Sleep -Seconds 10
                }
                else {
                    throw "Failed to download $Name after $maxRetries attempts: $_"
                }
            }
        }
        
        return $OutputPath
    }
    catch {
        Write-Log "Error downloading $Name : $_" -Err
        throw
    }
}

# ============================================================================
# Run MSI Installer with Retry
# ============================================================================
function Install-MSI {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MsiPath,
        
        [Parameter(Mandatory = $true)]
        [string]$DisplayName,
        
        [Parameter(Mandatory = $false)]
        [string]$AdditionalArgs = "",
        
        [Parameter(Mandatory = $false)]
        [bool]$VerboseLogging = $false
    )
    
    Write-Log "Installing $DisplayName from: $MsiPath"
    
    $logPath = "$env:TEMP\$DisplayName-Install.log"
    
    $argumentList = @(
        "/i"
        "`"$MsiPath`""
        "/quiet"
        "/qn"
        "/norestart"
        "/passive"
    )
    
    if ($AdditionalArgs) {
        $argumentList += $AdditionalArgs
    }
    
    if ($VerboseLogging) {
        $argumentList += "/l*vx+ `"$logPath`""
    }
    else {
        $argumentList += "/liwemo+! `"$logPath`""
    }
    
    $maxRetries = 20
    $retryCount = 0
    $exitCode = -1
    
    do {
        if ($retryCount -gt 0) {
            Write-Log "Retrying installation in 30 seconds (attempt $retryCount)..."
            Start-Sleep -Seconds 30
        }
        
        $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $argumentList -Wait -PassThru
        $exitCode = $process.ExitCode
        
        $retryCount++
    } while ($exitCode -eq 1618 -and $retryCount -lt $maxRetries)
    
    if ($exitCode -eq 1618) {
        throw "Installation of $DisplayName failed with exit code 1618 (ERROR_INSTALL_ALREADY_RUNNING) after $maxRetries retries"
    }
    
    Write-Log "Installation of $DisplayName completed with exit code: $exitCode"
    
    if ($exitCode -ne 0 -and $exitCode -ne 3010) {
        Write-Log "Installation may have failed. Check log: $logPath" -Err
    }
    
    return $exitCode
}

# ============================================================================
# Uninstall Existing Agents
# ============================================================================
function Uninstall-ExistingAgents {
    Write-Log "Checking for existing agent installations..."
    
    $msiToUninstall = @(
        @{ Name = "Remote Desktop Services Infrastructure Agent"; DisplayName = "RD Infra Agent" }
        @{ Name = "Remote Desktop Agent Boot Loader"; DisplayName = "RDAgentBootLoader" }
    )
    
    foreach ($msi in $msiToUninstall) {
        while ($true) {
            try {
                $installedMsi = Get-Package -ProviderName msi -Name $msi.Name -ErrorAction SilentlyContinue
            }
            catch {
                if ($_.FullyQualifiedErrorId -eq "NoMatchFound,Microsoft.PowerShell.PackageManagement.Cmdlets.GetPackage") {
                    break
                }
                throw
            }
            
            if (-not $installedMsi) {
                break
            }
            
            $oldVersion = $installedMsi.Version
            $productCode = $installedMsi.FastPackageReference
            
            Write-Log "Uninstalling $($msi.DisplayName) version $oldVersion"
            
            $logPath = "$env:TEMP\$($msi.DisplayName)-Uninstall.log"
            $argumentList = @(
                "/x"
                $productCode
                "/quiet"
                "/qn"
                "/norestart"
                "/passive"
            )
            
            if ($EnableVerboseMsiLogging) {
                $argumentList += "/l*vx+ `"$logPath`""
            }
            else {
                $argumentList += "/liwemo+! `"$logPath`""
            }
            
            $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $argumentList -Wait -PassThru
            Write-Log "Uninstall completed with exit code: $($process.ExitCode)"
        }
    }
}

# ============================================================================
# Check if Already Registered
# ============================================================================
function Test-AgentRegistration {
    Write-Log "Checking if agent is already registered..."
    
    $rdInfraReg = Get-ItemProperty -Path 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\RDInfraAgent' -ErrorAction SilentlyContinue
    
    if (-not $rdInfraReg) {
        Write-Log "RD Infra registry not found - agent not registered"
        return $false
    }
    
    if ($rdInfraReg.IsRegistered -eq 1 -and [string]::IsNullOrEmpty($rdInfraReg.RegistrationToken)) {
        Write-Log "Agent is already registered"
        return $true
    }
    
    Write-Log "Agent registration incomplete"
    return $false
}

# ============================================================================
# Get Session Host Name
# ============================================================================
function Get-SessionHostName {
    $wmi = Get-WmiObject win32_computersystem
    
    if ($wmi.Domain -eq "WORKGROUP") {
        return "$($wmi.DNSHostName)"
    }
    
    return "$($wmi.DNSHostName).$($wmi.Domain)"
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

try {
    Write-Log "========================================"
    Write-Log "AVD Agent Installation Script Starting"
    Write-Log "========================================"
    Write-Log "HostPool: $HostPoolName"
    Write-Log "AAD Join: $AadJoin"
    
    # Check if already registered
    if (Test-AgentRegistration) {
        $sessionHostName = Get-SessionHostName
        Write-Log "VM '$sessionHostName' is already registered to a hostpool. Skipping installation."
        exit 0
    }
    
    # Detect Azure environment
    $azureEnvironment = Get-AzureEnvironment
    Write-Log "Azure Environment: $azureEnvironment"
    
    # Get MSI endpoints for the environment
    $msiEndpoints = Get-MSIEndpoints -Environment $azureEnvironment
    
    # Create temp directory for downloads
    $tempDir = "$env:TEMP\AVDAgentInstall_$(Get-Date -Format 'yyyyMMddHHmmss')"
    New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
    Write-Log "Created temp directory: $tempDir"
    
    # Download MSI files
    $bootLoaderPath = Join-Path $tempDir "RDAgentBootLoader.msi"
    $agentPath = Join-Path $tempDir "RDAgent.msi"
    
    Download-MSI -Url $msiEndpoints.BootLoader -OutputPath $bootLoaderPath -Name "RD Agent Boot Loader"
    Download-MSI -Url $msiEndpoints.Agent -OutputPath $agentPath -Name "RD Infra Agent"
    
    # Uninstall existing agents
    Uninstall-ExistingAgents
    
    # Install RD Infra Agent first (with registration token)
    Write-Log "Installing RD Infrastructure Agent..."
    $agentExitCode = Install-MSI -MsiPath $agentPath `
                                  -DisplayName "RD Infra Agent" `
                                  -AdditionalArgs "REGISTRATIONTOKEN=$RegistrationToken" `
                                  -VerboseLogging $EnableVerboseMsiLogging
    
    # Install Boot Loader
    Write-Log "Installing RD Agent Boot Loader..."
    $bootLoaderExitCode = Install-MSI -MsiPath $bootLoaderPath `
                                       -DisplayName "RD Agent Boot Loader" `
                                       -VerboseLogging $EnableVerboseMsiLogging
    
    # Wait for and start the boot loader service
    Write-Log "Waiting for RDAgentBootLoader service..."
    $maxWaitTime = 180
    $waitedTime = 0
    $serviceFound = $false
    
    while ($waitedTime -lt $maxWaitTime) {
        $service = Get-Service -Name "RDAgentBootLoader" -ErrorAction SilentlyContinue
        if ($service) {
            $serviceFound = $true
            Write-Log "RDAgentBootLoader service found"
            break
        }
        
        Start-Sleep -Seconds 10
        $waitedTime += 10
        Write-Log "Waiting for service... ($waitedTime seconds)"
    }
    
    if (-not $serviceFound) {
        throw "RDAgentBootLoader service not found after $maxWaitTime seconds"
    }
    
    Write-Log "Starting RDAgentBootLoader service..."
    Start-Service -Name "RDAgentBootLoader"
    
    $service = Get-Service -Name "RDAgentBootLoader"
    Write-Log "RDAgentBootLoader service status: $($service.Status)"
    
    # Additional wait for AAD joined machines (Intune metadata logging)
    if ($AadJoin) {
        Write-Log "AAD Join detected - waiting 6 minutes for Intune metadata..."
        Start-Sleep -Seconds 360
        Write-Log "Intune wait complete"
    }
    
    # Cleanup
    Write-Log "Cleaning up temporary files..."
    Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    
    # Final verification
    if (Test-AgentRegistration) {
        $sessionHostName = Get-SessionHostName
        Write-Log "========================================"
        Write-Log "SUCCESS: VM '$sessionHostName' successfully registered to HostPool '$HostPoolName'"
        Write-Log "========================================"
        exit 0
    }
    else {
        throw "Agent installation completed but registration verification failed"
    }
}
catch {
    Write-Log "========================================"
    Write-Log "ERROR: Agent installation failed" -Err
    Write-Log "Error details: $_" -Err
    Write-Log "========================================"
    
    # Cleanup on error
    if (Test-Path $tempDir) {
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    
    exit 1
}
