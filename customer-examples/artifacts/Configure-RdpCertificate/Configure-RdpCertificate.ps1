#requires -Version 5.1
<#
.SYNOPSIS
    Prepares a host enrollment identity or installs host/CA-side RDP certificate tasks.
.NOTES
    Stage approved PowerShell 7.4+ x64 first. No dependencies are downloaded at runtime.
    Host operations must run as SYSTEM on the final session host, never in an image.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('PrepareHost', 'EnrollHost', 'InstallHost', 'InstallServer')]
    [string]$Mode,

    [string]$ConfigurationPath = 'host.json',

    [string]$EnrollmentCertificatePath,

    [PSCredential]$ServerTaskCredential,

    [string]$PowerShellPath = "$env:ProgramFiles\PowerShell\7\pwsh.exe"
)

$ErrorActionPreference = 'Stop'
if (-not [Environment]::Is64BitProcess) { throw 'Run this installer with 64-bit PowerShell.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Installation requires an elevated administrator or SYSTEM.'
}
if ($Mode -ne 'InstallServer' -and -not $identity.IsSystem) {
    throw 'Host modes must run as SYSTEM on the final session host.'
}
if (-not (Test-Path -LiteralPath $PowerShellPath -PathType Leaf)) {
    throw 'Stage an approved PowerShell 7.4+ x64 installation before using this package.'
}
$version = & $PowerShellPath -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()'
if ($LASTEXITCODE -ne 0 -or [version]$version -lt [version]'7.4') { throw 'PowerShell 7.4+ is required.' }
if (-not [IO.Path]::IsPathRooted($ConfigurationPath)) { $ConfigurationPath = Join-Path $PSScriptRoot $ConfigurationPath }
$configuration = Get-Content -LiteralPath $ConfigurationPath -Raw
$root = Join-Path $env:ProgramData 'FederalAVD\RdpCertificateAutomation'
$data = Join-Path $root 'state'
$scripts = Join-Path $root 'scripts'
if ($PSScriptRoot -eq $root) { throw 'Run the installer from a separate staging directory.' }
foreach ($path in @((Split-Path $root -Parent), $root, $scripts, $data)) {
    if (Test-Path -LiteralPath $path) {
        $item = Get-Item -LiteralPath $path -Force
        $owner = (Get-Acl -LiteralPath $path).GetOwner([Security.Principal.SecurityIdentifier]).Value
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $owner -notin @('S-1-5-18', 'S-1-5-32-544')) {
            throw "Installation directory must be a non-reparse directory owned by SYSTEM/Administrators: $path"
        }
    }
}
$role = if ($Mode -eq 'InstallServer') { 'Server' } else { 'Host' }
$marker = Join-Path $root 'role.txt'
if ((Test-Path -LiteralPath $marker) -and (Get-Content -LiteralPath $marker -Raw).Trim() -ne $role) {
    throw 'Do not install the host and server roles on the same machine.'
}
$serviceSid = $null
if ($Mode -eq 'InstallServer') {
    if ($null -eq $ServerTaskCredential) { throw 'Supply the dedicated non-administrative local service account credential.' }
    $serviceSid = ([Security.Principal.NTAccount]::new($ServerTaskCredential.UserName)).Translate(
        [Security.Principal.SecurityIdentifier]
    )
    $user = Get-LocalUser -SID $serviceSid -ErrorAction Stop
    if (-not $user.Enabled) { throw 'The server task account is disabled.' }
    $administrators = Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction Stop
    if (@(Get-LocalGroupMember -Group $administrators -ErrorAction Stop | Where-Object { $_.SID -eq $serviceSid }).Count) {
        throw 'The server task account must not be a local administrator.'
    }
}

function Set-DirectoryPermissions {
    param([string]$Path, [switch]$WritableState)
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sid), 'FullControl',
            'ContainerInherit,ObjectInherit', 'None', 'Allow'
        ))
    }
    if ($null -ne $serviceSid) {
        $rights = if ($WritableState) { 'Modify' } else { 'ReadAndExecute' }
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $serviceSid, $rights, 'ContainerInherit,ObjectInherit', 'None', 'Allow'
        ))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Set-FilePermissions {
    param([string]$Path)
    if (((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Installation files must not be reparse points: $Path"
    }
    $acl = [Security.AccessControl.FileSecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'Allow'
        ))
    }
    if ($null -ne $serviceSid) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($serviceSid, 'ReadAndExecute', 'Allow'))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

