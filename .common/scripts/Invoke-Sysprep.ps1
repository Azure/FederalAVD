param (
    [string]$AdminPassword
)

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
    # (e.g. from FSLogix, Office, or WDOT customizations) mixed with the current run.
    $PantherDir = "$env:SystemRoot\System32\Sysprep\Panther"
    if (Test-Path $PantherDir) {
        Write-Log "Clearing previous Sysprep Panther logs from '$PantherDir'."
        Remove-Item -Path "$PantherDir\*.log" -Force -ErrorAction SilentlyContinue
    }

    Write-Log "Launching sysprep as the local administrator account."

    # Launch sysprep as the named admin account via CreateProcessAsUser.
    # Register-ScheduledTask (CIM) and Schedule.Service (COM) both fail to validate
    # credentials in this environment with 'The user name or password is incorrect'
    # even when LogonUser(BATCH) succeeds directly. CreateProcessAsUser bypasses Task
    # Scheduler entirely: we obtain a user token via LogonUser and launch sysprep directly
    # under that token. Sysprep runs as the named admin user - not SYSTEM - which is the
    # Microsoft-supported path (running as SYSTEM skips AppX/XAML package registration,
    # causing black screen / explorer.exe failures after deployment).
    if (-not ([System.Management.Automation.PSTypeName]'SysprepLauncher').Type) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SysprepLauncher {
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool LogonUser(string username, string domain, string password,
        int logonType, int logonProvider, out IntPtr token);

    [DllImport("userenv.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool LoadUserProfile(IntPtr hToken, ref PROFILEINFO lpProfileInfo);

    [DllImport("userenv.dll", SetLastError=true)]
    public static extern bool UnloadUserProfile(IntPtr hToken, IntPtr hProfile);

    [DllImport("userenv.dll", SetLastError=true)]
    public static extern bool CreateEnvironmentBlock(out IntPtr lpEnvironment, IntPtr hToken, bool bInherit);

    [DllImport("userenv.dll", SetLastError=true)]
    public static extern bool DestroyEnvironmentBlock(IntPtr lpEnvironment);

    // lpCommandLine must be a mutable LPWSTR buffer - CreateProcessAsUserW writes into it.
    // Using StringBuilder instead of string ensures the marshaler allocates a writable buffer.
    // lpCurrentDirectory is IntPtr so we can pass an explicit NULL (IntPtr.Zero) without
    // PowerShell's $null->empty-string coercion.
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool CreateProcessAsUser(IntPtr hToken,
        string lpApplicationName, System.Text.StringBuilder lpCommandLine,
        IntPtr lpProcessAttributes, IntPtr lpThreadAttributes,
        bool bInheritHandles, uint dwCreationFlags,
        IntPtr lpEnvironment, IntPtr lpCurrentDirectory,
        ref STARTUPINFO lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);

    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct PROFILEINFO {
        public int dwSize;
        public int dwFlags;
        public string lpUserName;
        public string lpProfilePath, lpDefaultPath, lpServerName, lpPolicyPath;
        public IntPtr hProfile;
    }

    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct STARTUPINFO {
        public int cb;
        public string lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars,
                   dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION {
        public IntPtr hProcess, hThread;
        public int dwProcessId, dwThreadId;
    }
}
'@
    }

    # If FilterAdministratorToken=1 is set (e.g. by DoD STIG V-253357), LogonUser returns
    # a filtered (standard user) token even for the built-in Administrator (SID-500).
    # CreateProcessAsUser with a filtered token would launch sysprep without admin rights.
    # Clear the value before LogonUser so we get the full elevated token. The VM is about
    # to be sysprepped so this setting does not need to be restored.
    $uacPolicyPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $filterVal = (Get-ItemProperty -Path $uacPolicyPath -Name 'FilterAdministratorToken' -ErrorAction SilentlyContinue).FilterAdministratorToken
    if ($filterVal -eq 1) {
        Write-Log "FilterAdministratorToken=1 detected (STIG V-253357). Clearing temporarily so LogonUser returns the full elevated token."
        Set-ItemProperty -Path $uacPolicyPath -Name 'FilterAdministratorToken' -Value 0 -Type DWord -Force
    }

    Write-Log "Obtaining user token for '$($AdminAccount.Name)' via LogonUser."
    $UserToken = [IntPtr]::Zero
    # LOGON32_LOGON_BATCH=4, LOGON32_PROVIDER_DEFAULT=0
    $LogonOk = [SysprepLauncher]::LogonUser($AdminAccount.Name, '.', $AdminPassword, 4, 0, [ref]$UserToken)
    if (-not $LogonOk) {
        $le = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "LogonUser failed with Win32 error $le. Cannot obtain user token to launch sysprep."
    }

    # Load the user profile so sysprep can perform AppX/XAML package registration.
    # Without a loaded profile hive, sysprep skips AppX registration for XAML packages
    # (MicrosoftWindows.Client.CBS, Microsoft.UI.Xaml.CBS, MicrosoftWindows.Client.Core)
    # resulting in black screen / explorer.exe crashes on first sign-in after deployment.
    # See: https://learn.microsoft.com/troubleshoot/windows-client/setup-upgrade-and-drivers/sysprep-as-system-windows-11
    Write-Log "Loading user profile for '$($AdminAccount.Name)' via LoadUserProfile."
    $ProfInfo = New-Object SysprepLauncher+PROFILEINFO
    $ProfInfo.dwSize = [Runtime.InteropServices.Marshal]::SizeOf($ProfInfo)
    $ProfInfo.dwFlags = 1  # PI_NOUI: suppress error dialogs in non-interactive session 0
    $ProfInfo.lpUserName = $AdminAccount.Name
    $ProfileLoaded = [SysprepLauncher]::LoadUserProfile($UserToken, [ref]$ProfInfo)
    if (-not $ProfileLoaded) {
        [SysprepLauncher]::CloseHandle($UserToken) | Out-Null
        $le = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "LoadUserProfile failed with Win32 error $le."
    }

    Write-Log "Launching sysprep as '$($AdminAccount.Name)' via CreateProcessAsUser."
    $SysprepExe = "$env:SystemRoot\System32\Sysprep\sysprep.exe"
    $Si = New-Object SysprepLauncher+STARTUPINFO
    $Si.cb = [Runtime.InteropServices.Marshal]::SizeOf($Si)
    $Pi = New-Object SysprepLauncher+PROCESS_INFORMATION

    # Build a user environment block from the token. Passing IntPtr.Zero for the environment
    # inherits the SYSTEM environment which lacks user-specific variables, causing Win32
    # error 203 (ERROR_ENVVAR_NOT_FOUND). CREATE_UNICODE_ENVIRONMENT=0x400 is required
    # when using an environment block from CreateEnvironmentBlock.
    $EnvBlock = [IntPtr]::Zero
    $EnvOk = [SysprepLauncher]::CreateEnvironmentBlock([ref]$EnvBlock, $UserToken, $false)
    if (-not $EnvOk) {
        [SysprepLauncher]::UnloadUserProfile($UserToken, $ProfInfo.hProfile) | Out-Null
        [SysprepLauncher]::CloseHandle($UserToken) | Out-Null
        $le = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "CreateEnvironmentBlock failed with Win32 error $le."
    }

    Write-Log "Environment block pointer: 0x$($EnvBlock.ToString('X'))"
    Write-Log "Sysprep path: $SysprepExe"
    # StringBuilder ensures a writable native buffer as required by CreateProcessAsUserW.
    $CmdLine = New-Object System.Text.StringBuilder("$SysprepExe /oobe /generalize /quit /mode:vm")
    $CreateOk = [SysprepLauncher]::CreateProcessAsUser(
        $UserToken, $SysprepExe, $CmdLine,
        [IntPtr]::Zero, [IntPtr]::Zero, $false, 0x400,
        $EnvBlock, [IntPtr]::Zero, [ref]$Si, [ref]$Pi)

    # Capture error IMMEDIATELY before any other P/Invoke call overwrites GetLastError.
    # DestroyEnvironmentBlock is a P/Invoke call with SetLastError=true and will replace
    # the saved error if called before we read it.
    $CreateErr = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    [SysprepLauncher]::DestroyEnvironmentBlock($EnvBlock) | Out-Null

    if (-not $CreateOk) {
        [SysprepLauncher]::UnloadUserProfile($UserToken, $ProfInfo.hProfile) | Out-Null
        [SysprepLauncher]::CloseHandle($UserToken) | Out-Null
        throw "CreateProcessAsUser failed with Win32 error $CreateErr."
    }

    Write-Log "Sysprep process started (PID $($Pi.dwProcessId)). Waiting up to 30 minutes."
    $WaitResult = [SysprepLauncher]::WaitForSingleObject($Pi.hProcess, 1800000)

    $SysprepExitCode = [uint32]0
    [SysprepLauncher]::GetExitCodeProcess($Pi.hProcess, [ref]$SysprepExitCode) | Out-Null
    [SysprepLauncher]::CloseHandle($Pi.hProcess) | Out-Null
    [SysprepLauncher]::CloseHandle($Pi.hThread) | Out-Null
    Write-Log "Sysprep process handle closed. Exit code captured: 0x$('{0:X8}' -f $SysprepExitCode) ($SysprepExitCode)"

    # Unload the profile hive via the same API that loaded it. This is the clean path -
    # no reg unload, no ProfSvc reference count issues.
    [SysprepLauncher]::UnloadUserProfile($UserToken, $ProfInfo.hProfile) | Out-Null
    [SysprepLauncher]::CloseHandle($UserToken) | Out-Null
    Write-Log "User profile unloaded."

    if ($WaitResult -eq 0x102) {  # WAIT_TIMEOUT
        throw "Timed out after 30 minutes waiting for sysprep to complete."
    }

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

    # Fail the deployment with full log context if sysprep returned non-zero
    if ($SysprepExitCode -ne 0) {
        throw "Sysprep failed with exit code 0x$('{0:X8}' -f $SysprepExitCode). " +
              "Review the Panther log output above for details."
    }

    Write-Log "Sysprep completed successfully. Script exiting  - Generalize-Vm.ps1 will deallocate and generalize the VM."
}
catch {
    Write-Log "FATAL: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    If ($_.Exception.InnerException) { Write-Log "Inner exception: $($_.Exception.InnerException.Message)" }
    Write-Log $_.ScriptStackTrace
    Exit 1
}