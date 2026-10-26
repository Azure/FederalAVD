$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module Az.Resources -ErrorAction Stop
$publisherPath = Join-Path $repoRoot 'tools\New-TemplateSpecs.ps1'
$parseErrors = $null
$publisherAst = [System.Management.Automation.Language.Parser]::ParseFile($publisherPath, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($function in $publisherAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    Invoke-Expression $function.Extent.Text
}
$sizeCases = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'deployments') -Filter uiFormDefinition.json -Recurse -File | ForEach-Object {
    $form = $_.FullName
    Get-ChildItem -LiteralPath $_.DirectoryName -Filter *.json -File |
        Where-Object { Test-Path -LiteralPath ([IO.Path]::ChangeExtension($_.FullName, '.bicep')) } |
        ForEach-Object { @{ Name = $_.FullName.Substring($repoRoot.Length + 1); TemplateFile = $_.FullName; FormFile = $form } }
})

function Expand-TestTemplateArtifacts {
    param(
        [Newtonsoft.Json.Linq.JObject]$Template,
        [hashtable]$Artifacts,
        [string]$Directory = '',
        [bool]$HasLinkContext = $true
    )

    $resources = $Template['resources']
    $values = [System.Collections.Generic.List[Newtonsoft.Json.Linq.JObject]]::new()
    if ($resources -is [Newtonsoft.Json.Linq.JObject]) {
        foreach ($property in $resources.Properties()) { $values.Add($property.Value) }
    }
    elseif ($resources -is [Newtonsoft.Json.Linq.JArray]) {
        foreach ($resource in $resources) { $values.Add($resource) }
    }
    foreach ($resource in $values) {
        if ([string]$resource['type'] -ine 'Microsoft.Resources/deployments') { continue }
        $properties = $resource['properties']
        $childDirectory = $Directory
        $childHasLinkContext = $false
        $link = $properties['templateLink']
        if ($null -ne $link -and $null -ne $link['relativePath']) {
            if (-not $HasLinkContext) { throw 'Inline deployment cannot resolve relative artifact links.' }
            $path = $Directory + [string]$link['relativePath']
            if (-not $Artifacts.ContainsKey($path)) { throw "Missing artifact '$path'." }
            $properties['template'] = $Artifacts[$path].DeepClone()
            $properties['expressionEvaluationOptions'] = [Newtonsoft.Json.Linq.JObject]::Parse('{"scope":"inner"}')
            $properties.Remove('templateLink') | Out-Null
            $childDirectory = $path.Substring(0, $path.LastIndexOf('/') + 1)
            $childHasLinkContext = $true
        }
        if ($properties['template'] -is [Newtonsoft.Json.Linq.JObject]) {
            Expand-TestTemplateArtifacts -Template $properties['template'] -Artifacts $Artifacts -Directory $childDirectory -HasLinkContext $childHasLinkContext
        }
    }
}

function New-TestDeduplicationPackage {
    param([Newtonsoft.Json.Linq.JObject]$Template, [string]$Directory)

    $file = Join-Path $Directory 'main.json'
    $form = Join-Path $Directory 'form.json'
    [IO.File]::WriteAllText($file, $Template.ToString())
    [IO.File]::WriteAllText($form, '{}')
    return New-DeduplicatedTemplateSpecPackage -TemplateFile $file -FormFile $form -Location usgovvirginia
}

