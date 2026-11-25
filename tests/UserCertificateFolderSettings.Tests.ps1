BeforeAll {
    $artifact = Join-Path (Split-Path -Parent $PSScriptRoot) 'customer-examples\artifacts\UserCertificateBackupRestore'
    Import-Module (Join-Path $artifact 'scripts\CertificateSignIn.Core.psm1') -Force
    Import-Module (Join-Path $artifact 'scripts\CertificateBackup.Core.psm1') -Force
    $moduleName = 'CertificateSignIn.Core'
    $testRoot = 'Software\FederalAVD\Tests\CertificateFolders-' + [guid]::NewGuid().ToString('N')
    $registryBase = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryView]::Registry64)
    function Get-FolderClickHandler {
        param([string]$File, [string]$Control, [string]$Member = 'Add_Click')
        $ast = [Management.Automation.Language.Parser]::ParseFile($File, [ref]$null, [ref]$null)
        $call = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
                $node.Expression.Extent.Text -eq $Control -and $node.Member.Value -eq $Member
        }, $true)
        return $call.Arguments[0].ScriptBlock.GetScriptBlock()
    }
    $restoreSave = Get-FolderClickHandler (Join-Path $artifact 'scripts\CertificateSignIn.ps1') '$save'
    $backupSave = Get-FolderClickHandler (Join-Path $artifact 'scripts\CertificateBackup.ps1') '$backupRemember'
    $restoreChanged = Get-FolderClickHandler (Join-Path $artifact 'scripts\CertificateSignIn.ps1') '$folder' 'Add_TextChanged'
    $backupChanged = Get-FolderClickHandler (Join-Path $artifact 'scripts\CertificateBackup.ps1') '$backupFolder' 'Add_TextChanged'
    function Set-RestoreStatus { param($Text, $ErrorState) }
    function Set-BackupStatus { param($Message, $Failed) }
    function Update-RestoreFolderPresentation {}
    function Update-BackupFolderPresentation {}
    $installerAst = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $artifact 'Deploy-UserCertificateBackupRestore.ps1'), [ref]$null, [ref]$null)
}

