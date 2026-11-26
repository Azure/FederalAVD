BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $artifactPath = Join-Path $repoRoot 'customer-examples\artifacts\EdgeFavoritesBackupRestore'
    $installerPath = Join-Path $artifactPath 'Deploy-EdgeFavoritesBackupRestore.ps1'
    $workerPath = Join-Path $artifactPath 'scripts\Backup-EdgeFavorites.ps1'
    $commonPath = Join-Path $artifactPath 'scripts\FavoritesBackup.Common.ps1'
    $helperPath = Join-Path $artifactPath 'scripts\Show-EdgeFavorites.ps1'
    $asts = @{}
    foreach ($path in @($installerPath, $workerPath, $commonPath, $helperPath)) {
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
        if ($errors.Count) { throw "Cannot parse $path" }
        $asts[$path] = $ast
        foreach ($definition in $ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst]
        }, $false)) {
            . ([scriptblock]::Create($definition.Extent.Text))
        }
    }
    function New-TestBookmarks {
        @'
{
  "roots": {
    "bookmark_bar": {
      "type": "folder", "name": "Localized toolbar", "date_added": "11644473600000000",
      "children": [
        { "type": "url", "name": "A & B <link>", "url": "https://example.test/?q=\"quoted\"&a=1", "date_added": "21474836480000000" },
        { "type": "folder", "name": "Favorites Bar", "children": [
          { "type": "url", "name": "Nested", "url": "https://example.test/nested" }
        ] }
      ]
    },
    "other": { "type": "folder", "name": "Other", "children": [] },
    "synced": { "type": "folder", "name": "Mobile", "children": [] }
  }
}
'@ | ConvertFrom-Json
    }
    function Write-TestBookmarks {
        param($Data = (New-TestBookmarks))
        [IO.File]::WriteAllText($script:bookmarksPath, ($Data | ConvertTo-Json -Depth 20), [Text.Encoding]::UTF8)
    }
    function New-TestEdgeProfile {
        param([string]$Name, [string]$Content = ([IO.File]::ReadAllText($script:bookmarksPath)))
        $userData = Split-Path (Split-Path $script:bookmarksPath)
        $directory = Join-Path $userData $Name
        $null = New-Item -Path $directory -ItemType Directory -Force
        [IO.File]::WriteAllText((Join-Path $directory 'Bookmarks'), $Content, [Text.Encoding]::UTF8)
    }
}

Describe 'Edge favorites package contract' {
    It 'has one root script, nested worker, documentation and ASCII PowerShell' {
        @(Get-ChildItem -LiteralPath $artifactPath -Filter '*.ps1' -File).Count | Should -Be 1
        Test-Path -LiteralPath (Join-Path $artifactPath 'README.md') | Should -BeTrue
        foreach ($path in @(Get-ChildItem -LiteralPath $artifactPath -Filter '*.ps1' -File -Recurse).FullName) {
            Get-Content -LiteralPath $path -Raw | Should -Not -Match '[^\x00-\x7E]'
            Get-Content -LiteralPath $path -Raw | Should -Not -Match 'FederalAVD'
        }
        Get-Content -LiteralPath (Join-Path $artifactPath 'README.md') -Raw | Should -Not -Match 'FederalAVD'
    }

    It 'keeps user execution out of the installer and automatic recovery out of tasks' {
        $installer = Get-Content -LiteralPath $installerPath -Raw
        $worker = Get-Content -LiteralPath $workerPath -Raw
        $installer | Should -Not -Match 'Start-ScheduledTask|Invoke-FavoritesBackup'
        $worker | Should -Not -Match 'Stop-Process|Start-Process|Invoke-WebRequest|Invoke-RestMethod'
        $installer | Should -Match 'Assert-ProtectedBackupPath -Path \$path'
        $installer | Should -Match 'Assert-ProtectedBackupPath -Path \$configurationPath'
        $worker | Should -Match 'must not run as SYSTEM'
    }

    It 'defaults to business OneDrive discovery and every persistent browser profile without recurring task parameters' {
        $parameters = $asts[$installerPath].ParamBlock.Parameters
        ($parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'BackupRoot' }).DefaultValue.SafeGetValue() |
            Should -Be ''
        ($parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'EdgeProfileName' }).DefaultValue.SafeGetValue() |
            Should -Be '*'
        $parameters.Name.VariablePath.UserPath | Should -Not -Contain 'CheckIntervalMinutes'
        $asts[$workerPath].ParamBlock.Parameters.Name.VariablePath.UserPath | Should -Not -Contain 'RegisterUserTask'
        Get-Content -LiteralPath $workerPath -Raw |
            Should -Not -Match 'ScheduledTask|Start-Sleep|RegisterUserTask|CheckIntervalMinutes'
    }

    It 'does not resolve a configuration path during worker parameter binding' {
        $parameter = $asts[$workerPath].ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'ConfigurationPath' }
        $parameter.DefaultValue | Should -BeNullOrEmpty
        $parametersOnly = [scriptblock]::Create($asts[$workerPath].ParamBlock.Extent.Text)
        { & $parametersOnly } | Should -Not -Throw
    }

    It 'rejects invalid namespace <Name> before installation' -TestCases @(
        @{ Name = '..' }, @{ Name = '..\outside' }, @{ Name = 'folder.' },
        @{ Name = 'folder ' }, @{ Name = 'C:\outside' }, @{ Name = '' }
    ) {
        param($Name)
        $parametersOnly = [scriptblock]::Create($asts[$installerPath].ParamBlock.Extent.Text)
        { & $parametersOnly -BackupSetName $Name } | Should -Throw
    }
}

Describe 'Favorites artwork' {
    It 'ships a readable wide banner and distinct seven-resolution icons' {
        Add-Type -AssemblyName System.Drawing
        $assetsPath = Join-Path $artifactPath 'scripts\assets'
        $image = [Drawing.Image]::FromFile((Join-Path $assetsPath 'favorites-restore-banner.png'))
        try {
            $image.Width | Should -Be 1200
            $image.Height | Should -Be 240
        }
        finally { $image.Dispose() }
        foreach ($role in @('backup', 'restore')) {
            $bytes = [IO.File]::ReadAllBytes((Join-Path $assetsPath "favorites-$role.ico"))
            [BitConverter]::ToUInt16($bytes, 0) | Should -Be 0
            [BitConverter]::ToUInt16($bytes, 2) | Should -Be 1
            [BitConverter]::ToUInt16($bytes, 4) | Should -Be 7
            $sizes = @(16, 24, 32, 48, 64, 128, 256)
            for ($i = 0; $i -lt $sizes.Count; $i++) {
                $entry = 6 + 16 * $i
                $size = if ($bytes[$entry] -eq 0) { 256 } else { [int]$bytes[$entry] }
                $size | Should -Be $sizes[$i]
                $length = [BitConverter]::ToUInt32($bytes, $entry + 8)
                $offset = [BitConverter]::ToUInt32($bytes, $entry + 12)
                ($offset + $length) | Should -BeLessOrEqual $bytes.Length
                $stream = [IO.MemoryStream]::new($bytes, [int]$offset, [int]$length)
                $frame = $null
                try {
                    $frame = [Drawing.Bitmap]::new($stream)
                    $frame.Width | Should -Be $size
                    $frame.Height | Should -Be $size
                    $frame.GetPixel(0, 0).A | Should -Be 0
                }
                finally {
                    if ($frame) { $frame.Dispose() }
                    $stream.Dispose()
                }
            }
        }
        (Get-FileHash -LiteralPath (Join-Path $assetsPath 'favorites-backup.ico')).Hash |
            Should -Not -Be (Get-FileHash -LiteralPath (Join-Path $assetsPath 'favorites-restore.ico')).Hash
    }

    It 'keeps the artwork generator parseable and out of runtime installation' {
        $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $artifactPath 'scripts\assets\New-FavoritesArtwork.ps1'), [ref]$null, [ref]$errors)
        $errors.Count | Should -Be 0
        Get-Content -LiteralPath $installerPath -Raw | Should -Not -Match 'New-FavoritesArtwork'
        Get-Content -LiteralPath $helperPath -Raw | Should -Not -Match 'New-FavoritesArtwork'
    }
}

