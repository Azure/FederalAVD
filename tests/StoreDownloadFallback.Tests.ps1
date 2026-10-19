$path = Join-Path (Split-Path -Parent $PSScriptRoot) 'deployments\Update-ImageArtifacts.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
foreach ($name in @('Get-MicrosoftStorePackageUrl', 'Save-MicrosoftStorePackages', 'Invoke-WingetOrStoreDownload', 'Optimize-SharedDependencies')) {
    $definition = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}

function winget { throw 'Tests must mock WinGet; the real executable must never run.' }

Describe 'Automatic Store fallback eligibility' {
    It 'limits fallback to connected x64-compatible preserve-layout Store product IDs' {
        $assignment = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -eq '$StoreFallbackEligible'
        }, $true)
        $evaluate = [scriptblock]::Create(
            'param($downloadsParametersPrefix, $PreserveLayout, $Download, $WingetSource, $WingetArch)' +
            "`n" + $assignment.Right.Extent.Text
        )
        (& $evaluate public $true @{ WingetId = '9N4WGH0Z6VHQ' } msstore x64) | Should Be $true
        (& $evaluate public $true @{ WingetId = '9N4WGH0Z6VHQ' } msstore neutral) | Should Be $true
        (& $evaluate public $true @{ WingetId = '9N4WGH0Z6VHQ' } winget x64) | Should Be $false
        (& $evaluate public $false @{ WingetId = '9N4WGH0Z6VHQ' } msstore x64) | Should Be $false
        (& $evaluate public $true @{ WingetId = 'Microsoft.PowerShell' } msstore x64) | Should Be $false
        (& $evaluate public $true @{ WingetId = '9N4WGH0Z6VHQ' } msstore arm64) | Should Be $false
        (& $evaluate secret $true @{ WingetId = '9N4WGH0Z6VHQ' } msstore x64) | Should Be $false
        (& $evaluate topsecret $true @{ WingetId = '9N4WGH0Z6VHQ' } msstore x64) | Should Be $false
    }
}

