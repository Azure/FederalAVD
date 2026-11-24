BeforeDiscovery {
    $softwareArtifacts = @(
        '7-Zip', 'Adobe-Acrobat-Reader-DC', 'BuiltIn-UWP-Apps',
        'DoD-InstallRoot', 'Git-for-Windows', 'Google-Chrome-Enterprise', 'LGPO',
        'Microsoft-AVD-Multimedia-Redirection', 'Microsoft-AzCLI', 'Microsoft-Defender-VDI-Onboarding',
        'Microsoft-Edge-Enterprise', 'Microsoft-FSLogix', 'Microsoft-Power-BI-Desktop',
        'Microsoft-PowerShell-7', 'Microsoft-VCRedistributable', 'Microsoft-VSCode',
        'Microsoft-WinGet', 'Microsoft-WSL2', 'Notepad-PlusPlus', 'PuTTY',
        'Windows-11-RSAT', 'Windows-Catalog-Updates'
    )
}

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $frameworkPath = Join-Path $repoRoot 'tools\ArtifactFramework.ps1'
    $frameworkAst = [Management.Automation.Language.Parser]::ParseFile($frameworkPath, [ref]$null, [ref]$null)
    $canonical = @{}
    foreach ($definition in $frameworkAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst]
    }, $false)) {
        $canonical[$definition.Name] = $definition.Extent.Text.Replace("`r`n", "`n")
        . ([scriptblock]::Create($definition.Extent.Text))
    }
}

Describe 'Standalone embedded framework: <_>' -ForEach $softwareArtifacts {
    BeforeAll {
        $artifactName = $_
        $directory = Join-Path $repoRoot "customer-examples\artifacts\$artifactName"
        $scripts = @(Get-ChildItem -LiteralPath $directory -Filter '*.ps1' -File)
        if ($scripts.Count -ne 1) { throw "Expected one root script in $directory" }
        $path = $scripts[0].FullName
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
        $definitions = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst]
        }, $false))
        $source = Get-Content -LiteralPath $path -Raw
    }
    It 'has valid Windows PowerShell syntax and ASCII-only content' {
        $errors.Count | Should -Be 0
        @(Get-Content -LiteralPath $path | Where-Object { $_ -match '[^\x00-\x7E]' }).Count | Should -Be 0
    }
    It 'uses byte-equivalent canonical implementations for every embedded framework helper' {
        foreach ($definition in $definitions | Where-Object { $canonical.ContainsKey($_.Name) }) {
            $definition.Extent.Text.Replace("`r`n", "`n") | Should -BeExactly $canonical[$definition.Name]
        }
        'Write-Log' | Should -BeIn $definitions.Name
        'New-Log' | Should -BeIn $definitions.Name
        @($definitions.Name | Where-Object { $_ -in @('Get-InstalledApplication', 'Remove-MsiApplication', 'Invoke-Process') }).Count | Should -Be 0
    }
    It 'requires no runtime dependency on the authoring framework or synchronization tool' {
        $source | Should -Not -Match 'ArtifactFramework\.ps1|Sync-ArtifactFramework\.ps1'
        $imports = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Import-Module'
        }, $true))
        $imports.Count | Should -Be 0
    }
    It 'routes native installation execution through the common process helper' {
        foreach ($command in $ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Start-Process'
        }, $true)) {
            $parent = $command.Parent
            while ($parent -and $parent -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $parent = $parent.Parent }
            $parent.Name | Should -BeIn @('Invoke-ApplicationProcess', 'Test-ApplicationPayload')
        }
        if ('Invoke-MsiProcess' -in $definitions.Name) {
            'Invoke-ApplicationProcess' | Should -BeIn $definitions.Name
        }
    }
    It 'is already synchronized and remains byte-identical when synchronized again' {
        $copyDirectory = Join-Path $TestDrive $artifactName
        New-Item -Path $copyDirectory -ItemType Directory | Out-Null
        $copyPath = Join-Path $copyDirectory (Split-Path $path -Leaf)
        Copy-Item -LiteralPath $path -Destination $copyPath
        $originalHash = (Get-FileHash -LiteralPath $copyPath).Hash
        & (Join-Path $repoRoot 'tools\Sync-ArtifactFramework.ps1') -ArtifactPath $copyDirectory | Out-Null
        (Get-FileHash -LiteralPath $copyPath).Hash | Should -Be $originalHash
    }
}

