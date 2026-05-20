
<#
.SYNOPSIS
  Moves variables in hostpool.bicep that depend on naming convention vars to a
  "Derived Variables" section immediately after the naming block, so the file
  reads top-to-bottom without forward references.

  Blocks moved AFTER the naming block:
    A  diskEncryptionSetName
    B  fslLocalStorageAccountNames … fslogixConfigurationTags
    C  vmIntuneEnrollment … vmConfigurationTags
    D  fslogixFileShareNames + fslogixStorageCount
    E  hostsResourceGroupIdTag + storageResourceGroupIdTag
#>

$file = 'c:\repos\FederalAVD\deployments\hostpools\hostpool.bicep'
$lines = [System.IO.File]::ReadAllLines($file)
$n = $lines.Count

# ── helpers ────────────────────────────────────────────────────────────────────
function Find-Line ([string]$pattern, [int]$after = 0) {
  for ($i = $after; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match $pattern) { return $i }
  }
  throw "Pattern not found: $pattern"
}

# Return the last non-blank 0-based index strictly before $beforeIdx
function Last-NonBlank ([int]$beforeIdx) {
  $j = $beforeIdx - 1
  while ($j -ge 0 -and $lines[$j].Trim() -eq '') { $j-- }
  return $j
}

# ── locate block boundaries ────────────────────────────────────────────────────
# Each block: [start, end] inclusive (0-based)

# Block A: diskEncryptionSetName — ends just before "// NOTE: the name formula"
$aStart      = Find-Line '^var diskEncryptionSetName = confidentialVMOSDiskEncryption'
$bStart      = Find-Line '^// NOTE: the name formula below'
$aEnd        = Last-NonBlank $bStart

# Block B: fslLocalStorageAccountNames … fslogixConfigurationTags
# ends just before "var vmIntuneEnrollment"
$cStart      = Find-Line '^var vmIntuneEnrollment = '
$bEnd        = Last-NonBlank $cStart

# Block C: vmIntuneEnrollment … vmConfigurationTags
# ends just before "var scalingPlanSchedules"
$scalingLine = Find-Line '^var scalingPlanSchedules = deployScalingPlan'
$cEnd        = Last-NonBlank $scalingLine

# Block D: fslogixFileShareNames + fslogixStorageCount (two adjacent lines)
$dStart      = Find-Line '^var fslogixFileShareNames = fslogixShareNamesLookup'
$dEnd        = Find-Line '^var fslogixStorageCount = '

# Block E: // Custom Tags for Host Pool … storageResourceGroupIdTag
# ends just before "// Existing Session Host Virtual Network"
$eStart      = Find-Line '^// Custom Tags for Host Pool'
$existVnet   = Find-Line '^// Existing Session Host Virtual Network location'
$eEnd        = Last-NonBlank $existVnet

# Insert point: last non-blank line before "// Resource Groups"
$rgLine      = Find-Line '^// Resource Groups'
$insertAfter = Last-NonBlank $rgLine

Write-Host "Block A : L$($aStart+1)–L$($aEnd+1) : diskEncryptionSetName"
Write-Host "Block B : L$($bStart+1)–L$($bEnd+1) : fslLocalStorageAccountNames…fslogixConfigurationTags"
Write-Host "Block C : L$($cStart+1)–L$($cEnd+1) : vmIntuneEnrollment…vmConfigurationTags"
Write-Host "Block D : L$($dStart+1)–L$($dEnd+1) : fslogixFileShareNames + fslogixStorageCount"
Write-Host "Block E : L$($eStart+1)–L$($eEnd+1) : hostsResourceGroupIdTag + storageResourceGroupIdTag"
Write-Host "Insert after : L$($insertAfter+1) : $($lines[$insertAfter])"

# ── extract block content ──────────────────────────────────────────────────────
$blkA = $lines[$aStart..$aEnd]
$blkB = $lines[$bStart..$bEnd]
$blkC = $lines[$cStart..$cEnd]
$blkD = $lines[$dStart..$dEnd]
$blkE = $lines[$eStart..$eEnd]

# Trim trailing whitespace-only lines from each extracted block
foreach ($blk in @([ref]$blkA, [ref]$blkB, [ref]$blkC, [ref]$blkD, [ref]$blkE)) {
  $arr = $blk.Value
  $end = $arr.Count - 1
  while ($end -ge 0 -and $arr[$end].Trim() -eq '') { $end-- }
  $blk.Value = $arr[0..$end]
}

# ── mark lines to remove ──────────────────────────────────────────────────────
$remove = [System.Collections.Generic.HashSet[int]]::new()
foreach ($range in @(
  ($aStart..$aEnd),
  ($bStart..$bEnd),
  ($cStart..$cEnd),
  ($dStart..$dEnd),
  ($eStart..$eEnd)
)) { foreach ($i in $range) { [void]$remove.Add($i) } }

# Remove the single blank line immediately before each block start (avoids double-blanks after removal)
foreach ($blkStart in @($aStart, $bStart, $cStart, $dStart, $eStart)) {
  $j = $blkStart - 1
  if ($j -ge 0 -and $lines[$j].Trim() -eq '') { [void]$remove.Add($j) }
}

# ── build the new derived-variables section ────────────────────────────────────
$derived = [System.Collections.Generic.List[string]]::new()
$derived.Add('')
$derived.Add('// ============================================================================')
$derived.Add('// Derived Variables')
$derived.Add('// All vars below depend on the naming convention block above.')
$derived.Add('// ============================================================================')

$derived.Add('')
$derived.Add('// Resource Group ID tags — used on resources for cost management / chargeback')
$blkE | ForEach-Object { $derived.Add($_) }

$derived.Add('')
$derived.Add('// FSLogix storage configuration')
$blkD | ForEach-Object { $derived.Add($_) }
$derived.Add('')
$blkB | ForEach-Object { $derived.Add($_) }

$derived.Add('')
$derived.Add('// Disk encryption set name — selects the right DES convention based on key management settings')
$blkA | ForEach-Object { $derived.Add($_) }

$derived.Add('')
$derived.Add('// VM configuration tags — stamped on the hosts RG so SessionHostsOnly deployments can')
$derived.Add('// read the host pool configuration without requiring every parameter to be re-supplied')
$blkC | ForEach-Object { $derived.Add($_) }

# ── rebuild output lines ───────────────────────────────────────────────────────
$output = [System.Collections.Generic.List[string]]::new()
for ($i = 0; $i -lt $n; $i++) {
  if ($remove.Contains($i)) { continue }
  $output.Add($lines[$i])
  if ($i -eq $insertAfter) {
    $derived | ForEach-Object { $output.Add($_) }
  }
}

# ── collapse any triple+ blank lines introduced by the moves ──────────────────
$final = [System.Collections.Generic.List[string]]::new()
$prevBlank = $false
$prevPrevBlank = $false
foreach ($line in $output) {
  $isBlank = $line.Trim() -eq ''
  if ($isBlank -and $prevBlank -and $prevPrevBlank) { continue }  # skip third+ consecutive blank
  $final.Add($line)
  $prevPrevBlank = $prevBlank
  $prevBlank = $isBlank
}

# ── write back ────────────────────────────────────────────────────────────────
[System.IO.File]::WriteAllLines($file, $final, [System.Text.UTF8Encoding]::new($false))
Write-Host "`nDone. Lines: $n → $($final.Count)"