AfterAll {
    if ($null -ne $registryBase) {
        $registryBase.DeleteSubKeyTree($testRoot, $false)
        $registryBase.Dispose()
    }
    Remove-Module CertificateBackup.Core, CertificateSignIn.Core -Force
    Remove-Variable certificateFolderTest -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Certificate shared HKCU folder preference' {
    BeforeEach {
        $keyPath = "$testRoot\$([guid]::NewGuid().ToString('N'))"
        $key = $registryBase.CreateSubKey($keyPath)
        $global:certificateFolderTest = @{ LegacyPath = (Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.json')) }
        Mock Get-CertificateSettingsPath -ModuleName $moduleName { $global:certificateFolderTest.LegacyPath }
    }
    AfterEach {
        $key.Dispose()
        $registryBase.DeleteSubKeyTree($keyPath, $false)
    }

    It 'writes only InputPath as an expandable string, preserving environment references' {
        Save-CertificateSettings -InputPath '  %USERPROFILE%\CertificateBackups  ' -RegistryKey $key
        $key.GetValueKind('InputPath') | Should -Be ([Microsoft.Win32.RegistryValueKind]::ExpandString)
        Get-CertificateSettings -RegistryKey $key | Should -Be '%USERPROFILE%\CertificateBackups'
        @($key.GetValueNames()) | Should -Be @('InputPath')
        Test-Path $global:certificateFolderTest.LegacyPath | Should -BeFalse
    }

    It 'expands the remembered folder in the signed-in user context' {
        Save-CertificateSettings -InputPath '%USERPROFILE%\CertificateBackups' -RegistryKey $key
        Resolve-CertificateInputPath -SavedInputPath (Get-CertificateSettings -RegistryKey $key) `
            -DefaultInputPath 'C:\Default' | Should -Be (Join-Path $env:USERPROFILE 'CertificateBackups')
    }

    It 'preserves percent tokens through display, save and reopen without guessing profile prefixes' {
        $display = Resolve-CertificateInputPath -DefaultInputPath '%USERPROFILE%\CertificateBackups' -PreserveEnvironmentReferences
        $display | Should -Be '%USERPROFILE%\CertificateBackups'
        Save-CertificateSettings -InputPath $display -RegistryKey $key
        $settings = Get-CertificateSettings -RegistryKey $key -IncludeSource
        $settings.Source | Should -Be 'Saved'
        Resolve-CertificateInputPath -SavedInputPath $settings.InputPath -DefaultInputPath 'C:\Default' `
            -PreserveEnvironmentReferences | Should -Be '%USERPROFILE%\CertificateBackups'
        Save-CertificateSettings -InputPath (Join-Path $env:USERPROFILE 'Chosen') -RegistryKey $key
        Get-CertificateSettings -RegistryKey $key | Should -Be (Join-Path $env:USERPROFILE 'Chosen')
    }

    It 'accepts a prepopulated <Kind> preference' -TestCases @(
        @{ Kind = [Microsoft.Win32.RegistryValueKind]::String }
        @{ Kind = [Microsoft.Win32.RegistryValueKind]::ExpandString }
    ) {
        param($Kind)
        $key.SetValue('InputPath', '\\server\private\%USERNAME%', $Kind)
        Get-CertificateSettings -RegistryKey $key | Should -Be '\\server\private\%USERNAME%'
    }

    It 'retains legacy JSON fallback without rewriting it or creating HKCU defaults' {
        '{"InputPath":"C:\\Legacy"}' | Set-Content -LiteralPath $global:certificateFolderTest.LegacyPath
        Get-CertificateSettings -RegistryKey $key | Should -Be 'C:\Legacy'
        (Get-CertificateSettings -RegistryKey $key -IncludeSource).Source | Should -Be 'Legacy'
        @($key.GetValueNames()).Count | Should -Be 0
        $before = [IO.File]::ReadAllText($global:certificateFolderTest.LegacyPath)
        Save-CertificateSettings -InputPath 'C:\Chosen' -RegistryKey $key
        Get-CertificateSettings -RegistryKey $key | Should -Be 'C:\Chosen'
        [IO.File]::ReadAllText($global:certificateFolderTest.LegacyPath) | Should -Be $before
    }

    It 'ignores malformed legacy JSON when the HKCU preference exists' {
        '{invalid' | Set-Content -LiteralPath $global:certificateFolderTest.LegacyPath
        Save-CertificateSettings -InputPath 'C:\Chosen' -RegistryKey $key
        Get-CertificateSettings -RegistryKey $key | Should -Be 'C:\Chosen'
    }

    It 'returns no preference when neither registry nor legacy file supplies one' {
        Get-CertificateSettings -RegistryKey $key | Should -Be ''
        (Get-CertificateSettings -RegistryKey $key -IncludeSource).Source | Should -Be 'Default'
    }

    It 'surfaces invalid registry values instead of silently falling back' -TestCases @(
        @{ Value = ''; Kind = [Microsoft.Win32.RegistryValueKind]::String }
        @{ Value = '   '; Kind = [Microsoft.Win32.RegistryValueKind]::ExpandString }
        @{ Value = 1; Kind = [Microsoft.Win32.RegistryValueKind]::DWord }
    ) {
        param($Value, $Kind)
        $key.SetValue('InputPath', $Value, $Kind)
        { Get-CertificateSettings -RegistryKey $key } | Should -Throw '*Saved InputPath*'
    }

    It 'surfaces a registry write denial without creating a JSON fallback' {
        $readOnly = $registryBase.OpenSubKey($keyPath, $false)
        try {
            { Save-CertificateSettings -InputPath 'C:\Chosen' -RegistryKey $readOnly } | Should -Throw
            @($key.GetValueNames()).Count | Should -Be 0
            Test-Path $global:certificateFolderTest.LegacyPath | Should -BeFalse
        } finally { $readOnly.Dispose() }
    }

    It 'rejects a blank folder without changing the saved value' {
        Save-CertificateSettings -InputPath 'C:\Chosen' -RegistryKey $key
        { Save-CertificateSettings -InputPath ' ' -RegistryKey $key } | Should -Throw '*Choose a certificate folder*'
        Get-CertificateSettings -RegistryKey $key | Should -Be 'C:\Chosen'
    }

    It 'keeps managed role folders above explicit and remembered paths' {
        Save-CertificateSettings -InputPath 'C:\User' -RegistryKey $key
        $key.SetValue('RestoreFolder', 'C:\ManagedRestore', [Microsoft.Win32.RegistryValueKind]::ExpandString)
        $key.SetValue('BackupFolder', 'C:\ManagedBackup', [Microsoft.Win32.RegistryValueKind]::ExpandString)
        $policy = Get-CertificatePolicy -RegistryKey $key
        foreach ($role in @('RestoreFolder', 'BackupFolder')) {
            Resolve-CertificateInputPath -ManagedInputPath $policy.$role -InputPath 'C:\Explicit' `
                -SavedInputPath (Get-CertificateSettings -RegistryKey $key) -DefaultInputPath 'C:\Default' |
                Should -Be $policy.$role
        }
        Get-CertificateSettings -RegistryKey $key | Should -Be 'C:\User'
    }

    It 'restores remembered behavior independently when a role policy is removed' {
        Save-CertificateSettings -InputPath 'C:\User' -RegistryKey $key
        $key.SetValue('BackupFolder', 'C:\ManagedBackup', [Microsoft.Win32.RegistryValueKind]::String)
        $policy = Get-CertificatePolicy -RegistryKey $key
        Resolve-CertificateInputPath -ManagedInputPath $policy.RestoreFolder `
            -SavedInputPath (Get-CertificateSettings -RegistryKey $key) -DefaultInputPath 'C:\Default' | Should -Be 'C:\User'
        $key.DeleteValue('BackupFolder')
        $policy = Get-CertificatePolicy -RegistryKey $key
        Resolve-CertificateInputPath -ManagedInputPath $policy.BackupFolder `
            -SavedInputPath (Get-CertificateSettings -RegistryKey $key) -DefaultInputPath 'C:\Default' | Should -Be 'C:\User'
    }

    It 'retains explicit path precedence and uses the default only without a preference' {
        Resolve-CertificateInputPath -InputPath 'C:\Explicit' -SavedInputPath 'C:\Saved' `
            -DefaultInputPath 'C:\Default' | Should -Be 'C:\Explicit'
        Resolve-CertificateInputPath -SavedInputPath 'C:\Saved' -DefaultInputPath 'C:\Default' | Should -Be 'C:\Saved'
        Resolve-CertificateInputPath -DefaultInputPath 'C:\Default' | Should -Be 'C:\Default'
    }

    It 'does not bypass an invalid managed folder with a remembered user path' {
        Save-CertificateSettings -InputPath 'C:\User' -RegistryKey $key
        $key.SetValue('RestoreFolder', '', [Microsoft.Win32.RegistryValueKind]::String)
        { Get-CertificatePolicy -RegistryKey $key } | Should -Throw '*Managed RestoreFolder*'
    }

    It 'uses the intended non-policy current-user key in the production opener' {
        $module = Get-Module $moduleName
        $definition = & $module { (Get-Command Open-CertificateSettingsKey).Definition }
        $definition | Should -Match 'RegistryHive\]::CurrentUser'
        $definition | Should -Match "'Software\\CertificateSignIn'"
        $definition | Should -Not -Match 'Policies|LocalMachine'
    }
}

Describe 'Certificate OneDrive path safety' {
    BeforeEach {
        $previousOneDrive = [Environment]::GetEnvironmentVariable('OneDriveCommercial', 'Process')
        $oneDriveRoot = Join-Path $TestDrive 'Work OneDrive - Example'
        [Environment]::SetEnvironmentVariable('OneDriveCommercial', $oneDriveRoot, 'Process')
    }
    AfterEach {
        [Environment]::SetEnvironmentVariable('OneDriveCommercial', $previousOneDrive, 'Process')
    }

    It 'resolves a work OneDrive path with spaces without creating folders during resolution' {
        Resolve-CertificateInputPath -DefaultInputPath '%OneDriveCommercial%\Certificates\Backups' |
            Should -Be (Join-Path $oneDriveRoot 'Certificates\Backups')
        Test-Path -LiteralPath $oneDriveRoot | Should -BeFalse
    }

    It 'keeps the original template available for display and saving even before OneDrive is configured' {
        [Environment]::SetEnvironmentVariable('OneDriveCommercial', $null, 'Process')
        Resolve-CertificateInputPath -DefaultInputPath '%OneDriveCommercial%\Certificates' `
            -PreserveEnvironmentReferences | Should -Be '%OneDriveCommercial%\Certificates'
        { Resolve-CertificateInputPath -DefaultInputPath '%OneDriveCommercial%\Certificates' } |
            Should -Throw '*unresolved environment variable*'
    }

    It 'blocks <Operation> before unresolved paths can be used or directories created' -TestCases @(
        @{ Operation = 'Discovery' }
        @{ Operation = 'Status' }
        @{ Operation = 'NewBackup' }
        @{ Operation = 'Backup' }
    ) {
        param($Operation)
        [Environment]::SetEnvironmentVariable('OneDriveCommercial', $null, 'Process')
        $folderPath = Join-Path $TestDrive '%OneDriveCommercial%\Certificates'
        $secret = ConvertTo-SecureString 'Test-only-passphrase' -AsPlainText -Force
        $emptyCertificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new()
        try {
            $invoke = {
                switch ($Operation) {
                    Discovery { Find-NewestCertificate -InputPath $folderPath }
                    Status { Get-CertificateBackupStatus -Folder $folderPath -Certificates @() }
                    NewBackup { New-CertificateBackup -Certificates @($emptyCertificate) -Password $secret -Folder $folderPath }
                    Backup { Backup-UserCertificates -Thumbprints @('TestOnly') -Password $secret -Folder $folderPath }
                }
            }
            $invoke | Should -Throw '*unresolved environment variable*'
            Test-Path -LiteralPath $folderPath | Should -BeFalse
        } finally {
            $emptyCertificate.Dispose()
            $secret.Dispose()
        }
    }

    It 'keeps actual destination creation before staging writes in the submitted backup operation' {
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $artifact 'scripts\CertificateBackup.Core.psm1'), [ref]$null, [ref]$null)
        $backup = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-CertificateBackup'
        }, $true)
        $create = $backup.Body.Find({
            param($node)
            $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
                $node.Expression.Extent.Text -eq '[IO.Directory]' -and $node.Member.Value -eq 'CreateDirectory'
        }, $true)
        $write = $backup.Body.Find({
            param($node)
            $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
                $node.Expression.Extent.Text -eq '[IO.File]' -and $node.Member.Value -eq 'WriteAllBytes'
        }, $true)
        $create.Arguments[0].Extent.Text | Should -Be '$Folder'
        $create.Extent.StartOffset | Should -BeLessThan $write.Extent.StartOffset
    }
}

Describe 'Certificate form Remember folder integration' {
    BeforeEach {
        $folder = [pscustomobject]@{ Text = 'C:\RestoreChoice' }
        $backupFolder = [pscustomobject]@{ Text = 'C:\BackupChoice' }
        $folderManaged = $false
        $backupManaged = $false
        $Startup = $true
        $state = @{ FolderSource = 'Custom'; Candidate = $null; Verified = $false }
        $backupState = @{ FolderSource = 'Custom' }
        $selected = [pscustomobject]@{}
        $selected | Add-Member ScriptMethod Clear {}
        $password = [pscustomobject]@{}
        $password | Add-Member ScriptMethod Clear {}
        $import = [pscustomobject]@{ Enabled = $true }
        Mock Save-CertificateSettings {}
        Mock Set-CertificateStartup {}
        Mock Set-RestoreStatus {}
        Mock Set-BackupStatus {}
        Mock Update-RestoreFolderPresentation {}
        Mock Update-BackupFolderPresentation {}
    }
    It 'saves the restore form choice through the shared preference helper' {
        & $restoreSave
        Should -Invoke Save-CertificateSettings -Times 1 -Exactly -ParameterFilter { $InputPath -eq 'C:\RestoreChoice' }
        $state.FolderSource | Should -Be 'Saved'
        Should -Invoke Update-RestoreFolderPresentation -Times 1 -Exactly
    }
    It 'saves the backup form choice through the same helper' {
        & $backupSave
        Should -Invoke Save-CertificateSettings -Times 1 -Exactly -ParameterFilter { $InputPath -eq 'C:\BackupChoice' }
        $backupState.FolderSource | Should -Be 'Saved'
        Should -Invoke Update-BackupFolderPresentation -Times 1 -Exactly
    }
    It 'does not save or replace either managed folder' {
        $folderManaged = $true
        $backupManaged = $true
        & $restoreSave
        & $backupSave
        Should -Invoke Save-CertificateSettings -Times 0 -Exactly
    }
    It 'shows a preference write failure in the backup form' {
        Mock Save-CertificateSettings { throw 'write denied' }
        & $backupSave
        Should -Invoke Set-BackupStatus -Times 1 -Exactly -ParameterFilter {
            $Failed -eq $true -and $Message -like '*Could not remember folder*write denied*'
        }
        $backupState.FolderSource | Should -Be 'Custom'
    }
    It 'marks edits to either unmanaged folder as not remembered' {
        $state.FolderSource = $backupState.FolderSource = 'Saved'
        & $restoreChanged
        & $backupChanged
        $state.FolderSource | Should -Be 'Custom'
        $backupState.FolderSource | Should -Be 'Custom'
        Should -Invoke Update-RestoreFolderPresentation -Times 1 -Exactly
        Should -Invoke Update-BackupFolderPresentation -Times 1 -Exactly
    }
}

Describe 'Certificate folder source text and shortcut contracts' {
    It 'identifies <Source> folders consistently in both forms' -TestCases @(
        @{ Source = 'Managed'; Expected = 'Organization-managed'; Hint = 'locked' }
        @{ Source = 'Saved'; Expected = 'saved'; Hint = 'HKCU' }
        @{ Source = 'Legacy'; Expected = 'legacy'; Hint = 'JSON' }
        @{ Source = 'Default'; Expected = 'Default'; Hint = 'fallback' }
        @{ Source = 'Explicit'; Expected = 'Launch-supplied'; Hint = 'launch' }
        @{ Source = 'Custom'; Expected = 'not remembered'; Hint = 'Not remembered' }
    ) {
        param($Source, $Expected, $Hint)
        foreach ($role in @('Restore', 'Backup')) {
            $presentation = Get-CertificateFolderPresentation -Role $role -Source $Source
            $presentation.FolderTitle | Should -Match $Expected
            $presentation.Hint | Should -Match $Hint
            $presentation.WindowTitle | Should -Match 'User Certificate Backup & Restore'
        }
    }
    It 'offers startup-only saving for managed manual restore and no folder saving otherwise' {
        (Get-CertificateFolderPresentation -Role Restore -Source Managed).SaveText | Should -Be 'Save startup option'
        (Get-CertificateFolderPresentation -Role Restore -Source Managed -Startup).SaveText | Should -Be 'Managed folder'
        (Get-CertificateFolderPresentation -Role Backup -Source Managed).SaveText | Should -Be 'Managed folder'
        (Get-CertificateFolderPresentation -Role Backup -Source Saved).SaveText | Should -Be 'Remember folder'
    }
    It 'continues to explain explicit launch precedence after saving or editing a folder' {
        foreach ($source in @('Saved', 'Custom')) {
            (Get-CertificateFolderPresentation -Role Restore -Source $source -ExplicitInputPath).Hint |
                Should -Match 'launch path still wins'
        }
    }
    It 'builds script-based launch arguments with deferred percent tokens' {
        $arguments = Get-CertificateLaunchArguments -ScriptPath 'C:\Program Files\CertificateSignIn\CertificateSignIn.ps1'
        $arguments | Should -Match '-File "C:\\Program Files\\CertificateSignIn\\CertificateSignIn.ps1"'
        $arguments | Should -Match '-DefaultInputPath "%USERPROFILE%\\Documents\\CertificateBackups"'
        $arguments | Should -Not -Match 'CertificateSignIn.exe|-InputPath|-Startup'
        Get-CertificateLaunchArguments -ScriptPath 'C:\Program Files\CertificateSignIn\CertificateSignIn.ps1' -Startup |
            Should -Match ' -Startup '
    }
    It 'defines only the three correctly named current shortcuts and two script entry points' {
        $definition = $installerAst.Find({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$links'
        }, $true)
        $linkPath = Join-Path $TestDrive 'User Certificate Backup & Restore.lnk'
        $menuFolder = Join-Path $TestDrive 'User Certificate Backup & Restore'
        $links = & ([scriptblock]::Create($definition.Right.Extent.Text))
        @($links).Count | Should -Be 3
        $links[0].Path | Should -Be $linkPath
        $links[0].Startup | Should -BeTrue
        $links[1].Path | Should -Be (Join-Path $menuFolder 'Restore certificates.lnk')
        $links[2].Path | Should -Be (Join-Path $menuFolder 'Back up certificates.lnk')
        @($links | Where-Object Startup -eq $true).Count | Should -Be 1
        $links[1].Script | Should -Be 'CertificateSignIn.ps1'
        $links[2].Script | Should -Be 'CertificateBackup.ps1'
        @($links | Where-Object { $_.Script -like '*.exe' }).Count | Should -Be 0
    }
    It 'targets the PowerShell host and assigns script arguments in the installer' {
        $text = $installerAst.Extent.Text
        $text | Should -Match ([regex]::Escape("'System32\WindowsPowerShell\v1.0\powershell.exe'"))
        $text | Should -Match '\$shortcut.TargetPath = \$hostPath'
        $text | Should -Match '\$shortcut.Arguments = Get-CertificateLaunchArguments'
        $text | Should -Match '\$shortcut.WorkingDirectory = \$destination'
        $text | Should -Match 'assets\\'
    }
}
