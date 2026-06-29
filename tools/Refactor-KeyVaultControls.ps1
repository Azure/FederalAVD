# Refactor-KeyVaultControls.ps1
# Moves Key Vault controls from Operations & Monitoring to Identity (secrets KV)
# and Zero Trust > keyManagement (encryption KV). Removes the Key Vaults section
# from Operations & Monitoring entirely.

$f = 'C:\repos\FederalAVD\deployments\hostpools\uiFormDefinition.json'
$c = [System.IO.File]::ReadAllText($f)
$nl = "`r`n"
$t5  = "`t" * 5
$t6  = "`t" * 6
$t7  = "`t" * 7
$t8  = "`t" * 8
$t9  = "`t" * 9
$t10 = "`t" * 10
$t11 = "`t" * 11
$t12 = "`t`t`t`t`t`t`t`t`t`t`t`t"

Write-Host "File loaded: $($c.Length) chars"

# -----------------------------------------------------------------------------
# PHASE 1  Global path renames
# -----------------------------------------------------------------------------
$globalRenames = @(
    ,@("steps('operationsAndMonitoring').keyVaults.deploySecretsKeyVault",
       "steps('identity').credentials.deploySecretsKeyVault")
    ,@("steps('operationsAndMonitoring').keyVaults.useExistingEncryptionKv",
       "steps('zeroTrust').keyManagement.useExistingEncryptionKv")
    ,@("steps('operationsAndMonitoring').keyVaults.existingEncryptionKeyVault",
       "steps('zeroTrust').keyManagement.existingEncryptionKeyVault")
    ,@("steps('operationsAndMonitoring').keyVaults.keyExpirationInDays",
       "steps('zeroTrust').keyManagement.keyExpirationInDays")
    ,@("steps('operationsAndMonitoring').keyVaults.enableSoftDelete",
       "steps('identity').credentials.enableSoftDelete")
    ,@("steps('operationsAndMonitoring').keyVaults.enablePurgeProtection",
       "steps('identity').credentials.enablePurgeProtection")
)
foreach ($p in $globalRenames) {
    $n = ([regex]::Matches($c,[regex]::Escape($p[0]))).Count
    if ($n -eq 0) { Write-Warning "NOT FOUND: $($p[0])" }
    else { $c = $c.Replace($p[0],$p[1]); Write-Host "Phase1 ${n}x: $($p[0])" }
}

# -----------------------------------------------------------------------------
# PHASE 2  Insert secrets KV controls into Identity > Credentials
#          Inserted after the keyVault ResourceSelector element,
#          before the closing ] of credentials.elements
# -----------------------------------------------------------------------------
$newSecretsKvControls = @"
,${nl}${t8}{${nl}${t9}"name": "deploySecretsKeyVault",${nl}${t9}"type": "Microsoft.Common.CheckBox",${nl}${t9}"label": "Deploy VM Secrets Key Vault",${nl}${t9}"toolTip": "Deploy a Key Vault and store VM admin credentials (and domain join credentials if applicable) as secrets. Required when using this deployment's templates with ARM getSecret() references.",${nl}${t9}"visible": "[equals(steps('identity').credentials.source, 'manual')]"${nl}${t8}},${nl}${t8}{${nl}${t9}"name": "enableSoftDelete",${nl}${t9}"type": "Microsoft.Common.CheckBox",${nl}${t9}"label": "Enable Soft Delete on Secrets Key Vault",${nl}${t9}"defaultValue": true,${nl}${t9}"toolTip": "Allow recovery of deleted Key Vault objects within the retention period.",${nl}${t9}"visible": "[and(equals(steps('identity').credentials.source, 'manual'), steps('identity').credentials.deploySecretsKeyVault)]"${nl}${t8}},${nl}${t8}{${nl}${t9}"name": "enablePurgeProtection",${nl}${t9}"type": "Microsoft.Common.CheckBox",${nl}${t9}"label": "Enable Purge Protection on Secrets Key Vault",${nl}${t9}"defaultValue": true,${nl}${t9}"toolTip": "Prevent permanent deletion of the Key Vault and its objects during the retention period. Requires soft delete to be enabled.",${nl}${t9}"visible": "[and(equals(steps('identity').credentials.source, 'manual'), steps('identity').credentials.deploySecretsKeyVault, steps('identity').credentials.enableSoftDelete)]"${nl}${t8}},${nl}${t8}{${nl}${t9}"name": "secretsKvRetentionInDays",${nl}${t9}"type": "Microsoft.Common.Slider",${nl}${t9}"label": "Secrets Key Vault Soft Delete Retention (Days)",${nl}${t9}"defaultValue": 90,${nl}${t9}"showStepMarkers": false,${nl}${t9}"toolTip": "Number of days the Secrets Key Vault and its objects are retained after deletion before permanent removal.",${nl}${t9}"min": 7,${nl}${t9}"max": 90,${nl}${t9}"visible": "[and(equals(steps('identity').credentials.source, 'manual'), steps('identity').credentials.deploySecretsKeyVault)]"${nl}${t8}}
"@