function New-TestInlineDeployment {
    param([Newtonsoft.Json.Linq.JObject]$Template, [string]$Scope = 'inner')

    $resource = [Newtonsoft.Json.Linq.JObject]::Parse(@'
{
  "type":"Microsoft.Resources/deployments",
  "apiVersion":"2024-03-01",
  "name":"[parameters('name')]",
  "subscriptionId":"[subscription().subscriptionId]",
  "resourceGroup":"[parameters('resourceGroup')]",
  "condition":"[parameters('enabled')]",
  "dependsOn":["otherDeployment"],
  "copy":{"name":"batch","count":2},
  "properties":{
    "mode":"Incremental",
    "parameters":{"password":{"reference":{"keyVault":{"id":"/subscriptions/test/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv"},"secretName":"password"}}}
  }
}
'@)
    $resource['properties']['template'] = $Template.DeepClone()
    if ($Scope -ne 'default') {
        $resource['properties']['expressionEvaluationOptions'] = [Newtonsoft.Json.Linq.JObject]::FromObject(@{ scope = $Scope })
    }
    return ,$resource
}

Describe 'Deduplicated publication packages' {
    It 'restores all deployment content and stays within the complete request budget for <Name>' -TestCases $sizeCases {
        param($Name, $TemplateFile, $FormFile)

        $sourceHash = (Get-FileHash -LiteralPath $TemplateFile).Hash
        $formHash = (Get-FileHash -LiteralPath $FormFile).Hash
        $package = New-DeduplicatedTemplateSpecPackage -TemplateFile $TemplateFile -FormFile $FormFile -Location usgovvirginia
        $package.PayloadBytes | Should Not BeGreaterThan $package.OriginalPayloadBytes
        ($package.PayloadBytes + 16384) | Should BeLessThan 2000000
        $payload = [Newtonsoft.Json.Linq.JObject]::Parse((Get-DeduplicatedTemplateSpecPayload -Package $package -Location usgovvirginia))
        $payload['properties']['linkedTemplates'].Count | Should Be $package.Artifacts.Count
        $artifacts = @{}
        foreach ($artifact in $package.Artifacts) { $artifacts[$artifact.Path] = $artifact.Template }
        $restored = $package.RootTemplate.DeepClone()
        Expand-TestTemplateArtifacts -Template $restored -Artifacts $artifacts
        $expected = [Newtonsoft.Json.Linq.JObject]::Parse((Get-Content -LiteralPath $TemplateFile -Raw))
        Remove-TemplateSpecInternalAnnotations -Node $expected
        [Newtonsoft.Json.Linq.JToken]::DeepEquals($expected, $restored) | Should Be $true
        $expectedForm = [Newtonsoft.Json.Linq.JObject]::Parse((Get-Content -LiteralPath $FormFile -Raw))
        [Newtonsoft.Json.Linq.JToken]::DeepEquals($expectedForm, $package.UIFormDefinition) | Should Be $true
        (Get-FileHash -LiteralPath $TemplateFile).Hash | Should Be $sourceHash
        (Get-FileHash -LiteralPath $FormFile).Hash | Should Be $formHash
        if ($Name -eq 'deployments\hostpools\hostpool.json') {
            ($package.OriginalPayloadBytes - $package.PayloadBytes) | Should BeGreaterThan 240000
            ($package.PayloadBytes + 16384) | Should BeLessThan 1600000
            $package.Artifacts.Count | Should Be 28
        }
    }

    It 'deduplicates overlapping parent and child groups with correct artifact-relative paths for <Shape>' -TestCases @(
        @{ Shape = 'symbolic' }
        @{ Shape = 'array' }
    ) {
        param($Shape)

        $leaf = [Newtonsoft.Json.Linq.JObject]::Parse('{"$schema":"https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#","contentVersion":"1.0.0.0","resources":[],"outputs":{"value":{"type":"string","value":"same"}}}')
        $parent = $leaf.DeepClone()
        $children = [Newtonsoft.Json.Linq.JObject]::new()
        $children['first'] = New-TestInlineDeployment $leaf
        $children['second'] = New-TestInlineDeployment $leaf
        $parent['resources'] = $children
        $root = $leaf.DeepClone()
        if ($Shape -eq 'symbolic') {
            $resources = [Newtonsoft.Json.Linq.JObject]::new()
            $resources['one'] = New-TestInlineDeployment $parent
            $resources['two'] = New-TestInlineDeployment $parent
            $root['resources'] = $resources
        }
        else {
            $resources = [Newtonsoft.Json.Linq.JArray]::new()
            $resources.Add((New-TestInlineDeployment $parent))
            $resources.Add((New-TestInlineDeployment $parent))
            $root['resources'] = $resources
        }
        $package = New-TestDeduplicationPackage -Template $root -Directory $TestDrive
        $package.Artifacts.Count | Should Be 2
        $artifacts = @{}
        foreach ($artifact in $package.Artifacts) { $artifacts[$artifact.Path] = $artifact.Template }
        $restored = $package.RootTemplate.DeepClone()
        Expand-TestTemplateArtifacts $restored $artifacts
        [Newtonsoft.Json.Linq.JToken]::DeepEquals($root, $restored) | Should Be $true
        $second = New-TestDeduplicationPackage -Template $root -Directory $TestDrive
        (Get-DeduplicatedTemplateSpecPayload $package usgovvirginia) | Should Be (Get-DeduplicatedTemplateSpecPayload $second usgovvirginia)
    }

    It 'links unique ancestors of duplicate leaves without crossing inline boundaries for <Shape>' -TestCases @(
        @{ Shape = 'symbolic' }
        @{ Shape = 'array' }
    ) {
        param($Shape)

        $leaf = [Newtonsoft.Json.Linq.JObject]::Parse('{"resources":[]}')
        $root = $leaf.DeepClone()
        if ($Shape -eq 'symbolic') {
            $resources = [Newtonsoft.Json.Linq.JObject]::new()
        }
        else {
            $resources = [Newtonsoft.Json.Linq.JArray]::new()
        }
        foreach ($name in @('one', 'two')) {
            $parent = [Newtonsoft.Json.Linq.JObject]::Parse('{"resources":[]}')
            $parent['variables'] = [Newtonsoft.Json.Linq.JObject]::FromObject(@{ unique = $name })
            $parent['resources'].Add((New-TestInlineDeployment $leaf))
            $grandparent = [Newtonsoft.Json.Linq.JObject]::Parse('{"resources":[]}')
            $grandparent['resources'].Add((New-TestInlineDeployment $parent))
            $deployment = New-TestInlineDeployment $grandparent
            if ($Shape -eq 'symbolic') { $resources[$name] = $deployment } else { $resources.Add($deployment) }
        }
        $root['resources'] = $resources
        $package = New-TestDeduplicationPackage $root $TestDrive
        $package.Artifacts.Count | Should Be 5
        $artifacts = @{}
        foreach ($artifact in $package.Artifacts) { $artifacts[$artifact.Path] = $artifact.Template }
        $restored = $package.RootTemplate.DeepClone()
        Expand-TestTemplateArtifacts $restored $artifacts
        [Newtonsoft.Json.Linq.JToken]::DeepEquals($root, $restored) | Should Be $true
        foreach ($deployment in (Get-DeduplicatedTemplateResources $package.RootTemplate)) {
            $deployment['properties']['template'] | Should BeNullOrEmpty
            [string]$deployment['properties']['templateLink']['relativePath'] | Should Match '^artifacts/'
        }
    }

    It 'rejects relative artifact links below an inline deployment in the test resolver' {
        $root = [Newtonsoft.Json.Linq.JObject]::Parse('{"resources":[]}')
        $parent = [Newtonsoft.Json.Linq.JObject]::Parse('{"resources":[{"type":"Microsoft.Resources/deployments","properties":{"templateLink":{"relativePath":"artifacts/leaf.json"}}}]}')
        $root['resources'].Add((New-TestInlineDeployment $parent))
        { Expand-TestTemplateArtifacts $root @{ 'artifacts/leaf.json' = [Newtonsoft.Json.Linq.JObject]::Parse('{"resources":[]}') } } |
            Should Throw 'Inline deployment cannot resolve relative artifact links.'
    }

    It 'keeps duplicate descendants below <Scope>-scope boundaries inline' -TestCases @(
        @{ Scope = 'outer' }
        @{ Scope = 'default' }
    ) {
        param($Scope)

        $leaf = [Newtonsoft.Json.Linq.JObject]::Parse('{"resources":[]}')
        $parent = $leaf.DeepClone()
        $parent['resources'].Add((New-TestInlineDeployment $leaf))
        $parent['resources'].Add((New-TestInlineDeployment $leaf))
        $root = $leaf.DeepClone()
        $root['resources'].Add((New-TestInlineDeployment $parent $Scope))
        $package = New-TestDeduplicationPackage $root $TestDrive
        $package.Artifacts.Count | Should Be 0
        [Newtonsoft.Json.Linq.JToken]::DeepEquals($root, $package.RootTemplate) | Should Be $true
    }

    It 'leaves <Scope>-scope templates inline' -TestCases @(
        @{ Scope = 'outer' }
        @{ Scope = 'default' }
    ) {
        param($Scope)

        $leaf = [Newtonsoft.Json.Linq.JObject]::Parse('{"resources":[]}')
        $root = [Newtonsoft.Json.Linq.JObject]::new()
        $root['resources'] = [Newtonsoft.Json.Linq.JArray]::new()
        $root['resources'].Add((New-TestInlineDeployment $leaf $Scope))
        $root['resources'].Add((New-TestInlineDeployment $leaf $Scope))
        $package = New-TestDeduplicationPackage $root $TestDrive
        $package.Artifacts.Count | Should Be 0
        [Newtonsoft.Json.Linq.JToken]::DeepEquals($root, $package.RootTemplate) | Should Be $true
    }

    It 'does not transform ARM-shaped data in variables, defaults, outputs or runtime payloads' {
        $template = [Newtonsoft.Json.Linq.JObject]::Parse(@'
{
  "resources":[],
  "variables":{"runtime":{"resources":[{"type":"Microsoft.Resources/deployments","properties":{"templateLink":{"relativePath":"runtime-only.json"}}}]}},
  "parameters":{"data":{"type":"object","defaultValue":{"resources":[]}}},
  "outputs":{"data":{"type":"object","value":{"resources":[]}}}
}
'@)
        $package = New-TestDeduplicationPackage $template $TestDrive
        $package.Artifacts.Count | Should Be 0
        [Newtonsoft.Json.Linq.JToken]::DeepEquals($template, $package.RootTemplate) | Should Be $true
    }

    It 'does not coalesce different template bodies' {
        $root = [Newtonsoft.Json.Linq.JObject]::Parse('{"resources":[]}')
        foreach ($value in @('one', 'two')) {
            $leaf = [Newtonsoft.Json.Linq.JObject]::FromObject(@{ resources = @(); variables = @{ value = $value } })
            $root['resources'].Add((New-TestInlineDeployment $leaf))
        }
        $package = New-TestDeduplicationPackage $root $TestDrive
        $package.Artifacts.Count | Should Be 0
    }

    It 'rejects pre-existing relative links instead of silently losing artifacts' {
        $root = [Newtonsoft.Json.Linq.JObject]::Parse('{"resources":{"linked":{"type":"Microsoft.Resources/deployments","properties":{"templateLink":{"relativePath":"existing.json"}}}}}')
        { New-TestDeduplicationPackage $root $TestDrive } | Should Throw 'self-contained ARM input'
    }

    It 'preserves remote and Template Spec ID links without downloading them' {
        $root = [Newtonsoft.Json.Linq.JObject]::Parse('{"resources":[{"type":"Microsoft.Resources/deployments","properties":{"templateLink":{"id":"/subscriptions/test/spec/version"}}},{"type":"Microsoft.Resources/deployments","properties":{"templateLink":{"uri":"https://example.invalid/template.json"}}}]}')
        $package = New-TestDeduplicationPackage $root $TestDrive
        [Newtonsoft.Json.Linq.JToken]::DeepEquals($root, $package.RootTemplate) | Should Be $true
    }
}

Describe 'Explicit cloud-context Template Spec publication' {
    It 'sends the complete version through -Path without calling the native packager' {
        $script:putCalls = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-AzRestMethod {
            param($Path, $Method, $Payload)
            $script:putCalls.Add(@{ Path = $Path; Method = $Method; Payload = $Payload })
            [pscustomobject]@{ StatusCode = 201; Content = '{}' }
        }
        $package = New-DeduplicatedTemplateSpecPackage `
            -TemplateFile (Join-Path $repoRoot 'deployments\hostpools\hostpool.json') `
            -FormFile (Join-Path $repoRoot 'deployments\hostpools\uiFormDefinition.json') -Location usgovvirginia
        $payload = Get-DeduplicatedTemplateSpecPayload $package usgovvirginia
        Publish-DeduplicatedTemplateSpec -ResourceId '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Resources/templateSpecs/spec' `
            -Version '2.0.0' -ParentPayload '{}' -VersionPayload $payload
        $script:putCalls.Count | Should Be 2
        $script:putCalls[1].Payload | Should Be $payload
        $script:putCalls[1].Path | Should Be '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Resources/templateSpecs/spec/versions/2.0.0?api-version=2021-05-01'
        $source = Get-Content -LiteralPath $publisherPath -Raw
        $source | Should Not Match 'TemplateSpecPackagingEngine|New-AzTemplateSpec\s+`|https://management\.azure\.com'
    }

    It 'stops on HTTP <StatusCode> without sending the version' -TestCases @(
        @{ StatusCode = 400 }
        @{ StatusCode = 403 }
        @{ StatusCode = 500 }
    ) {
        param($StatusCode)

        Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = $StatusCode; Content = 'server failure' } }
        { Publish-DeduplicatedTemplateSpec -ResourceId '/subscriptions/test/spec' -Version '1.0.0' -ParentPayload '{}' -VersionPayload '{}' } |
            Should Throw "HTTP $StatusCode"
        Assert-MockCalled Invoke-AzRestMethod -Times 1 -Exactly -Scope It
    }
}

