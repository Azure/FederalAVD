#requires -Version 5.1
<#
.SYNOPSIS
    Exports the current user's Edge favorites without modifying browser data.
.DESCRIPTION
    Intended for the artifact's non-elevated logon task or a manual run. Empty or invalid
    favorites never replace existing backups. Recovery is a manual HTML import.
.PARAMETER EdgeProfileName
    Optional single-profile override for a manual backup run.
.PARAMETER ConfigurationPath
    Configuration JSON path. If omitted, resolved beside the script file after
    logging is initialized. The logon task passes the installed path explicitly.
#>
[CmdletBinding()]
param(
    [string]$EdgeProfileName,
    [string]$ConfigurationPath
)

$ErrorActionPreference = 'Stop'

function Write-BackupLog {
    param([string]$Message)
    Add-Content -LiteralPath $script:LogPath -Value "[$([DateTime]::UtcNow.ToString('o'))] $Message" -Encoding UTF8 -ErrorAction Stop
}

function Get-FavoritesBackupRoot {
    param([string]$ConfiguredPath)
    if (-not [string]::IsNullOrWhiteSpace($ConfiguredPath)) {
        $root = [Environment]::ExpandEnvironmentVariables($ConfiguredPath)
        if ($root -match '%[^%]+%' -or $root -notmatch '^(?:[A-Za-z]:\\|\\\\[^\\]+\\[^\\]+(?:\\|$))') {
            throw 'BackupRoot must expand to an absolute, existing per-user directory.'
        }
    }
    else {
        $root = $env:OneDriveCommercial
        if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root -PathType Container)) {
            $accounts = 'HKCU:\Software\Microsoft\OneDrive\Accounts'
            $roots = @(if (Test-Path -LiteralPath $accounts) {
                Get-ChildItem -LiteralPath $accounts -ErrorAction Stop |
                    Where-Object { $_.PSChildName -like 'Business*' } |
                    ForEach-Object { (Get-ItemProperty -LiteralPath $_.PSPath -Name UserFolder -ErrorAction Stop).UserFolder } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    Select-Object -Unique
            })
            if ($roots.Count -ne 1) {
                throw 'No unambiguous business OneDrive root is available. Configure BackupRoot or retry after OneDrive setup.'
            }
            $root = $roots[0]
        }
    }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw 'The backup root is unavailable. It will not be created automatically.'
    }
    return [IO.Path]::GetFullPath($root)
}

function Get-EdgeFavoritesProfiles {
    param([string]$ProfileName)
    if ($ProfileName -ne '*') {
        if ([string]::IsNullOrWhiteSpace($ProfileName) -or $ProfileName -in @('.', '..') -or
            $ProfileName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
            $ProfileName.TrimEnd(' ', '.') -ne $ProfileName) {
            throw 'EdgeProfileName must be * or one valid profile directory name.'
        }
        return $ProfileName
    }
    $userData = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'
    $profiles = @(Get-ChildItem -LiteralPath $userData -Directory -Force -ErrorAction Stop |
        Where-Object {
            $_.Name -notin @('Guest Profile', 'System Profile') -and
            ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and
            (Test-Path -LiteralPath (Join-Path $_.FullName 'Bookmarks') -PathType Leaf)
        } | Sort-Object Name | Select-Object -ExpandProperty Name)
    if ($profiles.Count -eq 0) {
        throw 'No persistent Edge profiles with a Bookmarks file were found. Existing backups are unchanged.'
    }
    return $profiles
}

