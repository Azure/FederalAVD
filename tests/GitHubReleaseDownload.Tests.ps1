BeforeAll {
    $path = Join-Path (Split-Path -Parent $PSScriptRoot) 'deployments\Update-ImageArtifacts.ps1'
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
    $definition = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-GitHubAssetRelease'
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
    $singleDownloadClause = @(
        $ast.FindAll({ param($node) $node -is [Management.Automation.Language.IfStatementAst] }, $true) |
            ForEach-Object { $_.Clauses } |
            Where-Object { $_.Item1.Extent.Text -eq "(`$DownloadUrl -ne '') -and (`$null -ne `$DownloadUrl)" }
    )
    if ($singleDownloadClause.Count -ne 1) { throw 'Expected exactly one single-file download branch.' }
    $blockText = $singleDownloadClause[0].Item2.Extent.Text
    $singleDownloadBlock = [scriptblock]::Create($blockText.Substring(1, $blockText.Length - 2))
    function Get-InternetFile {
        [CmdletBinding()] param ([uri]$Url, [string]$OutputDirectory, [string]$OutputFileName)
        throw 'Unexpected actual download.'
    }
    function New-TestRelease {
        param([string]$Tag, [string[]]$Names, [string]$Published = '2026-11-01T00:00:00Z')
        [pscustomobject]@{
            tag_name = $Tag
            published_at = $Published
            prerelease = $false
            draft = $false
            assets = @($Names | ForEach-Object {
                [pscustomobject]@{
                    name = $_
                    browser_download_url = "https://github.com/example/app/releases/download/$Tag/$_"
                    digest = 'sha256:example'
                }

            })
        }
    }
}

Describe 'GitHub release asset selection' {
    BeforeEach {
        $cache = @{}
        $latest = New-TestRelease v7.7.0 @('PowerShell-7.7.0-win-x64.zip') '2026-11-10T00:00:00Z'
        $older = New-TestRelease v7.6.10 @('PowerShell-7.6.10-win-x64.msi') '2026-11-09T00:00:00Z'
        $history = @($latest, $older)
        Mock Invoke-RestMethod {
            param($Uri)
            if ($Uri -eq 'https://api.github.com/repos/example/app/releases/latest') { return $latest }
            if ($Uri -eq 'https://api.github.com/repos/example/app/releases?per_page=100') {
                Write-Output -NoEnumerate $history
                return
            }
            throw "Unexpected URI: $Uri"
        }
    }

    It 'uses the latest release without fetching history when all assets exist' {
        $result = Get-GitHubAssetRelease example/app '*win-x64.zip' Example $cache
        $result.tag_name | Should -Be v7.7.0
        $result.assets[0].browser_download_url | Should -Be 'https://github.com/example/app/releases/download/v7.7.0/PowerShell-7.7.0-win-x64.zip'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }

    It 'selects the most recently published stable MSI release and warns' {
        $preview = New-TestRelease v7.8.0-preview @('PowerShell-preview-win-x64.msi') '2026-11-12T00:00:00Z'
        $preview.prerelease = $true
        $draft = New-TestRelease draft @('PowerShell-draft-win-x64.msi') '2026-11-11T00:00:00Z'
        $draft.draft = $true
        $oldest = New-TestRelease v7.4.22 @('PowerShell-7.4.22-win-x64.msi') '2026-11-08T00:00:00Z'
        $history = @($oldest, $preview, $draft, $latest, $older)
        $result = Get-GitHubAssetRelease example/app '*win-x64.msi' PowerShell7 $cache -WarningVariable warnings -WarningAction SilentlyContinue
        $result.tag_name | Should -Be v7.6.10
        $result.assets[0].name | Should -Be 'PowerShell-7.6.10-win-x64.msi'
        $warnings.Count | Should -Be 2
        "$($warnings[0])" | Should -Match "v7.7.0.*missing.*win-x64.msi"
        "$($warnings[1])" | Should -Match "Using GitHub release 'v7.6.10'.*instead of latest 'v7.7.0'"
    }

    It 'resolves a grouped download entirely from one complete release' {
        $latest = New-TestRelease v3 @('app.msixbundle', 'dependencies.zip')
        $partial = New-TestRelease v2 @('license.xml') '2026-10-31T00:00:00Z'
        $complete = New-TestRelease v1 @('app.msixbundle', 'dependencies.zip', 'license.xml') '2026-10-30T00:00:00Z'
        $history = @($latest, $partial, $complete)
        $result = Get-GitHubAssetRelease example/app @('*.msixbundle', 'dependencies.zip', '*license.xml') Example $cache -WarningAction SilentlyContinue
        $result.tag_name | Should -Be v1
        $result.assets.Count | Should -Be 3
    }

    It 'does not combine assets from incomplete releases' {
        $latest = New-TestRelease v2 @('app.msixbundle')
        $history = @($latest, (New-TestRelease v1 @('license.xml')))
        { Get-GitHubAssetRelease example/app @('*.msixbundle', '*.xml') Example $cache -WarningAction SilentlyContinue } |
            Should -Throw '*No stable GitHub release*within the 100 most recent releases*'
    }

    It 'rejects ambiguous matches without falling back' {
        $latest = New-TestRelease v2 @('one-win-x64.msi', 'two-win-x64.msi')
        { Get-GitHubAssetRelease example/app '*win-x64.msi' Example $cache } | Should -Throw '*found 2*'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }

    It 'rejects ambiguous matches in a fallback release' {
        $history = @((New-TestRelease v1 @('one-win-x64.msi', 'two-win-x64.msi')))
        { Get-GitHubAssetRelease example/app '*win-x64.msi' Example $cache -WarningAction SilentlyContinue } |
            Should -Throw "*release 'v1'; found 2*"
    }

    It 'fails explicitly when no stable release contains the asset' {
        $history = @($latest)
        { Get-GitHubAssetRelease example/app '*win-x64.msi' Example $cache -WarningAction SilentlyContinue } |
            Should -Throw '*No stable GitHub release*win-x64.msi*'
    }

    It 'reuses metadata without forcing later entries onto an earlier fallback release' {
        $msi = Get-GitHubAssetRelease example/app '*win-x64.msi' Example $cache -WarningAction SilentlyContinue
        $zip = Get-GitHubAssetRelease example/app '*win-x64.zip' Example $cache
        $again = Get-GitHubAssetRelease example/app '*win-x64.msi' Example $cache -WarningAction SilentlyContinue
        $msi.tag_name | Should -Be v7.6.10
        $zip.tag_name | Should -Be v7.7.0
        $again.tag_name | Should -Be v7.6.10
        Should -Invoke Invoke-RestMethod -Times 2 -Exactly
    }

    It 'propagates GitHub API errors instead of treating them as missing assets' {
        Mock Invoke-RestMethod { throw 'GitHub API rate limit exceeded' }
        { Get-GitHubAssetRelease example/app '*win-x64.msi' Example $cache } | Should -Throw '*rate limit exceeded*'
    }

    It 'propagates release-history errors instead of selecting a default' {
        Mock Invoke-RestMethod { throw 'GitHub history unavailable' } -ParameterFilter { $Uri -like '*per_page=100' }
        { Get-GitHubAssetRelease example/app '*win-x64.msi' Example $cache -WarningAction SilentlyContinue } |
            Should -Throw '*GitHub history unavailable*'
    }
}

