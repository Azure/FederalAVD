$repoRoot = Split-Path -Parent $PSScriptRoot

function Invoke-ImageBuildFormExpression {
    param([string]$Expression, [hashtable]$Steps)

    function Get-ImageBuildFormLength {
        param($Value)
        if ($Value -is [string]) { $Value.Length } else { $Value.Count }
    }

    # Evaluate the scalar functions used by these controls, not the Portal runtime.
    $functions = @{
        steps = { param($name) $Steps[$name] }.GetNewClosure()
        'if' = { param($condition, $yes, $no) if ($condition) { ,$yes } else { ,$no } }
        coalesce = { foreach ($value in $args) { if ($null -ne $value) { return ,$value } } }
        contains = {
            param($value, $search)
            if ($value -is [string]) { $value.Contains($search) } else { $value -ccontains $search }
        }
        equals = { param($left, $right) [object]::Equals($left, $right) }
        'and' = { $false -notin $args }
        'or' = { $true -in $args }
        'not' = { param($value) -not $value }
        parse = { param($value) ,($value | ConvertFrom-Json) }
    }
    $body = $Expression.Substring(1, $Expression.Length - 2)
    $body = [regex]::Replace($body, "'(?:[^']|'')*'|\b(?:steps|if|coalesce|contains|equals|and|or|not|length|parse)\(|\b(?:true|false)\b", {
        param($match)
        if ($match.Value.StartsWith("'")) {
            $match.Value
        } elseif ($match.Value -eq 'length(') {
            '(Get-ImageBuildFormLength '
        } elseif ($match.Value.EndsWith('(')) {
            '$functions.' + $match.Value.TrimEnd('(') + '.InvokeReturnAsIs('
        } else {
            '$' + $match.Value
        }
    })
    & ([scriptblock]::Create($body))
}

function New-ImageBuildFormContext {
    param(
        [string]$SecurityType,
        [bool]$Existing,
        [hashtable]$Sizes,
        [bool]$Accelerated = $false,
        [bool]$Hibernate = $false,
        [bool]$Nvme = $false
    )

    $inactiveSecurity = if ($SecurityType -eq 'ConfidentialVM') { 'Standard' } else { 'ConfidentialVM' }
    @{
        imageDest = @{
            imageDefinition = @{
                useExImageDef = $Existing
                securityType = $(if ($Existing) { $inactiveSecurity } else { $SecurityType })
                isAcceleratedNetworkSupported = $(if ($Existing) { -not $Accelerated } else { $Accelerated })
                isHibernateSupported = $(if ($Existing) { -not $Hibernate } else { $Hibernate })
                isNVMeSupported = $(if ($Existing) { -not $Nvme } else { $Nvme })
                existingImageDefinition = @{
                    SecurityType = $(if ($Existing) { $SecurityType } else { $inactiveSecurity })
                    IsAcceleratedNetworkSupported = $(if ($Existing) { $Accelerated } else { -not $Accelerated })
                    IsHibernateSupported = $(if ($Existing) { $Hibernate } else { -not $Hibernate })
                    DiskControllerTypes = $(if ($Existing -eq $Nvme) { 'NVMe' } else { 'SCSI' })
                }
            }
        }
        basics = @{ resourceSkusApi = @{ transformed = $Sizes } }
        imageSource = @{ sku = 'win11' }
    }
}