Describe 'Framework execution and synchronization contracts' {
    BeforeEach {
        Mock Write-Log {}
        $script:codes = @(1618, 0)
        $script:calls = 0
        Mock Start-Process {
            $code = $script:codes[[math]::Min($script:calls, $script:codes.Count - 1)]
            $script:calls++
            $process = [pscustomobject]@{ ExitCode = $code }
            $process | Add-Member ScriptMethod WaitForExit { param($timeout) return $true }
            $process | Add-Member ScriptMethod Kill { throw 'Unexpected termination' }
            return $process
        }

        Mock Start-Sleep {}
    }
    It 'retries MSI contention through the same bounded process implementation' {
        (Invoke-MsiProcess -ArgumentList '/i example.msi /qn' -Action 'Example installer').ExitCode | Should -Be 0
        Should -Invoke Start-Process -Times 2 -Exactly -ParameterFilter { $FilePath -eq 'msiexec.exe' }
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 30 }
    }
    It 'returns raw exit codes only when the caller explicitly requests them' {
        $script:codes = @(1603)
        (Invoke-ApplicationProcess -FilePath 'example.exe' -ArgumentList '/quiet' -Action 'Example' -SuccessExitCodes @()).ExitCode |
            Should -Be 1603
        { Invoke-ApplicationProcess -FilePath 'example.exe' -ArgumentList '/quiet' -Action 'Example' } |
            Should -Throw '*1603*'
    }
    It 'retains the process handle before waiting for a Windows PowerShell child' {
        Mock Start-Process {
            $process = [pscustomobject]@{ ExitCode = $null; HandleRetained = $false }
            $process | Add-Member ScriptProperty Handle { $this.HandleRetained = $true; [IntPtr]1 }
            $process | Add-Member ScriptMethod WaitForExit {
                param($timeout)
                if ($this.HandleRetained) { $this.ExitCode = 0 }
                return $true
            }
            $process
        }
        (Invoke-ApplicationProcess -FilePath 'example.exe' -ArgumentList '/quiet' -Action 'Example').ExitCode |
            Should -Be 0
    }
    It 'rejects unavailable exit codes even when raw status was requested' {
        $script:codes = @($null)
        { Invoke-ApplicationProcess -FilePath 'example.exe' -ArgumentList '/quiet' -Action 'Example' -SuccessExitCodes @() } |
            Should -Throw '*Example did not report an exit code*'
    }
    It 'preserves single-registration ambiguity guards unless multiple removal is explicitly selected' {
        Mock Invoke-MsiProcess { [pscustomobject]@{ ExitCode = 0 } }
        $applications = @(
            [pscustomobject]@{ DisplayName = 'Example'; ProductCode = '{00000000-0000-0000-0000-000000000001}' }
            [pscustomobject]@{ DisplayName = 'Other'; ProductCode = '{00000000-0000-0000-0000-000000000002}' }
        )
        { Remove-MsiApplications -Applications $applications } | Should -Throw '*Multiple MSI*'
        Should -Invoke Invoke-MsiProcess -Times 0
        Remove-MsiApplications -Applications $applications -AllowMultiple
        Should -Invoke Invoke-MsiProcess -Times 2 -Exactly
    }

    It 'honors main-owned MSI argument conventions without dropping the ProductCode' {
        Mock Invoke-MsiProcess { [pscustomobject]@{ ExitCode = 0 } }
        $application = [pscustomobject]@{ DisplayName = 'Example'; ProductCode = '{00000000-0000-0000-0000-000000000001}' }
        Remove-MsiApplications -Applications @($application) -ArgumentListFormat '/X {0} /qn'
        Should -Invoke Invoke-MsiProcess -Times 1 -Exactly -ParameterFilter {
            $ArgumentList -eq '/X {00000000-0000-0000-0000-000000000001} /qn'
        }
        { Remove-MsiApplications -Applications @($application) -ArgumentListFormat '/qn' } | Should -Throw '*ProductCode placeholder*'
    }
    It 'synchronizes an isolated package idempotently without replacing its product configuration or payload' {
        $directory = Join-Path $TestDrive 'example'
        New-Item -Path $directory -ItemType Directory | Out-Null
        $path = Join-Path $directory 'Deploy-Example.ps1'
        $text = @'
$script:Name = 'Example'
function Write-Log { param($Message) Write-Host $Message }
function New-Log { param($Path) }
New-Log -Path $PSScriptRoot
$productRule = 'Customer-specific value'
Write-Log $productRule
'@
        Set-Content -LiteralPath $path -Value $text -Encoding ASCII
        $payload = Join-Path $directory 'example.exe'
        Set-Content -LiteralPath $payload -Value 'untouched payload' -Encoding ASCII
        $payloadHash = (Get-FileHash $payload).Hash
        & (Join-Path $repoRoot 'tools\Sync-ArtifactFramework.ps1') -ArtifactPath $directory | Out-Null
        $firstHash = (Get-FileHash $path).Hash
        & (Join-Path $repoRoot 'tools\Sync-ArtifactFramework.ps1') -ArtifactPath $directory | Out-Null
        (Get-FileHash $path).Hash | Should -Be $firstHash
        (Get-FileHash $payload).Hash | Should -Be $payloadHash
        Get-Content -LiteralPath $path -Raw | Should -Match '\$productRule = ''Customer-specific value'''
    }
}

