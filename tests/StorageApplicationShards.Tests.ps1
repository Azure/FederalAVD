BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $scripts = Join-Path $repoRoot 'deployments\shared\scripts'
    function Get-WindowsFeature { param($Name) }
    function Get-ADDomainController { param([switch]$Discover, $DomainName, $Service, [switch]$ForceDiscover) }
    function Get-ADDomain { param($Identity, $Server, $Credential) }
    function Get-ADGroup { param($Identity, $Server, $Credential) }

    function Invoke-StorageGraphScript {
        param($Name, $Prefix = 'profile', $PrivateEndpoint = 'true')
        $arguments = @{
            AppDisplayNamePrefix = "[Storage Account] $Prefix"
            StorageCount = 2
            StorageIndex = 7
            ClientId = 'test-identity'
            GraphEndpoint = 'https://graph.microsoft.com'
        }
        if ($Name -eq 'Update-StorageAccountApplicationManifest.ps1') {
            $arguments.PrivateEndpoint = $PrivateEndpoint
        }
        . (Join-Path $scripts $Name) @arguments | Out-Null
    }
}

Describe 'Storage application shard coverage' {
    BeforeEach {
        $script:apps = @{}
        $script:patches = @{}
        $script:grants = @{}
        $script:lookups = @{}
        $script:missingApp = ''
        $script:missingSp = ''
        $script:delayedApp = ''
        $script:delayedSp = ''
        $script:duplicateApp = ''
        $script:suffix = 'core.usgovcloudapi.net'
        foreach ($role in @('profile', 'office')) {
            foreach ($index in @(7, 8)) {
                $accountName = "$role$($index.ToString('00'))"
                $uris = @(
                    foreach ($service in @('HOST', 'CIFS', 'HTTP')) {
                        "api://tenant/$service/$accountName.file.$script:suffix"
                        "$service/$accountName.file.$script:suffix"
                    }
                )
                $script:apps[$accountName] = [pscustomobject]@{
                    id = $accountName
                    appId = "client-$accountName"
                    displayName = "[Storage Account] $accountName.file.$script:suffix"
                    identifierUris = $uris
                    tags = @()
                }
            }
        }
        Mock Start-Transcript {}
        Mock Stop-Transcript {}
        Mock Start-Sleep {}
        Mock Invoke-RestMethod {
            param($Uri, $Method, $Body)
            if ($Uri -like 'http://169.254.169.254/*') {
                return @{ access_token = 'test-token' }
            }
            $decoded = [uri]::UnescapeDataString($Uri)
            if ($decoded -match "/applications\?.*startswith\(displayName, '\[Storage Account\] ([^.]+)\.file\.") {
                $name = $Matches[1]
                $script:lookups[$name]++
                if ($name -eq $script:missingApp -or ($name -eq $script:delayedApp -and $script:lookups[$name] -lt 3)) {
                    return @{ value = @() }
                }
                if (-not $script:apps.ContainsKey($name)) { throw "Unexpected account lookup: $name" }
                if ($name -eq $script:duplicateApp) { return @{ value = @($script:apps[$name], $script:apps[$name]) } }
                return @{ value = @($script:apps[$name]) }
            }
            if ($decoded -match '/applications/([^/?]+)$') {
                $name = $Matches[1]
                if ($Method -eq 'Patch') {
                    $update = $Body | ConvertFrom-Json
                    $script:patches[$name] = $update
                    if ($update.identifierUris) { $script:apps[$name].identifierUris = $update.identifierUris }
                    return
                }
                return $script:apps[$name]
            }
            if ($decoded -match "/servicePrincipals\?.*appId eq 'client-([^']+)'") {
                $name = $Matches[1]
                $script:lookups["sp-$name"]++
                if ($name -eq $script:missingSp -or ($name -eq $script:delayedSp -and $script:lookups["sp-$name"] -lt 3)) {
                    return @{ value = @() }
                }
                return @{ value = @(@{ id = "sp-$name"; displayName = $name }) }
            }
            if ($decoded -match "/servicePrincipals\?.*00000003-0000-0000-c000-000000000000") {
                return @{ value = @(@{ id = 'graph-sp' }) }
            }
            if ($decoded -match "/oauth2PermissionGrants\?.*clientId eq 'sp-([^']+)'") {
                return @{ value = @() }
            }
            if ($decoded -match '/oauth2PermissionGrants$' -and $Method -eq 'Post') {
                $grant = $Body | ConvertFrom-Json
                $script:grants[$grant.clientId] = $grant
                return
            }
            throw "Unexpected Graph call: $Method $decoded"
        }
    }

    It 'adds all six Private Link counterparts to every Profile and Office shard, idempotently' {
        foreach ($role in @('profile', 'office')) {
            Invoke-StorageGraphScript -Name 'Update-StorageAccountApplicationManifest.ps1' -Prefix $role
        }
        $script:patches.Count | Should -Be 4
        foreach ($name in $script:apps.Keys) {
            $script:apps[$name].identifierUris.Count | Should -Be 12
            foreach ($service in @('HOST', 'CIFS', 'HTTP')) {
                $script:apps[$name].identifierUris | Should -Contain "$service/$name.privatelink.file.$script:suffix"
                $script:apps[$name].identifierUris | Should -Contain "api://tenant/$service/$name.privatelink.file.$script:suffix"
                $script:apps[$name].identifierUris | Should -Contain "$service/$name.file.$script:suffix"
            }
        }
        $script:patches.Clear()
        Invoke-StorageGraphScript -Name 'Update-StorageAccountApplicationManifest.ps1'
        $script:patches.Count | Should -Be 0
    }

    It 'does not add Private Link identifiers when private endpoints are disabled' {
        Invoke-StorageGraphScript -Name 'Update-StorageAccountApplicationManifest.ps1' -PrivateEndpoint 'false'
        $script:patches.Count | Should -Be 0
    }

    It 'grants tenant-wide consent for every Profile and Office shard' {
        foreach ($role in @('profile', 'office')) {
            Invoke-StorageGraphScript -Name 'Grant-StorageAccountApplicationConsent.ps1' -Prefix $role
        }
        $script:grants.Count | Should -Be 4
        foreach ($grant in $script:grants.Values) {
            $grant.consentType | Should -Be 'AllPrincipals'
            $grant.scope | Should -Be 'openid profile User.Read'
            $grant.resourceId | Should -Be 'graph-sp'
        }
    }

    It 'waits for shard 08 instead of accepting a partial set in <Name>' -TestCases @(
        @{ Name = 'Update-StorageAccountApplicationManifest.ps1' }
        @{ Name = 'Grant-StorageAccountApplicationConsent.ps1' }
    ) {
        param($Name)
        $script:delayedApp = 'profile08'
        Invoke-StorageGraphScript -Name $Name
        $script:lookups.profile08 | Should -Be 3
        Should -Invoke Start-Sleep -Times 2 -Exactly
    }

    It 'fails explicitly when shard 08 never appears in <Name>' -TestCases @(
        @{ Name = 'Update-StorageAccountApplicationManifest.ps1' }
        @{ Name = 'Grant-StorageAccountApplicationConsent.ps1' }
    ) {
        param($Name)
        $script:missingApp = 'profile08'
        { Invoke-StorageGraphScript -Name $Name } | Should -Throw '*profile08*12 attempts*'
        $script:patches.Count | Should -Be 0
        $script:grants.Count | Should -Be 0
    }

    It 'rejects ambiguous applications in <Name>' -TestCases @(
        @{ Name = 'Update-StorageAccountApplicationManifest.ps1' }
        @{ Name = 'Grant-StorageAccountApplicationConsent.ps1' }
    ) {
        param($Name)
        $script:duplicateApp = 'profile08'
        { Invoke-StorageGraphScript -Name $Name } | Should -Throw '*Multiple applications*'
    }

    It 'waits for a delayed service principal before granting consent' {
        $script:delayedSp = 'profile08'
        Invoke-StorageGraphScript -Name 'Grant-StorageAccountApplicationConsent.ps1'
        $script:grants.Count | Should -Be 2
        $script:lookups['sp-profile08'] | Should -Be 3
    }

    It 'fails rather than silently skipping consent for a missing service principal' {
        $script:missingSp = 'profile08'
        { Invoke-StorageGraphScript -Name 'Grant-StorageAccountApplicationConsent.ps1' } |
            Should -Throw '*Service principal not found*profile08*'
    }
}