Describe 'Favorites HTML conversion' {
    It 'escapes names and URL attributes and preserves nested folders and root sections' {
        $result = ConvertTo-FavoritesHtml -Data (New-TestBookmarks)
        $result.Count | Should -Be 2
        $result.Html | Should -Match 'A &amp; B &lt;link&gt;'
        $result.Html | Should -Match 'q=&quot;quoted&quot;&amp;a=1'
        $result.Html | Should -Match '<H3>Favorites Bar</H3>\r?\n<DL><p>\r?\n<DT><A'
        $result.Html | Should -Match '>Other</H3>'
        $result.Html | Should -Match '>Mobile</H3>'
        ([regex]::Matches($result.Html, 'PERSONAL_TOOLBAR_FOLDER="true"')).Count | Should -Be 1
        ([regex]::Matches($result.Html, '<DL>')).Count |
            Should -Be ([regex]::Matches($result.Html, '</DL>')).Count
    }

    It 'converts UTC epoch and post-2038 timestamps without rounding or Int32 overflow' {
        $data = New-TestBookmarks
        $data.roots.bookmark_bar.children[0].date_added = '13791957248123456'
        $result = ConvertTo-FavoritesHtml -Data $data
        $result.Html | Should -Match '<H3 ADD_DATE="0" PERSONAL_TOOLBAR_FOLDER'
        $expected = [DateTimeOffset]::FromFileTime(137919572481234560).ToUnixTimeSeconds()
        $expected | Should -BeGreaterThan ([int]::MaxValue)
        $result.Html | Should -Match "ADD_DATE=`"$expected`""
    }

    It 'preserves non-English titles through UTF-8 output and HTML decoding' {
        $data = New-TestBookmarks
        $title = 'Caf' + [char]0xE9 + ' ' + [char]0x4E2D
        $data.roots.bookmark_bar.name = $title
        $result = ConvertTo-FavoritesHtml -Data $data
        [Net.WebUtility]::HtmlDecode($result.Html) | Should -Match ([regex]::Escape($title))
    }

    It 'rejects malformed or unknown bookmark structures' -TestCases @(
        @{ Json = '{}' }
        @{ Json = '{"roots":{}}' }
        @{ Json = '{"roots":{"bookmark_bar":{"name":"x","type":"folder"}}}' }
        @{ Json = '{"roots":{"bookmark_bar":{"name":"x","type":"unexpected"}}}' }
        @{ Json = '{"roots":{"bookmark_bar":{"name":"x","type":"url","url":""}}}' }
    ) {
        param($Json)
        { ConvertTo-FavoritesHtml -Data ($Json | ConvertFrom-Json) } | Should -Throw
    }
}

Describe 'Interactive favorites recovery' {
    It 'round-trips nested, escaped and non-English favorites without executing HTML' {
        $data = New-TestBookmarks
        $data.roots.bookmark_bar.children[0].name = 'Line 1' + "`n" + [char]0x4E2D + ' & <title>'
        $snapshot = Read-FavoritesSnapshot -Html (ConvertTo-FavoritesHtml -Data $data).Html
        $snapshot.Count | Should -Be 2
        $snapshot.Root.Children[0].Children[0].Name | Should -BeExactly $data.roots.bookmark_bar.children[0].name
        $snapshot.Root.Children[0].Children[0].Url | Should -BeExactly $data.roots.bookmark_bar.children[0].url
        $snapshot.Root.Children[0].Children[1].Children[0].Selected = $true
        $selected = ConvertTo-SelectedFavoritesHtml -Snapshot $snapshot
        $selected.Count | Should -Be 1
        $selected.Html | Should -Not -Match 'quoted|Other|Mobile'
        $selected.Html | Should -Match 'PERSONAL_TOOLBAR_FOLDER="true"'
        $restored = Read-FavoritesSnapshot -Html $selected.Html
        $restored.Root.Children[0].Children[0].Name | Should -Be 'Favorites Bar'
        $restored.Root.Children[0].Children[0].Children[0].Url | Should -Be 'https://example.test/nested'
    }

    It 'rejects no selection and malformed or unsupported snapshots' {
        $html = (ConvertTo-FavoritesHtml -Data (New-TestBookmarks)).Html
        $snapshot = Read-FavoritesSnapshot -Html $html
        { ConvertTo-SelectedFavoritesHtml -Snapshot $snapshot } | Should -Throw '*Select at least one*'
        { Read-FavoritesSnapshot -Html '<html>not a backup</html>' } | Should -Throw
        { Read-FavoritesSnapshot -Html ($html + '<script>alert(1)</script>') } | Should -Throw
        { Read-FavoritesSnapshot -Html ($html.Replace('</H3>', '</H4>')) } | Should -Throw
        { Read-FavoritesSnapshot -Html ($html.Substring(0, $html.LastIndexOf('</DL>'))) } | Should -Throw
    }

    It 'preserves the full snapshot outside history and writes only selected favorites' {
        $html = (ConvertTo-FavoritesHtml -Data (New-TestBookmarks)).Html
        $snapshot = Read-FavoritesSnapshot -Html $html
        $snapshot.Root.Children[0].Children[0].Selected = $true
        $recoveryRoot = Join-Path $TestDrive 'Recovery'
        $result = Save-FavoritesRecovery -Snapshot $snapshot -RecoveryRoot $recoveryRoot
        $result.Count | Should -Be 1
        Get-Content -LiteralPath (Join-Path (Split-Path $result.Path) 'Source.html') -Raw | Should -BeExactly $html
        $subset = Read-FavoritesSnapshot -Html (Get-Content -LiteralPath $result.Path -Raw -Encoding UTF8)
        $subset.Count | Should -Be 1
        $subset.Root.Children[0].Children[0].Name | Should -Be 'A & B <link>'
        $again = Save-FavoritesRecovery -Snapshot $snapshot -RecoveryRoot $recoveryRoot
        $again.Path | Should -Not -Be $result.Path
        $snapshot.Html | Should -BeExactly $html
        { Save-FavoritesRecovery -Snapshot $snapshot -RecoveryRoot $result.Path } | Should -Throw
    }

    It 'discovers dated snapshots from old profiles without needing a live Edge profile' {
        $root = Join-Path $TestDrive 'Catalog'
        $profile = Join-Path $root 'EdgeFavoritesBackupRestore\Test\Old Profile'
        $history = Join-Path $profile 'History'
        $null = New-Item -Path $history -ItemType Directory -Force
        $html = (ConvertTo-FavoritesHtml -Data (New-TestBookmarks)).Html
        [IO.File]::WriteAllText((Join-Path $profile 'Latest.html'), $html)
        $dated = Join-Path $history 'Favorites-20261126T1234561234567Z-0123456789abcdef0123456789abcdef.html'
        [IO.File]::WriteAllText($dated, $html)
        [IO.File]::WriteAllText((Join-Path $history 'unrelated.html'), $html)
        $files = @(Get-FavoritesRecoveryFiles -BackupRoot $root -BackupSetName 'Test')
        $files.Count | Should -Be 2
        $files[0].Label | Should -Match 'Old Profile.*Latest'
        $files[1].Label | Should -Be 'Old Profile | 2026-11-26 12:34:56Z'
        $files[1].Path | Should -Be $dated
        { Get-FavoritesRecoveryFiles -BackupRoot $root -BackupSetName '..' } | Should -Throw
        { Get-FavoritesRecoveryFiles -BackupRoot $root -BackupSetName 'Missing' } | Should -Throw '*unavailable*'
    }

    It 'creates adjacent non-elevated STA shortcuts with explicit modes and installed configuration' {
        $script:shortcutCalls = [Collections.Generic.List[object]]::new()
        $shell = New-Object psobject
        $shell | Add-Member -MemberType ScriptMethod -Name CreateShortcut -Value {
            param($Path)
            $shortcut = [pscustomobject]@{
                Path = $Path; TargetPath = ''; Arguments = ''; WorkingDirectory = ''; Description = ''; IconLocation = ''
            }
            $shortcut | Add-Member -MemberType ScriptMethod -Name Save -Value { $script:shortcutCalls.Add($this) }
            return $shortcut
        }
        Mock New-Object { $shell } -ParameterFilter { $ComObject -eq 'WScript.Shell' }
        Mock Initialize-BackupDirectory {}
        Mock Assert-ProtectedBackupPath {}
        $helper = 'C:\ProgramData\EdgeFavoritesBackupRestore\Show-EdgeFavorites.ps1'
        $config = 'C:\ProgramData\EdgeFavoritesBackupRestore\Configuration.json'
        Register-FavoritesShortcuts -HelperPath $helper -ConfigPath $config
        $script:shortcutCalls.Count | Should -Be 2
        Split-Path $script:shortcutCalls[0].Path | Should -Be (Split-Path $script:shortcutCalls[1].Path)
        Split-Path $script:shortcutCalls[0].Path -Leaf | Should -Be 'Back Up Edge Favorites.lnk'
        Split-Path $script:shortcutCalls[1].Path -Leaf | Should -Be 'Restore Edge Favorites.lnk'
        foreach ($shortcut in $script:shortcutCalls) {
            $shortcut.Arguments | Should -Match '\s-STA\s'
            $shortcut.Arguments | Should -Match ([regex]::Escape('-ConfigurationPath "' + $config + '"'))
            $shortcut.Arguments | Should -Not -Match 'NonInteractive|RunAs'
        }
        $script:shortcutCalls[0].Arguments | Should -Match '-Mode Backup'
        $script:shortcutCalls[1].Arguments | Should -Match '-Mode Restore'
        $script:shortcutCalls[0].IconLocation | Should -Be 'C:\ProgramData\EdgeFavoritesBackupRestore\assets\favorites-backup.ico,0'
        $script:shortcutCalls[1].IconLocation | Should -Be 'C:\ProgramData\EdgeFavoritesBackupRestore\assets\favorites-restore.ico,0'
    }

    It 'wires the Windows form selection, preparation and corrupt-snapshot error states' {
        Add-Type -AssemblyName System.Windows.Forms
        $html = (ConvertTo-FavoritesHtml -Data (New-TestBookmarks)).Html
        $snapshotPath = Join-Path $TestDrive 'FormSnapshot.html'
        $badPath = Join-Path $TestDrive 'CorruptSnapshot.html'
        [IO.File]::WriteAllText($snapshotPath, $html)
        [IO.File]::WriteAllText($badPath, 'corrupt')
        $script:RecoveryLog = Join-Path $TestDrive 'Recovery.log'
        $script:formRecoveryRoot = Join-Path $TestDrive 'FormRecovery'
        $form = [Windows.Forms.Form]::new()
        $form | Add-Member -MemberType ScriptMethod -Name ShowDialog -Force -Value {
            $picker, $tree, $status, $prepare, $instructions = @($this.Controls)[0..4]
            $this.Icon.Width | Should -Be 32
            $hero = $this.Controls['FavoritesBanner']
            $hero | Should -Not -BeNullOrEmpty
            $hero.Bottom | Should -BeLessThan $picker.Top
            $tree.Bottom | Should -BeLessOrEqual $status.Top
            $instructions.Bottom | Should -BeLessOrEqual $this.ClientSize.Height
            if (-not [Windows.Forms.SystemInformation]::HighContrast) {
                $hero.Controls['FavoritesBannerImage'].Image.Width | Should -Be 1200
            }
            $tree.Nodes.Count | Should -Be 3
            $status.Text | Should -Match '2 favorites'
            $tree.Nodes[0].Nodes[0].ToolTipText | Should -Match 'quoted'
            $tree.Nodes[0].Checked | Should -BeFalse
            $tree.Nodes[0].Checked = $true
            $tree.Nodes[0].Nodes[0].Checked | Should -BeTrue
            $tree.Nodes[0].Nodes[1].Nodes[0].Checked | Should -BeTrue
            $tree.Nodes[0].Nodes[1].Nodes[0].Checked = $false
            $click = $prepare.GetType().GetMethod('OnClick', [Reflection.BindingFlags]'Instance, NonPublic')
            $null = $click.Invoke($prepare, @([EventArgs]::Empty))
            $instructions.Text | Should -Match 'Prepared 1 favorites; Edge has NOT been changed'
            $outputs = @(Get-ChildItem -LiteralPath $script:formRecoveryRoot -Filter 'Selected.html' -Recurse)
            $outputs.Count | Should -Be 1
            $selected = Read-FavoritesSnapshot -Html (Get-Content -LiteralPath $outputs[0].FullName -Raw)
            $selected.Count | Should -Be 1
            $tree.Nodes[0].Checked = $false
            $tree.Nodes[0].Nodes[0].Checked | Should -BeFalse
            $null = $click.Invoke($prepare, @([EventArgs]::Empty))
            $picker.SelectedIndex = 1
            $prepare.Enabled | Should -BeFalse
            $tree.Nodes.Count | Should -Be 0
        }
        Mock New-Object { $form } -ParameterFilter { $TypeName -eq 'Windows.Forms.Form' }
        Mock Show-FavoritesError {}
        $files = @(
            [pscustomobject]@{ Path = $snapshotPath; Label = 'Default | Latest' },
            [pscustomobject]@{ Path = $badPath; Label = 'Default | Corrupt' }
        )
        Show-FavoritesRestoreForm -Files $files -RecoveryRoot $script:formRecoveryRoot -AssetsPath (Join-Path $artifactPath 'scripts\assets')
        Should -Invoke Show-FavoritesError -Times 1 -Exactly -ParameterFilter { $Message -like '*Select at least one*' }
        Should -Invoke Show-FavoritesError -Times 1 -Exactly -ParameterFilter { $Message -like '*not an HTML snapshot*' }
    }
}

