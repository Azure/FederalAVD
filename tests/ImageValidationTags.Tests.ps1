BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
}

Describe 'Image validation resource-type tags and deployment payload' {
    BeforeAll {
        $template = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\add-ons\imageValidation\main.json') -Raw | ConvertFrom-Json
        $vmTemplate = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\add-ons\imageValidation\modules\validationVirtualMachine.json') -Raw | ConvertFrom-Json
        $form = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\add-ons\imageValidation\uiFormDefinition.json') -Raw | ConvertFrom-Json
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $repoRoot 'deployments\add-ons\imageValidation\scripts\run.ps1'),
            [ref]$tokens, [ref]$parseErrors
        )
        if ($parseErrors.Count -gt 0) { throw 'Image validation timer has parse errors.' }
        $bodyAssignment = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -eq '$Body'
        }, $true)
        if (-not $bodyAssignment) { throw 'Image validation timer has no deployment body assignment.' }
    }

    It 'passes TagsByResource output and selects the VM tag object for runtime deployments' {
        $tagsSection = ($form.view.properties.steps | Where-Object name -eq 'namingAndTags').elements |
            Where-Object name -eq 'tagsSection'
        $control = $tagsSection.elements | Where-Object name -eq 'tags'
        $control.type | Should -Be 'Microsoft.Common.TagsByResource'
        ($control.resources -contains 'Microsoft.Compute/virtualMachines') | Should -Be $true
        $form.view.outputs.parameters.tags | Should -Be "[steps('namingAndTags').tagsSection.tags]"
        $template.resources.rg.tags | Should -Be "[coalesce(tryGet(parameters('tags'), 'Microsoft.Resources/resourceGroups'), createObject())]"
        $template.resources.networkInterface.properties.parameters.tags.value |
            Should -Be "[coalesce(tryGet(parameters('tags'), 'Microsoft.Network/networkInterfaces'), createObject())]"
        $template.resources.functionApp.properties.parameters.functionAppAppSettings.value |
            Should -Match "string\(coalesce\(tryGet\(parameters\('tags'\), 'Microsoft.Compute/virtualMachines'\), createObject\(\)\)\)"
        $vmTemplate.resources.virtualMachine.properties.parameters.tags.value | Should -Be "[parameters('tags')]"
    }

    It 'preserves <Name> tags, typed Boolean settings, and the VM template parameter contract' -TestCases @(
        @{ Name = 'empty'; Tags = '{}'; Enabled = 'False' }
        @{ Name = 'escaped'; Tags = '{"Environment":"Production","Notes":"Quotes: \" and path C:\\Temp","Empty":""}'; Enabled = 'True' }
    ) {
        param($Name, $Tags, $Enabled)
        $environment = @{
            tags = $Tags
            vmCustomizations = '[{"name":"Example","blobNameOrUri":"Example.zip","arguments":"-Mode Test","successExitCodes":"0,3010"}]'
            acceleratedNetworking = $Enabled
            bootDiagnostics = $Enabled
            encryptionAtHost = $Enabled
            integrityMonitoring = $Enabled
            secureBoot = $Enabled
            vTpm = $Enabled
            templateSpecResourceId = '/subscriptions/test/resourceGroups/validation/providers/Microsoft.Resources/templateSpecs/test/versions/1.0'
        }
        $originalEnvironment = @{}
        try {
            foreach ($key in $environment.Keys) {
                $originalEnvironment[$key] = [Environment]::GetEnvironmentVariable($key)
                [Environment]::SetEnvironmentVariable($key, $environment[$key])
            }
            $LatestComputeGalleryImageVersion = @{ id = '/subscriptions/test/versions/1.10.0' }
            Invoke-Expression $bodyAssignment.Extent.Text
            $payload = $Body | ConvertFrom-Json
            $parameters = $payload.properties.parameters
            ($parameters.PSObject.Properties.Name | Sort-Object) -join ',' |
                Should -Be (($vmTemplate.parameters.PSObject.Properties.Name | Sort-Object) -join ',')
            $parameters.tags.value | ConvertTo-Json -Compress | Should -Be (($Tags | ConvertFrom-Json) | ConvertTo-Json -Compress)
            foreach ($key in @('acceleratedNetworking', 'bootDiagnostics', 'encryptionAtHost', 'integrityMonitoring', 'secureBoot', 'vTpm')) {
                ($parameters.$key.value -is [bool]) | Should -Be $true
                $parameters.$key.value | Should -Be ([bool]::Parse($Enabled))
            }
            $parameters.vmCustomizations.value.Count | Should -Be 1
            $parameters.vmCustomizations.value[0].blobNameOrUri | Should -Be 'Example.zip'
            $parameters.vmCustomizations.value[0].successExitCodes | Should -Be '0,3010'
            $parameters.imageVersionResourceId.value | Should -Be $LatestComputeGalleryImageVersion.id
            $payload.properties.templateLink.id | Should -Be $env:templateSpecResourceId
        } finally {
            foreach ($key in $originalEnvironment.Keys) {
                [Environment]::SetEnvironmentVariable($key, $originalEnvironment[$key])
            }
        }
    }
}
