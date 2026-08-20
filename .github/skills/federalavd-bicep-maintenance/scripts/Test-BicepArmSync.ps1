[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$BicepPath,

    [string]$ArmPath
)

$ErrorActionPreference = 'Stop'
$bicepFile = Get-Item -LiteralPath $BicepPath
if ($bicepFile.Extension -ne '.bicep') {
    throw "BicepPath must reference a .bicep file."
}

if ([string]::IsNullOrWhiteSpace($ArmPath)) {
    $ArmPath = [System.IO.Path]::ChangeExtension($bicepFile.FullName, '.json')
}
if (-not (Test-Path -LiteralPath $ArmPath -PathType Leaf)) {
    throw "Generated ARM template not found at '$ArmPath'."
}

$temporaryArmPath = Join-Path ([System.IO.Path]::GetTempPath()) ("federalavd-{0}.json" -f [guid]::NewGuid())
try {
    if (Get-Command -Name 'az' -ErrorAction SilentlyContinue) {
        & az bicep build --file $bicepFile.FullName --outfile $temporaryArmPath
    } elseif (Get-Command -Name 'bicep' -ErrorAction SilentlyContinue) {
        & bicep build $bicepFile.FullName --outfile $temporaryArmPath
    } else {
        throw "Neither the Bicep CLI nor Azure CLI is available."
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Bicep build failed with exit code $LASTEXITCODE."
    }

    $expected = Get-Content -LiteralPath $ArmPath -Raw | ConvertFrom-Json
    $actual = Get-Content -LiteralPath $temporaryArmPath -Raw | ConvertFrom-Json
    $expectedNormalized = $expected | ConvertTo-Json -Depth 100 -Compress
    $actualNormalized = $actual | ConvertTo-Json -Depth 100 -Compress

    if ($expectedNormalized -ne $actualNormalized) {
        Write-Error "Generated ARM template is stale: '$ArmPath'. Rebuild it from '$($bicepFile.FullName)'."
        exit 1
    }

    Write-Output "Bicep and ARM JSON are synchronized: $($bicepFile.FullName)"
} finally {
    Remove-Item -LiteralPath $temporaryArmPath -Force -ErrorAction SilentlyContinue
}
