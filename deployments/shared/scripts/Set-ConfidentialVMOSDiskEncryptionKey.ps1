[CmdletBinding()]
param (
    [string]$KeyName,
    [string]$Tags,
    [string]$UserAssignedIdentityClientId,
    [string]$VaultUri
)

$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'

# Fix the Vault URI since only AzureCloud contains a trailing slash
$VaultUriFixed = if($VaultUri[-1] -eq '/'){$VaultUri.Substring(0,$VaultUri.Length - 1)} else {$VaultUri}

$PolicyContentJson = @"
{"version":"1.0.0","anyOf":[{"authority":"https://sharedeus.eus.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"tdxvm"},{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://sharedwus.wus.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"tdxvm"},{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://sharedneu.neu.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"tdxvm"},{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://sharedweu.weu.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"tdxvm"},{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://sharedsasia.sasia.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"tdxvm"},{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://sharedeasia.easia.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"tdxvm"},{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://sharedjpe.jpe.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"tdxvm"},{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://sharedswn.swn.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"tdxvm"},{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://shareditn.itn.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"tdxvm"},{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://sharedeus2.eus2.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"tdxvm"},{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://sharedeus2e.eus2e.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"tdxvm"},{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://sharedscus.scus.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://sharedcuse.cuse.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://sharedcus.cus.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"tdxvm"},{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://sharedeau.eau.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"tdxvm"},{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://sharedsau.sau.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"tdxvm"},{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://sharedcin.cin.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://shareduaen.uaen.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://shareddewc.dewc.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]},{"authority":"https://sharedwus3.wus3.attest.azure.net/","allOf":[{"claim":"x-ms-compliance-status","equals":"azure-compliant-cvm"},{"anyOf":[{"claim":"x-ms-attestation-type","equals":"tdxvm"},{"claim":"x-ms-attestation-type","equals":"sevsnpvm"}]}]}]}
"@
If ($Tags -ne '{}') {
    [PSCustomObject]$TagsObject = $Tags | ConvertFrom-Json
}
try 
{
    # Get an access token for Azure resources
    $AzureKeyVaultAccessToken = (Invoke-RestMethod `
        -Headers @{Metadata="true"} `
        -Uri $('http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=' + $VaultUriFixed + '&client_id=' + $UserAssignedIdentityClientId)).access_token

    # Set header for Azure Management API
    $AzureKeyVaultHeader = @{
        'Content-Type'='application/json'
        'Authorization'='Bearer ' + $AzureKeyVaultAccessToken
    }

    $Key = (Invoke-RestMethod `
        -Headers $AzureKeyVaultHeader `
        -Method 'GET' `
        -Uri $($VaultUriFixed + '/keys?api-version=7.4')).value | Where-Object { $_.kid -eq "$VaultUriFixed/keys/$KeyName" }
        
    If (!$Key) {
        #$PolicyContentJson | ConvertFrom-Json | ConvertTo-Json -Depth 100
        $Release_Policy_Data = [Convert]::ToBase64String([char[]]$PolicyContentJson)
        $Body = (@{
            attributes = @{
                enabled = $true
                exportable = $true
            }
            kty='RSA-HSM'
            key_size=4096
            key_ops=@('encrypt', 'decrypt', 'sign', 'verify', 'wrapKey', 'unwrapKey')
            release_policy=@{
                data=$Release_Policy_Data
            }
        })
        If($TagsObject) {
            $Body.tags = $TagsObject
        }
        $Body = $Body | ConvertTo-Json -Depth 100 -Compress

        Invoke-RestMethod `
            -Headers $AzureKeyVaultHeader `
            -Method 'POST' `
            -Uri $($VaultUriFixed + '/keys/' + $KeyName + '/create?api-version=7.4') `
            -Body $Body
    }
}
catch 
{
    Write-Error -Message "Failed to create or retrieve the key from the Key Vault. $_"
    throw
}