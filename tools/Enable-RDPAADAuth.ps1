$Environment = 'AzureUSGovernment'
Connect-AzAccount -Environment $Environment
Connect-MgGraph -Environment USGov
$AppIds = 'a4a365df-50f1-4397-bc59-1a1564b8bb9c','270efc09-cd0d-444b-a71f-39af4910ec45'
$Token = (Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.us').token
$ContentType = 'application/json'
$Headers = @{
    "Authorization" = "Bearer $Token"
}
$BodyConfigObject = [PSCustomObject]@{
    "@odata.type" = "#microsoft.graph.remoteDesktopSecurityConfiguration"
    "isRemoteDesktopProtocolEnabled" = $true
}
$BodyConfig = $BodyConfigObject | ConvertTo-Json

$DeviceGroupId = 'f9bf0413-cccc-4090-b6e7-3a910aa24ab8'

$BodyGroupsObject = [PSCustomObject]@{
    "@odata.type" = "#microsoft.graph.targetDeviceGroup"
    "id" = "$DeviceGroupId"
    "displayName" = "AVD Session Hosts"
}
$BodyGroups = $BodyGroupsObject | ConvertTo-Json

ForEach ($AppId in $AppIds) {
    $ServicePrincipalId = (Get-MgServicePrincipal -Filter "appId eq 'a4a365df-50f1-4397-bc59-1a1564b8bb9c'").id
    $Uri = "https://graph.microsoft.us/v1.0/servicePrincipals/$ServicePrincipalId/remoteDesktopSecurityConfiguration"
    Invoke-WebRequest -Uri $uri -Headers $Headers -Method Patch -Body $BodyConfig -ContentType $ContentType -UseBasicParsing
    $Uri = "$Uri/targetDeviceGroups"
    Invoke-WebRequest -Uri $Uri -Headers $Headers -Method Post -Body $BodyGroups -ContentType $ContentType -UseBasicParsing
    #Invoke-WebRequest -Uri "$Uri/$DeviceGroupId" -Headers $Headers -Method Get -ContentType $ContentType -UseBasicParsing
}