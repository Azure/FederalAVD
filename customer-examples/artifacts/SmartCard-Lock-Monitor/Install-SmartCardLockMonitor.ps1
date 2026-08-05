#region Initialization
$Script:Name    = 'Install-SmartCardLockMonitor'
$Script:InstallDir = 'C:\ProgramData\FederalAVD\SmartCardLock'
$Script:TaskName   = 'SmartCard-Lock-Monitor'
$Script:EventSource = 'SmartCardLockMonitor'
#endregion

#region Supporting Functions
Function Write-Log {
    Param (
        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateSet('Info', 'Warning', 'Error')]
        $Category = 'Info',
        [Parameter(Mandatory = $true, Position = 1)]
        $Message
    )
    $Content = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')]`t$Category`t`t$Message"
    if (-not $env:SUPPRESS_FILELOG) { Add-Content $Script:Log $Content -ErrorAction SilentlyContinue }
    Switch ($Category) {
        'Info'    { Write-Host $Content }
        'Error'   { Write-Error $Content -ErrorAction Continue }
        'Warning' { Write-Warning $Content }
    }
}

Function New-Log {
    Param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Path
    )
    if ($env:SUPPRESS_FILELOG -eq '1') { return }
    $date = Get-Date -UFormat '%Y-%m-%d %H-%M-%S'
    Set-Variable logFile -Scope Script
    $Script:logFile = "$Script:Name-$date.log"
    if (-not (Test-Path $Path)) { $null = New-Item -Path $Path -ItemType Directory }
    $Script:Log = Join-Path $Path $Script:logFile
    Add-Content $Script:Log 'Date`t`t`tCategory`t`tDetails'
}
#endregion

#region Main
New-Log -Path 'C:\Windows\Logs\Configuration'
Write-Log -Category 'Info' -Message "Starting $Script:Name"

# ---- Require elevation ----
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log -Category 'Error' -Message 'This script must run as Administrator or SYSTEM.'
    exit 1
}

# ---- Copy monitoring script to persistent install location ----
Write-Log -Category 'Info' -Message "Creating install directory: $Script:InstallDir"
if (-not (Test-Path $Script:InstallDir)) {
    $null = New-Item -Path $Script:InstallDir -ItemType Directory -Force
}

$MonitorScript = Join-Path $PSScriptRoot 'Watch-SmartCardRemoval.ps1'
if (-not (Test-Path $MonitorScript)) {
    Write-Log -Category 'Error' -Message "Watch-SmartCardRemoval.ps1 not found in $PSScriptRoot"
    exit 1
}

$VbsLauncher = Join-Path $PSScriptRoot 'Watch-SmartCardRemoval.vbs'
if (-not (Test-Path $VbsLauncher)) {
    Write-Log -Category 'Error' -Message "Watch-SmartCardRemoval.vbs not found in $PSScriptRoot"
    exit 1
}

$Destination    = Join-Path $Script:InstallDir 'Watch-SmartCardRemoval.ps1'
$VbsDestination = Join-Path $Script:InstallDir 'Watch-SmartCardRemoval.vbs'
Copy-Item -Path $MonitorScript -Destination $Destination    -Force
Copy-Item -Path $VbsLauncher  -Destination $VbsDestination -Force
Write-Log -Category 'Info' -Message "Monitoring script copied to: $Destination"
Write-Log -Category 'Info' -Message "VBScript launcher copied to: $VbsDestination"

# Restrict write access so standard users cannot tamper with the script
$Acl = Get-Acl -Path $Script:InstallDir
$Acl.SetAccessRuleProtection($true, $false)
$BuiltinAdmins  = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
$SystemAccount  = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
$BuiltinUsers   = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')
foreach ($Sid in @($BuiltinAdmins, $SystemAccount)) {
    $Rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $Sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $Acl.AddAccessRule($Rule)
}
# Users get ReadAndExecute only - cannot modify the monitoring script
$Rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $BuiltinUsers, 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
$Acl.AddAccessRule($Rule)
Set-Acl -Path $Script:InstallDir -AclObject $Acl
Write-Log -Category 'Info' -Message 'ACL restricted: Users=ReadAndExecute, Admins/SYSTEM=FullControl'

# ---- Register Windows Event Log source ----
if (-not [System.Diagnostics.EventLog]::SourceExists($Script:EventSource)) {
    [System.Diagnostics.EventLog]::CreateEventSource($Script:EventSource, 'Application')
    Write-Log -Category 'Info' -Message "Event log source created: $Script:EventSource"
} else {
    Write-Log -Category 'Info' -Message "Event log source already exists: $Script:EventSource"
}

# ---- Register scheduled task ----
# The task triggers at logon for ANY user (BUILTIN\Users principal, RunLevel Limited).
# PowerShell is launched with -WindowStyle Hidden so no console window appears.
# ExecutionTimeLimit = PT0S means the task runs indefinitely until the user logs off.

# Use wscript.exe + VBScript launcher so no console window or taskbar entry appears.
# powershell.exe -WindowStyle Hidden still briefly creates a console host; wscript.exe
# with window style 0 prevents any window from ever being created.
$TaskAction = New-ScheduledTaskAction `
    -Execute 'wscript.exe' `
    -Argument "`"$VbsDestination`""

$TaskTrigger = New-ScheduledTaskTrigger -AtLogOn

$TaskPrincipal = New-ScheduledTaskPrincipal `
    -GroupId 'BUILTIN\Users' `
    -RunLevel Limited

$TaskSettings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew `
    -DisallowStartIfOnBatteries $false `
    -StopIfGoingOnBatteries $false `
    -StartWhenAvailable

# Remove any existing copy of the task before registering
$Existing = Get-ScheduledTask -TaskName $Script:TaskName -ErrorAction SilentlyContinue
if ($Existing) {
    Unregister-ScheduledTask -TaskName $Script:TaskName -Confirm:$false
    Write-Log -Category 'Info' -Message "Removed existing scheduled task: $Script:TaskName"
}

Register-ScheduledTask `
    -TaskName $Script:TaskName `
    -Action $TaskAction `
    -Trigger $TaskTrigger `
    -Principal $TaskPrincipal `
    -Settings $TaskSettings `
    -Description 'Monitors smart card state via PC/SC redirection and locks the workstation when the card is removed. Deployed by FederalAVD.' `
    | Out-Null

Write-Log -Category 'Info' -Message "Scheduled task registered: $Script:TaskName"
Write-Log -Category 'Info' -Message "Task launches via wscript.exe + VBScript (window style 0). No console window or taskbar entry will appear."
Write-Log -Category 'Info' -Message "$Script:Name completed successfully."
#endregion