# The keyVault ResourceSelector is the last element in credentials.elements.
# Replace its closing } (no comma) followed by the array/section close.
$credAnchorOld = @"
									"visible": "[equals(steps('identity').credentials.source, 'keyVault')]"
								}
							]
						}
					]
				},
				{
					"name": "controlPlane",
"@

$credAnchorNew = @"
									"visible": "[equals(steps('identity').credentials.source, 'keyVault')]"
								}$($newSecretsKvControls.TrimEnd())
							]
						}
					]
				},
				{
					"name": "controlPlane",
"@

if ($c.IndexOf($credAnchorOld) -lt 0) { Write-Error "Phase2: credentials anchor not found"; exit 1 }
$c = $c.Replace($credAnchorOld, $credAnchorNew)
Write-Host "Phase2: Inserted secrets KV controls into Identity > Credentials"

# -----------------------------------------------------------------------------
# PHASE 3  Insert encryption KV controls into Zero Trust > keyManagement
#          Inserted after keyManagementRecoveryServicesVault (last element),
#          before the closing ] of keyManagement.elements
# -----------------------------------------------------------------------------
$cmkOr = "or(contains(steps('zeroTrust').keyManagement.keyManagementDisks, 'CustomerManaged'), contains(steps('zeroTrust').keyManagement.keyManagementStorage, 'CustomerManaged'), contains(steps('zeroTrust').keyManagement.keyManagementRecoveryServicesVault, 'CustomerManaged'))"

$newEncKvControls = "${nl}${t8}{${nl}${t9}`"name`": `"useExistingEncryptionKv`",${nl}${t9}`"type`": `"Microsoft.Common.CheckBox`",${nl}${t9}`"label`": `"Use Existing Encryption Key Vault`",${nl}${t9}`"defaultValue`": false,${nl}${t9}`"toolTip`": `"Check to select an existing Encryption Key Vault (e.g., from the Security deployment) instead of creating one inline in the operations resource group.`",${nl}${t9}`"visible`": `"[$cmkOr]`"${nl}${t8}},${nl}${t8}{${nl}${t9}`"name`": `"existingEncryptionKeyVault`",${nl}${t9}`"type`": `"Microsoft.Solutions.ResourceSelector`",${nl}${t9}`"label`": `"Existing Encryption Key Vault`",${nl}${t9}`"resourceType`": `"Microsoft.KeyVault/vaults`",${nl}${t9}`"toolTip`": `"Select an existing Key Vault to use for Customer Managed Keys. Only key vaults in the session host location are shown.`",${nl}${t9}`"constraints`": {${nl}${t10}`"required`": `"[steps('zeroTrust').keyManagement.useExistingEncryptionKv]`"${nl}${t9}},${nl}${t9}`"scope`": {${nl}${t10}`"subscriptionId`": `"[steps('hosts').scope.subscription.subscriptionId]`",${nl}${t10}`"location`": `"[steps('hosts').scope.location.name]`"${nl}${t9}},${nl}${t9}`"visible`": `"[and(steps('zeroTrust').keyManagement.useExistingEncryptionKv, $cmkOr)]`"${nl}${t8}},${nl}${t8}{${nl}${t9}`"name`": `"keyExpirationInDays`",${nl}${t9}`"type`": `"Microsoft.Common.Slider`",${nl}${t9}`"label`": `"Encryption Key Rotation (in Days)`",${nl}${t9}`"defaultValue`": 180,${nl}${t9}`"showStepMarkers`": false,${nl}${t9}`"toolTip`": `"The number of days before a new key version is automatically generated in the Azure Key Vault.`",${nl}${t9}`"min`": 30,${nl}${t9}`"max`": 180,${nl}${t9}`"visible`": `"[$cmkOr]`"${nl}${t8}},${nl}${t8}{${nl}${t9}`"name`": `"encKvRetentionInDays`",${nl}${t9}`"type`": `"Microsoft.Common.Slider`",${nl}${t9}`"label`": `"Encryption Key Vault Soft Delete Retention (Days)`",${nl}${t9}`"defaultValue`": 90,${nl}${t9}`"showStepMarkers`": false,${nl}${t9}`"toolTip`": `"Number of days the Encryption Key Vault and its objects are retained after deletion before permanent removal.`",${nl}${t9}`"min`": 7,${nl}${t9}`"max`": 90,${nl}${t9}`"visible`": `"[and($cmkOr, not(steps('zeroTrust').keyManagement.useExistingEncryptionKv))]`"${nl}${t8}}"

