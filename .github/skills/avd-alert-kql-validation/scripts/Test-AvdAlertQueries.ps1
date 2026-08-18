[CmdletBinding()]
param(
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ModulePath = 'deployments/add-ons/avdAlerts/modules',

    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$results = [System.Collections.Generic.List[object]]::new()
$errors = [System.Collections.Generic.List[string]]::new()
$tripleQuote = "'''"

if ($OutputDirectory) {
    $null = New-Item -Path $OutputDirectory -ItemType Directory -Force
}

foreach ($file in Get-ChildItem -LiteralPath $ModulePath -Filter '*.bicep' -File -Recurse) {
    $lines = @(Get-Content -LiteralPath $file.FullName)
    $resourceName = $null
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match "^resource\s+(?<name>[A-Za-z0-9_]+)\s+'Microsoft\.Insights/scheduledQueryRules@") {
            $resourceName = $Matches.name
        }
        if ($resourceName -and $lines[$index] -match 'query:' -and $lines[$index].Contains($tripleQuote)) {
            $startLine = $index + 1
            $queryLines = [System.Collections.Generic.List[string]]::new()
            $openingPosition = $lines[$index].IndexOf($tripleQuote) + $tripleQuote.Length
            $openingRemainder = $lines[$index].Substring($openingPosition)
            if ($openingRemainder) {
                $queryLines.Add($openingRemainder)
            }
            $index++
            while ($index -lt $lines.Count -and -not $lines[$index].Contains($tripleQuote)) {
                $queryLines.Add($lines[$index])
                $index++
            }
            if ($index -ge $lines.Count) {
                $errors.Add("Unterminated query for '$resourceName' in '$($file.FullName):$startLine'.")
                continue
            }

            $query = ($queryLines -join [Environment]::NewLine).Trim()
            if ([string]::IsNullOrWhiteSpace($query)) {
                $errors.Add("Empty query for '$resourceName' in '$($file.FullName):$startLine'.")
            }
            if ($query -match '(?im)^\s*\|?\s*render\s+') {
                $errors.Add("Alert query '$resourceName' contains a workbook-only render clause.")
            }

            $result = [pscustomobject]@{
                Resource = $resourceName
                File = $file.FullName
                StartLine = $startLine
                Query = $query
            }
            $results.Add($result)

            if ($OutputDirectory) {
                $outputPath = Join-Path $OutputDirectory ("$resourceName.kql")
                Set-Content -LiteralPath $outputPath -Value $query -Encoding utf8
            }
        }
    }
}

if ($results.Count -eq 0) {
    $errors.Add("No scheduled query rules with embedded KQL were found under '$ModulePath'.")
}

$results | Select-Object Resource, File, StartLine | Format-Table -AutoSize

if ($errors.Count -gt 0) {
    foreach ($validationError in $errors) {
        Write-Error $validationError
    }
    exit 1
}

Write-Output "Validated $($results.Count) embedded alert queries."
