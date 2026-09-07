$repoRoot = Split-Path -Parent $PSScriptRoot
$formPath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\uiFormDefinition.json'

Describe 'Session Host Replacer shutdown retention form behavior' {
    BeforeAll {
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $configStep = $form.view.properties.steps | Where-Object { $_.name -eq 'replacerConfig' }
        $replacementMode = $configStep.elements | Where-Object { $_.name -eq 'replacementMode' }
        $shutdownRetentionHeader = $configStep.elements | Where-Object { $_.name -eq 'shutdownRetentionHeader' }
        $shutdownRetentionInfoBox = $configStep.elements | Where-Object { $_.name -eq 'shutdownRetentionInfoBox' }
        $enableShutdownRetention = $configStep.elements | Where-Object { $_.name -eq 'enableShutdownRetention' }
        $shutdownRetentionDays = $configStep.elements | Where-Object { $_.name -eq 'shutdownRetentionDays' }
        $tagShutdownTimestamp = $configStep.elements | Where-Object { $_.name -eq 'tagShutdownTimestamp' }
        $outputs = $form.view.outputs.parameters
    }

    It 'uses the Side-by-Side display label as the dropdown default' {
        $replacementMode.defaultValue | Should Be 'Side-by-Side (Add then Delete)'
        ($replacementMode.constraints.allowedValues | Where-Object { $_.label -eq $replacementMode.defaultValue }).value | Should Be 'SideBySide'
    }

    It 'shows shutdown retention controls only in Side-by-Side mode' {
        $sideBySideVisibility = "[equals(steps('replacerConfig').replacementMode, 'SideBySide')]"
        $shutdownRetentionHeader.visible | Should Be $sideBySideVisibility
        $shutdownRetentionInfoBox.visible | Should Be $sideBySideVisibility
        $enableShutdownRetention.visible | Should Be $sideBySideVisibility
        $shutdownRetentionDays.visible | Should Be "[and(equals(steps('replacerConfig').replacementMode, 'SideBySide'), steps('replacerConfig').enableShutdownRetention)]"
        $tagShutdownTimestamp.visible | Should Be "[and(equals(steps('replacerConfig').replacementMode, 'SideBySide'), steps('replacerConfig').enableShutdownRetention)]"
    }

    It 'disables shutdown retention in outputs for Delete-First mode' {
        $outputs.enableShutdownRetention | Should Be "[if(equals(steps('replacerConfig').replacementMode, 'SideBySide'), steps('replacerConfig').enableShutdownRetention, false)]"
        $outputs.shutdownRetentionDays | Should Be "[if(and(equals(steps('replacerConfig').replacementMode, 'SideBySide'), steps('replacerConfig').enableShutdownRetention), steps('replacerConfig').shutdownRetentionDays, 3)]"
        $outputs.tagShutdownTimestamp | Should Be "[if(and(equals(steps('replacerConfig').replacementMode, 'SideBySide'), steps('replacerConfig').enableShutdownRetention), steps('replacerConfig').tagShutdownTimestamp, 'AutoReplaceShutdownTimestamp')]"
    }
}