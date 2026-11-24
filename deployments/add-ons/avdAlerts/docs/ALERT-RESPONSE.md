# AVD Alerts - Alert Response Playbook

This document describes every alert rule deployed by the AVD Alerts Add-On, including its
severity, trigger condition, what it means operationally, and the recommended response actions.

Alerts are grouped by category matching the add-on's enable/disable parameters.

---

## Severity Reference

| Sev | Label | Meaning |
| :---: | :---: | --- |
| 1 | Critical | Immediate user impact or imminent failure. Page on-call. |
| 2 | Warning | Degraded state that will become critical without intervention. Address within hours. |
| 3 | Informational | Notable event that warrants awareness but is not yet impacting users. |

---

## Host Pool Capacity (Pooled Pools Only)

> Controlled by `enableCapacityAlerts`. Applies to Pooled host pools only — capacity percentage is not meaningful for Personal (1:1) pools.

### AVD - Host Pool Capacity 50% — Sev 3

**Trigger:** Host pool is at 50-84% capacity (active sessions / available MaxSessions), sustained for 15 or more continuous minutes.  
**Meaning:** The pool is filling up. If load continues to grow, users may encounter performance degradation or be blocked from connecting.

**Response:**

- Review the host pool scaling plan — ensure scale-out rules will trigger before the 85% threshold.
- Verify all session hosts are in Available state (`WVDAgentHealthStatus`).
- If capacity is expected (morning logon storm), no action needed; monitor through the peak.
- If unexpected, investigate whether session hosts are draining or unhealthy.

---

### AVD - Host Pool Capacity 85% — Sev 2

**Trigger:** Host pool is at 85-94% capacity, sustained for 15 or more continuous minutes.  
**Meaning:** The pool is near-full. New user connections are at risk if growth continues.

**Response:**

- Verify the scaling plan is actively adding hosts. Check Azure Virtual Desktop → Scaling Plans → Activity.
- If autoscale is not responding, manually add session hosts via the host pool.
- Check for session hosts stuck in Unavailable state that are consuming MaxSessions quota without accepting connections.
- Review for disconnected sessions consuming slots — enforce session time limits via Group Policy.

---

### AVD - Host Pool Capacity 95% — Sev 1

**Trigger:** Host pool is at or above 95% capacity.  
**Meaning:** Critical. New connections will fail imminently. Users are about to be blocked.

**Response:**

- **Immediate:** Manually add session hosts to the host pool.
- Force-drain disconnected sessions that have been idle for more than 1 hour.
- If using a scaling plan, check for throttling or quota limits preventing scale-out.
- After resolution, review scaling plan configuration to ensure headroom is maintained.

---

## Host Pool Availability

> Controlled by `enableAvailabilityAlerts`.

### AVD - No Resources Available — Sev 1

**Trigger:** Zero healthy session hosts are available for new connections in the host pool.  
**Meaning:** Catastrophic outage. No users can connect to this host pool.

**Response:**

- Check host pool → Session Hosts for health status. Look for mass Unavailable state.
- Investigate the most recent health check failures: domain connectivity, FSLogix, SxS stack.
- Restart unavailable session hosts if they appear stuck.
- Verify the VNet has connectivity to domain controllers and the FSLogix storage account.
- Escalate if more than 2 hosts are affected simultaneously — may indicate a platform-level issue (check Service Health alerts).

---

### AVD - Host Health Check Failed — Sev 1

**Trigger:** A session host is in Available state but one or more dependent health checks are failing (domain reachability, FSLogix, SxS stack reverse connect, URL checks, IMDS).

**Meaning:** The host is accepting connections but underlying dependencies are degraded. User experience on this host may be impaired or fail at logon.

**Response:**

- The alert includes `SessionHostName` and `HealthCheckDesc` dimensions — identify which check is failing.
- **Domain unreachable:** Verify VNet/NSG rules allow the session host to reach domain controllers on ports 88, 389, 445, 636.
- **FSLogix:** Verify the FSLogix service is running on the host and the storage account is reachable.
- **SxSStackEncryption / WebRTCRedirector:** Usually resolved by restarting the `RDAgentBootLoader` service or reimaging the host.
- **URLCheck:** Verify AVD service endpoint connectivity (portal.azure.com, `*.wvd.microsoft.com`).
- **IMDSReachable:** Verify that IMDS (`169.254.169.254`) is not blocked by a UDR or NSG.

