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
    $backupCompleted = Get-FolderClickHandler (Join-Path $artifact 'scripts\CertificateBackup.ps1') '$backupTimer' 'Add_Tick'
    $restoreSelectionChanged = Get-FolderClickHandler (Join-Path $artifact 'scripts\CertificateSignIn.ps1') '$selected' 'Add_SelectedIndexChanged'
    $restoreImport = Get-FolderClickHandler (Join-Path $artifact 'scripts\CertificateSignIn.ps1') '$import'
    $restoreAst = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $artifact 'scripts\CertificateSignIn.ps1'), [ref]$null, [ref]$null)
    $restoreDiscovery = $restoreAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Find-SelectedCertificate'
    }, $true).Body.GetScriptBlock()
    $restoreUpdate = $restoreAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Update-SelectedCertificate'
    }, $true).Body.GetScriptBlock()
    function Set-RestoreStatus { param($Text, $ErrorState) }
    function Set-BackupStatus { param($Message, $Failed) }
    function Update-RestoreFolderPresentation {}
    function Update-BackupFolderPresentation {}
    function Refresh-BackupCatalog {}
    function Set-BackupBusy { param($Busy) }
    function Update-SelectedCertificate {}
    function Confirm-UnverifiedCertificateRestore { param([string]$Path) }
    function New-PinningTestPair {
        param([string]$Folder)
        [void][IO.Directory]::CreateDirectory($Folder)
        $path = Join-Path $Folder 'CertificateSignIn-20260101T120000000Z-00000000000000000000000000000001.pfx'
        [IO.File]::WriteAllText($path, 'Mock PFX; contains no certificate or private key.')
        [IO.File]::WriteAllText((Join-Path $Folder 'CertificateSignIn.backup.json'), '{}')
        return $path
    }
    function Write-RestoreTestManifest {
        param([string]$Path)
        $manifest = @{
            SchemaVersion = 1
            BackupFile = [IO.Path]::GetFileName($Path)
            Sha256 = Get-CertificateFileHash $Path
            CreatedUtc = '2026-01-02T00:00:00Z'
            Certificates = @(@{
                Thumbprint = ('A' * 40); IdentityId = ('B' * 64)
                Subject = 'CN=Test only'; Issuer = 'CN=Test only'
                NotBeforeUtc = '2026-01-01T00:00:00Z'; NotAfterUtc = '2027-01-01T00:00:00Z'
            })
        }
        [IO.File]::WriteAllText((Join-Path ([IO.Path]::GetDirectoryName($Path)) 'CertificateSignIn.backup.json'),
            ($manifest | ConvertTo-Json -Depth 4))
    }
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

    It 'keeps the single managed folder above explicit and remembered paths' {
        Save-CertificateSettings -InputPath 'C:\User' -RegistryKey $key
        $key.SetValue('CertificateFolder', 'C:\Managed', [Microsoft.Win32.RegistryValueKind]::ExpandString)
        $policy = Get-CertificatePolicy -RegistryKey $key
        Resolve-CertificateInputPath -ManagedInputPath $policy.CertificateFolder -InputPath 'C:\Explicit' `
            -SavedInputPath (Get-CertificateSettings -RegistryKey $key) -DefaultInputPath 'C:\Default' |
            Should -Be 'C:\Managed'
        @($policy.PSObject.Properties.Name) | Should -Not -Contain 'RestoreFolder'
        @($policy.PSObject.Properties.Name) | Should -Not -Contain 'BackupFolder'
        Get-CertificateSettings -RegistryKey $key | Should -Be 'C:\User'
    }

    It 'restores the common preference when the shared policy is removed' {
        Save-CertificateSettings -InputPath 'C:\User' -RegistryKey $key
        $key.SetValue('CertificateFolder', 'C:\Managed', [Microsoft.Win32.RegistryValueKind]::String)
        $policy = Get-CertificatePolicy -RegistryKey $key
        $policy.CertificateFolder | Should -Be 'C:\Managed'
        $key.DeleteValue('CertificateFolder')
        $policy = Get-CertificatePolicy -RegistryKey $key
        Resolve-CertificateInputPath -ManagedInputPath $policy.CertificateFolder `
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
        $key.SetValue('CertificateFolder', '', [Microsoft.Win32.RegistryValueKind]::String)
        { Get-CertificatePolicy -RegistryKey $key } | Should -Throw '*Managed CertificateFolder*'
    }

    It 'uses the intended non-policy current-user key in the production opener' {
        $module = Get-Module $moduleName
        $definition = & $module { (Get-Command Open-CertificateSettingsKey).Definition }
        $definition | Should -Match 'RegistryHive\]::CurrentUser'
        $definition | Should -Match "'Software\\UserCertificateBackupRestore'"
        $definition | Should -Not -Match 'Policies|LocalMachine'
    }
}

