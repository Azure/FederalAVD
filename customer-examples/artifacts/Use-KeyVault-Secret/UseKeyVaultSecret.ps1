param(
    [Parameter(Mandatory = $true)]
    [string] $VaultBaseUrl,   # Fully-qualified Key Vault URL

    [Parameter(Mandatory = $true)]
    [string] $SecretName,

    [Parameter(Mandatory = $true)]
    [string] $UserAssignedIdentityClientId
)

# ============================================================
# Normalize vault URL
# ============================================================

$VaultBaseUrl = $VaultBaseUrl.TrimEnd("/")

$uri = [Uri]$VaultBaseUrl
$kvHost = $uri.Host   # e.g. myvault.vault.usgovcloudapi.net

# ============================================================
# Derive resource from DNS suffix
# ============================================================

$labels = $kvHost.Split('.')
if ($labels.Count -lt 2) {
    throw "VaultBaseUrl host '$kvHost' is not valid for deriving resource."
}

# Drop the first label (vault name), keep suffix
$suffix = ($labels[1..($labels.Count - 1)] -join '.')
$resource = "https://$suffix"

Write-Output "Using resource: $resource"

# ============================================================
# Get token from IMDS using UAI
# ============================================================

$imdsUrl = "http://169.254.169.254/metadata/identity/oauth2/token" +
           "?api-version=2018-02-01" +
           "&resource=$([Uri]::EscapeDataString($resource))" +
           "&client_id=$UserAssignedIdentityClientId"

$tokenResponse = Invoke-RestMethod -Method GET `
    -Uri $imdsUrl `
    -Headers @{ "Metadata" = "true" }

$accessToken = $tokenResponse.access_token

if (-not $accessToken) {
    throw "Failed to obtain access token from IMDS."
}

# ============================================================
# Build Key Vault REST URL
# ============================================================

$kvUri = $VaultBaseUrl + '/secrets/' + $SecretName + '?api-version=2025-07-01'

# ============================================================
# Retrieve secret
# ============================================================

$secretResponse = Invoke-RestMethod -Method GET `
    -Uri $kvUri `
    -Headers @{ "Authorization" = "Bearer $accessToken" }

# ============================================================
# Store secret value
# ============================================================

$SecretValue = $secretResponse.value

Write-Output "Secret successfully retrieved."
Write-Output "Secret value length: $($SecretValue.Length)"