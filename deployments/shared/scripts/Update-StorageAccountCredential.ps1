param (
    [string]$StorageAccountName,
    [string]$StorageAccountSuffix,
    [string]$StorageAccountKey
)

function Set-StorageAccountCredential {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TargetName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$UserName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Password
    )

    if (-not ('FederalAVD.StorageCredential' -as [type])) {
        Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace FederalAVD
{
    public static class StorageCredential
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct Credential
        {
            public uint Flags;
            public uint Type;
            public string TargetName;
            public string Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public uint CredentialBlobSize;
            public IntPtr CredentialBlob;
            public uint Persist;
            public uint AttributeCount;
            public IntPtr Attributes;
            public string TargetAlias;
            public string UserName;
        }

        [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CredWrite(ref Credential credential, uint flags);

        public static void Write(string targetName, string userName, string password)
        {
            if (String.IsNullOrEmpty(targetName) || String.IsNullOrEmpty(userName) || String.IsNullOrEmpty(password))
                throw new ArgumentException("Credential target, user name and password must not be empty.");
            if (password.Length > 1280)
                throw new ArgumentException("Credential password exceeds the Windows credential size limit.");

            IntPtr passwordBuffer = Marshal.StringToCoTaskMemUni(password);
            try
            {
                Credential credential = new Credential();
                credential.Type = 2; // CRED_TYPE_DOMAIN_PASSWORD: used by SMB authentication.
                credential.TargetName = targetName;
                credential.UserName = userName;
                credential.CredentialBlobSize = (uint)(password.Length * 2);
                credential.CredentialBlob = passwordBuffer;
                credential.Persist = 2; // CRED_PERSIST_LOCAL_MACHINE: same identity, across logon sessions.

                if (!CredWrite(ref credential, 0))
                {
                    int error = Marshal.GetLastWin32Error();
                    throw new Win32Exception(error, "Writing the storage credential failed (Win32 error " + error + ").");
                }
            }
            finally
            {
                Marshal.ZeroFreeCoTaskMemUnicode(passwordBuffer);
            }
        }
    }
}
'@
    }

    [FederalAVD.StorageCredential]::Write($TargetName, $UserName, $Password)
}

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($StorageAccountName) -or
    [string]::IsNullOrWhiteSpace($StorageAccountSuffix) -or
    [string]::IsNullOrWhiteSpace($StorageAccountKey)) {
    throw 'Storage account name, suffix and key are required.'
}

# Preserve the existing credential-storage policy setup before writing the credential.
# Effective domain/MDM policy and restart requirements must also permit credential storage.
$seceditInf = Join-Path -Path $env:TEMP -ChildPath 'avd-disable-domain-creds.inf'
$seceditDb  = Join-Path -Path $env:TEMP -ChildPath 'avd-disable-domain-creds.sdb'
$seceditLog = Join-Path -Path $env:TEMP -ChildPath 'avd-disable-domain-creds.log'
$infLines = @(
    '[Unicode]'
    'Unicode=yes'
    '[Version]'
    'signature="$CHICAGO$"'
    'Revision=1'
    '[Registry Values]'
    'MACHINE\System\CurrentControlSet\Control\Lsa\DisableDomainCreds=4,0'
)
[System.IO.File]::WriteAllLines($seceditInf, $infLines, [System.Text.Encoding]::Unicode)
$secedit = Start-Process -FilePath 'secedit.exe' `
    -ArgumentList "/configure /cfg `"$seceditInf`" /db `"$seceditDb`" /log `"$seceditLog`" /quiet" `
    -Wait -PassThru -NoNewWindow
if ($secedit.ExitCode -ne 0) {
    throw "Credential-storage policy configuration failed with exit code $($secedit.ExitCode). Review '$seceditLog'."
}
Remove-Item -Path $seceditInf, $seceditDb, $seceditLog -Force -ErrorAction SilentlyContinue

Set-StorageAccountCredential -TargetName "$StorageAccountName.file.$StorageAccountSuffix" `
    -UserName "localhost\$StorageAccountName" -Password $StorageAccountKey
Write-Output "Updated the storage credential for '$StorageAccountName.file.$StorageAccountSuffix'."