Describe 'Certificate redirected Documents token' {
    BeforeEach {
        $keyPath = "$testRoot\$([guid]::NewGuid().ToString('N'))"
        $key = $registryBase.CreateSubKey($keyPath)
        $previousOneDrive = [Environment]::GetEnvironmentVariable('OneDriveCommercial', 'Process')
        $workRoot = Join-Path $TestDrive 'Configured Work OneDrive'
        [void][IO.Directory]::CreateDirectory($workRoot)
        [Environment]::SetEnvironmentVariable('OneDriveCommercial', $workRoot, 'Process')
        $global:certificateFolderTest = @{ DocumentsPath = (Join-Path $workRoot 'Redirected Documents') }
        Mock Get-CertificateDocumentsFolder -ModuleName $moduleName { $global:certificateFolderTest.DocumentsPath }
        Mock Get-CertificateOneDriveRoot -ModuleName $moduleName {
            [Environment]::GetEnvironmentVariable('OneDriveCommercial', 'Process')
        }
        Mock Test-CertificateDocumentsKfmExpected -ModuleName $moduleName { $false }
    }
    AfterEach {
        $key.Dispose()
        $registryBase.DeleteSubKeyTree($keyPath, $false)
        [Environment]::SetEnvironmentVariable('OneDriveCommercial', $previousOneDrive, 'Process')
    }

    It 'keeps the token unchanged through editable display and HKCU save' {
        $display = Resolve-CertificateInputPath -DefaultInputPath '{Documents}\CertificateBackups' -PreserveEnvironmentReferences
        $display | Should -Be '{Documents}\CertificateBackups'
        Save-CertificateSettings -InputPath $display -RegistryKey $key
        Get-CertificateSettings -RegistryKey $key | Should -Be '{Documents}\CertificateBackups'
        Should -Invoke Get-CertificateDocumentsFolder -ModuleName $moduleName -Times 0 -Exactly
    }
    It 'resolves redirected Documents without creating the directory during lookup' {
        Resolve-CertificateInputPath -DefaultInputPath '{Documents}\CertificateBackups' |
            Should -Be (Join-Path $global:certificateFolderTest.DocumentsPath 'CertificateBackups')
        Test-Path -LiteralPath $global:certificateFolderTest.DocumentsPath | Should -BeFalse
    }
    It 'looks up Documents again after a redirection change rather than caching the old location' {
        Resolve-CertificateInputPath -DefaultInputPath '{Documents}\CertificateBackups' |
            Should -Be (Join-Path $global:certificateFolderTest.DocumentsPath 'CertificateBackups')
        $global:certificateFolderTest.DocumentsPath = Join-Path $TestDrive 'Different Redirected Documents'
        Resolve-CertificateInputPath -DefaultInputPath '{Documents}\CertificateBackups' |
            Should -Be (Join-Path $global:certificateFolderTest.DocumentsPath 'CertificateBackups')
        Should -Invoke Get-CertificateDocumentsFolder -ModuleName $moduleName -Times 2 -Exactly
    }
    It 'preserves explicit path precedence and does not consult Documents for a non-token path' {
        Resolve-CertificateInputPath -InputPath 'C:\Explicit' -DefaultInputPath '{Documents}\CertificateBackups' |
            Should -Be 'C:\Explicit'
        Should -Invoke Get-CertificateDocumentsFolder -ModuleName $moduleName -Times 0 -Exactly
        Should -Invoke Test-CertificateDocumentsKfmExpected -ModuleName $moduleName -Times 0 -Exactly
    }
    It 'rejects an invalid known-folder result without a profile-relative fallback' -TestCases @(
        @{ Path = '' }
        @{ Path = 'RelativeDocuments' }
        @{ Path = '%Unavailable%\Documents' }
    ) {
        param($Path)
        $global:certificateFolderTest.DocumentsPath = $Path
        { Resolve-CertificateInputPath -DefaultInputPath '{Documents}\CertificateBackups' } |
            Should -Throw '*No profile-relative fallback*'
    }
    It 'supports a Documents token alone, a drive root and a redirected UNC path' {
        $global:certificateFolderTest.DocumentsPath = 'C:\'
        Resolve-CertificateInputPath -DefaultInputPath '{Documents}' | Should -Be 'C:\'
        Resolve-CertificateInputPath -DefaultInputPath '{documents}\CertificateBackups' | Should -Be 'C:\CertificateBackups'
        $global:certificateFolderTest.DocumentsPath = '\\server\private\user\Documents'
        Resolve-CertificateInputPath -DefaultInputPath '{Documents}\CertificateBackups' |
            Should -Be '\\server\private\user\Documents\CertificateBackups'
    }
    It 'rejects misplaced or repeated application tokens' {
        { Resolve-CertificateInputPath -DefaultInputPath 'C:\Unexpected\{Documents}\Backup' } |
            Should -Throw '*must appear only at the start*'
        { Resolve-CertificateInputPath -DefaultInputPath '{Documents}\{Documents}\Backup' } |
            Should -Throw '*must appear only at the start*'
    }
    It 'resolves the shared managed folder while preserving its registry template' {
        $key.SetValue('CertificateFolder', '{Documents}\CertificateBackups', [Microsoft.Win32.RegistryValueKind]::ExpandString)
        $policy = Get-CertificatePolicy -RegistryKey $key
        $policy.CertificateFolder | Should -Be (Join-Path $global:certificateFolderTest.DocumentsPath 'CertificateBackups')
        $key.GetValue('CertificateFolder', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) |
            Should -Be '{Documents}\CertificateBackups'
    }
    It 'uses the non-creating Windows API option in the production lookup' {
        $definition = & (Get-Module $moduleName) { (Get-Command Get-CertificateDocumentsFolder).Definition }
        $definition | Should -Match 'SpecialFolder\]::MyDocuments'
        $definition | Should -Match 'SpecialFolderOption\]::DoNotVerify'
        $definition | Should -Not -Match 'SpecialFolderOption\]::Create|CreateDirectory|UserShellFolders'
    }
    It 'allows ready Documents under work OneDrive when KFM is expected' {
        Mock Test-CertificateDocumentsKfmExpected -ModuleName $moduleName { $true }
        Resolve-CertificateInputPath -DefaultInputPath '{Documents}\CertificateBackups' |
            Should -Be (Join-Path $global:certificateFolderTest.DocumentsPath 'CertificateBackups')
    }
    It 'can retry readiness after OneDrive initializes without updating the process environment' {
        Mock Test-CertificateDocumentsKfmExpected -ModuleName $moduleName { $true }
        Mock Get-CertificateOneDriveRoot -ModuleName $moduleName { $global:certificateFolderTest.WorkRoot }
        [Environment]::SetEnvironmentVariable('OneDriveCommercial', $null, 'Process')
        $global:certificateFolderTest.WorkRoot = $null
        { Resolve-CertificateInputPath -DefaultInputPath '{Documents}\CertificateBackups' } |
            Should -Throw '*Waiting for Documents redirection*'
        $global:certificateFolderTest.WorkRoot = $workRoot
        Resolve-CertificateInputPath -DefaultInputPath '{Documents}\CertificateBackups' |
            Should -Be (Join-Path $global:certificateFolderTest.DocumentsPath 'CertificateBackups')
        Should -Invoke Get-CertificateOneDriveRoot -ModuleName $moduleName -Times 2 -Exactly
    }
    It 'reads fresh user environment before inherited process environment without writing either' {
        $definition = & (Get-Module $moduleName) { (Get-Command Get-CertificateOneDriveRoot).Definition }
        $definition | Should -Match 'EnvironmentVariableTarget\]::User'
        $definition | Should -Match 'EnvironmentVariableTarget\]::Process'
        $definition.IndexOf('EnvironmentVariableTarget]::User') |
            Should -BeLessThan $definition.IndexOf('EnvironmentVariableTarget]::Process')
        $definition | Should -Not -Match 'SetEnvironmentVariable|SetValue|CreateSubKey'
    }
    It 'blocks old local Documents and similar-looking sibling roots when KFM is expected' -TestCases @(
        @{ Location = 'Local' }
        @{ Location = 'Sibling' }
    ) {
        param($Location)
        Mock Test-CertificateDocumentsKfmExpected -ModuleName $moduleName { $true }
        $global:certificateFolderTest.DocumentsPath = if ($Location -eq 'Local') {
            Join-Path $TestDrive 'Old Local Documents'
        } else { Join-Path ($workRoot + '-OtherTenant') 'Documents' }
        $pending = { Resolve-CertificateInputPath -DefaultInputPath '{Documents}\CertificateBackups' } |
            Should -Throw '*Waiting for Documents redirection*' -PassThru
        $pending.Exception.Data['CertificateKfmPending'] | Should -BeTrue
        Test-Path -LiteralPath $global:certificateFolderTest.DocumentsPath | Should -BeFalse
    }
    It 'blocks a missing or unavailable OneDrive root without creating one' -TestCases @(
        @{ Root = 'MissingVariable' }
        @{ Root = 'MissingFolder' }
    ) {
        param($Root)
        Mock Test-CertificateDocumentsKfmExpected -ModuleName $moduleName { $true }
        $value = if ($Root -eq 'MissingVariable') { $null } else { Join-Path $TestDrive 'Not Configured Work Root' }
        [Environment]::SetEnvironmentVariable('OneDriveCommercial', $value, 'Process')
        { Resolve-CertificateInputPath -DefaultInputPath '{Documents}\CertificateBackups' } |
            Should -Throw '*Waiting for Documents redirection*'
        if ($null -ne $value) { Test-Path -LiteralPath $value | Should -BeFalse }
    }
    It 'allows ordinary local Documents when Documents KFM is not expected' {
        $global:certificateFolderTest.DocumentsPath = Join-Path $TestDrive 'Local Documents'
        [Environment]::SetEnvironmentVariable('OneDriveCommercial', $null, 'Process')
        Resolve-CertificateInputPath -DefaultInputPath '{Documents}\CertificateBackups' |
            Should -Be (Join-Path $global:certificateFolderTest.DocumentsPath 'CertificateBackups')
    }
}

