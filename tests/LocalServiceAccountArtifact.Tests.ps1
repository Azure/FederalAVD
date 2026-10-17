$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$artifactPath = Join-Path $repoRoot 'customer-examples\artifacts\Configure-LocalServiceAccount'
$scriptPath = Join-Path $artifactPath 'Configure-LocalServiceAccount.ps1'
$readmePath = Join-Path $artifactPath 'README.md'
$scriptContent = Get-Content -LiteralPath $scriptPath -Raw
$tokens = $null
$parseErrors = $null
$scriptAst = [Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)

Describe 'Configure Local Service Account artifact' {
    It 'contains one root script and a README' {
        @(Get-ChildItem -LiteralPath $artifactPath -Filter '*.ps1' -File).Count | Should Be 1
        Test-Path -LiteralPath $readmePath | Should Be $true
    }

    It 'parses and contains only ASCII characters' {
        @($parseErrors).Count | Should Be 0
        @(Get-Content -LiteralPath $scriptPath | Where-Object { $_ -match '[^\x00-\x7E]' }).Count | Should Be 0
    }

    It 'accepts only the intended configuration parameters' {
        $parameterNames = @($scriptAst.ParamBlock.Parameters | ForEach-Object {
            $_.Name.VariablePath.UserPath
        })

        ($parameterNames -join ',') | Should Be 'AccountName,KeyVaultUri,SecretName,UserAssignedIdentityClientId,LocalGroups,Description'
    }

    It 'retrieves the password from Key Vault without logging it' {
        $scriptContent | Should Match 'metadata/identity/oauth2/token'
        $scriptContent | Should Match '/secrets/\$SecretName\?api-version=2025-07-01'
        $scriptContent | Should Match 'ConvertTo-SecureString'
        $scriptContent | Should Not Match 'Write-(Output|Host).*secretResponse\.value'
    }

    It 'creates or updates the account and accepts requested groups directly' {
        $scriptContent | Should Match 'New-LocalUser'
        $scriptContent | Should Match 'Set-LocalUser'
        $scriptContent | Should Match 'Add-LocalGroupMember'
        $scriptContent | Should Not Match 'AllowAdministratorsGroup|AllowSharedSecret|SecretNamePattern'
    }
}