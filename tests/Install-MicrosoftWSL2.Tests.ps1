$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$artifactPath = Join-Path -Path $repoRoot -ChildPath 'customer-examples\artifacts\Microsoft-WSL2'
$sourceScriptPath = Join-Path -Path $artifactPath -ChildPath 'Install-MicrosoftWSL2.ps1'
$readmePath = Join-Path -Path $artifactPath -ChildPath 'README.md'
$downloadsPath = Join-Path -Path $repoRoot -ChildPath 'customer-examples\parameters\imageManagement\downloads.json'

$rootScripts = @(Get-ChildItem -LiteralPath $artifactPath -Filter '*.ps1' -File)
if ($rootScripts.Count -ne 1) {
    throw "Microsoft-WSL2 must contain exactly one root PowerShell script; found $($rootScripts.Count)."
}

$tokens = $null
$parseErrors = $null
$scriptAst = [Management.Automation.Language.Parser]::ParseFile(
    $sourceScriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw "Install-MicrosoftWSL2.ps1 has $($parseErrors.Count) PowerShell parse error(s)."
}
if (Get-Content -LiteralPath $sourceScriptPath | Where-Object { $_ -match '[^\x00-\x7E]' }) {
    throw 'Install-MicrosoftWSL2.ps1 contains non-ASCII content.'
}

function Get-ValidateSetValues {
    param([Parameter(Mandatory = $true)][string]$ParameterName)

    $parameter = $scriptAst.ParamBlock.Parameters | Where-Object {
        $_.Name.VariablePath.UserPath -eq $ParameterName
    }
    if (-not $parameter) {
        throw "Parameter '$ParameterName' was not found."
    }

    return @(
        $parameter.Attributes |
            Where-Object { $_.TypeName.FullName -eq 'ValidateSet' } |
            ForEach-Object { $_.PositionalArguments.SafeGetValue() }
    )
}

$phases = Get-ValidateSetValues -ParameterName 'Phase'
if (($phases -join ',') -ne 'EnablePlatform,ProvisionDistribution') {
    throw "Unexpected Phase values: $($phases -join ',')"
}

$distributions = Get-ValidateSetValues -ParameterName 'Distribution'
$expectedDistributions = @('Ubuntu-24.04', 'Ubuntu-22.04', 'Debian', 'Kali-Linux', 'Rocky-Linux-9')
if (($distributions -join ',') -ne ($expectedDistributions -join ',')) {
    throw "Unexpected Distribution values: $($distributions -join ',')"
}

$scriptText = Get-Content -LiteralPath $sourceScriptPath -Raw
$requiredScriptText = @(
    "'Microsoft-Windows-Subsystem-Linux'",
    "'VirtualMachinePlatform'",
    "-Regions 'all'",
    "'WSL-x64.msi'",
    'DefaultVersion',
    'reg.exe ADD "HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss"',
    'Get-AppxIdentityName',
    "Get-Command -Name 'wsl.exe'",
    "-SuccessExitCodes @(0, 1638, 3010)",
    'Install-WSLFileDistribution',
    '--install --from-file $imagePath --name $distributionName --no-launch',
    "-Filter '*.wsl'",
    'WSL\$Name',
    "-ChildPath 'Distribution.wsl'",
    "{882E5A8C-CC7D-43B5-AB9D-2EF10E6859D2}",
    "{CB23A9AC-6072-4DA4-96CF-91100CF5A176}",
    ".Replace('__DISTRIBUTION_NAME__', `$Name)",
    'Set-Content -LiteralPath $bootstrapPath -Value $bootstrap -Encoding ASCII',
    '-ArgumentList "`"$stagingDirectory`" /inheritance:r'
)
foreach ($requiredText in $requiredScriptText) {
    if (-not $scriptText.Contains($requiredText)) {
        throw "Install-MicrosoftWSL2.ps1 is missing required text: $requiredText"
    }
}

