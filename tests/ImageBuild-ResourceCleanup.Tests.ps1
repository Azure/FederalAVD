$repoRoot = Split-Path -Parent $PSScriptRoot
$cleanupScriptPath = Join-Path $repoRoot 'deployments\imageBuild\scripts\Remove-ImageBuildResources.ps1'

Describe 'Image Build resource cleanup' {
    BeforeEach {
        $global:ImageBuildCleanupDeletedUris = @()
        $global:ImageBuildCleanupSleepSeconds = @()

        Mock Start-Sleep {
            param($Seconds)
            $global:ImageBuildCleanupSleepSeconds += $Seconds
        }
        Mock Invoke-RestMethod {
            param($Headers, $Method, $Uri)

            if ($Uri -like 'http://169.254.169.254/*') {
                return [pscustomobject]@{ access_token = 'test-token' }
            }
            if ($Method -eq 'DELETE') {
                $global:ImageBuildCleanupDeletedUris += $Uri
                return
            }

            throw "Unexpected REST request: $Method $Uri"
        }
    }

    AfterEach {
        Remove-Variable -Name ImageBuildCleanupDeletedUris -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name ImageBuildCleanupSleepSeconds -Scope Global -ErrorAction SilentlyContinue
    }

    It 'waits before deleting a deployment-created resource group' {
        & $cleanupScriptPath `
            -ResourceManagerUri 'https://management.azure.com/' `
            -ImageVmResourceId '/subscriptions/test/resourceGroups/test/providers/Microsoft.Compute/virtualMachines/image-vm' `
            -ManagementVmResourceId '/subscriptions/test/resourceGroups/test/providers/Microsoft.Compute/virtualMachines/management-vm' `
            -ResourceGroupId '/subscriptions/test/resourceGroups/test'

        $global:ImageBuildCleanupDeletedUris.Count | Should Be 1
        $global:ImageBuildCleanupDeletedUris[0] | Should Match '/subscriptions/test/resourceGroups/test\?api-version=2021-04-01$'
        $global:ImageBuildCleanupSleepSeconds.Count | Should Be 1
        $global:ImageBuildCleanupSleepSeconds[0] | Should BeGreaterThan 29
        $global:ImageBuildCleanupSleepSeconds[0] | Should BeLessThan 31
    }

    It 'waits before deleting the management VM when reusing a resource group' {
        & $cleanupScriptPath `
            -ResourceManagerUri 'https://management.azure.com/' `
            -UserAssignedIdentityClientId '00000000-0000-0000-0000-000000000000' `
            -ImageVmResourceId '/subscriptions/test/resourceGroups/test/providers/Microsoft.Compute/virtualMachines/image-vm' `
            -ManagementVmResourceId '/subscriptions/test/resourceGroups/test/providers/Microsoft.Compute/virtualMachines/management-vm' `
            -ImageResourceId '/subscriptions/test/resourceGroups/test/providers/Microsoft.Compute/images/image'

        $global:ImageBuildCleanupDeletedUris.Count | Should Be 3
        ($global:ImageBuildCleanupDeletedUris -join "`n") | Should Match '/virtualMachines/image-vm\?api-version=2024-03-01'
        ($global:ImageBuildCleanupDeletedUris -join "`n") | Should Match '/images/image\?api-version=2024-03-01'
        ($global:ImageBuildCleanupDeletedUris -join "`n") | Should Match '/virtualMachines/management-vm\?forceDeletion=true&api-version=2024-03-01'
        $global:ImageBuildCleanupSleepSeconds.Count | Should Be 1
        $global:ImageBuildCleanupSleepSeconds[0] | Should BeGreaterThan 29
        $global:ImageBuildCleanupSleepSeconds[0] | Should BeLessThan 31
    }

    It 'keeps deletion idempotent and removes obsolete cleanup mechanisms' {
        $content = Get-Content -LiteralPath $cleanupScriptPath -Raw

        $content | Should Match '\$StatusCode -ne 404'
        $content | Should Not Match 'Register-ScheduledTask|DeferredConfigPath|\$RunCommandUri|\$ArmConfirmed'
    }

    It 'remains ASCII-only for ARM script embedding' {
        $characters = [System.IO.File]::ReadAllText($cleanupScriptPath).ToCharArray()
        @($characters | Where-Object { [int]$_ -gt 127 }).Count | Should Be 0
    }
}
