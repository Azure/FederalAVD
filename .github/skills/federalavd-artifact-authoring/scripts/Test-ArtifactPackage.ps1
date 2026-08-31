[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ArtifactPath,

    [string]$DownloadsPath = 'customer-examples/parameters/imageManagement/downloads.json'
)

$ErrorActionPreference = 'Stop'
$artifact = Get-Item -LiteralPath $ArtifactPath
$errors = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

if (-not (Test-Path -LiteralPath (Join-Path $artifact.FullName 'README.md'))) {
    $errors.Add("Missing README.md in '$($artifact.FullName)'.")
}

$rootPowerShellFiles = @(Get-ChildItem -LiteralPath $artifact.FullName -Filter '*.ps1' -File)
if ($rootPowerShellFiles.Count -ne 1) {
    $errors.Add("Artifact '$($artifact.FullName)' must contain exactly one PowerShell script in its root. Found $($rootPowerShellFiles.Count). Place helper scripts in a subdirectory.")
}

$powerShellFiles = @(Get-ChildItem -LiteralPath $artifact.FullName -Filter '*.ps1' -File -Recurse)
foreach ($file in $powerShellFiles) {
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $file.FullName) {
        $lineNumber++
        if ($line -match '[^\x00-\x7E]') {
            $errors.Add("Non-ASCII content: $($file.FullName):$lineNumber")
        }
    }
}

if (Test-Path -LiteralPath $DownloadsPath -PathType Leaf) {
    $downloads = Get-Content -LiteralPath $DownloadsPath -Raw | ConvertFrom-Json
    $matchingEntries = @(
        foreach ($property in $downloads.PSObject.Properties) {
            $destinations = @($property.Value.DestinationFolders)
            if ($destinations -contains $artifact.Name) {
                $property.Name
            }
        }
    )

    if ($matchingEntries.Count -eq 0) {
        $warnings.Add("No downloads.json entry targets '$($artifact.Name)'. This is valid for artifacts with no external payload.")
    } else {
        Write-Output "Download entries: $($matchingEntries -join ', ')"
    }
} else {
    $warnings.Add("Downloads manifest not found at '$DownloadsPath'.")
}

foreach ($warning in $warnings) {
    Write-Warning $warning
}

if ($errors.Count -gt 0) {
    foreach ($validationError in $errors) {
        Write-Error $validationError
    }
    exit 1
}

Write-Output "Artifact validation passed: $($artifact.FullName)"
