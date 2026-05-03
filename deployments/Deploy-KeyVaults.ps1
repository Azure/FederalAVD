<#
.SYNOPSIS
    Deploys the AVD Key Vault resources: Secrets Key Vault and/or Encryption Key Vault.

.DESCRIPTION
    Run this script before deploying any AVD solution that uses CMK or references a
    credentials Key Vault. Provide the output resource IDs as inputs to downstream solutions:

      Solution                  | Parameter name(s)
      --------------------------|-------------------------------------------------
      Host Pool                 | credentialsKeyVaultResourceId
                                | encryptionKeyVaultResourceId
      Image Management          | encryptionKeyVaultResourceId
      Image Build               | encryptionKeyVaultResourceId
      Session Host Replacer     | credentialsKeyVaultResourceId
                                | encryptionKeyVaultResourceId
      Storage Quota Manager     | encryptionKeyVaultResourceId

    REQUIRED RBAC for the deploying identity on the Key Vaults:
      - Secrets Key Vault:    'Key Vault Secrets User'    — needed when downstream ARM
                               templates use getSecret() references to resolve credentials.
      - Encryption Key Vault: 'Key Vault Crypto Officer'  — needed at deployment time to
                               create encryption keys via the CMK module. This role may be
                               removed after initial key creation if key rotation is managed
                               separately by the security team.

.PARAMETER Location
    Required. The Azure region where the foundation resources will be deployed.

.PARAMETER ParameterFilePrefix
    Optional. Prefix for the parameter file name. If not provided, defaults based on the
    connected Azure environment:
      - AzureCloud / AzureUSGovernment → 'public'
      - USNat / USSec → 'secret' / 'topsecret'

.EXAMPLE
    .\Deploy-KeyVaults.ps1 -Location 'eastus'

.EXAMPLE
    .\Deploy-KeyVaults.ps1 -Location 'usgovvirginia' -ParameterFilePrefix 'govcloud'
#>

param(
    # The Azure region where the foundation resources will be deployed.
    [Parameter(Mandatory = $true)]
    [string]$Location,

    # Optional prefix for the parameter file.
    [Parameter(Mandatory = $false)]
    [string]$ParameterFilePrefix
)

#region Variables

$ErrorActionPreference = 'Stop'

$Context = Get-AzContext

If ($null -eq $Context) {
    Throw 'You are not logged in to Azure. Please login to Azure before continuing.'
}

$Environment = $Context.Environment.Name

If ($ParameterFilePrefix -ne '' -and $null -ne $ParameterFilePrefix) {
    Write-Output "Using custom parameter file prefix: '$ParameterFilePrefix'."
    $Prefix = $ParameterFilePrefix
}
Else {
    If ($Environment -eq 'AzureCloud' -or $Environment -eq 'AzureUSGovernment') {
        $Prefix = 'public'
    }
    ElseIf ($Environment -match 'USN') {
        $Prefix = 'topsecret'
    }
    Else {
        $Prefix = 'secret'
    }
}

$Time = Get-Date -Format 'yyyyMMddhhmmss'
$TemplatePath = Join-Path -Path $PSScriptRoot -ChildPath 'keyVaults'
$Template = (Get-ChildItem -Path $TemplatePath -Filter 'keyVaults.json' -ErrorAction SilentlyContinue).FullName
$ParameterFilePath = Join-Path -Path $TemplatePath -ChildPath 'parameters'

# Try environment-specific parameter file first, fall back to default
If ($Prefix -ne 'public') {
    $ParameterFile = (Get-ChildItem -Path $ParameterFilePath -Filter "$Prefix.keyVaults.parameters.json" -ErrorAction SilentlyContinue).FullName
}
If ([string]::IsNullOrEmpty($ParameterFile)) {
    $ParameterFile = (Get-ChildItem -Path $ParameterFilePath -Filter 'keyVaults.parameters.json' -ErrorAction SilentlyContinue).FullName
}

If ([string]::IsNullOrEmpty($Template)) {
    Throw "Key Vaults ARM template not found at '$TemplatePath'. Run 'az bicep build --file keyVaults.bicep' to generate 'keyVaults.json'."
}
If ([string]::IsNullOrEmpty($ParameterFile)) {
    Throw "Key Vaults parameter file not found at '$ParameterFilePath'. Ensure 'keyVaults.parameters.json' exists."
}

#endregion Variables

Write-Output ("[{0} entered]" -f $MyInvocation.MyCommand)

#region Deploy Foundation Key Vaults

Write-Verbose "###########################################################################"
Write-Verbose "## 1 - Deploy Foundation Key Vaults                                      ##"
Write-Verbose "###########################################################################"

Write-Output "Deploying Key Vault resources:"
Write-Output "`tTemplate:       '$Template'"
Write-Output "`tParameter file: '$ParameterFile'"
Write-Output "`tLocation:       '$Location'"

New-AzDeployment `
    -Name "KeyVaults-$Time" `
    -Location $Location `
    -TemplateFile $Template `
    -TemplateParameterFile $ParameterFile `
    -Verbose

$DeploymentOutputs = (Get-AzSubscriptionDeployment -Name "KeyVaults-$Time").Outputs

$ResourceGroupName            = $DeploymentOutputs['resourceGroupName']?.Value
$SecretsKeyVaultName          = $DeploymentOutputs['secretsKeyVaultName']?.Value
$SecretsKeyVaultResourceId    = $DeploymentOutputs['secretsKeyVaultResourceId']?.Value
$EncryptionKeyVaultName       = $DeploymentOutputs['encryptionKeyVaultName']?.Value
$EncryptionKeyVaultResourceId = $DeploymentOutputs['encryptionKeyVaultResourceId']?.Value
$EncryptionKeyVaultUri        = $DeploymentOutputs['encryptionKeyVaultUri']?.Value

#endregion

#region Output Foundation Information

Write-Output "`nKey Vault deployment complete."
Write-Output "Resource group:            '$ResourceGroupName'"
Write-Output ""
Write-Output "Secrets Key Vault:"
Write-Output "  Name:        '$SecretsKeyVaultName'"
Write-Output "  Resource ID: '$SecretsKeyVaultResourceId'"
Write-Output ""
Write-Output "Encryption Key Vault:"
Write-Output "  Name:        '$EncryptionKeyVaultName'"
Write-Output "  Resource ID: '$EncryptionKeyVaultResourceId'"
Write-Output "  URI:         '$EncryptionKeyVaultUri'"
Write-Output ""
Write-Output "Use these values in downstream solution deployments:"
Write-Output ""
Write-Output "  Host Pool:"
Write-Output "    credentialsKeyVaultResourceId  = '$SecretsKeyVaultResourceId'"
Write-Output "    encryptionKeyVaultResourceId   = '$EncryptionKeyVaultResourceId'"
Write-Output ""
Write-Output "  Image Management / Image Build / Add-ons:"
Write-Output "    encryptionKeyVaultResourceId   = '$EncryptionKeyVaultResourceId'"

#endregion

Write-Verbose ("[{0} exited]" -f $MyInvocation.MyCommand)
