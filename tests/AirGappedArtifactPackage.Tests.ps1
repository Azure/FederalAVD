$repoRoot = Split-Path -Parent $PSScriptRoot
$builder = Join-Path $repoRoot 'tools\New-AirGappedArtifactPackage.ps1'
$workflowPath = Join-Path $repoRoot '.github\workflows\release-airgap-artifacts.yml'
$joiner = Join-Path $repoRoot 'tools\Join-AirGappedArtifactPackage.ps1'

Describe 'Combined air-gapped artifact transfer package' {
    BeforeAll {
        $fakeRepo = Join-Path $TestDrive 'repository'
        $toolDirectory = Join-Path $fakeRepo 'tools'
        [IO.Directory]::CreateDirectory($toolDirectory) | Out-Null
        Copy-Item -LiteralPath $builder -Destination $toolDirectory
        Copy-Item -LiteralPath (Join-Path $repoRoot 'LICENSE') -Destination $fakeRepo
        $data = Join-Path $fakeRepo 'deployments\shared\data'
        [IO.Directory]::CreateDirectory($data) | Out-Null
        Copy-Item -LiteralPath (Join-Path $repoRoot 'deployments\shared\data\public.downloads.parameters.json') -Destination $data
        foreach ($name in 'Microsoft-WinGet', 'BuiltIn-UWP-Apps') {
            [IO.Directory]::CreateDirectory((Join-Path $fakeRepo "customer-examples\artifacts\$name\_build")) | Out-Null
        }
        @'
param($OutputPath, $ReleaseTag)
if ($global:airgapTest.FailBuilder) { throw 'Simulated artifact failure' }
$global:airgapTest.ReleaseTag = $ReleaseTag
$stage = Join-Path (Split-Path $OutputPath) 'winGet-stage'
[IO.Directory]::CreateDirectory($stage) | Out-Null
Set-Content (Join-Path $stage 'Install-MicrosoftWinGet.ps1') -Value 'runtime installer'
@{releaseTag='v1.29.380';assets=@(1,2,3,4)} | ConvertTo-Json | Set-Content (Join-Path $stage 'transfer-manifest.json')
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $OutputPath)
Remove-Item -LiteralPath $stage -Recurse -Force
'@ | Set-Content -LiteralPath (Join-Path $fakeRepo 'customer-examples\artifacts\Microsoft-WinGet\_build\Build-MicrosoftWinGet.ps1') -Encoding ascii
        @'
param($OutputPath, $AppStoreIds)
$global:airgapTest.AppStoreIds = $AppStoreIds
$stage = Join-Path (Split-Path $OutputPath) 'uwp-stage'
[IO.Directory]::CreateDirectory($stage) | Out-Null
Set-Content (Join-Path $stage 'Install-BuiltinUwpApps.ps1') -Value 'runtime installer'
[IO.Directory]::CreateDirectory((Join-Path $stage 'SharedDependencies')) | Out-Null
Set-Content (Join-Path $stage 'SharedDependencies\framework.appx') -Value 'required offline framework'
$id = if ($global:airgapTest.HEVC) {'9N4WGH0Z6VHQ'} else {'9WZDNCRFHVN5'}
@{apps=@(@{storeId=$id;version='1.2.3.4'})} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $stage 'transfer-manifest.json')
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $OutputPath)
Remove-Item -LiteralPath $stage -Recurse -Force
'@ | Set-Content -LiteralPath (Join-Path $fakeRepo 'customer-examples\artifacts\BuiltIn-UWP-Apps\_build\Build-BuiltinUwpApps.ps1') -Encoding ascii
        $testBuilder = Join-Path $toolDirectory 'New-AirGappedArtifactPackage.ps1'
        function Read-TransferEntry {
            param($Path, $Name)
            $archive = [IO.Compression.ZipFile]::OpenRead($Path)
            try {
                $reader = [IO.StreamReader]::new($archive.GetEntry($Name).Open())
                try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
            } finally { $archive.Dispose() }
        }
    }
    BeforeEach {
        $output = Join-Path $TestDrive "$([guid]::NewGuid()).zip"
        $global:airgapTest = @{FailBuilder=$false; HEVC=$false; ReleaseTag=''; AppStoreIds=@(); BadSignature=$false}
        Mock Invoke-WebRequest { Set-Content -LiteralPath $OutFile -Value 'downloaded payload' }
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{
                Status = if ($global:airgapTest.BadSignature) {'NotSigned'} else {'Valid'}
                SignerCertificate = [pscustomobject]@{Subject='CN=Microsoft Corporation, O=Microsoft Corporation, C=US'}
            }
        }
        Mock Get-Item {
            $file = [IO.FileInfo]::new($LiteralPath)
            return [pscustomobject]@{
                Name=$file.Name; FullName=$file.FullName; Length=$file.Length
                VersionInfo=[pscustomobject]@{FileVersion='1.2.3.4'}
            }
        } -ParameterFilter { $LiteralPath -like '*.exe' }
        Mock New-Object {
            $record = [pscustomobject]@{}
            $record | Add-Member ScriptMethod StringData { param($Index) '1.2.3' }
            $view = [pscustomobject]@{Record=$record}
            $view | Add-Member ScriptMethod Execute {}
            $view | Add-Member ScriptMethod Fetch { $this.Record }
            $view | Add-Member ScriptMethod Close {}
            $database = [pscustomobject]@{View=$view}
            $database | Add-Member ScriptMethod OpenView { param($Query) $this.View }
            $installer = [pscustomobject]@{Database=$database}
            $installer | Add-Member ScriptMethod OpenDatabase { param($Path,$Mode) $this.Database }
            return $installer
        } -ParameterFilter { $ComObject -eq 'WindowsInstaller.Installer' }
    }
    AfterAll { Remove-Variable airgapTest -Scope Global -ErrorAction SilentlyContinue }

    It 'creates one outer bundle with unchanged inner ZIPs and loose prerequisites' {
        $result = & $testBuilder -OutputPath $output -SourceRevision 'test-commit' -WinGetReleaseTag 'v1.29.380' `
            -AppStoreIds '9WZDNCRFHVN5' -IncludeWebRtc
        $result.ArtifactCount | Should Be 5
        $result.PartCount | Should Be 0
        $result.ReleaseFiles.Count | Should Be 2
        $global:airgapTest.ReleaseTag | Should Be 'v1.29.380'
        $global:airgapTest.AppStoreIds | Should Contain '9WZDNCRFHVN5'
        $manifest = Read-TransferEntry $output 'transfer-manifest.json' | ConvertFrom-Json
        $manifest.schemaVersion | Should Be 1
        $manifest.sourceRevision | Should Be 'test-commit'
        $manifest.includeWebRtc | Should Be $true
        $manifest.unresolved.Count | Should Be 2
        $manifest.artifacts.Count | Should Be 5
        $manifest.artifacts.fileName | Should Contain 'MsRdcWebRTCSvc.msi'
        $manifest.artifacts.fileName | Should Not Contain 'MSTeams-x64.msix'
        $manifest.artifacts.fileName | Should Not Contain 'OneDriveSetup.exe'
        $manifest.artifacts.fileName | Should Not Contain 'Office365DeploymentTool.exe'
        $manifest.artifacts.fileName | Should Not Contain 'teamsbootstrapper.exe'
        foreach ($item in $manifest.artifacts) {
            $archive = [IO.Compression.ZipFile]::OpenRead($output)
            try {
                $stream = $archive.GetEntry("artifacts/$($item.fileName)").Open()
                try {
                    $sha = [Security.Cryptography.SHA256]::Create()
                    try { $hash = [Convert]::ToHexString($sha.ComputeHash($stream)) } finally { $sha.Dispose() }
                } finally { $stream.Dispose() }
            } finally { $archive.Dispose() }
            $item.sha256 | Should Be $hash
            $item.destination | Should Be "customer/artifacts/$($item.fileName)"
        }
        $result.SHA256 | Should Be (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash
        (Get-Content -LiteralPath "$output.sha256" -Raw).Trim() |
            Should Be "$($result.SHA256)  $([IO.Path]::GetFileName($output))"
        Read-TransferEntry $output 'LICENSE' | Should Be (Get-Content (Join-Path $repoRoot 'LICENSE') -Raw)
    }
    It 'includes WebRTC by default for the current air-gapped Teams path' {
        $result = & $testBuilder -OutputPath $output -SourceRevision 'test'
        $result.IncludeWebRtc | Should Be $true
        $result.ArtifactCount | Should Be 5
        $manifest = Read-TransferEntry $output 'transfer-manifest.json' | ConvertFrom-Json
        $manifest.artifacts.Count | Should Be 5
        $manifest.includeWebRtc | Should Be $true
        $manifest.artifacts.fileName | Should Contain 'MsRdcWebRTCSvc.msi'
        ($manifest.artifacts | Where-Object fileName -eq 'MsRdcWebRTCSvc.msi').consumer |
            Should Match 'Windows App support awaits product-group confirmation'
        Assert-MockCalled Invoke-WebRequest -Times 3 -Exactly -Scope It
    }
    It 'honors explicit WebRTC omission and warns that it does not migrate the Teams path' {
        Mock Write-Warning {}
        $result = & $testBuilder -OutputPath $output -SourceRevision 'test' -IncludeWebRtc:$false
        $result.IncludeWebRtc | Should Be $false
        $manifest = Read-TransferEntry $output 'transfer-manifest.json' | ConvertFrom-Json
        $manifest.artifacts.Count | Should Be 4
        $manifest.includeWebRtc | Should Be $false
        $manifest.artifacts.fileName | Should Not Contain 'MsRdcWebRTCSvc.msi'
        Assert-MockCalled Invoke-WebRequest -Times 2 -Exactly -Scope It
        Assert-MockCalled Write-Warning -Times 1 -Exactly -Scope It -ParameterFilter {
            $Message -like '*current air-gapped Teams path requires this MSI*'
        }
    }
    It 'rejects licensed HEVC selections and HEVC returned in an inner inventory' {
        { & $testBuilder -OutputPath $output -SourceRevision 'test' -AppStoreIds '9N4WGH0Z6VHQ' } | Should Throw
        $global:airgapTest.HEVC = $true
        { & $testBuilder -OutputPath $output -SourceRevision 'test' } | Should Throw 'HEVC'
        Test-Path -LiteralPath $output | Should Be $false
    }
    It 'rejects unsigned payloads without publishing output' {
        $global:airgapTest.BadSignature = $true
        { & $testBuilder -OutputPath $output -SourceRevision 'test' } | Should Throw 'signed'
        Test-Path -LiteralPath $output | Should Be $false
    }
    It 'preserves approved outputs when an artifact build fails' {
        Set-Content -LiteralPath $output -Value 'approved zip'
        Set-Content -LiteralPath "$output.sha256" -Value 'approved hash'
        $global:airgapTest.FailBuilder = $true
        { & $testBuilder -OutputPath $output -SourceRevision 'test' -Force } | Should Throw 'artifact failure'
        (Get-Content -LiteralPath $output -Raw).Trim() | Should Be 'approved zip'
        (Get-Content -LiteralPath "$output.sha256" -Raw).Trim() | Should Be 'approved hash'
    }
    It 'does not overwrite existing output or accept duplicate apps' {
        Set-Content -LiteralPath $output -Value 'approved'
        { & $testBuilder -OutputPath $output -SourceRevision 'test' } | Should Throw 'exists'
        { & $testBuilder -OutputPath "$output.new.zip" -SourceRevision 'test' `
            -AppStoreIds '9WZDNCRFHVN5','9WZDNCRFHVN5' } | Should Throw 'duplicate'
    }
    It 'rejects part sizes at the GitHub release limit before building' {
        { & $testBuilder -OutputPath $output -SourceRevision 'test' -ReleasePartSizeBytes 2GB } | Should Throw
        Test-Path -LiteralPath $output | Should Be $false
        Test-Path -LiteralPath "$output.sha256" | Should Be $false
    }
    It 'splits at exact byte boundaries and reassembles unchanged ZIPs with offline frameworks intact' {
        $result = & $testBuilder -OutputPath $output -SourceRevision 'test' -ReleasePartSizeBytes 256
        $result.PartCount | Should BeGreaterThan 1
        $result.ReleaseFiles | Should Not Contain $output
        $result.ReleaseFiles | Should Contain "$output.parts.json"
        $result.ReleaseFiles.Count | Should Be ($result.PartCount + 2)
        $parts = Get-Content -LiteralPath "$output.parts.json" -Raw | ConvertFrom-Json
        $parts.zipSizeBytes | Should Be (Get-Item -LiteralPath $output).Length
        for ($index=0; $index -lt $parts.parts.Count; $index++) {
            $part = $parts.parts[$index]
            $partPath = Join-Path (Split-Path $output) $part.fileName
            $part.sizeBytes | Should Be (Get-Item -LiteralPath $partPath).Length
            if ($index -lt $parts.parts.Count - 1) { $part.sizeBytes | Should Be 256 }
            $part.sizeBytes | Should BeLessThan 257
            $part.sha256 | Should Be (Get-FileHash -LiteralPath $partPath -Algorithm SHA256).Hash
        }
        $destination = Join-Path $TestDrive 'joined\transfer.zip'
        $joined = & $joiner -PartsManifest "$output.parts.json" -OutputPath $destination
        $joined.SHA256 | Should Be $result.SHA256
        (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash | Should Be $result.SHA256
        { & $joiner -PartsManifest "$output.parts.json" -OutputPath $destination } | Should Throw 'exists'
        & $joiner -PartsManifest "$output.parts.json" -OutputPath $destination -Force | Out-Null
        $archive = [IO.Compression.ZipFile]::OpenRead($destination)
        try {
            $inner = Join-Path $TestDrive 'checked-uwp.zip'
            [IO.Compression.ZipFileExtensions]::ExtractToFile($archive.GetEntry('artifacts/BuiltIn-UWP-Apps.zip'), $inner)
            $uwp = [IO.Compression.ZipFile]::OpenRead($inner)
            try { $uwp.GetEntry('SharedDependencies/framework.appx') | Should Not BeNullOrEmpty }
            finally { $uwp.Dispose() }
        } finally { $archive.Dispose() }
    }
    It 'rejects missing, corrupted, reordered, unsafe, or inconsistent parts without replacing approved output' {
        & $testBuilder -OutputPath $output -SourceRevision 'test' -ReleasePartSizeBytes 256 | Out-Null
        $manifestPath = "$output.parts.json"
        $originalManifest = Get-Content -LiteralPath $manifestPath -Raw
        $destination = Join-Path $TestDrive 'approved.zip'
        Set-Content -LiteralPath $destination -Value 'approved original'
        $parts = $originalManifest | ConvertFrom-Json
        $firstPath = Join-Path (Split-Path $output) $parts.parts[0].fileName
        $bytes = [IO.File]::ReadAllBytes($firstPath)
        Remove-Item -LiteralPath $firstPath
        { & $joiner -PartsManifest $manifestPath -OutputPath $destination -Force } | Should Throw
        [IO.File]::WriteAllBytes($firstPath, $bytes)
        $badBytes = $bytes.Clone()
        $badBytes[0] = $badBytes[0] -bxor 1
        [IO.File]::WriteAllBytes($firstPath, $badBytes)
        { & $joiner -PartsManifest $manifestPath -OutputPath $destination -Force } | Should Throw 'integrity'
        [IO.File]::WriteAllBytes($firstPath, $bytes)
        foreach ($mutation in 'reorder','path','size','hash') {
            $parts = $originalManifest | ConvertFrom-Json
            switch ($mutation) {
                reorder { [array]::Reverse($parts.parts) }
                path { $parts.parts[0].fileName = '..\outside.part001' }
                size { $parts.zipSizeBytes++ }
                hash { $parts.zipSHA256 = '0' * 64 }
            }
            $parts | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath
            { & $joiner -PartsManifest $manifestPath -OutputPath $destination -Force } | Should Throw
            (Get-Content -LiteralPath $destination -Raw).Trim() | Should Be 'approved original'
        }
        Set-Content -LiteralPath $manifestPath -Value $originalManifest
        Set-Content -LiteralPath "$destination.sha256" -Value ('0' * 64)
        { & $joiner -PartsManifest $manifestPath -OutputPath $destination -Force } | Should Throw 'disagrees'
    }
    It 'reassembles beside downloaded checksum records and refuses to overwrite existing parts' {
        $result = & $testBuilder -OutputPath $output -SourceRevision 'test' -ReleasePartSizeBytes 256
        Remove-Item -LiteralPath $output
        & $joiner -PartsManifest "$output.parts.json" | Out-Null
        (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash | Should Be $result.SHA256
        Remove-Item -LiteralPath $output,"$output.sha256","$output.parts.json"
        { & $testBuilder -OutputPath $output -SourceRevision 'test' -ReleasePartSizeBytes 256 } | Should Throw 'exists'
        Test-Path -LiteralPath $output | Should Be $false
    }
    It 'uses the offline WebView2 standalone source rather than the online bootstrapper' {
        $source = Get-Content (Join-Path $repoRoot 'deployments\shared\data\public.downloads.parameters.json') -Raw |
            ConvertFrom-Json
        $source.WebView2Runtime.DownloadUrl | Should Be 'https://go.microsoft.com/fwlink/?linkid=2124701'
        $source.WebView2Runtime.DestinationFileName | Should Be 'WebView2.exe'
    }
}

Describe 'Manual approved transfer release workflow' {
    It 'defaults WebRTC to enabled and forwards explicit enabled or disabled selections' {
        $workflow = Get-Content -LiteralPath $workflowPath -Raw
        $workflow | Should Match 'include_webrtc:\s+description:[^\r\n]+\s+type: boolean\s+default: true'
        $block = [regex]::Matches($workflow, '(?m)^        run: \|\r?\n((?:          .*(?:\r?\n|$))+)')[2]
        $text = $block.Groups[1].Value -replace '(?m)^          ', ''
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
        $assignment = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -eq '$arguments'
        }, $true)
        $expression = [scriptblock]::Create($assignment.Right.Extent.Text)
        $names = @('INCLUDE_WEBRTC', 'RUNNER_TEMP', 'SOURCE_REVISION')
        $original = @{}
        foreach ($name in $names) { $original[$name] = [Environment]::GetEnvironmentVariable($name) }
        try {
            $env:RUNNER_TEMP = $TestDrive
            $env:SOURCE_REVISION = 'test-commit'
            foreach ($selection in @('true', 'false')) {
                $env:INCLUDE_WEBRTC = $selection
                $arguments = & $expression
                $arguments.IncludeWebRtc | Should Be ($selection -eq 'true')
            }
        } finally {
            foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $original[$name]) }
        }
    }

    It 'uses manual dispatch, explicit approval, protected environment, and immutable source' {
        $workflow = Get-Content -LiteralPath $workflowPath -Raw
        $workflow | Should Match 'workflow_dispatch:'
        $workflow | Should Not Match '(?m)^  (release|push|pull_request):'
        $workflow | Should Match "REDISTRIBUTION_APPROVED -ne 'true'"
        $workflow | Should Match 'environment: airgap-artifact-publication'
        $workflow | Should Match 'ref: \$\{\{ steps.release.outputs.sha \}\}'
        $workflow | Should Match 'persist-credentials: false'
        $workflow | Should Not Match '--clobber'
        $workflow | Should Match 'uses: actions/checkout@[a-f0-9]{40}'
        $workflow | Should Match '\$result.ReleaseFiles'
        $workflow | Should Match 'gh release upload \$env:RELEASE_TAG @assets'
        $workflow | Should Match 'Length -ge 2GB'
    }
    It 'has parseable PowerShell blocks without inline expression injection' {
        $workflow = Get-Content -LiteralPath $workflowPath -Raw
        $blocks = @([regex]::Matches($workflow, '(?m)^        run: \|\r?\n((?:          .*(?:\r?\n|$))+)'))
        $blocks.Count | Should Be 4
        foreach ($block in $blocks) {
            $text = $block.Groups[1].Value -replace '(?m)^          ', ''
            $text | Should Not Match '\$\{\{'
            $tokens=$null; $errors=$null
            [void][Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
            $errors.Count | Should Be 0
        }
    }
    It 'executes the approval gate and rejects draft or failed release lookups without real GitHub calls' {
        $workflow = Get-Content -LiteralPath $workflowPath -Raw
        $block = [regex]::Matches($workflow, '(?m)^        run: \|\r?\n((?:          .*(?:\r?\n|$))+)')[0]
        $gate = [scriptblock]::Create(($block.Groups[1].Value -replace '(?m)^          ', ''))
        $names = @('REDISTRIBUTION_APPROVED','RELEASE_TAG','GITHUB_REPOSITORY','GITHUB_OUTPUT')
        $original = @{}
        foreach ($name in $names) { $original[$name] = [Environment]::GetEnvironmentVariable($name) }
        $originalExit = $global:LASTEXITCODE
        $global:airgapGate = @{Calls=0; Draft=$false; Fail=$false}
        function gh {
            param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
            $global:airgapGate.Calls++
            $global:LASTEXITCODE = if ($global:airgapGate.Fail) {1} else {0}
            if ($Arguments[0] -eq 'release') {
                @{isDraft=$global:airgapGate.Draft;tagName=$env:RELEASE_TAG} | ConvertTo-Json -Compress
            } else { '0123456789012345678901234567890123456789' }
        }
        try {
            $env:RELEASE_TAG='tag-with-literal-input'
            $env:GITHUB_REPOSITORY='test/repository'
            $env:GITHUB_OUTPUT=Join-Path $TestDrive 'gate-output.txt'
            $env:REDISTRIBUTION_APPROVED='false'
            { & $gate } | Should Throw 'approval'
            $global:airgapGate.Calls | Should Be 0
            $env:REDISTRIBUTION_APPROVED='true'
            $global:airgapGate.Draft=$true
            { & $gate } | Should Throw 'published'
            $global:airgapGate.Draft=$false
            $global:airgapGate.Fail=$true
            { & $gate } | Should Throw 'lookup failed'
            $global:airgapGate.Fail=$false
            & $gate
            (Get-Content $env:GITHUB_OUTPUT -Raw).Trim() |
                Should Be 'sha=0123456789012345678901234567890123456789'
        } finally {
            foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name,$original[$name]) }
            $global:LASTEXITCODE=$originalExit
            Remove-Variable airgapGate -Scope Global
        }
    }
    It 'uploads only the returned release assets and rejects oversized files without GitHub writes' {
        $workflow = Get-Content -LiteralPath $workflowPath -Raw
        $block = [regex]::Matches($workflow, '(?m)^        run: \|\r?\n((?:          .*(?:\r?\n|$))+)')[3]
        $upload = [scriptblock]::Create(($block.Groups[1].Value -replace '(?m)^          ', ''))
        $originalTemp = $env:RUNNER_TEMP
        $originalExit = $global:LASTEXITCODE
        $global:airgapUpload = @()
        function gh {
            param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
            $global:airgapUpload = $Arguments
            $global:LASTEXITCODE = 0
        }
        try {
            $env:RUNNER_TEMP = Join-Path $TestDrive 'release-assets'
            [IO.Directory]::CreateDirectory($env:RUNNER_TEMP) | Out-Null
            $assets = @('bundle.zip.part001','bundle.zip.part002','bundle.zip.parts.json','bundle.zip.sha256') |
                ForEach-Object { Join-Path $env:RUNNER_TEMP $_ }
            foreach ($path in $assets) { Set-Content -LiteralPath $path -Value 'test asset' }
            $assets | ConvertTo-Json | Set-Content (Join-Path $env:RUNNER_TEMP 'airgap-release-files.json')
            & $upload
            foreach ($path in $assets) { $global:airgapUpload | Should Contain $path }
            $global:airgapUpload | Should Not Contain (Join-Path $env:RUNNER_TEMP 'bundle.zip')
            Mock Get-Item { [pscustomobject]@{Length=2GB} } -ParameterFilter {
                $LiteralPath -like '*bundle.zip.part001'
            }
            $global:airgapUpload = @()
            { & $upload } | Should Throw '2 GiB'
            $global:airgapUpload.Count | Should Be 0
        } finally {
            $env:RUNNER_TEMP = $originalTemp
            $global:LASTEXITCODE = $originalExit
            Remove-Variable airgapUpload -Scope Global
        }
    }
}
