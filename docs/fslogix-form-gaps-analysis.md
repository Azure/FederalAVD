# FSLogix Storage Add-On Form vs. Host Pool Form: Configuration Gaps

## Executive Summary

The FSLogix Storage add-on form and the Host Pool form serve different purposes:
- **Host Pool Form**: Complete end-to-end deployment (control plane, session hosts, FSLogix storage, monitoring, backup)
- **FSLogix Storage Add-On Form**: Standalone FSLogix storage deployment for existing host pools or future deployments

This analysis identifies functional gaps where the FSLogix add-on form lacks configuration options present in the Host Pool form's FSLogix storage section.

---

## Part 1: Intentional Scope Differences (Not Gaps)

These are features that don't appear in FSLogix add-on because they're outside its scope:

| Feature | Host Pool Form | FSLogix Add-On | Reason |
|---------|---|---|---|
| Session Host VM Size | ✓ | ✗ | Add-on doesn't deploy session hosts |
| Session Host Count | ✓ | ✗ | Add-on doesn't deploy session hosts |
| Host Pool Load Balancing | ✓ | ✗ | Add-on doesn't deploy host pool |
| Scaling Plan | ✓ | ✗ | Add-on doesn't deploy host pool |
| Desktop Application Groups | ✓ | ✗ | Add-on doesn't deploy host pool |
| Temp VM Size | ✓ (fixed via API) | ✓ | Configurable for storage setup |
| Backup for VM OS Disks | ✓ (Personal only) | ✗ | Only relevant for Personal host pools |

---

## Part 2: FSLogix Storage Configuration Gaps

### A. Backup and Recovery Configuration

**Host Pool Form** (operationsAndMonitoring.backup section):
- `Enable Recovery Services` (checkbox)
- `Use Existing Recovery Services Vault` (checkbox)
- `Recovery Services Vault Storage Redundancy` (dropdown: LRS, ZRS)
- `Backup Retention Days` (slider: 1-365 for Personal, 1-200 for Pooled Azure Files)
- `Recovery Services Vault` (resource selector for existing vault)

**FSLogix Add-On Form** (zeroTrust.operations section):
- `Recovery Services Vault` (resource selector only)
- `Azure Files Backup Policy Name` (textbox - only visible when vault is selected)

**Gap Analysis:**
The FSLogix add-on form provides no way to:
1. **Enable/disable backup** - assumes user always wants it if they select a vault
2. **Create a new vault** - only accepts existing vaults (unlike host pool which can create one)
3. **Control backup retention days** - no slider for Azure Files snapshot retention (1-200 days)
4. **Select vault redundancy** - no choice of LRS vs ZRS for new vaults

**Impact**: Users deploying standalone FSLogix storage cannot:
- Create a new backup vault if one doesn't exist
- Customize backup retention policy from the form (must be set post-deployment)
- Choose between LRS and ZRS redundancy for backup vault
- Easily determine if backup is enabled (no explicit toggle)

**Recommendation**: Add a "Backup Configuration" section similar to the host pool form with:
- `Enable Recovery Services` checkbox
- `Use Existing Recovery Services Vault` checkbox
- When creating new vault:
  - `Recovery Services Vault Storage Redundancy` dropdown (LRS/ZRS)
  - `Backup Retention Days` slider (1-200 for Azure Files)

---

### B. Virtual Machine Configuration Details

**Host Pool Form** (hosts.specs section):
- `Session Host Count` (slider)
- `Virtual Machine Size` (dropdown with vCPU/RAM info)
- Supports: Generic VMs, Confidential VMs, Hibernation-enabled VMs
- VM image source (Marketplace vs Gallery)
- Disk encryption options

**FSLogix Add-On Form** (deployment.deploymentVirtualMachineSize):
- Only `Temporary Deployment VM Size` (dropdown - read-only, 2 vCPU minimum)

**Gap Analysis:**
Not actually a gap - the FSLogix form only needs a temporary 2-vCPU VM for AD/Entra Kerberos setup. The form correctly filters to that minimum.

---

### C. Storage Configuration Options

#### 1. Azure Files Backup Policy

**Host Pool Form**: Uses `backupRetentionDays` parameter (template handles policy creation)

**FSLogix Add-On Form**: Exposes `fileSharePolicyName` (user must know policy naming conventions)

