#requires -Version 5.1
<#
.SYNOPSIS
    Installs Edge Favorites Backup & Restore with automatic backup and self-service recovery.
.DESCRIPTION
    Run elevated during image creation or session-host customization. A delayed
    all-user logon task checks backup once in the signing-in user's context.
    No favorites are read in the installer's context. User shortcuts provide
    immediate backup and selective recovery through guided Edge HTML import.
    Existing Edge data is never replaced by this artifact.
.PARAMETER BackupRoot
    Existing per-user destination root. Environment references such as %USERNAME%
    are expanded by the user worker. By default the worker uses the signing-in
    user's OneDriveCommercial environment variable, with business-account
    registry discovery if that variable is not ready.
.PARAMETER BackupSetName
    Destination namespace. Use different names for independent devices or pools.
.PARAMETER EdgeProfileName
    Defaults to * to discover persistent Edge Stable profiles with a Bookmarks
    file. Specify a profile directory such as Default or Profile 1 to select one.
.PARAMETER BackupIntervalHours
    Minimum age of the latest successful backup before another export.
.PARAMETER HistoryCount
    Number of dated HTML recovery copies retained, in addition to Latest.html.
#>
[CmdletBinding()]
param(
    [string]$BackupRoot = '',
    [ValidatePattern('^[A-Za-z0-9](?:[A-Za-z0-9 _.-]{0,62}[A-Za-z0-9_-])?$')]
    [string]$BackupSetName = 'AVD',
    [ValidateScript({
        $_ -eq '*' -or (-not [string]::IsNullOrWhiteSpace($_) -and $_ -notin @('.', '..') -and
            $_.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -lt 0 -and $_.TrimEnd(' ', '.') -eq $_)
    })]
    [string]$EdgeProfileName = '*',
    [ValidateRange(1, 8760)]
    [int]$BackupIntervalHours = 24,
    [ValidateRange(1, 365)]
    [int]$HistoryCount = 14
)

$ErrorActionPreference = 'Stop'

function Assert-ProtectedBackupPath {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Staging path must not be a junction or symbolic link: '$Path'."
    }
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $trusted = @('S-1-5-18', 'S-1-5-32-544')
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted) {
        throw "Staging path must be owned by SYSTEM or Administrators: '$Path'."
    }
    $writeRights = [Security.AccessControl.FileSystemRights]'Write, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership'
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin $trusted -and
            ($rule.FileSystemRights -band $writeRights) -ne 0) {
            throw "Staging path permits non-administrator modification: '$Path'."
        }
    }
}

function Initialize-BackupDirectory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        $null = New-Item -Path $Path -ItemType Directory -ErrorAction Stop
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sidValue in @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-32-545')) {
            $sid = New-Object Security.Principal.SecurityIdentifier($sidValue)
            $rights = if ($sidValue -eq 'S-1-5-32-545') { 'ReadAndExecute' } else { 'FullControl' }
            $rule = New-Object Security.AccessControl.FileSystemAccessRule(
                $sid, $rights, 'ContainerInherit, ObjectInherit', 'None', 'Allow'
            )
            $acl.AddAccessRule($rule)
        }
        $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Staging path is not a directory: '$Path'."
    }
    Assert-ProtectedBackupPath -Path $Path
}

function Register-BackupLogonTask {
    param([string]$WorkerPath, [string]$ConfigPath)
    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -ConfigurationPath "{1}"' -f $WorkerPath, $ConfigPath
    $action = New-ScheduledTaskAction -Execute $powerShell -Argument $arguments -ErrorAction Stop
    $trigger = New-ScheduledTaskTrigger -AtLogOn -ErrorAction Stop
    $trigger.Delay = 'PT120S'
    $principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited -ErrorAction Stop
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances Parallel -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 5) -ErrorAction Stop
    $null = Register-ScheduledTask -TaskName 'EdgeFavoritesBackupRestore-Logon' -TaskPath '\' `
        -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
        -Description 'Check favorites backup once in each signing-in user context.' -Force -ErrorAction Stop
}

