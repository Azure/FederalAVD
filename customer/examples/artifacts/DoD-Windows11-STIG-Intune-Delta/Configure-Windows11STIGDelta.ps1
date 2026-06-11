<#
.SYNOPSIS
    Applies the Windows 11 STIG Intune Delta security configuration.

.DESCRIPTION
    Processes the GptTmpl.inf security template located alongside this script,
    substitutes or strips domain group placeholder tokens, applies the template
    via secedit.exe, sets additional required registry values, disables PowerShell
    version 2.0, and removes the "Run as different user" context menu entries.

.NOTES
    Must be run as a local administrator or SYSTEM.
    Designed for Entra ID-joined (non-domain-joined) AVD session hosts managed via Intune.
#>
[CmdletBinding()]

#region Initialization
$Script:Name = 'Configure-Windows11STIGDelta'
[bool]$IsDomainJoined = (Get-WmiObject -Class Win32_ComputerSystem).PartOfDomain
#endregion

#region Functions

Function New-Log {
    [CmdletBinding()]
    Param (
        [Parameter(Position = 0)]
        [string] $Path = (Join-Path -Path $env:SystemRoot -ChildPath 'Logs')
    )

    if ($env:SUPPRESS_FILELOG -eq '1') { return }
    $date = Get-Date -UFormat "%Y-%m-%d %H-%M-%S"
    Set-Variable logFile -Scope Script
    $script:logFile = "$Script:Name-$date.log"

    if ((Test-Path $path) -eq $false) {
        $null = New-Item -Path $path -ItemType Directory
    }

    $script:Log = Join-Path $path $logfile
    Add-Content $script:Log "Date`t`t`tCategory`t`tDetails"
}

Function Write-Log {
    Param (
        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateSet('Info', 'Warning', 'Error')]
        $Category = 'Info',
        [Parameter(Mandatory = $true, Position = 1)]
        $Message
    )

    $Content = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')]`t$Category`t`t$Message"
    if (-not $env:SUPPRESS_FILELOG) {
        Add-Content $Script:Log $Content -ErrorAction SilentlyContinue
    }
    Switch ($Category) {
        'Info'    { Write-Host $Content }
        'Error'   { Write-Error $Content -ErrorAction Continue }
        'Warning' { Write-Warning $Content }
    }
}

Function Set-RegistryValue {
    [CmdletBinding()]
    param (
        [Parameter()] [string] $Name,
        [Parameter()] [string] $Path,
        [Parameter()] [string] $PropertyType,
        [Parameter()] $Value
    )
    Begin {
        Write-Log -Message "[Set-RegistryValue]: Setting Registry Value: $Name"
    }
    Process {
        If (!(Test-Path -Path $Path)) {
            Write-Log -Message "[Set-RegistryValue]: Creating Registry Key: $Path"
            New-Item -Path $Path -Force | Out-Null
        }
        $RemoteValue = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        If ($RemoteValue) {
            $CurrentValue = Get-ItemPropertyValue -Path $Path -Name $Name
            Write-Log -Message "[Set-RegistryValue]: Current Value of $($Path)\$($Name) : $CurrentValue"
            If ($Value -ne $CurrentValue) {
                Write-Log -Message "[Set-RegistryValue]: Setting Value of $($Path)\$($Name) : $Value"
                Set-ItemProperty -Path $Path -Name $Name -Value $Value -Force | Out-Null
            }
            Else {
                Write-Log -Message "[Set-RegistryValue]: Value of $($Path)\$($Name) is already set to $Value"
            }
        }
        Else {
            Write-Log -Message "[Set-RegistryValue]: Setting Value of $($Path)\$($Name) : $Value"
            New-ItemProperty -Path $Path -Name $Name -PropertyType $PropertyType -Value $Value -Force | Out-Null
        }
        Start-Sleep -Milliseconds 500
    }
}

Function Disable-OptionalFeatureIfEnabled {
    param(
        [Parameter(Mandatory)] [string] $FeatureName,
        [Parameter(Mandatory)] [string] $StigId
    )
    $feature = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction SilentlyContinue
    if ($feature -and $feature.State -eq 'Enabled') {
        Write-Log -Message "${StigId}: Disabling Windows Optional Feature '$FeatureName'."
        Disable-WindowsOptionalFeature -Online -FeatureName $FeatureName -NoRestart -ErrorAction SilentlyContinue | Out-Null
    }
    else {
        Write-Log -Message "${StigId}: '$FeatureName' is already disabled or not present. No action required."
    }
}