---

### AVD - Session Host Unhealthy — Sev 1

**Trigger:** A session host in any host pool (Pooled or Personal) has been in a non-Available, non-Shutdown state for 15 or more continuous minutes, and `AllowNewSessions` is `true` (not in admin drain mode or shutdown by a scaling plan). Newly deployed hosts are excluded until they have been visible in the health status data for at least 15 minutes.  
**Meaning:** The host is failing to serve connections but is not intentionally offline. In a Personal pool this directly impacts the assigned user. In a Pooled pool it reduces available capacity and may degrade experience for active users.

**Response:**

- Identify the affected VM and current `Status` from the alert dimensions.
- Check the health check details in the Portal (Host Pool → Session Hosts → VM → Health).
- Review `WVDAgentHealthStatus` in Log Analytics for the health check failure sequence leading up to the alert.
- Attempt to restart the VM. If it does not recover, reimage it (user data is in the FSLogix profile, not on the VM).
- For Personal pools, notify the assigned user of the outage and expected resolution time.

---

## Connections

> Controlled by `enableConnectionAlerts`.

### AVD - User Auth / Service Connection Failed — Sev 3

**Trigger:** The same user accumulates 3 or more connection failures at the gateway or broker level (no session host was assigned) in a 15-minute window.  
**Meaning:** The failure occurred before a session host was assigned — the broker could not authenticate the user or locate an available host. This points to an identity or service issue rather than a VM problem.

**Response:**

- Check the `UserName` dimension. If it is one user, investigate their account: expired password, MFA failure, Conditional Access policy block, or token expiry.
- If multiple users are affected simultaneously, check Azure Service Health for AVD service incidents and review the Action Group for concurrent Service Health alerts.
- Review `WVDErrors` for the `ErrorCodes` dimension to identify the specific error code (e.g., `ConnectionFailedNoHealthyRdshAvailable`, `ConnectionFailedClientDisconnect`).
- If correlated with Capacity or Session Host Unhealthy alerts, address those first — the broker may be failing to find a healthy host.

---

### AVD - Session Host Connection Failed — Sev 2

**Trigger:** A session host accumulates 3 or more post-assignment connection failures in a 15-minute window (a session host was assigned but the connection failed on the VM side).  
**Meaning:** The broker successfully assigned a host, but the RDP session could not be established to that specific VM. This points to a problem on the VM itself.

**Response:**

- Identify the affected `SessionHost` from the alert dimensions. Check `AffectedUsers` to understand the blast radius.
- Common causes: RDP stack crash (restart `TermService`), FSLogix profile load failure (check Event 23/52 on the VM), VM networking issue (NSG rule or route blocking reverse connect), or high memory/CPU causing session rejection.
- Review `WVDErrors` for the `ErrorCodes` dimension.
- If the VM is unresponsive, redeploy or reimage the session host.
- If correlated with Health Check alerts on the same host, address those first.

---

### AVD - Session Disconnected — Sev 3

**Trigger:** A user is currently in a Disconnected state and has been in that state for longer than the configured threshold (default: 8 hours; controlled by `disconnectedSessionAlertThresholdHours`). The alert fires while the session is still open — not retrospectively after it ends.
**Meaning:** Stale sessions consume host capacity and block scaling automation.

**Response:**

- Verify that Remote Desktop session timeout Group Policy settings are applied (Computer Configuration > Windows Components > Remote Desktop Services > Session Host > Session Time Limits):
  - `Set time limit for active but idle sessions` (`MaxIdleTime`) — recommend 3 hours. **By default this disconnects the session rather than logging it off.** The FSLogix profile VHD stays mounted and compaction does not run until the disconnected session timeout fires.
  - `Set time limit for disconnected sessions` (`MaxDisconnectionTime`) — recommend 3–4 hours. This **always** logs off the session when it expires regardless of the setting below, and will trigger FSLogix compaction.
  - `End session when time limits are reached` (`fResetBroken`) — when enabled, idle timeout logs off the session immediately instead of disconnecting, so FSLogix compaction runs sooner. Default is disabled (disconnect only); enable this to have compaction triggered at idle timeout.
