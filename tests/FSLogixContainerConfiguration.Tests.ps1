BeforeDiscovery {
    $containerCases = @(
        @{ ContainerType = 'ProfileContainer'; Office = $false; Cloud = $false }
        @{ ContainerType = 'CloudCacheProfileContainer'; Office = $false; Cloud = $true }
        @{ ContainerType = 'ProfileOfficeContainer'; Office = $true; Cloud = $false }
        @{ ContainerType = 'CloudCacheProfileOfficeContainer'; Office = $true; Cloud = $true }
    )
    $runtimeCases = @($containerCases) + @(foreach ($case in $containerCases) {
        $data = $case.Clone()
        $data.ContainerType = $case.ContainerType.ToLowerInvariant()
        $data
    })
    $initializerCases = foreach ($initializer in @('standard', 'automated')) {
        foreach ($case in $runtimeCases) {
            $data = $case.Clone()
            $data.Initializer = $initializer
            $data
        }
    }
}

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'NamingTestHelpers.ps1')
    $fixtureDirectory = Join-Path ([IO.Path]::GetTempPath()) ('FederalAVD-Containers-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $fixtureDirectory -ErrorAction Stop | Out-Null
    $initializerScripts = @{
        standard = 'deployments\shared\scripts\Initialize-SessionHost.ps1'
        automated = 'deployments\automatedHostPools\scripts\Initialize-SessionHost.ps1'
    }
    $initializerAsts = @{}
    $initializerConfigurations = @{}
    function Get-ContainerTestAst([string]$Path) {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $Path), [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw "Cannot parse $Path" }
        return $ast
    }
    foreach ($initializer in $initializerScripts.Keys) {
        $ast = Get-ContainerTestAst $initializerScripts[$initializer]
        $initializerAsts[$initializer] = $ast
        $assignments = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -in @('$CloudCacheBool', '$ProfileShareName', '$OfficeShareName')
        }, $true))
        if ($assignments.Count -ne 3) { throw "Container configuration not found in $initializer" }
        $initializerConfigurations[$initializer] = [scriptblock]::Create(
            $ast.ParamBlock.Extent.Text + "`n" + ($assignments.Extent.Text -join "`n") +
            "`n[pscustomobject]@{ Profile = `$ProfileShareName; Office = `$OfficeShareName; Cloud = `$CloudCacheBool }"
        )
    }

    $typeParameter = $initializerAsts.standard.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'ContainerType' }
    $containerTypes = ($typeParameter.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }).PositionalArguments.Value
    $module = Join-Path $repoRoot 'deployments\shared\modules\orchestration\fslogix\fslogix.bicep'
    $relativeModule = [Uri]::UnescapeDataString(([Uri]("$fixtureDirectory\")).MakeRelativeUri([Uri]$module).ToString())
    $netAppLookup = Get-Content (Join-Path $repoRoot 'deployments\shared\modules\orchestration\fslogix\modules\getNetAppVolumeSmbServerFqdns.bicep') -Raw
    $shareCountExpression = [regex]::Match($netAppLookup, '(?m)^var shareCount = (?<expression>[^\r\n]+)').Groups['expression'].Value
    if ([string]::IsNullOrWhiteSpace($shareCountExpression)) { throw 'NetApp share-count expression not found' }
    $fixture = Join-Path $fixtureDirectory 'containers.bicep'
    [IO.File]::WriteAllLines($fixture, @(
        "targetScope = 'local'"
        "import { fslogixShareNames } from '$relativeModule'"
        "func fixtureShareCount(fslogixContainerType string) int => $shareCountExpression"
        "var types = [$((($containerTypes | ForEach-Object { "'$_'" }) -join ', '))]"
        'output encodedResults string = base64(string({ containers: map(types, type => { input: type, shares: fslogixShareNames(type), volumeCount: fixtureShareCount(type) }) }))'
    ))
    $resolvedContainers = (Invoke-TestNamingVectors -TemplateFile $fixture).containers.value

    function Write-Log { param($Message, $Category) }
    function Stop-Transcript {}
    function Set-AzureFileSharePermissions {
        param($ClientId, $FileShareName, $StorageAccountName, $StorageSuffix, $SDDLString)
        $script:containerAclCalls.Add([pscustomobject]@{
            Share = $FileShareName; Account = $StorageAccountName; Sddl = $SDDLString
        })
    }
    function Update-ACL {
        param($AdminGroups, $Credential, $FileShare, $UserGroups)
        $script:containerAclCalls.Add([pscustomobject]@{ Share = $FileShare })
    }
    function Get-ContainerAclScript([string]$Path) {
        $ast = Get-ContainerTestAst $Path
        $main = @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] })
        if ($main.Count -ne 1) { throw "ACL main block not found in $Path" }
        [scriptblock]::Create($ast.ParamBlock.Extent.Text + "`n" + ($main[0].Body.Statements.Extent.Text -join "`n"))
    }
    $azureAclScript = Get-ContainerAclScript 'deployments\shared\scripts\Set-NtfsPermissionsAzureFiles.ps1'
    $netAppAclScript = Get-ContainerAclScript 'deployments\shared\scripts\Set-NtfsPermissionsNetApp.ps1'
    $azureAst = Get-ContainerTestAst 'deployments\shared\scripts\Set-NtfsPermissionsAzureFiles.ps1'
    $sidFunction = $azureAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Convert-EntraIdObjectIdToSid'
    }, $true)
    . ([scriptblock]::Create($sidFunction.Extent.Text))
    $groupIds = @('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002')
    $groupSids = @($groupIds | ForEach-Object { Convert-EntraIdObjectIdToSid -ObjectId $_ })
}

