param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceManagerUri,

    [Parameter(Mandatory=$true)]
    [string]$UserAssignedIdentityClientId,

    [Parameter(Mandatory=$true)]
    [string]$ImageDefinitionResourceId,

    [Parameter(Mandatory=$true)]
    [string]$VmResourceId,

    [Parameter(Mandatory=$true)]
    [string]$Location   
)

$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'

Try {
    # Fix the resource manager URI since only AzureCloud contains a trailing slash
    $ResourceManagerUriFixed = if($ResourceManagerUri[-1] -eq '/'){$ResourceManagerUri.Substring(0,$ResourceManagerUri.Length - 1)} else {$ResourceManagerUri}

    # Get an access token for Azure resources
    $AzureManagementAccessToken = (Invoke-RestMethod `
        -Headers @{Metadata="true"} `
        -Uri $('http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=' + $ResourceManagerUriFixed + '&client_id=' + $UserAssignedIdentityClientId)).access_token

    # Set header for Azure Management API
    $AzureManagementHeader = @{
        'Content-Type'='application/json'
        'Authorization'='Bearer ' + $AzureManagementAccessToken
    }

    $Vm = Invoke-RestMethod `
            -Headers $AzureManagementHeader `
            -Method 'Get' `
            -Uri $($ResourceManagerUriFixed + $VmResourceId + '?api-version=2024-03-01')    

    $ImageDefinition = Invoke-RestMethod `
        -Headers $AzureManagementHeader `
        -Method 'Get' `
        -Uri $($ResourceManagerUriFixed + $ImageDefinitionResourceId + '?api-version=2023-07-03')
    
    $SecurityType = ($ImageDefinition.Features | Where-Object { $_.Name -eq 'SecurityType' }).Value
    
    If ($SecurityType -like '*Supported') {
        $HyperVGeneration = $ImageDefinition.properties.hyperVGeneration

        $Body = @{
            'location' = $Location
            'properties'= @{
                'hyperVGeneration' = $HyperVGeneration
                'sourceVirtualMachine' = @{
                    'id' = $VmResourceId
                }    
            }
        }
        $SubId = $VmResourceId.split('/')[2]
        $RGName = $VmResourceId.split('/')[4]
        $VMName = $VmResourceId.split('/')[-1]

        $Image = Invoke-RestMethod `
            -Body ($Body | ConvertTo-Json) `
            -Headers $AzureManagementHeader `
            -Method 'Put' `
            -Uri $($ResourceManagerUriFixed + 'subscriptions/' + $SubId + '/resourceGroups/' + $RGName + '/providers/Microsoft.Compute/images/img-' + $VMName + '?api-version=2024-03-01')

        $SourceId = $Image.Id
    } Else {
        $SourceId = $Vm.Id
    }
    
    $Output = [pscustomobject][ordered]@{
        SourceId = $SourceId
    }
    $JsonOutput = $Output | ConvertTo-Json
    return $JsonOutput
}
catch {
    throw
}