Describe 'Certificate effective OneDrive KFM policy scope' {
    BeforeEach {
        $keyPath = "$testRoot\$([guid]::NewGuid().ToString('N'))"
        $key = $registryBase.CreateSubKey($keyPath)
        $key.SetValue('KFMSilentOptIn', '11111111-2222-3333-4444-555555555555', [Microsoft.Win32.RegistryValueKind]::String)
    }
    AfterEach {
        $key.Dispose()
        $registryBase.DeleteSubKeyTree($keyPath, $false)
    }
    It 'determines Documents intent for <Case>' -TestCases @(
        @{ Case = 'No selectors'; Values = @{}; Expected = $true }
        @{ Case = 'Documents selected'; Values = @{ KFMSilentOptInDocuments = 1 }; Expected = $true }
        @{ Case = 'Desktop only'; Values = @{ KFMSilentOptInDesktop = 1 }; Expected = $false }
        @{ Case = 'Pictures only'; Values = @{ KFMSilentOptInPictures = 1 }; Expected = $false }
        @{ Case = 'Documents excluded'; Values = @{ KFMSilentOptInDesktop = 1; KFMSilentOptInDocuments = 0 }; Expected = $false }
        @{ Case = 'All selectors cleared'; Values = @{ KFMSilentOptInDesktop = 0; KFMSilentOptInDocuments = 0; KFMSilentOptInPictures = 0 }; Expected = $false }
    ) {
        param($Values, $Expected)
        foreach ($name in $Values.Keys) { $key.SetValue($name, $Values[$name], [Microsoft.Win32.RegistryValueKind]::DWord) }
        $actual = & (Get-Module $moduleName) { param($testKey) Test-CertificateDocumentsKfmExpected -RegistryKey $testKey } $key
        $actual | Should -Be $Expected
    }
    It 'does not infer silent KFM from sign-in, opt-out blocking, or wizard policy alone' {
        $key.DeleteValue('KFMSilentOptIn')
        $key.SetValue('SilentAccountConfig', 1)
        $key.SetValue('KFMBlockOptOut', 1)
        $key.SetValue('KFMOptInWithWizard', '11111111-2222-3333-4444-555555555555')
        (& (Get-Module $moduleName) { param($testKey) Test-CertificateDocumentsKfmExpected -RegistryKey $testKey } $key) |
            Should -BeFalse
    }
    It 'rejects malformed effective policy rather than guessing readiness' {
        $key.SetValue('KFMSilentOptInDocuments', 2, [Microsoft.Win32.RegistryValueKind]::DWord)
        { & (Get-Module $moduleName) { param($testKey) Test-CertificateDocumentsKfmExpected -RegistryKey $testKey } $key } |
            Should -Throw '*must be DWORD 0 or 1*'
        $key.DeleteValue('KFMSilentOptInDocuments')
        $key.SetValue('KFMSilentOptIn', 'not-a-tenant')
        { & (Get-Module $moduleName) { param($testKey) Test-CertificateDocumentsKfmExpected -RegistryKey $testKey } $key } |
            Should -Throw '*must contain a nonempty tenant GUID*'
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
        $selected = [pscustomobject]@{ Items = [Collections.Generic.List[string]]::new() }
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

Describe 'Certificate restore file selection' {
    BeforeEach {
        $restoreFolder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $currentPath = New-PinningTestPair $restoreFolder
        Write-RestoreTestManifest $currentPath
        $otherPath = Join-Path $restoreFolder 'External.p12'
        [IO.File]::WriteAllText($otherPath, 'Mock external bundle; not a real certificate.')
        [IO.File]::SetLastWriteTimeUtc($currentPath, [datetime]'2026-01-02T00:00:00Z')
        [IO.File]::SetLastWriteTimeUtc($otherPath, [datetime]'2026-02-01T00:00:00Z')
    }

    It 'lists PFX/P12 files only from the selected folder, newest first' {
        [IO.File]::WriteAllText((Join-Path $restoreFolder 'Staged.pending'), 'Not a published backup.')
        $nested = Join-Path $restoreFolder 'Subfolder'
        [void](New-PinningTestPair $nested)
        $files = @(Get-CertificateRestoreFiles -InputPath $restoreFolder)
        $files.Count | Should -Be 2
        $files[0].FullName | Should -Be $otherPath
        $files[1].FullName | Should -Be $currentPath
    }

    It 'uses ordinal filename ordering to resolve equal timestamps' {
        [IO.File]::SetLastWriteTimeUtc($currentPath, [IO.File]::GetLastWriteTimeUtc($otherPath))
        $files = @(Get-CertificateRestoreFiles -InputPath $restoreFolder)
        $files[0].FullName | Should -Be $currentPath
    }

    It 'defaults to the current validated complete bundle, not a newer unrelated file' {
        Find-NewestCertificate -InputPath $restoreFolder | Should -Be $currentPath
        $selection = Get-CertificateRestoreFile -Path $currentPath
        $selection.HasMatchingManifest | Should -BeTrue
        $selection.Manifest.Certificates[0].NotBeforeUtc | Should -BeOfType ([string])
    }

    It 'defaults to the newest file without a manifest but requires approval to restore it' {
        Remove-Item -LiteralPath (Join-Path $restoreFolder 'CertificateSignIn.backup.json')
        Find-NewestCertificate -InputPath $restoreFolder | Should -Be $otherPath
        { Get-CertificateRestoreFile -Path $otherPath } | Should -Throw '*Explicit approval is required*'
        (Get-CertificateRestoreFile -Path $otherPath -AllowUnverifiedFile).HasMatchingManifest | Should -BeFalse
    }

    It 'permits an explicitly approved non-current file without applying the current identity list' {
        { Get-CertificateRestoreFile -Path $otherPath } | Should -Throw '*Explicit approval is required*'
        $selection = Get-CertificateRestoreFile -Path $otherPath -AllowUnverifiedFile
        $selection.Path | Should -Be $otherPath
        $selection.HasMatchingManifest | Should -BeFalse
        $selection.Manifest | Should -BeNullOrEmpty
    }

    It 'does not bypass a current backup hash mismatch through explicit approval' {
        [IO.File]::WriteAllText($currentPath, 'Changed content.')
        { Find-NewestCertificate -InputPath $restoreFolder } | Should -Throw '*hash does not match*'
        { Get-CertificateRestoreFile -Path $currentPath -AllowUnverifiedFile } | Should -Throw '*hash does not match*'
        (Get-CertificateRestoreFile -Path $otherPath -AllowUnverifiedFile).HasMatchingManifest | Should -BeFalse
    }

    It 'allows deliberate recovery from a different file when the current bundle is missing' {
        Remove-Item -LiteralPath $currentPath
        { Find-NewestCertificate -InputPath $restoreFolder } | Should -Throw '*last validated backup is missing*'
        (Get-CertificateRestoreFile -Path $otherPath -AllowUnverifiedFile).HasMatchingManifest | Should -BeFalse
    }

    It 'does not silently ignore malformed metadata during explicit selection' {
        [IO.File]::WriteAllText((Join-Path $restoreFolder 'CertificateSignIn.backup.json'), '{"SchemaVersion":99}')
        { Get-CertificateRestoreFile -Path $otherPath -AllowUnverifiedFile } | Should -Throw '*Invalid backup manifest*'
    }

    It 'enforces the exact 32 MB limit and rejects an empty selection' -TestCases @(
        @{ Length = 0; Accepted = $false }
        @{ Length = 32MB; Accepted = $true }
        @{ Length = (32MB + 1); Accepted = $false }
    ) {
        param($Length, $Accepted)
        $stream = [IO.File]::OpenWrite($otherPath)
        try { $stream.SetLength($Length) } finally { $stream.Dispose() }
        if ($Accepted) { (Get-CertificateRestoreFile -Path $otherPath -AllowUnverifiedFile).Path | Should -Be $otherPath }
        else { { Get-CertificateRestoreFile -Path $otherPath -AllowUnverifiedFile } | Should -Throw '*nonempty and no larger than 32 MB*' }
    }

    It 'rejects unapproved import before opening the user store or inventorying keys' {
        Mock Get-CertificateFileInventory -ModuleName $moduleName {}
        $secret = ConvertTo-SecureString 'Test-only password' -AsPlainText -Force
        try {
            { Import-UserCertificate -Path $otherPath -Password $secret } | Should -Throw '*Explicit approval is required*'
            Should -Invoke Get-CertificateFileInventory -ModuleName $moduleName -Times 0 -Exactly
        } finally { $secret.Dispose() }
    }
}

Describe 'Certificate restore dropdown handlers' {
    BeforeEach {
        $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $path = New-PinningTestPair $fixture
        $files = @([IO.FileInfo]::new($path))
        $global:certificateFolderTest = @{ RestoreFiles = $files; DefaultPath = $path; ManifestBacked = $true }
        $state = @{ Candidate = $null; Files = $files; UnverifiedFile = $false; RefreshingFiles = $false; Busy = $false; Verified = $false; Worker = $null; Secret = $null }
        $folder = [pscustomobject]@{ Text = $fixture }
        $folderManaged = $false
        $expiryWarningDays = 30
        $selected = [pscustomobject]@{ Items = [Collections.Generic.List[string]]::new(); SelectedIndex = -1 }
        $password = [pscustomobject]@{ Clears = 0 }
        $password | Add-Member ScriptMethod Clear { $this.Clears++ }
        $password | Add-Member ScriptMethod Focus { return $true }
        $import = [pscustomobject]@{ Enabled = $false }
        Mock Get-CertificateRestoreFiles { $global:certificateFolderTest.RestoreFiles }
        Mock Find-NewestCertificate { $global:certificateFolderTest.DefaultPath }
        Mock Get-CertificateRestoreFile {
            [pscustomobject]@{ Path = $global:certificateFolderTest.DefaultPath; HasMatchingManifest = $global:certificateFolderTest.ManifestBacked }
        }
        Mock Get-CertificateBackupStatus { [pscustomobject]@{ Warnings = @() } }
        Mock Update-SelectedCertificate {}
        Mock Set-RestoreStatus {}
        Mock Confirm-UnverifiedCertificateRestore { return $false }
    }

    It 'populates and selects the default without firing selection processing mid-refresh' {
        & $restoreDiscovery
        $selected.Items.Count | Should -Be 1
        $selected.Items[0] | Should -Match '^\[default\].* UTC$'
        $selected.SelectedIndex | Should -Be 0
        $state.RefreshingFiles | Should -BeFalse
        Should -Invoke Update-SelectedCertificate -Times 1 -Exactly
    }

    It 'retains the file list but does not choose a fallback when default validation fails' {
        Mock Find-NewestCertificate { throw 'Mock current hash mismatch.' }
        & $restoreDiscovery
        $selected.Items.Count | Should -Be 1
        $selected.SelectedIndex | Should -Be -1
        $state.Candidate | Should -BeNullOrEmpty
        $import.Enabled | Should -BeFalse
        $state.RefreshingFiles | Should -BeFalse
        Should -Invoke Update-SelectedCertificate -Times 0 -Exactly
    }

    It 'normalizes a relative default path before matching an absolute dropdown entry' {
        $origin = [uri]([IO.Directory]::GetCurrentDirectory().TrimEnd('\') + '\')
        $relative = $origin.MakeRelativeUri([uri]$global:certificateFolderTest.DefaultPath)
        if ($relative.IsAbsoluteUri) {
            Set-ItResult -Skipped -Because 'The test file and process directory are on different drives.'
            return
        }
        $global:certificateFolderTest.DefaultPath = [uri]::UnescapeDataString($relative.ToString()).Replace('/', '\')
        & $restoreDiscovery
        $selected.SelectedIndex | Should -Be 0
        Should -Invoke Update-SelectedCertificate -Times 1 -Exactly
    }

    It 'clears the password and warns for an explicitly selected file without metadata' {
        $global:certificateFolderTest.ManifestBacked = $false
        $selected.SelectedIndex = 0
        & $restoreUpdate
        $password.Clears | Should -Be 1
        $state.UnverifiedFile | Should -BeTrue
        $state.Candidate | Should -Be $global:certificateFolderTest.DefaultPath
        $import.Enabled | Should -BeTrue
        Should -Invoke Set-RestoreStatus -Times 1 -Exactly -ParameterFilter {
            $ErrorState -eq $true -and $Text -like '*WARNING:*no matching backup manifest*'
        }
        Should -Invoke Get-CertificateBackupStatus -Times 0 -Exactly
    }

    It 'processes a user selection only when the form is not busy, verified or refreshing' -TestCases @(
        @{ Flag = 'RefreshingFiles' }
        @{ Flag = 'Busy' }
        @{ Flag = 'Verified' }
    ) {
        param($Flag)
        $state[$Flag] = $true
        & $restoreSelectionChanged
        Should -Invoke Update-SelectedCertificate -Times 0 -Exactly
        $state[$Flag] = $false
        & $restoreSelectionChanged
        Should -Invoke Update-SelectedCertificate -Times 1 -Exactly
    }

    It 'does not create an import worker or keep the password when confirmation is declined' {
        $state.UnverifiedFile = $true
        $state.Candidate = $global:certificateFolderTest.DefaultPath
        & $restoreImport
        Should -Invoke Confirm-UnverifiedCertificateRestore -Times 1 -Exactly
        $state.Worker | Should -BeNullOrEmpty
        $state.Secret | Should -BeNullOrEmpty
        $password.Clears | Should -Be 1
    }
}

Describe 'Certificate shared folder policy contracts' {
    It 'uses application-named policy files for packaging, template copy, and removal' {
        Test-Path -LiteralPath (Join-Path $artifact 'scripts\policy\UserCertificateBackupRestore.admx') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $artifact 'scripts\policy\en-US\UserCertificateBackupRestore.adml') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $artifact 'scripts\policy\CertificateSignIn.admx') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $artifact 'scripts\policy\en-US\CertificateSignIn.adml') | Should -BeFalse
        $installerAst.Extent.Text | Should -Not -Match 'CertificateSignIn\.(admx|adml)'
        foreach ($name in @('Copy-CertificatePolicyTemplates', 'Remove-CertificatePolicyTemplates')) {
            $functionName = $name
            $definition = $installerAst.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
            }, $true)
            $definition.Extent.Text | Should -Match 'UserCertificateBackupRestore.admx'
            $definition.Extent.Text | Should -Match 'en-US\\UserCertificateBackupRestore.adml'
        }
    }

    It 'publishes exactly one machine folder policy with a matching expandable textbox' {
        $admx = [xml][IO.File]::ReadAllText((Join-Path $artifact 'scripts\policy\UserCertificateBackupRestore.admx'))
        $adml = [xml][IO.File]::ReadAllText((Join-Path $artifact 'scripts\policy\en-US\UserCertificateBackupRestore.adml'))
        @($admx.policyDefinitions.policies.policy).Count | Should -Be 2
        $policy = $admx.policyDefinitions.policies.policy | Where-Object name -EQ 'SetCertificateFolder'
        $policy.class | Should -Be 'Machine'
        $policy.key | Should -Be 'Software\Policies\UserCertificateBackupRestore'
        $policy.elements.text.valueName | Should -Be 'CertificateFolder'
        $policy.elements.text.expandable | Should -Be 'true'
        $policy.elements.text.required | Should -Be 'true'
        $presentation = $adml.policyDefinitionResources.resources.presentationTable.presentation |
            Where-Object id -EQ 'CertificateFolderPresentation'
        $presentation.textBox.refId | Should -Be $policy.elements.text.id
        $presentation.textBox.defaultValue | Should -Be '{Documents}\CertificateBackups'
        $admx.policyDefinitions.revision | Should -Be $adml.policyDefinitionResources.revision
    }

    It 'aligns the policy namespace, category, registry keys, and localized explanations' {
        $admx = [xml][IO.File]::ReadAllText((Join-Path $artifact 'scripts\policy\UserCertificateBackupRestore.admx'))
        $admlText = [IO.File]::ReadAllText((Join-Path $artifact 'scripts\policy\en-US\UserCertificateBackupRestore.adml'))
        $admx.policyDefinitions.policyNamespaces.target.prefix | Should -Be 'userCertificateBackupRestore'
        $admx.policyDefinitions.policyNamespaces.target.namespace | Should -Be 'UserCertificateBackupRestore.Policies'
        $admx.policyDefinitions.categories.category.name | Should -Be 'UserCertificateBackupRestore'
        $admx.policyDefinitions.categories.category.displayName | Should -Be '$(string.UserCertificateBackupRestoreCategory)'
        foreach ($policy in $admx.policyDefinitions.policies.policy) {
            $policy.key | Should -Be 'Software\Policies\UserCertificateBackupRestore'
            $policy.parentCategory.ref | Should -Be 'UserCertificateBackupRestore'
        }
        $admlText | Should -Not -Match 'CertificateSignIn'
        $admlText | Should -Match ([regex]::Escape('HKCU\Software\UserCertificateBackupRestore\InputPath'))
        $admlText | Should -Match ([regex]::Escape('{Documents}\CertificateBackups'))
    }

    It 'uses the application identity for runtime preferences, policy reads, and per-user startup' {
        foreach ($name in @('Get-CertificateSettingsPath', 'Open-CertificateSettingsKey',
            'Get-CertificatePolicy', 'Get-CertificateStartupEnabled', 'Set-CertificateStartup')) {
            $definition = & (Get-Module $moduleName) { param($CommandName) (Get-Command $CommandName).Definition } $name
            $definition | Should -Match 'UserCertificateBackupRestore'
            $definition | Should -Not -Match "['""](?:Software\\(?:Policies\\)?)?CertificateSignIn(?:\\|['""])"
        }
        $installerAst.Extent.Text | Should -Match ([regex]::Escape("GetFolderPath('ProgramFiles')) 'UserCertificateBackupRestore'"))
        $installerAst.Extent.Text | Should -Not -Match ([regex]::Escape('Software\Policies\CertificateSignIn'))
        $installerAst.Extent.Text | Should -Not -Match "GetFolderPath\('ProgramFiles'\)\) 'CertificateSignIn'"
    }

    It 'exposes only the new managed folder parameter and wires it to both forms' {
        $parameters = @($installerAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $parameters | Should -Contain 'CertificateFolder'
        $parameters | Should -Not -Contain 'RestoreFolder'
        $parameters | Should -Not -Contain 'BackupFolder'
        foreach ($script in @('CertificateSignIn.ps1', 'CertificateBackup.ps1')) {
            $text = [IO.File]::ReadAllText((Join-Path $artifact "scripts\$script"))
            $text | Should -Match '\$folderPolicy.CertificateFolder'
            $text | Should -Not -Match '\$folderPolicy\.(RestoreFolder|BackupFolder)'
        }
    }

    It 'uses a file dropdown and a default-No warning without allowing typed arbitrary file paths' {
        $text = $restoreAst.Extent.Text
        $text | Should -Match '\$selected = \[Windows.Forms.ComboBox\]::new\(\)'
        $text | Should -Match '\$selected.DropDownStyle = ''DropDownList'''
        $text | Should -Match 'MessageBoxDefaultButton\]::Button2'
        $text | Should -Match ([regex]::Escape('AddParameter(''AllowUnverifiedFile'', $state.UnverifiedFile)'))
    }
}

Describe 'Certificate OneDrive offline pinning' {
    BeforeEach {
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $root = Join-Path $base 'Work OneDrive'
        $documents = Join-Path $root 'Documents'
        $folder = Join-Path $documents 'CertificateBackups'
        $backupPath = New-PinningTestPair $folder
        $global:certificateFolderTest = @{ Root = $root; Documents = $documents; BackupPath = $backupPath }
        Mock Get-CertificateOneDriveRoot -ModuleName $moduleName { $global:certificateFolderTest.Root }
        Mock Get-CertificateDocumentsFolder -ModuleName $moduleName { $global:certificateFolderTest.Documents }
        Mock Invoke-CertificatePinAttributes -ModuleName $moduleName {}
    }

    It 'requests only the dedicated folder, retained managed versions, new PFX and manifest, with one result' {
        $retained = Join-Path $folder 'CertificateSignIn-20251201T120000000Z-00000000000000000000000000000002.pfx'
        [IO.File]::WriteAllText($retained, 'Mock retained backup.')
        $results = @(Set-CertificateBackupOfflineAvailability -BackupPath $backupPath)
        $results.Count | Should -Be 1
        $results[0].Status | Should -Be 'Requested'
        $results[0].Scope | Should -Be 'FolderAndFiles'
        $results[0].Message | Should -Match 'does not confirm completed downloads or cloud upload'
        Should -Invoke Invoke-CertificatePinAttributes -ModuleName $moduleName -Times 4 -Exactly
        foreach ($expected in @($backupPath, (Join-Path $folder 'CertificateSignIn.backup.json'), $folder, $retained)) {
            Should -Invoke Invoke-CertificatePinAttributes -ModuleName $moduleName -Times 1 -Exactly -ParameterFilter {
                $Path -eq $expected -and $TimeoutMilliseconds -gt 0 -and $TimeoutMilliseconds -le 30000
            }
        }
    }

    It 'pins files only in <Location>, never the broad or custom folder' -TestCases @(
        @{ Location = '' }
        @{ Location = 'Documents' }
        @{ Location = 'Shared Certificates' }
    ) {
        param($Location)
        $destination = if ($Location) { Join-Path $root $Location } else { $root }
        $path = New-PinningTestPair $destination
        $result = Set-CertificateBackupOfflineAvailability -BackupPath $path
        $result.Status | Should -Be 'Requested'
        $result.Scope | Should -Be 'Files'
        Should -Invoke Invoke-CertificatePinAttributes -ModuleName $moduleName -Times 2 -Exactly
        Should -Invoke Invoke-CertificatePinAttributes -ModuleName $moduleName -Times 0 -Exactly -ParameterFilter {
            $Path -eq $destination
        }
    }

    It 'never pins a Documents root even when it is named CertificateBackups' {
        $global:certificateFolderTest.Documents = $folder
        (Set-CertificateBackupOfflineAvailability -BackupPath $backupPath).Scope | Should -Be 'Files'
        Should -Invoke Invoke-CertificatePinAttributes -ModuleName $moduleName -Times 2 -Exactly
    }

    It 'does not infer dedication from the name when <Content> is present' -TestCases @(
        @{ Content = 'an unrelated file' }
        @{ Content = 'a subdirectory' }
    ) {
        param($Content)
        if ($Content -eq 'a subdirectory') { [void][IO.Directory]::CreateDirectory((Join-Path $folder 'Other')) }
        else { [IO.File]::WriteAllText((Join-Path $folder 'Notes.txt'), 'Unrelated content.') }
        (Set-CertificateBackupOfflineAvailability -BackupPath $backupPath).Scope | Should -Be 'Files'
        Should -Invoke Invoke-CertificatePinAttributes -ModuleName $moduleName -Times 2 -Exactly
    }

    It 'skips ordinary local destinations and prefix-sibling OneDrive paths' -TestCases @(
        @{ Sibling = $false }
        @{ Sibling = $true }
    ) {
        param($Sibling)
        $destination = if ($Sibling) { $root + '-OtherTenant\CertificateBackups' } else { Join-Path $base 'LocalBackup' }
        $path = New-PinningTestPair $destination
        (Set-CertificateBackupOfflineAvailability -BackupPath $path).Status | Should -Be 'NotApplicable'
        Should -Invoke Invoke-CertificatePinAttributes -ModuleName $moduleName -Times 0 -Exactly
    }

    It 'skips UNC destinations without requesting any attributes or consulting OneDrive' {
        $result = Set-CertificateBackupOfflineAvailability -BackupPath '\\server\private\CertificateSignIn-test.pfx'
        $result.Status | Should -Be 'NotApplicable'
        $result.Message | Should -Match 'network destination'
        Should -Invoke Get-CertificateOneDriveRoot -ModuleName $moduleName -Times 0 -Exactly
        Should -Invoke Invoke-CertificatePinAttributes -ModuleName $moduleName -Times 0 -Exactly
    }

    It 'reports <Status> when the work root is <Description>' -TestCases @(
        @{ Value = $null; Status = 'NotApplicable'; Description = 'absent' }
        @{ Value = ''; Status = 'Failed'; Description = 'empty rather than initialized' }
        @{ Value = '%OneDriveCommercial%'; Status = 'Failed'; Description = 'unexpanded' }
    ) {
        param($Value, $Status, $Description)
        $global:certificateFolderTest.Root = $Value
        (Set-CertificateBackupOfflineAvailability -BackupPath $backupPath).Status | Should -Be $Status
        Should -Invoke Invoke-CertificatePinAttributes -ModuleName $moduleName -Times 0 -Exactly
    }

    It 'rejects a <LinkType> in the destination ancestry without following it' -TestCases @(
        @{ LinkType = 'Junction' }
        @{ LinkType = 'SymbolicLink' }
    ) {
        param($LinkType)
        $global:certificateFolderTest.LinkPath = $documents
        $global:certificateFolderTest.LinkType = $LinkType
        Mock Get-Item -ModuleName $moduleName -ParameterFilter {
            $LiteralPath -eq $global:certificateFolderTest.LinkPath
        } {
            [pscustomobject]@{ LinkType = $global:certificateFolderTest.LinkType; PSIsContainer = $true }
        }
        $result = Set-CertificateBackupOfflineAvailability -BackupPath $backupPath
        $result.Status | Should -Be 'Failed'
        $result.Message | Should -Match 'does not follow directory links'
        Should -Invoke Invoke-CertificatePinAttributes -ModuleName $moduleName -Times 0 -Exactly
    }

    It 'accepts a cloud reparse point without treating it as a symbolic link' {
        Mock Get-Item -ModuleName $moduleName -ParameterFilter {
            $LiteralPath -eq $global:certificateFolderTest.BackupPath
        } {
            [pscustomobject]@{ LinkType = $null; PSIsContainer = $false; Attributes = [IO.FileAttributes]::ReparsePoint }
        }
        (Set-CertificateBackupOfflineAvailability -BackupPath $backupPath).Status | Should -Be 'Requested'
        Should -Invoke Invoke-CertificatePinAttributes -ModuleName $moduleName -Times 3 -Exactly
    }

    It 'rejects a linked backup file of type <LinkType>' -TestCases @(
        @{ LinkType = 'SymbolicLink' }
        @{ LinkType = 'HardLink' }
    ) {
        param($LinkType)
        $global:certificateFolderTest.LinkType = $LinkType
        Mock Get-Item -ModuleName $moduleName -ParameterFilter {
            $LiteralPath -eq $global:certificateFolderTest.BackupPath
        } {
            [pscustomobject]@{ LinkType = $global:certificateFolderTest.LinkType; PSIsContainer = $false }
        }
        (Set-CertificateBackupOfflineAvailability -BackupPath $backupPath).Status | Should -Be 'Failed'
        Should -Invoke Invoke-CertificatePinAttributes -ModuleName $moduleName -Times 0 -Exactly
    }

    It 'requires both published files before requesting attributes' {
        Remove-Item -LiteralPath (Join-Path $folder 'CertificateSignIn.backup.json') -ErrorAction Stop
        $result = Set-CertificateBackupOfflineAvailability -BackupPath $backupPath
        $result.Status | Should -Be 'Failed'
        $result.Message | Should -Match 'does not exist'
        Should -Invoke Invoke-CertificatePinAttributes -ModuleName $moduleName -Times 0 -Exactly
    }

    It 'reports a pin failure separately and still attempts the manifest and folder' {
        Mock Invoke-CertificatePinAttributes -ModuleName $moduleName -ParameterFilter {
            $Path -eq $global:certificateFolderTest.BackupPath
        } { throw 'Mock pin request failure.' }
        $results = @(Set-CertificateBackupOfflineAvailability -BackupPath $backupPath)
        $results.Count | Should -Be 1
        $results[0].Status | Should -Be 'Failed'
        $results[0].Message | Should -Match 'Mock pin request failure'
        $results[0].Message | Should -Match 'Some pin requests may have succeeded'
        Should -Invoke Invoke-CertificatePinAttributes -ModuleName $moduleName -Times 3 -Exactly
    }

    It 'surfaces metadata failures without changing any pin attributes' {
        Mock Get-CertificateOneDriveRoot -ModuleName $moduleName { throw 'Mock registry access failure.' }
        $result = Set-CertificateBackupOfflineAvailability -BackupPath $backupPath
        $result.Status | Should -Be 'Failed'
        $result.Message | Should -Match 'Mock registry access failure'
        Should -Invoke Invoke-CertificatePinAttributes -ModuleName $moduleName -Times 0 -Exactly
    }

    It 'requests pinning only after publication and staging cleanup, outside the export failure catch' {
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $artifact 'scripts\CertificateBackup.Core.psm1'), [ref]$null, [ref]$null)
        $definition = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-CertificateBackup'
        }, $true)
        $call = $definition.Find({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Set-CertificateBackupOfflineAvailability'
        }, $true)
        $export = $definition.Body.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] }
        $call.Extent.StartOffset | Should -BeGreaterThan $export.Finally.Extent.EndOffset
        $definition.Extent.Text | Should -Match 'Backup succeeded; offline pinning failed:'
        foreach ($property in @('Path', 'Count', 'CreatedUtc', 'OfflinePinStatus', 'OfflinePinScope', 'OfflinePinMessage')) {
            $definition.Extent.Text | Should -Match ("\b$property\s*=")
        }
    }
}