Describe 'Artifact staging without accessing installer favorites' {
    It 'stages the worker and literal configuration before registering the logon task' {
        $savedProgramData = $env:ProgramData
        $env:ProgramData = Join-Path $TestDrive 'ProgramData'
        $null = New-Item -Path $env:ProgramData -ItemType Directory -Force
        $BackupRoot = '\\files.example.test\UserBackups\%USERNAME%'
        $BackupSetName = 'PrimaryAVD'
        $EdgeProfileName = 'Profile 1'
        $BackupIntervalHours = 24
        $HistoryCount = 14
        Mock Initialize-BackupDirectory { $null = New-Item -Path $Path -ItemType Directory -Force }
        Mock Assert-ProtectedBackupPath {}
        Mock Remove-LegacyFavoritesTasks {}
        Mock Register-FavoritesShortcuts {}
        Mock Register-BackupLogonTask {
            Test-Path -LiteralPath $WorkerPath | Should -BeTrue
            Test-Path -LiteralPath $ConfigPath | Should -BeTrue
            $ConfigPath | Should -Be (Join-Path (Split-Path $WorkerPath) 'Configuration.json')
        }
        $start = $asts[$installerPath].EndBlock.Statements | Where-Object {
            $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$directory'
        }
        $statements = $asts[$installerPath].EndBlock.Statements | Where-Object {
            $_.Extent.StartOffset -ge $start.Extent.StartOffset
        }
        $body = [scriptblock]::Create(($statements.Extent.Text -join "`n").Replace('$PSScriptRoot', '$artifactPath'))
        try {
            $null = & $body
            $installed = Join-Path $env:ProgramData 'EdgeFavoritesBackupRestore'
            $configuration = Get-Content -LiteralPath (Join-Path $installed 'Configuration.json') -Raw | ConvertFrom-Json
            $configuration.BackupRoot | Should -BeExactly $BackupRoot
            $configuration.EdgeProfileName | Should -Be 'Profile 1'
            $configuration.PSObject.Properties.Name | Should -Not -Contain 'CheckIntervalMinutes'
            Get-Content -LiteralPath (Join-Path $installed 'Backup-EdgeFavorites.ps1') -Raw |
                Should -BeExactly (Get-Content -LiteralPath $workerPath -Raw)
            Should -Invoke Register-BackupLogonTask -Times 1 -Exactly
            Should -Invoke Remove-LegacyFavoritesTasks -Times 1 -Exactly -ParameterFilter {
                $WorkerPath -eq (Join-Path $env:ProgramData 'EdgeFavoritesBackupRestore\Backup-EdgeFavorites.ps1')
            }
            Should -Invoke Assert-ProtectedBackupPath -Times 7 -Exactly
            Should -Invoke Register-FavoritesShortcuts -Times 1 -Exactly -ParameterFilter {
                $HelperPath -eq (Join-Path $env:ProgramData 'EdgeFavoritesBackupRestore\Show-EdgeFavorites.ps1') -and
                $ConfigPath -eq (Join-Path $env:ProgramData 'EdgeFavoritesBackupRestore\Configuration.json')
            }
            foreach ($name in @('FavoritesBackup.Common.ps1', 'Show-EdgeFavorites.ps1')) {
                Get-Content -LiteralPath (Join-Path $installed $name) -Raw |
                    Should -BeExactly (Get-Content -LiteralPath (Join-Path $artifactPath "scripts\$name") -Raw)
            }
            foreach ($name in @('favorites-backup.ico', 'favorites-restore.ico', 'favorites-restore-banner.png')) {
                (Get-FileHash -LiteralPath (Join-Path $installed "assets\$name")).Hash |
                    Should -Be (Get-FileHash -LiteralPath (Join-Path $artifactPath "scripts\assets\$name")).Hash
            }
        }
        finally { $env:ProgramData = $savedProgramData }
    }
}