# Hex-verified exact closing sequence of keyManagementRecoveryServicesVault:
#   "CustomerManagedHSM"  (12 tabs for "value")
#   CRLF + 11 tabs }      (closes last allowedValue item)
#   CRLF + 10 tabs ]      (closes allowedValues array)
#   CRLF +  9 tabs }      (closes constraints)
#   CRLF +  8 tabs }      (closes keyManagementRecoveryServicesVault element)  ? insert comma + new elements here
#   CRLF +  7 tabs ]      (closes keyManagement.elements array)
#   CRLF +  6 tabs },     (closes keyManagement section)
# Build the anchor using concatenation (verified to match the file bytes)
$crlf = "`r`n"
$phase3Old = 'CustomerManagedHSM"' + $crlf + ("`t"*11) + "}" + $crlf + ("`t"*10) + "]" + $crlf + ("`t"*9) + "}" + $crlf + ("`t"*8) + "}" + $crlf + ("`t"*7) + "]" + $crlf + ("`t"*6) + "},"
$phase3New = 'CustomerManagedHSM"' + $crlf + ("`t"*11) + "}" + $crlf + ("`t"*10) + "]" + $crlf + ("`t"*9) + "}" + $crlf + ("`t"*8) + "}," + $newEncKvControls + $crlf + ("`t"*7) + "]" + $crlf + ("`t"*6) + "},"

# Verify it's unique to keyManagementRecoveryServicesVault
$phase3Count = ([regex]::Matches($c,[regex]::Escape($phase3Old))).Count
if ($phase3Count -eq 0) { Write-Error "Phase3: anchor not found"; exit 1 }
if ($phase3Count -gt 1) { Write-Warning "Phase3: $phase3Count matches - expected 1" }
$c = $c.Replace($phase3Old, $phase3New)
Write-Host "Phase3: Inserted encryption KV controls into Zero Trust > keyManagement (${phase3Count} match)"

# -----------------------------------------------------------------------------
# PHASE 4  Remove the entire Key Vaults section from Operations & Monitoring
# -----------------------------------------------------------------------------
# The section starts at: (5 tabs){ (6 tabs)"name": "keyVaults",
# and ends at the }, before: (5 tabs){ (6 tabs)"name": "monitoring",
$t5 = "`t`t`t`t`t"
$t6 = "`t`t`t`t`t`t"

$kvSectionStart = "`r`n" + ("`t"*5) + "{" + "`r`n" + ("`t"*7) + '"name": "keyVaults",'
$monitoringStart = "`r`n" + ("`t"*5) + "{" + "`r`n" + ("`t"*7) + '"name": "monitoring",'

# Debug: verify anchors against current in-memory content
$testKv  = $c.IndexOf($kvSectionStart)
$testMon = $c.IndexOf($monitoringStart)
Write-Host "Phase4 debug: kvIdx=$testKv  monIdx=$testMon"
if ($testKv -lt 0) {
    # Try to locate keyVaults name to understand actual context
    $kvNameIdx = $c.IndexOf('"name": "keyVaults"')
    Write-Host "  keyVaults name at: $kvNameIdx"
    if ($kvNameIdx -ge 0) {
        $preBytes = [System.Text.Encoding]::UTF8.GetBytes($c.Substring($kvNameIdx-25,30))
        Write-Host "  Bytes -25 to +5: $($preBytes | ForEach-Object { $_.ToString('X2') })"
        # Also test partial anchor
        $partial = "`r`n" + ("`t"*5) + "{"
        $pidx = $c.IndexOf($partial, $kvNameIdx-30)
        Write-Host "  CRLF+5t+{ near keyVaults: $pidx (nameIdx=$kvNameIdx)"
    }
}

