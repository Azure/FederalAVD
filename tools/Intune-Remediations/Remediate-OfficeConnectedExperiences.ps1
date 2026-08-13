#Requires -Version 5.1
<#
.SYNOPSIS
    Removes Intune ADMX-backed Office privacy registry values that block connected experiences.

.DESCRIPTION
    Deletes the four Office\16.0\Common\Privacy values from every loaded user hive
    (HKU\<SID>\...). Deleting the values returns control to Office defaults (allow).

    Must run as SYSTEM. The Policy CSP sets a restrictive DACL on HKCU\Software\Policies\
    keys (owner: SYSTEM, user gets Read-only), so user-context scripts receive
    Access Denied when attempting to delete those values. SYSTEM retains Full Control
    and can delete regardless of the user-facing DACL.

    Intune does not clean up these values when a Settings Catalog profile removes a
    user-scoped ADMX-backed setting, so this remediation handles the cleanup.

.NOTES
    Run context : SYSTEM
    Registry key: HKU\<SID>\Software\Policies\Microsoft\Office\16.0\Common\Privacy

    Pair with Detect-OfficeConnectedExperiences.ps1 as an Intune remediation.
#>

$RelativeKey = 'Software\Policies\Microsoft\Office\16.0\Common\Privacy'

$Values = @(
    'disconnectedstate',                   # Allow connected experiences in Office
    'usercontentdisabled',                 # Allow experiences that analyze content
    'downloadcontentdisabled',             # Allow experiences that download content
    'controllerconnectedservicesenabled'   # Allow additional optional connected experiences
)

# Enumerate loaded user hives. S-1-5-21-* are real user SIDs; exclude _Classes sub-hives.
$UserSids = Get-ChildItem -Path 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match '^S-1-5-21-' -and $_.PSChildName -notmatch '_Classes$' } |
    Select-Object -ExpandProperty PSChildName

if ($UserSids.Count -eq 0) {
    Write-Output 'No user hives loaded - nothing to remediate.'
    exit 0
}

$Errors = @()

foreach ($Sid in $UserSids) {
    $KeyPath = "Registry::HKEY_USERS\$Sid\$RelativeKey"
    if (-not (Test-Path -Path $KeyPath)) { continue }

    foreach ($ValueName in $Values) {
        $current = Get-ItemProperty -Path $KeyPath -Name $ValueName -ErrorAction SilentlyContinue
        if ($null -eq $current) { continue }

        try {
            Remove-ItemProperty -Path $KeyPath -Name $ValueName -Force -ErrorAction Stop
            Write-Output "[$Sid] Removed: $ValueName"
        }
        catch {
            $Errors += "[$Sid] Failed to remove $ValueName - $($_.Exception.Message)"
        }
    }

    # Remove the key itself if it is now empty
    $remaining = Get-Item -Path $KeyPath -ErrorAction SilentlyContinue
    if ($null -ne $remaining -and $remaining.ValueCount -eq 0) {
        try {
            Remove-Item -Path $KeyPath -Force -ErrorAction Stop
            Write-Output "[$Sid] Removed empty registry key."
        }
        catch {
            # Non-fatal - key may have other values this script does not own
            Write-Output "[$Sid] Note: key not removed (may have other values) - $($_.Exception.Message)"
        }
    }
}

if ($Errors.Count -gt 0) {
    Write-Error ($Errors -join '; ')
    exit 1
}

Write-Output 'Remediation complete. Office connected experience policy values removed.'
exit 0
