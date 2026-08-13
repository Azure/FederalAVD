#Requires -Version 5.1
<#
.SYNOPSIS
    Detects whether Intune ADMX-backed Office privacy policies are blocking connected experiences.

.DESCRIPTION
    Checks the Office privacy registry key for the four connected-experience values across
    all loaded user hives (HKU\<SID>\...). A value of 2 means the policy is actively
    blocking the experience.

    Must run as SYSTEM. The Policy CSP sets a restrictive DACL on HKCU\Software\Policies\
    keys (owner: SYSTEM, user gets Read-only), so user-context scripts receive Access
    Denied when attempting to read or delete those values.

.NOTES
    Run context : SYSTEM
    Source      : office16.admx, class="User"
    Registry key: HKU\<SID>\Software\Policies\Microsoft\Office\16.0\Common\Privacy

    Value scheme (all four settings use the same encoding):
        1 = Allow (policy enabled  - connected experience is on)
        2 = Block (policy disabled - connected experience is off)
        absent = Not Configured (Office default - typically on)
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
    Write-Output 'Compliant: no user hives loaded.'
    exit 0
}

$BlockingEntries = @()

foreach ($Sid in $UserSids) {
    $KeyPath = "Registry::HKEY_USERS\$Sid\$RelativeKey"
    if (-not (Test-Path -Path $KeyPath)) { continue }

    foreach ($ValueName in $Values) {
        $current = Get-ItemProperty -Path $KeyPath -Name $ValueName -ErrorAction SilentlyContinue
        if ($null -ne $current -and $current.$ValueName -eq 2) {
            $BlockingEntries += "$Sid : $ValueName"
        }
    }
}

if ($BlockingEntries.Count -gt 0) {
    Write-Output "Non-compliant: $($BlockingEntries -join '; ')"
    exit 1
}

Write-Output 'Compliant: no Office connected experience values are set to Block.'
exit 0