function ConvertTo-FavoritesHtml {
    param([Parameter(Mandatory)]$Data)
    if ($null -eq $Data.roots -or $Data.roots -isnot [pscustomobject]) {
        throw 'Bookmarks JSON must contain a roots object.'
    }
    $context = @{ Text = [Text.StringBuilder]::new(); Count = 0 }
    $null = $context.Text.AppendLine(@'
<!DOCTYPE NETSCAPE-Bookmark-file-1>
<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
<TITLE>Bookmarks</TITLE>
<H1>Bookmarks</H1>
<DL><p>
'@)
    function Get-DateAttribute {
        param([string]$Name, [string]$Value)
        if ([string]::IsNullOrEmpty($Value) -or $Value -eq '0') { return '' }
        $microseconds = [long]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture)
        if ($microseconds -lt 0) { throw 'Bookmark timestamps cannot be negative.' }
        $seconds = [DateTimeOffset]::FromFileTime([long]([decimal]$microseconds * 10)).ToUnixTimeSeconds()
        return " $Name=`"$seconds`""
    }
    function Add-BookmarkNode {
        param($Node, [bool]$Toolbar = $false, [int]$Depth = 0)
        if ($Depth -gt 100 -or $Node.name -isnot [string]) {
            throw 'Bookmarks contain an invalid name or exceed 100 nested folders.'
        }
        $name = [Net.WebUtility]::HtmlEncode($Node.name)
        $added = Get-DateAttribute -Name 'ADD_DATE' -Value $Node.date_added
        switch ($Node.type) {
            'folder' {
                if ($Node.children -isnot [array]) { throw 'A bookmark folder must contain a children array.' }
                $modified = Get-DateAttribute -Name 'LAST_MODIFIED' -Value $Node.date_modified
                $bar = if ($Toolbar) { ' PERSONAL_TOOLBAR_FOLDER="true"' } else { '' }
                $null = $context.Text.AppendLine("<DT><H3$added$modified$bar>$name</H3>")
                $null = $context.Text.AppendLine('<DL><p>')
                foreach ($child in $Node.children) { Add-BookmarkNode -Node $child -Depth ($Depth + 1) }
                $null = $context.Text.AppendLine('</DL><p>')
            }
            'url' {
                if ($Node.url -isnot [string] -or [string]::IsNullOrWhiteSpace($Node.url)) {
                    throw 'A bookmark URL must be a nonempty string.'
                }
                $url = [Net.WebUtility]::HtmlEncode($Node.url)
                $null = $context.Text.AppendLine("<DT><A HREF=`"$url`"$added>$name</A>")
                $context.Count++
            }
            default { throw "Unsupported bookmark node type: '$($Node.type)'." }
        }
    }
    $roots = @($Data.roots.PSObject.Properties)
    if ($roots.Count -eq 0) { throw 'Bookmarks roots cannot be empty.' }
    foreach ($root in $roots) { Add-BookmarkNode -Node $root.Value -Toolbar ($root.Name -eq 'bookmark_bar') }
    $null = $context.Text.AppendLine('</DL><p>')
    [pscustomobject]@{ Html = $context.Text.ToString(); Count = $context.Count }
}

function Write-AtomicBackupFile {
    param([string]$Path, [string]$Content)
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, $Content, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path) {
            [IO.File]::Replace($temporary, $Path, [NullString]::Value)
        }
        else { [IO.File]::Move($temporary, $Path) }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction Stop }
    }
}