$kvIdx    = $c.IndexOf($kvSectionStart)
$monIdx   = $c.IndexOf($monitoringStart)
if ($kvIdx -lt 0)  { Write-Error "Phase4: keyVaults section start not found"; exit 1 }
if ($monIdx -lt 0) { Write-Error "Phase4: monitoring section start not found"; exit 1 }
if ($monIdx -le $kvIdx) { Write-Error "Phase4: monitoring section not after keyVaults"; exit 1 }

# Everything from kvIdx up to (not including) monIdx is removed
$removed = $c.Substring($kvIdx, $monIdx - $kvIdx)
Write-Host "Phase4: Removing Key Vaults section ($($removed.Length) chars)"
$c = $c.Substring(0, $kvIdx) + $c.Substring($monIdx)
Write-Host "Phase4: Key Vaults section removed"

# -----------------------------------------------------------------------------
# PHASE 5  Update keyVaultRetentionInDays output line specifically
# -----------------------------------------------------------------------------
$oldRetentionOutput = @'
			"keyVaultRetentionInDays": "[if(or(steps('identity').credentials.deploySecretsKeyVault, and(or(contains(steps('zeroTrust').keyManagement.keyManagementDisks, 'CustomerManaged'), contains(steps('zeroTrust').keyManagement.keyManagementStorage, 'CustomerManaged'), contains(steps('zeroTrust').keyManagement.keyManagementRecoveryServicesVault, 'CustomerManaged')), not(steps('zeroTrust').keyManagement.useExistingEncryptionKv))), steps('operationsAndMonitoring').keyVaults.keyVaultRetentionInDays, 7)]",
'@

$newRetentionOutput = @'
			"keyVaultRetentionInDays": "[if(and(or(contains(steps('zeroTrust').keyManagement.keyManagementDisks, 'CustomerManaged'), contains(steps('zeroTrust').keyManagement.keyManagementStorage, 'CustomerManaged'), contains(steps('zeroTrust').keyManagement.keyManagementRecoveryServicesVault, 'CustomerManaged')), not(steps('zeroTrust').keyManagement.useExistingEncryptionKv)), steps('zeroTrust').keyManagement.encKvRetentionInDays, if(steps('identity').credentials.deploySecretsKeyVault, steps('identity').credentials.secretsKvRetentionInDays, 90))]",
'@

if ($c.IndexOf($oldRetentionOutput.Trim()) -lt 0) { Write-Error "Phase5: keyVaultRetentionInDays output not found"; exit 1 }
$c = $c.Replace($oldRetentionOutput.Trim(), $newRetentionOutput.Trim())
Write-Host "Phase5: Updated keyVaultRetentionInDays output expression"

# -----------------------------------------------------------------------------
# PHASE 6  Validate and write
# -----------------------------------------------------------------------------
try {
    $null = $c | ConvertFrom-Json
    Write-Host "JSON: VALID"
} catch {
    Write-Error "JSON INVALID: $_"
    exit 1
}

[System.IO.File]::WriteAllText($f, $c)
Write-Host "Written: $($c.Length) chars"

# Quick verification
$checks = @(
    @("deploySecretsKeyVault in Identity", "steps('identity').credentials.deploySecretsKeyVault"),
    @("useExistingEncryptionKv in ZeroTrust", "steps('zeroTrust').keyManagement.useExistingEncryptionKv"),
    @("encKvRetentionInDays slider", '"name": "encKvRetentionInDays"'),
    @("secretsKvRetentionInDays slider", '"name": "secretsKvRetentionInDays"'),
    @("keyExpirationInDays in keyManagement", '"name": "keyExpirationInDays"'),
    @("No orphan keyVaults refs", "operationsAndMonitoring').keyVaults.")
)
foreach ($chk in $checks) {
    $found = $c.IndexOf($chk[1]) -ge 0
    if ($chk[0] -like "No orphan*") {
        if ($found) { Write-Warning "ORPHAN REFERENCE REMAINS: $($chk[1])" } else { Write-Host "  OK - $($chk[0])" }
    } else {
        if ($found) { Write-Host "  OK - $($chk[0])" } else { Write-Warning "MISSING: $($chk[0])" }
    }
}
