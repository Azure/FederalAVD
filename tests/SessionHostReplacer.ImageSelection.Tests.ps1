$repoRoot = Split-Path -Parent $PSScriptRoot
$shrRoot = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer'
$moduleRoot = Join-Path $shrRoot 'functions\Modules\SessionHostReplacer'
$tokens = $null
$parseErrors = $null
foreach ($module in @('Core', 'ImageManagement')) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $moduleRoot "SessionHostReplacer.$module.psm1"),
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
    foreach ($function in $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true)) {
        Invoke-Expression $function.Extent.Text
    }
}

function New-SelectionTestVersion {
    param(
        [string]$Name = '2.0.0',
        [bool]$Excluded = $false,
        [bool]$RegionExcluded = $false,
        [string]$ReplicationState = 'Completed',
        [string]$PublishedDate = '2026-10-01T00:00:00Z'
    )

    [pscustomobject]@{
        name = $Name
        properties = @{
            publishingProfile = @{
                publishedDate = $PublishedDate
                excludeFromLatest = $Excluded
                targetRegions = @(@{ name = 'East US'; excludeFromLatest = $RegionExcluded })
            }
            replicationStatus = @{
                summary = @(@{ region = 'East US'; state = $ReplicationState })
            }
        }
    }
}

Describe 'Session Host Replacer numeric gallery selection and pilot exclusions' {
    BeforeEach {
        $script:selectionVersions = @()
        $script:requestedVersions = @()
        $script:selectionParameters = @{
            ARMToken = 'test-token'
            ResourceManagerUri = 'https://arm.example.invalid'
            SubscriptionId = '11111111-1111-1111-1111-111111111111'
            ImageReference = @{
                id = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/images/providers/Microsoft.Compute/galleries/gallery/images/avd'
            }
            Location = 'eastus'
        }
        Mock Write-LogEntry {}
        Mock Invoke-AzureRestMethod {
            param($Uri)
            if ($Uri -match '/versions/(?<version>[^?]+)\?') {
                $script:requestedVersions += $Matches.version
                return $script:selectionVersions | Where-Object { $_.name -eq $Matches.version }
            }
            return $script:selectionVersions
        }
    }

    It 'orders major, minor and patch numerically rather than lexically or by date' -TestCases @(
        @{ Lower = '9.99.99'; Higher = '10.0.0' },
        @{ Lower = '1.9.99'; Higher = '1.10.0' },
        @{ Lower = '1.0.9'; Higher = '1.0.10' },
        @{ Lower = '1.0.0'; Higher = '2.2147483647.2147483647' }
    ) {
        param($Lower, $Higher)
        $script:selectionVersions = @(
            New-SelectionTestVersion -Name $Lower -PublishedDate '2026-10-20T00:00:00Z'
            New-SelectionTestVersion -Name $Higher -PublishedDate '2026-10-01T00:00:00Z'
        )
        $result = Get-LatestImageVersion @selectionParameters
        $result.Version | Should Be $Higher
        $result.Date | Should Be ([datetime]'2026-10-01T00:00:00Z')
        $requestedVersions.Count | Should Be 1
        $requestedVersions[0] | Should Be $Higher
    }

    It 'keeps excluded candidates out of production but includes them in pilot' -TestCases @(
        @{ GlobalExcluded = $true; RegionExcluded = $false },
        @{ GlobalExcluded = $false; RegionExcluded = $true },
        @{ GlobalExcluded = $true; RegionExcluded = $true }
    ) {
        param($GlobalExcluded, $RegionExcluded)
        $script:selectionVersions = @(
            New-SelectionTestVersion -Name '1.0.0'
            New-SelectionTestVersion -Name '2.0.0' -Excluded $GlobalExcluded -RegionExcluded $RegionExcluded
        )
        (Get-LatestImageVersion @selectionParameters).Version | Should Be '1.0.0'
        (Get-LatestImageVersion @selectionParameters -IncludeExcludedImageVersions $true).Version | Should Be '2.0.0'
    }

    It 'fails closed rather than falling back when every version is excluded' -TestCases @(
        @{ GlobalExcluded = $true; RegionExcluded = $false },
        @{ GlobalExcluded = $false; RegionExcluded = $true }
    ) {
        param($GlobalExcluded, $RegionExcluded)
        $script:selectionVersions = @(New-SelectionTestVersion -Excluded $GlobalExcluded -RegionExcluded $RegionExcluded)
        { Get-LatestImageVersion @selectionParameters } | Should Throw 'No eligible image versions'
        $requestedVersions.Count | Should Be 0
        (Get-LatestImageVersion @selectionParameters -IncludeExcludedImageVersions $true).Version | Should Be '2.0.0'
    }

    It 'promotes the same tested version by clearing its global exclusion' {
        $candidate = New-SelectionTestVersion -Name '2.0.0' -Excluded $true
        $script:selectionVersions = @(New-SelectionTestVersion -Name '1.0.0'; $candidate)
        $pilot = Get-LatestImageVersion @selectionParameters -IncludeExcludedImageVersions $true
        (Get-LatestImageVersion @selectionParameters).Version | Should Be '1.0.0'
        $candidate.properties.publishingProfile.excludeFromLatest = $false
        (Get-LatestImageVersion @selectionParameters).Version | Should Be $pilot.Version
    }

    It 'does not treat an exclusion in another region as an exclusion here' {
        $candidate = New-SelectionTestVersion -RegionExcluded $true
        $candidate.properties.publishingProfile.targetRegions[0].name = 'West US'
        $script:selectionVersions = @($candidate)
        (Get-LatestImageVersion @selectionParameters).Version | Should Be '2.0.0'
    }

    It 'selects the highest completed regional replica without bypassing replication in pilot' {
        $script:selectionVersions = @(
            New-SelectionTestVersion -Name '2.0.0' -Excluded $true
            New-SelectionTestVersion -Name '10.0.0' -Excluded $true -ReplicationState 'InProgress'
        )
        (Get-LatestImageVersion @selectionParameters -IncludeExcludedImageVersions $true).Version | Should Be '2.0.0'
        ($requestedVersions -join ',') | Should Be '10.0.0,2.0.0'
    }

    It 'rejects candidates with failed or missing regional replication even in pilot' -TestCases @(
        @{ State = 'Failed' },
        @{ State = 'InProgress' },
        @{ State = 'MissingRegion' }
    ) {
        param($State)
        $candidate = New-SelectionTestVersion -Excluded $true -ReplicationState $State
        if ($State -eq 'MissingRegion') { $candidate.properties.replicationStatus.summary[0].region = 'West US' }
        $script:selectionVersions = @($candidate)
        { Get-LatestImageVersion @selectionParameters -IncludeExcludedImageVersions $true } |
            Should Throw 'No replicated image versions'
    }

    It 'retains the publication-date requirement for rollout age even in pilot' {
        $script:selectionVersions = @(New-SelectionTestVersion -PublishedDate '')
        { Get-LatestImageVersion @selectionParameters -IncludeExcludedImageVersions $true } |
            Should Throw 'No eligible image versions'
    }

    It 'surfaces invalid numeric version data rather than silently selecting another candidate' {
        $script:selectionVersions = @(New-SelectionTestVersion -Name 'invalid')
        { Get-LatestImageVersion @selectionParameters } | Should Throw 'is not a valid numeric major.minor.patch version'
    }

    It 'surfaces gallery API failures' {
        Mock Invoke-AzureRestMethod { throw 'Gallery API unavailable' }
        { Get-LatestImageVersion @selectionParameters } | Should Throw 'Gallery API unavailable'
    }

    It 'does not retarget a pinned gallery image when pilot selection is enabled' {
        $selectionParameters.ImageReference.id += '/versions/1.0.0'
        $script:selectionVersions = @(New-SelectionTestVersion -Name '1.0.0' -Excluded $true)
        (Get-LatestImageVersion @selectionParameters -IncludeExcludedImageVersions $true).Version | Should Be '1.0.0'
        ($requestedVersions -join ',') | Should Be '1.0.0'
    }

    It 'leaves marketplace latest and pinned selection unchanged' {
        $selectionParameters.ImageReference = @{ publisher = 'publisher'; offer = 'offer'; sku = 'sku'; version = 'latest' }
        $script:selectionVersions = @(
            [pscustomobject]@{ name = '1.0.261001' }
            [pscustomobject]@{ name = '1.0.261020' }
        )
        (Get-LatestImageVersion @selectionParameters -IncludeExcludedImageVersions $true).Version | Should Be '1.0.261020'
        $selectionParameters.ImageReference.version = '1.0.261001'
        (Get-LatestImageVersion @selectionParameters -IncludeExcludedImageVersions $true).Version | Should Be '1.0.261001'
    }
}

