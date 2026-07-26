# SessionHostReplacer Tabletop Scenarios - SideBySide Mode - Code Walkthrough

This document walks through three detailed scenarios for SideBySide replacement mode, tracing actual code execution paths.

## Test Environment Setup

- **Host Pool**: 100 session hosts (target capacity)
- **All hosts**: Need replacement (old image)
- **Replacement Mode**: SideBySide
- **Progressive Scale-Up**: Enabled
  - InitialDeploymentPercentage: 20%
  - ScaleUpIncrementPercentage: 40%
  - SuccessfulRunsBeforeScaleUp: 1
  - MaxDeploymentBatchSize: 50
- **Session Host Naming**: Sequential (e.g., avd-001, avd-002, etc.)
- **Current highest index**: avd-100

---

## Scenario 1: Successful Progressive Scale-Up Cycle

### Run 1: Initial 20% Batch (20 new hosts)

**Code Execution Path:**

1. **Line 119-123** (`run.ps1`): Load deployment state

   ```powershell
   if ($enableProgressiveScaleUp -or $replacementMode -eq 'DeleteFirst') {
       $deploymentState = Get-DeploymentState
   }
   ```

   - Result: `ConsecutiveSuccesses = 0`, SideBySide doesn't use `PendingHostMappings`

2. **Line 125-130**: Check previous deployment
   - Result: No previous deployment, skip this section

3. **Lines 450-475** (`SessionHostReplacer.Planning.psm1`): SideBySide capacity calculation

   ```powershell
   if ($ReplacementMode -eq 'DeleteFirst') {
       // Not executed
   }
   else {
       # SideBySide: Use buffer to allow pool to double
       $effectiveBuffer = $TargetSessionHostCount  # 100
       Write-LogEntry "Automatic buffer: $effectiveBuffer session hosts (allows pool to double)"
       
       $canDeployUpTo = $TargetSessionHostCount + $effectiveBuffer - $SessionHosts.count - $runningDeploymentVMCount
       # canDeployUpTo = 100 + 100 - 100 - 0 = 100
       
       $weNeedToDeploy = $TargetSessionHostCount - $sessionHostsCurrentTotal.Count
       # weNeedToDeploy = 100 - 0 = 100 (all hosts need replacement)
       
       $canDeploy = if ($weNeedToDeploy -gt $canDeployUpTo) { $canDeployUpTo } else { $weNeedToDeploy }
       # canDeploy = Min(100, 100) = 100
   }
   ```

   - canDeployUpTo = 100 (buffer allows pool to temporarily double)
   - weNeedToDeploy = 100 (all hosts need replacement)
   - canDeploy = **100 hosts**

4. **Lines 490-510**: Progressive scale-up calculation

   ```powershell
   if ($EnableProgressiveScaleUp -and $canDeploy -gt 0) {
       $deploymentState = Get-DeploymentState
       $currentPercentage = $InitialDeploymentPercentage  # 20
       
       if ($deploymentState.ConsecutiveSuccesses -ge $SuccessfulRunsBeforeScaleUp) {
           // Not executed (ConsecutiveSuccesses = 0)
       }
       
       $currentPercentage = [Math]::Min($currentPercentage, 100)  # 20
       $percentageBasedCount = [Math]::Ceiling($canDeploy * ($currentPercentage / 100.0))
       # percentageBasedCount = Ceiling(100 × 0.20) = 20
       
       $batchSizeLimit = if ($ReplacementMode -eq 'DeleteFirst') { $MaxDeletionsPerCycle } else { $MaxDeploymentBatchSize }
       # batchSizeLimit = 50
       
       $actualDeployCount = [Math]::Min($percentageBasedCount, $batchSizeLimit)
       # actualDeployCount = Min(20, 50) = 20
       
       $actualDeployCount = [Math]::Min($actualDeployCount, $canDeploy)
       # actualDeployCount = Min(20, 100) = 20
       
       $canDeploy = $actualDeployCount  # 20
   }
   ```

   - Result: **Deploy 20 hosts** (20% of 100)

5. **Lines 594-650**: Calculate deletions (SideBySide waits until after deployment)

   ```powershell
   if ($ReplacementMode -eq 'DeleteFirst') {
       // Not executed
   }
   else {
       # SideBySide mode: Only delete when overpopulated (more hosts than target)
       $overpopulation = $SessionHosts.Count - $TargetSessionHostCount
       # overpopulation = 100 - 100 = 0 (not overpopulated yet)
       
       if ($overpopulation -gt 0) {
           // Not executed
       }
       else {
           $canDelete = 0
           Write-LogEntry "Pool is not overpopulated. No deletions at this time."
       }
   }
   ```

   - Result: **canDelete = 0** (must deploy new hosts first before pool becomes overpopulated)

