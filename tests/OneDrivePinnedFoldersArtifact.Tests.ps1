BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $artifactPath = Join-Path $repoRoot 'customer-examples\artifacts\Configure-OneDrivePinnedFolders'
    $scriptPath = Join-Path $artifactPath 'Configure-OneDrivePinnedFolders.ps1'
    $source = Get-Content -LiteralPath $scriptPath -Raw
    $parseErrors = $null
    $installerAst = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)
    foreach ($definition in $installerAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst]
    }, $false)) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $generated = New-OneDriveUserScript -Folders @('jsignout', 'cspid') -WaitTimeoutSeconds 3 -RetryIntervalSeconds 1
    $userErrors = $null
    $userAst = [Management.Automation.Language.Parser]::ParseInput($generated, [ref]$null, [ref]$userErrors)
    foreach ($definition in $userAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst]
    }, $false)) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $userStatements = @($userAst.EndBlock.Statements |
        Where-Object { $_ -isnot [Management.Automation.Language.FunctionDefinitionAst] } |
        ForEach-Object { $_.Extent.Text })
    $userBody = [scriptblock]::Create($userAst.ParamBlock.Extent.Text + "`n" + ($userStatements -join "`n"))
    $registrationStart = $source.IndexOf("`$taskName = 'OneDrivePinnedFolders'")
    $registrationBody = [scriptblock]::Create($source.Substring($registrationStart))
}

Describe 'OneDrive pinned folders package and parameter transport' {
    It 'has one ASCII root script and a README, with valid installer and generated syntax' {
        @(Get-ChildItem -LiteralPath $artifactPath -Filter '*.ps1' -File).Count | Should -Be 1
        Test-Path -LiteralPath (Join-Path $artifactPath 'README.md') | Should -BeTrue
        @($parseErrors).Count | Should -Be 0
        @($userErrors).Count | Should -Be 0
        $source | Should -Not -Match '[^\x00-\x7E]'
        $generated | Should -Not -Match '[^\x00-\x7E]'
        $generated | Should -Not -Match '__FOLDERS__|__WAIT_TIMEOUT__|__RETRY_INTERVAL__|__FOLDER_VALIDATOR__|Base64|ConvertFrom-Json'
    }

    It 'accepts Folders as a string array in both installer and generated script' {
        foreach ($ast in @($installerAst, $userAst)) {
            $parameter = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Folders' }
            $parameter.StaticType | Should -Be ([string[]])
        }
        $installerFolders = $installerAst.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'Folders' }
        $installerFolders.DefaultValue | Should -BeNullOrEmpty
        $mandatory = $installerFolders.Attributes |
            Where-Object { $_.TypeName.FullName -eq 'Parameter' } |
            ForEach-Object { $_.NamedArguments } |
            Where-Object { $_.ArgumentName -eq 'Mandatory' }
        $mandatory.Argument.SafeGetValue() | Should -BeTrue
    }

    It 'round-trips arrays and timing defaults as literals, not executable substitutions' {
        $folders = @(
            "O'Brien", 'Reports\$literal; $(throw ''not code'')', ('Caf' + [char]0xE9),
            ('O' + [char]0x2019 + 'Brien'), '__FOLDER_VALIDATOR__', '__FOLDERS__', '__WAIT_TIMEOUT__', '__RETRY_INTERVAL__'
        )
        $content = New-OneDriveUserScript -Folders $folders -WaitTimeoutSeconds 45 -RetryIntervalSeconds 7
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($content, [ref]$null, [ref]$errors)
        @($errors).Count | Should -Be 0
        $defaultsOnly = [scriptblock]::Create($ast.ParamBlock.Extent.Text + @'

[pscustomobject]@{
    Folders = @($Folders)
    WaitTimeoutSeconds = $WaitTimeoutSeconds
    RetryIntervalSeconds = $RetryIntervalSeconds
}
'@)
        $settings = & $defaultsOnly
        @($settings.Folders).Count | Should -Be $folders.Count
        for ($i = 0; $i -lt $folders.Count; $i++) {
            $settings.Folders[$i] | Should -BeExactly $folders[$i]
        }
        $settings.WaitTimeoutSeconds | Should -Be 45
        $settings.RetryIntervalSeconds | Should -Be 7
        $content | Should -Match "O''Brien"
        $content | Should -Not -Match '[^\x00-\x7E]|Base64|ConvertFrom-Json'

        $override = & $defaultsOnly -Folders @('Documents\jsignout') -WaitTimeoutSeconds 12 -RetryIntervalSeconds 2
        $override.Folders[0] | Should -Be 'Documents\jsignout'
        $override.WaitTimeoutSeconds | Should -Be 12
        $override.RetryIntervalSeconds | Should -Be 2
    }

    It 'preserves a single-element array containing a nested folder' {
        $content = New-OneDriveUserScript -Folders @('Documents\jsignout') -WaitTimeoutSeconds 10 -RetryIntervalSeconds 1
        $ast = [Management.Automation.Language.Parser]::ParseInput($content, [ref]$null, [ref]$null)
        $parameter = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Folders' }
        $defaults = @($parameter.DefaultValue.SafeGetValue())
        $defaults.Count | Should -Be 1
        $defaults[0] | Should -Be 'Documents\jsignout'
        $content | Should -Match ([regex]::Escape("[string[]]`$Folders = @('Documents\jsignout')"))
    }

    It 'rejects unsafe relative folder <Path>' -TestCases @(
        @{ Path = '' }, @{ Path = '..' }, @{ Path = '..\outside' },
        @{ Path = 'C:\outside' }, @{ Path = '\\server\share' }, @{ Path = '\rooted' },
        @{ Path = 'folder\..\outside' }, @{ Path = 'folder\*' }, @{ Path = 'file:stream' },
        @{ Path = 'folder\\child' }, @{ Path = 'folder.' }
    ) {
        param($Path)
        { Assert-RelativeFolders -Paths @($Path) } | Should -Throw
    }

    It 'accepts nested relative paths but rejects an empty folder list' {
        { Assert-RelativeFolders -Paths @('Shared Documents\Reports', 'Folder [1]') } | Should -Not -Throw
        { Assert-RelativeFolders -Paths @() } | Should -Throw '*at least one*'
    }
}

