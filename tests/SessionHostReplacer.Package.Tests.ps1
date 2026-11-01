$repoRoot = Split-Path -Parent $PSScriptRoot
$builderPath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\New-SessionHostReplacerPackage.ps1'
$sourcePath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\functions'
$workflowPath = Join-Path $repoRoot '.github\workflows\release-shr-package.yml'

Describe 'SHR optional prebuilt extension package' {
    BeforeAll {
        $workflow = Get-Content -LiteralPath $workflowPath -Raw
        $workflowScripts = @([regex]::Matches($workflow, '(?m)^        run: \|\r?\n((?:          .*(?:\r?\n|$))+)') |
            ForEach-Object { ($_.Groups[1].Value -replace '(?m)^          ', '') })
        $fakeDotnet = Join-Path $TestDrive 'dotnet.ps1'
        @'
param([Parameter(ValueFromRemainingArguments)] [string[]] $Arguments)
if ($Arguments[0] -eq '--list-sdks') {
    $global:LASTEXITCODE = 0
    if ($global:shrPackageTest.NoSdk) { return }
    '8.0.100 [test-sdk]'
    return
}
$global:shrPackageTest.Arguments = $Arguments
$global:shrPackageTest.ProjectPath = $Arguments[1]
$global:shrPackageTest.Project = Get-Content -LiteralPath $Arguments[1] -Raw
$global:LASTEXITCODE = $global:shrPackageTest.BuildExit
if ($global:LASTEXITCODE -ne 0) { return }
if ($global:shrPackageTest.RaceOutputPath) {
    Set-Content -LiteralPath $global:shrPackageTest.RaceOutputPath -Value 'concurrent archive'
}
$outputPath = $Arguments[[array]::IndexOf($Arguments, '--output') + 1]
$binPath = Join-Path $outputPath 'bin'
[IO.Directory]::CreateDirectory($binPath) | Out-Null
Set-Content -LiteralPath (Join-Path $outputPath 'extensions.deps.json') -Value '{}'
if (-not $global:shrPackageTest.MissingAssembly) {
    [IO.File]::WriteAllBytes((Join-Path $binPath 'Microsoft.Azure.WebJobs.Extensions.Storage.Queues.dll'), [byte[]]@(1, 2, 3))
}
Set-Content -LiteralPath (Join-Path $binPath 'dependency.dll') -Value 'dependency'
if (-not $global:shrPackageTest.MissingMetadata) {
    $type = 'Microsoft.Azure.WebJobs.Extensions.Storage.Queues.StorageQueuesWebJobsStartup, Microsoft.Azure.WebJobs.Extensions.Storage.Queues'
    if ($global:shrPackageTest.WrongMetadata) { $type = 'Other.Extension' }
    @{ extensions = @(@{ name = 'AzureStorageQueues'; typeName = $type }) } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $binPath 'extensions.json')
}
'Build completed.'
'@ | Set-Content -LiteralPath $fakeDotnet -Encoding ascii

        function Read-PackageEntry {
            param([string] $ZipPath, [string] $Name)
            $archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
            try {
                $entry = $archive.GetEntry($Name)
                if (-not $entry) { throw "Missing package entry: $Name" }
                $reader = [IO.StreamReader]::new($entry.Open())
                try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
            } finally { $archive.Dispose() }
        }
    }

    BeforeEach {
        $outputPath = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N')).zip"
        $global:shrPackageTest = @{
            NoSdk = $false
            BuildExit = 0
            MissingAssembly = $false
            MissingMetadata = $false
            WrongMetadata = $false
            Arguments = @()
            ProjectPath = ''
            Project = ''
            RaceOutputPath = ''
        }
        Mock Get-Command { [PSCustomObject]@{ Source = $fakeDotnet } } -ParameterFilter { $Name -eq 'dotnet' }
        Mock Import-PowerShellDataFile { @{} }
    }

    AfterAll {
        Remove-Variable shrPackageTest -Scope Global -ErrorAction SilentlyContinue
    }

    It 'creates a complete app-root layout with exact scheduler, worker, engine and shared modules' {
        $result = & $builderPath -OutputPath $outputPath
        $result.OutputPath | Should Be $outputPath
        $result.SHA256 | Should Be (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash
        $result.TimerScheduleSetting | Should Be 'TimerSchedule'
        Read-PackageEntry $outputPath 'LICENSE' | Should Be (Get-Content (Join-Path $repoRoot 'LICENSE') -Raw)
        Read-PackageEntry $outputPath 'ThirdPartyNotices.txt' |
            Should Be (Get-Content (Join-Path (Split-Path -Parent $builderPath) 'ThirdPartyNotices.txt') -Raw)
        Read-PackageEntry $outputPath 'session-host-replacer/run.ps1' |
            Should Be (Get-Content (Join-Path $sourcePath 'scheduler.ps1') -Raw)
        Read-PackageEntry $outputPath 'session-host-replacer-worker/run.ps1' |
            Should Be (Get-Content (Join-Path $sourcePath 'worker.ps1') -Raw)
        Read-PackageEntry $outputPath 'shr-cycle.ps1' |
            Should Be (Get-Content (Join-Path $sourcePath 'run.ps1') -Raw)
        foreach ($file in Get-ChildItem (Join-Path $sourcePath 'Modules') -Recurse -File |
            Where-Object { $_.Extension -in '.psm1', '.psd1' }) {
            $name = [IO.Path]::GetRelativePath($sourcePath, $file.FullName).Replace('\', '/')
            Read-PackageEntry $outputPath $name | Should Be (Get-Content -LiteralPath $file.FullName -Raw)
        }
        Read-PackageEntry $outputPath 'profile.ps1' | Should Be (Get-Content (Join-Path $sourcePath 'profile.ps1') -Raw)
        Read-PackageEntry $outputPath 'requirements.psd1' | Should Be (Get-Content (Join-Path $sourcePath 'requirements.psd1') -Raw)
        Test-Path -LiteralPath (Split-Path -Parent $global:shrPackageTest.ProjectPath) | Should Be $false
    }

    It 'packages extension binaries, registration and dependencies without requesting a runtime bundle or module restore' {
        & $builderPath -OutputPath $outputPath | Out-Null
        $hostConfig = Read-PackageEntry $outputPath 'host.json' | ConvertFrom-Json
        $hostConfig.PSObject.Properties.Name | Should Not Contain 'extensionBundle'
        $hostConfig.managedDependency.enabled | Should Be $false
        $hostConfig.functionTimeout | Should Be '00:10:00'
        $hostConfig.extensions.queues.visibilityTimeout | Should Be '00:02:00'
        Read-PackageEntry $outputPath 'bin/extensions.json' | Should Match 'StorageQueuesWebJobsStartup'
        Read-PackageEntry $outputPath 'bin/dependency.dll' | Should Match 'dependency'
        Read-PackageEntry $outputPath 'extensions.deps.json' | Should Match '\{\}'
        $archive = [IO.Compression.ZipFile]::OpenRead($outputPath)
        try {
            $archive.GetEntry('bin/Microsoft.Azure.WebJobs.Extensions.Storage.Queues.dll') | Should Not BeNullOrEmpty
            $archive.GetEntry('local.settings.json') | Should BeNullOrEmpty
            $archive.GetEntry('scheduler.ps1') | Should BeNullOrEmpty
        } finally { $archive.Dispose() }
    }

    It 'uses the deployment app setting instead of embedding a schedule and retains the queue identity connection' {
        & $builderPath -OutputPath $outputPath | Out-Null
        $timer = Read-PackageEntry $outputPath 'session-host-replacer/function.json' | ConvertFrom-Json
        $timer.scriptFile | Should Be 'run.ps1'
        $timer.bindings.Count | Should Be 1
        $timer.bindings[0].type | Should Be 'timerTrigger'
        $timer.bindings[0].name | Should Be 'Timer'
        $timer.bindings[0].schedule | Should Be '%TimerSchedule%'
        $worker = Read-PackageEntry $outputPath 'session-host-replacer-worker/function.json' | ConvertFrom-Json
        $worker.bindings[0].type | Should Be 'queueTrigger'
        $worker.bindings[0].name | Should Be 'WorkItem'
        $worker.bindings[0].queueName | Should Be 'shr-continuation'
        $worker.bindings[0].connection | Should Be 'AzureWebJobsStorage'
    }

    It 'pins the build versions and accepts an approved NuGet feed only on the build workstation' {
        & $builderPath -OutputPath $outputPath -QueueExtensionVersion '5.3.4' `
            -NuGetSource 'https://approved.example/nuget/v3/index.json' | Out-Null
        $global:shrPackageTest.Arguments | Should Contain 'publish'
        $global:shrPackageTest.Arguments | Should Contain '--source'
        $global:shrPackageTest.Arguments | Should Contain 'https://approved.example/nuget/v3/index.json'
        $global:shrPackageTest.Project | Should Match 'Version="5.3.4"'
        $global:shrPackageTest.Project | Should Match 'Version="4.6.0"'
        $manifest = Read-PackageEntry $outputPath 'shr-package.json' | ConvertFrom-Json
        $manifest.queueExtensionVersion | Should Be '5.3.4'
        $manifest.schemaVersion | Should Be 2
        $manifest.timerScheduleSetting | Should Be 'TimerSchedule'
        $manifest.PSObject.Properties.Name | Should Not Contain 'timerSchedule'
        Read-PackageEntry $outputPath 'shr-package.json' | Should Not Match 'approved.example'
    }

    It 'preserves an existing output unless Force is supplied' {
        Set-Content -LiteralPath $outputPath -Value 'existing archive'
        { & $builderPath -OutputPath $outputPath } | Should Throw 'already exists'
        Get-Content -LiteralPath $outputPath | Should Be 'existing archive'
        & $builderPath -OutputPath $outputPath -Force | Out-Null
        Read-PackageEntry $outputPath 'host.json' | Should Match '"version"'
    }

    It 'does not overwrite an archive created during the build without Force and removes its staged file' {
        $global:shrPackageTest.RaceOutputPath = $outputPath
        { & $builderPath -OutputPath $outputPath } | Should Throw
        Get-Content -LiteralPath $outputPath | Should Be 'concurrent archive'
        @(Get-ChildItem -LiteralPath $TestDrive -Filter 'shr-package-*.tmp').Count | Should Be 0
    }

    It 'fails explicitly without an installed SDK or with invalid extension version or output type' {
        $global:shrPackageTest.NoSdk = $true
        { & $builderPath -OutputPath $outputPath } | Should Throw 'Install .NET SDK'
        { & $builderPath -OutputPath $outputPath -QueueExtensionVersion '4.0.0' } | Should Throw
        { & $builderPath -OutputPath "$outputPath.txt" } | Should Throw '.zip file'
        Test-Path -LiteralPath $outputPath | Should Be $false
    }

    It 'does not silently disable configured managed PowerShell dependencies' {
        Mock Import-PowerShellDataFile { @{ Az = '17.*' } }
        { & $builderPath -OutputPath $outputPath } | Should Throw 'Managed PowerShell dependencies'
        Test-Path -LiteralPath $outputPath | Should Be $false
    }

    It 'retains the old ZIP and cleans temporary build files when compilation fails' {
        Set-Content -LiteralPath $outputPath -Value 'existing archive'
        $global:shrPackageTest.BuildExit = 17
        { & $builderPath -OutputPath $outputPath -Force } | Should Throw 'exit code 17'
        Get-Content -LiteralPath $outputPath | Should Be 'existing archive'
        Test-Path -LiteralPath (Split-Path -Parent $global:shrPackageTest.ProjectPath) | Should Be $false
    }

    It 'rejects missing binaries, missing registration metadata and metadata without the queue extension' {
        $global:shrPackageTest.MissingAssembly = $true
        { & $builderPath -OutputPath $outputPath } | Should Throw 'did not produce'
        $global:shrPackageTest.MissingAssembly = $false
        $global:shrPackageTest.MissingMetadata = $true
        { & $builderPath -OutputPath $outputPath } | Should Throw 'did not produce'
        $global:shrPackageTest.MissingMetadata = $false
        $global:shrPackageTest.WrongMetadata = $true
        { & $builderPath -OutputPath $outputPath } | Should Throw 'does not register'
        Test-Path -LiteralPath $outputPath | Should Be $false
    }

    It 'publishes only from a release tag with pinned actions and no persisted checkout credentials' {
        $workflow | Should Match 'types: \[published\]'
        $workflow | Should Match 'ref: \$\{\{ github.sha \}\}'
        $workflow | Should Match 'persist-credentials: false'
        $workflow | Should Match 'actions/checkout@[a-f0-9]{40}'
        $workflow | Should Match 'actions/setup-dotnet@[a-f0-9]{40}'
        $workflow | Should Match "dotnet-version: '8.0.x'"
        $workflow | Should Match 'contents: write'
        $workflow | Should Not Match '--clobber'
    }

    It 'keeps workflow PowerShell valid and release inputs out of inline script expressions' {
        $workflowScripts.Count | Should Be 2
        foreach ($body in $workflowScripts) {
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseInput($body, [ref]$null, [ref]$errors) | Out-Null
            $errors.Count | Should Be 0
            $body | Should Not Match '\$\{\{'
        }
    }

    It 'runs the workflow build step to create the portable ZIP and matching checksum sidecar' {
        $previousTemp = [Environment]::GetEnvironmentVariable('RUNNER_TEMP')
        $releaseDirectory = Join-Path $TestDrive 'release-assets'
        [IO.Directory]::CreateDirectory($releaseDirectory) | Out-Null
        [Environment]::SetEnvironmentVariable('RUNNER_TEMP', $releaseDirectory)
        Push-Location $repoRoot
        try {
            & ([ScriptBlock]::Create($workflowScripts[0]))
            $zip = Join-Path $releaseDirectory 'SessionHostReplacer.zip'
            $checksum = (Get-Content -LiteralPath "$zip.sha256" -Raw).Trim() -split '\s+'
            $checksum[0] | Should Be (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
            $checksum[1] | Should Be 'SessionHostReplacer.zip'
            $timer = Read-PackageEntry $zip 'session-host-replacer/function.json' | ConvertFrom-Json
            $timer.bindings[0].schedule | Should Be '%TimerSchedule%'
        } finally {
            Pop-Location
            [Environment]::SetEnvironmentVariable('RUNNER_TEMP', $previousTemp)
        }
    }

    It 'passes release inputs literally and reports asset-upload failures without contacting GitHub' {
        function gh {
            param([Parameter(ValueFromRemainingArguments)] [string[]] $Arguments)
            $global:shrPackageTest.UploadArguments = $Arguments
            $global:LASTEXITCODE = $global:shrPackageTest.UploadExit
        }
        $previousTag = [Environment]::GetEnvironmentVariable('RELEASE_TAG')
        $previousRepository = [Environment]::GetEnvironmentVariable('GITHUB_REPOSITORY')
        $previousTemp = [Environment]::GetEnvironmentVariable('RUNNER_TEMP')
        [Environment]::SetEnvironmentVariable('RELEASE_TAG', 'v1;not-a-command')
        [Environment]::SetEnvironmentVariable('GITHUB_REPOSITORY', 'test/repository')
        [Environment]::SetEnvironmentVariable('RUNNER_TEMP', $TestDrive)
        try {
            $global:shrPackageTest.UploadExit = 0
            & ([ScriptBlock]::Create($workflowScripts[1]))
            $global:shrPackageTest.UploadArguments | Should Contain 'v1;not-a-command'
            $global:shrPackageTest.UploadArguments | Should Contain 'test/repository'
            $global:shrPackageTest.UploadArguments | Should Contain (Join-Path $TestDrive 'SessionHostReplacer.zip')
            $global:shrPackageTest.UploadArguments | Should Contain (Join-Path $TestDrive 'SessionHostReplacer.zip.sha256')
            $global:shrPackageTest.UploadExit = 1
            { & ([ScriptBlock]::Create($workflowScripts[1])) } | Should Throw 'asset upload failed'
        } finally {
            [Environment]::SetEnvironmentVariable('RELEASE_TAG', $previousTag)
            [Environment]::SetEnvironmentVariable('GITHUB_REPOSITORY', $previousRepository)
            [Environment]::SetEnvironmentVariable('RUNNER_TEMP', $previousTemp)
        }
    }
}
