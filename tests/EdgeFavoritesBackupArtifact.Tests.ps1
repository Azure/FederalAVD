BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $artifactPath = Join-Path $repoRoot 'customer-examples\artifacts\Configure-EdgeFavoritesBackup'
    $installerPath = Join-Path $artifactPath 'Configure-EdgeFavoritesBackup.ps1'
    $workerPath = Join-Path $artifactPath 'scripts\Backup-EdgeFavorites.ps1'
    $asts = @{}
    foreach ($path in @($installerPath, $workerPath)) {
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
        foreach ($path in @($installerPath, $workerPath)) {
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
        $installer | Should -Match 'Assert-ProtectedBackupPath -Path \$workerPath'
        $installer | Should -Match 'Assert-ProtectedBackupPath -Path \$configurationPath'
        $worker | Should -Match 'must not run as SYSTEM'
    }

    It 'defaults to hourly checks, business OneDrive discovery and every persistent browser profile' {
        $parameters = $asts[$installerPath].ParamBlock.Parameters
        ($parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'BackupRoot' }).DefaultValue.SafeGetValue() |
            Should -Be ''
        ($parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'EdgeProfileName' }).DefaultValue.SafeGetValue() |
            Should -Be '*'
        ($parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'CheckIntervalMinutes' }).DefaultValue.SafeGetValue() |
            Should -Be 60
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
        $CheckIntervalMinutes = 60
        Mock Initialize-BackupDirectory { $null = New-Item -Path $Path -ItemType Directory -Force }
        Mock Assert-ProtectedBackupPath {}
        Mock Register-BackupLogonTask {
            Test-Path -LiteralPath $WorkerPath | Should -BeTrue
            Test-Path -LiteralPath (Join-Path (Split-Path $WorkerPath) 'Configuration.json') | Should -BeTrue
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
            $installed = Join-Path $env:ProgramData 'EdgeFavoritesBackup'
            $configuration = Get-Content -LiteralPath (Join-Path $installed 'Configuration.json') -Raw | ConvertFrom-Json
            $configuration.BackupRoot | Should -BeExactly $BackupRoot
            $configuration.EdgeProfileName | Should -Be 'Profile 1'
            $configuration.CheckIntervalMinutes | Should -Be 60
            Get-Content -LiteralPath (Join-Path $installed 'Backup-EdgeFavorites.ps1') -Raw |
                Should -BeExactly (Get-Content -LiteralPath $workerPath -Raw)
            Should -Invoke Register-BackupLogonTask -Times 1 -Exactly
            Should -Invoke Assert-ProtectedBackupPath -Times 2 -Exactly
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
        $destination = Join-Path $root 'EdgeFavoritesBackup\Test\Default'
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
            Test-Path -LiteralPath (Join-Path $root "EdgeFavoritesBackup\Test\$profile\Latest.html") | Should -BeTrue
        }
    }

    It 'supports selecting just one browser profile' {
        New-TestEdgeProfile -Name 'Profile 1'
        $configuration = [pscustomobject]$options.Clone()
        $configuration.EdgeProfileName = 'Profile 1'
        Invoke-ConfiguredFavoritesBackup -Configuration $configuration
        Test-Path -LiteralPath (Join-Path $root 'EdgeFavoritesBackup\Test\Profile 1\Latest.html') | Should -BeTrue
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
        $otherLatest = Join-Path $root 'EdgeFavoritesBackup\Test\Profile 1\Latest.html'
        (Get-Item -LiteralPath $otherLatest).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-25)
        { Invoke-ConfiguredFavoritesBackup -Configuration $configuration } | Should -Throw '*Default*'
        @(Get-ChildItem -LiteralPath (Join-Path $root 'EdgeFavoritesBackup\Test\Profile 1\History') -File).Count | Should -Be 2
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
        Test-Path -LiteralPath (Join-Path $root 'EdgeFavoritesBackup\Test\Profile 1\Latest.html') | Should -BeTrue
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
        Get-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'EdgeFavoritesBackup\Backup.log') -Raw |
            Should -Match 'ERROR:'
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

Describe 'Scheduled task identity, repetition and staging protection' {
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
        Register-BackupLogonTask -WorkerPath 'C:\Protected\Backup-EdgeFavorites.ps1'
        $task = $script:registeredTask
        $task.Name | Should -Be 'EdgeFavoritesBackup-Logon'
        $task.Trigger.CimClass.CimClassName | Should -Be 'MSFT_TaskLogonTrigger'
        $task.Trigger.Delay | Should -Be 'PT120S'
        $task.Trigger.UserId | Should -BeNullOrEmpty
        $groupSid = (New-Object Security.Principal.NTAccount($task.Principal.GroupId)).
            Translate([Security.Principal.SecurityIdentifier]).Value
        $groupSid | Should -Be 'S-1-5-32-545'
        [int]$task.Principal.LogonType | Should -Be 4
        [int]$task.Principal.RunLevel | Should -Be 0
        [int]$task.Settings.MultipleInstances | Should -Be 0
        $task.Action.Arguments | Should -BeLike '*-RegisterUserTask'
        $task.Force | Should -BeTrue
        Should -Invoke Register-ScheduledTask -Times 1 -Exactly
    }

    It 'registers separate limited interactive user checks, never SYSTEM or browser restore' {
        Register-UserFavoritesTask -UserId 'S-1-5-21-1-2-3-1001' -WorkerPath 'C:\Protected\Backup.ps1' `
            -ConfigPath 'C:\Protected\Configuration.json' -IntervalMinutes 60
        $task = $script:registeredTask
        $task.Name | Should -Be 'EdgeFavoritesBackup-S-1-5-21-1-2-3-1001'
        $task.Trigger.CimClass.CimClassName | Should -Be 'MSFT_TaskTimeTrigger'
        $task.Trigger.Repetition.Interval | Should -Be 'PT1H'
        $task.Trigger.Repetition.Duration | Should -BeNullOrEmpty
        $task.Principal.UserId | Should -Be 'S-1-5-21-1-2-3-1001'
        [int]$task.Principal.LogonType | Should -Be 3
        [int]$task.Principal.RunLevel | Should -Be 0
        [int]$task.Settings.MultipleInstances | Should -Be 2
        $task.Settings.ExecutionTimeLimit | Should -Be 'PT5M'
        $task.Settings.RestartCount | Should -Be 3
        $task.Settings.RestartInterval | Should -Be 'PT5M'
        $task.Settings.StartWhenAvailable | Should -BeTrue
        $task.Action.Arguments | Should -Not -Match 'Restore|RegisterUserTask'
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