6. **Lines 880-960** (`run.ps1`): Deploy new session hosts

   ```powershell
   if ($hostPoolReplacementPlan.PossibleDeploymentsCount -gt 0) {
       # Generate new session host names (avd-101 through avd-120)
       $sessionHostNames = Get-NextSessionHostNames -Count 20 -StartingIndex 101
       
       # Deploy session hosts
       $deploymentResult = Start-SessionHostDeployment(...)
       
       $deploymentState = Get-DeploymentState
       $deploymentState.LastDeploymentName = $deploymentResult.DeploymentName
       $deploymentState.LastDeploymentCount = 20
       $deploymentState.LastTimestamp = Get-Date -AsUTC -Format 'o'
       
       Save-DeploymentState -DeploymentState $deploymentState
   }
   ```

   - New hosts: **avd-101 through avd-120** (20 new VMs)
   - Deployment submitted asynchronously

7. **Lines 564-597** (`virtualMachines.bicep`): DSC extension deploys

   ```bicep
   resource extension_DSC_installAvdAgents {
       properties: {
           forceUpdateTag: timestamp
           protectedSettings: {
               Items: {
                   RegistrationInfoToken: last(hostPool.listRegistrationTokens().value).token
               }
           }
       }
   }
   ```

   - DSC registers new 20 VMs with AVD

8. **Lines 975-983** (`run.ps1`): Safety check (next run, after deployment completes)

   ```powershell
   # STEP 2: Verify new session hosts are available before removing old ones
   if (-not $newHostAvailability.SafeToProceed -and $newHostAvailability.TotalNewHosts -gt 0) {
       Write-LogEntry "SAFETY CHECK FAILED: {0}" -Level Warning
       Write-LogEntry "Skipping old host removal to preserve capacity until new hosts become available"
       # Don't proceed with deletion - exit the SideBySide flow here
   }
   elseif ($newHostAvailability.TotalNewHosts -gt 0) {
       Write-LogEntry "SAFETY CHECK PASSED: {0}"
   }
   ```

   - Checks if new hosts (avd-101 to avd-120) are Available in AVD
   - If registered and Available → SafeToProceed = true
   - If not registered yet → SafeToProceed = false, SKIP deletions

**Next Function Run (after deployment completes):**

