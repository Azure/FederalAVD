BeforeDiscovery {
    $msiCases = @(
        @{ Artifact = '7-Zip'; Script = 'Deploy-7-Zip.ps1'; Name = '*7-Zip*'; Publisher = '*'; NativeOnly = $true; ProductPattern = '^\{[0-9A-Fa-f-]{36}\}$' }
        @{ Artifact = 'Adobe-Acrobat-Reader-DC'; Script = 'Deploy-AdobeReaderDC.ps1'; Name = 'Adobe Acrobat*'; Publisher = 'Adobe*'; NativeOnly = $true; ProductPattern = '^\{AC76BA86-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$' }
        @{ Artifact = 'Google-Chrome-Enterprise'; Script = 'Deploy-GoogleChromeEnterprise.ps1'; Name = 'Google Chrome'; Publisher = 'Google*'; NativeOnly = $false; ProductPattern = '' }
        @{ Artifact = 'Microsoft-Edge-Enterprise'; Script = 'Deploy-MicrosoftEdgeEnterprise.ps1'; Name = 'Microsoft Edge'; Publisher = 'Microsoft*'; NativeOnly = $false; ProductPattern = '' }
        @{ Artifact = 'PuTTY'; Script = 'Deploy-PuTTY.ps1'; Name = 'PuTTY release *'; Publisher = 'Simon Tatham'; NativeOnly = $false; ProductPattern = '' }
        @{ Artifact = 'DoD-InstallRoot'; Script = 'Deploy-InstallRoot.ps1'; Name = '*InstallRoot*'; Publisher = '*'; NativeOnly = $false; ProductPattern = '^\{[0-9A-Fa-f-]{36}\}$' }
    )
    $discoveryCases = $msiCases + @(@{ Artifact = 'Microsoft-Power-BI-Desktop'; Script = 'Deploy-PowerBIDesktop.ps1' })
    $processCases = @(
        @{ Artifact = 'Adobe-Acrobat-Reader-DC'; Script = 'Deploy-AdobeReaderDC.ps1' }
        @{ Artifact = 'Git-for-Windows'; Script = 'Deploy-GitforWindows.ps1' }
        @{ Artifact = 'Microsoft-Power-BI-Desktop'; Script = 'Deploy-PowerBIDesktop.ps1' }
        @{ Artifact = 'Microsoft-VCRedistributable'; Script = 'Install-MicrosoftVCRedistributable.ps1' }
    )
}

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    function Get-TestArtifactAst {
        param([string]$Artifact, [string]$Script)
        $path = Join-Path $repoRoot "customer-examples\artifacts\$Artifact\$Script"
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
        if ($errors.Count) { throw ($errors | Out-String) }
        if (Get-Content -LiteralPath $path | Where-Object { $_ -match '[^\x00-\x7E]' }) {
            throw "Non-ASCII content in $path"
        }
        return $ast
    }
}