**Gap**: User must manually create or specify Azure Files backup policy; form doesn't provide a way to:
- Select from existing policies
- Create a new policy with desired retention
- Understand retention constraints (200-day max for Pooled)

**Recommendation**: Replace textbox with:
- Resource selector for existing backup policies
- Optional inline creation of new policy with retention slider (1-200)

---

#### 2. Share Name Configuration

**Host Pool Form**: None - share names are generated

**FSLogix Add-On Form**: None - share names are generated

**Status**: Consistent, no gap.

---

#### 3. Profile Container vs Office Container Size

**Host Pool Form**:
- `Profile Container Size (MB)`: textbox (default 30000)
- Separate sizes for:
  - `Azure NetApp Files Volume Size (GB)`: 100 GB default
  - `Azure Files Share Size (GB)`: 100 GB default

**FSLogix Add-On Form**:
- `Profile Container Size (MB)`: textbox (default 30000)
- `File Share or Volume Size (GB)`: textbox (default 100)
- No separate configuration for Profile vs Office container sizes

**Gap**: FSLogix add-on does NOT expose:
- Separate size for Office container (when `CloudCacheProfileOfficeContainer` or `ProfileOfficeContainer` is selected)
- Guidance on recommended sizes by container type

**Current Behavior**: Uses same size for both containers - may not be optimal since Office containers typically need more space.

**Recommendation**: When container type is `ProfileOfficeContainer` or `CloudCacheProfileOfficeContainer`, add:
- `Office Container Size (MB)`: textbox with default (e.g., 80000 or user-configurable)
- InfoBox explaining typical ratios (Profile:Office = 30GB:80GB)

---

#### 4. Azure Files vs Azure NetApp Files Naming

**Host Pool Form**: Advanced naming controls for:
- Storage account name prefix (Azure Files only)
- Private endpoint conventions
- NetApp account, pool, and volume naming (NetApp only)

**FSLogix Add-On Form**: Same advanced naming controls in tagsAndNaming section

**Status**: Consistent, no gap.

---

### D. Network Configuration Gaps

#### 1. Public Network Access Control

**Host Pool Form**: Via `permittedIPs` in privateNetworking section (editable grid)

**FSLogix Add-On Form**: Same (`permittedIPs` in privateNetworking section)

**Status**: Consistent, no gap.

---

#### 2. Private Endpoint DNS Integration

**Host Pool Form**: 
- `Enable Private DNS Integration` checkbox
- Selectors for Azure Files, Blob, Queue private DNS zones

**FSLogix Add-On Form**:
- Same controls in privateNetworking section

**Status**: Consistent, no gap.

---

### E. Identity and Access Control Gaps

#### 1. SMB Signing and Encryption

**Host Pool Form**: None - uses defaults (no form control)

**FSLogix Add-On Form**: 
- `Kerberos Encryption Type` dropdown (AES256 / RC4)

**Gap**: FSLogix add-on DOES have this, but hostpool form DOES NOT expose it as a form control.

**Recommendation**: Add to hostpool form's FSLogix storage section:
- `Kerberos Encryption Type` when using AD DS or Entra Kerberos-Hybrid

---

#### 2. Group Filtering by Identity Type

**Host Pool Form**: Uses raw Microsoft Entra ID group picker (no pre-filtering)

**FSLogix Add-On Form**: Filters based on identity solution:
- AD DS + Entra Hybrid: `queries=4194304` (both synced and cloud groups)
- Entra ID Kerberos: `queries=32` (cloud groups only)

**Gap**: Hostpool form does NOT filter groups by identity type - allows selecting incompatible groups (AD-only groups for Entra-joined).

**Recommendation**: Update hostpool form group picker to use same filtering as FSLogix add-on.

---

#### 3. Entra Kerberos Automation Identity

**Host Pool Form**: NOT PRESENT in user profiles form

**FSLogix Add-On Form**: Full configuration:
- `Automate Entra Kerberos Application Update Tasks` checkbox
- `Entra Kerberos Application Update Identity` resource selector

**Gap**: Hostpool form should expose this when `identitySolution` is Entra Kerberos

**Recommendation**: Add to hostpool form's FSLogix storage section:
- Checkbox for automating Entra Kerberos tasks
- Identity selector when enabled

---

### F. Encryption Key Management Gaps

#### 1. CMK Rotation Period

**Host Pool Form**: `keyExpirationInDays` slider (30-180 days)

