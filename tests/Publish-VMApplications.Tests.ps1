$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$publisherPath = Join-Path -Path $repoRoot -ChildPath 'deployments\Publish-VMApplications.ps1'
$manifestPath = Join-Path -Path $repoRoot -ChildPath 'customer-examples\parameters\imageManagement\vmApplications.json'

$tokens = $null
$parseErrors = $null
[Management.Automation.Language.Parser]::ParseFile($publisherPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count -gt 0) {
    throw "Publisher has $($parseErrors.Count) PowerShell parse error(s)."
}
if (Get-Content -LiteralPath $publisherPath | Where-Object { $_ -match '[^\x00-\x7E]' }) {
    throw 'Publisher contains non-ASCII content.'
}

$validationOutput = @(& $publisherPath -ManifestPath $manifestPath -ValidateOnly)
if ($validationOutput.Count -ne 0) {
    throw 'ValidateOnly wrote unexpected objects to the success stream.'
}

$invalidManifestPath = Join-Path -Path $env:TEMP -ChildPath 'FederalAVD-invalid-vmApplications.json'
[IO.File]::WriteAllText(
    $invalidManifestPath,
    '{"applications":[{"name":"Bad","version":"1.0.0","packageBlob":"Bad.exe","supportedOSType":"Windows","install":"install","remove":"remove","targetRegions":[{"name":"eastus2"}]}]}',
    [Text.Encoding]::ASCII
)
try {
    $invalidRejected = $false
    try {
        & $publisherPath -ManifestPath $invalidManifestPath -ValidateOnly
    }
    catch {
        $invalidRejected = $_.Exception.Message -match 'must reference a \.zip'
    }
    if (-not $invalidRejected) {
        throw 'ValidateOnly did not reject a non-ZIP package.'
    }
}
finally {
    Remove-Item -LiteralPath $invalidManifestPath -Force -ErrorAction SilentlyContinue
}

$global:vmApplicationTestState = @{
    ApplicationExists = $false
    VersionExists = $false
    VersionPayload = $null
    VersionPutCount = 0
}

function global:Get-AzContext {
    return [pscustomobject]@{
        Environment = [pscustomobject]@{
            Name = 'AzureUSGovernment'
            StorageEndpointSuffix = 'core.usgovcloudapi.net'
        }
    }
}

function global:Invoke-AzRestMethod {
    param (
        [string]$Method,
        [string]$Path,
        [string]$Payload
    )

    $state = $global:vmApplicationTestState
    $response = @{ StatusCode = 200; Content = '{}' }

    if ($Path -match '/galleries/gallery-test\?') {
        $response.Content = '{"location":"usgovvirginia","identity":{"type":"UserAssigned","userAssignedIdentities":{"/subscriptions/test/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uai":{}}}}'
    }
    elseif ($Path -match '/applications/Contoso-Agent/versions/1\.0\.0') {
        if ($Method -eq 'PUT') {
            $state.VersionExists = $true
            $state.VersionPayload = $Payload
            $state.VersionPutCount++
            $response.StatusCode = 201
        }
        elseif (-not $state.VersionExists) {
            $response.StatusCode = 404
            $response.Content = ''
        }
        else {
            $version = $state.VersionPayload | ConvertFrom-Json -Depth 20
            $response.Content = [ordered]@{
                properties = [ordered]@{
                    provisioningState = 'Succeeded'
                    replicationStatus = [ordered]@{
                        aggregatedState = 'Completed'
                        summary = @([ordered]@{ region = 'eastus2'; state = 'Completed'; progress = 100 })
                    }
                }
                tags = $version.tags
            } | ConvertTo-Json -Depth 20 -Compress
        }
    }
    elseif ($Path -match '/applications/Contoso-Agent\?') {
        if ($Method -eq 'PUT') {
            $state.ApplicationExists = $true
            $response.StatusCode = 201
        }
        elseif (-not $state.ApplicationExists) {
            $response.StatusCode = 404
            $response.Content = ''
        }
        else {
            $response.Content = '{"properties":{"supportedOSType":"Windows"}}'
        }
    }
    else {
        throw "Unexpected mocked ARM request: $Method $Path"
    }

    return [pscustomobject]$response
}

try {
    $galleryId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/galleries/gallery-test'
    $storageId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/sttest'
    $result = @(& $publisherPath `
        -ManifestPath $manifestPath `
        -GalleryResourceId $galleryId `
        -StorageAccountResourceId $storageId `
        -PollingIntervalSeconds 5 `
        -TimeoutMinutes 1)

    if ($result.Count -ne 1) {
        throw "Expected one publisher output object, received $($result.Count)."
    }
    $expectedId = "$galleryId/applications/Contoso-Agent/versions/1.0.0"
    if ($result[0].packageReferenceId -ne $expectedId) {
        throw 'Publisher returned an incorrect packageReferenceId.'
    }

    $payload = $global:vmApplicationTestState.VersionPayload | ConvertFrom-Json -Depth 20
    $mediaLink = $payload.properties.publishingProfile.source.mediaLink
    $expectedMediaLink = 'https://sttest.blob.core.usgovcloudapi.net/artifacts/Contoso-Agent.zip'
    if ($mediaLink -ne $expectedMediaLink) {
        throw "Publisher returned an incorrect mediaLink: $mediaLink"
    }
    if ($mediaLink.Contains('?')) {
        throw 'Publisher added a query string or SAS token to the package URL.'
    }
    if ($payload.properties.publishingProfile.settings.packageFileName -ne 'Contoso-Agent.zip') {
        throw 'Publisher did not preserve the ZIP package filename.'
    }

    $rerunResult = @(& $publisherPath `
        -ManifestPath $manifestPath `
        -GalleryResourceId $galleryId `
        -StorageAccountResourceId $storageId `
        -PollingIntervalSeconds 5 `
        -TimeoutMinutes 1)
    if ($rerunResult.Count -ne 1 -or $global:vmApplicationTestState.VersionPutCount -ne 1) {
        throw 'An identical manifest rerun was not idempotent.'
    }

    $conflictManifestPath = Join-Path -Path $env:TEMP -ChildPath 'FederalAVD-conflicting-vmApplications.json'
    $conflictingManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 20
    $conflictingManifest.applications[0].install = 'different install command'
    [IO.File]::WriteAllText(
        $conflictManifestPath,
        ($conflictingManifest | ConvertTo-Json -Depth 20),
        [Text.Encoding]::ASCII
    )
    try {
        $conflictRejected = $false
        try {
            & $publisherPath `
                -ManifestPath $conflictManifestPath `
                -GalleryResourceId $galleryId `
                -StorageAccountResourceId $storageId `
                -PollingIntervalSeconds 5 `
                -TimeoutMinutes 1
        }
        catch {
            $conflictRejected = $_.Exception.Message -match 'already exists with different publication settings'
        }
        if (-not $conflictRejected) {
            throw 'A changed manifest reused an existing semantic version without a conflict.'
        }
    }
    finally {
        Remove-Item -LiteralPath $conflictManifestPath -Force -ErrorAction SilentlyContinue
    }
}
finally {
    Remove-Item function:\Get-AzContext -ErrorAction SilentlyContinue
    Remove-Item function:\Invoke-AzRestMethod -ErrorAction SilentlyContinue
    Remove-Variable vmApplicationTestState -Scope Global -ErrorAction SilentlyContinue
}

Write-Output 'Publish-VMApplications tests passed.'