Describe 'OneDrive discovery and bounded readiness polling' {
    BeforeEach {
        $savedOneDrive = $env:OneDriveCommercial
        $env:OneDriveCommercial = 'C:\OneDrive - Example'
        Mock Test-Path { $false }
        Mock Get-ItemProperty { [pscustomobject]@{ UserFolder = 'C:\Registry OneDrive' } }
        $script:clock = [datetime]'2026-01-01T00:00:00'
        Mock Get-Date { $script:clock }
        Mock Start-Sleep { $script:clock = $script:clock.AddSeconds($Seconds) }
        $WaitTimeoutSeconds = 3
        $RetryIntervalSeconds = 1
    }
    AfterEach { $env:OneDriveCommercial = $savedOneDrive }

    It 'uses the current user environment root when available' {
        Mock Test-Path { $LiteralPath -eq 'C:\OneDrive - Example' }
        Get-OneDriveRoot | Should -Be 'C:\OneDrive - Example'
        Should -Invoke Get-ItemProperty -Times 0
    }

    It 'uses the Business1 registry fallback when the environment is not ready' {
        $env:OneDriveCommercial = ''
        Mock Test-Path { $LiteralPath -in @('HKCU:\Software\Microsoft\OneDrive\Accounts\Business1', 'C:\Registry OneDrive') }
        Get-OneDriveRoot | Should -Be 'C:\Registry OneDrive'
    }

    It 'falls back to the registry when the environment root no longer exists' {
        Mock Test-Path { $LiteralPath -in @('HKCU:\Software\Microsoft\OneDrive\Accounts\Business1', 'C:\Registry OneDrive') }
        Get-OneDriveRoot | Should -Be 'C:\Registry OneDrive'
    }

    It 'retries discovery until a delayed root appears' {
        $script:attempts = 0
        $resolved = Wait-ForUserPath -Description 'OneDrive' -Resolve {
            $script:attempts++
            if ($script:attempts -eq 3) { 'C:\Ready' }
        }
        $resolved | Should -Be 'C:\Ready'
        Should -Invoke Start-Sleep -Times 2 -Exactly
    }

    It 'fails explicitly at the deadline without real sleeping' {
        { Wait-ForUserPath -Description 'missing folder' -Resolve { $null } } |
            Should -Throw '*Timed out after 3 seconds*missing folder*'
        Should -Invoke Start-Sleep -Times 3 -Exactly
    }

    It 'surfaces registry read failures instead of treating them as absent configuration' {
        $env:OneDriveCommercial = ''
        Mock Test-Path { $true }
        Mock Get-ItemProperty { throw 'Registry access denied' }
        { Get-OneDriveRoot } | Should -Throw '*Registry access denied*'
    }
}

