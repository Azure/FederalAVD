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

# -- Step 1: Build security template (GptTmpl.inf) dynamically -----------------
# Each setting is annotated with its STIG V-ID. To validate coverage against a
# new STIG version, search this file for the V-ID and compare the required value.
$SecEditFile = Join-Path -Path $env:TEMP -ChildPath 'delta-secedit.inf'
$infLines    = [System.Collections.Generic.List[string]]::new()

$infLines.Add('[Unicode]')
$infLines.Add('Unicode=yes')
$infLines.Add('[Version]')
$infLines.Add('signature="$CHICAGO$"')
$infLines.Add('Revision=1')

# ---- [System Access] --------------------------------------------------------
$infLines.Add('[System Access]')

# V-253304: The built-in Microsoft password complexity filter must be enabled.
Write-Log -Message 'V-253304: PasswordComplexity = 1'
$infLines.Add('PasswordComplexity = 1')

# V-253300: The password history must be configured to 24 passwords remembered.
Write-Log -Message 'V-253300: PasswordHistorySize = 24'
$infLines.Add('PasswordHistorySize = 24')

# V-253303: Passwords must, at a minimum, be 14 characters.
Write-Log -Message 'V-253303: MinimumPasswordLength = 14'
$infLines.Add('MinimumPasswordLength = 14')

# V-253298: The number of allowed bad logon attempts must be three or less.
Write-Log -Message 'V-253298: LockoutBadCount = 3'
$infLines.Add('LockoutBadCount = 3')

# V-253299: The period before the bad logon counter resets must be 15 minutes.
Write-Log -Message 'V-253299: ResetLockoutCount = 15'
$infLines.Add('ResetLockoutCount = 15')

# V-253297: Account lockout duration must be 15 minutes or greater.
Write-Log -Message 'V-253297: LockoutDuration = 15'
$infLines.Add('LockoutDuration = 15')

# V-253305: Reversible password encryption must be disabled.
Write-Log -Message 'V-253305: ClearTextPassword = 0'
$infLines.Add('ClearTextPassword = 0')

# V-253452: Anonymous SID/Name translation must not be allowed.
Write-Log -Message 'V-253452: LSAAnonymousNameLookup = 0'
$infLines.Add('LSAAnonymousNameLookup = 0')

# ---- [Registry Values] ------------------------------------------------------
$infLines.Add('[Registry Values]')

# V-253447: Caching of logon credentials must be limited.
Write-Log -Message 'V-253447: CachedLogonsCount = 10'
$infLines.Add('MACHINE\Software\Microsoft\Windows NT\CurrentVersion\Winlogon\CachedLogonsCount=1,"10"')

# V-253460: Kerberos encryption must prevent DES and RC4 (AES128/AES256/Future only).
Write-Log -Message 'V-253460: SupportedEncryptionTypes = 2147483640'
$infLines.Add('MACHINE\Software\Microsoft\Windows\CurrentVersion\Policies\System\Kerberos\Parameters\SupportedEncryptionTypes=4,2147483640')

# V-253455: Anonymous users must not have the same rights as the Everyone group.
Write-Log -Message 'V-253455: EveryoneIncludesAnonymous = 0'
$infLines.Add('MACHINE\System\CurrentControlSet\Control\Lsa\EveryoneIncludesAnonymous=4,0')

# V-253458: NTLM must be prevented from falling back to a Null session.
Write-Log -Message 'V-253458: allownullsessionfallback = 0'
$infLines.Add('MACHINE\System\CurrentControlSet\Control\Lsa\MSV1_0\allownullsessionfallback=4,0')

# V-253437: Audit policy using subcategories must be enabled.
Write-Log -Message 'V-253437: SCENoApplyLegacyAuditPolicy = 1'
$infLines.Add('MACHINE\System\CurrentControlSet\Control\Lsa\SCENoApplyLegacyAuditPolicy=4,1')

# V-253466: FIPS-compliant algorithms must be used for encryption, hashing, and signing.
Write-Log -Message 'V-253466: FipsAlgorithmPolicy Enabled = 1'
$infLines.Add('MACHINE\System\CurrentControlSet\Control\Lsa\FipsAlgorithmPolicy\Enabled=4,1')

# V-253467: The default permissions of global system objects must be increased.
Write-Log -Message 'V-253467: ProtectionMode = 1'
$infLines.Add('MACHINE\System\CurrentControlSet\Control\Session Manager\ProtectionMode=4,1')

# V-253463: LDAP client signing must be required.
Write-Log -Message 'V-253463: LDAPClientIntegrity = 1'
$infLines.Add('MACHINE\System\CurrentControlSet\Services\LDAP\LDAPClientIntegrity=4,1')

# V-253441: The computer account password must not be prevented from being reset.
Write-Log -Message 'V-253441: DisablePasswordChange = 0'
$infLines.Add('MACHINE\System\CurrentControlSet\Services\Netlogon\Parameters\DisablePasswordChange=4,0')

# V-253442: Machine account password maximum age must be 30 days or less.
Write-Log -Message 'V-253442: MaximumPasswordAge = 30'
$infLines.Add('MACHINE\System\CurrentControlSet\Services\Netlogon\Parameters\MaximumPasswordAge=4,30')

# V-253443: A strong session key must be required.
Write-Log -Message 'V-253443: RequireStrongKey = 1'
$infLines.Add('MACHINE\System\CurrentControlSet\Services\Netlogon\Parameters\RequireStrongKey=4,1')

# V-253439: Outgoing secure channel traffic must be encrypted.
Write-Log -Message 'V-253439: SealSecureChannel = 1'
$infLines.Add('MACHINE\System\CurrentControlSet\Services\Netlogon\Parameters\SealSecureChannel=4,1')

# V-253440: Outgoing secure channel traffic must be signed.
Write-Log -Message 'V-253440: SignSecureChannel = 1'
$infLines.Add('MACHINE\System\CurrentControlSet\Services\Netlogon\Parameters\SignSecureChannel=4,1')

# ---- [Privilege Rights] -----------------------------------------------------
$infLines.Add('[Privilege Rights]')
if ($IsDomainJoined) {
    # V-253492: Deny log on as a batch job -- domain-joined hosts only.
    Write-Log -Message 'V-253492: SeDenyBatchLogonRight = Enterprise Admins, Domain Admins'
    $infLines.Add('SeDenyBatchLogonRight = Enterprise Admins,Domain Admins')
    # V-253493: Deny log on as a service -- domain-joined hosts only.
    Write-Log -Message 'V-253493: SeDenyServiceLogonRight = Enterprise Admins, Domain Admins'
    $infLines.Add('SeDenyServiceLogonRight = Enterprise Admins,Domain Admins')
}
else {
    Write-Log -Message 'V-253492/V-253493: Non-domain-joined -- skipping SeDenyBatchLogonRight and SeDenyServiceLogonRight.'
}

# ---- [Service General Setting] ----------------------------------------------
$infLines.Add('[Service General Setting]')
# V-253289: The Secondary Logon service must be disabled.
Write-Log -Message 'V-253289: seclogon startup type = 4 (Disabled)'
$infLines.Add('"seclogon",4,""')

Write-Log -Message "[GptTmpl] Writing generated security template to '$SecEditFile'."
[System.IO.File]::WriteAllLines($SecEditFile, $infLines, [System.Text.Encoding]::Unicode)

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
