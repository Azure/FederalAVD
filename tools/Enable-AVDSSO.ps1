[CmdletBinding()]
param (
    [Parameter()]
    [string]
    $Environment = 'AzureUSGovernment',
    [Parameter()]
    [array]
    $DeviceGroups = @(@{'id' = 'f9bf0413-cccc-4090-b6e7-3a910aa24ab8'; 'displayName' = 'AVD West Session Hosts'})
)
switch ($environment) {
    AzureUSGovernment {
        $graphUri = 'https://graph.microsoft.us'
        $graphEnv = 'USGov'
    }
    Default {
        $graphUri = 'https://graph.microsoft.com'
    }
}
Connect-AzAccount -Environment $Environment
If ($graphEnv) { Connect-MgGraph -Environment $graphEnv }
Else { Connect-MgGraph }
$AppIds = 'a4a365df-50f1-4397-bc59-1a1564b8bb9c','270efc09-cd0d-444b-a71f-39af4910ec45'
$Token = (Get-AzAccessToken -ResourceUrl $graphUri).token
$ContentType = 'application/json'
$Headers = @{
    "Authorization" = "Bearer $Token"
}
$BodyConfigObject = [PSCustomObject]@{
    "@odata.type" = "#microsoft.graph.remoteDesktopSecurityConfiguration"
    "isRemoteDesktopProtocolEnabled" = $true
}
$BodyConfig = $BodyConfigObject | ConvertTo-Json

ForEach ($AppId in $AppIds) {
    $ServicePrincipalId = (Get-MgServicePrincipal -Filter "appId eq $AppId").id
    $Uri = "$graphUri/v1.0/servicePrincipals/$ServicePrincipalId/remoteDesktopSecurityConfiguration"
    Invoke-WebRequest -Uri $uri -Headers $Headers -Method Patch -Body $BodyConfig -ContentType $ContentType -UseBasicParsing
    $Uri = "$Uri/targetDeviceGroups"
    ForEach ($DeviceGroup in $DeviceGroups) {
        $BodyGroupObject = [PSCustomObject]@{
            "@odata.type" = "#microsoft.graph.targetDeviceGroup"
            "id" = $DeviceGroup.Id
            "displayName" = $DeviceGroup.displayName
        }
        $BodyGroup = $BodyGroupObject | ConvertTo-Json
        Invoke-WebRequest -Uri $Uri -Headers $Headers -Method Post -Body $BodyGroup -ContentType $ContentType -UseBasicParsing -ErrorAction SilentlyContinue
    }
    Invoke-WebRequest -Uri "$Uri/$($DeviceGroup.id)" -Headers $Headers -Method Get -ContentType $ContentType -UseBasicParsing
}