Describe 'Image-build VM-size compatibility' {
    BeforeAll {
        $form = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\imageBuild\uiFormDefinition.json') -Raw | ConvertFrom-Json
        $template = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\imageBuild\imageBuild.json') -Raw | ConvertFrom-Json
        $basics = $form.view.properties.steps | Where-Object name -eq 'basics'
        $transforms = ($basics.elements | Where-Object name -eq 'resourceSkusApi').request.transforms
        $vmStep = $form.view.properties.steps | Where-Object name -eq 'vmProps'
        $vmSize = $vmStep.elements | Where-Object name -eq 'vmSize'
        $destination = $form.view.properties.steps | Where-Object name -eq 'imageDest'
        $definition = $destination.elements | Where-Object name -eq 'imageDefinition'
        $nvme = $definition.elements | Where-Object name -eq 'isNVMeSupported'
        $accelerated = $definition.elements | Where-Object name -eq 'isAcceleratedNetworkSupported'
        $hibernate = $definition.elements | Where-Object name -eq 'isHibernateSupported'
        $security = $definition.elements | Where-Object name -eq 'securityType'
        $confidentialWarning = $definition.elements | Where-Object name -eq 'confidentialVmWarningBox'
        $incompatibleWarning = $definition.elements | Where-Object name -eq 'existingImageDefIncompatibleWarning'
        $regionalWarning = $definition.elements | Where-Object name -eq 'existingImageDefRegionalIncompatWarning'
        $newFeatureWarning = $definition.elements | Where-Object name -eq 'newImageDefFeatureCompatibilityWarning'
        $hibernationWarning = $definition.elements | Where-Object name -eq 'hibernationWarningBox'
        $featureOutputs = @{
            imageDefinitionIsAcceleratedNetworkSupported = 'isAcceleratedNetworkSupported'
            imageDefinitionIsHibernateSupported = 'isHibernateSupported'
            imageDefinitionIsHigherStoragePerformanceSupported = 'isNVMeSupported'
        }
        $selector = $vmSize.constraints.allowedValues
        if (-not $selector.StartsWith('[map(') -or $selector.IndexOf(', (item) =>') -lt 0) {
            throw 'The VM-size selector must map the existing feature-filtered list.'
        }
        $selectorExpression = '[' + $selector.Substring(5, $selector.IndexOf(', (item) =>') - 5) + ']'

        $fixtures = @(
            @{ Name = 'scsi-accelerated'; Controller = 'SCSI'; Accel = 'True' }
            @{ Name = 'scsi-basic'; Controller = 'SCSI' }
            @{ Name = 'dual-accelerated'; Controller = 'SCSI,NVMe'; Accel = 'True' }
            @{ Name = 'nvme-basic'; Controller = 'NVMe' }
            @{ Name = 'Standard_D4as_v6'; Controller = 'NVMe'; Accel = 'True' }
            @{ Name = 'hibernation-basic'; Controller = 'SCSI'; Hibernate = 'True' }
            @{ Name = 'hibernation-accelerated'; Controller = 'SCSI'; Hibernate = 'True'; Accel = 'True' }
            @{ Name = 'hibernation-nvme'; Controller = 'NVMe'; Hibernate = 'True'; Accel = 'True' }
            @{ Name = 'confidential'; Controller = 'SCSI'; Confidential = 'SNP' }
            @{ Name = 'restricted'; Controller = 'NVMe'; Accel = 'True'; Restricted = $true }
            @{ Name = 'arm64'; Controller = 'NVMe'; Accel = 'True'; Architecture = 'Arm64' }
            @{ Name = 'legacy-scsi'; Accel = 'True' }
            @{ Name = 'gen1-only'; Controller = 'NVMe'; Accel = 'True'; Generation = 'V1' }
            @{ Name = 'not-a-vm'; Controller = 'NVMe'; Accel = 'True'; ResourceType = 'disks' }
            @{ Name = 'two-vcpu'; Controller = 'SCSI,NVMe'; Accel = 'True'; Hibernate = 'True'; Cpus = '2' }
            @{ Name = 'eight-vcpu'; Controller = 'SCSI,NVMe'; Accel = 'True'; Hibernate = 'True'; Cpus = '8' }
            @{ Name = 'missing-vcpu'; Controller = 'SCSI,NVMe'; Accel = 'True'; Hibernate = 'True'; Cpus = $null }
            @{ Name = 'confidential-eight-vcpu'; Controller = 'SCSI'; Confidential = 'SNP'; Cpus = '8' }
        )
        $fixtureExpressions = foreach ($fixture in $fixtures) {
            $capabilities = @(
                "{name: 'AcceleratedNetworkingEnabled', value: '$($fixture.Accel)'}"
                "{name: 'HibernationSupported', value: '$($fixture.Hibernate)'}"
                "{name: 'CpuArchitectureType', value: '$(if ($fixture.Architecture) { $fixture.Architecture } else { 'x64' })'}"
                "{name: 'HyperVGenerations', value: '$(if ($fixture.Generation) { $fixture.Generation } else { 'V1,V2' })'}"
            )
            if (-not $fixture.ContainsKey('Cpus') -or $fixture.Cpus) {
                $cpus = if ($fixture.ContainsKey('Cpus')) { $fixture.Cpus } else { '4' }
                $capabilities += "{name: 'vCPUs', value: '$cpus'}"
            }
            if ($fixture.Controller) {
                $capabilities += "{name: 'DiskControllerTypes', value: '$($fixture.Controller)'}"
            }
            if ($fixture.Confidential) {
                $capabilities += "{name: 'ConfidentialComputingType', value: '$($fixture.Confidential)'}"
            }
            $resourceType = if ($fixture.ResourceType) { $fixture.ResourceType } else { 'virtualMachines' }
            $restrictions = if ($fixture.Restricted) { "[{type: 'Location'}]" } else { '`[]`' }
            "{name: '$($fixture.Name)', resourceType: '$resourceType', capabilities: [$($capabilities -join ',')], restrictions: $restrictions}"
        }

        # Azure CLI supplies the JMESPath evaluator; az version makes no Azure requests.
        $results = @{}
        foreach ($transform in $transforms.PSObject.Properties) {
            $query = "{value: [$($fixtureExpressions -join ',')]} | $($transform.Value)"
            $json = & az version --query $query --output json --only-show-errors
            if ($LASTEXITCODE -ne 0) {
                throw "SKU transform '$($transform.Name)' failed in Azure CLI."
            }
            $results[$transform.Name] = @($json | ConvertFrom-Json)
        }
        $withoutPreferred = $fixtureExpressions | Where-Object { $_ -notmatch "name: 'Standard_D4as_v6'" }
        $query = "{value: [$($withoutPreferred -join ',')]} | $($transforms.nvmeAccelNetVMSizes)"
        $json = & az version --query $query --output json --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw 'Preferred-size absence query failed in Azure CLI.' }
        $withoutPreferredResult = @($json | ConvertFrom-Json)

        $emptyResults = @{}
        foreach ($transform in $transforms.PSObject.Properties) {
            $emptyResults[$transform.Name] = "$($transform.Name): ($($transform.Value))"
        }
        $query = '{value: `[]`} | {' + ($emptyResults.Values -join ',') + '}'
        $json = & az version --query $query --output json --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw 'Empty-region query failed in Azure CLI.' }
        $emptyRegion = $json | ConvertFrom-Json
    }

    It 'filters <Name> to four-vCPU SKUs using advertised capabilities' -TestCases @(
        @{ Name = 'confidentialVMSizes'; Expected = 'confidential' }
        @{ Name = 'hibernationVMSizes'; Expected = 'hibernation-basic|hibernation-accelerated' }
        @{ Name = 'nvmeVMSizes'; Expected = 'Standard_D4as_v6|dual-accelerated|nvme-basic|hibernation-nvme' }
        @{ Name = 'acceleratedNetworkingVMSizes'; Expected = 'scsi-accelerated|dual-accelerated|hibernation-accelerated|legacy-scsi' }
        @{ Name = 'hibernationAccelNetVMSizes'; Expected = 'hibernation-accelerated' }
        @{ Name = 'nvmeAccelNetVMSizes'; Expected = 'Standard_D4as_v6|dual-accelerated|hibernation-nvme' }
        @{ Name = 'defaultVMSizes'; Expected = 'scsi-accelerated|scsi-basic|dual-accelerated|hibernation-basic|hibernation-accelerated|legacy-scsi' }
    ) {
        param($Name, $Expected)
        ($results[$Name] -join '|') | Should Be $Expected
    }

    It 'keeps the default VM size and controller aligned in generated ARM' {
        $template.parameters.vmSize.defaultValue | Should Be 'Standard_D4as_v6'
        $template.parameters.vmSize.minLength | Should Be 1
        ($template.parameters.vmSize.PSObject.Properties.Name -contains 'allowedValues') | Should Be $false
        $template.parameters.imageDefinitionIsHigherStoragePerformanceSupported.defaultValue | Should Be $true
        $imageController = $template.resources.imageVm.properties.parameters.diskControllerType
        $orchestrationController = $template.resources.orchestrationVm.properties.parameters.diskControllerType
        $imageController | Should Match "'NVMe'"
        $imageController | Should Be $orchestrationController
    }

    It 'lets the dropdown use its first compatible option instead of an unavailable fixed default' {
        $vmSize.type | Should Be 'Microsoft.Common.DropDown'
        $vmSize.filter | Should Be $true
        $vmSize.constraints.required | Should Be $true
        ($vmSize.PSObject.Properties.Name -contains 'defaultValue') | Should Be $false
        $results.nvmeAccelNetVMSizes[0] | Should Be 'Standard_D4as_v6'
        $withoutPreferredResult[0] | Should Be 'dual-accelerated'
    }

    It 'keeps empty regions empty rather than substituting an incompatible size' {
        foreach ($property in $emptyRegion.PSObject.Properties) {
            @($property.Value).Count | Should Be 0
        }
    }

    It 'uses a valid NVMe default for hibernation without resetting controls on security changes' {
        $condition = "equals(coalesce(steps('imageDest').imageDefinition.isHibernateSupported, false), true)"
        $nvme.defaultValue | Should Be "[if($condition, 'No', 'Yes')]"
        $nvme.constraints.allowedValues.StartsWith("[if($condition,") | Should Be $true
        $accelerated.defaultValue | Should Be 'Yes'
        foreach ($control in @($accelerated, $hibernate)) {
            ($control.constraints.allowedValues -is [array]) | Should Be $true
            ($control.constraints.allowedValues.value -join '|') | Should Be 'True|False'
        }
        $nvme.constraints.allowedValues | Should Not Match 'securityType'
    }

    It 'uses ordinary build-feature filtering for <SecurityType> on both definition paths' -TestCases @(
        @{ SecurityType = 'Standard' }
        @{ SecurityType = 'TrustedLaunch' }
        @{ SecurityType = 'TrustedLaunchSupported' }
        @{ SecurityType = 'ConfidentialVMSupported' }
        @{ SecurityType = 'TrustedLaunchAndConfidentialVmSupported' }
    ) {
        param($SecurityType)
        $combinations = @(
            @{ Accelerated = $false; Hibernate = $false; Nvme = $false; List = 'defaultVMSizes' }
            @{ Accelerated = $true; Hibernate = $false; Nvme = $false; List = 'acceleratedNetworkingVMSizes' }
            @{ Accelerated = $false; Hibernate = $true; Nvme = $false; List = 'hibernationVMSizes' }
            @{ Accelerated = $true; Hibernate = $true; Nvme = $false; List = 'hibernationAccelNetVMSizes' }
            @{ Accelerated = $false; Hibernate = $false; Nvme = $true; List = 'nvmeVMSizes' }
            @{ Accelerated = $true; Hibernate = $false; Nvme = $true; List = 'nvmeAccelNetVMSizes' }
        )
        foreach ($existing in @($false, $true)) {
            foreach ($combination in $combinations) {
                $context = New-ImageBuildFormContext -SecurityType $SecurityType -Existing $existing -Sizes $results `
                    -Accelerated $combination.Accelerated -Hibernate $combination.Hibernate -Nvme $combination.Nvme
                $selected = @(Invoke-ImageBuildFormExpression $selectorExpression $context)
                ($selected -join '|') | Should Be ($results[$combination.List] -join '|')
                (Invoke-ImageBuildFormExpression $vmSize.visible $context) | Should Be $true
                (Invoke-ImageBuildFormExpression $incompatibleWarning.visible $context) | Should Be $false
                (Invoke-ImageBuildFormExpression $regionalWarning.visible $context) | Should Be $false
                foreach ($binding in $featureOutputs.GetEnumerator()) {
                    $expected = if ($existing) { $false } else { $context.imageDest.imageDefinition[$binding.Value] }
                    (Invoke-ImageBuildFormExpression $form.view.outputs.parameters.($binding.Key) $context) | Should Be $expected
                }
                if (-not $existing) {
                    (Invoke-ImageBuildFormExpression $confidentialWarning.visible $context) | Should Be $false
                    $choices = $security.constraints.allowedValues
                    ($choices.value -contains $SecurityType) | Should Be $true
                    ($choices.value -contains 'ConfidentialVM') | Should Be $true
                    $choices = $accelerated.constraints.allowedValues
                    ($choices.value -contains $true) | Should Be $true
                    $choices = $hibernate.constraints.allowedValues
                    ($choices.value -contains $true) | Should Be $true
                    $choices = Invoke-ImageBuildFormExpression $nvme.constraints.allowedValues $context
                    ($choices.value -contains $true) | Should Be (-not $combination.Hibernate)
                    $expectedDefault = if ($combination.Hibernate) { 'No' } else { 'Yes' }
                    (Invoke-ImageBuildFormExpression $nvme.defaultValue $context) | Should Be $expectedDefault
                    foreach ($control in @($accelerated, $hibernate, $nvme)) {
                        (Invoke-ImageBuildFormExpression $control.visible $context) | Should Be $true
                    }
                }
            }
        }
    }

    It 'preserves exact ConfidentialVM build restrictions' {
        foreach ($existing in @($false, $true)) {
            $context = New-ImageBuildFormContext -SecurityType 'ConfidentialVM' -Existing $existing -Sizes $results
            $selected = @(Invoke-ImageBuildFormExpression $selectorExpression $context)
            ($selected -join '|') | Should Be ($results.confidentialVMSizes -join '|')
            (Invoke-ImageBuildFormExpression $vmSize.visible $context) | Should Be $true
            if (-not $existing) {
                (Invoke-ImageBuildFormExpression $confidentialWarning.visible $context) | Should Be $true
                foreach ($control in @($accelerated, $hibernate, $nvme)) {
                    (Invoke-ImageBuildFormExpression $control.visible $context) | Should Be $false
                }
                $choices = $security.constraints.allowedValues
                ($choices.value -contains 'ConfidentialVM') | Should Be $true
            }
        }
        foreach ($feature in @('Accelerated', 'Hibernate', 'Nvme')) {
            $parameters = @{ SecurityType = 'ConfidentialVM'; Existing = $true; Sizes = $results; $feature = $true }
            $context = New-ImageBuildFormContext @parameters
            (Invoke-ImageBuildFormExpression $incompatibleWarning.visible $context) | Should Be $true
            (Invoke-ImageBuildFormExpression $vmSize.visible $context) | Should Be $false
        }
    }

    It 'keeps all security choices available independently of the feature controls' {
        ($security.constraints.allowedValues -is [array]) | Should Be $true
        $security.constraints.allowedValues.Count | Should Be 6
        ($security.constraints.allowedValues.value -join '|') |
            Should Be 'Standard|TrustedLaunch|TrustedLaunchSupported|ConfidentialVM|ConfidentialVMSupported|TrustedLaunchAndConfidentialVmSupported'
        ($security.constraints.allowedValues.label -contains $security.defaultValue) | Should Be $true
    }

    It 'forces new ConfidentialVM feature outputs off despite every possible stale selection' {
        $sizes = $results.Clone()
        $sizes.hibernationAccelNetVMSizes = @()
        foreach ($accelValue in @($false, $true)) {
            foreach ($hibernateValue in @($false, $true)) {
                foreach ($nvmeValue in @($false, $true)) {
                    $context = New-ImageBuildFormContext -SecurityType 'ConfidentialVM' -Existing $false -Sizes $sizes `
                        -Accelerated $accelValue -Hibernate $hibernateValue -Nvme $nvmeValue
                    foreach ($binding in $featureOutputs.GetEnumerator()) {
                        (Invoke-ImageBuildFormExpression $form.view.outputs.parameters.($binding.Key) $context) | Should Be $false
                    }
                    $selected = @(Invoke-ImageBuildFormExpression $selectorExpression $context)
                    ($selected -join '|') | Should Be ($results.confidentialVMSizes -join '|')
                    (Invoke-ImageBuildFormExpression $vmSize.visible $context) | Should Be $true
                    (Invoke-ImageBuildFormExpression $hibernationWarning.visible $context) | Should Be $false
                    (Invoke-ImageBuildFormExpression $newFeatureWarning.visible $context) | Should Be $false
                    (Invoke-ImageBuildFormExpression $confidentialWarning.visible $context) | Should Be $true
                    foreach ($control in @($accelerated, $hibernate, $nvme)) {
                        (Invoke-ImageBuildFormExpression $control.visible $context) | Should Be $false
                    }
                    foreach ($supportedType in @('TrustedLaunchSupported', 'ConfidentialVMSupported', 'TrustedLaunchAndConfidentialVmSupported')) {
                        $context.imageDest.imageDefinition.securityType = $supportedType
                        foreach ($binding in $featureOutputs.GetEnumerator()) {
                            $expected = $context.imageDest.imageDefinition[$binding.Value]
                            (Invoke-ImageBuildFormExpression $form.view.outputs.parameters.($binding.Key) $context) | Should Be $expected
                        }
                        (Invoke-ImageBuildFormExpression $confidentialWarning.visible $context) | Should Be $false
                    }
                }
            }
        }
        $confidentialWarning.options.style | Should Be 'Info'
    }

    It 'does not hide supported definitions when only the Confidential SKU list is empty' {
        $sizes = $results.Clone()
        $sizes.confidentialVMSizes = @()
        foreach ($securityType in @('ConfidentialVMSupported', 'TrustedLaunchAndConfidentialVmSupported', 'ConfidentialVM')) {
            $context = New-ImageBuildFormContext -SecurityType $securityType -Existing $true -Sizes $sizes
            $isConfidential = $securityType -eq 'ConfidentialVM'
            (Invoke-ImageBuildFormExpression $vmSize.visible $context) | Should Be (-not $isConfidential)
            (Invoke-ImageBuildFormExpression $regionalWarning.visible $context) | Should Be $isConfidential
        }
    }

    It 'preserves hibernation controller and regional restrictions for supported definitions' {
        foreach ($securityType in @('TrustedLaunchSupported', 'ConfidentialVMSupported', 'TrustedLaunchAndConfidentialVmSupported')) {
            $context = New-ImageBuildFormContext -SecurityType $securityType -Existing $true -Sizes $results -Hibernate $true -Nvme $true
            (Invoke-ImageBuildFormExpression $incompatibleWarning.visible $context) | Should Be $true
            (Invoke-ImageBuildFormExpression $vmSize.visible $context) | Should Be $false
            $sizes = $results.Clone()
            $sizes.hibernationAccelNetVMSizes = @()
            foreach ($existing in @($false, $true)) {
                $context = New-ImageBuildFormContext -SecurityType $securityType -Existing $existing -Sizes $sizes -Hibernate $true -Accelerated $true
                (Invoke-ImageBuildFormExpression $vmSize.visible $context) | Should Be $false
                (Invoke-ImageBuildFormExpression $regionalWarning.visible $context) | Should Be $existing
                (Invoke-ImageBuildFormExpression $newFeatureWarning.visible $context) | Should Be (-not $existing)
            }
        }
    }

    It 'preserves the existing selector branches and output parameter bindings' {
        @($transforms.PSObject.Properties).Count | Should Be 7
        $vmSize.constraints.allowedValues | Should Not Match 'scsiOnlyVMSizes|scsiAccelNetVMSizes'
        $vmSize.constraints.allowedValues | Should Match 'existingImageDefinition\.DiskControllerTypes'
        $vmSize.constraints.allowedValues | Should Match 'transformed\.acceleratedNetworkingVMSizes'
        $vmSize.constraints.allowedValues | Should Match 'transformed\.defaultVMSizes'
        $vmSize.constraints.allowedValues.StartsWith("[map(if(steps('imageDest').imageDefinition.useExImageDef,") | Should Be $true
        $form.view.outputs.parameters.vmSize | Should Be "[steps('vmProps').vmSize]"
        foreach ($binding in $featureOutputs.GetEnumerator()) {
            $form.view.outputs.parameters.($binding.Key) |
                Should Be "[if(and(equals(steps('imageDest').imageDefinition.useExImageDef, false), not(equals(steps('imageDest').imageDefinition.securityType, 'ConfidentialVM'))), steps('imageDest').imageDefinition.$($binding.Value), false)]"
        }
    }
}
