#requires -Version 5.1

function Get-FavoritesBackupRoot {
    param([string]$ConfiguredPath)
    if (-not [string]::IsNullOrWhiteSpace($ConfiguredPath)) {
        $root = [Environment]::ExpandEnvironmentVariables($ConfiguredPath)
        if ($root -match '%[^%]+%' -or $root -notmatch '^(?:[A-Za-z]:\\|\\\\[^\\]+\\[^\\]+(?:\\|$))') {
            throw 'BackupRoot must expand to an absolute, existing per-user directory.'
        }
    }
    else {
        $root = $env:OneDriveCommercial
        if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root -PathType Container)) {
            $accounts = 'HKCU:\Software\Microsoft\OneDrive\Accounts'
            $roots = @(if (Test-Path -LiteralPath $accounts) {
                Get-ChildItem -LiteralPath $accounts -ErrorAction Stop |
                    Where-Object { $_.PSChildName -like 'Business*' } |
                    ForEach-Object { (Get-ItemProperty -LiteralPath $_.PSPath -Name UserFolder -ErrorAction Stop).UserFolder } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    Select-Object -Unique
            })
            if ($roots.Count -ne 1) {
                throw 'No unambiguous business OneDrive root is available. Configure BackupRoot or retry after OneDrive setup.'
            }
            $root = $roots[0]
        }
    }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw 'The backup root is unavailable. It will not be created automatically.'
    }
    return [IO.Path]::GetFullPath($root)
}