Describe 'Session Host Replacer pilot setting deployment contract' {
    It 'defaults off and maps the form checkbox to the ARM parameter and app setting' {
        $form = Get-Content -LiteralPath (Join-Path $shrRoot 'uiFormDefinition.json') -Raw | ConvertFrom-Json
        $template = Get-Content -LiteralPath (Join-Path $shrRoot 'main.json') -Raw | ConvertFrom-Json
        $config = $form.view.properties.steps | Where-Object { $_.name -eq 'replacerConfig' }
        $checkbox = $config.elements | Where-Object { $_.name -eq 'includeExcludedImageVersions' }
        $checkbox.type | Should Be 'Microsoft.Common.CheckBox'
        ($checkbox.PSObject.Properties.Name -contains 'defaultValue') | Should Be $false
        $checkbox.constraints.required | Should Be $false
        $form.view.outputs.parameters.includeExcludedImageVersions | Should Be "[steps('replacerConfig').includeExcludedImageVersions]"
        $template.parameters.includeExcludedImageVersions.type | Should Be 'bool'
        $template.parameters.includeExcludedImageVersions.defaultValue | Should Be $false
        $template.resources.functionApp.properties.parameters.functionAppAppSettings.value |
            Should Match "'IncludeExcludedImageVersions', 'value', string\(parameters\('includeExcludedImageVersions'\)\)"
    }

    It 'exposes a nullable runtime configuration update and safe review default' {
        $path = Join-Path $shrRoot 'Set-SessionHostReplacerConfiguration.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
        $parameter = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'IncludeExcludedImageVersions' }
        $parameter.StaticType | Should Be ([Nullable[bool]])
        $text = Get-Content -LiteralPath $path -Raw
        $text | Should Match "IncludeExcludedImageVersions = 'IncludeExcludedImageVersions'"
        $text | Should Match "Name 'IncludeExcludedImageVersions' -Default 'false'"
    }

    It 'surfaces the pilot policy in fresh runtime logs and the workbook configuration page' {
        $workbook = Get-Content -LiteralPath (Join-Path $shrRoot 'modules\workBook\workbookTemplate.json') -Raw | ConvertFrom-Json
        $page = $workbook.items | Where-Object { $_.name -eq 'configuration-page' }
        $policy = $page.content.items | Where-Object { $_.name -eq 'pilot-image-selection-policy' }
        $policy.content.query | Should Match 'IncludeExcludedImageVersions:'
        $policy.content.query | Should Match 'arg_max\(timestamp'
        $policy.content.query | Should Match 'Unknown: requires upgraded runtime and a fresh execution'
        Get-Content -LiteralPath (Join-Path $shrRoot 'functions\run.ps1') -Raw |
            Should Match 'IncludeExcludedImageVersions: \{16\} \| FunctionAppResourceId: \{15\}'
    }
}