- Manually log off the stale session if needed: Host Pool → User Sessions → Log Off.

---

### AVD - Slow Session Logon — Sev 3

**Trigger:** A user took longer than the configured threshold (default: 2 minutes; controlled by `slowLogonThresholdMinutes`) from connection start to a productive desktop.  
**Meaning:** Logon times above the threshold indicate a performance problem in the logon pipeline.

**Response:**

- Check the alert dimensions for the affected `SessionHostName` and `UserName`.
- Common causes in order of frequency:
  1. **FSLogix profile bloat** — profile VHD too large, taking too long to attach. Check profile size.
  2. **Storage latency** — slow attachment from Azure Files. Check storage latency alerts.
  3. **GPO processing** — excessive Group Policy objects or logon scripts. Use `gpresult /H` analysis.
  4. **Roaming profiles or folder redirection** — large `AppData` roaming folders.
  5. **AV scanning** — real-time scanning of the profile VHD mount point.
- Use the AVD Insights workbook (Diagnostics → Logon Time) for deeper logon time breakdown.

---

## Session Host Local Disk

> Controlled by `enableLocalDiskAlerts`. Disable if using ephemeral OS disks.

### AVD - VM Local Disk Space Low - 10pct — Sev 2

**Trigger:** A session host C: drive has 10% or less free space remaining.  
**Meaning:** The OS disk is filling up. When it reaches 0%, the session host will become unstable and AVD services may fail.

**Response:**

- Identify the affected `ComputerName` from the alert dimensions.
- Check what is consuming disk space. Common culprits:
  - Windows temp files (`%TEMP%`, `C:\Windows\Temp`)
  - Local FSLogix profile cache (if using `IsDynamic` VHDs without cloud cache)
  - Application logs or crash dumps
  - Windows Update cache
- Run `cleanmgr` or a disk cleanup script. For a fleet-wide issue, use Run Commands on VMs.
- Consider increasing the OS disk size or switching to ephemeral OS disks if this recurs.

---

### AVD - VM Local Disk Space Low - 5pct — Sev 1

**Trigger:** A session host C: drive has 5% or less free space.  
**Meaning:** Critical. The session host is at risk of becoming unresponsive imminently.

**Response:**

- **Immediate:** Put the host in drain mode (Host Pool → Session Hosts → Allow New Sessions: off).
- Connect to the host and free disk space immediately.
- If you cannot free enough space, drain active sessions and reimage the host.
- After resolution, investigate root cause to prevent recurrence.

---

## FSLogix Profile Alerts

> Controlled by `enableFslogixAlerts`.

### AVD - FSLogix Profile < 5% Free Space — Sev 2

**Trigger:** FSLogix Event ID 34 — a profile VHD has less than 5% free space.  
**Alert dimensions:** `UserName`, `ProfileID`, `SessionHostName`, `StorageAccount`

**Meaning:** The user's profile container is nearly full. If it reaches 0%, FSLogix will mount a temporary profile and the user will lose any work done in that session.

**Response:**

- Identify the affected user from `UserName` and the storage account from `StorageAccount`.
- Check the profile VHD size in the storage account file share.
- Options to resolve:
  1. **Increase VHD size:** FSLogix Admin → Profile Management → Expand VHD (online expansion supported).
  2. **User cleanup:** Work with the user to clean up large files in their profile (Downloads, AppData caches).
  3. **Exclusions:** Add exclusion paths for known large items (browser caches, Teams cache) in FSLogix configuration.
- Monitor the 2% alert to ensure the situation does not escalate before remediation.

---

### AVD - FSLogix Profile < 2% Free Space — Sev 1

**Trigger:** FSLogix Event ID 33 — a profile VHD has less than 2% free space.  
**Alert dimensions:** `UserName`, `ProfileID`, `SessionHostName`, `StorageAccount`

**Meaning:** Critical. The profile container is nearly full. The next significant write may cause FSLogix to fail over to a temporary profile — any work done in that session will be lost.

**Response:**

- **Immediate:** Contact the affected user to save all work and log off cleanly.
- Expand the profile VHD before they log back in.
- Review the `ProfileID` to locate the VHD file in the storage share.
- If the VHD cannot be expanded online, schedule a maintenance window.

---

