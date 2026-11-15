BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $artifactScript = Join-Path $repoRoot 'customer-examples\artifacts\Microsoft-PowerShell-7\Deploy-PowerShell7.ps1'
    $sourceText = Get-Content -LiteralPath $artifactScript -Raw
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($artifactScript, [ref]$null, [ref]$parseErrors)
    $definitions = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst]
    }, $false))
    foreach ($definition in $definitions) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $deploymentStatement = @($ast.EndBlock.Statements |
        Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })
    if ($deploymentStatement.Count -ne 1) { throw 'Expected one main deployment lifecycle.' }
    $deploymentBlock = [scriptblock]::Create($deploymentStatement[0].Extent.Text)

    # These boundaries must never reach the host's AppX store during unit tests.
    function Get-AppxPackage {
        [CmdletBinding()] param ([switch]$AllUsers, [string[]]$PackageTypeFilter)
        throw 'Unexpected real AppX discovery.'
    }
    function Get-AppxProvisionedPackage {
        [CmdletBinding()] param ([switch]$Online)
        throw 'Unexpected real provisioning discovery.'
    }
    function Remove-AppxPackage {
        [CmdletBinding()] param ([string]$Package, [switch]$AllUsers)
        throw 'Unexpected real AppX removal.'
    }
    function Remove-AppxProvisionedPackage {
        [CmdletBinding()] param ([string]$PackageName, [switch]$Online)
        throw 'Unexpected real provisioning removal.'
    }
}

Describe 'PowerShell ZIP artifact contract' {
    It 'parses and remains ASCII-only' {
        $parseErrors.Count | Should -Be 0
        @(Get-Content -LiteralPath $artifactScript | Where-Object { $_ -match '[^\x00-\x7E]' }).Count | Should -Be 0
    }

    It 'uses product-only installation metadata and paths' {
        $sourceText | Should -Not -Match 'FederalAVD'
        $sourceText | Should -Match 'Uninstall\\PowerShell7\.Zip'
    }

    It 'requires Windows PowerShell rather than uninstalling its executing pwsh host' -Skip:($PSVersionTable.PSEdition -eq 'Desktop' -and [Environment]::Is64BitProcess) {
        { Assert-DeploymentHost } | Should -Throw '*64-bit Windows PowerShell 5.1*'
    }

    It 'keeps product selection in main rather than in reusable helper bodies' {
        foreach ($definition in $definitions) {
            $definition.Name | Should -Not -Match 'PowerShell7|PowerShellManifest'
            $definition.Extent.Text | Should -Not -Match 'pwsh\.exe|Microsoft\.PowerShell|PowerShell 7'
            $definition.Extent.Text | Should -Not -Match '\$script:(InstallPath|ShortcutPath|UninstallKey|SourcePath|PackageRoot)'
        }
    }

    It 'downloads the stable x64 ZIP and preserves the prior optional integration defaults' {
        $manifest = Get-Content (Join-Path $repoRoot 'customer-examples\parameters\imageManagement\downloads.json') -Raw | ConvertFrom-Json
        $manifest.PowerShell7.GitHubFileNamePattern | Should -Be 'PowerShell-7.*-win-x64.zip'
        $manifest.PowerShell7.DestinationFileName | Should -Be 'PowerShell7.zip'
        $sourceText | Should -Not -Match 'ADD_EXPLORER|ADD_FILE_CONTEXT|ENABLE_PSREMOTING|HKCR:'
        $sourceText | Should -Match "'Path', 'Machine'"
        $sourceText | Should -Match "appxNames = @\('Microsoft.PowerShell', 'Microsoft.PowerShellPreview'\)"
        $sourceText | Should -Match 'WindowsPowerShell\\v1.0\\powershell.exe'
    }
}