Describe 'Microsoft Store fallback package staging' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -Path $root -ItemType Directory -Force | Out-Null
        $global:FederalAvdStoreFallbackTest = @{
            Root = $root
            Output = Join-Path $root 'App'
            Packages = @()
            Downloads = @()
            Corrupt = $false
        }
        New-Item -Path $global:FederalAvdStoreFallbackTest.Output -ItemType Directory -Force | Out-Null
        Mock Get-MicrosoftStorePackageUrl {
            param($ProductId, $Architecture)
            if ($ProductId -ne '9N4WGH0Z6VHQ' -or $Architecture -ne 'All') {
                throw 'Unexpected product ID or architecture passed to the resolver.'
            }
            $global:FederalAvdStoreFallbackTest.Packages
        }
        function New-TestStoreLink {
            param($Name, $Version, $Architecture, [bool]$Main, [bool]$Encrypted = $false)
            $extension = if ($Encrypted) { '.emsixbundle' } elseif ($Main) { '.msixbundle' } else { '.appx' }
            [pscustomobject]@{
                PackageMoniker = "${Name}_${Version}_${Architecture}_~_abcdefghijklm"
                IsMainPackage = $Main
                IsEncrypted = $Encrypted
                FileName = "$([guid]::NewGuid())$extension"
                Url = "https://tlu.dl.delivery.mp.microsoft.com/${Name}/${Version}/${Architecture}"
                Size = 4
                DigestAlgorithm = 'SHA1'
                Digest = [Convert]::ToBase64String([Security.Cryptography.SHA1]::Create().ComputeHash([byte[]](1, 2, 3, 4)))
                Sha256Digest = [Convert]::ToBase64String([Security.Cryptography.SHA256]::Create().ComputeHash([byte[]](1, 2, 3, 4)))
            }
        }
        $global:FederalAvdStoreFallbackTest.Packages = @(
            New-TestStoreLink 'Example.App' '1.0.0.0' neutral $true
            New-TestStoreLink 'Example.App' '2.0.0.0' neutral $true
            New-TestStoreLink 'Example.App' '9.0.0.0' arm64 $true
            New-TestStoreLink 'Example.Framework' '1.0.0.0' x64 $false
            New-TestStoreLink 'Example.Framework' '2.0.0.0' x64 $false
            New-TestStoreLink 'Example.Framework' '2.0.0.0' x86 $false
            New-TestStoreLink 'Example.Framework' '2.0.0.0' neutral $false
            New-TestStoreLink 'Example.Framework' '2.0.0.0' arm64 $false
        )
        Mock Invoke-WebRequest {
            param($Uri, $OutFile)
            $global:FederalAvdStoreFallbackTest.Downloads += [uri]$Uri
            $bytes = if ($global:FederalAvdStoreFallbackTest.Corrupt) { [byte[]](4, 3, 2, 1) } else { [byte[]](1, 2, 3, 4) }
            [IO.File]::WriteAllBytes($OutFile, $bytes)
        }
    }

    AfterAll {
        Remove-Variable -Name FederalAvdStoreFallbackTest -Scope Global
    }

    It 'stages only the newest main package and newest x86/x64/neutral dependencies with identity filenames' {
        Save-MicrosoftStorePackages -ProductId 9N4WGH0Z6VHQ `
            -OutputDirectory $global:FederalAvdStoreFallbackTest.Output
        $main = @(Get-ChildItem -LiteralPath $global:FederalAvdStoreFallbackTest.Output -File)
        $main.Count | Should Be 1
        $main[0].Name | Should Be 'Example.App_2.0.0.0_neutral_~_abcdefghijklm.msixbundle'
        $dependencies = @(Get-ChildItem (Join-Path $global:FederalAvdStoreFallbackTest.Output 'Dependencies') -Recurse -File)
        $dependencies.Count | Should Be 3
        @($dependencies | Where-Object Name -match 'arm|1\.0\.0\.0').Count | Should Be 0
        $global:FederalAvdStoreFallbackTest.Downloads.Count | Should Be 4
        @($global:FederalAvdStoreFallbackTest.Downloads | Where-Object Scheme -ne https).Count | Should Be 0
        Optimize-SharedDependencies -ParentDir $global:FederalAvdStoreFallbackTest.Root | Out-Null
        @(Get-ChildItem (Join-Path $global:FederalAvdStoreFallbackTest.Root 'SharedDependencies') -File).Count | Should Be 3
    }

    It 'fails instead of falling back to an older unencrypted main version' {
        $global:FederalAvdStoreFallbackTest.Packages += New-TestStoreLink 'Example.App' '3.0.0.0' neutral $true $true
        { Save-MicrosoftStorePackages -ProductId 9N4WGH0Z6VHQ `
            -OutputDirectory $global:FederalAvdStoreFallbackTest.Output } |
            Should Throw 'newest Store package'
        $global:FederalAvdStoreFallbackTest.Downloads.Count | Should Be 0
    }

    It 'does not mistake a same-family resource package for the main app' {
        $resource = New-TestStoreLink 'Example.App' '99.0.0.0' x64 $true
        $resource.PackageMoniker = $resource.PackageMoniker.Replace('_~_', '_en-us_')
        $global:FederalAvdStoreFallbackTest.Packages += $resource
        Save-MicrosoftStorePackages -ProductId 9N4WGH0Z6VHQ `
            -OutputDirectory $global:FederalAvdStoreFallbackTest.Output
        @(Get-ChildItem -LiteralPath $global:FederalAvdStoreFallbackTest.Output -File)[0].Name |
            Should Be 'Example.App_2.0.0.0_neutral_~_abcdefghijklm.msixbundle'
    }

    It 'fails explicitly when the newest required dependency is encrypted' {
        $global:FederalAvdStoreFallbackTest.Packages += New-TestStoreLink 'Example.Framework' '3.0.0.0' x64 $false $true
        { Save-MicrosoftStorePackages -ProductId 9N4WGH0Z6VHQ `
            -OutputDirectory $global:FederalAvdStoreFallbackTest.Output } |
            Should Throw 'newest Store dependency'
    }

    It 'checks SHA256 even when a legacy SHA1 digest is also supplied and removes failed partial files' {
        $global:FederalAvdStoreFallbackTest.Corrupt = $true
        { Save-MicrosoftStorePackages -ProductId 9N4WGH0Z6VHQ `
            -OutputDirectory $global:FederalAvdStoreFallbackTest.Output } |
            Should Throw 'SHA256 mismatch'
        @(Get-ChildItem -LiteralPath $global:FederalAvdStoreFallbackTest.Output -Recurse -File).Count | Should Be 0
    }

    It 'allows Microsoft-provided HTTP only when SHA256 can verify the package' {
        $global:FederalAvdStoreFallbackTest.Packages[1].Url = 'http://tlu.dl.delivery.mp.microsoft.com/package'
        Save-MicrosoftStorePackages -ProductId 9N4WGH0Z6VHQ `
            -OutputDirectory $global:FederalAvdStoreFallbackTest.Output
        @($global:FederalAvdStoreFallbackTest.Downloads | Where-Object Scheme -eq http).Count | Should Be 1
    }

    It 'rejects HTTP packages without SHA256 instead of accepting only a SHA1 digest' {
        $global:FederalAvdStoreFallbackTest.Packages[1].Url = 'http://tlu.dl.delivery.mp.microsoft.com/package'
        $global:FederalAvdStoreFallbackTest.Packages[1].Sha256Digest = ''
        { Save-MicrosoftStorePackages -ProductId 9N4WGH0Z6VHQ `
            -OutputDirectory $global:FederalAvdStoreFallbackTest.Output } |
            Should Throw 'requires a SHA256 digest'
        $global:FederalAvdStoreFallbackTest.Downloads.Count | Should Be 0
    }

    It 'can verify a legacy SHA1 digest for a Microsoft-provided HTTPS URL' {
        $global:FederalAvdStoreFallbackTest.Packages[1].Sha256Digest = ''
        Save-MicrosoftStorePackages -ProductId 9N4WGH0Z6VHQ `
            -OutputDirectory $global:FederalAvdStoreFallbackTest.Output
        @(Get-ChildItem -LiteralPath $global:FederalAvdStoreFallbackTest.Output -File).Count | Should Be 1
    }

    It 'rejects a byte-size mismatch before accepting the downloaded file' {
        $global:FederalAvdStoreFallbackTest.Packages[1].Size = 100
        { Save-MicrosoftStorePackages -ProductId 9N4WGH0Z6VHQ `
            -OutputDirectory $global:FederalAvdStoreFallbackTest.Output } |
            Should Throw 'byte-size mismatch'
    }

    It 'does not stage dependencies as the main app when the catalog family is missing' {
        foreach ($package in $global:FederalAvdStoreFallbackTest.Packages) { $package.IsMainPackage = $false }
        { Save-MicrosoftStorePackages -ProductId 9N4WGH0Z6VHQ `
            -OutputDirectory $global:FederalAvdStoreFallbackTest.Output } |
            Should Throw 'no identifiable x64/neutral main package'
    }

    It 'packages an existing-style customer entry end to end and persists deduplicated offline files' {
        $repo = Join-Path $global:FederalAvdStoreFallbackTest.Root 'repo'
        $deployments = Join-Path $repo 'deployments'
        $customer = Join-Path $repo 'customer'
        foreach ($relative in @('deployments\shared\data', 'deployments\shared\artifacts',
            'customer\parameters\imageManagement', 'customer\artifacts\BuiltIn-UWP-Apps', 'temp')) {
            New-Item -Path (Join-Path $repo $relative) -ItemType Directory -Force | Out-Null
        }
        $resolverDefinition = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-MicrosoftStorePackageUrl'
        }, $true)
        $resolverStub = @'
function Get-MicrosoftStorePackageUrl {
    param($ProductId, $Architecture)
    if ($ProductId -ne '9N4WGH0Z6VHQ' -or $Architecture -ne 'All') {
        throw 'Unexpected product ID or architecture passed to the inline resolver.'
    }
    $global:FederalAvdStoreFallbackTest.Packages
}
'@
        (Get-Content -LiteralPath $path -Raw).Replace($resolverDefinition.Extent.Text, $resolverStub) |
            Set-Content -LiteralPath (Join-Path $deployments 'Update-ImageArtifacts.ps1') -Encoding ASCII
        '{}' | Set-Content -LiteralPath (Join-Path $deployments 'shared\data\public.downloads.parameters.json') -Encoding ASCII
        'Offline artifact fixture' | Set-Content -LiteralPath (Join-Path $customer 'artifacts\BuiltIn-UWP-Apps\fixture.txt') -Encoding ASCII
        @{
            HEVCVideoExtension = @{
                WingetId = '9N4WGH0Z6VHQ'
                WingetPreserveLayout = $true
                DestinationFolders = @('BuiltIn-UWP-Apps\HEVCVideoExtension')
            }
        } | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath (Join-Path $customer 'parameters\imageManagement\downloads.json') -Encoding ASCII
        Mock winget { $global:LASTEXITCODE = 1; 'Forced WinGet failure for validation.' }
        Mock Start-Job { }
        $originalTemp = $env:TEMP
        try {
            $env:TEMP = Join-Path $repo 'temp'
            & (Join-Path $deployments 'Update-ImageArtifacts.ps1') -PackageOnly `
                -OutputPath (Join-Path $repo 'export') -CustomerRootPath $customer `
                -TempDir $env:TEMP -CopyDownloadsToCustomerArtifacts | Out-Null
        }
        finally {
            $env:TEMP = $originalTemp
        }
        Test-Path (Join-Path $repo 'export\BuiltIn-UWP-Apps.zip') | Should Be $true
        Get-Content -LiteralPath (Join-Path $repo 'export\uploadedFileVersionInfo.txt') -Raw |
            Should Match 'DownloadProvider = MicrosoftStore'
        @(Get-ChildItem (Join-Path $customer 'artifacts\BuiltIn-UWP-Apps\SharedDependencies') -File).Count | Should Be 3
        Test-Path (Join-Path $customer 'artifacts\BuiltIn-UWP-Apps\HEVCVideoExtension\Dependencies') | Should Be $false
        $archive = [IO.Compression.ZipFile]::OpenRead((Join-Path $repo 'export\BuiltIn-UWP-Apps.zip'))
        try {
            ($archive.Entries.FullName -join "`n") | Should Match 'Example.App_2.0.0.0'
            ($archive.Entries.FullName -join "`n") | Should Match 'SharedDependencies'
            ($archive.Entries.FullName -join "`n") | Should Not Match 'Example.App_1.0.0.0'
        }
        finally {
            $archive.Dispose()
        }
    }
}