Describe 'Certificate backup completion messages' {
    BeforeEach {
        $global:certificateFolderTest = @{
            Result = [pscustomobject]@{
                Path = 'C:\Mock\CertificateSignIn-test.pfx'
                Count = 2
                OfflinePinStatus = 'Requested'
                OfflinePinMessage = 'Offline pinning requested; cloud upload is not confirmed.'
            }
        }
        $worker = [pscustomobject]@{ HadErrors = $false }
        $worker | Add-Member ScriptMethod EndInvoke { param($Operation) return $global:certificateFolderTest.Result }
        $worker | Add-Member ScriptMethod Dispose {}
        $secret = [pscustomobject]@{}
        $secret | Add-Member ScriptMethod Dispose {}
        $backupState = @{ Worker = $worker; Operation = [pscustomobject]@{ IsCompleted = $true }; Secret = $secret }
        $backupStatus = [pscustomobject]@{ Text = 'Current backup catalog.' }
        $backupTimer = [pscustomobject]@{}
        $backupTimer | Add-Member ScriptMethod Stop {}
        Mock Refresh-BackupCatalog {}
        Mock Set-BackupStatus {}
        Mock Set-BackupBusy {}
    }

    It 'shows success plus the <Status> pinning outcome, without calling the backup failed' -TestCases @(
        @{ Status = 'Requested'; Warning = $false; Message = 'Offline pinning requested; cloud upload is not confirmed.' }
        @{ Status = 'NotApplicable'; Warning = $false; Message = 'Offline pinning not requested for a network destination.' }
        @{ Status = 'Failed'; Warning = $true; Message = 'Backup succeeded; offline pinning failed: Mock failure.' }
    ) {
        param($Status, $Warning, $Message)
        $global:certificateFolderTest.Result.OfflinePinStatus = $Status
        $global:certificateFolderTest.Result.OfflinePinMessage = $Message
        & $backupCompleted
        Should -Invoke Set-BackupStatus -Times 1 -Exactly -ParameterFilter {
            $Message.StartsWith('Success: 2 identities backed up and verified.') -and
                $Message.Contains($global:certificateFolderTest.Result.Path) -and
                $Message.Contains($global:certificateFolderTest.Result.OfflinePinMessage) -and
                $Failed -eq $Warning -and $Message -notlike '*Backup failed:*'
        }
        Should -Invoke Set-BackupBusy -Times 1 -Exactly -ParameterFilter { $Busy -eq $false }
        $backupState.Worker | Should -BeNullOrEmpty
        $backupState.Secret | Should -BeNullOrEmpty
    }

    It 'does not relabel a valid backup as failed when the catalog refresh fails' {
        Mock Refresh-BackupCatalog { throw 'Mock refresh failure.' }
        & $backupCompleted
        Should -Invoke Set-BackupStatus -Times 1 -Exactly -ParameterFilter {
            $Failed -eq $true -and $Message -like 'Success:*refreshing backup details failed: Mock refresh failure.*' -and
                $Message -notlike '*Backup failed:*'
        }
    }
}