Describe 'Existing single-file GitHub downloader with a ZIP payload' {
    BeforeEach {
        $SoftwareName = 'PowerShell7'
        $DownloadUrl = 'https://github.com/PowerShell/PowerShell/releases/download/v7.7.0/PowerShell-7.7.0-win-x64.zip'
        $DownloadDir = Join-Path $TestDrive "downloads-$([guid]::NewGuid())"
        $ArtifactsDir = Join-Path $TestDrive "artifacts-$([guid]::NewGuid())"
        $CustomerArtifactsDir = Join-Path $TestDrive "customer-$([guid]::NewGuid())"
        $CopyDownloadsToCustomerArtifacts = $true
        $FileVersionInfoFile = Join-Path $TestDrive 'versions.txt'
        $Download = [pscustomobject]@{
            DestinationFileName = 'PowerShell7.zip'
            DestinationFolders = @('Microsoft-PowerShell-7')
        }
        $script:sourceZip = Join-Path $TestDrive 'source.zip'
        Set-Content -LiteralPath $script:sourceZip -Value 'ZIP content'
        foreach ($root in @($ArtifactsDir, $CustomerArtifactsDir)) {
            $destination = Join-Path $root 'Microsoft-PowerShell-7'
            New-Item -Path $destination -ItemType Directory -Force | Out-Null
            Set-Content (Join-Path $destination 'PowerShell7.msi') -Value 'old MSI'
            Set-Content (Join-Path $destination 'PowerShell-7.6.10-win-x64.zip') -Value 'old ZIP'
            Set-Content (Join-Path $destination 'Deploy-PowerShell7.ps1') -Value 'authored script'
            Set-Content (Join-Path $destination 'README.md') -Value 'authored documentation'
        }
        Mock Get-InternetFile {
            $path = Join-Path $OutputDirectory 'PowerShell-7.7.0-win-x64.zip'
            Copy-Item -LiteralPath $script:sourceZip -Destination $path
            $path
        }
    }

    It 'renames and copies the ZIP to both destinations without deleting existing files' {
        $null = & $singleDownloadBlock
        foreach ($root in @($ArtifactsDir, $CustomerArtifactsDir)) {
            $destination = Join-Path $root 'Microsoft-PowerShell-7'
            Test-Path (Join-Path $destination 'PowerShell7.msi') | Should -BeTrue
            Test-Path (Join-Path $destination 'PowerShell-7.6.10-win-x64.zip') | Should -BeTrue
            Test-Path (Join-Path $destination 'Deploy-PowerShell7.ps1') | Should -BeTrue
            Test-Path (Join-Path $destination 'README.md') | Should -BeTrue
            (Get-FileHash (Join-Path $destination 'PowerShell7.zip')).Hash |
                Should -Be (Get-FileHash $script:sourceZip).Hash
        }
    }

    It 'does not copy the ZIP to customer artifacts unless requested' {
        $CopyDownloadsToCustomerArtifacts = $false
        $null = & $singleDownloadBlock
        Test-Path (Join-Path $ArtifactsDir 'Microsoft-PowerShell-7\PowerShell7.zip') | Should -BeTrue
        Test-Path (Join-Path $CustomerArtifactsDir 'Microsoft-PowerShell-7\PowerShell7.zip') | Should -BeFalse
    }
}