Describe 'Generated user script behavior without touching OneDrive' {
    BeforeEach {
        $savedTemp = $env:TEMP
        $env:TEMP = $TestDrive
        Mock New-Item {}
        Mock Add-Content {}
        Mock Get-OneDriveRoot { 'C:\OneDrive - Example' }
        Mock Test-Path { $true }
        Mock Get-ChildItem { [pscustomobject]@{ Name = 'existing.txt' } }
        Mock Invoke-PinAttributes {}
    }
    AfterEach { $env:TEMP = $savedTemp }

    It 'writes runtime logs directly in the current user temp directory' {
        & $userBody
        Should -Invoke Add-Content -Times 4 -Exactly -ParameterFilter {
            $LiteralPath -eq (Join-Path $env:TEMP 'OneDrivePinnedFolders.log')
        }
        Should -Invoke New-Item -Times 1 -Exactly -ParameterFilter {
            $Path -eq $env:TEMP -and $ItemType -eq 'Directory'
        }
    }

    It 'pins each configured folder and its descendants separately' {
        & $userBody
        Should -Invoke Invoke-PinAttributes -Times 4 -Exactly
        Should -Invoke Invoke-PinAttributes -Times 1 -Exactly -ParameterFilter {
            $Path -eq 'C:\OneDrive - Example\jsignout' -and -not $Recurse
        }
        Should -Invoke Invoke-PinAttributes -Times 1 -Exactly -ParameterFilter {
            $Path -eq 'C:\OneDrive - Example\cspid\*' -and $Recurse
        }
    }

    It 'accepts a user-context array override and skips wildcard calls for empty folders' {
        Mock Get-ChildItem { @() }
        & $userBody -Folders @('Shared Documents\Reports')
        Should -Invoke Invoke-PinAttributes -Times 1 -Exactly -ParameterFilter {
            $Path -eq 'C:\OneDrive - Example\Shared Documents\Reports' -and -not $Recurse
        }
    }

    It 'pins nested Documents folders and their descendants relative to the OneDrive root' {
        & $userBody -Folders @('Documents\jsignout', 'Documents\cspid')
        Should -Invoke Invoke-PinAttributes -Times 4 -Exactly
        Should -Invoke Invoke-PinAttributes -Times 1 -Exactly -ParameterFilter {
            $Path -eq 'C:\OneDrive - Example\Documents\jsignout' -and -not $Recurse
        }
        Should -Invoke Invoke-PinAttributes -Times 1 -Exactly -ParameterFilter {
            $Path -eq 'C:\OneDrive - Example\Documents\jsignout\*' -and $Recurse
        }
        Should -Invoke Invoke-PinAttributes -Times 1 -Exactly -ParameterFilter {
            $Path -eq 'C:\OneDrive - Example\Documents\cspid' -and -not $Recurse
        }
        Should -Invoke Invoke-PinAttributes -Times 1 -Exactly -ParameterFilter {
            $Path -eq 'C:\OneDrive - Example\Documents\cspid\*' -and $Recurse
        }
    }

    It 'logs attribute failures and fails the run' {
        Mock Invoke-PinAttributes { throw 'attrib access denied' }
        { & $userBody } | Should -Throw '*attrib access denied*'
        Should -Invoke Add-Content -Times 1 -Exactly -ParameterFilter {
            $Value -like '*ERROR:*attrib access denied*' -and
            $LiteralPath -eq (Join-Path $env:TEMP 'OneDrivePinnedFolders.log')
        }
    }

    It 'rejects invalid runtime overrides before pinning any files' {
        { & $userBody -Folders @('..\outside') } | Should -Throw
        Should -Invoke Invoke-PinAttributes -Times 0
    }

    It 'returns a failed Windows PowerShell process exit code for scheduler retries' {
        $testScript = Join-Path $TestDrive 'FailedPinning.ps1'
        [IO.File]::WriteAllText($testScript, $generated)
        $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $process = Start-Process -FilePath $powerShellPath `
            -ArgumentList ('-NoLogo -NoProfile -NonInteractive -File "{0}" -Folders ..\Rejected-OneDrive-Test' -f $testScript) `
            -RedirectStandardError (Join-Path $TestDrive 'failure.stderr') `
            -RedirectStandardOutput (Join-Path $TestDrive 'failure.stdout') `
            -WindowStyle Hidden -Wait -PassThru
        try {
            $process.ExitCode | Should -Be 1
            Get-Content -LiteralPath (Join-Path $env:TEMP 'OneDrivePinnedFolders.log') -Raw |
                Should -Match 'ERROR:.*invalid relative path'
        }
        finally {
            $process.Dispose()
        }
    }

    It 'requires a user temp location' {
        $env:TEMP = ''
        { & $userBody } | Should -Throw '*TEMP is required*'
        Should -Invoke Invoke-PinAttributes -Times 0
    }
}

