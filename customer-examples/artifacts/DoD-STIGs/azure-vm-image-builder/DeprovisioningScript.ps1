<#
.SYNOPSIS
    Restores final STIG policy and generalizes an Azure VM Image Builder build VM.

.DESCRIPTION
    Apply-STIGsAVD.ps1 installs this file at C:\DeprovisioningScript.ps1 when invoked with
    -ExecutionProfile AzureVMImageBuilder. Azure VM Image Builder executes that exact path from
    its hidden final customizer. The script removes temporary WinRM compatibility state before
    running the standard Azure VM Image Builder Sysprep sequence.
#>
$ErrorActionPreference = 'Stop'
$requiredImageState = 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE'
$statePath = Join-Path -Path $env:ProgramData -ChildPath 'FederalAVD\DoD-STIGs\AzureVMImageBuilder.state'
$tempDirectory = Join-Path -Path $env:SystemRoot -ChildPath "Temp\Finalize-STIGsForAIB-$([guid]::NewGuid().ToString('N'))"
$logDirectory = Join-Path -Path $env:SystemRoot -ChildPath 'Logs\Configuration'
$logPath = Join-Path -Path $logDirectory -ChildPath 'Finalize-STIGsForAzureVMImageBuilder.log'

Function Write-FinalizerLog {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $entry = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')] $Message"
    Write-Host $entry
    Add-Content -LiteralPath $logPath -Value $entry -Encoding ASCII
}

Function Add-LgpoRegistrySetting {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $true)]
        [string]$RegistryKeyPath,
        [Parameter(Mandatory = $true)]
        [string]$RegistryValue,
        [Parameter(Mandatory = $true)]
        [string]$RegistryData
    )

    Add-Content -LiteralPath $FilePath -Encoding Unicode -Value @(
        'Computer'
        $RegistryKeyPath
        $RegistryValue
        "DWORD:$RegistryData"
        ''
    )
}

Function Set-DwordRegistryValue {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [int]$Value
    )

    If (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        $null = New-Item -Path $Path -ItemType Directory -Force
    }
    $null = New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType DWord -Value $Value -Force
}

$null = New-Item -Path $tempDirectory -ItemType Directory -Force
$null = New-Item -Path $logDirectory -ItemType Directory -Force