Describe 'Reusable installed-application discovery' {
    BeforeEach {
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like 'Registry::*' }
        Mock Get-ChildItem {
            if ($LiteralPath -like '*Wow6432Node*') {
                [pscustomobject]@{ PSPath = 'Registry::preview'; PSChildName = '{00000000-0000-0000-0000-000000000002}' }
            }
            else {
                [pscustomobject]@{ PSPath = 'Registry::stable'; PSChildName = '{00000000-0000-0000-0000-000000000001}' }
                [pscustomobject]@{ PSPath = 'Registry::other'; PSChildName = '{00000000-0000-0000-0000-000000000003}' }
                [pscustomobject]@{ PSPath = 'Registry::zip'; PSChildName = 'PowerShell7.Zip' }
                [pscustomobject]@{ PSPath = 'Registry::bundle'; PSChildName = '{00000000-0000-0000-0000-000000000004}' }
            }
        } -ParameterFilter { $LiteralPath -like 'Registry::*' }
        Mock Get-ItemProperty {
            switch ($LiteralPath) {
                'Registry::stable' { [pscustomobject]@{ DisplayName = 'PowerShell 7-x64'; Publisher = 'Microsoft Corporation'; WindowsInstaller = 1 } }
                'Registry::preview' { [pscustomobject]@{ DisplayName = 'PowerShell 7-preview-x86'; Publisher = 'Microsoft Corporation'; WindowsInstaller = 1 } }
                'Registry::other' { [pscustomobject]@{ DisplayName = 'Example Editor'; Publisher = 'Example Corporation'; WindowsInstaller = 1 } }
                'Registry::zip' { [pscustomobject]@{ DisplayName = 'PowerShell 7 (ZIP)'; Publisher = 'Microsoft Corporation' } }
                'Registry::bundle' { [pscustomobject]@{ DisplayName = 'PowerShell 7.6.10.0-x64'; Publisher = 'Microsoft Corporation'; BundleCachePath = 'C:\Package Cache\bundle.exe'; QuietUninstallString = '"C:\Package Cache\bundle.exe" /uninstall /quiet' } }
            }
        }
    }

    It 'accepts the main script regex and publisher and finds both MSI architectures without matching ZIP registrations' {
        $applications = @(Get-InstalledApplications -Name '^PowerShell 7(?:\D|$)' -RegEx -Publisher 'Microsoft*' -WindowsInstaller)
        $applications.Count | Should -Be 2
        $applications.ProductCode | Should -Contain '{00000000-0000-0000-0000-000000000001}'
        $applications.ProductCode | Should -Contain '{00000000-0000-0000-0000-000000000002}'
    }

    It 'can discover non-MSI registrations and use wildcard name matching' {
        $applications = @(Get-InstalledApplications -Name 'PowerShell 7*' -Publisher 'Microsoft*')
        $applications.Count | Should -Be 4
        @($applications | Where-Object { -not $_.ProductCode }).Count | Should -Be 2
    }

    It 'keeps a GUID-named EXE bundle separate from the underlying MSI' {
        $bundles = @(Get-InstalledApplications -Name 'PowerShell 7*' -Publisher 'Microsoft*' |
            Where-Object BundleCachePath)
        $bundles.Count | Should -Be 1
        $bundles[0].ProductCode | Should -Be ''
        $bundles[0].WindowsInstaller | Should -BeFalse
        $bundles[0].QuietUninstallString | Should -Be '"C:\Package Cache\bundle.exe" /uninstall /quiet'
    }

    It 'supports another application and publisher without code changes' {
        $applications = @(Get-InstalledApplications -Name 'Example*' -Publisher 'Example Corporation' -WindowsInstaller)
        $applications.Count | Should -Be 1
        $applications[0].DisplayName | Should -Be 'Example Editor'
        $applications[0].Publisher | Should -Be 'Example Corporation'
    }

    It 'does not match another publisher or an adjacent major version' {
        Mock Get-ItemProperty { [pscustomobject]@{ DisplayName = 'PowerShell 70'; Publisher = 'Microsoft Corporation' } }
        @(Get-InstalledApplications -Name '^PowerShell 7(?:\D|$)' -RegEx -Publisher 'Microsoft*').Count | Should -Be 0
        Mock Get-ItemProperty { [pscustomobject]@{ DisplayName = 'PowerShell 7-x64'; Publisher = 'Example' } }
        @(Get-InstalledApplications -Name 'PowerShell 7*' -Publisher 'Microsoft*').Count | Should -Be 0
    }

    It 'propagates registry discovery errors rather than treating an unreadable product as absent' {
        Mock Get-ItemProperty { throw 'Registry access denied' }
        { Get-InstalledApplications -Name 'Example*' } | Should -Throw '*Registry access denied*'
    }
}

Describe 'Reusable AppX discovery and removal' {
    BeforeEach {
        Mock Write-Log {}
        Mock Get-AppxPackage {
            foreach ($name in @('Microsoft.PowerShell', 'Microsoft.PowerShellPreview', 'Microsoft.PowerShellSomething', 'Example.Editor')) {
                [pscustomobject]@{ Name = $name }
            }
        }
        Mock Get-AppxProvisionedPackage {
            foreach ($name in @('Microsoft.PowerShell', 'Microsoft.PowerShellPreview', 'Example.Editor')) {
                [pscustomobject]@{ DisplayName = $name }
            }
        }
    }

    It 'uses exact caller-provided identities for registered and provisioned packages' {
        $names = @('Microsoft.PowerShell', 'Microsoft.PowerShellPreview')
        @(Get-InstalledAppxPackages -Name $names).Count | Should -Be 2
        @(Get-ProvisionedAppxPackages -Name $names).Count | Should -Be 2
        @(Get-InstalledAppxPackages -Name 'Example.Editor').Count | Should -Be 1
        @(Get-ProvisionedAppxPackages -Name 'Example.Editor').Count | Should -Be 1
        Should -Invoke Get-AppxPackage -ParameterFilter { $AllUsers -and 'Bundle' -in $PackageTypeFilter -and 'Main' -in $PackageTypeFilter }
    }

    It 'removes bundles before remaining main packages and removes provisioning using the supplied identities' {
        $script:packages = @(
            [pscustomobject]@{ PackageFullName = 'example-main'; IsBundle = $false }
            [pscustomobject]@{ PackageFullName = 'example-bundle'; IsBundle = $true }
            [pscustomobject]@{ PackageFullName = 'preview-main'; IsBundle = $false }
        )
        $script:provisioned = @([pscustomobject]@{ PackageName = 'example-provisioned' })
        $script:removedPackages = @()
        Mock Get-InstalledAppxPackages { $script:packages }
        Mock Get-ProvisionedAppxPackages { $script:provisioned }
        Mock Remove-AppxPackage {
            $script:removedPackages += $Package
            if ($Package -eq 'example-bundle') {
                $script:packages = @($script:packages | Where-Object PackageFullName -NotLike 'example-*')
            }
            else {
                $script:packages = @($script:packages | Where-Object PackageFullName -ne $Package)
            }
        }
        Mock Remove-AppxProvisionedPackage { $script:provisioned = @() }
        Remove-AppxApplications -Name @('Example.Editor', 'Example.EditorPreview')
        $script:removedPackages -join ',' | Should -Be 'example-bundle,preview-main'
        Should -Invoke Get-InstalledAppxPackages -ParameterFilter { ($Name -join ',') -eq 'Example.Editor,Example.EditorPreview' }
        Should -Invoke Get-ProvisionedAppxPackages -ParameterFilter { ($Name -join ',') -eq 'Example.Editor,Example.EditorPreview' }
        Should -Invoke Remove-AppxPackage -Times 2 -Exactly -ParameterFilter { $AllUsers }
        Should -Invoke Remove-AppxProvisionedPackage -Times 1 -Exactly -ParameterFilter { $Online -and $PackageName -eq 'example-provisioned' }
    }

    It 'fails explicitly on native removal errors or surviving registrations' {
        Mock Get-InstalledAppxPackages { [pscustomobject]@{ PackageFullName = 'example-main'; IsBundle = $false } }
        Mock Remove-AppxPackage { throw 'AppX access denied' }
        { Remove-AppxApplications -Name 'Example.Editor' } | Should -Throw '*AppX access denied*'
        Mock Get-InstalledAppxPackages { @() }
        Mock Get-ProvisionedAppxPackages { [pscustomobject]@{ PackageName = 'example-provisioned' } }
        Mock Remove-AppxProvisionedPackage {}
        { Remove-AppxApplications -Name 'Example.Editor' } | Should -Throw '*registrations remain*Example.Editor*'
    }

    It 'is idempotent when neither registered nor provisioned packages exist' {
        Mock Get-InstalledAppxPackages { @() }
        Mock Get-ProvisionedAppxPackages { @() }
        Mock Remove-AppxPackage {}
        Mock Remove-AppxProvisionedPackage {}
        Remove-AppxApplications -Name 'Example.Editor'
        Should -Invoke Remove-AppxPackage -Times 0
        Should -Invoke Remove-AppxProvisionedPackage -Times 0
    }
}