Describe 'Daily backup, retention and empty-profile protection' {
    BeforeEach {
        $script:savedLocalAppData = $env:LOCALAPPDATA
        $caseDirectory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $env:LOCALAPPDATA = Join-Path $caseDirectory 'Local'
        $root = Join-Path $caseDirectory 'Backups'
        $null = New-Item -Path $root -ItemType Directory -Force
        $sourceDirectory = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\Default'
        $null = New-Item -Path $sourceDirectory -ItemType Directory -Force
        $script:bookmarksPath = Join-Path $sourceDirectory 'Bookmarks'
        Write-TestBookmarks
        $options = @{
            BackupRoot = $root; BackupSetName = 'Test'; EdgeProfileName = 'Default'
            BackupIntervalHours = 24; HistoryCount = 2
        }
        $destination = Join-Path $root 'EdgeFavoritesBackupRestore\Test\Default'
        $latest = Join-Path $destination 'Latest.html'
        $history = Join-Path $destination 'History'
        Mock Write-BackupLog {}
    }
    AfterEach { $env:LOCALAPPDATA = $script:savedLocalAppData }

    It 'writes complete UTF-8 latest/history files and leaves source bytes untouched' {
        $original = (Get-FileHash -LiteralPath $script:bookmarksPath).Hash
        Invoke-FavoritesBackup @options
        Get-Content -LiteralPath $latest -Raw | Should -Match '<!DOCTYPE NETSCAPE-Bookmark-file-1>'
        @(Get-ChildItem -LiteralPath $history -File).Count | Should -Be 1
        Get-Content -LiteralPath $latest -Raw |
            Should -BeExactly (Get-Content -LiteralPath (Get-ChildItem $history -File)[0].FullName -Raw)
        (Get-FileHash -LiteralPath $script:bookmarksPath).Hash | Should -Be $original
        @(Get-ChildItem -LiteralPath $destination -Filter '*.tmp' -Recurse).Count | Should -Be 0
    }

    It 'bypasses only the age gate for an explicit manual backup' {
        Invoke-FavoritesBackup @options
        $data = New-TestBookmarks
        $data.roots.bookmark_bar.children[0].name = 'Manual change'
        Write-TestBookmarks -Data $data
        Invoke-FavoritesBackup @options
        Get-Content -LiteralPath $latest -Raw | Should -Not -Match 'Manual change'
        Invoke-ConfiguredFavoritesBackup -Configuration ([pscustomobject]$options) -ForceBackup
        Get-Content -LiteralPath $latest -Raw | Should -Match 'Manual change'
        @(Get-ChildItem -LiteralPath $history -File).Count | Should -Be 2
        $data.roots.bookmark_bar.children = @()
        Write-TestBookmarks -Data $data
        { Invoke-FavoritesBackup @options -ForceBackup } | Should -Throw '*No favorites*'
        Get-Content -LiteralPath $latest -Raw | Should -Match 'Manual change'
    }

    It 'discovers persistent profiles automatically and excludes Guest, System and cache directories' {
        New-TestEdgeProfile -Name 'Profile 1'
        New-TestEdgeProfile -Name 'Guest Profile'
        New-TestEdgeProfile -Name 'System Profile'
        $customName = 'Profil ' + [char]0xE9
        New-TestEdgeProfile -Name $customName
        $null = New-Item -Path (Join-Path (Split-Path (Split-Path $script:bookmarksPath)) 'ShaderCache') -ItemType Directory
        $profiles = @(Get-EdgeFavoritesProfiles -ProfileName '*')
        $profiles.Count | Should -Be 3
        $profiles | Should -Contain 'Default'
        $profiles | Should -Contain 'Profile 1'
        $profiles | Should -Contain $customName
        $configuration = [pscustomobject]$options.Clone()
        $configuration.EdgeProfileName = '*'
        Invoke-ConfiguredFavoritesBackup -Configuration $configuration
        foreach ($profile in $profiles) {
            Test-Path -LiteralPath (Join-Path $root "EdgeFavoritesBackupRestore\Test\$profile\Latest.html") | Should -BeTrue
        }
    }

    It 'supports selecting just one browser profile' {
        New-TestEdgeProfile -Name 'Profile 1'
        $configuration = [pscustomobject]$options.Clone()
        $configuration.EdgeProfileName = 'Profile 1'
        Invoke-ConfiguredFavoritesBackup -Configuration $configuration
        Test-Path -LiteralPath (Join-Path $root 'EdgeFavoritesBackupRestore\Test\Profile 1\Latest.html') | Should -BeTrue
        Test-Path -LiteralPath $latest | Should -BeFalse
    }

    It 'backs up healthy profiles after another profile fails and reports an overall failure' {
        New-TestEdgeProfile -Name 'A Broken' -Content '{invalid'
        $configuration = [pscustomobject]$options.Clone()
        $configuration.EdgeProfileName = '*'
        { Invoke-ConfiguredFavoritesBackup -Configuration $configuration } | Should -Throw '*A Broken*'
        Test-Path -LiteralPath $latest | Should -BeTrue
        Should -Invoke Write-BackupLog -Times 1 -Exactly -ParameterFilter {
            $Message -like "ERROR for Edge profile 'A Broken':*"
        }
    }

    It 'keeps backing up a healthy profile when another profile has become empty' {
        New-TestEdgeProfile -Name 'Profile 1'
        $configuration = [pscustomobject]$options.Clone()
        $configuration.EdgeProfileName = '*'
        Invoke-ConfiguredFavoritesBackup -Configuration $configuration
        $empty = New-TestBookmarks
        $empty.roots.bookmark_bar.children = @()
        Write-TestBookmarks -Data $empty
        $otherLatest = Join-Path $root 'EdgeFavoritesBackupRestore\Test\Profile 1\Latest.html'
        (Get-Item -LiteralPath $otherLatest).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-25)
        { Invoke-ConfiguredFavoritesBackup -Configuration $configuration } | Should -Throw '*Default*'
        @(Get-ChildItem -LiteralPath (Join-Path $root 'EdgeFavoritesBackupRestore\Test\Profile 1\History') -File).Count | Should -Be 2
        @(Get-ChildItem -LiteralPath $history -File).Count | Should -Be 1
    }

    It 'does not require recovery acknowledgment or a local state file' {
        $asts[$workerPath].ParamBlock.Parameters.Name.VariablePath.UserPath | Should -Not -Contain 'AcknowledgeRecovery'
        Get-Content -LiteralPath $workerPath -Raw | Should -Not -Match 'AcceptCurrentFavorites|State\.json'
    }

    It 'fails explicitly without changing backups when no persistent bookmarks files exist' {
        Invoke-FavoritesBackup @options
        $original = (Get-FileHash -LiteralPath $latest).Hash
        Remove-Item -LiteralPath $script:bookmarksPath
        { Get-EdgeFavoritesProfiles -ProfileName '*' } | Should -Throw '*No persistent Edge profiles*'
        (Get-FileHash -LiteralPath $latest).Hash | Should -Be $original
    }

    It 'enforces the actual 24-hour minimum at <Age> hours' -TestCases @(
        @{ Age = 23.99; Copies = 1 }
        @{ Age = 24; Copies = 2 }
    ) {
        param($Age, $Copies)
        Invoke-FavoritesBackup @options
        (Get-Item -LiteralPath $latest).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-$Age)
        Invoke-FavoritesBackup @options
        @(Get-ChildItem -LiteralPath $history -File).Count | Should -Be $Copies
    }

    It 'retains only the configured dated copies and never prunes unrelated files' {
        Invoke-FavoritesBackup @options
        $unrelated = Join-Path $history 'Important.html'
        [IO.File]::WriteAllText($unrelated, 'Keep this file')
        1..3 | ForEach-Object {
            (Get-Item -LiteralPath $latest).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-25)
            Invoke-FavoritesBackup @options
        }
        @(Get-ChildItem -LiteralPath $history -Filter 'Favorites-*.html').Count | Should -Be 2
        Get-Content -LiteralPath $unrelated -Raw | Should -BeExactly 'Keep this file'
    }

    It 'uses invariant history filenames under non-Gregorian user cultures' {
        $oldCulture = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('ar-SA')
            Invoke-FavoritesBackup @options
        }
        finally { [Threading.Thread]::CurrentThread.CurrentCulture = $oldCulture }
        $file = Get-ChildItem -LiteralPath $history -File
        $file.Name | Should -Match ('^Favorites-' + [DateTime]::UtcNow.Year + '\d{4}T\d{13}Z-[a-f0-9]{32}\.html$')
    }

    It 'preserves the latest backup on invalid JSON, empty favorites or missing source' {
        Invoke-FavoritesBackup @options
        $original = (Get-FileHash -LiteralPath $latest).Hash
        (Get-Item -LiteralPath $latest).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-25)
        [IO.File]::WriteAllText($script:bookmarksPath, '{invalid')
        { Invoke-FavoritesBackup @options } | Should -Throw
        $empty = New-TestBookmarks
        $empty.roots.bookmark_bar.children = @()
        Write-TestBookmarks -Data $empty
        { Invoke-FavoritesBackup @options } | Should -Throw '*No favorites*'
        Remove-Item -LiteralPath $script:bookmarksPath
        { Invoke-FavoritesBackup @options } | Should -Throw
        (Get-FileHash -LiteralPath $latest).Hash | Should -Be $original
        @(Get-ChildItem -LiteralPath $history -File).Count | Should -Be 1
    }

    It 'automatically resumes due backups after Windows profile recreation with nonempty favorites' {
        Invoke-FavoritesBackup @options
        (Get-Item -LiteralPath $latest).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-25)
        $env:LOCALAPPDATA = Join-Path $caseDirectory 'RecreatedLocal'
        $newSource = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\Default'
        $null = New-Item -Path $newSource -ItemType Directory -Force
        $script:bookmarksPath = Join-Path $newSource 'Bookmarks'
        Write-TestBookmarks
        { Invoke-FavoritesBackup @options } | Should -Not -Throw
        @(Get-ChildItem -LiteralPath $history -File).Count | Should -Be 2
    }

    It 'retains a dated recovery copy when a nonempty Edge-only reset is not detected' {
        Invoke-FavoritesBackup @options
        $oldCopy = Get-ChildItem -LiteralPath $history -File
        $oldHash = (Get-FileHash -LiteralPath $oldCopy.FullName).Hash
        $replacement = New-TestBookmarks
        $replacement.roots.bookmark_bar.children[0].name = 'Replacement defaults'
        Write-TestBookmarks -Data $replacement
        (Get-Item -LiteralPath $latest).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-25)
        Invoke-FavoritesBackup @options
        Get-Content -LiteralPath $latest -Raw | Should -Match 'Replacement defaults'
        (Get-FileHash -LiteralPath $oldCopy.FullName).Hash | Should -Be $oldHash
        Get-Content -LiteralPath $oldCopy.FullName -Raw | Should -Match 'A &amp; B &lt;link&gt;'
        @(Get-ChildItem -LiteralPath $history -File).Count | Should -Be 2
    }

    It 'does not prune the old namespace when a recreated browser uses a different profile directory' {
        Invoke-FavoritesBackup @options
        $oldCopy = Get-ChildItem -LiteralPath $history -File
        $oldHash = (Get-FileHash -LiteralPath $oldCopy.FullName).Hash
        New-TestEdgeProfile -Name 'Profile 1'
        Remove-Item -LiteralPath $script:bookmarksPath
        $configuration = [pscustomobject]$options.Clone()
        $configuration.EdgeProfileName = '*'
        Invoke-ConfiguredFavoritesBackup -Configuration $configuration
        Test-Path -LiteralPath (Join-Path $root 'EdgeFavoritesBackupRestore\Test\Profile 1\Latest.html') | Should -BeTrue
        (Get-FileHash -LiteralPath $oldCopy.FullName).Hash | Should -Be $oldHash
        @(Get-ChildItem -LiteralPath $history -File).Count | Should -Be 1
    }

    It 'keeps history and resumes backups if Latest.html is missing' {
        Invoke-FavoritesBackup @options
        $oldCopy = Get-ChildItem -LiteralPath $history -File
        Remove-Item -LiteralPath $latest
        { Invoke-FavoritesBackup @options } | Should -Not -Throw
        Test-Path -LiteralPath $oldCopy.FullName | Should -BeTrue
        @(Get-ChildItem -LiteralPath $history -File).Count | Should -Be 2
    }

    It 'preserves old backups across empty-profile checks and resumes automatically after favorites return' {
        Invoke-FavoritesBackup @options
        $original = (Get-FileHash -LiteralPath $latest).Hash
        (Get-Item -LiteralPath $latest).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-25)
        $empty = New-TestBookmarks
        $empty.roots.bookmark_bar.children = @()
        Write-TestBookmarks -Data $empty
        1..3 | ForEach-Object { { Invoke-FavoritesBackup @options } | Should -Throw '*No favorites*' }
        (Get-FileHash -LiteralPath $latest).Hash | Should -Be $original
        @(Get-ChildItem -LiteralPath $history -File).Count | Should -Be 1
        Write-TestBookmarks
        { Invoke-FavoritesBackup @options } | Should -Not -Throw
        @(Get-ChildItem -LiteralPath $history -File).Count | Should -Be 2
    }

    It 'leaves a good backup intact when destination replacement fails and cleans temporary files' {
        Invoke-FavoritesBackup @options
        (Get-Item -LiteralPath $latest).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-25)
        $original = (Get-FileHash -LiteralPath $latest).Hash
        $heldFile = [IO.File]::Open($latest, 'Open', 'Read', 'None')
        try { { Invoke-FavoritesBackup @options } | Should -Throw }
        finally { $heldFile.Dispose() }
        (Get-FileHash -LiteralPath $latest).Hash | Should -Be $original
        @(Get-ChildItem -LiteralPath $destination -Filter '*.tmp' -Recurse).Count | Should -Be 0
    }

    It 'rejects overlapping destination access and releases its lock after failures' {
        Invoke-FavoritesBackup @options
        $lockPath = Join-Path $destination 'Backup.lock'
        $heldLock = [IO.File]::Open($lockPath, 'Open', 'ReadWrite', 'None')
        try { { Invoke-FavoritesBackup @options } | Should -Throw }
        finally { $heldLock.Dispose() }
        { Invoke-FavoritesBackup @options } | Should -Not -Throw
    }

    It 'never creates an unavailable destination root' {
        $options.BackupRoot = Join-Path $root 'NotConfigured'
        { Invoke-FavoritesBackup @options } | Should -Throw '*will not be created*'
        Test-Path -LiteralPath $options.BackupRoot | Should -BeFalse
    }

    It 'runs under Windows PowerShell 5.1 and returns a failed process code for invalid data' {
        $configuration = $options.Clone()
        $configuration.CheckIntervalMinutes = 60
        $configPath = Join-Path $caseDirectory 'Configuration.json'
        [IO.File]::WriteAllText($configPath, ($configuration | ConvertTo-Json))
        $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments = '-NoLogo -NoProfile -NonInteractive -File "{0}" -ConfigurationPath "{1}"' -f $workerPath, $configPath
        $stdout = Join-Path $caseDirectory 'worker.stdout'
        $stderr = Join-Path $caseDirectory 'worker.stderr'
        $process = Start-Process -FilePath $powerShell -ArgumentList $arguments -Wait -PassThru `
            -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        try { $process.ExitCode | Should -Be 0 -Because (Get-Content -LiteralPath $stderr -Raw) }
        finally { $process.Dispose() }
        (Get-Item -LiteralPath $latest).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-25)
        $process = Start-Process -FilePath $powerShell -ArgumentList $arguments -Wait -PassThru `
            -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        try { $process.ExitCode | Should -Be 0 -Because (Get-Content -LiteralPath $stderr -Raw) }
        finally { $process.Dispose() }
        [IO.File]::WriteAllText($script:bookmarksPath, 'invalid')
        $process = Start-Process -FilePath $powerShell -ArgumentList $arguments -Wait -PassThru `
            -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        try { $process.ExitCode | Should -Be 1 }
        finally { $process.Dispose() }
        Get-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'EdgeFavoritesBackupRestore\Backup.log') -Raw |
            Should -Match 'ERROR:'
    }

    It 'resolves omitted configuration beside the worker under Windows PowerShell 5.1' {
        $configuration = $options.Clone()
        $configuration.CheckIntervalMinutes = 60
        $configPath = Join-Path $caseDirectory 'Configuration.json'
        [IO.File]::WriteAllText($configPath, ($configuration | ConvertTo-Json))
        $stagedWorker = Join-Path $caseDirectory 'Backup-EdgeFavorites.ps1'
        Copy-Item -LiteralPath $workerPath -Destination $stagedWorker
        Copy-Item -LiteralPath $commonPath -Destination $caseDirectory
        $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments = '-NoLogo -NoProfile -NonInteractive -File "{0}"' -f $stagedWorker
        $stdout = Join-Path $caseDirectory 'default-worker.stdout'
        $stderr = Join-Path $caseDirectory 'default-worker.stderr'
        $process = Start-Process -FilePath $powerShell -ArgumentList $arguments -Wait -PassThru `
            -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        try { $process.ExitCode | Should -Be 0 -Because (Get-Content -LiteralPath $stderr -Raw) }
        finally { $process.Dispose() }
        Test-Path -LiteralPath $latest | Should -BeTrue

        Remove-Item -LiteralPath $configPath
        $process = Start-Process -FilePath $powerShell -ArgumentList $arguments -Wait -PassThru `
            -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        try { $process.ExitCode | Should -Be 1 }
        finally { $process.Dispose() }
        Get-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'EdgeFavoritesBackupRestore\Backup.log') -Raw |
            Should -Match 'ERROR:.*Configuration.json'
    }

    It 'logs a missing script directory instead of failing during parameter binding' {
        $worker = [scriptblock]::Create($asts[$workerPath].Extent.Text)
        { & $worker } | Should -Throw '*Cannot resolve ConfigurationPath without a script directory*'
        Should -Invoke Write-BackupLog -Times 1 -Exactly -ParameterFilter {
            $Message -like 'ERROR:*Cannot resolve ConfigurationPath*'
        }
        Test-Path -LiteralPath $destination | Should -BeFalse
    }

    It 'logs an explicitly empty configuration path without attempting a backup' {
        $worker = [scriptblock]::Create($asts[$workerPath].Extent.Text)
        { & $worker -ConfigurationPath '' } | Should -Throw '*ConfigurationPath must not be empty*'
        Should -Invoke Write-BackupLog -Times 1 -Exactly -ParameterFilter {
            $Message -like 'ERROR:*ConfigurationPath must not be empty*'
        }
        Test-Path -LiteralPath $destination | Should -BeFalse
    }

    It 'checks once per invocation without registering tasks, including with legacy configuration' {
        $configuration = $options.Clone()
        $configuration.CheckIntervalMinutes = 60
        $configPath = Join-Path $caseDirectory 'Configuration.json'
        [IO.File]::WriteAllText($configPath, ($configuration | ConvertTo-Json))
        $worker = [scriptblock]::Create($asts[$workerPath].Extent.Text.Replace('$PSScriptRoot', '(Split-Path $workerPath)'))
        Mock Register-ScheduledTask {}
        Mock Invoke-ConfiguredFavoritesBackup {}
        foreach ($signIn in 1..3) { & $worker -ConfigurationPath $configPath }
        Should -Invoke Invoke-ConfiguredFavoritesBackup -Times 3 -Exactly
        Should -Invoke Register-ScheduledTask -Times 0 -Exactly
    }
}

Describe 'Business OneDrive discovery' {
    BeforeEach {
        $savedOneDrive = $env:OneDriveCommercial
        $env:OneDriveCommercial = ''
        Mock Test-Path { $true }
        Mock Get-ChildItem { [pscustomobject]@{ PSChildName = 'Business1'; PSPath = 'HKCU:\Business1' } }
        Mock Get-ItemProperty { [pscustomobject]@{ UserFolder = 'C:\ConfiguredBusiness' } }
    }
    AfterEach { $env:OneDriveCommercial = $savedOneDrive }

    It 'prefers the configured business environment root' {
        $env:OneDriveCommercial = 'C:\BusinessEnvironment'
        Get-FavoritesBackupRoot | Should -Be 'C:\BusinessEnvironment'
        Should -Invoke Get-ChildItem -Times 0
    }

    It 'uses the business account registry when the environment is unavailable' {
        Get-FavoritesBackupRoot | Should -Be 'C:\ConfiguredBusiness'
    }

    It 'fails explicitly rather than choosing an ambiguous business account' {
        Mock Get-ChildItem {
            [pscustomobject]@{ PSChildName = 'Business1'; PSPath = 'HKCU:\Business1' }
            [pscustomobject]@{ PSChildName = 'Business2'; PSPath = 'HKCU:\Business2' }
        }
        Mock Get-ItemProperty { [pscustomobject]@{ UserFolder = "C:\$($LiteralPath.Split('\')[-1])" } }
        { Get-FavoritesBackupRoot } | Should -Throw '*unambiguous*'
    }

    It 'rejects relative and unresolved explicit roots' {
        { Get-FavoritesBackupRoot -ConfiguredPath 'relative\folder' } | Should -Throw '*absolute*'
        { Get-FavoritesBackupRoot -ConfiguredPath 'C:relative\folder' } | Should -Throw '*absolute*'
        { Get-FavoritesBackupRoot -ConfiguredPath '\rooted-on-current-drive' } | Should -Throw '*absolute*'
        { Get-FavoritesBackupRoot -ConfiguredPath '%UNDEFINED_FAVORITES_TEST_VARIABLE%\folder' } | Should -Throw '*absolute*'
    }
}

Describe 'Single logon task identity and staging protection' {
    BeforeEach {
        $script:registeredTask = $null
        Mock Register-ScheduledTask {
            $script:registeredTask = [pscustomobject]@{
                Name = $TaskName; Action = $Action; Trigger = $Trigger
                Principal = $Principal; Settings = $Settings; Force = $Force
            }
        }
    }

    It 'registers an all-user limited logon task with a two-minute delay' {
        Register-BackupLogonTask -WorkerPath 'C:\Protected\Backup-EdgeFavorites.ps1' `
            -ConfigPath 'C:\Protected\Configuration.json'
        $task = $script:registeredTask
        $task.Name | Should -Be 'EdgeFavoritesBackupRestore-Logon'
        $task.Trigger.CimClass.CimClassName | Should -Be 'MSFT_TaskLogonTrigger'
        $task.Trigger.Delay | Should -Be 'PT120S'
        $task.Trigger.UserId | Should -BeNullOrEmpty
        $groupSid = (New-Object Security.Principal.NTAccount($task.Principal.GroupId)).
            Translate([Security.Principal.SecurityIdentifier]).Value
        $groupSid | Should -Be 'S-1-5-32-545'
        [int]$task.Principal.LogonType | Should -Be 4
        [int]$task.Principal.RunLevel | Should -Be 0
        [int]$task.Settings.MultipleInstances | Should -Be 0
        $task.Action.Arguments | Should -Not -Match 'RegisterUserTask|Restore'
        $task.Action.Arguments | Should -Match '-ConfigurationPath "C:\\Protected\\Configuration.json"'
        $task.Trigger.Repetition.Interval | Should -BeNullOrEmpty
        $task.Settings.ExecutionTimeLimit | Should -Be 'PT5M'
        $task.Settings.RestartCount | Should -Be 3
        $task.Settings.RestartInterval | Should -Be 'PT5M'
        $task.Settings.StartWhenAvailable | Should -BeTrue
        $task.Force | Should -BeTrue
        Should -Invoke Register-ScheduledTask -Times 1 -Exactly
    }

    It 'rejects junction staging paths before reading ACLs' {
        Mock Get-Item { [pscustomobject]@{ Attributes = [IO.FileAttributes]::ReparsePoint } }
        Mock Get-Acl {}
        { Assert-ProtectedBackupPath -Path 'C:\Unsafe' } | Should -Throw '*junction*'
        Should -Invoke Get-Acl -Times 0
    }

    It 'rejects existing user-writable staging paths' {
        Mock Get-Item { [pscustomobject]@{ Attributes = [IO.FileAttributes]::Directory } }
        $script:unsafeAcl = New-Object Security.AccessControl.DirectorySecurity
        $script:unsafeAcl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
        $script:unsafeAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')), 'Modify', 'Allow'
        )))
        Mock Get-Acl { $script:unsafeAcl }
        { Assert-ProtectedBackupPath -Path 'C:\Unsafe' } | Should -Throw '*non-administrator modification*'
    }
}