Describe 'Credential-backed configuration processes every shard' {
    BeforeEach {
        Mock Start-Transcript {}
        Mock Stop-Transcript {}
        Mock Get-WindowsFeature { @{ Installed = $true } }
        Mock Get-ADDomainController { @{ HostName = 'dc.example.test' } }
        Mock Get-ADDomain { @{ ObjectGUID = [guid]'11111111-1111-1111-1111-111111111111'; DNSRoot = 'example.test'; NetBIOSName = 'EXAMPLE' } }
        Mock Get-ADGroup {
            param($Identity)
            @{ SID = @{ Value = $(if ($Identity -eq 'group1') { 'S-1-5-21-1-2-3-1001' } else { 'S-1-5-21-1-2-3-1002' }) } }
        }
        Mock Invoke-RestMethod { @{ access_token = 'test-token' } }
        Mock Invoke-WebRequest { @{ Headers = @{ 'x-ms-file-permission-key' = 'test-key' } } }
        $arguments = @{
            DomainName = 'example.test'
            DomainJoinUserPrincipalName = 'lookup@example.test'
            DomainJoinUserPwd = 'test-only'
            StorageAccountPrefix = 'profile'
            StorageCount = '2'
            StorageIndex = '7'
            StorageSuffix = 'core.usgovcloudapi.net'
            UserAssignedIdentityClientId = 'test-identity'
        }
    }

    It 'PATCHes hybrid domain information on both shards' {
        & (Join-Path $scripts 'Configure-StorageAccountforEntraHybrid.ps1') @arguments `
            -DefaultSharePermission 'StorageFileDataSmbShareContributor' `
            -ResourceManagerUri 'https://management.usgovcloudapi.net/' `
            -StorageAccountResourceGroupName 'test-storage' -SubscriptionId 'test-subscription' | Out-Null
        foreach ($name in @('profile07', 'profile08')) {
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'PATCH' -and $Uri -like "*/storageAccounts/$name`?*" -and
                ($Body | ConvertFrom-Json).properties.azureFilesIdentityBasedAuthentication.activeDirectoryProperties.domainName -eq 'example.test'
            }
        }
    }

    It 'sets the corresponding group NTFS ACL on both shards for <Share>' -TestCases @(
        @{ Share = 'profile-containers' }
        @{ Share = 'office-containers' }
    ) {
        param($Share)
        & (Join-Path $scripts 'Set-NtfsPermissionsAzureFiles.ps1') @arguments `
            -ShareName $Share -ShardAzureFilesStorage 'true' -UserGroups '["group1","group2"]' | Out-Null
        foreach ($index in @(7, 8)) {
            $name = "profile$($index.ToString('00'))"
            $sid = "S-1-5-21-1-2-3-$($index + 994)"
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'PUT' -and $Uri -eq "https://$name.file.core.usgovcloudapi.net/$Share`?restype=share&comp=filepermission" -and
                ($Body | ConvertFrom-Json).permission.Contains($sid)
            }
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'PUT' -and $Uri -eq "https://$name.file.core.usgovcloudapi.net/$Share`?restype=directory&comp=properties"
            }
        }
    }
}
