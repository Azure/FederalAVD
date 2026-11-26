#requires -Version 5.1
<#
.SYNOPSIS
    Backs up favorites on demand or prepares selected favorites for Edge HTML import.
.DESCRIPTION
    Runs as the interactive user. Does not modify live Edge data or import automatically.
    Restore reads snapshots from storage, including profiles absent from this host.
#>
[CmdletBinding()]
param(
    [ValidateSet('Backup', 'Restore')]
    [string]$Mode = 'Restore',
    [string]$ConfigurationPath
)

$ErrorActionPreference = 'Stop'

function Read-FavoritesSnapshot {
    param([Parameter(Mandatory)][string]$Html)
    $header = '<!DOCTYPE NETSCAPE-Bookmark-file-1>\s*<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">\s*<TITLE>Bookmarks</TITLE>\s*<H1>Bookmarks</H1>\s*<DL><p>'
    $match = [regex]::Match($Html, "\A$header")
    if (-not $match.Success) { throw 'This file is not an HTML snapshot produced by this backup tool.' }
    $root = [pscustomobject]@{ Children = [Collections.Generic.List[object]]::new() }
    $stack = [Collections.Generic.Stack[object]]::new()
    $stack.Push($root)
    $position = $match.Length
    $count = 0
    $pattern = '\G\s*(?:(?<folder><DT><H3(?: ADD_DATE="-?\d+")?(?: LAST_MODIFIED="-?\d+")?(?: PERSONAL_TOOLBAR_FOLDER="true")?>(?<folderName>[^<]*)</H3>)\s*<DL><p>|(?<link><DT><A HREF="(?<url>[^"]*)"(?: ADD_DATE="-?\d+")?>(?<linkName>[^<]*)</A>)|(?<close></DL><p>))'
    $regex = [regex]::new($pattern, [Text.RegularExpressions.RegexOptions]::None, [TimeSpan]::FromSeconds(5))
    while ($stack.Count -gt 0) {
        $match = $regex.Match($Html, $position)
        if (-not $match.Success) { throw "Invalid or unsupported favorites HTML near character $position." }
        $position += $match.Length
        if ($match.Groups['close'].Success) {
            $null = $stack.Pop()
            continue
        }
        $folder = $match.Groups['folder'].Success
        $name = if ($folder) { $match.Groups['folderName'].Value } else { $match.Groups['linkName'].Value }
        $node = [pscustomobject]@{
            Name = [Net.WebUtility]::HtmlDecode($name)
            Url = if ($folder) { '' } else { [Net.WebUtility]::HtmlDecode($match.Groups['url'].Value) }
            Type = if ($folder) { 'folder' } else { 'url' }
            Html = if ($folder) { $match.Groups['folder'].Value } else { $match.Groups['link'].Value }
            Selected = $false
            Children = [Collections.Generic.List[object]]::new()
        }
        if (-not $folder -and [string]::IsNullOrWhiteSpace($node.Url)) { throw 'A favorite has an empty URL.' }
        $stack.Peek().Children.Add($node)
        if ($folder) {
            if ($stack.Count -gt 101) { throw 'Favorites exceed 100 nested folders.' }
            $stack.Push($node)
        }
        else { $count++ }
    }
    if (-not [string]::IsNullOrWhiteSpace($Html.Substring($position)) -or $count -eq 0) {
        throw 'Favorites HTML has trailing content or contains no favorites.'
    }
    [pscustomobject]@{ Root = $root; Count = $count; Html = $Html }
}

function ConvertTo-SelectedFavoritesHtml {
    param([Parameter(Mandatory)]$Snapshot)
    $context = @{ Count = 0 }
    function Get-SelectedNodeHtml {
        param($Node)
        if ($Node.Type -eq 'url') {
            if ($Node.Selected) { $context.Count++; return $Node.Html }
            return
        }
        $children = @($Node.Children | ForEach-Object { Get-SelectedNodeHtml -Node $_ })
        if ($children.Count -gt 0) {
            return ($Node.Html + "`r`n<DL><p>`r`n" + ($children -join "`r`n") + "`r`n</DL><p>")
        }
    }
    $body = @($Snapshot.Root.Children | ForEach-Object { Get-SelectedNodeHtml -Node $_ })
    if ($context.Count -eq 0) { throw 'Select at least one favorite before preparing an import.' }
    $header = @'
<!DOCTYPE NETSCAPE-Bookmark-file-1>
<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
<TITLE>Bookmarks</TITLE>
<H1>Bookmarks</H1>
<DL><p>
'@
    [pscustomobject]@{
        Count = $context.Count
        Html = $header + "`r`n" + ($body -join "`r`n") + "`r`n</DL><p>`r`n"
    }
}