$bootstrapMatch = [regex]::Match($scriptText, '(?s)\$bootstrap\s*=\s*@''\r?\n(?<Content>.*?)\r?\n''@')
if (-not $bootstrapMatch.Success) {
    throw 'The embedded Rocky Linux registration bootstrap was not found.'
}
$bootstrapTokens = $null
$bootstrapParseErrors = $null
[Management.Automation.Language.Parser]::ParseInput(
    $bootstrapMatch.Groups['Content'].Value,
    [ref]$bootstrapTokens,
    [ref]$bootstrapParseErrors
) | Out-Null
if ($bootstrapParseErrors.Count -gt 0) {
    throw "The embedded Rocky Linux registration bootstrap has $($bootstrapParseErrors.Count) PowerShell parse error(s)."
}

$identityFunctionAst = $scriptAst.Find({
    param($ast)
    $ast -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $ast.Name -eq 'Get-AppxIdentityName'
}, $true)
if (-not $identityFunctionAst) {
    throw 'Get-AppxIdentityName function AST was not found.'
}

$identityTestRoot = Join-Path -Path $env:TEMP -ChildPath "FederalAVD-WSL2-identity-$([guid]::NewGuid())"
try {
    $metadataPath = Join-Path -Path $identityTestRoot -ChildPath 'content\AppxMetadata'
    New-Item -Path $metadataPath -ItemType Directory -Force | Out-Null
    $manifestPath = Join-Path -Path $metadataPath -ChildPath 'AppxBundleManifest.xml'
    @'
<?xml version="1.0" encoding="utf-8"?>
<Bundle xmlns="http://schemas.microsoft.com/appx/2013/bundle">
  <Identity Name="FederalAVD.WSL2.TestDistribution" Publisher="CN=FederalAVD" Version="1.0.0.0" />
</Bundle>
'@ | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    $testPackagePath = Join-Path -Path $identityTestRoot -ChildPath 'TestDistribution.AppxBundle'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        (Join-Path -Path $identityTestRoot -ChildPath 'content'),
        $testPackagePath
    )

    Invoke-Expression $identityFunctionAst.Extent.Text
    $actualIdentity = Get-AppxIdentityName -PackagePath $testPackagePath
    if ($actualIdentity -ne 'FederalAVD.WSL2.TestDistribution') {
        throw "Unexpected AppX identity '$actualIdentity'."
    }
}
finally {
    Remove-Item function:\Get-AppxIdentityName -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $identityTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$downloads = Get-Content -LiteralPath $downloadsPath -Raw | ConvertFrom-Json
$downloadExpectations = @{
    MicrosoftWSL2 = @('WSL-x64.msi', 'Microsoft-WSL2')
    WSLUbuntu2404 = @('Ubuntu-24.04.AppxBundle', 'Microsoft-WSL2\DistributionPackages\Ubuntu-24.04')
    WSLUbuntu2204 = @('Ubuntu-22.04.AppxBundle', 'Microsoft-WSL2\DistributionPackages\Ubuntu-22.04')
    WSLDebian = @('Debian.AppxBundle', 'Microsoft-WSL2\DistributionPackages\Debian')
    WSLKaliLinux = @('Kali-Linux.AppxBundle', 'Microsoft-WSL2\DistributionPackages\Kali-Linux')
    WSLRockyLinux9 = @('Rocky-9-WSL-Base.latest.x86_64.wsl', 'Microsoft-WSL2\DistributionPackages\Rocky-Linux-9')
}
foreach ($entryName in $downloadExpectations.Keys) {
    $entry = $downloads.$entryName
    if (-not $entry) {
        throw "downloads.json is missing '$entryName'."
    }

    $expectedFileName = $downloadExpectations[$entryName][0]
    $expectedFolder = $downloadExpectations[$entryName][1]
    if ($entry.DestinationFileName -ne $expectedFileName) {
        throw "'$entryName' has unexpected DestinationFileName '$($entry.DestinationFileName)'."
    }
    if (@($entry.DestinationFolders) -notcontains $expectedFolder) {
        throw "'$entryName' does not target '$expectedFolder'."
    }
}

$readmeText = Get-Content -LiteralPath $readmePath -Raw
foreach ($requiredText in @('"restart": true', 'FSLogix Profile Container', 'Windows 11 Enterprise multi-session', 'Per-user boundary', 'WSLRockyLinux9', 'wsl.exe --install --from-file', '.CHECKSUM')) {
    if (-not $readmeText.Contains($requiredText)) {
        throw "Microsoft-WSL2 README is missing required guidance: $requiredText"
    }
}

Write-Output 'Install-MicrosoftWSL2 tests passed.'
