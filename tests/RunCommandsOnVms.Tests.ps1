BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $addonPath = Join-Path $repoRoot 'deployments\add-ons\runCommandsOnVms'
    $template = Get-Content -LiteralPath (Join-Path $addonPath 'main.json') -Raw | ConvertFrom-Json
    $sharedScript = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\shared\scripts\Invoke-Customization.ps1') -Raw

    function Find-CustomizationScript {
        param($Node)

        if ($Node -is [string]) {
            if ($Node.Contains('function ConvertTo-ParametersSplat')) { $Node }
        }
        elseif ($Node -is [System.Collections.IEnumerable]) {
            foreach ($item in $Node) { Find-CustomizationScript -Node $item }
        }
        elseif ($Node -is [pscustomobject]) {
            foreach ($property in $Node.PSObject.Properties) {
                Find-CustomizationScript -Node $property.Value
            }
        }
    }

    $embeddedScripts = @(Find-CustomizationScript -Node $template)
    if ($embeddedScripts.Count -ne 1) {
        throw "Expected one embedded customization script; found $($embeddedScripts.Count)."
    }
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($embeddedScripts[0], [ref]$null, [ref]$errors)
    if ($errors.Count -gt 0) { throw ($errors.Message -join '; ') }
    foreach ($name in @('Split-ArgumentString', 'ConvertTo-ParametersSplat')) {
        $definition = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    $artifactPath = Join-Path $repoRoot 'customer-examples\artifacts\Configure-OneDrivePinnedFolders\Configure-OneDrivePinnedFolders.ps1'
    $artifactAst = [Management.Automation.Language.Parser]::ParseFile($artifactPath, [ref]$null, [ref]$null)
    $validator = $artifactAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-RelativeFolders'
    }, $true)
    . ([scriptblock]::Create($validator.Extent.Text))
}

Describe 'Run Commands on VMs shared customization wrapper' {
    It 'embeds the exact shared script in generated ARM' {
        $embeddedScripts[0].Replace("`r`n", "`n") | Should -BeExactly $sharedScript.Replace("`r`n", "`n")
        $module = Get-Content -LiteralPath (Join-Path $addonPath 'modules\runCommands.bicep') -Raw
        $module | Should -Match ([regex]::Escape("loadTextContent('../../../shared/scripts/Invoke-Customization.ps1')"))
        $module | Should -Match 'empty\(script.arguments\) \? \[\]'
        Test-Path -LiteralPath (Join-Path $addonPath 'scripts\Execute-Script.ps1') | Should -BeFalse
    }

    It 'preserves folder arrays from the Portal arguments field: <Arguments>' -TestCases @(
        @{ Arguments = "-Folders @('Documents\cspid')"; Expected = @('Documents\cspid') }
        @{ Arguments = "-Folders @('Documents\jsignout', 'Documents\cspid')"; Expected = @('Documents\jsignout', 'Documents\cspid') }
        @{ Arguments = "-Folders @('Documents\cspid', 'Shared Documents\Reports')"; Expected = @('Documents\cspid', 'Shared Documents\Reports') }
    ) {
        param($Arguments, $Expected)

        $parameters = ConvertTo-ParametersSplat -ArgumentString $Arguments
        $parameters.Folders | Should -BeOfType ([string])
        ($parameters.Folders -is [string[]]) | Should -BeTrue
        $parameters.Folders.Count | Should -Be $Expected.Count
        for ($i = 0; $i -lt $Expected.Count; $i++) {
            $parameters.Folders[$i] | Should -BeExactly $Expected[$i]
        }
        { Assert-RelativeFolders -Paths $parameters.Folders } | Should -Not -Throw
    }

    It 'decodes JSON escaping once before native array and integer parameter binding' {
        $row = '{"arguments":"-Folders @(''Documents\\cspid'') -WaitTimeoutSeconds 900 -RetryIntervalSeconds 10"}' | ConvertFrom-Json
        $parameters = ConvertTo-ParametersSplat -ArgumentString $row.arguments
        $result = & {
            param([string[]]$Folders, [int]$WaitTimeoutSeconds, [int]$RetryIntervalSeconds)
            Assert-RelativeFolders -Paths $Folders
            [pscustomobject]@{
                Folders = $Folders
                WaitTimeoutSeconds = $WaitTimeoutSeconds
                RetryIntervalSeconds = $RetryIntervalSeconds
            }
        } @parameters

        $result.Folders.Count | Should -Be 1
        $result.Folders[0] | Should -BeExactly 'Documents\cspid'
        $result.WaitTimeoutSeconds | Should -BeOfType ([int])
        $result.WaitTimeoutSeconds | Should -Be 900
        $result.RetryIntervalSeconds | Should -Be 10
    }

    It 'preserves existing scalar, boolean, switch, and omitted argument behavior' {
        $parameters = ConvertTo-ParametersSplat -ArgumentString '-Mode "my value" -Enabled $false -Force'
        $result = & {
            param([string]$Mode, [bool]$Enabled, [switch]$Force)
            [pscustomobject]@{ Mode = $Mode; Enabled = $Enabled; Force = [bool]$Force }
        } @parameters

        $result.Mode | Should -BeExactly 'my value'
        $result.Enabled | Should -BeFalse
        $result.Force | Should -BeTrue
        (ConvertTo-ParametersSplat -ArgumentString '').Count | Should -Be 0
    }

    It 'still rejects doubled path separators entered literally in the Portal' {
        $parameters = ConvertTo-ParametersSplat -ArgumentString "-Folders @('Documents\\cspid')"
        { Assert-RelativeFolders -Paths $parameters.Folders } | Should -Throw '*invalid relative path*'
    }
}