$taskNames = if ($role -eq 'Server') { @('RdpCertificate-EnrollmentServer') } else {
    @('RdpCertificate-Bootstrap', 'RdpCertificate-Renewal')
}
$existingTasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object {
    $_.TaskPath -eq '\FederalAVD\' -and $_.TaskName -in $taskNames
})
foreach ($task in $existingTasks) {
    if ($task.State -eq 'Running') { Stop-ScheduledTask -InputObject $task -ErrorAction Stop }
}
[void](New-Item -ItemType Directory -Path $root -Force)
Set-DirectoryPermissions $root
foreach ($path in @($scripts, $data)) { [void](New-Item -ItemType Directory -Path $path -Force) }
Set-DirectoryPermissions $scripts
Set-DirectoryPermissions $data -WritableState
foreach ($path in @($marker, (Join-Path $root 'configuration.json')) +
    @('Common.ps1', 'Host.ps1', 'Server.ps1', 'Bootstrap.ps1' | ForEach-Object { Join-Path $scripts $_ })) {
    if (Test-Path -LiteralPath $path) { Set-FilePermissions $path }
}
Set-Content -LiteralPath $marker -Value $role -Encoding ascii
Set-Content -LiteralPath (Join-Path $root 'configuration.json') -Value $configuration -Encoding utf8
foreach ($file in @('Common.ps1', 'Host.ps1', 'Server.ps1', 'Bootstrap.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "scripts\$file") -Destination (Join-Path $scripts $file) -Force
    Set-FilePermissions (Join-Path $scripts $file)
}
Set-FilePermissions $marker
Set-FilePermissions (Join-Path $root 'configuration.json')
$hostScript = Join-Path $scripts 'Host.ps1'
if ($Mode -eq 'PrepareHost') {
    & $PowerShellPath -NoProfile -NonInteractive -File $hostScript -Operation Prepare
    if ($LASTEXITCODE -ne 0) { throw 'Host enrollment preparation failed.' }
    return
}
if ($Mode -eq 'InstallHost') {
    if (-not $EnrollmentCertificatePath) { throw 'Supply the trusted provisioning response for the prepared enrollment CSR.' }
    & $PowerShellPath -NoProfile -NonInteractive -File $hostScript `
        -Operation InstallCredential -CertificatePath $EnrollmentCertificatePath
    if ($LASTEXITCODE -ne 0) { throw 'Enrollment credential validation/installation failed; tasks were not installed.' }
}
elseif ($Mode -eq 'InstallServer') {
    & $PowerShellPath -NoProfile -NonInteractive -File (Join-Path $scripts 'Server.ps1') -ValidateConfiguration
    if ($LASTEXITCODE -ne 0) { throw 'CA configuration validation failed; the endpoint task was not installed.' }
}

$scheduler = New-Object -ComObject Schedule.Service
$scheduler.Connect()
$schedulerRoot = $scheduler.GetFolder('\')
if (@($schedulerRoot.GetFolders(0) | Where-Object { $_.Name -eq 'FederalAVD' }).Count -eq 0) {
    [void]$schedulerRoot.CreateFolder('FederalAVD', 'D:P(A;;GA;;;SY)(A;;GA;;;BA)')
}
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::FromMinutes(10)) -RestartCount 3 -RestartInterval ([TimeSpan]::FromMinutes(5))
if ($role -eq 'Host') {
    $operation = if ($Mode -eq 'EnrollHost') { 'Enroll' } else { 'Run' }
    $action = New-ScheduledTaskAction -Execute $PowerShellPath `
        -Argument "-NoProfile -NonInteractive -File `"$hostScript`" -Operation $operation"
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    $bootstrapTriggers = @(
        (New-ScheduledTaskTrigger -AtStartup -RandomDelay ([TimeSpan]::FromMinutes(2))),
        (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval ([TimeSpan]::FromMinutes(15)))
    )
    $renewalTrigger = New-ScheduledTaskTrigger -Daily -At '02:00' -RandomDelay ([TimeSpan]::FromHours(2))
    foreach ($item in @(
        @{ Name = 'RdpCertificate-Bootstrap'; Triggers = $bootstrapTriggers },
        @{ Name = 'RdpCertificate-Renewal'; Triggers = @($renewalTrigger) }
    )) {
        Register-ScheduledTask -TaskPath '\FederalAVD\' -TaskName $item.Name -Action $action `
            -Trigger $item.Triggers -Principal $taskPrincipal -Settings $settings -Force -ErrorAction Stop | Out-Null
    }
}
else {
    $settings.ExecutionTimeLimit = 'PT0S'
    $serverScript = Join-Path $scripts 'Server.ps1'
    $action = New-ScheduledTaskAction -Execute $PowerShellPath `
        -Argument "-NoProfile -NonInteractive -File `"$serverScript`""
    $task = New-ScheduledTask -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $settings
    Register-ScheduledTask -TaskPath '\FederalAVD\' -TaskName 'RdpCertificate-EnrollmentServer' `
        -InputObject $task -User $ServerTaskCredential.UserName `
        -Password $ServerTaskCredential.GetNetworkCredential().Password -Force -ErrorAction Stop | Out-Null
}
foreach ($name in $taskNames) {
    $scheduler.GetFolder('\FederalAVD').GetTask($name).SetSecurityDescriptor('D:P(A;;GA;;;SY)(A;;GA;;;BA)', 0)
}
if ($Mode -eq 'EnrollHost') {
    & $PowerShellPath -NoProfile -NonInteractive -File $hostScript -Operation Enroll
    if ($LASTEXITCODE -ne 0) { throw 'Synchronous RDP enrollment/verification failed. Replacement readiness must remain blocked.' }
    return
}
$startName = if ($role -eq 'Server') { 'RdpCertificate-EnrollmentServer' } else { 'RdpCertificate-Bootstrap' }
Start-ScheduledTask -TaskPath '\FederalAVD\' -TaskName $startName -ErrorAction Stop
Write-Output "Installed and started $startName. Inspect protected state\audit.jsonl and task results; installation is not proof of issuance."
