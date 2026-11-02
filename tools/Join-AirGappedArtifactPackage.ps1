#requires -Version 7.2
<#
.SYNOPSIS
Reassembles release parts into the original air-gapped artifact transfer ZIP.
.DESCRIPTION
Checks every part's filename, size and SHA256, then verifies the complete ZIP
before publishing it. Parts and their manifest must be in the same directory.
Verify the release checksum against your separately approved record as well.
.PARAMETER PartsManifest
Path to the downloaded .zip.parts.json file.
.PARAMETER OutputPath
Optional destination ZIP. Defaults to the original filename beside the manifest.
.PARAMETER Force
Replace an existing ZIP only after successful integrity verification.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$PartsManifest,
    [string]$OutputPath,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$manifestPath = (Get-Item -LiteralPath $PartsManifest -ErrorAction Stop).FullName
$directory = Split-Path -Parent $manifestPath
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$name = [string]$manifest.zipFileName
if ($manifest.schemaVersion -ne 1 -or [string]::IsNullOrWhiteSpace($name) -or
    $name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
    [IO.Path]::GetFileName($name) -ne $name -or [IO.Path]::GetExtension($name) -ne '.zip' -or
    $manifest.zipSHA256 -notmatch '^[0-9a-fA-F]{64}$' -or
    ($manifest.zipSizeBytes -isnot [long] -and $manifest.zipSizeBytes -isnot [int])) {
    throw 'Invalid transfer-parts manifest.'
}
$parts = @($manifest.parts)
if ($parts.Count -lt 2 -or $parts.Count -gt 9999 -or
    $manifest.partSizeBytes -le 0 -or $manifest.partSizeBytes -ge 2GB -or
    $manifest.zipSizeBytes -le 0) {
    throw 'Invalid transfer-parts size or count.'
}
$paths = [Collections.Generic.List[string]]::new()
[long]$total = 0
for ($index = 0; $index -lt $parts.Count; $index++) {
    $part = $parts[$index]
    $expectedName = '{0}.part{1:D3}' -f $name, ($index + 1)
    $expectedSize = if ($index -eq $parts.Count - 1) {
        $manifest.zipSizeBytes - $total
    } else { $manifest.partSizeBytes }
    if ($part.fileName -cne $expectedName -or
        $part.sha256 -notmatch '^[0-9a-fA-F]{64}$' -or
        $part.sizeBytes -ne $expectedSize -or $expectedSize -le 0 -or
        $expectedSize -gt $manifest.partSizeBytes) {
        throw "Invalid transfer part at index $index."
    }
    $path = Join-Path $directory $expectedName
    $file = Get-Item -LiteralPath $path -ErrorAction Stop
    if ($file.PSIsContainer -or $file.Length -ne $expectedSize -or
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $part.sha256) {
        throw "Transfer part integrity check failed: $expectedName"
    }
    $total += $file.Length
    $paths.Add($file.FullName)
}
if ($total -ne $manifest.zipSizeBytes) { throw 'Transfer part lengths do not match the ZIP size.' }
if (-not $OutputPath) { $OutputPath = Join-Path $directory $name }
$outputFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
if ([IO.Path]::GetExtension($outputFile) -ne '.zip') { throw 'OutputPath must be a .zip file.' }
if ((Test-Path -LiteralPath $outputFile) -and
    (-not $Force -or (Test-Path -LiteralPath $outputFile -PathType Container))) {
    throw "Output already exists: $outputFile. Use -Force to replace a file."
}
$checksumPath = "$outputFile.sha256"
$checksumExists = Test-Path -LiteralPath $checksumPath
if ($checksumExists) {
    $expectedHash = ((Get-Content -LiteralPath $checksumPath -Raw).Trim() -split '\s+')[0]
    if ($expectedHash -ne $manifest.zipSHA256) { throw 'ZIP checksum record disagrees with the parts manifest.' }
}
$outputDirectory = Split-Path -Parent $outputFile
[IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
$stagedZip = Join-Path $outputDirectory "airgap-join-$([guid]::NewGuid().ToString('N')).tmp"
$stagedChecksum = "$stagedZip.sha256"
try {
    $stream = [IO.File]::Open($stagedZip, [IO.FileMode]::CreateNew)
    try {
        foreach ($path in $paths) {
            $partStream = [IO.File]::OpenRead($path)
            try { $partStream.CopyTo($stream) } finally { $partStream.Dispose() }
        }
    } finally { $stream.Dispose() }
    $hash = (Get-FileHash -LiteralPath $stagedZip -Algorithm SHA256).Hash
    if ((Get-Item -LiteralPath $stagedZip).Length -ne $manifest.zipSizeBytes -or
        $hash -ne $manifest.zipSHA256) {
        throw 'Reassembled ZIP integrity check failed.'
    }
    if (-not $checksumExists) {
        "$hash  $([IO.Path]::GetFileName($outputFile))" |
            Set-Content -LiteralPath $stagedChecksum -Encoding ascii
    }
    [IO.File]::Move($stagedZip, $outputFile, $Force.IsPresent)
    if (-not $checksumExists) { [IO.File]::Move($stagedChecksum, $checksumPath, $false) }
    [pscustomobject]@{OutputPath=$outputFile; SHA256=$hash; PartCount=$parts.Count}
} finally {
    foreach ($path in @($stagedZip, $stagedChecksum)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
}
