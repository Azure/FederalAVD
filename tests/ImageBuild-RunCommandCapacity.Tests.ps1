$repoRoot = Split-Path -Parent $PSScriptRoot
$cleanupScriptPath = Join-Path $repoRoot 'deployments\imageBuild\scripts\Remove-ImageBuildRunCommands.ps1'
$batchModulePath = Join-Path $repoRoot 'deployments\imageBuild\modules\applyCustomizationsBatch.bicep'
$customizeModulePath = Join-Path $repoRoot 'deployments\imageBuild\modules\customizeImage.bicep'

Describe 'Image Build Run Command capacity protection' {
    AfterEach {
        Remove-Variable -Name ImageBuildTestImageRunCommands -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name ImageBuildTestOrchestrationRunCommands -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name ImageBuildTestDeletedUris -Scope Global -ErrorAction SilentlyContinue
    }

    It 'removes completed commands from both VMs but preserves its current command' {
        $global:ImageBuildTestImageRunCommands = @(
            [pscustomobject]@{ name = 'customization-one' }
            [pscustomobject]@{ name = 'customization-two' }
        )
        $global:ImageBuildTestOrchestrationRunCommands = @(
            [pscustomobject]@{ name = 'previous-restart' }
            [pscustomobject]@{ name = 'current-cleanup' }
        )
        $global:ImageBuildTestDeletedUris = @()

        Mock Invoke-RestMethod {
            param($Headers, $Method, $Uri)

            if ($Uri -like 'http://169.254.169.254/*') {
                return [pscustomobject]@{ access_token = 'test-token' }
            }

            if ($Method -eq 'GET' -and $Uri -match '/virtualMachines/image-vm/runCommands') {
                return [pscustomobject]@{ value = @($global:ImageBuildTestImageRunCommands) }
            }
            if ($Method -eq 'GET' -and $Uri -match '/virtualMachines/orchestration-vm/runCommands') {
                return [pscustomobject]@{ value = @($global:ImageBuildTestOrchestrationRunCommands) }
            }
            if ($Method -eq 'DELETE') {
                $global:ImageBuildTestDeletedUris += $Uri
                if ($Uri -match '/virtualMachines/image-vm/runCommands/([^?]+)') {
                    $name = $Matches[1]
                    $global:ImageBuildTestImageRunCommands = @($global:ImageBuildTestImageRunCommands | Where-Object { $_.name -ne $name })
                }
                elseif ($Uri -match '/virtualMachines/orchestration-vm/runCommands/([^?]+)') {
                    $name = $Matches[1]
                    $global:ImageBuildTestOrchestrationRunCommands = @($global:ImageBuildTestOrchestrationRunCommands | Where-Object { $_.name -ne $name })
                }
                return
            }

            throw "Unexpected REST request: $Method $Uri"
        }

        & $cleanupScriptPath `
            -ResourceManagerUri 'https://management.azure.com/' `
            -SubscriptionId '00000000-0000-0000-0000-000000000000' `
            -ImageBuildResourceGroup 'image-build-rg' `
            -ImageVmName 'image-vm' `
            -OrchestrationVmName 'orchestration-vm' `
            -CurrentRunCommandName 'current-cleanup'

        $global:ImageBuildTestDeletedUris.Count | Should Be 3
        ($global:ImageBuildTestDeletedUris -join "`n") | Should Match '/virtualMachines/image-vm/runCommands/customization-one\?'
        ($global:ImageBuildTestDeletedUris -join "`n") | Should Match '/virtualMachines/image-vm/runCommands/customization-two\?'
        ($global:ImageBuildTestDeletedUris -join "`n") | Should Match '/virtualMachines/orchestration-vm/runCommands/previous-restart\?'
        ($global:ImageBuildTestDeletedUris -join "`n") | Should Not Match '/runCommands/current-cleanup\?'
        @($global:ImageBuildTestOrchestrationRunCommands).Count | Should Be 1
        $global:ImageBuildTestOrchestrationRunCommands[0].name | Should Be 'current-cleanup'
    }

    It 'passes the active cleanup command name from every Bicep call site' {
        $batchModule = Get-Content -LiteralPath $batchModulePath -Raw
        $customizeModule = Get-Content -LiteralPath $customizeModulePath -Raw

        $batchModule | Should Match "name: 'CurrentRunCommandName'[\s\S]*?value: removeRunCommandName"
        $customizeModule | Should Match "name: 'CurrentRunCommandName'[\s\S]*?value: removeMicrosoftSoftwareRunCommandName"
    }

    It 'keeps customization batches below the Managed Run Command limit' {
        $customizeModule = Get-Content -LiteralPath $customizeModulePath -Raw
        $customizeModule | Should Match 'var customizationBatchSize = 20'
    }
}
