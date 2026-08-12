param vmNames array = []
param location string = resourceGroup().location
param storageAccountResourceId string
@allowed([1, 2])
param storageAccountKey int

var keyIndex = storageAccountKey - 1

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
    name: last(split(storageAccountResourceId, '/'))
    scope: resourceGroup(split(storageAccountResourceId, '/')[2], split(storageAccountResourceId, '/')[4])
}

resource vms 'Microsoft.Compute/virtualMachines@2024-03-01' existing = [for (vm, i) in vmNames: {
    name: vm
    scope: resourceGroup()
}]

resource runCommand 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = [for (vm, i) in vmNames: {
    location: location
    name: 'Update-Storage-Account-Key'
    
    parent: vms[i]
    properties: {
        source: {
            script: '''
param (
    [string]$StorageAccountName,
    [string]$StorageAccountSuffix,
    [string]$StorageAccountKey
)

# Belt-and-suspenders: ensure "Network Access: Do not allow storage of passwords
# and credentials for network authentication" (DisableDomainCreds) is Disabled so
# cmdkey can persist the storage key credential in Credential Manager.
# This is an older STIG control not commonly seen in current releases, but may
# still be enforced by legacy baselines. Using secedit ensures the Security
# Configuration Engine does not revert a raw registry write on the next refresh.
$seceditInf = Join-Path -Path $env:TEMP -ChildPath 'avd-disable-domain-creds.inf'
$seceditDb  = Join-Path -Path $env:TEMP -ChildPath 'avd-disable-domain-creds.sdb'
$seceditLog = Join-Path -Path $env:TEMP -ChildPath 'avd-disable-domain-creds.log'
$infLines = @(
    '[Unicode]'
    'Unicode=yes'
    '[Version]'
    'signature="$CHICAGO$"'
    'Revision=1'
    '[Registry Values]'
    'MACHINE\System\CurrentControlSet\Control\Lsa\DisableDomainCreds=4,0'
)
[System.IO.File]::WriteAllLines($seceditInf, $infLines, [System.Text.Encoding]::Unicode)
$null = Start-Process -FilePath 'secedit.exe' `
    -ArgumentList "/configure /cfg `"$seceditInf`" /db `"$seceditDb`" /log `"$seceditLog`" /quiet" `
    -Wait -PassThru -NoNewWindow
Remove-Item -Path $seceditInf, $seceditDb, $seceditLog -Force -ErrorAction SilentlyContinue

Start-Process -FilePath 'cmdkey.exe' -ArgumentList "/add:$($StorageAccountName).file.$($StorageAccountSuffix) /user:localhost\$($StorageAccountName) /pass:$($StorageAccountKey)" -NoNewWindow -Wait
            '''
        }

        protectedParameters: [
            {
                name: 'StorageAccountName'
                value: last(split(storageAccountResourceId, '/'))
            }
            {
                name: 'StorageAccountSuffix'
                value: environment().suffixes.storage
            }
            {
                name: 'StorageAccountKey'
                value: storageAccount.listKeys().keys[keyIndex].value
            }
        ]
        timeoutInSeconds: 30
        treatFailureAsDeploymentFailure: true
    }
}]