Describe 'Reusable MSI removal' {
    BeforeEach {
        Mock Write-Log {}
        $applications = @(
            [pscustomobject]@{ DisplayName = 'Example Editor'; ProductCode = '{00000000-0000-0000-0000-000000000001}'; RegistryPath = 'Registry::example' }
            [pscustomobject]@{ DisplayName = 'Example Preview'; ProductCode = '{00000000-0000-0000-0000-000000000002}'; RegistryPath = 'Registry::preview' }
        )
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like 'Registry::*' }
        Mock Invoke-MsiProcess { [pscustomobject]@{ ExitCode = 0 } }
    }

    It 'removes every supplied MSI and honors caller-provided exit codes' {
        Mock Invoke-MsiProcess { [pscustomobject]@{ ExitCode = 42 } }
        Remove-MsiApplications -Applications $applications -SuccessExitCodes @(0, 42) -AllowMultiple -VerifyRemoval
        Should -Invoke Invoke-MsiProcess -Times 2 -Exactly -ParameterFilter { $ArgumentList -like '/x {*} /qn /norestart' }
    }

    It 'removes a ProductCode only once if it appears in both registry hives' {
        Remove-MsiApplications -Applications @($applications[0], $applications[0]) -AllowMultiple -VerifyRemoval
        Should -Invoke Invoke-MsiProcess -Times 1 -Exactly
    }

    It 'logs reboot-required success without rebooting' {
        Mock Invoke-MsiProcess { [pscustomobject]@{ ExitCode = 3010 } }
        Remove-MsiApplications -Applications $applications -AllowMultiple -VerifyRemoval
        Should -Invoke Write-Log -Times 2 -ParameterFilter { $Category -eq 'Warning' -and $Message -like '*reboot*' }
    }

    It 'fails on native errors and surviving registrations' {
        Mock Invoke-MsiProcess { [pscustomobject]@{ ExitCode = 1603 } }
        { Remove-MsiApplications -Applications $applications -AllowMultiple -VerifyRemoval } | Should -Throw '*exit code 1603*'
        Mock Invoke-MsiProcess { [pscustomobject]@{ ExitCode = 0 } }
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like 'Registry::*' }
        { Remove-MsiApplications -Applications $applications -AllowMultiple -VerifyRemoval } | Should -Throw '*registration remains*'
    }

    It 'rejects non-MSI input before starting an uninstaller' {
        { Remove-MsiApplications -Applications @([pscustomobject]@{ DisplayName = 'Example ZIP'; ProductCode = '' }) } |
            Should -Throw '*valid MSI ProductCode*'
        Should -Invoke Invoke-MsiProcess -Times 0
    }

    It 'does nothing when discovery returns no applications' {
        Remove-MsiApplications -Applications @()
        Should -Invoke Invoke-MsiProcess -Times 0
    }
}