Describe 'Session Host Replacer pilot configuration updates' {
    BeforeAll {
        Import-Module Az.Accounts
    }

    BeforeEach {
        $global:shrPilotConfigurationSettings = [pscustomobject]@{
            HostPoolName = 'pilot'
            ReplacementMode = 'SideBySide'
            UnrelatedSetting = 'preserve-this-value'
        }
        $global:shrPilotUpdatedSettings = $null
        Mock Get-AzContext { [pscustomobject]@{ Subscription = @{ Id = 'test-subscription' } } }
        Mock Invoke-AzRestMethod {
            param($Method, $Path, $Payload)
            if ($Method -eq 'GET') {
                return @{ StatusCode = 200; Content = '{"type":"Microsoft.Web/sites","kind":"functionapp"}' }
            }
            if ($Method -eq 'POST') {
                return @{ StatusCode = 200; Content = (@{ properties = $global:shrPilotConfigurationSettings } | ConvertTo-Json -Depth 10) }
            }
            if ($Method -eq 'PUT') {
                $global:shrPilotUpdatedSettings = ($Payload | ConvertFrom-Json).properties
                return @{ StatusCode = 200; Content = '{}' }
            }
            throw "Unexpected request: $Method $Path"
        }
        $script:configurationArguments = @{
            FunctionAppName = 'pilot-shr'
            ResourceGroupName = 'operations'
            PassThru = $true
        }
    }

    It 'reviews a missing setting as disabled without writing' {
        $result = & (Join-Path $shrRoot 'Set-SessionHostReplacerConfiguration.ps1') @configurationArguments
        $result.IncludeExcludedImageVersions | Should Be 'false'
        Assert-MockCalled Invoke-AzRestMethod -Times 0 -Exactly -Scope It -ParameterFilter { $Method -eq 'PUT' }
    }

    It 'enables pilot selection while preserving unrelated settings' {
        $result = & (Join-Path $shrRoot 'Set-SessionHostReplacerConfiguration.ps1') @configurationArguments `
            -IncludeExcludedImageVersions $true -Confirm:$false
        $global:shrPilotUpdatedSettings.IncludeExcludedImageVersions | Should Be 'true'
        $global:shrPilotUpdatedSettings.UnrelatedSetting | Should Be 'preserve-this-value'
        $result.IncludeExcludedImageVersions | Should Be 'true'
        Assert-MockCalled Invoke-AzRestMethod -Times 1 -Exactly -Scope It -ParameterFilter { $Method -eq 'PUT' }
    }

    It 'allows explicitly disabling pilot selection' {
        $global:shrPilotConfigurationSettings | Add-Member -NotePropertyName IncludeExcludedImageVersions -NotePropertyValue 'true'
        & (Join-Path $shrRoot 'Set-SessionHostReplacerConfiguration.ps1') @configurationArguments `
            -IncludeExcludedImageVersions $false -Confirm:$false | Out-Null
        $global:shrPilotUpdatedSettings.IncludeExcludedImageVersions | Should Be 'false'
    }

    It 'does not write or enable pilot selection during WhatIf' {
        & (Join-Path $shrRoot 'Set-SessionHostReplacerConfiguration.ps1') @configurationArguments `
            -IncludeExcludedImageVersions $true -WhatIf | Out-Null
        Assert-MockCalled Invoke-AzRestMethod -Times 0 -Exactly -Scope It -ParameterFilter { $Method -eq 'PUT' }
    }

    AfterAll {
        Remove-Variable -Name shrPilotConfigurationSettings,shrPilotUpdatedSettings -Scope Global
    }
}