AfterAll {
    if (Test-Path -LiteralPath $fixtureDirectory) {
        Remove-Item -LiteralPath $fixtureDirectory -Recurse -Force -ErrorAction Stop
    }
}

Describe 'FSLogix container type source of truth' {
    It 'resolves Bicep shares and volume counts for <ContainerType>' -TestCases $containerCases {
        param($ContainerType, $Office, $Cloud)
        $configuration = @($resolvedContainers | Where-Object input -eq $ContainerType)
        $configuration.Count | Should -Be 1
        $expected = if ($Office) { @('profile-containers', 'office-containers') } else { @('profile-containers') }
        $configuration[0].shares | Should -Be $expected
        $configuration[0].volumeCount | Should -Be $expected.Count
    }

    It 'derives <ContainerType> in the <Initializer> initializer without Shares or CloudCache arguments' -TestCases $initializerCases {
        param($ContainerType, $Office, $Cloud, $Initializer)
        $configuration = & $initializerConfigurations[$Initializer] -TimeZone 'UTC' -ContainerType $ContainerType
        $configuration.Profile | Should -Be 'profile-containers'
        $configuration.Office | Should -Be $(if ($Office) { 'office-containers' } else { $null })
        $configuration.Cloud | Should -Be $Cloud
        $parameters = $initializerAsts[$Initializer].ParamBlock.Parameters.Name.VariablePath.UserPath
        $parameters | Should -Not -Contain 'Shares'
        $parameters | Should -Not -Contain 'CloudCache'
    }

    It 'rejects unsupported and legacy <ContainerType> in initialization and permissions' -TestCases @(
        @{ ContainerType = 'Unknown' }
        @{ ContainerType = 'OfficeContainer' }
        @{ ContainerType = 'ProfileContainer OfficeContainer' }
        @{ ContainerType = 'ProfileContainer CloudCache' }
        @{ ContainerType = 'OfficeContainer CloudCache' }
        @{ ContainerType = 'ProfileContainer OfficeContainer CloudCache' }
    ) {
        param($ContainerType)
        foreach ($initializer in $initializerConfigurations.Keys) {
            { & $initializerConfigurations[$initializer] -TimeZone 'UTC' -ContainerType $ContainerType } | Should -Throw '*ContainerType*'
        }
        { & $netAppAclScript -ContainerType $ContainerType -NetAppServers '[]' `
            -DomainJoinUserPrincipalName 'fixture@example.test' -DomainJoinUserPwd 'fixture-password' } |
            Should -Throw '*ContainerType*'
    }

    It 'omits legacy normalization from the generated <Template> template' -TestCases @(
        @{ Template = 'deployments\hostpools\hostpool.json' }
        @{ Template = 'deployments\automatedHostPools\automatedHostPool.json' }
        @{ Template = 'deployments\hostpoolPoc\hostpoolPoc.json' }
        @{ Template = 'deployments\add-ons\fslogixStorage\main.json' }
        @{ Template = 'deployments\add-ons\sessionHosts\main.json' }
        @{ Template = 'deployments\add-ons\sessionHostReplacer\main.json' }
    ) {
        param($Template)
        Get-Content (Join-Path $repoRoot $Template) -Raw | Should -Not -Match '"normalizeFslogixContainerType"\s*:'
    }

    It 'validates canonical container selections at the <Template> entry point' -TestCases @(
        @{ Template = 'deployments\hostpools\hostpool.json' }
        @{ Template = 'deployments\automatedHostPools\automatedHostPool.json' }
        @{ Template = 'deployments\add-ons\fslogixStorage\main.json' }
        @{ Template = 'deployments\add-ons\sessionHosts\main.json' }
        @{ Template = 'deployments\add-ons\sessionHostReplacer\main.json' }
    ) {
        param($Template)
        $compiled = Get-Content (Join-Path $repoRoot $Template) -Raw | ConvertFrom-Json -Depth 100
        @($compiled.parameters.fslogixContainerType.allowedValues | Sort-Object) | Should -Be @(
            'CloudCacheProfileContainer', 'CloudCacheProfileOfficeContainer', 'ProfileContainer', 'ProfileOfficeContainer'
        )
    }

    It 'removes obsolete policy compatibility fields without forwarding redundant runtime inputs' {
        $remediation = Get-Content (Join-Path $repoRoot 'deployments\shared\modules\orchestration\sessionHostPolicy\modules\templates\RunCommand\ConfigureSessionHost.json') -Raw | ConvertFrom-Json -Depth 100
        $remediation.parameters.PSObject.Properties.Name | Should -Not -Contain 'fslogixFileShareNames'
        $resources = if ($remediation.resources -is [array]) { $remediation.resources } else { $remediation.resources.PSObject.Properties.Value }
        $command = $resources | Where-Object type -eq 'Microsoft.Compute/virtualMachines/runCommands'
        $command | Should -Not -BeNullOrEmpty
        $command.properties.parameters.name | Should -Contain 'ContainerType'
        $command.properties.parameters.name | Should -Not -Contain 'Shares'
        $command.properties.parameters.name | Should -Not -Contain 'CloudCache'
        $addon = Get-Content (Join-Path $repoRoot 'deployments\add-ons\fslogixStorage\main.bicep') -Raw
        $addon | Should -Not -Match '(?m)^\s+fileShareNames: fileShareNames'
        $policy = Get-Content (Join-Path $repoRoot 'deployments\shared\modules\orchestration\sessionHostPolicy\modules\configureSessionHost.policyDefinition.bicep') -Raw
        $policy | Should -Not -Match 'fslogixFileShareNames:'
        $policy | Should -Match 'provisioningState'
    }
}

Describe 'FSLogix per-role NTFS targets' {
    BeforeEach {
        $script:containerAclCalls = [Collections.Generic.List[object]]::new()
    }

    It 'applies only <ShareName> to its two ordered shards' -TestCases @(
        @{ ShareName = 'profile-containers'; Prefix = 'profile' }
        @{ ShareName = 'office-containers'; Prefix = 'office' }
    ) {
        param($ShareName, $Prefix)
        $null = & $azureAclScript -ShareName $ShareName -DomainName 'example.test' -StorageAccountPrefix $Prefix `
            -StorageCount '2' -StorageIndex '3' -StorageSuffix 'core.windows.net' -UserAssignedIdentityClientId 'fixture' `
            -UserGroups (ConvertTo-Json -InputObject $groupIds -Compress) -ShardAzureFilesStorage 'true'
        $script:containerAclCalls.Count | Should -Be 2
        $script:containerAclCalls.Account | Should -Be @("${Prefix}03", "${Prefix}04")
        foreach ($call in $script:containerAclCalls) { $call.Share | Should -Be $ShareName }
        $script:containerAclCalls[0].Sddl | Should -Match ([regex]::Escape($groupSids[0]))
        $script:containerAclCalls[0].Sddl | Should -Not -Match ([regex]::Escape($groupSids[1]))
        $script:containerAclCalls[1].Sddl | Should -Match ([regex]::Escape($groupSids[1]))
    }

    It 'preserves all selected groups on an unsharded share' {
        $null = & $azureAclScript -ShareName 'office-containers' -DomainName 'example.test' -StorageAccountPrefix 'office' `
            -StorageCount '1' -StorageIndex '1' -StorageSuffix 'core.windows.net' -UserAssignedIdentityClientId 'fixture' `
            -UserGroups (ConvertTo-Json -InputObject $groupIds -Compress) -ShardAzureFilesStorage 'false'
        $script:containerAclCalls.Count | Should -Be 1
        foreach ($sid in $groupSids) { $script:containerAclCalls[0].Sddl | Should -Match ([regex]::Escape($sid)) }
    }

    It 'preserves Authenticated Users when no groups are supplied' {
        $null = & $azureAclScript -ShareName 'profile-containers' -DomainName 'example.test' -StorageAccountPrefix 'profile' `
            -StorageCount '1' -StorageIndex '1' -StorageSuffix 'core.windows.net' -UserAssignedIdentityClientId 'fixture' `
            -UserGroups '[]' -ShardAzureFilesStorage 'false'
        $script:containerAclCalls.Count | Should -Be 1
        $script:containerAclCalls[0].Sddl | Should -Match ';;;AU\)'
    }

    It 'derives NetApp share targets from <ContainerType>' -TestCases $runtimeCases {
        param($ContainerType, $Office, $Cloud)
        $null = & $netAppAclScript -ContainerType $ContainerType -NetAppServers '["profile.example","office.example"]' `
            -DomainJoinUserPrincipalName 'fixture@example.test' -DomainJoinUserPwd 'fixture-password' `
            -AdminGroupNames '[]' -UserGroupNames '[]'
        $script:containerAclCalls.Count | Should -Be $(if ($Office) { 2 } else { 1 })
        $script:containerAclCalls[0].Share | Should -Be '\\profile.example\profile-containers'
        if ($Office) { $script:containerAclCalls[1].Share | Should -Be '\\office.example\office-containers' }
    }
}