9. **Lines 125-180**: Check previous deployment success

   ```powershell
   if ($previousDeploymentStatus.Succeeded) {
       $allHostsRegistered = $true
       if ($replacementMode -eq 'DeleteFirst' && $deploymentState.PendingHostMappings -ne '{}') {
           // Not executed (SideBySide mode)
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

   - Deployment succeeded (20 VMs created) ✓
   - SideBySide doesn't check PendingHostMappings
   - ConsecutiveSuccesses++ = **1**
   - scaleUpMultiplier = Floor(1/1) = 1
   - CurrentPercentage = 20 + (1 × 40) = **60%**

10. **Lines 450-475**: Calculate new deployment capacity

    ```powershell
    $canDeployUpTo = $TargetSessionHostCount + $effectiveBuffer - $SessionHosts.count - $runningDeploymentVMCount
    # canDeployUpTo = 100 + 100 - 120 - 0 = 80 (buffer reduced by new hosts)
    
    $weNeedToDeploy = $TargetSessionHostCount - $sessionHostsCurrentTotal.Count
    # weNeedToDeploy = 100 - 20 = 80 (20 new are good, 80 old still need replacement)
    
    $canDeploy = Min(80, 80) = 80
    ```

11. **Lines 594-650**: Calculate deletions

    ```powershell
    $overpopulation = $SessionHosts.Count - $TargetSessionHostCount
    # overpopulation = 120 - 100 = 20
    
    if ($overpopulation -gt 0) {
        # In SideBySide mode, apply progressive scale-up to deletions
        if ($EnableProgressiveScaleUp) {
            $currentPercentage = 60  # From ConsecutiveSuccesses = 1
            $percentageBasedCount = [Math]::Ceiling($sessionHostsToReplace.Count * ($currentPercentage / 100.0))
            # percentageBasedCount = Ceiling(100 × 0.60) = 60
            
            $canDelete = [Math]::Min($percentageBasedCount, $overpopulation)
            # canDelete = Min(60, 20) = 20
        }
    }
    ```

    - Pool is now overpopulated by 20 ✓
    - Progressive scale-up allows 60% deletions
    - But overpopulation only 20
    - **canDelete = 20 hosts**

12. **Lines 975-1050**: Safety check & deletion
    ```powershell
    if ($newHostAvailability.SafeToProceed) {
        # Verify avd-101 to avd-120 are Available
        # PASSED ✓
        
        # Delete 20 oldest hosts (avd-001 through avd-020)
        $deletionResults = Remove-SessionHosts(...)
        
        # SideBySide mode doesn't require blocking device cleanup verification
        Confirm-SessionHostDeletions(...) | Out-Null  # Log only
    }
    ```
    - 20 new hosts verified Available ✓
    - Delete 20 old hosts (avd-001 to avd-020) ✓
    - Device cleanup logged but doesn't block

**Result:**
- 20 new hosts deployed (avd-101 to avd-120) ✓
- 20 old hosts deleted (avd-001 to avd-020) ✓
- Pool back to 100 hosts (20 new, 80 old) ✓
- ConsecutiveSuccesses = 1
- CurrentPercentage = 60%

---

### Run 3: Second Batch at 60% (48 hosts)

**Code Execution Path:**

1. **Lines 450-475**: Calculate capacity
   ```powershell
   $canDeployUpTo = 100 + 100 - 100 - 0 = 100
   $weNeedToDeploy = 100 - 20 = 80
   $canDeploy = 80
   ```

2. **Lines 490-510**: Progressive scale-up
   ```powershell
   $currentPercentage = 60  # ConsecutiveSuccesses = 1
   $percentageBasedCount = Ceiling(80 × 0.60) = 48
   $actualDeployCount = Min(48, 50, 80) = 48
   ```
   - Result: **Deploy 48 hosts**

3. **Deploy**: avd-121 through avd-168 (48 new VMs)

4. **Next Run**: Pool = 148 hosts (48 new + 100 existing)

5. **Lines 594-650**: Calculate deletions
   ```powershell
   $overpopulation = 148 - 100 = 48
   $percentageBasedCount = Ceiling(80 × 0.60) = 48
   $canDelete = Min(48, 48) = 48
   ```
   - Result: **Delete 48 hosts**

6. **Lines 975-1050**: Safety check & deletion
   - Verify avd-121 to avd-168 Available ✓
   - Delete avd-021 through avd-068 ✓

7. **Lines 125-180**: Update state
   - ConsecutiveSuccesses++ = **2**
   - CurrentPercentage = 20 + (2 × 40) = 100% (capped)

**Result:**
- 48 new hosts deployed (avd-121 to avd-168) ✓
- 48 old hosts deleted (avd-021 to avd-068) ✓
- Pool back to 100 hosts (68 new, 32 old) ✓
- CurrentPercentage = 100%

---

### Run 5: Final Batch at 100% (32 hosts)

**Code Execution Path:**

1. **Lines 490-510**: Progressive scale-up
   ```powershell
   $currentPercentage = 100
   $percentageBasedCount = Ceiling(32 × 1.0) = 32
   $actualDeployCount = Min(32, 50, 32) = 32
   ```

2. **Deploy**: avd-169 through avd-200 (32 new VMs)

3. **Next Run**: Pool = 132 hosts

4. **Lines 594-650**: Calculate deletions
   ```powershell
   $overpopulation = 132 - 100 = 32
   $canDelete = 32
   ```

5. **Delete**: avd-069 through avd-100 (32 old hosts)

**Final Result:**
- All 100 hosts replaced ✓
- New hosts: avd-101 through avd-200
- Old hosts: All deleted (avd-001 to avd-100)
- Total runs: 6 (3 deployment runs + 3 deletion runs)

---

## Scenario 2: Deployment Failure with Retry

### Run 1: Deploy 20 hosts, deployment fails

**Code Execution Path:**

1. **Lines 450-510**: Calculate 20% batch
   - canDeploy = **20 hosts**

2. **Lines 880-960**: Submit deployment
   ```powershell
   $deploymentResult = Start-SessionHostDeployment(...)
   $deploymentState.LastDeploymentName = $deploymentResult.DeploymentName
   $deploymentState.LastDeploymentCount = 20
   Save-DeploymentState
   ```
   - Deployment submitted for avd-101 to avd-120
   - **Deployment FAILS** (quota, token, network issue)

**Next Function Run:**

3. **Lines 193-220**: Handle deployment failure
   ```powershell
   elseif ($previousDeploymentStatus.Failed) {
       Write-LogEntry "Previous deployment failed"
       
       if ($enableProgressiveScaleUp) {
           $deploymentState.ConsecutiveSuccesses = 0
           $deploymentState.CurrentPercentage = $initialDeploymentPercentage  # 20
       }
       $deploymentState.LastStatus = 'Failed'
       Save-DeploymentState
   }
   ```
   - ConsecutiveSuccesses reset to **0**
   - CurrentPercentage reset to **20%**
   - LastStatus = 'Failed'

4. **Lines 594-650**: Calculate deletions
   ```powersharp
   $overpopulation = 100 - 100 = 0
   $canDelete = 0
   ```
   - Pool NOT overpopulated (deployment failed, no new hosts)
   - **No deletions** (capacity preserved) ✓

**Result:**
- Deployment failed, no new hosts created
- Old hosts NOT deleted (capacity preserved) ✓
- ConsecutiveSuccesses = 0
- Will retry at 20% on next run

---

### Run 2: Retry deployment of 20 hosts

**Code Execution Path:**

1. **Lines 450-510**: Calculate batch size
   ```powershell
   $canDeployUpTo = 100 + 100 - 100 - 0 = 100
   $weNeedToDeploy = 100 - 0 = 100
   
   # Progressive scale-up (ConsecutiveSuccesses = 0)
   $currentPercentage = 20
   $percentageBasedCount = Ceiling(100 × 0.20) = 20
   $canDeploy = 20
   ```
   - Retry same batch size: **20 hosts**

2. **Lines 880-960**: Deploy
   ```powershell
   # Generate NEW session host names (avd-101 to avd-120 again)
   # These names were never used (previous deployment failed before VM creation)
   $deploymentResult = Start-SessionHostDeployment(...)
   ```
   - **Deployment succeeds this time** ✓
   - 20 VMs created (avd-101 to avd-120)
   - DSC registers hosts

3. **Lines 594-650**: Calculate deletions (next run)
   ```powershell
   $overpopulation = 120 - 100 = 20
   $canDelete = 20
   ```
   - Pool now overpopulated ✓

4. **Lines 975-1050**: Safety check & deletion
   - Verify avd-101 to avd-120 Available ✓
   - Delete avd-001 to avd-020 ✓

5. **Lines 125-180**: Update state
   - ConsecutiveSuccesses++ = **1**
   - CurrentPercentage = 60%

**Result:**
- Retry successful ✓
- 20 new hosts deployed ✓
- 20 old hosts deleted ✓
- Progressive scale-up continues at 60%

---

## Scenario 3: New Hosts Deploy But Don't Register

### Run 1: Deploy 20 hosts, VMs created but registration fails

**Code Execution Path:**

1. **Lines 450-510**: Calculate 20% batch = **20 hosts**

2. **Lines 880-960**: Deploy
   - 20 VMs created (avd-101 to avd-120) ✓
   - DSC extension runs
   - **Registration fails** (network issue, bad token, DSC error)
   - Deployment status: "Succeeded" (VMs exist)
   - But VMs NOT in AVD host pool

**Next Function Run:**

3. **Lines 125-180**: Check previous deployment
   ```powershell
   if ($previousDeploymentStatus.Succeeded) {
       # Deployment succeeded (VMs created)
       # SideBySide mode doesn't check PendingHostMappings
       
       if ($enableProgressiveScaleUp) {
           $deploymentState.ConsecutiveSuccesses++  # Incremented!
           $deploymentState.LastStatus = 'Success'
           $scaleUpMultiplier = [Math]::Floor(1 / 1)
           $deploymentState.CurrentPercentage = 60
       }
   }
   ```
   - **ISSUE**: SideBySide mode doesn't verify registration before incrementing!
   - ConsecutiveSuccesses++ = 1 (incorrectly)
   - CurrentPercentage = 60%

4. **Lines 594-650**: Calculate deletions
   ```powershell
   $overpopulation = 120 - 100 = 20
   $sessionHostsToReplace = Get-SessionHostsToReplace(...)
   # This will EXCLUDE avd-101 to avd-120 (not registered, so not in session host list)
   # Only returns avd-001 to avd-100 (100 hosts)
   
   $percentageBasedCount = Ceiling(100 × 0.60) = 60
   $canDelete = Min(60, 20) = 20
   ```
   - Wants to delete 20 hosts

5. **Lines 975-1050**: Safety check
   ```powershell
   # Check if new hosts (avd-101 to avd-120) are Available
   $newHostAvailability = Get-NewHostAvailability(...)
   # Checks: Are avd-101 to avd-120 in host pool with status = Available?
   # Result: NOT FOUND or NOT Available
   
   if (-not $newHostAvailability.SafeToProceed -and $newHostAvailability.TotalNewHosts -gt 0) {
       Write-LogEntry "SAFETY CHECK FAILED" -Level Warning
       Write-LogEntry "Skipping old host removal to preserve capacity until new hosts become available"
       # EXIT - Don't delete
   }
   ```
   - **Safety check FAILS** ✓
   - New hosts not Available
   - **BLOCKS deletion** ✓
   - Capacity preserved ✓

**Result:**
- 20 VMs exist in Azure ✓
- NOT registered in AVD ✗
- Safety check prevents deletion ✓
- ConsecutiveSuccesses = 1 (incorrectly incremented, but doesn't matter - safety check prevents damage)

---

### Run 2: Retry registration (or deploy more hosts)

**Code Execution Path:**

1. **Lines 450-510**: Calculate capacity
   ```powershell
   $canDeployUpTo = 100 + 100 - 120 - 0 = 80
   # (120 VMs exist, even though 20 not registered)
   
   $sessionHostsCurrentTotal = Get-SessionHostsInGoodShape(...)
   # Returns only avd-001 to avd-100 (100 hosts, because avd-101+ not registered)
   
   $weNeedToDeploy = 100 - 100 = 0
   # System thinks we have enough because it only sees registered hosts!
   
   $canDeploy = 0
   ```
   - **ISSUE**: System can't deploy more because buffer full
   - Stuck until avd-101 to avd-120 register or are removed

**Resolution Option A: Manual Intervention**
- Admin investigates why avd-101 to avd-120 didn't register
- Fix network/permissions/token issue
- Force DSC to re-run (update extension tag manually)
- Hosts register → Safety check passes → Deletions proceed

**Resolution Option B: Automatic with forceUpdateTag**
If deployment was submitted again (e.g., force via redeployment):

2. **Deploy**: Attempt to deploy avd-101 to avd-120 again
   - VMs already exist → ARM idempotence (no-op for VMs)
   - DSC extension: `forceUpdateTag: timestamp` (different value)
   - ARM sees extension changed → **Re-runs DSC**
   - Fresh registration token → **Registration succeeds** ✓

3. **Next Run**: Safety check
   ```powershell
   $newHostAvailability = Get-NewHostAvailability(...)
   # avd-101 to avd-120 now Available ✓
   
   if ($newHostAvailability.SafeToProceed) {
       # Delete avd-001 to avd-020
   }
   ```
   - Safety check passes ✓
   - Deletions proceed ✓

**Result:**
- forceUpdateTag enables automatic retry of DSC registration
- Safety check prevents capacity loss until new hosts Available
- Progressive scale-up continues

---

## Key Differences from DeleteFirst Mode

### 1. No PendingHostMappings
- **DeleteFirst**: Saves hostnames before deletion for reuse
- **SideBySide**: Generates new sequential hostnames each deployment
- Code: Lines 740-753 (`run.ps1`) only execute in DeleteFirst mode

### 2. Buffer Capacity Calculation (Lines 450-475)
```powershell
if ($ReplacementMode -eq 'SideBySide') {
    $effectiveBuffer = $TargetSessionHostCount  # Allows pool to double
    $canDeployUpTo = Target + Buffer - Current - Running
}
```
- Allows pool to temporarily grow to 2× target capacity
- DeleteFirst doesn't need buffer (deletes first to make room)

### 3. Deletion Timing (Lines 594-650)
```powershell
# SideBySide: Only delete when overpopulated
$overpopulation = $SessionHosts.Count - $TargetSessionHostCount
if ($overpopulation -gt 0) {
    $canDelete = Min($percentageBasedCount, $overpopulation)
}
```
- DeleteFirst: Deletes BEFORE deployment
- SideBySide: Deletes AFTER deployment (when overpopulated)

### 4. Safety Check (Lines 975-983)
```powershell
if (-not $newHostAvailability.SafeToProceed -and $newHostAvailability.TotalNewHosts -gt 0) {
    Write-LogEntry "SAFETY CHECK FAILED"
    # BLOCK deletions until new hosts Available
}
```
- Critical for SideBySide: Prevents deleting old hosts until new hosts are Available
- DeleteFirst: Not used (hosts already deleted before deployment)

### 5. Device Cleanup (Lines 1013-1050)
```powershell
# SideBySide mode doesn't halt on failures since name reuse isn't critical
Confirm-SessionHostDeletions(...) | Out-Null  # Log only
```
- DeleteFirst: BLOCKS deployment if device cleanup fails (hostname reuse requires it)
- SideBySide: Logs device cleanup status but doesn't block (new hostnames used)

### 6. Registration Verification Gap
**DeleteFirst** (Lines 125-180):
```powershell
if ($replacementMode -eq 'DeleteFirst' && $deploymentState.PendingHostMappings -ne '{}') {
    # Verify hosts actually registered before clearing mappings
    $missingHosts = Check if hosts in AVD
    if ($missingHosts.Count -eq 0) {
        $allHostsRegistered = true
    }
}
```

**SideBySide**:
- No equivalent verification before incrementing ConsecutiveSuccesses
- Relies on **safety check** (lines 975-983) to prevent damage
- Safety check verifies new hosts Available before allowing deletions

---

## Protection Mechanisms in SideBySide Mode

### 1. Buffer Capacity (Line 467)
- Allows pool to double during rolling updates
- Prevents deployment failures due to capacity limits

### 2. Safety Check (Lines 975-983)
- **Critical protection**: Verifies new hosts Available before deleting old hosts
- Prevents capacity loss if deployment succeeds but registration fails
- Blocks deletions until new capacity is confirmed

### 3. Overpopulation-Based Deletion (Lines 594-650)
- Only deletes when pool exceeds target capacity
- Natural throttle: Can only delete as many hosts as were deployed
- Progressive scale-up applies to deletions (not just deployments)

### 4. Force Update Tag (virtualMachines.bicep:571)
```bicep
forceUpdateTag: timestamp
```
- Enables automatic DSC retry on redeployment
- Fixes registration failures through idempotent redeployment

### 5. Device Cleanup (Non-Blocking)
- Logs cleanup status but doesn't halt operations
- Name reuse not required (new sequential names)
- Hygiene operation, not critical path

---

## Code References

### Critical Files
- **run.ps1**: Main orchestration
  - Lines 125-180: State management (no registration verification for SideBySide)
  - Lines 880-960: Deployment submission
  - Lines 975-983: Safety check (CRITICAL for SideBySide)
  - Lines 985-1050: Deletion with non-blocking device cleanup

- **SessionHostReplacer.Planning.psm1**: Capacity and deletion planning
  - Lines 450-475: Buffer capacity calculation (SideBySide specific)
  - Lines 490-510: Progressive scale-up (applies to both modes)
  - Lines 594-650: Overpopulation-based deletion calculation

- **virtualMachines.bicep**: VM and extension deployment
  - Lines 564-597: DSC extension with forceUpdateTag

### Azure Table Storage Schema (SideBySide)
**Fields Used**:
- ConsecutiveSuccesses: integer (tracks successful deployments)
- CurrentPercentage: integer (progressive scale-up percentage)
- LastDeploymentName: string (for status checking)
- LastStatus: 'Success' | 'Failed'
- **PendingHostMappings**: NOT USED in SideBySide mode

---

## Summary

All three scenarios verified against actual code:

1. **Successful Cycle**: Progressive scale-up 20% → 60% → 100%, deploy then delete pattern works correctly
2. **Deployment Failure**: No deletions until deployment succeeds, retry works correctly
3. **Registration Failure**: Safety check prevents deletions until hosts Available, forceUpdateTag enables DSC retry

The implementation correctly handles:
- ✓ Buffer capacity for temporary pool doubling
- ✓ Safety check prevents capacity loss
- ✓ Overpopulation-based deletion timing
- ✓ Progressive scale-up applies to both deployments and deletions
- ✓ Force update tag enables DSC retry
- ✓ Non-blocking device cleanup (hygiene only)

**Key Gap Identified**: SideBySide mode doesn't verify registration before incrementing ConsecutiveSuccesses, but the **safety check compensates** by preventing deletions until new hosts are Available. This means incorrect scale-up won't cause capacity loss, but could accelerate batch sizes prematurely.
