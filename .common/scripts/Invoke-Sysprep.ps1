$ErrorActionPreference = 'Stop'
$LogFile = "$env:SystemRoot\Logs\Invoke-Sysprep.log"

function Write-Log {
    param([string]$Message)
    $Entry = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')] $Message"
    Add-Content -Path $LogFile -Value $Entry -ErrorAction SilentlyContinue
    Write-Output $Entry
}

try {
    Write-Log "Starting sysprep script"
    $Services = 'RdAgent', 'WindowsTelemetryService', 'WindowsAzureGuestAgent'
    ForEach ($Service in $Services) {
        Write-Log "Checking for service '$Service' and waiting for it to start if it exists."
        If (Get-Service | Where-Object { $_.Name -eq $Service }) {
            Write-Log "Found Service '$Service'. Checking to see if it is running."
            If ((Get-Service -Name $Service).Status -eq 'Running') {
                Write-Log "'$Service' is already running."
            }
            Else {
                $ServiceTimeout = (Get-Date).AddMinutes(5)
                While ((Get-Service -Name $Service).Status -ne 'Running') {
                    Write-Log "Waiting for $Service to start."
                    If ((Get-Date) -ge $ServiceTimeout) {
                        Write-Log "Timed out waiting for service '$Service' to start. Continuing."
                        Break
                    }
                    Start-Sleep -Seconds 5
                }
            }
        }
        Else {
            Write-Log "Service $Service not found."
        }
    }

    $Files = "$env:SystemRoot\System32\sysprep\unattend.xml", "$env:SystemRoot\Panther\Unattend.xml"
    Write-Log "Checking for cached unattend files."
    ForEach ($File in $Files) {
        if (Test-Path -Path $File) {
            Write-Log "Removing $File"
            Remove-Item $File -Force
        }
    }

    $AdminAccount = Get-LocalUser | Where-Object { $_.SID -like '*-500' }
    If (-Not $AdminAccount.Enabled) {
        Write-Log "Enabling local administrator account '$($AdminAccount.Name)'."
        Enable-LocalUser -Name $AdminAccount.Name
    }

    # Wait for CBS (Component Based Servicing) to settle. CBS still churning after a post-update reboot will cause sysprep to fail.
    Write-Log "Checking CBS (Component Based Servicing) status before running sysprep."
    $CbsTimeout = (Get-Date).AddMinutes(30)
    do {
        $CbsBusy = $false

        # A reboot is still pending - sysprep will fail in this state. Cannot auto-recover from a run command on the image VM.
        $RebootPendingPaths = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress'
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        )
        foreach ($Path in $RebootPendingPaths) {
            if (Test-Path $Path) {
                Write-Log "A reboot is required before sysprep can run ($Path exists). Add an additional restart step in the orchestration after Windows Updates and re-deploy."
                Exit 1
            }
        }

        # TrustedInstaller running means CBS is actively applying packages
        if ((Get-Service -Name TrustedInstaller -ErrorAction SilentlyContinue).Status -eq 'Running') {
            Write-Log "TrustedInstaller service is running. CBS is still processing. Waiting..."
            $CbsBusy = $true
        }

        # Pending exclusive CBS sessions indicate packages are queued
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\SessionsPending') {
            $Exclusive = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\SessionsPending' -ErrorAction SilentlyContinue).Exclusive
            if ($Exclusive -gt 0) {
                Write-Log "CBS has $Exclusive pending exclusive session(s). Waiting..."
                $CbsBusy = $true
            }
        }

        if ($CbsBusy) {
            if ((Get-Date) -ge $CbsTimeout) {
                Write-Log "Timed out waiting for CBS to settle after 30 minutes. Proceeding with sysprep."
                break
            }
            Start-Sleep -Seconds 30
        }
    } while ($CbsBusy)
    Write-Log "CBS check complete. Proceeding with sysprep."

    # Clear any existing Sysprep Panther logs so the captured output only reflects
    # this run. Sysprep appends to setupact.log rather than replacing it, so without
    # this the captured log would contain output from prior sysprep invocations
    # (e.g. from FSLogix or Office customizations) mixed with the current run.
    $PantherDir = "$env:SystemRoot\System32\Sysprep\Panther"
    if (Test-Path $PantherDir) {
        Write-Log "Clearing previous Sysprep Panther logs from '$PantherDir'."
        Remove-Item -Path "$PantherDir\*.log" -Force -ErrorAction SilentlyContinue
    }

    # The Task Scheduler CIM provider's internal credential validation rejects the built-in
    # administrator account (SID-500) under VDI-optimized LGPO policy state with 0x8007052e
    # ("The user name or password is incorrect") even though the credentials are correct and
    # direct LogonUser(BATCH) with the same credentials succeeds. This is a false-positive in
    # the CIM provider's credential check path that only affects SID-500.
    #
    # Fix: create a short-lived throwaway local administrator account, register the sysprep
    # task under that account (CIM provider accepts non-SID-500 credentials without issue),
    # then remove the account immediately after sysprep completes.
    $TempUser = 'sysprep_svc'
    $TaskName = 'RunSysprep'

    # Remove any leftover account from a prior failed run
    Remove-LocalUser -Name $TempUser -ErrorAction SilentlyContinue

    # Generate a strong random password (in-memory only; discarded after task registration)
    $chars     = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*'
    $rng       = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes     = New-Object byte[] 32
    $rng.GetBytes($bytes)
    $TempChars = $bytes | ForEach-Object { $chars[$_ % $chars.Length] }
    $TempPw    = 'Aa1!' + (-join $TempChars[0..19])   # 24 chars, satisfies complexity requirements
    $rng.Dispose()

    Write-Log "Creating throwaway local admin account '$TempUser' for sysprep task registration."
    $SecTempPw = ConvertTo-SecureString -String $TempPw -AsPlainText -Force
    New-LocalUser -Name $TempUser -Password $SecTempPw `
        -PasswordNeverExpires -UserMayNotChangePassword `
        -AccountNeverExpires `
        -Description 'Temp sysprep task account; auto-removed' | Out-Null
    Add-LocalGroupMember -Group 'Administrators' -Member $TempUser
    Write-Log "Account '$TempUser' created and added to Administrators."

    $Action  = New-ScheduledTaskAction -Execute 'C:\Windows\System32\Sysprep\sysprep.exe' `
                   -Argument '/oobe /generalize /quit /mode:vm'
    $Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddHours(24)  # Far-future fallback only; we start it explicitly below.

    Register-ScheduledTask -TaskName $TaskName `
        -Description 'Runs Sysprep (OOBE / Generalize / Quit / VM mode) as a throwaway admin account.' `
        -Action $Action -Trigger $Trigger `
        -User "$env:COMPUTERNAME\$TempUser" -Password $TempPw `
        -RunLevel Highest -Force | Out-Null

    If (-not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) {
        throw "Scheduled task '$TaskName' was not found after registration attempt."
    }
    Write-Log "Scheduled task '$TaskName' registered. Starting now."

    # Start the task immediately (do not wait for the far-future trigger)
    Start-ScheduledTask -TaskName $TaskName

    # -- Confirm the task actually started (transitions to Running) -------------
    # This is the critical check  - if sysprep.exe never launches (e.g. bad
    # credentials, locked account, binary missing) we catch it here rather than
    # timing out 30 minutes later.
    Write-Log "Waiting for sysprep task to enter Running state (timeout: 2 minutes)."
    $StartTimeout = (Get-Date).AddMinutes(2)
    do {
        Start-Sleep -Seconds 5
        $taskState = (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue).State
        if ($taskState -eq 'Running') {
            Write-Log "Sysprep task is Running. Sysprep has started."
            break
        }
        if ((Get-Date) -ge $StartTimeout) {
            $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
            throw "Sysprep task failed to enter Running state within 2 minutes. " +
                  "Task state: '$taskState'. Last result: 0x$('{0:X8}' -f $info.LastTaskResult)."
        }
        Write-Log "Task state: '$taskState'  - waiting for Running..."
    } while ($true)

    # -- Wait for sysprep to complete (task returns to Ready) -------------------
    Write-Log "Sysprep is running. Waiting for completion (timeout: 30 minutes)."
    $SysprepTimeout = (Get-Date).AddMinutes(30)
    do {
        Start-Sleep -Seconds 15
        $taskState = (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue).State
        if ($taskState -eq 'Ready') {
            Write-Log "Sysprep task has completed."
            break
        }
        if ((Get-Date) -ge $SysprepTimeout) {
            throw "Timed out after 30 minutes waiting for sysprep to complete. Task state: '$taskState'."
        }
        Write-Log "Task state: '$taskState'  - sysprep still running..."
    } while ($true)

    $taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName
    Write-Log "Sysprep exit code: 0x$('{0:X8}' -f $taskInfo.LastTaskResult) ($($taskInfo.LastTaskResult))"

    # -- Capture Panther logs into Run Command output (goes to outputBlobUri) ---
    # Writing to stdout here means the content lands in the same blob that ARM
    # already captures for this Run Command  - no separate upload needed.
    foreach ($logFile in @(
        "$env:SystemRoot\System32\Sysprep\Panther\setupact.log",
        "$env:SystemRoot\System32\Sysprep\Panther\setuperr.log"
    )) {
        if (Test-Path $logFile) {
            Write-Output ""
            Write-Log "=== BEGIN $(Split-Path $logFile -Leaf) ==="
            Get-Content $logFile | ForEach-Object { Write-Output $_ }
            Write-Log "=== END $(Split-Path $logFile -Leaf) ==="
        } else {
            Write-Log "Log file not found: $logFile"
        }
    }

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Log "Scheduled task '$TaskName' deregistered."

    # Remove the throwaway account. Sysprep /generalize removes user profiles from the
    # image file system but does NOT remove the SAM account entry - do that explicitly.
    # Attempt a WMI profile delete first (belt-and-suspenders; the profile may already be
    # gone if sysprep's generalize pass cleaned it up before we reach this point).
    $TempUserSid = (Get-LocalUser -Name $TempUser -ErrorAction SilentlyContinue).SID.Value
    if ($TempUserSid) {
        $wmiProfile = Get-WmiObject -Class Win32_UserProfile -Filter "SID='$TempUserSid'" -ErrorAction SilentlyContinue
        if ($wmiProfile) {
            try {
                $wmiProfile.Delete()
                Write-Log "User profile for '$TempUser' deleted via WMI."
            } catch {
                # Delete() fails when sysprep /generalize already removed the profile directory,
                # leaving a stale Win32_UserProfile entry. Fall back to direct registry cleanup.
                Write-Log "WMI profile Delete() failed for '$TempUser' ($($_.Exception.Message)) - removing ProfileList registry key directly."
                $profileListKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$TempUserSid"
                if (Test-Path $profileListKey) {
                    Remove-Item -Path $profileListKey -Force -ErrorAction SilentlyContinue
                    Write-Log "ProfileList registry key removed for SID $TempUserSid."
                }
                # Remove the profile directory if sysprep left it behind
                if ($null -ne $wmiProfile.LocalPath -and (Test-Path $wmiProfile.LocalPath)) {
                    Remove-Item -Path $wmiProfile.LocalPath -Recurse -Force -ErrorAction SilentlyContinue
                    Write-Log "Profile directory '$($wmiProfile.LocalPath)' removed."
                }
            }
        } else {
            Write-Log "No WMI profile found for '$TempUser' (SID: $TempUserSid) - already removed by sysprep."
        }
    }
    Remove-LocalUser -Name $TempUser -ErrorAction SilentlyContinue
    Write-Log "Throwaway account '$TempUser' removed."

    # Fail the deployment with full log context if sysprep returned non-zero
    if ($taskInfo.LastTaskResult -ne 0) {
        throw "Sysprep failed with exit code 0x$('{0:X8}' -f $taskInfo.LastTaskResult). " +
              "Review the Panther log output above for details."
    }

    Write-Log "Sysprep completed successfully. Script exiting - Generalize-Vm.ps1 will deallocate and generalize the VM."
}
catch {
    Write-Log "FATAL: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    If ($_.Exception.InnerException) { Write-Log "Inner exception: $($_.Exception.InnerException.Message)" }
    Write-Log $_.ScriptStackTrace
    Exit 1
}