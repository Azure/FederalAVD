[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({
        foreach ($path in $_) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        }
        return $true
    })]
    [string[]]$ParameterPath,

    [string]$CsvPath
)

$ErrorActionPreference = 'Stop'
$relevantNames = @(
    'deployMonitoring',
    'enableMonitoring',
    'deployPrivateEndpoints',
    'permittedIPs',
    'hostPoolPublicNetworkAccess',
    'workspaceFeedPublicNetworkAccess',
    'keyExpirationInDays',
    'keyManagementDisks',
    'keyManagementStorage',
    'keyManagementRecoveryServicesVault',
    'keyManagementStorageAccounts',
    'keyManagementGalleryImageVersions',
    'securityType',
    'encryptionAtHost',
    'deployToDedicatedHosts',
    'dedicatedHostGroupResourceId',
    'recoveryServices',
    'recoveryServicesVaultStorageRedundancy',
    'fslogixStorageRedundancy',
    'logAnalyticsWorkspaceResourceId',
    'existingLogAnalyticsWorkspaceResourceId'
)

$evidence = [System.Collections.Generic.List[object]]::new()
foreach ($path in $ParameterPath) {
    $file = Get-Item -LiteralPath $path
    $document = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
    $parameters = if ($document.parameters) { $document.parameters } else { $document }

    foreach ($name in $relevantNames) {
        $property = $parameters.PSObject.Properties[$name]
        if ($null -eq $property) { continue }
        $rawValue = if ($null -ne $property.Value.value) { $property.Value.value } else { $property.Value }
        $displayValue = if ($name -match '(?i)password|secret|token|credential') {
            '<redacted>'
        } elseif ($null -eq $rawValue) {
            '<null>'
        } elseif ($rawValue -is [string] -or $rawValue -is [ValueType]) {
            [string]$rawValue
        } else {
            $rawValue | ConvertTo-Json -Depth 20 -Compress
        }

        $evidence.Add([pscustomobject]@{
            Parameter = $name
            Value = $displayValue
            File = $file.FullName
        })
    }
}

$conflicts = @(
    $evidence |
        Group-Object Parameter |
        Where-Object { @($_.Group.Value | Select-Object -Unique).Count -gt 1 }
)

$evidence | Sort-Object Parameter, File | Format-Table -AutoSize
foreach ($conflict in $conflicts) {
    Write-Warning "Conflicting values found for parameter '$($conflict.Name)'."
}

if ($CsvPath) {
    $evidence | Sort-Object Parameter, File | Export-Csv -LiteralPath $CsvPath -NoTypeInformation
    Write-Output "Evidence exported to '$CsvPath'."
}

Write-Output "Collected $($evidence.Count) compliance-relevant parameter values from $($ParameterPath.Count) file(s)."