Try {
    If (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw "Azure VM Image Builder state file was not found at '$statePath'."
    }
    $stateValue = (Get-Content -LiteralPath $statePath -Raw).Trim()
    If ($stateValue -notin @('True', 'False')) {
        throw "Azure VM Image Builder state file contains invalid value '$stateValue'."
    }
    $intendedDomainJoined = $stateValue -eq 'True'

    $lgpoPath = Join-Path -Path $env:SystemRoot -ChildPath 'System32\LGPO.exe'
    If (-not (Test-Path -LiteralPath $lgpoPath -PathType Leaf)) {
        throw "LGPO.exe was not found at '$lgpoPath'. Run Apply-STIGsAVD.ps1 before deprovisioning."
    }

    Write-FinalizerLog -Message 'Restoring final registry-based policy before Azure VM Image Builder Sysprep.'
    $lgpoTextPath = Join-Path -Path $tempDirectory -ChildPath 'AIB-Final-Policy.txt'
    $null = New-Item -Path $lgpoTextPath -ItemType File -Force

    Add-LgpoRegistrySetting -FilePath $lgpoTextPath -RegistryKeyPath 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -RegistryValue 'LocalAccountTokenFilterPolicy' -RegistryData '0'
    Add-LgpoRegistrySetting -FilePath $lgpoTextPath -RegistryKeyPath 'SOFTWARE\Policies\Microsoft\Windows\WinRM\Service' -RegistryValue 'AllowBasic' -RegistryData '0'
    If ($intendedDomainJoined) {
        Add-LgpoRegistrySetting -FilePath $lgpoTextPath -RegistryKeyPath 'SOFTWARE\Policies\Microsoft\WindowsFirewall\DomainProfile' -RegistryValue 'AllowLocalPolicyMerge' -RegistryData '0'
        Add-LgpoRegistrySetting -FilePath $lgpoTextPath -RegistryKeyPath 'SOFTWARE\Policies\Microsoft\WindowsFirewall\PrivateProfile' -RegistryValue 'AllowLocalPolicyMerge' -RegistryData '0'
        Add-LgpoRegistrySetting -FilePath $lgpoTextPath -RegistryKeyPath 'SOFTWARE\Policies\Microsoft\WindowsFirewall\PublicProfile' -RegistryValue 'AllowLocalPolicyMerge' -RegistryData '0'
    }

    $lgpo = Start-Process -FilePath $lgpoPath -ArgumentList "/t `"$lgpoTextPath`"" -Wait -PassThru
    If ($lgpo.ExitCode -ne 0) {
        throw "LGPO.exe failed to restore final registry policy with exit code [$($lgpo.ExitCode)]."
    }

    Set-DwordRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'LocalAccountTokenFilterPolicy' -Value 0
    Set-DwordRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WinRM\Service' -Name 'AllowBasic' -Value 0
    If ($intendedDomainJoined) {
        Set-DwordRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall\DomainProfile' -Name 'AllowLocalPolicyMerge' -Value 0
        Set-DwordRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall\PrivateProfile' -Name 'AllowLocalPolicyMerge' -Value 0
        Set-DwordRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall\PublicProfile' -Name 'AllowLocalPolicyMerge' -Value 0
        Write-FinalizerLog -Message 'Restored domain-oriented firewall local-policy merge restrictions.'
    }
    Else {
        Write-FinalizerLog -Message 'Retained workgroup firewall local-policy merge behavior.'
    }

    Write-FinalizerLog -Message 'Restoring local-account deny-network-logon principals.'
    $securityPolicyPath = Join-Path -Path $tempDirectory -ChildPath 'SecurityPolicy.inf'
    $securityDatabasePath = Join-Path -Path $tempDirectory -ChildPath 'SecurityPolicy.sdb'
    $seceditExport = Start-Process -FilePath 'secedit.exe' -ArgumentList "/export /cfg `"$securityPolicyPath`" /areas USER_RIGHTS" -Wait -PassThru
    If ($seceditExport.ExitCode -ne 0) {
        throw "secedit.exe failed to export user rights with exit code [$($seceditExport.ExitCode)]."
    }

    $securityPolicy = @(Get-Content -LiteralPath $securityPolicyPath -Encoding Unicode)
    $denyNetworkLogonIndex = -1
    For ($index = 0; $index -lt $securityPolicy.Count; $index++) {
        If ($securityPolicy[$index] -match '^SeDenyNetworkLogonRight\s*=') {
            If ($denyNetworkLogonIndex -ne -1) {
                throw 'The exported security policy contains multiple SeDenyNetworkLogonRight assignments.'
            }
            $denyNetworkLogonIndex = $index
        }
    }
    If ($denyNetworkLogonIndex -eq -1) {
        throw 'SeDenyNetworkLogonRight was not found in the exported security policy.'
    }

    $existingPrincipals = @($securityPolicy[$denyNetworkLogonIndex].Split('=', 2)[1].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $finalPrincipals = @($existingPrincipals + '*S-1-5-113' + '*S-1-5-114' | Select-Object -Unique)
    $securityPolicy[$denyNetworkLogonIndex] = "SeDenyNetworkLogonRight = $($finalPrincipals -join ',')"
    Set-Content -LiteralPath $securityPolicyPath -Value $securityPolicy -Encoding Unicode

    $seceditConfigure = Start-Process -FilePath 'secedit.exe' -ArgumentList "/configure /db `"$securityDatabasePath`" /cfg `"$securityPolicyPath`" /areas USER_RIGHTS" -Wait -PassThru
    If ($seceditConfigure.ExitCode -ne 0) {
        throw "secedit.exe failed to restore user rights with exit code [$($seceditConfigure.ExitCode)]."
    }

    Remove-Item -LiteralPath $statePath -Force
    Write-FinalizerLog -Message 'Waiting for installed Azure Guest Agent services required by Sysprep.'
    $agentDeadline = (Get-Date).AddMinutes(5)
    ForEach ($serviceName in 'RdAgent', 'WindowsAzureTelemetryService', 'WindowsAzureGuestAgent') {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        If ($service) {
            While ($service.Status -ne 'Running') {
                If ((Get-Date) -ge $agentDeadline) {
                    throw "Service '$serviceName' did not reach Running state before the timeout."
                }
                Start-Service -Name $serviceName -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 5
                $service.Refresh()
            }
        }
    }

    Write-FinalizerLog -Message 'Starting Azure VM Image Builder Sysprep.'
    $sysprepPath = Join-Path -Path $env:SystemRoot -ChildPath 'System32\Sysprep\Sysprep.exe'
    $sysprep = Start-Process -FilePath $sysprepPath -ArgumentList '/oobe /generalize /quiet /quit /mode:vm' -Wait -PassThru
    If ($sysprep.ExitCode -ne 0) {
        throw "Sysprep.exe failed with exit code [$($sysprep.ExitCode)]."
    }

    Do {
        $imageState = Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -Name 'ImageState'
        Write-FinalizerLog -Message "Current Windows image state: $imageState"
        If ($imageState -eq $requiredImageState) {
            break
        }
        Start-Sleep -Seconds 5
    } While ($true)

    Write-FinalizerLog -Message 'Windows is generalized. Azure VM Image Builder can capture the image.'
}
Finally {
    If (Test-Path -LiteralPath $tempDirectory) {
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}