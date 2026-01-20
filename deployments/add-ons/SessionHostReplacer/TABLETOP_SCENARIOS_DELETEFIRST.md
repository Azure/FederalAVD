# SessionHostReplacer Tabletop Scenarios - Code Walkthrough

This document walks through three detailed scenarios tracing actual code execution paths.

## Test Environment Setup

- **Host Pool**: 100 session hosts
- **All hosts**: Need replacement (old image)
- **Replacement Mode**: DeleteFirst
- **Progressive Scale-Up**: Enabled
  - InitialDeploymentPercentage: 20%
  - ScaleUpIncrementPercentage: 40%
  - SuccessfulRunsBeforeScaleUp: 1
  - MaxDeletionsPerCycle: 50

---

## Scenario 1: Successful Progressive Scale-Up Cycle

### Run 1: Initial 20% Batch (20 hosts)

**Code Execution Path:**

1. **Line 119-123** (`run.ps1`): Load deployment state

   ```powershell
   if ($enableProgressiveScaleUp -or $replacementMode -eq 'DeleteFirst') {
       $deploymentState = Get-DeploymentState
   }
   ```

   - Result: `ConsecutiveSuccesses = 0`, `PendingHostMappings = '{}'`

2. **Line 125-130**: Check previous deployment

   ```powershell
   if ($previousDeployment) {
       $previousDeploymentStatus = Get-DeploymentStatus
       if ($previousDeploymentStatus.Succeeded) {
   ```

   - Result: No previous deployment, skip this section

3. **Lines 310-320**: Lightweight check for pending hosts

   ```powershell
   if ($replacementMode -eq 'DeleteFirst') {
       $deploymentState = Get-DeploymentState
       if ($deploymentState.PendingHostMappings -ne '{}') {
           $isUpToDate = false
       }
   }
   ```

   - Result: PendingHostMappings empty, continue normal flow

4. **Lines 490-510** (`SessionHostReplacer.Planning.psm1`): Progressive scale-up calculation

   ```powershell
   if ($EnableProgressiveScaleUp -and $canDeploy -gt 0) {
       $deploymentState = Get-DeploymentState
       $currentPercentage = $InitialDeploymentPercentage  # 20
       
       if ($deploymentState.ConsecutiveSuccesses -ge $SuccessfulRunsBeforeScaleUp) {
           $scaleUpMultiplier = [Math]::Floor($deploymentState.ConsecutiveSuccesses / $SuccessfulRunsBeforeScaleUp)
           $currentPercentage = $InitialDeploymentPercentage + ($scaleUpMultiplier * $ScaleUpIncrementPercentage)
       }
       
       $currentPercentage = [Math]::Min($currentPercentage, 100)
       $percentageBasedCount = [Math]::Ceiling($canDeploy * ($currentPercentage / 100.0))
       $batchSizeLimit = if ($ReplacementMode -eq 'DeleteFirst') { $MaxDeletionsPerCycle } else { $MaxDeploymentBatchSize }
       $actualDeployCount = [Math]::Min($percentageBasedCount, $batchSizeLimit)
       $actualDeployCount = [Math]::Min($actualDeployCount, $canDeploy)
   }
   ```

   - ConsecutiveSuccesses = 0 (not >= 1)
   - currentPercentage = 20
   - percentageBasedCount = Ceiling(100 × 0.20) = 20
   - actualDeployCount = Min(20, 50, 100) = **20 hosts**

5. **Lines 662-710** (`run.ps1`): Check for pending unresolved hosts

   ```powershell
   $hasPendingUnresolvedHosts = $false
   $deploymentState = Get-DeploymentState
   if ($deploymentState.PendingHostMappings -ne '{}') {
       $hostPropertyMapping = ConvertFrom-Json -AsHashtable
       $unresolvedHosts = pendingHostNames not in registeredHostNames
       
       if ($unresolvedHosts.Count -gt 0) {
           $hasPendingUnresolvedHosts = true
           Write-LogEntry "BLOCKING new deletions"
       }
   }
   ```

   - Result: PendingHostMappings = '{}', hasPendingUnresolvedHosts = false