function Get-FavoritesRecoveryFiles {
    param([string]$BackupRoot, [string]$BackupSetName)
    if ($BackupSetName -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9 _.-]{0,62}[A-Za-z0-9_-])?$') {
        throw 'The configured backup-set name is invalid.'
    }
    $directory = Join-Path $BackupRoot "EdgeFavoritesBackupRestore\$BackupSetName"
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        throw 'The backup set is unavailable. Check storage and synchronization before concluding there are no backups.'
    }
    foreach ($profile in Get-ChildItem -LiteralPath $directory -Directory -ErrorAction Stop |
        Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 } | Sort-Object Name) {
        $latest = Join-Path $profile.FullName 'Latest.html'
        if (Test-Path -LiteralPath $latest -PathType Leaf) {
            [pscustomobject]@{ Path = $latest; Label = "$($profile.Name) | Latest (file time $((Get-Item -LiteralPath $latest).LastWriteTimeUtc.ToString('u')))" }
        }
        $history = Join-Path $profile.FullName 'History'
        if (Test-Path -LiteralPath $history -PathType Container) {
            Get-ChildItem -LiteralPath $history -File -ErrorAction Stop |
                Where-Object { $_.Name -match '^Favorites-\d{8}T\d{13}Z-[a-f0-9]{32}\.html$' } |
                Sort-Object Name -Descending | ForEach-Object {
                    $stamp = [DateTime]::ParseExact($_.Name.Substring(10, 23), 'yyyyMMddTHHmmssfffffffZ',
                        [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
                    [pscustomobject]@{ Path = $_.FullName; Label = "$($profile.Name) | $($stamp.ToUniversalTime().ToString('u'))" }
                }
        }
    }
}

function Save-FavoritesRecovery {
    param([Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)][string]$RecoveryRoot)
    $selected = ConvertTo-SelectedFavoritesHtml -Snapshot $Snapshot
    $directory = Join-Path $RecoveryRoot ([guid]::NewGuid().ToString('N'))
    $null = New-Item -Path $directory -ItemType Directory -ErrorAction Stop
    $encoding = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $directory 'Source.html'), $Snapshot.Html, $encoding)
    $path = Join-Path $directory 'Selected.html'
    [IO.File]::WriteAllText($path, $selected.Html, $encoding)
    [pscustomobject]@{ Path = $path; Count = $selected.Count }
}

function Show-FavoritesError {
    param([string]$Message)
    try {
        Add-Content -LiteralPath $script:RecoveryLog -Value "[$([DateTime]::UtcNow.ToString('o'))] ERROR: $Message" -Encoding UTF8 -ErrorAction Stop
    }
    catch { $Message += "`r`nError logging also failed: $($_.Exception.Message)" }
    $null = [Windows.Forms.MessageBox]::Show($Message, 'Edge Favorites', 'OK', 'Error')
}