Describe 'Native attribute command boundary' {
    BeforeAll {
        function Invoke-TestAttributeCommand { throw 'Attribute command was not mocked.' }
    }
    BeforeEach {
        $savedExitCode = $global:LASTEXITCODE
        Mock Join-Path { 'Invoke-TestAttributeCommand' }
        Mock Invoke-TestAttributeCommand { $global:LASTEXITCODE = 0 }
    }
    AfterEach { $global:LASTEXITCODE = $savedExitCode }

    It 'passes folder paths as literal arguments with the requested attributes' {
        Invoke-PinAttributes -Path "C:\OneDrive - Example\O'Brien"
        Should -Invoke Invoke-TestAttributeCommand -Times 1 -Exactly -ParameterFilter {
            $args.Count -eq 3 -and $args[0] -eq '+p' -and $args[1] -eq '-u' -and
            $args[2] -eq "C:\OneDrive - Example\O'Brien"
        }
        Should -Invoke Join-Path -Times 1 -Exactly -ParameterFilter {
            $Path -eq $env:SystemRoot -and $ChildPath -eq 'System32\attrib.exe'
        }
    }

    It 'adds recursion switches only when requested' {
        Invoke-PinAttributes -Path 'C:\OneDrive - Example\Reports\*' -Recurse
        Should -Invoke Invoke-TestAttributeCommand -Times 1 -Exactly -ParameterFilter {
            $args.Count -eq 5 -and $args[2] -eq 'C:\OneDrive - Example\Reports\*' -and
            $args[3] -eq '/s' -and $args[4] -eq '/d'
        }
    }

    It 'turns nonzero native exit codes into explicit errors' {
        Mock Invoke-TestAttributeCommand { $global:LASTEXITCODE = 5; 'Access denied' }
        { Invoke-PinAttributes -Path 'C:\OneDrive - Example\Reports' } |
            Should -Throw '*attrib failed*exit 5*Access denied*'
    }
}

