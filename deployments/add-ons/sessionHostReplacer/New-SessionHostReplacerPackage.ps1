#requires -Version 7.2
<#
.SYNOPSIS
Builds an optional SHR queue-continuation ZIP with precompiled binding extensions.
.DESCRIPTION
Run on a build workstation with .NET SDK 8 or later and access to approved NuGet
sources. This does not deploy infrastructure or contact Azure. The normal Bicep
extension-bundle deployment remains unchanged. See deployment-guide.md.
.PARAMETER OutputPath
Destination ZIP. Existing files are preserved unless Force is specified.
.PARAMETER QueueExtensionVersion
Pinned Storage Queues extension 5.x version, supporting identity connections.
.PARAMETER NuGetSource
Optional approved NuGet feed. Empty uses the build workstation's NuGet configuration.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $OutputPath,

    [ValidatePattern('^5\.\d+\.\d+$')]
    [string] $QueueExtensionVersion = '5.3.5',

    [string] $NuGetSource = '',
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
$outputFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
if ([IO.Path]::GetExtension($outputFile) -ne '.zip') { throw 'OutputPath must be a .zip file.' }
if (Test-Path -LiteralPath $outputFile) {
    if (-not $Force -or (Test-Path -LiteralPath $outputFile -PathType Container)) {
        throw "OutputPath already exists: $outputFile. Use -Force to replace an existing ZIP."
    }
}
$sourceRoot = Join-Path $PSScriptRoot 'functions'
if ((Import-PowerShellDataFile -LiteralPath (Join-Path $sourceRoot 'requirements.psd1')).Count -gt 0) {
    throw 'Managed PowerShell dependencies are configured. Pre-stage them before using this package builder.'
}

$dotnet = Get-Command dotnet -CommandType Application -ErrorAction Stop | Select-Object -First 1
$sdks = @(& $dotnet.Source --list-sdks)
if ($LASTEXITCODE -ne 0) { throw 'dotnet --list-sdks failed.' }
if (-not ($sdks | Where-Object { $_ -match '^(\d+)\.' -and [int]$Matches[1] -ge 8 })) {
    throw 'Install .NET SDK 8 or later on the build workstation. The runtime alone is insufficient.'
}

$workingDirectory = Join-Path ([IO.Path]::GetTempPath()) "shr-package-$([guid]::NewGuid().ToString('N'))"
$stagedZip = $null
[IO.Directory]::CreateDirectory($workingDirectory) | Out-Null
try {
    $projectPath = Join-Path $workingDirectory 'extensions.csproj'
    $publishPath = Join-Path $workingDirectory 'publish'
    $packagePath = Join-Path $workingDirectory 'package'
    $sdkVersion = '4.6.0'
    @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <AzureFunctionsVersion>v4</AzureFunctionsVersion>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Sdk.Functions" Version="$sdkVersion" />
    <PackageReference Include="Microsoft.Azure.WebJobs.Extensions.Storage.Queues" Version="$QueueExtensionVersion" />
  </ItemGroup>
</Project>
"@ | Set-Content -LiteralPath $projectPath -Encoding utf8

    $sourceArguments = @()
    if (-not [string]::IsNullOrWhiteSpace($NuGetSource)) { $sourceArguments = @('--source', $NuGetSource) }
    & $dotnet.Source publish $projectPath --configuration Release --output $publishPath --nologo @sourceArguments |
        Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Extension build failed with exit code $LASTEXITCODE. No package was published." }

    $binPath = Join-Path $publishPath 'bin'
    $metadataPath = Join-Path $binPath 'extensions.json'
    $assemblyPath = Join-Path $binPath 'Microsoft.Azure.WebJobs.Extensions.Storage.Queues.dll'
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $assemblyPath -PathType Leaf)) {
        throw 'Extension build did not produce bin\extensions.json and the Storage Queues assembly.'
    }
    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    if (-not ($metadata.extensions | Where-Object {
        $_.typeName -match 'Microsoft\.Azure\.WebJobs\.Extensions\.Storage\.Queues'
    })) {
        throw 'Generated extension metadata does not register the Storage Queues extension.'
    }

    Copy-Item -LiteralPath $publishPath -Destination $packagePath -Recurse
    Copy-Item -LiteralPath $projectPath -Destination (Join-Path $packagePath 'extensions.csproj')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\..\..\LICENSE') -Destination (Join-Path $packagePath 'LICENSE')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'ThirdPartyNotices.txt') -Destination (Join-Path $packagePath 'ThirdPartyNotices.txt')
    foreach ($file in 'profile.ps1', 'requirements.psd1') {
        Copy-Item -LiteralPath (Join-Path $sourceRoot $file) -Destination (Join-Path $packagePath $file)
    }
    $modulesPath = Join-Path $sourceRoot 'Modules'
    foreach ($file in Get-ChildItem -LiteralPath $modulesPath -Recurse -File |
        Where-Object { $_.Extension -in '.psm1', '.psd1' }) {
        $relativePath = [IO.Path]::GetRelativePath($sourceRoot, $file.FullName)
        $destination = Join-Path $packagePath $relativePath
        [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $destination
    }
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'run.ps1') -Destination (Join-Path $packagePath 'shr-cycle.ps1')

    foreach ($function in @(
        @{
            Name = 'session-host-replacer'
            Script = 'scheduler.ps1'
            Binding = @{ type = 'timerTrigger'; direction = 'in'; name = 'Timer'; schedule = '%TimerSchedule%' }
        },
        @{
            Name = 'session-host-replacer-worker'
            Script = 'worker.ps1'
            Binding = @{
                type = 'queueTrigger'; direction = 'in'; name = 'WorkItem'
                queueName = 'shr-continuation'; connection = 'AzureWebJobsStorage'
            }
        }
    )) {
        $directory = Join-Path $packagePath $function.Name
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        Copy-Item -LiteralPath (Join-Path $sourceRoot $function.Script) -Destination (Join-Path $directory 'run.ps1')
        @{ scriptFile = 'run.ps1'; bindings = @($function.Binding) } | ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath (Join-Path $directory 'function.json') -Encoding utf8
    }
    @{
        version = '2.0'
        functionTimeout = '00:10:00'
        managedDependency = @{ enabled = $false }
        extensions = @{ queues = @{ visibilityTimeout = '00:02:00' } }
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $packagePath 'host.json') -Encoding utf8
    @{
        schemaVersion = 2
        targetFramework = 'net8.0'
        functionsSdkVersion = $sdkVersion
        queueExtensionVersion = $QueueExtensionVersion
        timerScheduleSetting = 'TimerSchedule'
        builtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $packagePath 'shr-package.json') -Encoding utf8

    $temporaryZip = Join-Path $workingDirectory 'SessionHostReplacer.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($packagePath, $temporaryZip)
    $outputDirectory = Split-Path -Parent $outputFile
    [IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
    $stagedZip = Join-Path $outputDirectory "shr-package-$([guid]::NewGuid().ToString('N')).tmp"
    Copy-Item -LiteralPath $temporaryZip -Destination $stagedZip
    [IO.File]::Move($stagedZip, $outputFile, $Force.IsPresent)
    [PSCustomObject]@{
        OutputPath = $outputFile
        SHA256 = (Get-FileHash -LiteralPath $outputFile -Algorithm SHA256).Hash
        QueueExtensionVersion = $QueueExtensionVersion
        TimerScheduleSetting = 'TimerSchedule'
    }
} finally {
    if ($stagedZip -and (Test-Path -LiteralPath $stagedZip)) { Remove-Item -LiteralPath $stagedZip -Force }
    Remove-Item -LiteralPath $workingDirectory -Recurse -Force
}
