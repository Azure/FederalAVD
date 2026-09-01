$repoRoot = Split-Path -Parent $PSScriptRoot
$formPath = Join-Path $repoRoot 'deployments\automatedHostPools\uiFormDefinition.json'
$armPath = Join-Path $repoRoot 'deployments\automatedHostPools\automatedHostPool.json'

Describe 'Automated host-pool VM name prefix validation' {
    BeforeAll {
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $arm = Get-Content -LiteralPath $armPath -Raw | ConvertFrom-Json
        $hostsStep = $form.view.properties.steps | Where-Object { $_.name -eq 'hosts' }
        $hostDetails = $hostsStep.elements | Where-Object { $_.name -eq 'hostDetails' }
        $prefix = $hostDetails.elements | Where-Object { $_.name -eq 'virtualMachineNamePrefix' }
    }

    It 'limits direct deployments to 10 characters' {
        $arm.parameters.virtualMachineNamePrefix.maxLength | Should Be 10
        $arm.parameters.virtualMachineNamePrefix.metadata.description | Should Match 'Maximum 10 characters'
    }

    It 'limits Form View input to 10 valid characters' {
        $lengthValidation = $prefix.constraints.validations | Where-Object { $_.isValid }
        $regexValidation = $prefix.constraints.validations | Where-Object { $_.regex }

        $lengthValidation.isValid | Should Be "[lessOrEquals(length(steps('hosts').hostDetails.virtualMachineNamePrefix), 10)]"
        $lengthValidation.message | Should Match 'cannot exceed 10 characters'
        $regexValidation.regex | Should Be '^(?!-)(?![0-9]+$)[A-Za-z0-9-]+$'
    }
}