Describe 'Protected staging and user-context scheduled task registration' {
    BeforeEach {
        $script:safeAcl = New-Object Security.AccessControl.DirectorySecurity
        $script:safeAcl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')), 'ReadAndExecute', 'Allow'
        )
        $script:safeAcl.AddAccessRule($rule)
        Mock Get-Item { [pscustomobject]@{ Attributes = [IO.FileAttributes]::Directory } }
        Mock Get-Acl { $script:safeAcl }
        Mock Test-Path { $true }
        Mock New-Item {}
        $script:registeredTask = $null
        Mock Register-ScheduledTask {
            $script:registeredTask = [pscustomobject]@{
                TaskName = $TaskName
                TaskPath = $TaskPath
                Action = $Action
                Trigger = $Trigger
                Principal = $Principal
                Settings = $Settings
                Force = $Force
            }
        }
        Mock Get-ItemProperty { [pscustomobject]@{} }
        Mock Remove-ItemProperty {}
        Mock Set-Acl {}
        Mock Write-Output {}
        $scriptPath = 'C:\ProgramData\Scripts\Pin-OneDriveFolders.ps1'
        $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $actionArguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $scriptPath
    }

    It 'accepts administrator-owned read-only staging and preserves existing directory ACLs' {
        { Initialize-ScriptDirectory -Path 'C:\ProgramData\Scripts' } | Should -Not -Throw
        Should -Invoke Set-Acl -Times 0
        Should -Invoke New-Item -Times 0
    }

    It 'rejects ordinary-user writable staging' {
        $script:safeAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')), 'Modify', 'Allow'
        )))
        { Assert-ProtectedPath -Path 'C:\ProgramData\Scripts' } | Should -Throw '*non-administrator modification*'
    }

    It 'rejects untrusted ownership and reparse points' {
        $script:safeAcl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-21-1-2-3-1001')))
        { Assert-ProtectedPath -Path 'C:\ProgramData\Scripts' } | Should -Throw '*owned by SYSTEM or Administrators*'
        Mock Get-Item { [pscustomobject]@{ Attributes = [IO.FileAttributes]::ReparsePoint } }
        { Assert-ProtectedPath -Path 'C:\ProgramData\Scripts' } | Should -Throw '*junction or symbolic link*'
    }

    It 'creates a protected directory with Users read/execute only' {
        Mock Test-Path { $false }
        Initialize-ScriptDirectory -Path 'C:\ProgramData\Scripts'
        Should -Invoke Set-Acl -Times 1 -Exactly -ParameterFilter {
            $AclObject.AreAccessRulesProtected -and
            @($AclObject.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) |
                Where-Object {
                    $_.IdentityReference.Value -eq 'S-1-5-32-545' -and
                    ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Write) -eq 0
                }).Count -eq 1
        }
    }

    It 'registers a least-privilege group task for any user sign-in after 60 seconds' {
        & $registrationBody
        Should -Invoke New-Item -Times 0
        Should -Invoke Register-ScheduledTask -Times 1 -Exactly
        $task = $script:registeredTask
        $task.TaskName | Should -Be 'OneDrivePinnedFolders'
        $task.TaskPath | Should -Be '\'
        $task.Force | Should -BeTrue
        @($task.Action).Count | Should -Be 1
        $task.Action.Execute | Should -Be $powerShellPath
        $task.Action.Arguments | Should -Be $actionArguments
        @($task.Trigger).Count | Should -Be 1
        $task.Trigger.Delay | Should -Be 'PT60S'
        $task.Trigger.UserId | Should -BeNullOrEmpty
        $groupSid = (New-Object Security.Principal.NTAccount($task.Principal.GroupId)).
            Translate([Security.Principal.SecurityIdentifier]).Value
        $groupSid | Should -Be 'S-1-5-32-545'
        [int]$task.Principal.LogonType | Should -Be 4
        [int]$task.Principal.RunLevel | Should -Be 0
        $task.Principal.UserId | Should -BeNullOrEmpty
    }

    It 'sets a 30-minute cap, three one-minute failure retries, and parallel user instances' {
        & $registrationBody
        Should -Invoke Register-ScheduledTask -Times 1 -Exactly
        $settings = $script:registeredTask.Settings
        [Xml.XmlConvert]::ToTimeSpan($settings.ExecutionTimeLimit).TotalMinutes | Should -Be 30
        $settings.RestartCount | Should -Be 3
        [Xml.XmlConvert]::ToTimeSpan($settings.RestartInterval).TotalMinutes | Should -Be 1
        [int]$settings.MultipleInstances | Should -Be 0
        $settings.AllowHardTerminate | Should -BeTrue
        $settings.StartWhenAvailable | Should -BeTrue
        $settings.RunOnlyIfIdle | Should -BeFalse
        $settings.RunOnlyIfNetworkAvailable | Should -BeFalse
    }

    It 'removes only the two legacy Run values after successful registration' {
        Mock Get-ItemProperty {
            [pscustomobject]@{
                OneDrivePinnedFolders = 'old command'
                'FederalAVD-OneDrivePinnedFolders' = 'older command'
                UnrelatedStartup = 'leave alone'
            }
        }
        & $registrationBody
        Should -Invoke Remove-ItemProperty -Times 2 -Exactly -ParameterFilter {
            $LiteralPath -eq 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -and
            $Name -in @('OneDrivePinnedFolders', 'FederalAVD-OneDrivePinnedFolders')
        }
        Should -Invoke Remove-ItemProperty -Times 0 -ParameterFilter { $Name -eq 'UnrelatedStartup' }
    }

    It 'leaves an absent Run key untouched and does not recreate it' {
        Mock Test-Path { $false }
        & $registrationBody
        Should -Invoke Get-ItemProperty -Times 0
        Should -Invoke Remove-ItemProperty -Times 0
        Should -Invoke New-Item -Times 0
    }

    It 'does not remove unrelated startup values when legacy values are absent' {
        Mock Get-ItemProperty { [pscustomobject]@{ UnrelatedStartup = 'leave alone' } }
        & $registrationBody
        Should -Invoke Remove-ItemProperty -Times 0
    }

    It 'preserves existing startup registration and surfaces task registration failures' {
        Mock Register-ScheduledTask { throw 'Task registration denied' }
        { & $registrationBody } | Should -Throw '*Task registration denied*'
        Should -Invoke Get-ItemProperty -Times 0
        Should -Invoke Remove-ItemProperty -Times 0
    }

    It 'registers the script only after validating and writing it, without executing the payload' {
        $source.IndexOf('Initialize-ScriptDirectory -Path $scriptDirectory') | Should -BeLessThan $source.IndexOf('[IO.File]::WriteAllText(')
        $source.IndexOf('[IO.File]::WriteAllText(') | Should -BeLessThan $source.IndexOf('$null = Register-ScheduledTask')
        $source.IndexOf('$null = Register-ScheduledTask') | Should -BeLessThan $source.IndexOf('Remove-ItemProperty')
        $source | Should -Not -Match 'Start-Process|Start-ScheduledTask|Invoke-Expression|RunOnce|New-ItemProperty|& \$scriptPath'
        $generated | Should -Not -Match 'HKLM:|New-ItemProperty|Start-Process'
    }
}
