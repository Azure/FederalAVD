BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'NamingTestHelpers.ps1')
    $sourcePath = Join-Path $repoRoot 'deployments\shared\modules\orchestration\fslogix\modules\getNetAppVolumeSmbServerFqdns.bicep'
    $source = Get-Content -LiteralPath $sourcePath -Raw
    $directory = Join-Path $TestDrive 'netapp-lookup'
    New-Item -ItemType Directory -Path $directory -ErrorAction Stop | Out-Null
    $templatePath = Join-Path $directory 'lookup.json'
    az bicep build --file $sourcePath --outfile $templatePath --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'NetApp endpoint lookup did not compile.' }
    $template = Get-Content -LiteralPath $templatePath -Raw | ConvertFrom-Json -Depth 100
    $validation = [regex]::Match($source, '(?ms)^var shareCount = .*?(?=^resource localNetAppVolumes)')
    if (-not $validation.Success) { throw 'Production NetApp volume-count validation was not found.' }
    $lookupFunctions = @('func fixtureResourceGroup(subscriptionId string, resourceGroupName string) object => { subscriptionId: subscriptionId, resourceGroupName: resourceGroupName }')
    foreach ($side in @('local', 'remote')) {
        $resource = [regex]::Match($source, '(?ms)^resource ' + $side + 'NetAppVolumes .*?^\}\]')
        $name = [regex]::Match($resource.Value, "(?m)^\s+name: '([^\r\n]+)'\r?$").Groups[1].Value
        $scope = [regex]::Match($resource.Value, '(?m)^\s+scope: (.+)$').Groups[1].Value.Trim().Replace('resourceGroup(', 'fixtureResourceGroup(')
        if (-not $name -or -not $scope) { throw "Production $side NetApp name/scope expressions were not found." }
        $lookupFunctions += "func ${side}Name(volumeId string) string => '$name'"
        $lookupFunctions += "func ${side}Scope(volumeId string) object => $scope"
    }
    $identityFunction = @'
func volumeId(scope object, name string) string => '/subscriptions/${scope.subscriptionId}/resourceGroups/${scope.resourceGroupName}/providers/Microsoft.NetApp/netAppAccounts/${split(name, '/')[0]}/capacityPools/${split(name, '/')[1]}/volumes/${split(name, '/')[2]}'
'@
    $localIds = @(
        '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/local-profiles/providers/Microsoft.NetApp/netAppAccounts/account-a/capacityPools/pool-profile/volumes/profile-containers'
        '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/local-office/providers/Microsoft.NetApp/netAppAccounts/account-b/capacityPools/pool-office/volumes/office-containers'
    )
    $remoteIds = @(
        '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/remote-profiles/providers/Microsoft.NetApp/netAppAccounts/account-c/capacityPools/remote-profile/volumes/profile-containers'
        '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/remote-office/providers/Microsoft.NetApp/netAppAccounts/account-d/capacityPools/remote-office/volumes/office-containers'
    )
    function Invoke-NetAppLookupConfiguration {
        param([string[]]$Local = @(), [string[]]$Remote = @(), [string]$ContainerType = 'ProfileOfficeContainer')
        $lines = @("targetScope = 'local'") + $lookupFunctions
        $lines += @(
            "var localNetAppVolumeResourceIds = [$((($Local | ForEach-Object { "'$_'" }) -join ', '))]"
            "var remoteNetAppVolumeResourceIds = [$((($Remote | ForEach-Object { "'$_'" }) -join ', '))]"
            "var fslogixContainerType = '$ContainerType'"
            $validation.Value
            $identityFunction
            'var local = map(volumeCountsAreValid ? localNetAppVolumeResourceIds : [], id => { name: localName(id), scope: localScope(id), resourceId: volumeId(localScope(id), localName(id)) })'
            'var remote = map(volumeCountsAreValid ? remoteNetAppVolumeResourceIds : [], id => { name: remoteName(id), scope: remoteScope(id), resourceId: volumeId(remoteScope(id), remoteName(id)) })'
            'output encodedResults string = base64(string({ local: local, remote: remote }))'
        )
        $fixturePath = Join-Path $directory 'names.bicep'
        [IO.File]::WriteAllLines($fixturePath, $lines)
        Invoke-TestNamingVectors -TemplateFile $fixturePath
    }
}

Describe 'Existing NetApp volume endpoint lookup' {
    It 'resolves full local and remote resource identities in Profile-then-Office order' {
        $result = Invoke-NetAppLookupConfiguration -Local $localIds -Remote $remoteIds
        $result.local.value.resourceId | Should -Be $localIds
        $result.remote.value.resourceId | Should -Be $remoteIds
        $result.local.value.name | Should -Be @('account-a/pool-profile/profile-containers', 'account-b/pool-office/office-containers')
        $result.remote.value.name | Should -Be @('account-c/remote-profile/profile-containers', 'account-d/remote-office/office-containers')
        $result.local.value.scope.resourceGroupName | Should -Be @('local-profiles', 'local-office')
        $result.remote.value.scope.resourceGroupName | Should -Be @('remote-profiles', 'remote-office')
    }

    It 'preserves Profile-only lookups across subscriptions' {
        $result = Invoke-NetAppLookupConfiguration -Local $localIds[0] -Remote $remoteIds[0] -ContainerType 'ProfileContainer'
        @($result.local.value).Count | Should -Be 1
        @($result.remote.value).Count | Should -Be 1
        $result.local.value[0].resourceId | Should -Be $localIds[0]
        $result.remote.value[0].resourceId | Should -Be $remoteIds[0]
    }

    It 'allows either endpoint array to be empty independently' {
        $localOnly = Invoke-NetAppLookupConfiguration -Local $localIds
        @($localOnly.remote.value).Count | Should -Be 0
        $localOnly.local.value.resourceId | Should -Be $localIds
        $remoteOnly = Invoke-NetAppLookupConfiguration -Remote $remoteIds
        @($remoteOnly.local.value).Count | Should -Be 0
        $remoteOnly.remote.value.resourceId | Should -Be $remoteIds
    }

    It 'returns empty endpoint arrays when no volumes are supplied' {
        $result = Invoke-NetAppLookupConfiguration
        @($result.local.value).Count | Should -Be 0
        @($result.remote.value).Count | Should -Be 0
    }

    It 'rejects an incorrect <Side> volume count for <ContainerType>' -TestCases @(
        @{ Side = 'Local'; ContainerType = 'ProfileOfficeContainer'; Count = 1 }
        @{ Side = 'Remote'; ContainerType = 'CloudCacheProfileOfficeContainer'; Count = 1 }
        @{ Side = 'Local'; ContainerType = 'ProfileContainer'; Count = 2 }
        @{ Side = 'Remote'; ContainerType = 'CloudCacheProfileContainer'; Count = 2 }
    ) {
        param($Side, $ContainerType, $Count)
        $arguments = @{ ContainerType = $ContainerType; $Side = $localIds[0..($Count - 1)] }
        { Invoke-NetAppLookupConfiguration @arguments } | Should -Throw '*one volume per FSLogix share*'
    }

    It 'retains runtime mount-target reads without truncating parent names' {
        foreach ($output in @('localNetAppVolumeSmbServerFqdns', 'remoteNetAppVolumeSmbServerFqdns')) {
            $expression = $template.outputs.$output.copy.input
            $expression | Should -Match 'Microsoft.NetApp/netAppAccounts/capacityPools/volumes'
            $expression | Should -Not -Match 'last\(split'
            $expression | Should -Match "'2023-11-01'\)\.mountTargets\[0\]\.smbServerFqdn"
        }
    }
}