Describe 'Publisher process lifecycle without Azure requests' {
    BeforeAll {
        $harnessPath = Join-Path $TestDrive 'publisher-harness.ps1'
        $harness = @'
param([string]$PublisherPath, [string]$Mode)
$ErrorActionPreference = 'Stop'
Import-Module Az.Resources -ErrorAction Stop
$global:FixtureMode = $Mode
$global:RestCalls = [System.Collections.Generic.List[object]]::new()
$global:ResourceGroupCreates = 0
$global:SpecReads = 0
$root = Split-Path -Parent (Split-Path -Parent $PublisherPath)
$policy = Get-Content -Raw (Join-Path $root 'deployments\shared\data\namingPolicy.json') | ConvertFrom-Json
$abbreviations = Get-Content -Raw (Join-Path $root 'deployments\shared\data\resourceAbbreviations.json') | ConvertFrom-Json
$global:SpecName = "$($abbreviations.templateSpecs)-$($policy.defaults.workload)-$($policy.templateSpecs.hostPool)-va-dedup-test"
function global:Get-AzContext {
    [CmdletBinding()]param()
    [pscustomobject]@{
        Environment = [pscustomobject]@{ Name = 'AzureUSGovernment' }
        Subscription = [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000000' }
    }
}
function global:Get-AzResourceGroup {
    [CmdletBinding()]param()
    if ($global:FixtureMode -notin @('Create', 'WhatIfMissing')) {
        [pscustomobject]@{ ResourceGroupName = 'rg-test' }
    }
}
function global:New-AzResourceGroup {
    [CmdletBinding()]param($Name, $Location)
    $global:ResourceGroupCreates++
}
function global:Get-AzTemplateSpec {
    [CmdletBinding()]param($ResourceGroupName, $Name, [ValidatePattern('^[-\w\._\(\)]+$')][string]$Version)
    $global:SpecReads++
    if (-not $Name -and $global:FixtureMode -like 'Collection*') {
        $specs = [System.Collections.Generic.List[Microsoft.Azure.Commands.ResourceManager.Cmdlets.SdkModels.PSTemplateSpec]]::new()
        $other = [Microsoft.Azure.Commands.ResourceManager.Cmdlets.SdkModels.PSTemplateSpec]::new()
        $other.Name = 'unrelated-spec'
        $other.Location = 'EASTUS2'
        $other.Tags = [System.Collections.Generic.Dictionary[string,string]]::new()
        $other.Tags.Add('owner', 'unrelated')
        $specs.Add($other)
        if ($global:FixtureMode -ne 'CollectionMissing') {
            $target = [Microsoft.Azure.Commands.ResourceManager.Cmdlets.SdkModels.PSTemplateSpec]::new()
            $target.Name = $global:SpecName
            $target.Location = if ($global:FixtureMode -eq 'CollectionWrongLocation') { 'westus2' } else { 'USGOVVIRGINIA' }
            $target.Tags = [System.Collections.Generic.Dictionary[string,string]]::new()
            $target.Tags.Add('owner', 'preserved')
            $specs.Add($target)
        }
        Write-Output -NoEnumerate $specs
        return
    }
    if ($global:FixtureMode -in @('Existing', 'EmptyVersions', 'NonNumericVersion', 'VersionReadFailure', 'CollectionExisting')) {
        if ($Name -and $Name -ne $global:SpecName) { throw "Unexpected Template Spec name '$Name'." }
        $spec = [Microsoft.Azure.Commands.ResourceManager.Cmdlets.SdkModels.PSTemplateSpec]::new()
        $spec.Name = $global:SpecName
        $spec.Location = 'usgovvirginia'
        $spec.Tags = [System.Collections.Generic.Dictionary[string,string]]::new()
        $spec.Tags.Add('owner', 'preserved')
        if ($Name) {
            if ($global:FixtureMode -eq 'VersionReadFailure') { throw 'Fixture version access denied' }
            $versionNames = switch ($global:FixtureMode) {
                'EmptyVersions' { @() }
                'NonNumericVersion' { @('release-preview') }
                default { @('2.5.0', '4.0.0', '3.9.0') }
            }
            $spec.Versions = @(
                foreach ($versionName in $versionNames) {
                    $specVersion = [Microsoft.Azure.Commands.ResourceManager.Cmdlets.SdkModels.PSTemplateSpecVersion]::new()
                    $specVersion.Name = $versionName
                    $specVersion
                }
            )
        }
        $spec
    }
}
function global:Invoke-AzRestMethod {
    [CmdletBinding()]param($Path, $Method, $Payload)
    $global:RestCalls.Add([pscustomobject]@{ Path = $Path; Method = $Method; Payload = $Payload })
    $status = if ($global:FixtureMode -eq 'Forbidden') { 403 } else { 201 }
    [pscustomobject]@{ StatusCode = $status; Content = 'fixture response' }
}
$failure = $null
$output = @()
try {
    $arguments = @{
        ResourceGroupName = 'rg-test'
        Location = 'usgovvirginia'
        TemplateSpecNameSuffix = 'dedup-test'
        createHostPool = $true
        createCustomImage = $false
        CreateAddOns = $false
    }
    if ($Mode -like 'WhatIf*') { $arguments.WhatIf = $true }
    $output = @(& $PublisherPath @arguments)
}
catch {
    $failure = $_.Exception.Message
}
$result = @{
    Failure = $failure
    RestCalls = @($global:RestCalls.ToArray())
    ResourceGroupCreates = $global:ResourceGroupCreates
    SpecReads = $global:SpecReads
    Output = @($output | ForEach-Object { [string]$_ })
}
Write-Output ('RESULT:' + (ConvertTo-Json -InputObject $result -Depth 100 -Compress))
'@
        [IO.File]::WriteAllText($harnessPath, $harness)
    }

    It 'handles <Mode> with explicit, isolated publication behavior' -TestCases @(
        @{ Mode = 'Publish'; ExpectedPuts = 2; ExpectedCreates = 0 }
        @{ Mode = 'Existing'; ExpectedPuts = 2; ExpectedCreates = 0 }
        @{ Mode = 'CollectionExisting'; ExpectedPuts = 2; ExpectedCreates = 0 }
        @{ Mode = 'CollectionMissing'; ExpectedPuts = 2; ExpectedCreates = 0 }
        @{ Mode = 'CollectionWrongLocation'; ExpectedPuts = 0; ExpectedCreates = 0 }
        @{ Mode = 'EmptyVersions'; ExpectedPuts = 2; ExpectedCreates = 0 }
        @{ Mode = 'NonNumericVersion'; ExpectedPuts = 0; ExpectedCreates = 0 }
        @{ Mode = 'Create'; ExpectedPuts = 2; ExpectedCreates = 1 }
        @{ Mode = 'WhatIf'; ExpectedPuts = 0; ExpectedCreates = 0 }
        @{ Mode = 'WhatIfMissing'; ExpectedPuts = 0; ExpectedCreates = 0 }
        @{ Mode = 'VersionReadFailure'; ExpectedPuts = 0; ExpectedCreates = 0 }
        @{ Mode = 'Forbidden'; ExpectedPuts = 1; ExpectedCreates = 0 }
    ) {
        param($Mode, $ExpectedPuts, $ExpectedCreates)

        $lines = @(& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File $harnessPath -PublisherPath $publisherPath -Mode $Mode)
        $LASTEXITCODE | Should Be 0
        $record = @($lines | Where-Object { $_ -like 'RESULT:*' })
        $record.Count | Should Be 1
        $result = $record[0].Substring(7) | ConvertFrom-Json
        @($result.RestCalls).Count | Should Be $ExpectedPuts
        $result.ResourceGroupCreates | Should Be $ExpectedCreates
        if ($Mode -eq 'CollectionWrongLocation') {
            $result.Failure | Should Match "is in 'westus2', not 'usgovvirginia'"
            $result.SpecReads | Should Be 1
        }
        elseif ($Mode -eq 'VersionReadFailure') {
            $result.Failure | Should Match 'Fixture version access denied'
        }
        elseif ($Mode -eq 'NonNumericVersion') {
            $result.Failure | Should Match "Cannot increment non-numeric Template Spec version 'release-preview'"
        }
        elseif ($Mode -eq 'Forbidden') {
            $result.Failure | Should Match 'HTTP 403'
        }
        else {
            $result.Failure | Should BeNullOrEmpty
        }
        if ($ExpectedPuts -eq 2) {
            $parent = $result.RestCalls[0].Payload | ConvertFrom-Json
            $version = $result.RestCalls[1].Payload | ConvertFrom-Json
            $version.properties.linkedTemplates.Count | Should Be 28
            $version.properties.mainTemplate.languageVersion | Should Be '2.0'
            $result.RestCalls[1].Path | Should Match '-dedup-test/versions/'
            $result.RestCalls[1].Path | Should Match '^/subscriptions/'
            if ($Mode -in @('Existing', 'CollectionExisting')) {
                $parent.tags.owner | Should Be 'preserved'
                $result.RestCalls[1].Path | Should Match '/versions/5.0.0\?'
                $result.SpecReads | Should Be 2
            }
            if ($Mode -eq 'EmptyVersions') {
                $parent.tags.owner | Should Be 'preserved'
                $result.RestCalls[1].Path | Should Match '/versions/1.0.0\?'
            }
            if ($Mode -eq 'CollectionMissing') {
                $parent.tags | Should BeNullOrEmpty
                $result.RestCalls[1].Path | Should Match '/versions/1.0.0\?'
                $result.SpecReads | Should Be 1
            }
        }
        if ($Mode -like 'WhatIf*') {
            ($result.Output -join "`n") | Should Match 'WhatIf complete. No resources were created or published.'
        }
        if ($Mode -eq 'WhatIfMissing') {
            $result.SpecReads | Should Be 0
        }
    }
}