Describe 'PowerShell main deployment lifecycle' {
    BeforeEach {
        $packageRoot = Join-Path $TestDrive "package-$([guid]::NewGuid())"
        $installPath = Join-Path $TestDrive "install-$([guid]::NewGuid())"
        $shortcutPath = Join-Path $TestDrive 'PowerShell 7.lnk'
        $uninstallKey = Join-Path $TestDrive 'registration'
        $directoryRoots = @('C:\Program Files\PowerShell', 'C:\Program Files (x86)\PowerShell')
        $appxNames = @('Microsoft.PowerShell', 'Microsoft.PowerShellPreview')
        $sourcePath = $artifactScript
        $SoftwareName = 'PowerShell 7'
        $SuccessExitCodes = @(0, 3010)
        $DeploymentType = 'Install'
        $stagingPath = $null
        New-Item -Path $packageRoot -ItemType Directory | Out-Null
        $payload = Join-Path $TestDrive 'payload.txt'
        Set-Content -LiteralPath $payload -Value 'test'
        Compress-Archive -LiteralPath $payload -DestinationPath (Join-Path $packageRoot 'PowerShell7.zip')
        $script:steps = @()
        Mock Write-Log {}
        Mock Test-ApplicationPayload { $script:steps += 'validate' }
        Mock Get-Process { @() }
        Mock Get-ApplicationDirectories { @() }
        Mock Get-InstalledApplications { @() }
        Mock Invoke-ApplicationProcess { throw 'Unexpected real EXE execution during a lifecycle test.' }
        Mock Remove-MsiApplications { $script:steps += 'msi' }
        Mock Remove-AppxApplications { $script:steps += 'appx' }
        Mock Invoke-RegistrationScript { $script:steps += 'manifest' }
        Mock Set-MachinePath {}
        Mock New-ApplicationShortcut {}
        Mock Register-InstalledApplication { $script:steps += 'register' }
        Mock Get-Item {
            [pscustomobject]@{ VersionInfo = [pscustomobject]@{ ProductVersion = '7.7.0' } }
        } -ParameterFilter { $LiteralPath -eq (Join-Path $installPath 'pwsh.exe') }
    }

    It 'passes software selection and validation rules to generic helpers and validates before removal' {
        & $deploymentBlock
        $script:steps -join ',' | Should -Be 'validate,msi,appx,manifest,register'
        Test-Path -LiteralPath (Join-Path $installPath 'payload.txt') | Should -BeTrue
        Should -Invoke Get-InstalledApplications -Times 1 -Exactly -ParameterFilter {
            $Name -eq '^PowerShell 7(?:\D|$)' -and $RegEx -and $Publisher -eq 'Microsoft*' -and $WindowsInstaller
        }
        Should -Invoke Get-ApplicationDirectories -Times 1 -Exactly -ParameterFilter {
            $RootPath.Count -eq 2 -and $DirectoryNamePattern -eq '^7(?:[-.].*)?$' -and
            $ExecutableName -eq 'pwsh.exe' -and $MajorVersion -eq 7 -and $Publisher -eq 'Microsoft Corporation'
        }
        Should -Invoke Remove-MsiApplications -Times 1 -Exactly -ParameterFilter {
            ($SuccessExitCodes -join ',') -eq '0,3010' -and $AllowMultiple -and $VerifyRemoval
        }
        Should -Invoke Remove-AppxApplications -Times 1 -Exactly -ParameterFilter { ($Name -join ',') -eq 'Microsoft.PowerShell,Microsoft.PowerShellPreview' }
        Should -Invoke Test-ApplicationPayload -Times 1 -Exactly -ParameterFilter {
            $ExecutableName -eq 'pwsh.exe' -and $RequiredFiles.Count -eq 7 -and
            $SignerSubjectPattern -eq '(^|, )CN=Microsoft Corporation(,|$)' -and
            $ValidationArguments -match 'PreReleaseLabel' -and $ValidationArguments -match 'Is64BitProcess'
        }
        Should -Invoke New-ApplicationShortcut -Times 1 -Exactly -ParameterFilter {
            $Path -eq $shortcutPath -and $TargetPath -eq (Join-Path $installPath 'pwsh.exe') -and
            $WorkingDirectory -eq $installPath -and $Arguments -eq '-WorkingDirectory ~'
        }
        Should -Invoke Register-InstalledApplication -Times 1 -Exactly -ParameterFilter {
            $RegistryPath -eq $uninstallKey -and $DisplayVersion -eq '7.7.0' -and
            $DisplayName -eq 'PowerShell 7 (x64, ZIP)' -and $Publisher -eq 'Microsoft Corporation' -and
            $UninstallString -like '*WindowsPowerShell\v1.0\powershell.exe*' -and $UninstallString -like '*-DeploymentType Uninstall'
        }
    }

    It 'preserves the target PATH entry during replacement but cleans other discovered directories' {
        $oldDirectory = Join-Path $TestDrive 'old-preview'
        foreach ($directory in @($installPath, $oldDirectory)) {
            New-Item -Path $directory -ItemType Directory | Out-Null
            Set-Content -LiteralPath (Join-Path $directory 'pwsh.exe') -Value 'test'
        }
        Mock Get-ApplicationDirectories { @($installPath, $oldDirectory) }
        & $deploymentBlock
        Should -Invoke Set-MachinePath -Times 1 -Exactly -ParameterFilter {
            $oldDirectory -in $RemovePaths -and $installPath -notin $RemovePaths
        }
        Should -Invoke Set-MachinePath -Times 1 -Exactly -ParameterFilter { $AddPath -eq $installPath }
    }

    Describe 'Native EXE bundle removal' {
        BeforeEach {
            $script:bundleRegistration = Join-Path $packageRoot 'bundle-registration'
            $script:bundleExecutable = Join-Path $packageRoot 'cached bundle.exe'
            New-Item -Path $script:bundleRegistration -ItemType Directory | Out-Null
            Set-Content -LiteralPath $script:bundleExecutable -Value 'test-only bundle stub'
            $script:bundleApplication = [pscustomobject]@{
                DisplayName = 'PowerShell 7.6.10.0-x64'
                WindowsInstaller = $false
                ProductCode = ''
                RegistryPath = $script:bundleRegistration
                BundleCachePath = $script:bundleExecutable
                QuietUninstallString = '"{0}" /uninstall /quiet' -f $script:bundleExecutable
            }
            Mock Get-InstalledApplications {
                if ($WindowsInstaller) {
                    $script:steps += 'rescan'
                    return @()
                }
                $script:bundleApplication
                [pscustomobject]@{ DisplayName = 'PowerShell 7-x64'; WindowsInstaller = $true; BundleCachePath = $null }
                [pscustomobject]@{ DisplayName = 'PowerShell 7 (ZIP)'; WindowsInstaller = $false; BundleCachePath = $null }
            }
            Mock Invoke-ApplicationProcess {
                $script:steps += 'bundle'
                Remove-Item -LiteralPath $script:bundleRegistration -Recurse -Force
                [pscustomobject]@{ ExitCode = 0 }
            }
        }

        It 'removes the wrapper first and rescans rather than uninstalling the wrapped MSI twice during <Action>' -ForEach @(
            @{ Action = 'Install' }
            @{ Action = 'Uninstall' }
        ) {
            $DeploymentType = $Action
            & $deploymentBlock
            $expectedSteps = if ($Action -eq 'Install') {
                'validate,bundle,rescan,msi,appx,manifest,register'
            } else {
                'bundle,rescan,msi,appx'
            }
            $script:steps -join ',' | Should -Be $expectedSteps
            Should -Invoke Invoke-ApplicationProcess -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq $script:bundleExecutable -and $ArgumentList -eq '/uninstall /quiet /norestart' -and
                    ($SuccessExitCodes -join ',') -eq '0,3010'
            }
            Should -Invoke Remove-MsiApplications -Times 1 -Exactly -ParameterFilter { $Applications.Count -eq 0 }
        }

        It 'removes a remaining standalone MSI using only a fresh post-bundle discovery result' {
            Mock Get-InstalledApplications {
                if (-not $WindowsInstaller) { return $script:bundleApplication }
                Test-Path -LiteralPath $script:bundleRegistration | Should -BeFalse
                [pscustomobject]@{
                    DisplayName = 'PowerShell 7-preview-x86'
                    ProductCode = '{00000000-0000-0000-0000-000000000005}'
                    WindowsInstaller = $true
                    RegistryPath = 'Registry::standalone'
                }
            }
            & $deploymentBlock
            Should -Invoke Remove-MsiApplications -Times 1 -Exactly -ParameterFilter {
                $Applications.Count -eq 1 -and $Applications[0].ProductCode -eq '{00000000-0000-0000-0000-000000000005}'
            }
        }

        It 'stops before MSI removal when the native bundle uninstaller fails' {
            Mock Invoke-ApplicationProcess { throw 'Native bundle failure' }
            { & $deploymentBlock } | Should -Throw '*Native bundle failure*'
            Should -Invoke Get-InstalledApplications -Times 0 -ParameterFilter { $WindowsInstaller }
            Should -Invoke Remove-MsiApplications -Times 0
            Should -Invoke Register-InstalledApplication -Times 0
        }

        It 'fails when a successful bundle exit leaves its registration behind' {
            Mock Invoke-ApplicationProcess { [pscustomobject]@{ ExitCode = 0 } }
            { & $deploymentBlock } | Should -Throw '*Bundle registration remains*'
            Should -Invoke Remove-MsiApplications -Times 0
            Should -Invoke Register-InstalledApplication -Times 0
        }

        It 'rejects a <Problem> bundle uninstaller without invoking any installer' -ForEach @(
            @{ Problem = 'missing quiet command' }
            @{ Problem = 'missing cached executable' }
            @{ Problem = 'mismatched cached executable' }
        ) {
            switch ($Problem) {
                'missing quiet command' { $script:bundleApplication.QuietUninstallString = '' }
                'missing cached executable' { Remove-Item -LiteralPath $script:bundleExecutable }
                'mismatched cached executable' { $script:bundleApplication.BundleCachePath = Join-Path $packageRoot 'different.exe' }
            }
            { & $deploymentBlock } | Should -Throw
            Should -Invoke Invoke-ApplicationProcess -Times 0
            Should -Invoke Remove-MsiApplications -Times 0
        }

        It 'logs reboot-required bundle success without rebooting or treating the bundle as MSI' {
            Mock Invoke-ApplicationProcess {
                Remove-Item -LiteralPath $script:bundleRegistration -Recurse -Force
                [pscustomobject]@{ ExitCode = 3010 }
            }
            & $deploymentBlock
            Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter {
                $Category -eq 'Warning' -and $Message -eq 'Bundle removal requires a reboot.'
            }
        }
    }

    It 'inherits destination read/execute permissions instead of retaining restricted Temp ACLs' {
        $installParent = Join-Path $TestDrive "program-files-$([guid]::NewGuid())"
        $installPath = Join-Path $installParent 'PowerShell\7'
        New-Item -Path $installParent -ItemType Directory | Out-Null
        $users = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
        $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
        $parentAcl = Get-Acl -LiteralPath $installParent
        $parentAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $users, [Security.AccessControl.FileSystemRights]::ReadAndExecute, $inheritance,
            [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
        Set-Acl -LiteralPath $installParent -AclObject $parentAcl
        $script:capturedStaging = $null
        Mock Test-ApplicationPayload {
            $script:capturedStaging = $Path
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
            $acl = Get-Acl -LiteralPath $Path
            $acl.SetAccessRuleProtection($true, $false)
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                $identity, [Security.AccessControl.FileSystemRights]::FullControl,
                [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',
                [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
            Set-Acl -LiteralPath $Path -AclObject $acl
            New-Item -Path (Join-Path $Path 'Modules\Example'), (Join-Path $Path 'empty') -ItemType Directory | Out-Null
            Set-Content -LiteralPath (Join-Path $Path 'Modules\Example\module.txt') -Value 'nested payload'
            $hiddenFile = Join-Path $Path '.hidden'
            Set-Content -LiteralPath $hiddenFile -Value 'hidden payload'
            [IO.File]::SetAttributes($hiddenFile, [IO.FileAttributes]::Hidden)
            $sourceRules = @((Get-Acl -LiteralPath $Path).GetAccessRules(
                $true, $true, [Security.Principal.SecurityIdentifier]))
            @($sourceRules | Where-Object { $_.IdentityReference.Value -eq 'S-1-5-32-545' }).Count | Should -Be 0
        }

        & $deploymentBlock

        foreach ($relativePath in @('', 'payload.txt', 'Modules', 'Modules\Example\module.txt', 'empty', '.hidden')) {
            $path = if ($relativePath) { Join-Path $installPath $relativePath } else { $installPath }
            Test-Path -LiteralPath $path | Should -BeTrue
            $acl = Get-Acl -LiteralPath $path
            $acl.AreAccessRulesProtected | Should -BeFalse
            $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) |
                Where-Object { $_.IdentityReference.Value -eq 'S-1-5-32-545' -and $_.IsInherited })
            @($rules | Where-Object {
                ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::ReadAndExecute) -eq
                    [Security.AccessControl.FileSystemRights]::ReadAndExecute
            }).Count | Should -BeGreaterThan 0
        }
        Get-Content -LiteralPath (Join-Path $installPath 'Modules\Example\module.txt') -Raw | Should -Match 'nested payload'
        Test-Path -LiteralPath $script:capturedStaging | Should -BeFalse
    }

    It 'does not register an installation when copying the staged payload fails' {
        Mock Copy-Item { throw 'Payload copy denied' } -ParameterFilter { $Destination -eq $installPath }
        { & $deploymentBlock } | Should -Throw '*Payload copy denied*'
        Should -Invoke Invoke-RegistrationScript -Times 0
        Should -Invoke Register-InstalledApplication -Times 0
    }

    It 'uninstalls without a payload and is repeatable when nothing is installed' {
        $DeploymentType = 'Uninstall'
        Remove-Item -LiteralPath (Join-Path $packageRoot 'PowerShell7.zip')
        & $deploymentBlock
        & $deploymentBlock
        Should -Invoke Test-ApplicationPayload -Times 0
        Should -Invoke Set-MachinePath -Times 2 -Exactly -ParameterFilter { $installPath -in $RemovePaths }
        Should -Invoke Register-InstalledApplication -Times 0
    }

    It 'stops removal if the caller-selected process is running' {
        Mock Get-Process { [pscustomobject]@{ ProcessName = 'pwsh'; Id = 123 } }
        { & $deploymentBlock } | Should -Throw '*PID(s): 123*'
        Should -Invoke Remove-MsiApplications -Times 0
        Should -Invoke Remove-AppxApplications -Times 0
    }

    It 'does not remove an existing installation when staged validation fails' {
        Mock Test-ApplicationPayload { throw 'Invalid signature' }
        { & $deploymentBlock } | Should -Throw '*Invalid signature*'
        Should -Invoke Remove-MsiApplications -Times 0
        Should -Invoke Register-InstalledApplication -Times 0
    }

    It 'rejects missing and ambiguous ZIP payloads before removing anything' {
        Remove-Item -LiteralPath (Join-Path $packageRoot 'PowerShell7.zip')
        { & $deploymentBlock } | Should -Throw '*found 0*'
        Set-Content (Join-Path $packageRoot 'one.zip') -Value 'test'
        Set-Content (Join-Path $packageRoot 'two.zip') -Value 'test'
        { & $deploymentBlock } | Should -Throw '*found 2*'
        Should -Invoke Remove-MsiApplications -Times 0
    }

    It 'does not mix residual customer files into the new installation' {
        New-Item -Path $installPath -ItemType Directory | Out-Null
        $customFile = Join-Path $installPath 'profile.ps1'
        Set-Content -LiteralPath $customFile -Value 'preserve'
        { & $deploymentBlock } | Should -Throw '*Residual files remain*'
        Test-Path -LiteralPath $customFile | Should -BeTrue
        Should -Invoke Register-InstalledApplication -Times 0
    }

    It 'propagates native removal and event-registration failures without reporting success' {
        Mock Remove-MsiApplications { throw 'Native removal failed' }
        { & $deploymentBlock } | Should -Throw '*Native removal failed*'
        Should -Invoke Register-InstalledApplication -Times 0
        Mock Remove-MsiApplications {}
        Mock Invoke-RegistrationScript { throw 'Event registration failed' }
        { & $deploymentBlock } | Should -Throw '*Event registration failed*'
        Should -Invoke Register-InstalledApplication -Times 0
    }

    It 'unregisters event logging before removing the recognized ZIP and only removes owned integration' {
        $DeploymentType = 'Uninstall'
        New-Item -Path $installPath -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $installPath 'pwsh.exe') -Value 'test'
        Set-Content -LiteralPath $shortcutPath -Value 'test'
        $unrelated = Join-Path $TestDrive 'unrelated.txt'
        Set-Content -LiteralPath $unrelated -Value 'preserve'
        Mock Get-ApplicationDirectories { $installPath }
        Mock Assert-SafeDirectory {}
        & $deploymentBlock
        Test-Path -LiteralPath $installPath | Should -BeFalse
        Test-Path -LiteralPath $shortcutPath | Should -BeFalse
        Test-Path -LiteralPath $unrelated | Should -BeTrue
        Should -Invoke Invoke-RegistrationScript -Times 1 -Exactly -ParameterFilter {
            $ScriptPath -like '*RegisterManifest.ps1' -and $Parameters.Unregister -and $AllowMissing
        }
    }

    It 'rejects an unsafe directory before starting native uninstallers' {
        $DeploymentType = 'Uninstall'
        Mock Get-ApplicationDirectories { 'C:\unsafe' }
        Mock Assert-SafeDirectory { throw 'reparse points' }
        { & $deploymentBlock } | Should -Throw '*reparse points*'
        Should -Invoke Remove-MsiApplications -Times 0
    }
}

