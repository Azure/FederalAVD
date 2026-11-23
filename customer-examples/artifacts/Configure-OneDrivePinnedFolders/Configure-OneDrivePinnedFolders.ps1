<#
.SYNOPSIS
    Stages an embedded OneDrive folder-pinning script and registers it for every user logon.

.DESCRIPTION
    Run elevated during image creation or session-host customization. The generated script
    runs without elevation in the signing-in user's context, not in the installer's context.
    A scheduled task starts 60 seconds after sign-in, allows 30 minutes per attempt, and
    retries failures up to three times at one-minute intervals. Folder parameters are
    written as readable script defaults, not task action arguments.

.PARAMETER Folders
    Folder paths relative to each user's OneDrive for Business root.

.PARAMETER WaitTimeoutSeconds
    Maximum wait for the OneDrive root, and separately for each requested folder.

.PARAMETER RetryIntervalSeconds
    Seconds between readiness checks.

.EXAMPLE
    .\Configure-OneDrivePinnedFolders.ps1 -Folders @('Documents\Pinned1', 'Documents\Pinned2')
#>
[CmdletBinding()]
param (
    [ValidateNotNullOrEmpty()]
    [Parameter(Mandatory=$true)]
    [string[]]$Folders,

    [ValidateRange(1, 86400)]
    [int]$WaitTimeoutSeconds = 900,

    [ValidateRange(1, 300)]
    [int]$RetryIntervalSeconds = 10
)

$ErrorActionPreference = 'Stop'

function Assert-RelativeFolders {
    param([string[]]$Paths)

    if ($Paths.Count -eq 0) { throw 'Folders must contain at least one relative folder path.' }
    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path) -or [IO.Path]::IsPathRooted($path)) {
            throw "Folders must contain nonempty relative paths: '$path'."
        }
        foreach ($part in ($path -split '[\\/]')) {
            if ($part -in @('', '.', '..') -or $part.TrimEnd(' ', '.') -ne $part -or
                $part.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
                throw "Folders contains an invalid relative path: '$path'."
            }
        }
    }
}

function New-OneDriveUserScript {
    param(
        [string[]]$Folders,
        [int]$WaitTimeoutSeconds,
        [int]$RetryIntervalSeconds
    )

    Assert-RelativeFolders -Paths $Folders
    $folderDefaults = ($Folders | ForEach-Object {
        $literal = "'" + $_.Replace("'", "''") + "'"
        if ($literal -match '[^\x00-\x7E]') {
            # Keep generated scripts ASCII-only and readable by Windows PowerShell 5.1.
            $literal = '(' + [regex]::Replace($literal, '[^\x00-\x7E]', {
                param($match)
                "' + [char]0x{0:X4} + '" -f [int][char]$match.Value
            }) + ')'
        }
        $literal
    }) -join ', '
    $folderValidator = (Get-Command Assert-RelativeFolders -CommandType Function).Definition
    $template = @'
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string[]]$Folders = @(__FOLDERS__),
    [ValidateRange(1, 86400)]
    [int]$WaitTimeoutSeconds = __WAIT_TIMEOUT__,
    [ValidateRange(1, 300)]
    [int]$RetryIntervalSeconds = __RETRY_INTERVAL__
)

$ErrorActionPreference = 'Stop'
function Assert-RelativeFolders {
__FOLDER_VALIDATOR__
}

function Write-UserLog {
    param([string]$Message)
    Add-Content -LiteralPath $logPath -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message" -ErrorAction Stop
}

function Get-OneDriveRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:OneDriveCommercial) -and
        (Test-Path -LiteralPath $env:OneDriveCommercial -PathType Container)) {
        return $env:OneDriveCommercial
    }
    $accountKey = 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1'
    if (Test-Path -LiteralPath $accountKey) {
        $account = Get-ItemProperty -LiteralPath $accountKey -ErrorAction Stop
        $folder = $account.PSObject.Properties['UserFolder']
        if ($null -ne $folder -and -not [string]::IsNullOrWhiteSpace($folder.Value) -and
            (Test-Path -LiteralPath $folder.Value -PathType Container)) {
            return $folder.Value
        }
    }
}

function Wait-ForUserPath {
    param([scriptblock]$Resolve, [string]$Description)
    $deadline = (Get-Date).AddSeconds($WaitTimeoutSeconds)
    do {
        $result = & $Resolve
        if (-not [string]::IsNullOrWhiteSpace($result)) { return $result }
        $remaining = ($deadline - (Get-Date)).TotalSeconds
        if ($remaining -le 0) { break }
        Start-Sleep -Seconds ([Math]::Min($RetryIntervalSeconds, [Math]::Ceiling($remaining)))
    } while ($true)
    throw "Timed out after $WaitTimeoutSeconds seconds waiting for $Description."
}