**FSLogix Add-On Form**: Same slider in keyManagement section

**Status**: Consistent, no gap.

---

#### 2. CMK for Recovery Services Vault

**Host Pool Form**: 
- For Personal host pools: `keyManagementRecoveryServicesVault` (Platform/Customer/CustomerManagedHSM)
- For Pooled host pools: No RSV created, but FSLogix storage RSV can use CMK

**FSLogix Add-On Form**: No CMK configuration for Recovery Services Vault (always platform-managed)

**Gap**: FSLogix add-on does NOT allow customer-managed encryption for Recovery Services Vault

**Impact**: Backup vault for FSLogix file shares is always platform-managed, even when customer specifies CMK for storage accounts.

**Recommendation**: Add to zeroTrust.operations section:
- When Recovery Services Vault is selected and CMK is enabled for storage:
  - Checkbox: `Use Customer-Managed Keys for Backup Vault`
  - If enabled, show Key Vault selector and key rotation slider

---

### G. Monitoring and Diagnostics Gaps

#### 1. Diagnostic Settings Configuration

**Host Pool Form**: Implicitly includes storage account via Log Analytics (operationsAndMonitoring.monitoring)

**FSLogix Add-On Form**: 
- `Log Analytics Workspace` resource selector (optional)
- But NO option to create diagnostics settings on storage account

**Gap**: FSLogix add-on accepts Log Analytics workspace but does NOT wire up diagnostics settings on:
- Storage accounts
- Recovery Services Vault
- Private endpoints

**Recommendation**: Add guidance or automation:
- InfoBox explaining that user must manually create diagnostics settings
- OR add a checkbox: `Create Diagnostics Settings` that wires LAW to storage metrics/logs

---

### H. Cloud Cache Configuration Gaps

#### 1. Remote Storage Input Validation

**Host Pool Form**: `CloudCacheRemoteStorageAccountResourceIds` (EditableGrid)

**FSLogix Add-On Form**: `remoteStorageAccountResourceIds` (EditableGrid)

**Gap**: Neither form validates that remote storage accounts:
- Exist and are accessible
- Use compatible storage service (Azure Files for Azure Files, NetApp for NetApp)
- Are in a different region (for DR)
- Have proper NTFS permissions already configured

**Status**: No validation in form layer - template-side validation occurs at deployment time.

---

## Part 3: Feature Parity Matrix

| Configuration Option | Host Pool Form | FSLogix Add-On | Gap? |
|---|:---:|:---:|---|
| **Backup & Recovery** | | | |
| Enable/Disable Recovery Services | ✓ | ✗ | **YES** - must select vault to enable |
| Create New RSV | ✓ | ✗ | **YES** - only accepts existing |
| RSV Storage Redundancy | ✓ | ✗ | **YES** |
| Backup Retention Days (Azure Files) | ✓ | ✗ | **YES** |
| RSV CMK Management | ✓ | ✗ | **YES** - only for Personal, FSLogix doesn't have it |
| Backup Policy Name | ✓ | ✓ | NO |
| **Storage Configuration** | | | |
| Profile Container Size | ✓ | ✓ | NO |
| Office Container Size (when selected) | ✗ | ✗ | **YES** - both missing |
| Share/Volume Size | ✓ | ✓ | NO |
| Storage Service Selection (Files/NetApp) | ✓ | ✓ | NO |
| Storage Redundancy (Azure Files) | ✓ | ✓ | NO |
| Container Type (Profile/Office/CloudCache) | ✓ | ✓ | NO |
| **Access Control** | | | |
| NTFS Least Privilege | ✓ | ✓ | NO |
| User Group Sharding | ✓ | ✓ | NO |
| User Group Selection | ✓ | ✓ | NO |
| Admin Group Access | ✓ | ✓ | NO |
| Group Filtering by Identity Type | ✗ | ✓ | **YES** - FSLogix is better |
| **Identity & Authentication** | | | |
| Identity Solution Selection | ✓ | ✓ | NO |
| Domain Credentials (AD DS) | ✓ | ✓ | NO |
| Entra Kerberos Automation | ✗ | ✓ | **YES** - Missing in hostpool form |
| Kerberos Encryption Type | ✗ | ✓ | **YES** - Missing in hostpool form |
| **Encryption** | | | |
| CMK for Storage | ✓ | ✓ | NO |
| CMK Key Rotation Period | ✓ | ✓ | NO |
| CMK for RSV | ✓ | ✗ | **YES** |
| **Networking** | | | |
| Private Endpoints | ✓ | ✓ | NO |
| Private Endpoint VNet Selection | ✓ | ✓ | NO |
| Private DNS Zone Integration | ✓ | ✓ | NO |
| Permitted IPs | ✓ | ✓ | NO |
| **Monitoring** | | | |
| Log Analytics Workspace Selection | ✓ | ✓ | NO |
| Diagnostic Settings Creation | ✗ | ✗ | **YES** - both missing explicit config |
| **Naming & Tags** | | | |
| Advanced Naming Overrides | ✓ | ✓ | NO |
| Tag Management | ✓ | ✓ | NO |
| **Azure NetApp Files Specific** | | | |
| Deployment Mode (CreateAll/Existing) | ✓ | ✓ | NO |
| NetApp Account Selection | ✓ | ✓ | NO |
| NetApp Capacity Pool Selection | ✓ | ✓ | NO |
| NetApp Delegated Subnet Selection | ✓ | ✓ | NO |
| Temp VM OU Path (NetApp) | ✓ | ✓ | NO |
| **Cloud Cache Specific** | | | |
| Remote Storage Account Input | ✓ | ✓ | NO |
| Remote NetApp Server Input | ✓ | ✓ | NO |