Describe 'Reusable payload validation' {
    BeforeEach {
        $validationParameters = @{
            Path = 'C:\staged'
            RequiredFiles = @('editor.exe', 'runtime.dll')
            ExecutableName = 'editor.exe'
            SignerSubjectPattern = '^CN=Example Corporation$'
            ValidationArguments = '--version'
            TimeoutMs = 1000
        }
        Mock Assert-SafeDirectory {}
        Mock Test-Path { $true }
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Example Corporation' } }
        }
        $script:smokeProcess = [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Killed = $false; Timeout = 0 }
        $script:smokeProcess | Add-Member ScriptMethod WaitForExit { param($timeout) $this.Timeout = $timeout; -not $this.TimedOut }
        $script:smokeProcess | Add-Member ScriptMethod Kill { $this.Killed = $true }
        Mock Start-Process { $script:smokeProcess }
    }

    It 'validates another product using supplied files, signer, executable, arguments, and timeout' {
        Test-ApplicationPayload @validationParameters
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\staged\editor.exe' -and $ArgumentList -eq '--version'
        }
        $script:smokeProcess.Timeout | Should -Be 1000
    }

    It 'rejects missing required files before starting anything' {
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like '*runtime.dll' }
        { Test-ApplicationPayload @validationParameters } | Should -Throw '*missing*runtime.dll*'
        Should -Invoke Start-Process -Times 0
    }

    It 'rejects invalid signatures and mismatched signers' {
        Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'HashMismatch'; SignerCertificate = $null } }
        { Test-ApplicationPayload @validationParameters } | Should -Throw '*valid signature*'
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Other' } }
        }
        { Test-ApplicationPayload @validationParameters } | Should -Throw '*valid signature*'
        Should -Invoke Start-Process -Times 0
    }

    It 'propagates smoke-test failure and enforces a bounded wait' {
        $script:smokeProcess.ExitCode = 1
        { Test-ApplicationPayload @validationParameters } | Should -Throw '*smoke test failed*exit code 1*'
        $script:smokeProcess.TimedOut = $true
        { Test-ApplicationPayload @validationParameters } | Should -Throw '*timed out*'
        $script:smokeProcess.Killed | Should -BeTrue
    }

    It 'retains the process handle before waiting so Windows PowerShell can read the exit code' {
        $script:smokeProcess.ExitCode = $null
        $script:smokeProcess | Add-Member ScriptProperty Handle { $this.ExitCode = 0; [IntPtr]1 }
        { Test-ApplicationPayload @validationParameters } | Should -Not -Throw
        $script:smokeProcess.ExitCode | Should -Be 0
    }

    It 'reports an unavailable exit code explicitly rather than assuming success' {
        $script:smokeProcess.ExitCode = $null
        { Test-ApplicationPayload @validationParameters } | Should -Throw '*did not report an exit code*'
    }
}