### AVD - FSLogix Network Issue — Sev 1

**Trigger:** FSLogix Event ID 43 — the session host cannot reach the FSLogix profile storage account over the network.  
**Meaning:** Users on the affected host cannot load FSLogix profiles. They will receive temporary profiles and lose any work done in the session.

**Response:**

- Verify network connectivity from the session host to the storage account:
  - Private endpoint DNS resolution: `nslookup {storageaccount}.file.core.windows.net` should resolve to a private IP.
  - NSG rules allowing port 445 from the session host subnet to the storage private endpoint subnet.
- Check whether other hosts are affected — if yes, investigate NSG/UDR changes.
- Verify the storage account is healthy (check Storage alerts in this add-on).

---

### AVD - FSLogix Profile Disk Attach Failed — Sev 1

**Trigger:** FSLogix Event ID 52 or 40 — the profile VHD failed to attach at logon.  
**Meaning:** FSLogix could not mount the profile container when the user logged in. The user received a temporary profile and their changes will not be saved.

**Response:**

- Review the FSLogix log on the session host: `C:\ProgramData\FSLogix\Logs\Profile\`.
- Common causes:
  - **VHD locked by another process** — check if the VHD file has an `.lck` file alongside it in the share.
  - **Storage account reachability** — verify private endpoint connectivity.
  - **Corrupted VHD** — if the VHD is corrupt, restore from the most recent VSS snapshot.
  - **Permissions** — verify the session host's managed identity or computer account has Storage File Data SMB Share Contributor.

---

### AVD - FSLogix VHD Reattach Failed — Sev 2

**Trigger:** FSLogix Event ID 56 — a session host exhausted all VHD reattach retry attempts (>= 3 events for the same profile in 15 minutes) during a user reconnect.  
**Meaning:** The user's session already existed (they were disconnected, not logged off) and FSLogix could not remount the profile VHD when they reconnected. By default FSLogix retries 3 times at 10-second intervals (`ReAttachCount` / `ReAttachIntervalSeconds` registry values); the threshold of 3 events means at least one full retry cycle was exhausted.

The `RenderedDescription` dimension contains the full profile path — use this to identify the affected user (e.g., `\\storage\share\profilecontainers\jdoe_S-1-5-21-...`). The `EventCount` dimension shows how many retry events fired for that user in the window.

**Response:**

- Check storage account reachability from the session host at the time of the reconnect.
- Review `C:\ProgramData\FSLogix\Logs\Profile\` on the affected session host for the specific error code.
- Common causes:
  - **Transient storage connectivity blip** — if the VHD eventually reattached (user reconnect succeeded after a delay), this may be informational only.
  - **VHD detached by another process** — check whether a concurrent host VM failure or force-logoff released the VHD lock while the session was active.
  - **Persistent storage issue** — if `EventCount` is high or the same profile fires repeatedly across days, investigate Azure Files latency and private endpoint health.
- If the user is stuck with a broken session, place the host in drain mode and ask the user to log off completely and log back in.

---

### AVD - FSLogix Service Disabled — Sev 1

**Trigger:** FSLogix Event ID 60 — the FSLogix Profile service is set to Disabled.  
**Meaning:** FSLogix is not running on the session host. All users on this host receive temporary profiles.

**Response:**

- **Immediate:** Put the host in drain mode.
- Re-enable and start the FSLogix Profile service:

  ```powershell
  Set-Service -Name frxsvc -StartupType Automatic
  Start-Service -Name frxsvc
  ```

- Investigate how the service was disabled — this should not happen spontaneously. Check for:
  - GPO or ConfigMgr policy applying a conflicting setting.
  - Antivirus disabling the service.
  - Manual change by a local administrator.

---

### AVD - FSLogix Profile Disk Compaction Failed — Sev 2

**Trigger:** FSLogix Event ID 62 or 63 — profile disk compaction failed after it was attempted. Fires when 3 or more failure events are observed on the same session host within the 15-minute evaluation window (a single failed compaction attempt typically logs multiple events).  
**Meaning:** The profile VHD was marked for compaction (to reclaim free space) but the operation failed mid-process. The VHD will continue to grow without compaction.

**Response:**

- Check `C:\ProgramData\FSLogix\Logs\Profile\` for the specific compaction error.
- Common causes:
  - Insufficient free disk space on the session host's C: drive to hold a temporary compaction file.
  - The VHD was in use by another process during compaction.
- Ensure the session host has sufficient local disk space (at least 10% free).
- Compaction runs at logoff, not at disconnect. Ensure users log off rather than closing the RDP client window. If relying on session timeout policy, note that idle timeout (`MaxIdleTime`) **disconnects** by default — FSLogix compaction will not run until the disconnected session timeout (`MaxDisconnectionTime`) expires and forces a logoff. To have compaction run at idle timeout, enable `End session when time limits are reached` (`fResetBroken = 1`) in Group Policy.

---

### AVD - FSLogix Profile Disk In Use by Another VM — Sev 2

**Trigger:** FSLogix Event ID 51 — a profile VHD is already attached to another VM. Fires when 3 or more Event 51 occurrences are observed on the same session host within the 15-minute evaluation window, because FSLogix retries attachment multiple times per incident.  
**Meaning:** The same user profile is mounted on two different session hosts simultaneously. This should not happen in a correctly configured environment.

**Response:**

- Determine which session host currently holds the VHD by checking for a `.lck` file in the file share profile directory.
- If the other session is stale (the user is not connected there), log it off from the host pool.
- If the VHD has a `.lck` file but no active session holds it, delete the lock file after verifying no session is active.
- Investigate the root cause: users may be connecting to multiple host pools that share the same profile storage path.

---

### AVD - FSLogix Corrupted / Temp Profile — Sev 1

**Trigger:** FSLogix Event ID 28 — a user was loaded into a temporary profile because the profile VHD is corrupted or could not be mounted.  
**Alert dimensions:** `UserName`, `ProfileID`, `SessionHostName`, `StorageAccount`

**Meaning:** The user's profile VHD is corrupted. Any work done in the current session will be lost when they log off.

**Response:**

- **Notify the user immediately** — they are in a temporary profile. Advise them to save work to a non-profile location (OneDrive, SharePoint).
- Locate the profile VHD in the storage share using `ProfileID` and `StorageAccount`.
- Attempt VHD repair:
  1. Verify the VHD is not locked (check for `.lck` file).
  2. Mount the VHD offline and run `chkdsk /F`.
  3. If `chkdsk` cannot repair it, restore from the most recent Azure Files VSS snapshot.
- After repair, have the user log off and back on to verify the profile loads correctly.

---

### AVD - FSLogix Compaction Pre-Check Failed — Sev 3

**Trigger:** FSLogix Event ID 58 (host disk too full for compaction) or 61 (VHD in use at compaction time).  
**Meaning:** Compaction was scheduled but aborted before it started. Profile VHDs will grow unbounded over time without compaction.

**Response:**

- **EventID 58 (disk too full):** Free space on the session host's C: drive. Compaction requires temporary scratch space equal to the VHD size. See Local Disk alerts.
- **EventID 61 (VHD in use):** The session was still active (connected or disconnected) at compaction time — the profile VHD was still mounted. Compaction only runs when the session is fully logged off and the VHD is dismounted. Idle timeout (`MaxIdleTime`) **disconnects** by default without logging off, so the VHD remains mounted until `MaxDisconnectionTime` expires. To have compaction triggered by idle timeout, enable `End session when time limits are reached` (`fResetBroken = 1`) in Group Policy. The disconnected session timeout (`MaxDisconnectionTime`) always logs off and will trigger compaction when it fires.

---

## VM Performance

> Controlled by `enableCpuAlerts`, `enableMemoryAlerts`, `enableOsDiskAlerts`. Metric alerts scoped to the VM resource group.

### AVD - Session Host CPU > 85% — Sev 2

**Trigger:** Average CPU utilization on a session host exceeded 85% over a 15-minute window.  
**Meaning:** The host is under heavy CPU load. Users on this host may notice application sluggishness.

**Response:**

- Identify the affected VM from the alert resource metadata.
- Check which processes are consuming CPU (Process Explorer, `Get-Process`).
- Drain new connections to this host while investigating.
- If caused by a runaway process, kill it. If the load is legitimate (too many users), drain users and redistribute.
- Review the scaling plan to ensure load distribution is balanced across the pool.

---

### AVD - Session Host CPU > 95% — Sev 1

**Trigger:** Average CPU exceeded 95% over 15 minutes.  
**Meaning:** The host is saturated. Users are experiencing severe performance degradation.

**Response:**

- **Immediate:** Set AllowNewSessions = false on this host.
- If there are active sessions, gracefully log off or migrate users.
- Investigate and resolve the CPU cause. If a user process is responsible, terminate it.
- After remediation, re-enable the host and monitor.

---

### AVD - Available Memory < 2 GB — Sev 2 / < 1 GB — Sev 1

**Trigger:** Available memory dropped below 2 GB (Sev 2) or 1 GB (Sev 1).  
**Meaning:** The session host is running low on memory. Application crashes and paging to disk will follow.

**Response:**

- Drain new connections to the affected host.
- Identify high-memory processes. Common culprits: browser tabs, Teams, Office applications with large documents.
- For < 1 GB: log off users immediately to prevent crashes.
- Long-term: review the VM SKU for memory-to-user ratio. Add a memory-scaling trigger to the scaling plan.

---

### AVD - OS Disk Bandwidth > 85% / > 95% — Sev 2 / 1

**Trigger:** OS disk bandwidth consumed percentage at or above 85% (Sev 2) or 95% (Sev 1).  
**Meaning:** The session host is near or at its disk I/O limit. This causes I/O queuing and latency spikes for all users on the host.

**Response:**

- Check if FSLogix profile I/O is the driver — large profiles with heavy write activity.
- Check for antivirus scanning the OS disk during peak hours.
- Consider upgrading the OS disk tier (Standard HDD → Standard SSD → Premium SSD → Ultra Disk).
- Ephemeral OS disks eliminate OS disk bandwidth limits for read/write by using local NVMe — consider this if the VM SKU supports it.
- For Sev 1: drain the host immediately and upgrade before re-enabling.

---

## Storage (Azure Files)

> Controlled by `enableStorageLatencyAlerts`, `enableStorageAvailabilityAlerts`, `enableStorageThrottlingAlerts`. Applies when `storageAccountResourceIds` is provided.

### AVD - AzFiles Server Latency Warning / Critical — Sev 2 / 1

**Trigger:** Server-side latency on the storage account has deviated above a dynamically learned
baseline. The Sev 2 (Warning) rule uses medium sensitivity with 3 of 4 evaluation periods
exceeding the baseline; the Sev 1 (Critical) rule uses low sensitivity with all 4 of 4 periods
exceeding the baseline. Dynamic thresholds learn from historical patterns including peak vs.
off-peak, so idle-period spikes from background maintenance operations do not generate alerts.

> **Note:** Dynamic thresholds require approximately 3 days of metric history to establish a
> reliable baseline. On fresh storage accounts, expect a brief warm-up period during which
> the alert may be less accurate.

**Meaning:** The Azure Files service itself is responding slowly. Elevated server latency will
degrade FSLogix profile attach times and any I/O-intensive profile operations.

**Response:**

- Check Azure Status for Azure Files in the affected region.
- Review the share's provisioned IOPS vs. consumed IOPS — if IOPS-limited, increase provisioned capacity.
- Check for large concurrent profile loads (morning logon storm) and stagger logon times if possible.
- For Critical (Sev 1): open an Azure support ticket referencing the storage account and time window.

---

### AVD - AzFiles E2E Latency Warning / Critical — Sev 2 / 1

**Trigger:** End-to-end latency from session host to storage has deviated above a dynamically
learned baseline. Same dynamic threshold behavior as the Server Latency alert above — medium
sensitivity (3 of 4 periods) for Warning, low sensitivity (4 of 4 periods) for Critical.

**Meaning:** The total round-trip including the network path is elevated. E2E latency above the
baseline when server latency is normal implies a network path problem between session hosts and
the storage private endpoint.

**Response:**

- Compare against the Server Latency alerts. If server latency is at baseline but E2E is elevated,
  the issue is the network path, not the storage service.
- Verify the UDR on the session host subnet does not force-tunnel storage traffic through an on-premises appliance.
- Check NSG flow logs for dropped packets on port 445.
- Verify private DNS zone `privatelink.file.core.windows.net` (or cloud equivalent) resolves to the private endpoint IP.

---

### AVD - Storage Availability < 99% — Sev 1

**Trigger:** Storage account availability metric dropped below 99%.  
**Meaning:** The Azure Files service is experiencing errors for a meaningful percentage of requests. Profile loads and saves are failing.

**Response:**

- Check Azure Service Health for Azure Files incidents in the region.
- If no platform incident, investigate whether the share is full (check Share Capacity alerts).
- Check for throttling (see Storage Throttling alert below).
- Open an Azure support ticket if availability does not recover within 15 minutes and no platform issue is identified.

---

### AVD - Storage Throttling — Sev 2

**Trigger:** Azure Files file share IOPS are being throttled.  
**Meaning:** The share's provisioned IOPS limit has been reached. Requests are being queued or failed with throttle responses.

**Response:**

- Increase the file share's provisioned capacity. For Azure Files Premium, IOPS scale with provisioned capacity (1 IOPS per GiB, minimum 400 IOPS).
- Review whether the share is overprovisioned with users — reduce the concurrent session count or distribute profiles across multiple shares.
- Check whether a compaction operation or large file transfer is causing a burst.

---

### AVD - Azure Files Share Low Space - 15% Remaining / 5% Remaining — Sev 2 / 1

**Trigger:** An Azure Files share has 15% (Sev 2) or 5% (Sev 1) or less free space remaining.  
**Meaning:** The share is filling up. When it reaches 100%, new profile VHDs cannot be created and existing ones cannot grow.

**Response:**

- Identify the affected share from the alert dimensions.
- Increase the share's provisioned size: Storage Account → File Shares → {share} → Quota → Edit.
- Review whether old or orphaned VHDs exist in the share (profiles for users who have left).
- Long-term: enable the FSLogix Storage Quota Manager add-on to automate quota increases.

---

## Azure NetApp Files

> Controlled by `enableAnfCapacityAlerts`. Applies when `anfVolumeResourceIds` is provided.

### AVD - ANF Volume Capacity >= 85% — Sev 2 / >= 95% — Sev 1

**Trigger:** ANF volume consumed capacity reached 85% (Sev 2) or 95% (Sev 1).  
**Meaning:** The ANF volume is filling up. At 100%, profile VHDs cannot grow and FSLogix will fail.

**Response:**

- Increase the ANF volume size: NetApp Account → Capacity Pool → Volume → Resize.
- Check whether volume auto-grow is configured — ANF supports automatic capacity expansion.
- Review orphaned profile VHDs from departed users.

---

## Azure Service Health

> Controlled by `enableServiceHealthAlerts`. Subscription-scoped.

### AVD - ServiceHealth: Incident — Sev 1 (implied by activity log)

**Trigger:** An active Azure service incident affecting this subscription is detected.

**Response:**

- Open the Azure Service Health blade to review the incident scope and estimated resolution time.
- Communicate the incident to users if AVD-affecting services are listed (Azure Virtual Desktop, Microsoft Entra ID, Azure Files, Azure Automation).
- Check the [Azure Status page](https://azure.status.microsoft) for broader visibility.
- No operational action is required until Microsoft resolves the platform incident.

---

### AVD - ServiceHealth: Maintenance — Sev 2 (implied)

**Trigger:** Azure has scheduled planned maintenance affecting services in this subscription.

**Response:**

- Review the maintenance window and affected services in Azure Service Health.
- Notify users if maintenance falls during business hours.
- For maintenance affecting session host VMs, consider a proactive reimage or drain before the window.

---

### AVD - ServiceHealth: Advisory — Sev 3 (implied)

**Trigger:** An Azure health advisory has been issued (feature deprecations, required configuration changes, service behavior changes).

**Response:**

- Review the advisory text. Determine if any action is required for your AVD environment.
- Common advisories: TLS version requirements, storage API changes, networking endpoint changes.
- Track action items in your change management backlog.

---

### AVD - ServiceHealth: Security — Sev 1 (implied)

**Trigger:** A security advisory has been issued for services in this subscription.

**Response:**

- **Immediate review required.** Treat as a potential vulnerability disclosure.
- Review the advisory in Azure Service Health for affected services and recommended actions.
- If the advisory relates to session host operating system components, accelerate the image refresh cycle.
- Coordinate with your security team per your incident response process.