---

## Priority Recommendations

### High Priority (Breaking/Critical Parity Issues)

1. **Backup Retention Configuration** - FSLogix add-on should allow users to set 1-200 day retention for Azure Files snapshots
   - **Impact**: Users cannot customize backup strategy from add-on form
   - **Effort**: Medium (add slider control and pass to Bicep)

2. **Create New Recovery Services Vault** - FSLogix add-on only accepts existing vaults
   - **Impact**: Requires pre-existing vault, blocks standalone deployments
   - **Effort**: High (add vault creation logic, requires separate deployment or ARM API call)

3. **Entra Kerberos Automation Identity** - Host Pool form is missing this; FSLogix add-on has it
   - **Impact**: Host pool deployments cannot automate Entra Kerberos app registration
   - **Effort**: Medium (copy from FSLogix form, add identity filtering by region)

4. **Kerberos Encryption Type Selection** - Host Pool form missing this; FSLogix add-on exposes it
   - **Impact**: No way to choose RC4 vs AES256 in host pool deployment
   - **Effort**: Low (add dropdown to hostpool form)

### Medium Priority (Feature Gaps)

5. **Office Container Size Configuration** - Neither form allows separate sizing
   - **Impact**: Profile and Office containers use same size, may waste storage
   - **Effort**: Medium (add conditional textbox when Office container type selected)

6. **CMK for Recovery Services Vault** - FSLogix add-on doesn't support this
   - **Impact**: Backup vault cannot use customer-managed keys even when storage is CMK-protected
   - **Effort**: Medium (add CMK options to zeroTrust.operations section in fslogix form)

7. **Group Filtering by Identity Type** - Host Pool form missing this; FSLogix add-on has it
   - **Impact**: Host pool form allows selecting incompatible groups (e.g., AD-only groups for Entra identity)
   - **Effort**: Medium (update group picker queries in hostpool form)

8. **Backup Policy Selection/Creation** - Both forms only accept manual policy name
   - **Impact**: User must know correct policy name or manually create it
   - **Effort**: Medium (add resource selector + optional inline creation)

### Low Priority (Enhancements)

9. **Diagnostic Settings Explicit Configuration** - Both forms skip this; handled by template defaults
   - **Impact**: Users may not realize diagnostics are being configured
   - **Effort**: Low (add InfoBox explaining behavior)

10. **Remote Storage Validation** - Cloud Cache inputs lack validation
    - **Impact**: Invalid remote storage detected only at deployment time
    - **Effort**: Medium (add ARM API calls to validate existence and compatibility)

---

## Next Steps

1. **Align Authentication Options**: Copy Entra Kerberos automation and Kerberos encryption type from FSLogix form to Host Pool form
2. **Enhance Backup Configuration**: Add full backup settings (retention, vault redundancy) to FSLogix add-on form
3. **Add Office Container Sizing**: Support separate sizes when Office container is selected
4. **Improve Group Filtering**: Update both forms to filter groups by identity solution type

