param(
    [securestring]
    [Parameter(Mandatory = $true)]
    [string] $ScriptB64
)

$ErrorActionPreference = 'Stop'

# Decode the base64-encoded script
$bytes = [Convert]::FromBase64String($ScriptB64)
$script = [Text.Encoding]::UTF8.GetString($bytes)

# Normalize line endings (optional but safe)
$script = $script -replace "`r`n", "`n" -replace "`r", "`n"

# Execute
$sb = [ScriptBlock]::Create($script)
try {
    Write-Host "----- Begin user script output -----"
    & $sb
    $exitCode = if ($LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    Write-Host "----- End user script output -----"
    exit $exitCode
}
catch {
    Write-Error ("User script threw: " + $_.Exception.Message)
    Write-Error $_.Exception | Format-List * -Force
    exit 1
}