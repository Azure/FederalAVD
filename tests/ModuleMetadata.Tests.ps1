$repoRoot = Split-Path -Parent $PSScriptRoot
$sharedModuleRoots = @(
    Join-Path $repoRoot 'deployments\shared\modules\orchestration'
    Join-Path $repoRoot 'deployments\shared\modules\resourceModules'
)
$moduleCases = @(Get-ChildItem -LiteralPath $sharedModuleRoots -Filter '*.bicep' -File -Recurse |
    Sort-Object FullName | ForEach-Object {
        @{ Module = $_.FullName.Substring($repoRoot.Length + 1) }
    })

Describe 'Shared Bicep module metadata contracts' {
    BeforeAll {
        $testOutputDirectory = Join-Path ([IO.Path]::GetTempPath()) ('FederalAVD-ModuleMetadata-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $testOutputDirectory -ErrorAction Stop | Out-Null
    }

    AfterAll {
        if (Test-Path -LiteralPath $testOutputDirectory) {
            Get-ChildItem -LiteralPath $testOutputDirectory -File | ForEach-Object {
                Remove-Item -LiteralPath $_.FullName -ErrorAction Stop
            }
            Remove-Item -LiteralPath $testOutputDirectory -ErrorAction Stop
        }
    }

    It 'compiles and documents the public contract of <Module>' -TestCases $moduleCases {
        param($Module)

        $source = Join-Path $repoRoot $Module
        $output = Join-Path $testOutputDirectory (($Module -replace '[\\/:]', '_') + '.json')
        & az bicep build --file $source --outfile $output
        if ($LASTEXITCODE -ne 0) {
            throw "Bicep compilation failed: $Module"
        }
        $template = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json
        [string]::IsNullOrWhiteSpace($template.metadata.name) | Should Be $false
        [string]::IsNullOrWhiteSpace($template.metadata.description) | Should Be $false
        foreach ($section in @('parameters', 'outputs')) {
            foreach ($property in $template.$section.PSObject.Properties) {
                if ([string]::IsNullOrWhiteSpace($property.Value.metadata.description)) {
                    throw "Missing description for $section.$($property.Name) in $Module."
                }
            }
        }
    }
}