Describe 'Reusable application discovery: <Artifact>' -ForEach $discoveryCases {
    BeforeAll {
        $ast = Get-TestArtifactAst -Artifact $Artifact -Script $Script
        $definition = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-InstalledApplications'
        }, $false)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    BeforeEach {
        Mock Test-Path { $true }
        Mock Get-ChildItem {
            [pscustomobject]@{ PSPath = 'Registry::Editor'; PSChildName = '{00000000-0000-0000-0000-000000000001}' }
            [pscustomobject]@{ PSPath = 'Registry::Portable'; PSChildName = 'Example.Editor.Zip' }
            [pscustomobject]@{ PSPath = 'Registry::Other'; PSChildName = '{00000000-0000-0000-0000-000000000002}' }
            [pscustomobject]@{ PSPath = 'Registry::Bundle'; PSChildName = '{00000000-0000-0000-0000-000000000003}' }
        }
        Mock Get-ItemProperty {
            switch ($LiteralPath) {
                'Registry::Editor' { [pscustomobject]@{ DisplayName = 'Example Editor'; Publisher = 'Example Corporation'; WindowsInstaller = 1; QuietUninstallString = '"C:\Example\remove.exe" /quiet' } }
                'Registry::Portable' { [pscustomobject]@{ DisplayName = 'Example Editor Portable'; Publisher = 'Example Corporation' } }
                'Registry::Other' { [pscustomobject]@{ DisplayName = 'Other Application'; Publisher = 'Other Corporation'; WindowsInstaller = 1 } }
                'Registry::Bundle' { [pscustomobject]@{ DisplayName = 'Example Editor Bundle'; Publisher = 'Example Corporation'; BundleCachePath = 'C:\Example\bundle.exe'; QuietUninstallString = '"C:\Example\bundle.exe" /uninstall /quiet' } }
            }
        }
    }
    It 'discovers another product and returns its uninstall metadata' {
        $applications = @(Get-InstalledApplications -Name 'Example Editor*' -Publisher 'Example*' -RegistryPaths 'Registry::Custom')
        $applications.Count | Should -Be 3
        $applications[0].ProductCode | Should -Be '{00000000-0000-0000-0000-000000000001}'
        $applications[0].QuietUninstallString | Should -Be '"C:\Example\remove.exe" /quiet'
        $applications[1].ProductCode | Should -Be ''
        $applications[2].ProductCode | Should -Be ''
        $applications[2].WindowsInstaller | Should -BeFalse
        $applications[2].BundleCachePath | Should -Be 'C:\Example\bundle.exe'
        Should -Invoke Get-ChildItem -Times 1 -Exactly -ParameterFilter { $LiteralPath -eq 'Registry::Custom' }
    }
    It 'supports MSI-only discovery and a caller-provided ProductCode pattern' {
        $applications = @(Get-InstalledApplications -Name 'Example*' -WindowsInstaller -RegistryPaths 'Registry::Custom')
        $applications.Count | Should -Be 1
        $applications = @(Get-InstalledApplications -Name 'Example*' -WindowsInstaller `
            -ProductCodePattern '^\{00000000-0000-0000-0000-000000000001\}$' -RegistryPaths 'Registry::Custom')
        $applications.Count | Should -Be 1
        $applications[0].DisplayName | Should -Be 'Example Editor'
    }
    It 'does not classify a GUID-named EXE bundle as an MSI even when the ProductCode pattern matches' {
        $applications = @(Get-InstalledApplications -Name 'Example Editor Bundle' -WindowsInstaller -RegistryPaths 'Registry::Custom')
        $applications.Count | Should -Be 0
    }
    It 'does not require publisher metadata when no publisher filter was supplied' {
        Mock Get-ItemProperty { [pscustomobject]@{ DisplayName = 'Example Editor' } }
        @(Get-InstalledApplications -Name 'Example*' -RegistryPaths 'Registry::Custom').Count | Should -Be 4
        @(Get-InstalledApplications -Name 'Example*' -Publisher 'Example*' -RegistryPaths 'Registry::Custom').Count | Should -Be 0
    }
    It 'surfaces registry failures instead of reporting an absent application' {
        Mock Get-ItemProperty { throw 'Registry access denied' }
        { Get-InstalledApplications -Name 'Example*' } | Should -Throw '*Registry access denied*'
    }
}

Describe 'Reusable single-MSI removal and main selectors: <Artifact>' -ForEach $msiCases {
    BeforeAll {
        $ast = Get-TestArtifactAst -Artifact $Artifact -Script $Script
        $definitions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false))
        foreach ($definition in $definitions) {
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        $mainText = ($ast.EndBlock.Statements |
            Where-Object { $_ -isnot [Management.Automation.Language.FunctionDefinitionAst] } |
            ForEach-Object { $_.Extent.Text }) -join "`n"
        $mainBlock = [scriptblock]::Create($mainText)
    }
    BeforeEach {
        Mock Write-Log {}
        Mock New-Log {}
        Mock Invoke-MsiProcess { [pscustomobject]@{ ExitCode = 0 } }
        $caseName = $Name
        $casePublisher = $Publisher
        $caseProductPattern = $ProductPattern
        $applications = @([pscustomobject]@{
            DisplayName = 'Example Editor'
            ProductCode = '{00000000-0000-0000-0000-000000000001}'
        })
    }
    It 'keeps helper bodies independent of product state and product selectors' {
        foreach ($definition in $definitions | Where-Object Name -in @('Get-InstalledApplications', 'Remove-MsiApplications')) {
            $definition.Extent.Text | Should -Not -Match '\$(SoftwareName|PSScriptRoot|DownloadUrls)|\$env:'
            $definition.Extent.Text | Should -Not -Match 'Adobe|Amazon|Google|PuTTY|InstallRoot|7-Zip'
        }
    }
    It 'passes a different application and explicit timeout to the MSI executor' {
        Remove-MsiApplications -Applications $applications -TimeoutMs 123
        Should -Invoke Invoke-MsiProcess -Times 1 -Exactly -ParameterFilter {
            $ArgumentList -eq '/x {00000000-0000-0000-0000-000000000001} /qn /norestart' -and
            $TimeoutMs -eq 123 -and $Action -eq "'Example Editor' uninstaller"
        }
    }
    It 'honors caller-provided success codes and rejects other exit codes' {
        Mock Invoke-MsiProcess { [pscustomobject]@{ ExitCode = 1641 } }
        Remove-MsiApplications -Applications $applications -SuccessExitCodes @(0, 1641)
        { Remove-MsiApplications -Applications $applications } | Should -Throw '*exit code 1641*'
    }
    It 'preserves no-installation success and rejects ambiguity before running an uninstaller' {
        Remove-MsiApplications -Applications @()
        { Remove-MsiApplications -Applications @($applications[0], $applications[0]) } | Should -Throw '*Multiple MSI installations matched*'
        Should -Invoke Invoke-MsiProcess -Times 0
    }
    It 'rejects invalid ProductCodes before running an uninstaller' {
        $applications[0].ProductCode = 'not-an-msi'
        { Remove-MsiApplications -Applications $applications } | Should -Throw '*valid MSI ProductCode*'
        Should -Invoke Invoke-MsiProcess -Times 0
    }
    It 'passes the original product selectors and configurable success codes from the real main block' {
        Mock Get-InstalledApplications { @() }
        Mock Remove-MsiApplications {}
        $DeploymentType = 'Uninstall'
        $SuccessExitCodes = @(0, 1641)
        & $mainBlock
        Should -Invoke Get-InstalledApplications -Times 1 -Exactly -ParameterFilter {
            $Name -eq $caseName -and $WindowsInstaller
        }
        Should -Invoke Remove-MsiApplications -Times 1 -Exactly -ParameterFilter {
            ($SuccessExitCodes -join ',') -eq '0,1641'
        }
    }
    It 'retains publisher, registry-root, and ProductCode restrictions in main' {
        Mock Get-InstalledApplications { @() }
        Mock Remove-MsiApplications {}
        $DeploymentType = 'Uninstall'
        $SuccessExitCodes = @(0, 3010)
        & $mainBlock
        if ($casePublisher -ne '*') {
            Should -Invoke Get-InstalledApplications -Times 1 -ParameterFilter { $Publisher -eq $casePublisher }
        }
        if ($NativeOnly) {
            Should -Invoke Get-InstalledApplications -Times 1 -ParameterFilter {
                $RegistryPaths.Count -eq 1 -and $RegistryPaths[0] -notlike '*Wow6432Node*'
            }
        }
        if ($caseProductPattern) {
            Should -Invoke Get-InstalledApplications -Times 1 -ParameterFilter { $ProductCodePattern -eq $caseProductPattern }
        }
    }
}