function Show-FavoritesRestoreForm {
    param([object[]]$Files, [string]$RecoveryRoot, [Parameter(Mandatory)][string]$AssetsPath)
    $state = @{ Snapshot = $null; UpdatingChecks = $false }
    $form = New-Object Windows.Forms.Form
    $form.Text = 'Restore Edge Favorites - prepare an HTML import'
    $form.Size = New-Object Drawing.Size(850, 680)
    $form.MinimumSize = $form.Size
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.StartPosition = 'CenterScreen'
    $picker = New-Object Windows.Forms.ComboBox
    $picker.Location = New-Object Drawing.Point(15, 195)
    $picker.Size = New-Object Drawing.Size(800, 28)
    $picker.DropDownStyle = 'DropDownList'
    $picker.DisplayMember = 'Label'
    foreach ($file in $Files) { $null = $picker.Items.Add($file) }
    $tree = New-Object Windows.Forms.TreeView
    $tree.Location = New-Object Drawing.Point(15, 235)
    $tree.Size = New-Object Drawing.Size(800, 210)
    $tree.CheckBoxes = $true
    $tree.ShowNodeToolTips = $true
    $status = New-Object Windows.Forms.Label
    $status.Location = New-Object Drawing.Point(15, 450)
    $status.Size = New-Object Drawing.Size(800, 35)
    $prepare = New-Object Windows.Forms.Button
    $prepare.Text = 'Prepare selected favorites'
    $prepare.Location = New-Object Drawing.Point(15, 490)
    $prepare.Size = New-Object Drawing.Size(220, 30)
    $prepare.Enabled = $false
    $instructions = New-Object Windows.Forms.TextBox
    $instructions.Location = New-Object Drawing.Point(15, 530)
    $instructions.Size = New-Object Drawing.Size(800, 95)
    $instructions.Multiline = $true
    $instructions.ReadOnly = $true
    $guide = 'Choose a snapshot, then check individual favorites or whole folders. Nothing is added to Edge automatically. After preparing, import Selected.html in the intended Edge profile through Settings > Profiles > Import browser data > Favorites or bookmarks HTML file. Import may create an Imported folder or duplicates.'
    $instructions.Text = $guide
    function Add-FavoritesTreeNode {
        param($Model, $Collection)
        $node = New-Object Windows.Forms.TreeNode($Model.Name)
        $node.Tag = $Model
        $node.ToolTipText = $Model.Url
        $null = $Collection.Add($node)
        foreach ($child in $Model.Children) { Add-FavoritesTreeNode -Model $child -Collection $node.Nodes }
    }
    function Set-FavoritesTreeCheck {
        param($Node, [bool]$Checked)
        $Node.Checked = $Checked
        $Node.Tag.Selected = $Checked
        foreach ($child in $Node.Nodes) { Set-FavoritesTreeCheck -Node $child -Checked $Checked }
    }
    $tree.add_AfterCheck({
        param($sender, $eventArgs)
        if ($state.UpdatingChecks) { return }
        $instructions.Text = $guide
        $state.UpdatingChecks = $true
        try { Set-FavoritesTreeCheck -Node $eventArgs.Node -Checked $eventArgs.Node.Checked }
        finally { $state.UpdatingChecks = $false }
    })
    $picker.add_SelectedIndexChanged({
        $prepare.Enabled = $false
        $state.Snapshot = $null
        $tree.Nodes.Clear()
        $status.Text = ''
        $instructions.Text = $guide
        try {
            $html = [IO.File]::ReadAllText($picker.SelectedItem.Path, [Text.Encoding]::UTF8)
            $state.Snapshot = Read-FavoritesSnapshot -Html $html
            foreach ($node in $state.Snapshot.Root.Children) { Add-FavoritesTreeNode -Model $node -Collection $tree.Nodes }
            $status.Text = "$($state.Snapshot.Count) favorites. Dates are UTC. Only checked favorites will be exported."
            $prepare.Enabled = $true
        }
        catch { Show-FavoritesError -Message $_.Exception.Message }
    })
    $prepare.add_Click({
        try {
            $result = Save-FavoritesRecovery -Snapshot $state.Snapshot -RecoveryRoot $RecoveryRoot
            $instructions.Text = "Prepared $($result.Count) favorites; Edge has NOT been changed.`r`nImport this file in the intended Edge profile:`r`n$($result.Path)`r`nA full Source.html copy is saved alongside it, outside rotating history."
            Add-Content -LiteralPath $script:RecoveryLog -Value "[$([DateTime]::UtcNow.ToString('o'))] Prepared $($result.Count) favorites for manual import." -Encoding UTF8 -ErrorAction Stop
        }
        catch { Show-FavoritesError -Message $_.Exception.Message }
    })
    $form.Controls.AddRange(@($picker, $tree, $status, $prepare, $instructions))
    $artResources = [Collections.Generic.List[IDisposable]]::new()
    try {
        $icon = [Drawing.Icon]::new((Join-Path $AssetsPath 'favorites-restore.ico'), 32, 32)
        $artResources.Add($icon)
        $form.Icon = $icon
        $highContrast = [Windows.Forms.SystemInformation]::HighContrast
        $hero = [Windows.Forms.Panel]::new()
        $hero.Name = 'FavoritesBanner'
        $hero.Location = [Drawing.Point]::new(15, 15)
        $hero.Size = [Drawing.Size]::new(800, 160)
        $hero.BackColor = [Drawing.SystemColors]::Window
        $hero.TabStop = $false
        $form.Controls.Add($hero)
        if (-not $highContrast) {
            $form.BackColor = [Drawing.Color]::White
            $artwork = [Drawing.Image]::FromFile((Join-Path $AssetsPath 'favorites-restore-banner.png'))
            $artResources.Add($artwork)
            $picture = [Windows.Forms.PictureBox]::new()
            $picture.Name = 'FavoritesBannerImage'
            $picture.Dock = 'Fill'
            $picture.SizeMode = 'StretchImage'
            $picture.Image = $artwork
            $picture.TabStop = $false
            $picture.AccessibleName = 'Blue and green favorites star in a browser window with a restore arrow'
            $hero.Controls.Add($picture)
        }
        $title = [Windows.Forms.Label]::new()
        $title.Text = 'Restore your favorites'
        $title.Location = [Drawing.Point]::new(24, 35)
        $title.Size = [Drawing.Size]::new(510, 40)
        $title.Font = [Drawing.Font]::new('Segoe UI', 21, [Drawing.FontStyle]::Bold)
        $artResources.Add($title.Font)
        $title.BackColor = [Drawing.Color]::Transparent
        $title.ForeColor = if ($highContrast) { [Drawing.SystemColors]::WindowText } else { [Drawing.Color]::White }
        $subtitle = [Windows.Forms.Label]::new()
        $subtitle.Text = "Choose a backup. Select what matters.`r`nPrepare an HTML file to import in Edge."
        $subtitle.Location = [Drawing.Point]::new(26, 85)
        $subtitle.Size = [Drawing.Size]::new(495, 50)
        $subtitle.Font = [Drawing.Font]::new('Segoe UI', 10)
        $artResources.Add($subtitle.Font)
        $subtitle.BackColor = [Drawing.Color]::Transparent
        $subtitle.ForeColor = if ($highContrast) { [Drawing.SystemColors]::WindowText } else {
            [Drawing.ColorTranslator]::FromHtml('#DDF5FB')
        }
        $textParent = if ($highContrast) { $hero } else { $picture }
        $textParent.Controls.AddRange(@($title, $subtitle))
        $picker.SelectedIndex = 0
        $null = $form.ShowDialog()
    }
    finally {
        $form.Dispose()
        foreach ($resource in $artResources) { $resource.Dispose() }
    }
}