function Invoke-PinAttributes {
    param([string]$Path, [switch]$Recurse)
    $arguments = @('+p', '-u', $Path)
    if ($Recurse) { $arguments += @('/s', '/d') }
    $result = & (Join-Path $env:SystemRoot 'System32\attrib.exe') @arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "attrib failed for '$Path' (exit $LASTEXITCODE): $($result -join ' ')"
    }
}

if ([string]::IsNullOrWhiteSpace($env:TEMP)) {
    throw 'TEMP is required. Run this script in the interactive user context.'
}
$logDirectory = $env:TEMP
$null = New-Item -Path $logDirectory -ItemType Directory -Force -ErrorAction Stop
$logPath = Join-Path $logDirectory 'OneDrivePinnedFolders.log'

try {
    Assert-RelativeFolders -Paths $Folders
    Write-UserLog "Starting OneDrive pinning for $($Folders.Count) folder(s)."
    $root = Wait-ForUserPath -Resolve { Get-OneDriveRoot } -Description 'the OneDrive for Business root'
    foreach ($folder in $Folders) {
        $path = Join-Path $root $folder
        $null = Wait-ForUserPath -Resolve {
            if (Test-Path -LiteralPath $path -PathType Container) { $path }
        } -Description "'$path'"
        Invoke-PinAttributes -Path $path
        if ($null -ne (Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop | Select-Object -First 1)) {
            Invoke-PinAttributes -Path (Join-Path $path '*') -Recurse
        }
        Write-UserLog "Requested pinning for '$path' and its existing contents."
    }
    Write-UserLog 'Pinning requests completed. OneDrive downloads may still be in progress.'
}
catch {
    Write-UserLog "ERROR: $($_.Exception.Message)"
    throw
}
'@
    return $template.Replace('__FOLDER_VALIDATOR__', $folderValidator).
        Replace('__WAIT_TIMEOUT__', [string]$WaitTimeoutSeconds).
        Replace('__RETRY_INTERVAL__', [string]$RetryIntervalSeconds).
        Replace('__FOLDERS__', $folderDefaults)
}

function Assert-ProtectedPath {
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
            throw "Staging path allows non-administrator modification: '$Path'. Correct its ACL before retrying."
        }
    }
}

function Initialize-ScriptDirectory {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            throw "Script directory is not a directory: '$Path'."
        }
        Assert-ProtectedPath -Path $Path
        return
    }
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
    Assert-ProtectedPath -Path $Path
}

if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) {
    throw 'Run this artifact with 64-bit Windows PowerShell or PowerShell on Windows.'
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this artifact elevated or as SYSTEM.'
}

$scriptDirectory = Join-Path $env:ProgramData 'Scripts'
$scriptPath = Join-Path $scriptDirectory 'Pin-OneDriveFolders.ps1'
$powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$actionArguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $scriptPath
$content = New-OneDriveUserScript -Folders $Folders -WaitTimeoutSeconds $WaitTimeoutSeconds -RetryIntervalSeconds $RetryIntervalSeconds
$parseErrors = $null
$null = [Management.Automation.Language.Parser]::ParseInput($content, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw "Generated user script failed parsing: $($parseErrors -join '; ')" }

Initialize-ScriptDirectory -Path $scriptDirectory
if (Test-Path -LiteralPath $scriptPath) { Assert-ProtectedPath -Path $scriptPath }
[IO.File]::WriteAllText($scriptPath, $content, (New-Object Text.UTF8Encoding($false)))

$taskName = 'OneDrivePinnedFolders'
$action = New-ScheduledTaskAction -Execute $powerShellPath -Argument $actionArguments -ErrorAction Stop
$trigger = New-ScheduledTaskTrigger -AtLogOn -ErrorAction Stop
$trigger.Delay = 'PT60S'
$taskPrincipal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited -ErrorAction Stop
# Parallel instances let different AVD users run in their own sign-in sessions.
$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances Parallel `
    -StartWhenAvailable `
    -ErrorAction Stop
$null = Register-ScheduledTask -TaskName $taskName -TaskPath '\' -Action $action -Trigger $trigger `
    -Principal $taskPrincipal -Settings $settings `
    -Description 'Pin selected OneDrive folders in each signing-in user context after a 60-second delay.' `
    -Force -ErrorAction Stop

$runKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
if (Test-Path -LiteralPath $runKey) {
    $runValues = Get-ItemProperty -LiteralPath $runKey -ErrorAction Stop
    foreach ($legacyName in @('OneDrivePinnedFolders', 'FederalAVD-OneDrivePinnedFolders')) {
        if ($null -ne $runValues.PSObject.Properties[$legacyName]) {
            Remove-ItemProperty -LiteralPath $runKey -Name $legacyName -ErrorAction Stop
        }
    }
}
Write-Output "Staged '$scriptPath' and registered scheduled task '$taskName' for future interactive logons."
