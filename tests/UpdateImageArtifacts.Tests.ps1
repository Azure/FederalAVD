BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $scriptPath = Join-Path $repoRoot 'deployments\Update-ImageArtifacts.ps1'
    $source = Get-Content -LiteralPath $scriptPath -Raw
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)
    if ($parseErrors.Count) { throw ($parseErrors.Message -join '; ') }
    $registration = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text.StartsWith('$RequiresWinget -and $RunningOnWindows')
    }, $true)
    $cleanup = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text -eq '$RunningOnWindows -and $RequiresWinget'
    }, $true)
    if (-not $registration -or -not $cleanup) {
        throw 'Windows-only WinGet setup blocks were not found.'
    }
    $registrationBlock = [scriptblock]::Create($registration.Extent.Text)
    $cleanupBlock = [scriptblock]::Create($cleanup.Extent.Text)
}

Describe 'Artifact updater portable path initialization' {
    BeforeEach {
        $fixtureRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $deployments = Join-Path $fixtureRoot 'deployments'
        foreach ($relative in @('deployments\shared\artifacts', 'deployments\shared\data',
            'customer\artifacts\Sample', 'temp')) {
            New-Item -Path (Join-Path $fixtureRoot $relative) -ItemType Directory -Force | Out-Null
        }
        $fixtureScript = Join-Path $deployments 'Update-ImageArtifacts.ps1'
        Copy-Item -LiteralPath $scriptPath -Destination $fixtureScript
        '{}' | Set-Content -LiteralPath (Join-Path $deployments 'shared\data\public.downloads.parameters.json') -Encoding ascii
        'fixture payload' | Set-Content -LiteralPath (Join-Path $fixtureRoot 'customer\artifacts\Sample\payload.txt') -Encoding ascii
        $output = Join-Path $fixtureRoot 'export'
        $fixtureTemp = Join-Path $fixtureRoot 'temp'
        $savedEnvironment = @{}
        foreach ($name in @('TEMP', 'TMP', 'TMPDIR')) {
            $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        }
        $env:TMP = $fixtureTemp
        $env:TMPDIR = $fixtureTemp
        Remove-Item Env:TEMP -ErrorAction SilentlyContinue
        Mock Start-Job {}
    }

    AfterEach {
        foreach ($name in $savedEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
        }
    }

    It 'packages with TEMP absent and the platform default temp directory' {
        & $fixtureScript -PackageOnly -OutputPath $output | Out-Null

        Test-Path -LiteralPath (Join-Path $output 'Sample.zip') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $fixtureTemp 'Artifacts\sources') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $output 'uploadedFileVersionInfo.txt') | Should -BeTrue
        $archive = [IO.Compression.ZipFile]::OpenRead((Join-Path $output 'Sample.zip'))
        try {
            $archive.Entries.FullName | Should -Contain 'payload.txt'
        }
        finally {
            $archive.Dispose()
        }
    }

    It 'honors explicit TempDir throughout download initialization even when TEMP is absent' {
        $customTemp = Join-Path $fixtureRoot 'custom-temp'
        & $fixtureScript -PackageOnly -OutputPath $output -TempDir $customTemp | Out-Null

        Test-Path -LiteralPath (Join-Path $customTemp 'Artifacts\sources') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $output 'Sample.zip') | Should -BeTrue
    }

    It 'packages pre-staged artifacts without downloading when TEMP is absent' {
        & $fixtureScript -PackageOnly -OutputPath $output -SkipDownloadingNewSources | Out-Null

        Test-Path -LiteralPath (Join-Path $output 'Sample.zip') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $fixtureTemp 'Artifacts\sources') | Should -BeFalse
    }

    It 'rejects an empty or whitespace TempDir: [<Value>]' -TestCases @(
        @{ Value = '' }, @{ Value = '   ' }
    ) {
        param($Value)
        { & $fixtureScript -PackageOnly -OutputPath $output -TempDir $Value } | Should -Throw '*TempDir*'
        Test-Path -LiteralPath $output | Should -BeFalse
    }

    It 'reports missing script context explicitly instead of failing in Join-Path' {
        $guard = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
                $node.Clauses[0].Item1.Extent.Text -eq '[string]::IsNullOrWhiteSpace($PSScriptRoot)'
        }, $true)
        $guard | Should -Not -BeNullOrEmpty
        $block = [scriptblock]::Create($guard.Extent.Text)
        { & { $PSScriptRoot = ''; & $block } } | Should -Throw '*saved file*'
    }

    It 'keeps the script ASCII-only' {
        $source | Should -Not -Match '[^\x00-\x7E]'
    }
}

Describe 'Artifact updater Windows-only WinGet setup' {
    It 'leaves PATH and Windows tooling untouched on non-Windows systems' {
        $RunningOnWindows = $false
        $RequiresWinget = $true
        $originalPath = $env:PATH
        Mock Get-Command { throw 'WinGet registration must not run on Linux.' } -ParameterFilter { $Name -eq 'winget' }
        Mock Join-Path { throw 'WinGet cleanup must not run on Linux.' } -ParameterFilter { $ChildPath -eq 'WinGet' }

        & $registrationBlock
        & $cleanupBlock

        $env:PATH | Should -BeExactly $originalPath
        Should -Invoke Get-Command -Times 0 -Exactly -ParameterFilter { $Name -eq 'winget' }
        Should -Invoke Join-Path -Times 0 -Exactly -ParameterFilter { $ChildPath -eq 'WinGet' }
    }

    It 'does not clean WinGet cache when no download requires WinGet' {
        $RunningOnWindows = $true
        $RequiresWinget = $false
        Mock Join-Path { throw 'WinGet cache is unrelated to these downloads.' } -ParameterFilter { $ChildPath -eq 'WinGet' }

        & $cleanupBlock

        Should -Invoke Join-Path -Times 0 -Exactly -ParameterFilter { $ChildPath -eq 'WinGet' }
    }

    It 'uses the platform temp directory for Windows WinGet cache even with TEMP absent' {
        $RunningOnWindows = $true
        $RequiresWinget = $true
        $originalTemp = $env:TEMP
        $expectedCache = Join-Path ([IO.Path]::GetTempPath()) 'WinGet'
        Mock Test-Path { $false } -ParameterFilter { $Path -eq $expectedCache }
        try {
            Remove-Item Env:TEMP -ErrorAction SilentlyContinue
            . $cleanupBlock
            $WingetTempDir | Should -BeExactly (Join-Path ([IO.Path]::GetTempPath()) 'WinGet')
        }
        finally {
            $env:TEMP = $originalTemp
        }
    }

    It 'preserves the Windows TEMP cache location independently of explicit artifact staging' {
        $RunningOnWindows = $true
        $RequiresWinget = $true
        $originalTemp = $env:TEMP
        $expectedCache = Join-Path $TestDrive 'windows-temp\WinGet'
        Mock Test-Path { $false } -ParameterFilter { $Path -eq $expectedCache }
        try {
            $env:TEMP = Join-Path $TestDrive 'windows-temp'
            $TempDir = Join-Path $TestDrive 'artifact-staging'
            . $cleanupBlock
            $WingetTempDir | Should -BeExactly $expectedCache
        }
        finally {
            $env:TEMP = $originalTemp
        }
    }
}