Describe 'Certificate folder source text and shortcut contracts' {
    It 'uses the Documents token consistently in all default parameters and policy-template examples' {
        foreach ($relativePath in @('Deploy-UserCertificateBackupRestore.ps1', 'scripts\CertificateSignIn.ps1', 'scripts\CertificateBackup.ps1')) {
            $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $artifact $relativePath), [ref]$null, [ref]$null)
            ($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'DefaultInputPath' }).DefaultValue.Value |
                Should -Be '{Documents}\CertificateBackups'
        }
        $core = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $artifact 'scripts\CertificateSignIn.Core.psm1'), [ref]$null, [ref]$null)
        foreach ($name in @('Get-CertificateLaunchArguments', 'Get-CertificateStartupCommand', 'Set-CertificateStartup')) {
            $functionName = $name
            $definition = $core.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
            }, $true)
            ($definition.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'DefaultInputPath' }).DefaultValue.Value |
                Should -Be '{Documents}\CertificateBackups'
        }
        $adml = [xml][IO.File]::ReadAllText((Join-Path $artifact 'scripts\policy\en-US\UserCertificateBackupRestore.adml'))
        @($adml.SelectNodes('//textBox/defaultValue')).Count | Should -Be 1
        foreach ($value in $adml.SelectNodes('//textBox/defaultValue')) {
            $value.InnerText | Should -Be '{Documents}\CertificateBackups'
        }
    }

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
            $presentation.FolderTitle | Should -Match 'backup/restore folder'
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
    It 'builds script-based launch arguments with a deferred Documents token' {
        $arguments = Get-CertificateLaunchArguments -ScriptPath 'C:\Program Files\UserCertificateBackupRestore\CertificateSignIn.ps1'
        $arguments | Should -Match '-File "C:\\Program Files\\UserCertificateBackupRestore\\CertificateSignIn.ps1"'
        $arguments | Should -Match '-DefaultInputPath "\{Documents\}\\CertificateBackups"'
        $arguments | Should -Not -Match 'CertificateSignIn.exe|-InputPath|-Startup'
        Get-CertificateLaunchArguments -ScriptPath 'C:\Program Files\UserCertificateBackupRestore\CertificateSignIn.ps1' -Startup |
            Should -Match ' -Startup '
        Get-CertificateLaunchArguments -ScriptPath 'C:\Program Files\UserCertificateBackupRestore\CertificateSignIn.ps1' `
            -DefaultInputPath '%OneDriveCommercial%\CertificateBackups' |
            Should -Match '-DefaultInputPath "%OneDriveCommercial%\\CertificateBackups"'
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