function Register-FavoritesShortcuts {
    param([string]$HelperPath, [string]$ConfigPath)
    $folder = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Edge Favorites'
    Initialize-BackupDirectory -Path $folder
    $shell = New-Object -ComObject WScript.Shell
    foreach ($mode in @('Backup', 'Restore')) {
        $name = if ($mode -eq 'Backup') { 'Back Up Edge Favorites' } else { 'Restore Edge Favorites' }
        $path = Join-Path $folder "$name.lnk"
        if (Test-Path -LiteralPath $path) { Assert-ProtectedBackupPath -Path $path }
        $shortcut = $shell.CreateShortcut($path)
        $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $shortcut.Arguments = '-NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Mode {1} -ConfigurationPath "{2}"' -f $HelperPath, $mode, $ConfigPath
        $shortcut.WorkingDirectory = Split-Path -Parent $HelperPath
        $shortcut.Description = "$name using the current user's configured backup storage."
        $shortcut.IconLocation = (Join-Path (Split-Path -Parent $HelperPath) "assets\favorites-$($mode.ToLowerInvariant()).ico") + ',0'
        $shortcut.Save()
        Assert-ProtectedBackupPath -Path $path
    }
}

function Remove-LegacyFavoritesTasks {
    param([string]$WorkerPath)
    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $workerArgument = '(?:^|\s)-File\s+"{0}"(?:\s|$)' -f [regex]::Escape($WorkerPath)
    $tasks = @(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop | Where-Object {
        $_.TaskPath -eq '\' -and $_.TaskName -match '^EdgeFavoritesBackupRestore-S-1-(?:\d+-)+\d+$'
    })
    foreach ($task in $tasks) {
        $actions = @($task.Actions)
        if ($actions.Count -ne 1 -or $actions[0].Execute -ne $powerShell -or
            $actions[0].Arguments -notmatch $workerArgument) {
            Write-Warning "Leaving task '$($task.TaskPath)$($task.TaskName)' because its action does not match the installed backup worker. Review it manually."
            continue
        }
        if ($task.State -eq 'Running') {
            Stop-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop
        }
        Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false -ErrorAction Stop
        Write-Output "Removed legacy favorites backup task '$($task.TaskPath)$($task.TaskName)'."
    }
}

if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) {
    throw 'Run this artifact with 64-bit PowerShell on Windows.'
}
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this artifact elevated or as SYSTEM.'
}

$directory = Join-Path $env:ProgramData 'EdgeFavoritesBackupRestore'
$workerPath = Join-Path $directory 'Backup-EdgeFavorites.ps1'
$configurationPath = Join-Path $directory 'Configuration.json'
$assets = @('favorites-backup.ico', 'favorites-restore.ico', 'favorites-restore-banner.png')
foreach ($name in $assets) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot "scripts\assets\$name") -PathType Leaf)) {
        throw "Packaged artwork '$name' is missing. Copy the complete artifact package."
    }
}
$sources = [ordered]@{}
foreach ($name in @('Backup-EdgeFavorites.ps1', 'FavoritesBackup.Common.ps1', 'Show-EdgeFavorites.ps1')) {
    $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot "scripts\$name") -Raw -ErrorAction Stop
    $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0 -or $source -match '[^\x00-\x7E]') {
        throw "Packaged script '$name' must be valid ASCII-only PowerShell."
    }
    $sources[$name] = $source
}
Initialize-BackupDirectory -Path $directory
$assetDirectory = Join-Path $directory 'assets'
Initialize-BackupDirectory -Path $assetDirectory
foreach ($path in @($sources.Keys | ForEach-Object { Join-Path $directory $_ }) + @($configurationPath)) {
    if (Test-Path -LiteralPath $path) { Assert-ProtectedBackupPath -Path $path }
}
foreach ($name in $sources.Keys) {
    $path = Join-Path $directory $name
    [IO.File]::WriteAllText($path, $sources[$name], (New-Object Text.UTF8Encoding($false)))
    Assert-ProtectedBackupPath -Path $path
}
foreach ($name in $assets) {
    $path = Join-Path $assetDirectory $name
    if (Test-Path -LiteralPath $path) { Assert-ProtectedBackupPath -Path $path }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "scripts\assets\$name") -Destination $path -Force -ErrorAction Stop
    Assert-ProtectedBackupPath -Path $path
}
$configuration = [ordered]@{
    BackupRoot = $BackupRoot
    BackupSetName = $BackupSetName
    EdgeProfileName = $EdgeProfileName
    BackupIntervalHours = $BackupIntervalHours
    HistoryCount = $HistoryCount
}
[IO.File]::WriteAllText($configurationPath, ($configuration | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
Assert-ProtectedBackupPath -Path $configurationPath
Register-BackupLogonTask -WorkerPath $workerPath -ConfigPath $configurationPath
Remove-LegacyFavoritesTasks -WorkerPath $workerPath
Register-FavoritesShortcuts -HelperPath (Join-Path $directory 'Show-EdgeFavorites.ps1') -ConfigPath $configurationPath
Write-Output 'Installed Edge Favorites Backup & Restore with one logon task and backup/restore Start-menu shortcuts. No user data was accessed.'