Describe 'WinGet-first download routing' {
    BeforeEach {
        $global:FederalAvdStoreRoutingTest = @{
            Root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
            ExitCode = 0
            HasWinGet = $true
            HasPackage = $true
            FailFallback = $false
        }
        New-Item -Path $global:FederalAvdStoreRoutingTest.Root -ItemType Directory -Force | Out-Null
        Mock winget {
            $global:LASTEXITCODE = $global:FederalAvdStoreRoutingTest.ExitCode
            if ($global:FederalAvdStoreRoutingTest.HasPackage) {
                Set-Content -LiteralPath (Join-Path $global:FederalAvdStoreRoutingTest.Root 'winget.msix') -Value 'test' -Encoding ASCII
            }
            'Found test app'
        }
        Mock Save-MicrosoftStorePackages {
            if ($global:FederalAvdStoreRoutingTest.FailFallback) { throw 'Store fallback failed.' }
            Set-Content -LiteralPath (Join-Path $OutputDirectory 'store.msix') -Value 'test' -Encoding ASCII
        }
        Mock Get-Command {
            if ($global:FederalAvdStoreRoutingTest.HasWinGet) { [pscustomobject]@{ Name = 'winget' } }
        } -ParameterFilter { $Name -eq 'winget' }
    }

    AfterAll {
        Remove-Variable -Name FederalAvdStoreRoutingTest -Scope Global
    }

    It 'does not call the Store resolver when WinGet succeeds' {
        $result = Invoke-WingetOrStoreDownload -ProductId 9N4WGH0Z6VHQ -WingetArguments @('download') `
            -OutputDirectory $global:FederalAvdStoreRoutingTest.Root -AllowStoreFallback $true
        $result.Source | Should Be WinGet
        Assert-MockCalled Save-MicrosoftStorePackages -Times 0 -Exactly -Scope It
    }

    It 'reuses the same product ID and discards partial WinGet files after a nonzero exit' {
        $global:FederalAvdStoreRoutingTest.ExitCode = 1
        $result = Invoke-WingetOrStoreDownload -ProductId 9N4WGH0Z6VHQ -WingetArguments @('download') `
            -OutputDirectory $global:FederalAvdStoreRoutingTest.Root -AllowStoreFallback $true
        $result.Source | Should Be MicrosoftStore
        Test-Path (Join-Path $global:FederalAvdStoreRoutingTest.Root 'winget.msix') | Should Be $false
        Assert-MockCalled Save-MicrosoftStorePackages -Times 1 -Exactly -Scope It -ParameterFilter { $ProductId -eq '9N4WGH0Z6VHQ' }
    }

    It 'uses the Store fallback if WinGet remains unavailable after registration' {
        $global:FederalAvdStoreRoutingTest.HasWinGet = $false
        $result = Invoke-WingetOrStoreDownload -ProductId 9N4WGH0Z6VHQ `
            -OutputDirectory $global:FederalAvdStoreRoutingTest.Root -AllowStoreFallback $true
        $result.Source | Should Be MicrosoftStore
        Assert-MockCalled winget -Times 0 -Exactly -Scope It
    }

    It 'treats a zero WinGet exit without a main package as a failure for eligible Store entries' {
        $global:FederalAvdStoreRoutingTest.HasPackage = $false
        $result = Invoke-WingetOrStoreDownload -ProductId 9N4WGH0Z6VHQ -WingetArguments @('download') `
            -OutputDirectory $global:FederalAvdStoreRoutingTest.Root -AllowStoreFallback $true
        $result.Source | Should Be MicrosoftStore
    }

    It 'does not fall back for ineligible entries' {
        $global:FederalAvdStoreRoutingTest.ExitCode = 1
        { Invoke-WingetOrStoreDownload -ProductId Microsoft.PowerShell -WingetArguments @('download') `
            -OutputDirectory $global:FederalAvdStoreRoutingTest.Root -AllowStoreFallback $false } |
            Should Throw 'exit code 1'
        Assert-MockCalled Save-MicrosoftStorePackages -Times 0 -Exactly -Scope It
    }

    It 'propagates fallback errors instead of reporting a successful download' {
        $global:FederalAvdStoreRoutingTest.ExitCode = 1
        $global:FederalAvdStoreRoutingTest.FailFallback = $true
        { Invoke-WingetOrStoreDownload -ProductId 9N4WGH0Z6VHQ -WingetArguments @('download') `
            -OutputDirectory $global:FederalAvdStoreRoutingTest.Root -AllowStoreFallback $true } |
            Should Throw 'Store fallback failed'
    }
}