Describe 'Legacy user task migration' {
    BeforeAll {
        function New-TestLegacyFavoritesTask {
            param([string]$Name = 'EdgeFavoritesBackupRestore-S-1-5-21-1-2-3-1001')
            [pscustomobject]@{
                TaskName = $Name
                TaskPath = '\'
                State = 'Ready'
                Actions = @([pscustomobject]@{
                    Execute = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                    Arguments = '-NoProfile -File "C:\Protected\Backup-EdgeFavorites.ps1" -ConfigurationPath "C:\Protected\Configuration.json"'
                })
            }
        }
    }
    BeforeEach {
        $script:legacyTasks = @()
        Mock Get-ScheduledTask { $script:legacyTasks }
        Mock Stop-ScheduledTask {}
        Mock Unregister-ScheduledTask {
            $script:legacyTasks = @($script:legacyTasks | Where-Object {
                $_.TaskName -ne $TaskName -or $_.TaskPath -ne $TaskPath
            })
        }
        Mock Write-Warning {}
    }

    It 'removes 100 matching user tasks while keeping the shared task and unrelated tasks' {
        $script:legacyTasks = @(
            New-TestLegacyFavoritesTask -Name 'EdgeFavoritesBackupRestore-Logon'
            New-TestLegacyFavoritesTask -Name 'OtherTask'
            foreach ($id in 1001..1100) {
                New-TestLegacyFavoritesTask -Name "EdgeFavoritesBackupRestore-S-1-5-21-1-2-3-$id"
            }
        )
        Remove-LegacyFavoritesTasks -WorkerPath 'C:\Protected\Backup-EdgeFavorites.ps1'
        $script:legacyTasks.Count | Should -Be 2
        $script:legacyTasks.TaskName | Should -Contain 'EdgeFavoritesBackupRestore-Logon'
        $script:legacyTasks.TaskName | Should -Contain 'OtherTask'
        Should -Invoke Get-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskPath -eq '\' }
        Should -Invoke Unregister-ScheduledTask -Times 100 -Exactly -ParameterFilter {
            $TaskPath -eq '\' -and $Confirm -eq $false -and $ErrorAction -eq 'Stop'
        }
        Should -Invoke Stop-ScheduledTask -Times 0 -Exactly
    }

    It 'stops a running legacy task before removing it' {
        $task = New-TestLegacyFavoritesTask
        $task.State = 'Running'
        $script:legacyTasks = @($task)
        Mock Stop-ScheduledTask { $script:legacyTasks[0].State = 'Ready' }
        Mock Unregister-ScheduledTask { $script:legacyTasks[0].State | Should -Be 'Ready' }
        Remove-LegacyFavoritesTasks -WorkerPath 'C:\Protected\Backup-EdgeFavorites.ps1'
        Should -Invoke Stop-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $TaskName -eq 'EdgeFavoritesBackupRestore-S-1-5-21-1-2-3-1001' -and $TaskPath -eq '\'
        }
        Should -Invoke Unregister-ScheduledTask -Times 1 -Exactly
    }

    It 'does nothing on a fresh host or after migration' {
        Remove-LegacyFavoritesTasks -WorkerPath 'C:\Protected\Backup-EdgeFavorites.ps1'
        Remove-LegacyFavoritesTasks -WorkerPath 'C:\Protected\Backup-EdgeFavorites.ps1'
        Should -Invoke Unregister-ScheduledTask -Times 0 -Exactly
        Should -Invoke Stop-ScheduledTask -Times 0 -Exactly
    }

    It 'leaves other task folders and non-SID names intact' {
        $task = New-TestLegacyFavoritesTask
        $task.TaskPath = '\Other\'
        $script:legacyTasks = @($task, (New-TestLegacyFavoritesTask -Name 'EdgeFavoritesBackupRestore-Custom'))
        Remove-LegacyFavoritesTasks -WorkerPath 'C:\Protected\Backup-EdgeFavorites.ps1'
        Should -Invoke Unregister-ScheduledTask -Times 0 -Exactly
    }

    It 'warns and preserves a modified legacy action <Change>' -TestCases @(
        @{ Change = 'Worker' }, @{ Change = 'Executable' }, @{ Change = 'MultipleActions' }
    ) {
        param($Change)
        $task = New-TestLegacyFavoritesTask
        switch ($Change) {
            'Worker' { $task.Actions[0].Arguments = '-File "C:\Other\Backup-EdgeFavorites.ps1"' }
            'Executable' { $task.Actions[0].Execute = 'C:\Other\powershell.exe' }
            'MultipleActions' { $task.Actions = @($task.Actions[0], $task.Actions[0]) }
        }
        $script:legacyTasks = @($task)
        Remove-LegacyFavoritesTasks -WorkerPath 'C:\Protected\Backup-EdgeFavorites.ps1'
        Should -Invoke Unregister-ScheduledTask -Times 0 -Exactly
        Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*Review it manually*' }
    }

    It 'surfaces task enumeration failures rather than reporting a successful migration' {
        Mock Get-ScheduledTask { throw 'Cannot enumerate tasks' }
        { Remove-LegacyFavoritesTasks -WorkerPath 'C:\Protected\Backup-EdgeFavorites.ps1' } |
            Should -Throw '*Cannot enumerate tasks*'
        Should -Invoke Unregister-ScheduledTask -Times 0 -Exactly
    }

    It 'surfaces task removal failures' {
        $script:legacyTasks = @(New-TestLegacyFavoritesTask)
        Mock Unregister-ScheduledTask { throw 'Cannot remove legacy task' }
        { Remove-LegacyFavoritesTasks -WorkerPath 'C:\Protected\Backup-EdgeFavorites.ps1' } |
            Should -Throw '*Cannot remove legacy task*'
    }

    It 'does not unregister a running task when stopping it fails' {
        $task = New-TestLegacyFavoritesTask
        $task.State = 'Running'
        $script:legacyTasks = @($task)
        Mock Stop-ScheduledTask { throw 'Cannot stop legacy task' }
        { Remove-LegacyFavoritesTasks -WorkerPath 'C:\Protected\Backup-EdgeFavorites.ps1' } |
            Should -Throw '*Cannot stop legacy task*'
        Should -Invoke Unregister-ScheduledTask -Times 0 -Exactly
    }
}