Describe 'Reusable bounded process execution: <Artifact>' -ForEach $processCases {
    BeforeAll {
        $ast = Get-TestArtifactAst -Artifact $Artifact -Script $Script
        $definition = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-ApplicationProcess'
        }, $false)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    BeforeEach {
        $script:process = [pscustomobject]@{ ExitCode = 42; Finished = $true; Killed = $false; Timeout = $null }
        $script:process | Add-Member ScriptMethod WaitForExit { param($timeout) $this.Timeout = $timeout; return $this.Finished }
        $script:process | Add-Member ScriptMethod Kill { $this.Killed = $true }
        Mock Start-Process { $script:process }
    }
    It 'uses the supplied executable, arguments, timeout, action, and success codes' {
        $result = Invoke-ApplicationProcess -FilePath 'C:\Example\editor.exe' -ArgumentList '/silent' `
            -Action 'Installing Example Editor' -SuccessExitCodes @(42) -TimeoutMs 123
        $result.ExitCode | Should -Be 42
        $result.Timeout | Should -Be 123
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\Example\editor.exe' -and $ArgumentList -eq '/silent' -and $PassThru -and $ErrorAction -eq 'Stop'
        }
        $definition.Extent.Text | Should -Not -Match '\$(SoftwareName|PSScriptRoot|DownloadUrls)|\$env:'
    }
    It 'fails immediately on a non-success code without killing the exited process' {
        { Invoke-ApplicationProcess -FilePath 'editor.exe' -ArgumentList '/silent' -Action 'Example install' } |
            Should -Throw '*Example install failed with exit code 42*'
        $script:process.Killed | Should -BeFalse
    }
    It 'terminates only its timed-out child process and surfaces the timeout' {
        $script:process.Finished = $false
        { Invoke-ApplicationProcess -FilePath 'editor.exe' -ArgumentList '/silent' -Action 'Example install' -TimeoutMs 5 } |
            Should -Throw '*Example install timed out*'
        $script:process.Killed | Should -BeTrue
        $script:process.Timeout | Should -Be 5
    }
    It 'propagates process startup failures' {
        Mock Start-Process { throw 'Execution denied' }
        { Invoke-ApplicationProcess -FilePath 'editor.exe' -ArgumentList '/silent' -Action 'Example install' } |
            Should -Throw '*Execution denied*'
    }
}

Describe 'Reusable executable command parsing' {
    BeforeAll {
        $ast = Get-TestArtifactAst -Artifact 'Microsoft-Power-BI-Desktop' -Script 'Deploy-PowerBIDesktop.ps1'
        $definition = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Split-ExecutableCommandLine'
        }, $false)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    It 'parses another application with a quoted path or unquoted executable' {
        $command = Split-ExecutableCommandLine -CommandLine '"C:\Example Editor\remove.exe" /quiet /norestart'
        $command.FilePath | Should -Be 'C:\Example Editor\remove.exe'
        $command.ArgumentList | Should -Be '/quiet /norestart'
        (Split-ExecutableCommandLine -CommandLine 'remove.exe /quiet').FilePath | Should -Be 'remove.exe'
    }
    It 'rejects an invalid executable command' {
        { Split-ExecutableCommandLine -CommandLine 'not an executable' } | Should -Throw '*Could not parse*'
    }
}

Describe 'VC++ generic installer discovery and main lifecycle' {
    BeforeAll {
        $ast = Get-TestArtifactAst -Artifact 'Microsoft-VCRedistributable' -Script 'Install-MicrosoftVCRedistributable.ps1'
        foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        $mainText = ($ast.EndBlock.Statements |
            Where-Object { $_ -isnot [Management.Automation.Language.FunctionDefinitionAst] } |
            ForEach-Object { $_.Extent.Text }) -join "`n"
        # Dynamic AST blocks have no script-file context.
        $mainBlock = [scriptblock]::Create('$PSScriptRoot = $packageRoot' + "`n" + $mainText)
        $loop = $ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.ForEachStatementAst] }
        $installLoop = [scriptblock]::Create('$PSScriptRoot = $packageRoot' + "`n" + $loop.Extent.Text)
    }
    BeforeEach {
        Mock Write-Log {}
        Mock New-Log {}
        $directory = Join-Path $TestDrive 'package'
        $packageRoot = $directory
        $downloadDirectory = Join-Path $TestDrive 'download'
        New-Item -Path $directory, $downloadDirectory -ItemType Directory -Force | Out-Null
        $script:client = [pscustomobject]@{ Url = $null; OutFile = $null; Disposed = $false }
        $script:client | Add-Member ScriptMethod DownloadFile {
            param($url, $path)
            $this.Url = $url
            $this.OutFile = $path
            Set-Content -LiteralPath $path -Value 'example installer'
        }
        $script:client | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
        Mock New-Object { $script:client } -ParameterFilter { $TypeName -eq 'System.Net.WebClient' }
    }
    It 'uses a pre-staged installer for an unrelated application without downloading' {
        $path = Join-Path $directory 'editor.exe'
        Set-Content -LiteralPath $path -Value 'pre-staged'
        Get-InstallerFile -Directory $directory -FileName 'editor.exe' -DownloadUrl 'https://example.invalid/editor.exe' `
            -DownloadDirectory $downloadDirectory | Should -Be $path
        Should -Invoke New-Object -Times 0
    }
    It 'downloads the caller-selected filename and URL only when the installer is absent' {
        $path = Get-InstallerFile -Directory $directory -FileName 'other.exe' -DownloadUrl 'https://example.invalid/editor.exe' `
            -DownloadDirectory $downloadDirectory
        $path | Should -Be (Join-Path $downloadDirectory 'other.exe')
        $script:client.Url | Should -Be 'https://example.invalid/editor.exe'
        $script:client.OutFile | Should -Be $path
        $script:client.Disposed | Should -BeTrue
    }
    It 'surfaces download failures and disposes the download client' {
        $script:client | Add-Member ScriptMethod DownloadFile { throw 'Download denied' } -Force
        { Get-InstallerFile -Directory $directory -FileName 'other.exe' -DownloadUrl 'https://example.invalid/editor.exe' `
            -DownloadDirectory $downloadDirectory } | Should -Throw '*Download denied*'
        $script:client.Disposed | Should -BeTrue
    }
    It 'passes both architectures, their original URLs, and custom success codes from main' {
        Mock Get-InstallerFile { "C:\Example\$FileName" }
        Mock Invoke-ApplicationProcess { [pscustomobject]@{ ExitCode = 1638 } }
        $Architecture = 'Both'
        $SuccessExitCodes = @(0, 1638)
        & $mainBlock
        foreach ($arch in @('x64', 'x86')) {
            $expectedFileName = "vc_redist.$arch.exe"
            $expectedUrl = "https://aka.ms/vs/17/release/vc_redist.$arch.exe"
            Should -Invoke Get-InstallerFile -Times 1 -Exactly -ParameterFilter { $FileName -eq $expectedFileName -and $DownloadUrl -eq $expectedUrl }
        }
        Should -Invoke Invoke-ApplicationProcess -Times 2 -Exactly -ParameterFilter {
            $ArgumentList -eq '/install /quiet /norestart' -and ($SuccessExitCodes -join ',') -eq '0,1638'
        }
    }
    It 'continues to the second architecture and records a reported execution failure' {
        Mock Get-InstallerFile { "C:\Example\$FileName" }
        Mock Invoke-ApplicationProcess {
            if ($FilePath -like '*x64.exe') { throw 'Example installer failed' }
            [pscustomobject]@{ ExitCode = 3010 }
        }
        $SoftwareName = 'Example Runtime'
        $Architectures = @('x64', 'x86')
        $DownloadUrls = @{ x64 = 'https://example.invalid/x64'; x86 = 'https://example.invalid/x86' }
        $SuccessExitCodes = @(0, 3010)
        $Failed = @()
        . $installLoop
        ($Failed -join ',') | Should -Be 'x64'
        Should -Invoke Invoke-ApplicationProcess -Times 2 -Exactly
        Should -Invoke Write-Log -Times 1 -ParameterFilter { $Category -eq 'Error' -and "$Message" -like '*Example installer failed*' }
        Should -Invoke Write-Log -Times 1 -ParameterFilter { "$Message" -like '*reboot is required*' }
    }
}
