<#
.SYNOPSIS
    Creates or updates a local service account using a password stored in Azure Key Vault.

.DESCRIPTION
    Retrieves one Key Vault secret with a user-assigned managed identity, creates or updates the
    local account, and adds it to the requested local groups. Rerunning the script updates the
    account password to the current secret value.

.NOTES
    Run this as a session-host customization, not during image creation.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string] $AccountName,

    [Parameter(Mandatory = $true)]
    [string] $KeyVaultUri,

    [Parameter(Mandatory = $true)]
    [string] $SecretName,

    [Parameter(Mandatory = $true)]
    [guid] $UserAssignedIdentityClientId,

    [Parameter()]
    [string[]] $LocalGroups = @(),

    [Parameter()]
    [ValidateLength(0, 48)]
    [string] $Description = 'Managed local service account'
)

$ErrorActionPreference = 'Stop'

if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) {
    throw 'Run this artifact with 64-bit PowerShell.'
}

$vault = [Uri]$KeyVaultUri.TrimEnd('/')
if ($vault.Scheme -ne 'https' -or $vault.AbsolutePath -ne '/') {
    throw 'KeyVaultUri must be the Key Vault URI copied from the Azure portal.'
}

$vaultResource = 'https://' + ($vault.Host -replace '^[^.]+\.', '')
$tokenUri = 'http://169.254.169.254/metadata/identity/oauth2/token' +
    '?api-version=2018-02-01' +
    "&resource=$([Uri]::EscapeDataString($vaultResource))" +
    "&client_id=$([Uri]::EscapeDataString($UserAssignedIdentityClientId.ToString()))"

$tokenResponse = Invoke-RestMethod `
    -Method Get `
    -Uri $tokenUri `
    -Headers @{ Metadata = 'true' } `
    -TimeoutSec 30

if ([string]::IsNullOrWhiteSpace($tokenResponse.access_token)) {
    throw 'Managed identity token request did not return an access token.'
}

$secretUri = "$($vault.AbsoluteUri.TrimEnd('/'))/secrets/$SecretName?api-version=2025-07-01"
$secretResponse = Invoke-RestMethod `
    -Method Get `
    -Uri $secretUri `
    -Headers @{ Authorization = "Bearer $($tokenResponse.access_token)" } `
    -TimeoutSec 30

if ([string]::IsNullOrEmpty($secretResponse.value)) {
    throw "Key Vault secret '$SecretName' is empty."
}

$password = ConvertTo-SecureString -String $secretResponse.value -AsPlainText -Force
$secretResponse.value = $null
$tokenResponse.access_token = $null

Import-Module Microsoft.PowerShell.LocalAccounts -ErrorAction Stop

$account = Get-LocalUser -Name $AccountName -ErrorAction SilentlyContinue
if ($null -eq $account) {
    $account = New-LocalUser `
        -Name $AccountName `
        -Password $password `
        -Description $Description `
        -AccountNeverExpires `
        -PasswordNeverExpires `
        -UserMayNotChangePassword
    Write-Output "Created local service account '$AccountName'."
}
else {
    Set-LocalUser `
        -InputObject $account `
        -Password $password `
        -Description $Description `
        -AccountNeverExpires `
        -PasswordNeverExpires $true `
        -UserMayChangePassword $false
    Enable-LocalUser -InputObject $account
    Write-Output "Updated local service account '$AccountName'."
}

foreach ($groupName in $LocalGroups) {
    $group = Get-LocalGroup -Name $groupName -ErrorAction Stop
    $isMember = Get-LocalGroupMember -Group $group -ErrorAction Stop |
        Where-Object { $_.SID -eq $account.SID }

    if (-not $isMember) {
        Add-LocalGroupMember -Group $group -Member $account
        Write-Output "Added '$AccountName' to '$groupName'."
    }
}

$password.Dispose()
Write-Output "Local service account '$env:COMPUTERNAME\$AccountName' is configured."