6. **Lines 740-753**: Save mappings BEFORE deletion

   ```powershell
   foreach ($sessionHost in $hostPoolReplacementPlan.SessionHostsPendingDelete) {
       $hostPropertyMapping[$sessionHost.SessionHostName] = @{
           HostId = ..., HostGroupId = ..., Zones = ...
       }
   }
   
   $deploymentState = Get-DeploymentState
   $deploymentState.PendingHostMappings = ($hostPropertyMapping | ConvertTo-Json -Compress)
   Save-DeploymentState -DeploymentState $deploymentState
   ```

   - Result: 20 hostnames saved to PendingHostMappings

7. **Lines 810-851**: Delete session hosts with device cleanup verification

   ```powershell
   $deletionResults = Remove-SessionHosts(...)
   
   if ($deletionResults.SuccessfulDeletions.Count -gt 0) {
       $verificationResults = Confirm-SessionHostDeletions `
           -DeletedHostNames $deletionResults.SuccessfulDeletions `
           -RemoveEntraDevice $removeEntraDevice `
           -RemoveIntuneDevice $removeIntuneDevice
       
       $deviceCleanupRequired = $removeEntraDevice -or $removeIntuneDevice
       if ($deviceCleanupRequired && $verificationResults.IncompleteHosts.Count -gt 0) {
           throw "Device cleanup verification failed - cannot safely reuse hostnames"
       }
   }
   ```

   - Result: 20 VMs deleted, 20 Entra devices removed, 20 Intune devices removed
   - Verification passed

8. **Line 833**: Calculate net-new hosts

   ```powershell
   $netNewHosts = [Math]::Max(0, $originalDeployCount - $hostsToReplace)
   ```

   - originalDeployCount = 20 (from progressive scale-up)
   - hostsToReplace = 20
   - netNewHosts = Max(0, 20-20) = **0**

9.  **Deploy**: 20 replacement VMs with reused hostnames

   - Bicep deployment: `sessionHostNames` = 20 hostnames from PendingHostMappings
   - VMs created successfully

10. **Lines 564-597** (`virtualMachines.bicep`): DSC extension with forceUpdateTag

    ```bicep
    resource extension_DSC_installAvdAgents 'Microsoft.Compute/virtualMachines/extensions@2021-03-01' = [
      for i in range(0, sessionHostCount): {
        properties: {
          forceUpdateTag: timestamp  // Unique per deployment
          ...
          protectedSettings: {
            Items: {
              RegistrationInfoToken: last(hostPool.listRegistrationTokens().value).token
            }
          }
        }
      }
    ]
    ```

    - DSC runs, registers all 20 VMs with AVD

**Next Function Run:**

11. **Lines 125-180**: Check previous deployment success + registration

    ```powershell
    if ($previousDeploymentStatus.Succeeded) {
        $allHostsRegistered = $true
        if ($replacementMode -eq 'DeleteFirst' && $deploymentState.PendingHostMappings -ne '{}') {
            $pendingMappings = ConvertFrom-Json -AsHashtable
            $expectedHostNames = $pendingMappings.Keys
            $registeredHostNames = (Get-AzWvdSessionHost ...).Name
            
            $missingHosts = $expectedHostNames | Where-Object { $_ -notin $registeredHostNames }
            
            if ($missingHosts.Count -eq 0) {
                Write-LogEntry "All {0} pending hosts are now registered" -StringValues $expectedHostNames.Count
                $deploymentState.PendingHostMappings = '{}'
                $allHostsRegistered = $true
            } else {
                Write-LogEntry "{0} hosts still not registered: {1}" -StringValues $missingHosts.Count, ($missingHosts -join ',') -Level Warning
                $allHostsRegistered = $false
            }
        }
        
        if ($enableProgressiveScaleUp) {
            if ($allHostsRegistered) {
                $deploymentState.ConsecutiveSuccesses++
                $deploymentState.LastStatus = 'Success'
                
                $scaleUpMultiplier = [Math]::Floor($deploymentState.ConsecutiveSuccesses / $successfulRunsBeforeScaleUp)
                $deploymentState.CurrentPercentage = [Math]::Min(
                    $initialDeploymentPercentage + ($scaleUpMultiplier * $scaleUpIncrementPercentage),
                    100
                )
            }
        }
    }
    ```

    - Deployment succeeded = true
    - PendingHostMappings has 20 hostnames
    - Get registered hosts from AVD: 20 hosts found
    - missingHosts.Count = 0 ✓
    - **Clear PendingHostMappings**
    - ConsecutiveSuccesses++ = **1**
    - scaleUpMultiplier = Floor(1/1) = 1
    - CurrentPercentage = 20 + (1 × 40) = **60%**

**Result:** 

- 20 hosts replaced successfully ✓
- ConsecutiveSuccesses = 1
- CurrentPercentage = 60%
- 80 hosts remain to be replaced

---

### Run 3: Second Batch at 60% (60 hosts)

**Code Execution Path:**

1. **Lines 490-510**: Progressive scale-up calculation
   - ConsecutiveSuccesses = 1 (>= 1) ✓
   - scaleUpMultiplier = Floor(1/1) = 1
   - currentPercentage = 20 + (1 × 40) = 60
   - percentageBasedCount = Ceiling(80 × 0.60) = 48
   - actualDeployCount = Min(48, 50, 80) = **48 hosts**

2. **Lines 662-710**: Check pending hosts
   - PendingHostMappings = '{}' (cleared in Run 2)
   - hasPendingUnresolvedHosts = false

3. **Lines 740-753**: Save 48 hostnames to PendingHostMappings

4. **Lines 810-851**: Delete 48 hosts, verify device cleanup

5. **Deploy**: 48 replacement VMs

6. **DSC Extension**: Registers 48 VMs with AVD

**Next Function Run:**

7. **Lines 125-180**: Check registration

   - All 48 hosts registered ✓
   - Clear PendingHostMappings
   - ConsecutiveSuccesses++ = **2**
   - scaleUpMultiplier = Floor(2/1) = 2
   - CurrentPercentage = 20 + (2 × 40) = 100 (capped at 100)

**Result:**

- 48 hosts replaced successfully ✓
- ConsecutiveSuccesses = 2
- CurrentPercentage = 100%
- 32 hosts remain

---

### Run 5: Final Batch at 100% (32 hosts)

**Code Execution Path:**

1. **Lines 490-510**: Progressive scale-up calculation
   - ConsecutiveSuccesses = 2 (>= 1) ✓
   - scaleUpMultiplier = Floor(2/1) = 2
   - currentPercentage = 20 + (2 × 40) = 100
   - percentageBasedCount = Ceiling(32 × 1.0) = 32
   - actualDeployCount = Min(32, 50, 32) = **32 hosts**

2. **Lines 740-753**: Save 32 hostnames

3. **Lines 810-851**: Delete 32 hosts, verify device cleanup

4. **Deploy**: 32 replacement VMs

5. **DSC Extension**: Registers 32 VMs

**Next Function Run:**

6. **Lines 125-180**: Check registration
   - All 32 hosts registered ✓
   - Clear PendingHostMappings
   - ConsecutiveSuccesses++ = **3**

**Final Result:**

- All 100 hosts replaced ✓
- Total runs: 6 (3 deployment runs + 3 verification runs)

---

## Scenario 2: Deployment Failure with Retry

### Run 1: Deploy 20 hosts, deployment fails (token quota exceeded)

**Code Execution Path:**

1. **Lines 119-123**: Load deployment state
   - ConsecutiveSuccesses = 0
   - PendingHostMappings = '{}'

2. **Lines 490-510**: Calculate 20% batch
   - actualDeployCount = **20 hosts**

3. **Lines 662-710**: Check pending hosts
   - PendingHostMappings = '{}', no blocking

4. **Lines 740-753**: **CRITICAL - Save BEFORE deletion**

   ```powershell
   $deploymentState.PendingHostMappings = ($hostPropertyMapping | ConvertTo-Json -Compress)
   Save-DeploymentState -DeploymentState $deploymentState
   ```

   - **20 hostnames saved to Azure Table Storage**

5. **Lines 810-851**: Delete 20 hosts
   - 20 VMs deleted ✓
   - 20 Entra devices removed ✓
   - 20 Intune devices removed ✓
   - Device cleanup verification passed ✓

6. **Deploy**: Bicep deployment starts
   - **Deployment FAILS** (quota exceeded, token issue, etc.)
   - VMs not created

**Next Function Run:**

7. **Lines 193-220**: Handle previous deployment failure

   ```powershell
   elseif ($previousDeploymentStatus.Failed) {
       # Cleanup partial resources if any
       
       # CRITICAL: Do NOT clear pending host mappings - keep for retry
       Write-LogEntry "Keeping {0} pending host mappings for retry" -StringValues $hostPropertyMapping.Count
       
       if ($enableProgressiveScaleUp) {
           $deploymentState.ConsecutiveSuccesses = 0
           $deploymentState.CurrentPercentage = $initialDeploymentPercentage
       }
       $deploymentState.LastStatus = 'Failed'
       Save-DeploymentState -DeploymentState $deploymentState
   }
   ```

   - **PendingHostMappings NOT cleared** (contains 20 hostnames)
   - ConsecutiveSuccesses reset to 0
   - CurrentPercentage reset to 20
   - LastStatus = 'Failed'

**Result:**

- 20 hosts deleted, but replacements not deployed
- **Capacity reduced by 20** (temporary)
- PendingHostMappings preserved with 20 hostnames

---

### Run 2: Retry deployment of same 20 hosts

**Code Execution Path:**

1. **Lines 310-320**: Lightweight check for pending work

   ```powershell
   if ($replacementMode -eq 'DeleteFirst') {
       $deploymentState = Get-DeploymentState
       if ($deploymentState.PendingHostMappings -ne '{}') {
           $isUpToDate = false  # Force processing
       }
   }
   ```

   - PendingHostMappings contains 20 hostnames
   - **Prevents early exit**, continues to deployment

2. **Lines 490-510**: Calculate batch size
   - ConsecutiveSuccesses = 0
   - currentPercentage = 20
   - canDeploy = 100 (still showing 80 healthy + 20 missing)
   - percentageBasedCount = Ceiling(100 × 0.20) = 20
   - actualDeployCount = **20 hosts**

3. **Lines 662-710**: Check for pending unresolved hosts

   ```powershell
   $deploymentState = Get-DeploymentState
   if ($deploymentState.PendingHostMappings -ne '{}') {
       $hostPropertyMapping = ConvertFrom-Json -AsHashtable
       $registeredHostNames = (Get-AzWvdSessionHost ...).Name
       
       $unresolvedHosts = $hostPropertyMapping.Keys | Where-Object { $_ -notin $registeredHostNames }
       
       if ($unresolvedHosts.Count -gt 0) {
           $hasPendingUnresolvedHosts = $true
           Write-LogEntry "BLOCKING new deletions until pending hosts are resolved"
       } else {
           # All resolved, clear mappings
           $deploymentState.PendingHostMappings = '{}'
           Save-DeploymentState
       }
   }
   ```

   - PendingHostMappings has 20 hostnames
   - Get registered hosts: 80 hosts (20 still missing)
   - unresolvedHosts.Count = 20
   - **hasPendingUnresolvedHosts = true**

4. **Lines 717-720**: Blocking prevents new deletions

   ```powershell
   elseif ($hasPendingUnresolvedHosts) {
       Write-LogEntry "SAFETY CHECK FAILED: Cannot delete more hosts while previous deletions have unresolved deployments"
       Write-LogEntry "Will retry deployment of pending hosts without deleting additional capacity"
       # Skip deletion but allow deployment retry below
   }
   ```

   - **SKIPS deletion phase** (no additional capacity lost)
   - Continues to deployment phase

5. **Line 830**: Calculate deployment count

   ```powershell
   # Use pending host mappings count if no new deletions occurred
   if ($hostPropertyMapping.Count -gt 0) {
       $canDeploy = $hostPropertyMapping.Count  # 20
   }
   ```

   - canDeploy = **20 hosts** (from PendingHostMappings)

6. **Deploy**: Bicep deployment with 20 hostnames from PendingHostMappings
   - VMs don't exist (deleted in Run 1)
   - ARM sees: VMs needed, don't exist → **Create VMs**
   - DSC extension: `forceUpdateTag: timestamp` (different value than Run 1)
   - **Deployment succeeds this time** ✓
   - 20 VMs created
   - DSC registers 20 VMs with AVD

**Next Function Run:**

7. **Lines 125-180**: Check registration

   ```powershell
   if ($previousDeploymentStatus.Succeeded) {
       if ($replacementMode -eq 'DeleteFirst' && $deploymentState.PendingHostMappings -ne '{}') {
           $missingHosts = expectedHostNames | Where-Object { $_ -notin $registeredHostNames }
           
           if ($missingHosts.Count -eq 0) {
               $deploymentState.PendingHostMappings = '{}'
               $allHostsRegistered = $true
           }
       }
       
       if ($enableProgressiveScaleUp && $allHostsRegistered) {
           $deploymentState.ConsecutiveSuccesses++
       }
   }
   ```

   - Deployment succeeded ✓
   - Get registered hosts: All 100 hosts present ✓
   - missingHosts.Count = 0
   - **Clear PendingHostMappings**
   - ConsecutiveSuccesses++ = 1
   - CurrentPercentage = 60%

**Result:**

- 20 hosts successfully deployed on retry ✓
- Capacity restored to 100 ✓
- Progressive scale-up continues at 60% for next batch

---

## Scenario 3: Registration Failure

### Run 1: Deploy 20 hosts, VMs created but don't register

**Code Execution Path:**

1. **Lines 119-123**: Load state (ConsecutiveSuccesses = 0)

2. **Lines 490-510**: Calculate 20% batch = **20 hosts**

3. **Lines 740-753**: Save 20 hostnames to PendingHostMappings

4. **Lines 810-851**: Delete 20 hosts successfully

5. **Deploy**: Bicep deployment
   - 20 VMs created ✓
   - DSC extension runs with fresh token
   - **Registration fails** (network issue, DSC error, bad token)
   - Deployment reports "Succeeded" (VMs created)
   - But VMs not in AVD host pool

**Next Function Run:**

6. **Lines 125-180**: Check registration status

   ```powershell
   if ($previousDeploymentStatus.Succeeded) {
       $allHostsRegistered = $true
       if ($replacementMode -eq 'DeleteFirst' && $deploymentState.PendingHostMappings -ne '{}') {
           $pendingMappings = ConvertFrom-Json -AsHashtable
           $expectedHostNames = $pendingMappings.Keys  # 20 hostnames
           $registeredHostNames = (Get-AzWvdSessionHost ...).Name  # 80 hosts
           
           $missingHosts = $expectedHostNames | Where-Object { $_ -notin $registeredHostNames }
           # missingHosts = 20 (all missing!)
           
           if ($missingHosts.Count -eq 0) {
               # Not executed
           } else {
               Write-LogEntry "{0} hosts still not registered: {1}" -Level Warning
               $allHostsRegistered = $false
               # DO NOT clear PendingHostMappings
           }
       }
       
       if ($enableProgressiveScaleUp) {
           if ($allHostsRegistered) {
               // Not executed - allHostsRegistered = false
           }
           else {
               # Deployment succeeded but hosts didn't register - don't count as success
               $deploymentState.LastStatus = 'PendingRegistration'
               Write-LogEntry "Deployment succeeded but hosts not yet registered - NOT incrementing success counter" -Level Warning
           }
       }
   }
   ```

   - Deployment succeeded = true ✓
   - PendingHostMappings has 20 hostnames
   - Get registered hosts: Only 80 hosts (20 missing)
   - missingHosts.Count = 20
   - allHostsRegistered = **false**
   - **PendingHostMappings NOT cleared**
   - **ConsecutiveSuccesses NOT incremented** (stays at 0)
   - LastStatus = **'PendingRegistration'**

**Result:**

- 20 VMs exist in Azure ✓
- But NOT registered in AVD host pool ✗
- PendingHostMappings preserved
- ConsecutiveSuccesses = 0 (no scale-up)

---

### Run 2: Retry registration

**Code Execution Path:**

1. **Lines 310-320**: Lightweight check
   - PendingHostMappings = 20 hostnames
   - Force processing (no early exit)

2. **Lines 490-510**: Calculate batch
   - ConsecutiveSuccesses = 0 (not incremented)
   - currentPercentage = 20
   - actualDeployCount = **20 hosts**

3. **Lines 662-710**: Check pending unresolved hosts

   ```powershell
   if ($deploymentState.PendingHostMappings -ne '{}') {
       $unresolvedHosts = pending hosts not in registered hosts
       # unresolvedHosts.Count = 20
       
       if ($unresolvedHosts.Count -gt 0) {
           $hasPendingUnresolvedHosts = $true
           Write-LogEntry "Found {0} unresolved pending hosts from previous deployment" -StringValues $unresolvedHosts.Count
           Write-LogEntry "BLOCKING new deletions until pending hosts are resolved"
       }
   }
   ```

   - unresolvedHosts.Count = 20
   - **hasPendingUnresolvedHosts = true**

4. **Lines 717-720**: Blocking prevents deletions
   - **SKIPS deletion** (no additional capacity lost)

5. **Deploy**: Retry deployment of same 20 hostnames
   - VMs already exist (created in Run 1)
   - ARM checks: VMs exist with matching properties → **No-op for VMs**
   - DSC extension: `forceUpdateTag: timestamp` (NEW VALUE - forces update!)
   - ARM sees: Extension properties changed (different forceUpdateTag)
   - **Re-runs DSC extension** ✓
   - DSC downloads fresh registration token
   - **Registration succeeds this time** ✓

6. **Lines 564-597** (`virtualMachines.bicep`): Why DSC re-runs

   ```bicep
   properties: {
     forceUpdateTag: timestamp  // Different on every deployment
     ...
     protectedSettings: {
       Items: {
         RegistrationInfoToken: last(hostPool.listRegistrationTokens().value).token  // Fresh token
       }
     }
   }
   ```

   - forceUpdateTag changed → ARM updates extension
   - New registration token → Registration succeeds

**Next Function Run:**

7. **Lines 125-180**: Check registration

   ```powershell
   if ($previousDeploymentStatus.Succeeded) {
       if ($replacementMode -eq 'DeleteFirst' && $deploymentState.PendingHostMappings -ne '{}') {
           $missingHosts = expected hosts not in registered hosts
           
           if ($missingHosts.Count -eq 0) {
               Write-LogEntry "All {0} pending hosts are now registered"
               $deploymentState.PendingHostMappings = '{}'
               $allHostsRegistered = $true
           }
       }
       
       if ($enableProgressiveScaleUp && $allHostsRegistered) {
           $deploymentState.ConsecutiveSuccesses++
           # Calculate new percentage
       }
   }
   ```

   - Get registered hosts: All 100 hosts present ✓
   - missingHosts.Count = 0 ✓
   - **Clear PendingHostMappings**
   - allHostsRegistered = true
   - ConsecutiveSuccesses++ = **1**
   - CurrentPercentage = 60%

**Result:**

- Registration successful on retry ✓
- All 100 hosts in AVD ✓
- Progressive scale-up resumes at 60% for next batch

---

## Key Protection Mechanisms

### 1. PendingHostMappings Lifecycle

- **Created**: Before any deletions occur (line 740-753)
- **Persisted**: Through deployment failures (line 198-220)
- **Persisted**: Through registration failures (line 168)
- **Cleared**: Only after hosts verify as registered (line 146)

### 2. Blocking Logic (Lines 662-710)

```powershell
if (PendingHostMappings exist AND hosts not registered) {
    hasPendingUnresolvedHosts = true
    BLOCK new deletions
}
```

- Prevents cascading capacity loss
- Forces resolution of pending hosts before new deletions

### 3. Registration Verification (Lines 125-180)

```powershell
if (deployment succeeded) {
    Check if hosts actually in AVD
    if (all registered) → Clear mappings, increment success
    else → Keep mappings, DON'T increment, status = 'PendingRegistration'
}
```

- Deployment success ≠ Registration success
- Progressive scale-up only proceeds when hosts actually register

### 4. Device Cleanup Verification (Lines 810-851)

```powershell
$verificationResults = Confirm-SessionHostDeletions(...)
if (device cleanup required && incomplete hosts > 0) {
    throw "Device cleanup verification failed - cannot safely reuse hostnames"
}
```

- Blocks deployment if Entra ID or Intune cleanup fails
- Critical for DeleteFirst mode (hostname reuse)

### 5. Force Update Tag (virtualMachines.bicep:571)

```bicep
forceUpdateTag: timestamp
```

- Forces DSC extension to re-run on every deployment
- Ensures fresh registration token on retries
- Works even when VM properties unchanged (idempotence)

---

## Code References

### Critical Files

- **run.ps1**: Main orchestration logic
  - Lines 119-180: State management and registration verification
  - Lines 310-320: Lightweight check for pending work
  - Lines 662-710: Blocking logic for unresolved hosts
  - Lines 740-753: Save mappings before deletion
  - Lines 810-851: Device cleanup verification

- **SessionHostReplacer.Planning.psm1**: Planning and calculation
  - Lines 490-510: Progressive scale-up percentage calculation

- **virtualMachines.bicep**: VM and extension deployment
  - Lines 564-597: DSC extension with forceUpdateTag

### Azure Table Storage Schema

**Table**: sessionHostDeploymentState  
**Partition Key**: HostPoolName  
**Row Key**: DeploymentState  
**Fields**:

- PendingHostMappings: `{"hostname": {"HostId": "...", "HostGroupId": "...", "Zones": [...]}}`
- ConsecutiveSuccesses: integer
- CurrentPercentage: integer
- LastDeploymentName: string
- LastStatus: 'Success' | 'Failed' | 'PendingRegistration'

---

## Summary

All three scenarios verified against actual code:

1. **Successful Cycle**: Progressive scale-up 20% → 60% → 100% works correctly
2. **Deployment Failure**: Mappings preserved, retry works, blocking prevents capacity loss
3. **Registration Failure**: Detection works, forceUpdateTag forces DSC retry, blocking prevents new deletions

The implementation correctly handles:

- ✓ Persistence across failures
- ✓ Registration verification
- ✓ Blocking to prevent capacity loss
- ✓ Device cleanup enforcement
- ✓ Force update for DSC retries
- ✓ Progressive scale-up only on confirmed success