Add-Type -AssemblyName System.Windows.Forms
try {
    if ($env:OS -ne 'Windows_NT' -or -not [Environment]::UserInteractive -or
        [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        throw 'Run this helper in an interactive Windows session with PowerShell -STA.'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if ($identity.User.Value -in @('S-1-5-18', 'S-1-5-19', 'S-1-5-20') -or
        $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run the shortcut as the signed-in user, not elevated or as a service account.'
    }
    $local = Join-Path $env:LOCALAPPDATA 'EdgeFavoritesBackupRestore'
    $null = New-Item -Path $local -ItemType Directory -Force -ErrorAction Stop
    $script:RecoveryLog = Join-Path $local 'Recovery.log'
    . (Join-Path $PSScriptRoot 'FavoritesBackup.Common.ps1')
    if (-not $PSBoundParameters.ContainsKey('ConfigurationPath')) {
        $ConfigurationPath = Join-Path $PSScriptRoot 'Configuration.json'
    }
    if ([string]::IsNullOrWhiteSpace($ConfigurationPath)) { throw 'ConfigurationPath must not be empty.' }
    if ($Mode -eq 'Backup') {
        & (Join-Path $PSScriptRoot 'Backup-EdgeFavorites.ps1') -ConfigurationPath $ConfigurationPath -ForceBackup
        $null = [Windows.Forms.MessageBox]::Show(
            'Backup files were written for all selected profiles. This does not confirm OneDrive upload. See Backup.log for details.',
            'Back Up Edge Favorites', 'OK', 'Information')
    }
    else {
        $configuration = Get-Content -LiteralPath $ConfigurationPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $root = Get-FavoritesBackupRoot -ConfiguredPath $configuration.BackupRoot
        $files = @(Get-FavoritesRecoveryFiles -BackupRoot $root -BackupSetName $configuration.BackupSetName)
        if ($files.Count -eq 0) { throw 'No local recovery files are available. Check storage synchronization or contact the help desk.' }
        Show-FavoritesRestoreForm -Files $files -RecoveryRoot (Join-Path $local 'Recovery') -AssetsPath (Join-Path $PSScriptRoot 'assets')
    }
}
catch {
    if ($script:RecoveryLog) { Show-FavoritesError -Message $_.Exception.Message }
    else { $null = [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Edge Favorites', 'OK', 'Error') }
    exit 1
}
