$filePath = "c:\repos\FederalAVD\deployments\hostpools\uiFormDefinition.json"
$content = Get-Content $filePath -Raw -Encoding UTF8
$content = $content.Replace("steps('hosts').scope.hostRGProps.tags", "steps('basics').hostRGProps.tags")
$content | Set-Content $filePath -NoNewline -Encoding UTF8
Write-Host "Replacement complete"