Describe 'Real child-process exit status' {
    It 'preserves native exit code <Code> without mocks' -TestCases @(
        @{ Code = 0 }
        @{ Code = 23 }
    ) {
        param($Code)
        $process = Invoke-ApplicationProcess -FilePath $env:ComSpec -ArgumentList "/c exit $Code" `
            -Action 'Exit-code regression' -SuccessExitCodes @()
        $process.ExitCode | Should -Be $Code
    }
}

Describe 'Framework logging and registry contracts' {
    BeforeEach {
        $previousSuppression = $env:SUPPRESS_FILELOG
        $env:SUPPRESS_FILELOG = '1'
    }
    AfterEach {
        $env:SUPPRESS_FILELOG = $previousSuppression
    }
    It 'does not mix informational logs into returned application metadata' {
        Mock Write-Host {}
        $result = @(& {
            Write-Log 'Example informational message'
            [pscustomobject]@{ Name = 'Example' }
        })
        $result.Count | Should -Be 1
        $result[0].Name | Should -Be 'Example'
        Should -Invoke Write-Host -Times 1
    }
    It 'preserves explicit fixed log paths without leaking initialization output' {
        $env:SUPPRESS_FILELOG = '0'
        $fixedPath = Join-Path $TestDrive 'logs\onboarding.log'
        @(New-Log -FilePath $fixedPath).Count | Should -Be 0
        Test-Path -LiteralPath $fixedPath -PathType Leaf | Should -BeTrue
        Write-Log 'Example file message'
        Get-Content -LiteralPath $fixedPath -Raw | Should -Match 'Example file message'
    }
    It 'surfaces file logging failures rather than silently dropping evidence' {
        $env:SUPPRESS_FILELOG = '0'
        Mock Add-Content { throw 'Log file unavailable' }
        { Write-Log 'Example' } | Should -Throw '*Log file unavailable*'
    }
    It 'preserves registry path/type aliases and explicit caller-provided values' {
        Mock Test-Path { $false }
        Mock New-Item {}
        Mock New-ItemProperty {}
        Set-RegistryValue -Key 'HKLM:\Example' -Name 'ExampleValue' -Value 7 -Type DWord
        Should -Invoke New-ItemProperty -Times 1 -Exactly -ParameterFilter {
            $LiteralPath -eq 'HKLM:\Example' -and $Name -eq 'ExampleValue' -and
                $Value -eq 7 -and $PropertyType -eq 'DWord' -and $Force -and $ErrorAction -eq 'Stop'
        }
    }
}