Describe 'Reusable MSI process retries' {
    BeforeEach {
        Mock Write-Log {}
        Mock Start-Sleep {}
        Mock Start-Process {
            $process = [pscustomobject]@{ ExitCode = 1618 }
            $process | Add-Member ScriptMethod WaitForExit { param($timeout) $true }
            $process
        }
    }

    It 'bounds busy-installer retries' {
        { Invoke-MsiProcess -ArgumentList '/x {1} /qn /norestart' -Action 'Uninstall' -MaxAttempts 2 } |
            Should -Throw '*after 2 attempts with exit code 1618*'
        Should -Invoke Start-Process -Times 2 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly
    }

    It 'does not retry unrelated native errors' {
        Mock Start-Process {
            $process = [pscustomobject]@{ ExitCode = 1603 }
            $process | Add-Member ScriptMethod WaitForExit { param($timeout) $true }
            $process
        }
        (Invoke-MsiProcess -ArgumentList '/x {1} /qn /norestart' -Action 'Uninstall').ExitCode | Should -Be 1603
        Should -Invoke Start-Process -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0
    }
}

Describe 'Reusable shortcut and uninstall registration' {
    BeforeEach {
        $script:testShortcut = [pscustomobject]@{
            TargetPath = ''; WorkingDirectory = ''; Arguments = ''; Description = ''; IconLocation = ''; Saved = $false
        }
        $script:testShortcut | Add-Member ScriptMethod Save { $this.Saved = $true }
        $script:testShell = [pscustomobject]@{ Shortcut = $script:testShortcut }
        $script:testShell | Add-Member ScriptMethod CreateShortcut { param($path) $this.Shortcut }
        Mock New-Object { $script:testShell } -ParameterFilter { $ComObject -eq 'WScript.Shell' }
        Mock New-ItemProperty {}
    }

    It 'creates a shortcut from caller-provided paths and arguments' {
        $shortcut = @{
            Path = Join-Path $TestDrive 'start-menu\Editor.lnk'
            TargetPath = 'C:\Example\editor.exe'
            WorkingDirectory = 'C:\Example'
            Arguments = '--new-window'
            Description = 'Example Editor'
        }
        New-ApplicationShortcut @shortcut
        $script:testShortcut.Saved | Should -BeTrue
        $script:testShortcut.TargetPath | Should -Be $shortcut.TargetPath
        $script:testShortcut.WorkingDirectory | Should -Be $shortcut.WorkingDirectory
        $script:testShortcut.Arguments | Should -Be $shortcut.Arguments
        $script:testShortcut.Description | Should -Be $shortcut.Description
    }

    It 'registers the supplied uninstall command and metadata without knowing the product or script path' {
        $registration = @{
            RegistryPath = Join-Path $TestDrive 'uninstall-registration'
            DisplayName = 'Example Editor'
            DisplayVersion = '2.0.0'
            Publisher = 'Example Corporation'
            InstallLocation = 'C:\Example'
            DisplayIcon = 'C:\Example\editor.exe,0'
            UninstallString = '"C:\Example\remove.exe" /quiet'
        }
        Register-InstalledApplication @registration
        Should -Invoke New-ItemProperty -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'DisplayName' -and $Value -eq 'Example Editor'
        }
        Should -Invoke New-ItemProperty -Times 2 -Exactly -ParameterFilter {
            $Name -in @('UninstallString', 'QuietUninstallString') -and $Value -eq '"C:\Example\remove.exe" /quiet'
        }
    }
}

