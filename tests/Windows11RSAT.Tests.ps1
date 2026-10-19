$installerPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'customer-examples\artifacts\Windows-11-RSAT\Install-Windows11RSAT.ps1'
$installerAst = [Management.Automation.Language.Parser]::ParseFile($installerPath, [ref]$null, [ref]$null)
$start = $installerAst.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.AssignmentStatementAst] -and
        $_.Left.Extent.Text -eq '$offlineSourceAvailable'
} | Select-Object -First 1
$body = (Get-Content -LiteralPath $installerPath -Raw).Substring($start.Extent.StartOffset)
$installCapabilities = [scriptblock]::Create("param([string]`$SourcePath, [switch]`$OfflineOnly)`n`$ErrorActionPreference = 'Stop'`n$body")

function Write-Log { param($Category, $Message) }

Describe 'Windows 11 RSAT capability installation' {
    BeforeEach {
        $global:FederalAvdRsatTest = @{
            Installed = @{}
            FailOffline = $false
            Logs = @()
        }
        Mock Write-Log { $global:FederalAvdRsatTest.Logs += $Message }
        Mock Get-WindowsCapability {
            param($Name)
            $state = if ($global:FederalAvdRsatTest.Installed[$Name]) { 'Installed' } else { 'NotPresent' }
            [pscustomobject]@{ State = $state }
        }
        Mock Add-WindowsCapability {
            param($Name, $Source)
            if ($Source -and $global:FederalAvdRsatTest.FailOffline) { throw 'Test offline source failure.' }
            $global:FederalAvdRsatTest.Installed[$Name] = $true
            [pscustomobject]@{ RestartNeeded = $true }
        }
        $sourcePath = Join-Path $TestDrive 'Payload'
        New-Item -Path $sourcePath -ItemType Directory -Force | Out-Null
    }

    AfterAll {
        Remove-Variable -Name FederalAvdRsatTest -Scope Global
    }

    It 'does not pass unsupported restart parameters to Add-WindowsCapability' {
        $commands = @($installerAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Add-WindowsCapability'
        }, $true))
        $commands.Count | Should Be 2
        foreach ($command in $commands) {
            $parameters = @($command.CommandElements |
                Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] } |
                ForEach-Object ParameterName)
            ($parameters -contains 'NoRestart') | Should Be $false
            ($parameters -contains 'Online') | Should Be $true
            ($parameters -contains 'Name') | Should Be $true
        }
    }

    It 'installs all three capabilities online and records restart status' {
        & $installCapabilities -SourcePath $sourcePath
        Assert-MockCalled Add-WindowsCapability -Times 3 -Exactly -Scope It -ParameterFilter {
            $Online -and -not $Source -and -not $LimitAccess
        }
        $global:FederalAvdRsatTest.Logs[-1] | Should Match 'Restart needed: True'
    }

    It 'keeps offline installation restricted to the staged source' {
        Set-Content -LiteralPath (Join-Path $sourcePath 'test.cab') -Value 'fixture' -Encoding ASCII
        & $installCapabilities -SourcePath $sourcePath -OfflineOnly
        Assert-MockCalled Add-WindowsCapability -Times 3 -Exactly -Scope It -ParameterFilter {
            $Online -and $Source -and $LimitAccess
        }
    }

    It 'falls back online when an offline install fails and OfflineOnly is not set' {
        Set-Content -LiteralPath (Join-Path $sourcePath 'test.cab') -Value 'fixture' -Encoding ASCII
        $global:FederalAvdRsatTest.FailOffline = $true
        & $installCapabilities -SourcePath $sourcePath
        Assert-MockCalled Add-WindowsCapability -Times 3 -Exactly -Scope It -ParameterFilter { $Source -and $LimitAccess }
        Assert-MockCalled Add-WindowsCapability -Times 3 -Exactly -Scope It -ParameterFilter { -not $Source -and -not $LimitAccess }
    }

    It 'does not fall back online after an OfflineOnly failure' {
        Set-Content -LiteralPath (Join-Path $sourcePath 'test.cab') -Value 'fixture' -Encoding ASCII
        $global:FederalAvdRsatTest.FailOffline = $true
        { & $installCapabilities -SourcePath $sourcePath -OfflineOnly } | Should Throw 'Offline installation'
        Assert-MockCalled Add-WindowsCapability -Times 0 -Exactly -Scope It -ParameterFilter { -not $Source }
    }

    It 'skips capabilities that are already installed' {
        foreach ($name in @('Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0',
            'Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0', 'Rsat.DHCP.Tools~~~~0.0.1.0')) {
            $global:FederalAvdRsatTest.Installed[$name] = $true
        }
        & $installCapabilities -SourcePath $sourcePath
        Assert-MockCalled Add-WindowsCapability -Times 0 -Exactly -Scope It
    }
}