#endregion

#region Main

New-Log -Path (Join-Path -Path "$env:SystemRoot\Logs" -ChildPath 'Configuration')
Write-Log -Message "Starting '$PSCommandPath'."
Write-Log -Message "Domain-joined: $IsDomainJoined"

# -- Step 1: Process GptTmpl.inf ------------------------------------------------
$SecEditFile = Join-Path -Path $PSScriptRoot -ChildPath 'GptTmpl.inf'
if (-not (Test-Path -LiteralPath $SecEditFile)) {
    Write-Log -Category Error -Message "GptTmpl.inf not found at '$SecEditFile'. Aborting."
    Exit 1
}

Write-Log -Message "[GptTmpl] Reading '$SecEditFile'."
$Content = Get-Content -Path $SecEditFile -Encoding Unicode

# Replace or remove the 'ADD YOUR ENTERPRISE ADMINS' / 'ADD YOUR DOMAIN ADMINS'
# placeholder tokens that the DoD STIG template leaves in the [Privilege Rights] section.
if ($IsDomainJoined) {
    Write-Log -Message "[GptTmpl] Replacing 'ADD YOUR ENTERPRISE ADMINS' and 'ADD YOUR DOMAIN ADMINS' with actual group names — domain-joined host."
    $Content | Where-Object { $_ -match 'ADD YOUR ENTERPRISE ADMINS|ADD YOUR DOMAIN ADMINS' } | ForEach-Object {
        $replaced = $_ -replace 'ADD YOUR ENTERPRISE ADMINS', 'Enterprise Admins' -replace 'ADD YOUR DOMAIN ADMINS', 'Domain Admins'
        Write-Log -Message "[GptTmpl] BEFORE : $_"
        Write-Log -Message "[GptTmpl] AFTER  : $replaced"
    }
    $Content = $Content -replace 'ADD YOUR ENTERPRISE ADMINS', 'Enterprise Admins'
    $Content = $Content -replace 'ADD YOUR DOMAIN ADMINS', 'Domain Admins'
}
else {
    # Non-domain-joined: remove the entire user right lines that contain the placeholders.
    # SeDenyBatchLogonRight and SeDenyServiceLogonRight are only meaningful for domain groups;
    # leaving them empty or unconfigured is the correct posture on Entra-joined/workgroup hosts.
    Write-Log -Message "[GptTmpl] Non-domain-joined host — removing lines containing 'ADD YOUR ENTERPRISE ADMINS' or 'ADD YOUR DOMAIN ADMINS' entirely."
    $Content | Where-Object { $_ -match 'ADD YOUR ENTERPRISE ADMINS|ADD YOUR DOMAIN ADMINS' } |
        ForEach-Object { Write-Log -Message "[GptTmpl] REMOVED LINE: $_" }
    $Content = $Content | Where-Object { $_ -notmatch 'ADD YOUR ENTERPRISE ADMINS|ADD YOUR DOMAIN ADMINS' }
}

Write-Log -Message "[GptTmpl] Writing updated template back to '$SecEditFile'."
Set-Content -Path $SecEditFile -Value $Content -Encoding Unicode

# -- Step 2: Apply security template via secedit.exe ----------------------------
$seceditDb  = Join-Path -Path $env:TEMP -ChildPath 'delta-secedit.sdb'
$seceditLog = Join-Path -Path $env:TEMP -ChildPath 'delta-secedit.log'

Write-Log -Message "Applying security template via secedit: '$SecEditFile'."
$secedit = Start-Process -FilePath 'secedit.exe' `
    -ArgumentList "/configure /cfg `"$SecEditFile`" /db `"$seceditDb`" /log `"$seceditLog`" /quiet" `
    -Wait -PassThru -NoNewWindow
Write-Log -Message "secedit.exe exited with code [$($secedit.ExitCode)]."
if ($secedit.ExitCode -ne 0) {
    Write-Log -Category Warning -Message "secedit returned a non-zero exit code. Review log at '$seceditLog'."
}