function Invoke-FavoritesBackup {
    param(
        [string]$BackupRoot,
        [ValidatePattern('^[A-Za-z0-9](?:[A-Za-z0-9 _.-]{0,62}[A-Za-z0-9_-])?$')]
        [string]$BackupSetName,
        [ValidateScript({
            -not [string]::IsNullOrWhiteSpace($_) -and $_ -notin @('.', '..') -and
                $_.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -lt 0 -and $_.TrimEnd(' ', '.') -eq $_
        })]
        [string]$EdgeProfileName,
        [ValidateRange(1, 8760)][int]$BackupIntervalHours,
        [ValidateRange(1, 365)][int]$HistoryCount
    )
    $root = Get-FavoritesBackupRoot -ConfiguredPath $BackupRoot
    $relative = "EdgeFavoritesBackup\$BackupSetName\$EdgeProfileName"
    $destination = Join-Path $root $relative
    $null = New-Item -Path $destination -ItemType Directory -Force -ErrorAction Stop
    $lock = [IO.File]::Open((Join-Path $destination 'Backup.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $latest = Join-Path $destination 'Latest.html'
        $historyDirectory = Join-Path $destination 'History'
        $bookmarks = Join-Path $env:LOCALAPPDATA "Microsoft\Edge\User Data\$EdgeProfileName\Bookmarks"
        $data = Get-Content -LiteralPath $bookmarks -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $export = ConvertTo-FavoritesHtml -Data $data
        if ($export.Count -eq 0) { throw 'No favorites found. Existing backups will not be replaced by an empty export.' }
        if (Test-Path -LiteralPath $latest) {
            $lastWrite = (Get-Item -LiteralPath $latest -ErrorAction Stop).LastWriteTimeUtc
            if ($lastWrite -gt [DateTime]::UtcNow) { throw 'Latest backup has a future timestamp; review its clock or sync metadata.' }
            if (([DateTime]::UtcNow - $lastWrite).TotalHours -lt $BackupIntervalHours) {
                Write-BackupLog 'A successful backup is still within the configured interval.'
                return
            }
        }
        $null = New-Item -Path $historyDirectory -ItemType Directory -Force -ErrorAction Stop
        $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture)
        $name = 'Favorites-{0}-{1}.html' -f $stamp, [guid]::NewGuid().ToString('N')
        Write-AtomicBackupFile -Path (Join-Path $historyDirectory $name) -Content $export.Html
        Write-AtomicBackupFile -Path $latest -Content $export.Html
        Get-ChildItem -LiteralPath $historyDirectory -File -ErrorAction Stop |
            Where-Object { $_.Name -match '^Favorites-\d{8}T\d{13}Z-[a-f0-9]{32}\.html$' } |
            Sort-Object Name -Descending | Select-Object -Skip $HistoryCount |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop }
        Write-BackupLog "Exported $($export.Count) favorites. Retained up to $HistoryCount dated copies in '$destination'."
    }
    finally { $lock.Dispose() }
}

function Invoke-ConfiguredFavoritesBackup {
    param($Configuration)
    $profiles = @(Get-EdgeFavoritesProfiles -ProfileName $Configuration.EdgeProfileName)
    $failures = [Collections.Generic.List[string]]::new()
    foreach ($profile in $profiles) {
        try {
            Invoke-FavoritesBackup -BackupRoot $Configuration.BackupRoot -BackupSetName $Configuration.BackupSetName `
                -EdgeProfileName $profile -BackupIntervalHours $Configuration.BackupIntervalHours `
                -HistoryCount $Configuration.HistoryCount
        }
        catch {
            Write-BackupLog "ERROR for Edge profile '$profile': $($_.Exception.Message)"
            $failures.Add($profile)
        }
    }
    if ($failures.Count -gt 0) {
        throw "Favorites backup failed for profile(s): $($failures -join ', '). See the per-profile errors in the log."
    }
}

if ($env:OS -ne 'Windows_NT' -or [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    throw 'Run the worker in an interactive Windows user context.'
}
$userId = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if ($userId -in @('S-1-5-18', 'S-1-5-19', 'S-1-5-20')) {
    throw 'The backup worker must not run as SYSTEM or a service account.'
}
$logDirectory = Join-Path $env:LOCALAPPDATA 'EdgeFavoritesBackup'
$null = New-Item -Path $logDirectory -ItemType Directory -Force -ErrorAction Stop
$script:LogPath = Join-Path $logDirectory 'Backup.log'
try {
    if (-not $PSBoundParameters.ContainsKey('ConfigurationPath')) {
        if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
            throw 'Cannot resolve ConfigurationPath without a script directory. Run the installed script file or pass -ConfigurationPath explicitly.'
        }
        $ConfigurationPath = Join-Path $PSScriptRoot 'Configuration.json'
    }
    elseif ([string]::IsNullOrWhiteSpace($ConfigurationPath)) {
        throw 'ConfigurationPath must not be empty.'
    }
    $configuration = Get-Content -LiteralPath $ConfigurationPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($PSBoundParameters.ContainsKey('EdgeProfileName')) { $configuration.EdgeProfileName = $EdgeProfileName }
    Invoke-ConfiguredFavoritesBackup -Configuration $configuration
}
catch {
    Write-BackupLog "ERROR: $($_.Exception.Message)"
    throw
}
