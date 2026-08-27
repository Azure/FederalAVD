[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({
        foreach ($path in $_) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        }
        return $true
    })]
    [string[]]$ParameterPath
)

$ErrorActionPreference = 'Stop'
$values = @{}
$sources = @{}
$results = [System.Collections.Generic.List[object]]::new()

foreach ($path in $ParameterPath) {
    $file = Get-Item -LiteralPath $path
    $document = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
    $parameters = if ($document.parameters) { $document.parameters } else { $document }
    foreach ($property in $parameters.PSObject.Properties) {
        $value = if ($null -ne $property.Value.value) { $property.Value.value } else { $property.Value }
        if ($values.ContainsKey($property.Name) -and (($values[$property.Name] | ConvertTo-Json -Compress) -ne ($value | ConvertTo-Json -Compress))) {
            $results.Add([pscustomobject]@{
                Check = "Consistent $($property.Name)"
                Status = 'Failed'
                Detail = "Conflicting values in '$($sources[$property.Name])' and '$($file.FullName)'."
            })
        }
        $values[$property.Name] = $value
        $sources[$property.Name] = $file.FullName
    }
}

function Test-RequiredValue {
    param(
        [string]$WhenName,
        [scriptblock]$When,
        [string]$RequiredName,
        [string]$Detail
    )
    if ($values.ContainsKey($WhenName) -and (& $When $values[$WhenName])) {
        $present = $values.ContainsKey($RequiredName) -and -not [string]::IsNullOrWhiteSpace([string]$values[$RequiredName])
        $results.Add([pscustomobject]@{
            Check = "$WhenName -> $RequiredName"
            Status = if ($present) { 'Passed' } else { 'Failed' }
            Detail = $Detail
        })
    }
}

$customerManaged = { param($value) -not [string]::IsNullOrWhiteSpace([string]$value) -and $value -ne 'PlatformManaged' }
foreach ($name in @('keyManagementStorageAccounts', 'keyManagementGalleryImageVersions')) {
    Test-RequiredValue -WhenName $name -When $customerManaged -RequiredName 'encryptionKeyVaultResourceId' -Detail 'Image Management CMK requires the AVD Shared Services encryption Key Vault output.'
}
$diskEncryptionKeyVaultParameter = if ($values.ContainsKey('deployDynamicScalingPlan')) {
    'encryptionKeyVaultResourceId'
} else {
    'existingEncryptionKeyVaultResourceId'
}
Test-RequiredValue -WhenName 'keyManagementDisks' -When $customerManaged -RequiredName $diskEncryptionKeyVaultParameter -Detail 'Host Pool disk CMK requires an encryption Key Vault resource ID.'
foreach ($name in @('keyManagementStorage', 'keyManagementRecoveryServicesVault')) {
    Test-RequiredValue -WhenName $name -When $customerManaged -RequiredName 'existingEncryptionKeyVaultResourceId' -Detail 'Host Pool CMK requires an existing encryption Key Vault resource ID.'
}

Test-RequiredValue -WhenName 'imageBuildResourceGroupId' -When { param($value) -not [string]::IsNullOrWhiteSpace([string]$value) } -RequiredName 'userAssignedIdentityResourceId' -Detail 'The existing image-build resource group path requires the Image Management identity output.'
Test-RequiredValue -WhenName 'collectCustomizationLogs' -When { param($value) $value -eq $true } -RequiredName 'logStorageAccountResourceId' -Detail 'Customization log collection requires the Image Management build-logs storage output.'
Test-RequiredValue -WhenName 'collectCustomizationLogs' -When { param($value) $value -eq $true } -RequiredName 'userAssignedIdentityResourceId' -Detail 'Customization log collection requires the Image Management identity output.'
Test-RequiredValue -WhenName 'galleryImageVersionConfidentialVMEncryptionType' -When { param($value) $value -eq 'EncryptedWithCmk' } -RequiredName 'confidentialVMDiskEncryptionSetResourceId' -Detail 'Confidential VM CMK encryption requires the matching Disk Encryption Set output.'
Test-RequiredValue -WhenName 'existingLogAnalyticsWorkspaceResourceId' -When { param($value) -not [string]::IsNullOrWhiteSpace([string]$value) } -RequiredName 'existingAVDInsightsDataCollectionRuleResourceId' -Detail 'Shared host-pool monitoring should reuse the matching AVD Insights DCR.'
Test-RequiredValue -WhenName 'existingLogAnalyticsWorkspaceResourceId' -When { param($value) -not [string]::IsNullOrWhiteSpace([string]$value) } -RequiredName 'existingDataCollectionEndpointResourceId' -Detail 'Shared host-pool monitoring should reuse the matching data collection endpoint.'

if ($results.Count -eq 0) {
    Write-Output 'No conditional dependency checks were activated by the supplied parameter files.'
    exit 0
}

$results | Format-Table -AutoSize
$failed = @($results | Where-Object Status -eq 'Failed')
if ($failed.Count -gt 0) {
    Write-Error "$($failed.Count) deployment dependency check(s) failed."
    exit 1
}

Write-Output "All $($results.Count) activated deployment dependency checks passed."