Describe 'Reusable registration script invocation' {
    It 'passes parameters to a caller-selected script' {
        $registrationScript = Join-Path $TestDrive 'Register-Example.ps1'
        Set-Content -LiteralPath $registrationScript -Value 'param([string]$Path, [switch]$Unregister) "$Path,$Unregister"'
        Invoke-RegistrationScript -ScriptPath $registrationScript -Parameters @{ Path = 'C:\Example'; Unregister = $true } |
            Should -Be 'C:\Example,True'
    }

    It 'permits an absent optional removal script but fails for a required registration script' {
        $missingScript = Join-Path $TestDrive 'missing.ps1'
        Invoke-RegistrationScript -ScriptPath $missingScript -AllowMissing
        { Invoke-RegistrationScript -ScriptPath $missingScript } | Should -Throw '*Registration script is missing*'
    }
}

Describe 'Machine PATH ordering' {
    BeforeAll {
        $pathDefinition = ($definitions | Where-Object Name -EQ 'Set-MachinePath').Extent.Text
        $readCall = "[Environment]::GetEnvironmentVariable('Path', 'Machine')"
        $writeCall = "[Environment]::SetEnvironmentVariable('Path', (`$entries -join ';'), 'Machine')"
        # Substitute only persistence boundaries; never write the test host's machine PATH.
        if (-not $pathDefinition.Contains($readCall) -or -not $pathDefinition.Contains($writeCall)) {
            throw 'Machine PATH persistence boundaries changed; update the isolated test.'
        }
        . ([scriptblock]::Create($pathDefinition.Replace($readCall, '$script:testMachinePath').
            Replace($writeCall, '$script:testMachinePath = $entries -join '';''')))
    }

    It 'prepends the new directory while preserving unrelated entries and their order' {
        $script:testMachinePath = 'C:\Windows;C:\Tools'
        Set-MachinePath -AddPath 'C:\Example'
        $script:testMachinePath | Should -BeExactly 'C:\Example;C:\Windows;C:\Tools'
    }

    It 'leaves existing equivalent entries in their original positions and spelling' {
        $script:testMachinePath = 'C:\Windows;%SystemRoot%\Example\;C:\Tools'
        $target = Join-Path $env:SystemRoot 'Example'
        $script:testMachinePath += ";$($target.ToLowerInvariant())"
        $original = $script:testMachinePath
        Set-MachinePath -AddPath $target
        $script:testMachinePath | Should -BeExactly $original
        Set-MachinePath -AddPath $target
        $script:testMachinePath | Should -BeExactly $original
    }

    It 'removes obsolete directories without moving an existing replacement entry' {
        $script:testMachinePath = 'C:\Windows;C:\Example-preview\;C:\Tools;C:\Example'
        Set-MachinePath -RemovePaths @('C:\Example-preview')
        Set-MachinePath -AddPath 'C:\Example'
        $script:testMachinePath | Should -BeExactly 'C:\Windows;C:\Tools;C:\Example'
    }

    It 'preserves removal-only behavior for uninstall' {
        $script:testMachinePath = 'C:\Windows;C:\Example\;C:\Tools;'
        Set-MachinePath -RemovePaths @('C:\Example')
        $script:testMachinePath | Should -BeExactly 'C:\Windows;C:\Tools'
    }
}

