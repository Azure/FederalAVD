[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$DownloadsPath,

    [string]$ArtifactsRoot = 'customer/artifacts',

    [switch]$FailOnIncompatible
)

$ErrorActionPreference = 'Stop'
$downloads = Get-Content -LiteralPath $DownloadsPath -Raw | ConvertFrom-Json
$results = [System.Collections.Generic.List[object]]::new()
$incompatibleCount = 0

foreach ($property in $downloads.PSObject.Properties) {
    $entry = $property.Value
    $sourceType = 'PreStagedOnly'
    $status = 'Review'

    if ($entry.WingetId) {
        $sourceType = 'WingetId'
        $status = 'Incompatible'
        $incompatibleCount++
    } elseif ($entry.GitHubRepo) {
        $sourceType = 'GitHubRepo'
        $status = 'RequiresConnectivityOrPreStage'
    } elseif ($entry.APIUrl) {
        $sourceType = 'APIUrl'
        $status = 'RequiresConnectivityOrPreStage'
    } elseif ($entry.WebSiteUrl) {
        $sourceType = 'WebSiteUrl'
        $status = 'RequiresConnectivityOrPreStage'
    } elseif ($entry.DownloadUrl) {
        $sourceType = 'DownloadUrl'
        $status = 'VerifyReachability'
    }

    $destinations = @($entry.DestinationFolders)
    $stagedPaths = @()
    if ($entry.DestinationFileName) {
        foreach ($destination in $destinations) {
            $candidate = if ([string]::IsNullOrWhiteSpace($destination)) {
                Join-Path $ArtifactsRoot $entry.DestinationFileName
            } else {
                Join-Path (Join-Path $ArtifactsRoot $destination) $entry.DestinationFileName
            }
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $stagedPaths += $candidate
            }
        }
    }

    if ($stagedPaths.Count -gt 0) {
        $status = 'Staged'
    }

    $results.Add([pscustomobject]@{
        Name = $property.Name
        SourceType = $sourceType
        DestinationFileName = $entry.DestinationFileName
        DestinationFolders = $destinations -join ', '
        Status = $status
        StagedPaths = $stagedPaths -join ', '
    })
}

$results | Sort-Object Status, Name | Format-Table -AutoSize

if ($FailOnIncompatible -and $incompatibleCount -gt 0) {
    Write-Error "$incompatibleCount downloads use WingetId and are not air-gapped compatible."
    exit 1
}

Write-Output "Reviewed $($results.Count) download entries; incompatible: $incompatibleCount."