# -- Step 3: Registry values ----------------------------------------------------
# V-253408 MEDIUM: Basic authentication for RSS feeds over HTTP must not be used.
# STIG requires AllowBasicAuthInClear = 0 (or the value must not exist with value 1).
# Setting it explicitly to 0 ensures compliance regardless of prior state.
Write-Log -Message "V-253408: Setting 'AllowBasicAuthInClear' to 0 under Internet Explorer Feeds policy."
Set-RegistryValue `
    -Name 'AllowBasicAuthInClear' `
    -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Internet Explorer\Feeds' `
    -PropertyType 'DWORD' `
    -Value 0

# -- Step 4: Disable prohibited Windows Optional Features / Capabilities -------
# V-253275 HIGH: IIS must not be installed.
Disable-OptionalFeatureIfEnabled -FeatureName 'IIS-WebServer'                    -StigId 'V-253275'
Disable-OptionalFeatureIfEnabled -FeatureName 'IIS-HostableWebCore'              -StigId 'V-253275'

# V-253276 MEDIUM: SNMP must not be installed.
# On Windows 11 SNMP ships as a Windows Capability; also check the legacy optional feature name.
$snmpCap = Get-WindowsCapability -Online -Name 'SNMP.Client~~~~0.0.1.0' -ErrorAction SilentlyContinue
if ($snmpCap -and $snmpCap.State -eq 'Installed') {
    Write-Log -Message 'V-253276: Removing SNMP Client Windows Capability.'
    Remove-WindowsCapability -Online -Name 'SNMP.Client~~~~0.0.1.0' -ErrorAction SilentlyContinue | Out-Null
}
else {
    Write-Log -Message 'V-253276: SNMP Client capability not installed. No action required.'
}
Disable-OptionalFeatureIfEnabled -FeatureName 'SNMP'                             -StigId 'V-253276'

# V-253277 MEDIUM: Simple TCP/IP Services must not be installed.
Disable-OptionalFeatureIfEnabled -FeatureName 'SimpleTCP'                        -StigId 'V-253277'

# V-253278 MEDIUM: Telnet Client must not be installed.
Disable-OptionalFeatureIfEnabled -FeatureName 'TelnetClient'                     -StigId 'V-253278'

# V-253279 MEDIUM: TFTP Client must not be installed.
Disable-OptionalFeatureIfEnabled -FeatureName 'TFTP'                             -StigId 'V-253279'

# V-253285 HIGH: PowerShell 2.0 must not be installed.
# The root feature must be disabled first; the engine feature depends on it.
Disable-OptionalFeatureIfEnabled -FeatureName 'MicrosoftWindowsPowerShellV2Root' -StigId 'V-253285'
Disable-OptionalFeatureIfEnabled -FeatureName 'MicrosoftWindowsPowerShellV2'     -StigId 'V-253285'

# V-253286 MEDIUM: SMB v1 protocol must be disabled.
Disable-OptionalFeatureIfEnabled -FeatureName 'SMB1Protocol'                     -StigId 'V-253286'

# -- Step 5: Remove "Run as different user" from context menus -----------------
# V-253359 MEDIUM: Run as different user must be removed from context menus.
# SuppressionPolicy = 4096 (0x1000) hides the shell verb from the context menu.
Write-Log -Message "V-253359: Removing 'Run as different user' from context menus."
Set-RegistryValue -Name 'SuppressionPolicy' -Path 'HKLM:\SOFTWARE\Classes\batfile\shell\runasuser' -PropertyType 'DWORD' -Value 4096
Set-RegistryValue -Name 'SuppressionPolicy' -Path 'HKLM:\SOFTWARE\Classes\cmdfile\shell\runasuser' -PropertyType 'DWORD' -Value 4096
Set-RegistryValue -Name 'SuppressionPolicy' -Path 'HKLM:\SOFTWARE\Classes\exefile\shell\runasuser' -PropertyType 'DWORD' -Value 4096
Set-RegistryValue -Name 'SuppressionPolicy' -Path 'HKLM:\SOFTWARE\Classes\mscfile\shell\runasuser' -PropertyType 'DWORD' -Value 4096

Write-Log -Message "Ending '$PSCommandPath'."
#endregion