Describe 'Reusable directory and process guards' {
    BeforeEach {
        $root = Join-Path $TestDrive 'Example'
        foreach ($name in @('2', '2-preview', '3')) {
            $directory = Join-Path $root $name
            New-Item -Path $directory -ItemType Directory -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $directory 'editor.exe') -Value 'test'
        }
        Mock Get-Item {
            [pscustomobject]@{ VersionInfo = [pscustomobject]@{ FileMajorPart = 2; CompanyName = 'Example Corporation' } }
        } -ParameterFilter { $LiteralPath -like '*editor.exe' }
    }

    It 'discovers another application using the caller roots, version pattern, executable, major version, and publisher' {
        $directories = @(Get-ApplicationDirectories -RootPath @($root) -DirectoryNamePattern '^2(?:[-.].*)?$' `
            -ExecutableName 'editor.exe' -MajorVersion 2 -Publisher 'Example Corporation')
        $directories.Count | Should -Be 2
        $directories | Should -Contain (Join-Path $root '2')
        $directories | Should -Contain (Join-Path $root '2-preview')
    }

    It 'refuses a directory whose executable has an unexpected version or publisher' {
        { Get-ApplicationDirectories -RootPath @($root) -DirectoryNamePattern '^2$' `
            -ExecutableName 'editor.exe' -MajorVersion 3 -Publisher 'Example Corporation' } |
            Should -Throw '*Unrecognized executable*'
        { Get-ApplicationDirectories -RootPath @($root) -DirectoryNamePattern '^2$' `
            -ExecutableName 'editor.exe' -MajorVersion 2 -Publisher 'Other Corporation' } |
            Should -Throw '*Unrecognized executable*'
    }

    It 'blocks only the supplied process names without terminating any process' {
        Mock Get-Process {
            [pscustomobject]@{ ProcessName = 'editor'; Id = 123 }
            [pscustomobject]@{ ProcessName = 'pwsh'; Id = 456 }
        }
        { Assert-NoRunningProcesses -Name 'editor' } | Should -Throw '*PID(s): 123)*'
        Assert-NoRunningProcesses -Name 'other'
    }

    It 'rejects a reparse-point ancestor before enumerating its contents' {
        Mock Get-Item {
            [pscustomobject]@{
                Attributes = [IO.FileAttributes]::Directory
                Parent = [pscustomobject]@{ Attributes = [IO.FileAttributes]::ReparsePoint }
            }
        }
        Mock Get-ChildItem {}
        { Assert-SafeDirectory -Path $root } | Should -Throw '*reparse-point ancestor*'
        Should -Invoke Get-ChildItem -Times 0
    }
}
