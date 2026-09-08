$repoRoot = Split-Path -Parent $PSScriptRoot
$msiArtifactScripts = @(
    'customer-examples\artifacts\7-Zip\Deploy-7-Zip.ps1'
    'customer-examples\artifacts\Adobe-Acrobat-Reader-DC\Deploy-AdobeReaderDC.ps1'
    'customer-examples\artifacts\Amazon-Workspaces-Client\Deploy-AmazonWorkspacesClient.ps1'
    'customer-examples\artifacts\DoD-InstallRoot\Deploy-InstallRoot.ps1'
    'customer-examples\artifacts\Google-Chrome-Enterprise\Deploy-GoogleChromeEnterprise.ps1'
    'customer-examples\artifacts\Microsoft-AVD-Multimedia-Redirection\Install-MicrosoftAVDMultimediaRedirection.ps1'
    'customer-examples\artifacts\Microsoft-AzCLI\Deploy-AzCLI.ps1'
    'customer-examples\artifacts\Microsoft-Edge-Enterprise\Deploy-MicrosoftEdgeEnterprise.ps1'
    'customer-examples\artifacts\Microsoft-PowerShell-7\Deploy-PowerShell7.ps1'
    'customer-examples\artifacts\PuTTY\Deploy-PuTTY.ps1'
)

Describe 'MSI exit code 1618 handling' {
    foreach ($relativePath in $msiArtifactScripts) {
        It "retries only after MSI reports contention in $relativePath" {
            $content = Get-Content -LiteralPath (Join-Path $repoRoot $relativePath) -Raw

            $content | Should Not Match 'Wait-MsiexecIdle'
            $content | Should Match 'function Invoke-MsiProcess'
            $content | Should Match '\$process\.ExitCode -ne 1618'
            $content | Should Match '\[int\]\$MaxAttempts = 11'
            $content | Should Match '\[int\]\$RetryDelaySeconds = 30'
            $content | Should Match 'Start-Sleep -Seconds \$RetryDelaySeconds'
        }
    }

    It 'does not wait for MSI before running the VS Code EXE installer' {
        $vscodeScript = Get-Content -LiteralPath (Join-Path $repoRoot 'customer-examples\artifacts\Microsoft-VSCode\Deploy-VSCode.ps1') -Raw
        $vscodeScript | Should Not Match 'Wait-MsiexecIdle|Invoke-MsiProcess'
    }

    It 'does not combine the equivalent quiet and qn options' {
        $artifactScripts = Get-ChildItem -LiteralPath (Join-Path $repoRoot 'customer-examples\artifacts') -Filter '*.ps1' -File -Recurse
        foreach ($artifactScript in $artifactScripts) {
            $content = Get-Content -LiteralPath $artifactScript.FullName -Raw
            $content | Should Not Match '(?i)/quiet\s+/qn|/qn\s+/quiet'
        }
    }
}

Describe 'InstallRoot MSI application lifecycle' {
    BeforeAll {
        $artifactPath = Join-Path $repoRoot 'customer-examples\artifacts\DoD-InstallRoot'
        $scriptPath = Join-Path $artifactPath 'Deploy-InstallRoot.ps1'
        $content = Get-Content -LiteralPath $scriptPath -Raw
    }

    It 'uses one Deploy entry point' {
        @(Get-ChildItem -LiteralPath $artifactPath -Filter '*.ps1' -File).Count | Should Be 1
        Test-Path -LiteralPath $scriptPath | Should Be $true
    }

    It 'exposes install and uninstall deployment types' {
        $content | Should Match "\[ValidateSet\('Install', 'Uninstall'\)\]"
        $content | Should Match "\[string\]\`$DeploymentType = 'Install'"
        $content | Should Match "\`$DeploymentType -eq 'Uninstall'"
    }

    It 'uses configurable success codes for install and uninstall' {
        $content | Should Match '\[int\[\]\]\$SuccessExitCodes = @\(0, 3010\)'
        ([regex]::Matches($content, '-notin \$SuccessExitCodes|-in \$SuccessExitCodes')).Count | Should Be 2
    }
}