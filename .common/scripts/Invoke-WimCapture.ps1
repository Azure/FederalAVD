param(
    [string]$BlobStorageSuffix = 'core.windows.net',
    [string]$WimBlobUri = '',
    [string]$UserAssignedIdentityClientId = ''
)

$ErrorActionPreference = 'Stop'
$Name = 'Invoke-WimCapture'
$LogFile = "$env:SystemRoot\Logs\$Name.log"
$WimStagingDir = 'C:\WimCapture'
$WimPath = "$WimStagingDir\image.wim"

function Write-Log {
    param([string]$Message)
    $Entry = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')] $Message"
    Add-Content -Path $LogFile -Value $Entry -ErrorAction SilentlyContinue
    Write-Output $Entry
}

# Uploads a local file to Azure Blob Storage as a block blob using the REST API.
# Uses HttpWebRequest directly so binary data is transmitted without encoding.
function Send-BlockBlob {
    param(
        [string]$FilePath,
        [string]$BlobUri,
        [string]$BearerToken,
        [int]$BlockSizeMB = 64
    )

    $BlockSize  = $BlockSizeMB * 1MB
    $ApiVersion = '2020-04-08'
    $BlockIds   = [System.Collections.Generic.List[string]]::new()
    $Stream     = [System.IO.File]::OpenRead($FilePath)
    $Buffer     = New-Object byte[] $BlockSize
    $BlockIndex = 0
    $TotalBytes = (Get-Item $FilePath).Length

    try {
        while (($Read = $Stream.Read($Buffer, 0, $BlockSize)) -gt 0) {
            # Block ID must be base64 and the same length for every block.
            $BlockId = [Convert]::ToBase64String(
                [System.Text.Encoding]::ASCII.GetBytes($BlockIndex.ToString('D8'))
            )
            $BlockIds.Add($BlockId)

            # Copy only the bytes that were actually read (last block may be smaller).
            $Chunk = New-Object byte[] $Read
            [System.Array]::Copy($Buffer, $Chunk, $Read)

            # PUT the block via HttpWebRequest for reliable binary transmission.
            $PutUri = "${BlobUri}?comp=block&blockid=$([Uri]::EscapeDataString($BlockId))"
            $Req = [System.Net.WebRequest]::Create($PutUri)
            $Req.Method        = 'PUT'
            $Req.ContentType   = 'application/octet-stream'
            $Req.ContentLength = $Read
            $Req.Headers.Add('Authorization', "Bearer $BearerToken")
            $Req.Headers.Add('x-ms-version', $ApiVersion)
            $Rs = $Req.GetRequestStream()
            $Rs.Write($Chunk, 0, $Read)
            $Rs.Flush()
            $Rs.Dispose()
            $Resp = $Req.GetResponse()
            $Resp.Dispose()

            $BlockIndex++
            $UploadedMB = [math]::Round(($BlockIndex * $BlockSizeMB), 0)
            $TotalMB    = [math]::Round($TotalBytes / 1MB, 0)
            Write-Log "  Block $BlockIndex uploaded ($UploadedMB / $TotalMB MB)"
        }

        # Commit the block list so Azure assembles the final blob.
        $XmlBlocks  = ($BlockIds | ForEach-Object { "<Latest>$_</Latest>" }) -join ''
        $XmlBody    = "<?xml version=`"1.0`" encoding=`"utf-8`"?><BlockList>$XmlBlocks</BlockList>"
        $XmlBytes   = [System.Text.Encoding]::UTF8.GetBytes($XmlBody)
        $CommitUri  = "${BlobUri}?comp=blocklist"
        $CommitReq  = [System.Net.WebRequest]::Create($CommitUri)
        $CommitReq.Method        = 'PUT'
        $CommitReq.ContentType   = 'application/xml'
        $CommitReq.ContentLength = $XmlBytes.Length
        $CommitReq.Headers.Add('Authorization', "Bearer $BearerToken")
        $CommitReq.Headers.Add('x-ms-version', $ApiVersion)
        $CommitReq.Headers.Add('x-ms-blob-content-type', 'application/octet-stream')
        $CommitRs   = $CommitReq.GetRequestStream()
        $CommitRs.Write($XmlBytes, 0, $XmlBytes.Length)
        $CommitRs.Flush()
        $CommitRs.Dispose()
        $CommitResp = $CommitReq.GetResponse()
        $CommitResp.Dispose()

        Write-Log "Block list committed. $BlockIndex block(s), $([math]::Round($TotalBytes / 1MB, 1)) MB total."
    }
    finally {
        $Stream.Dispose()
    }
}

try {
    Write-Log "Starting '$Name' script."
    Write-Log "WimBlobUri: $(if ($WimBlobUri) { $WimBlobUri } else { '(none - local capture only)' })"

    # Create a dedicated staging directory for the WIM.
    # This directory is always deleted in the finally block so it is never
    # present on the OS disk when Generalize-Vm.ps1 deallocates the VM and
    # the image is captured into the Compute Gallery.
    if (Test-Path $WimStagingDir) {
        Remove-Item -Path $WimStagingDir -Recurse -Force
        Write-Log "Removed previous staging directory '$WimStagingDir'."
    }
    New-Item -Path $WimStagingDir -ItemType Directory -Force | Out-Null
    Write-Log "Created staging directory '$WimStagingDir'."

    # Capture the OS volume using DISM.
    # Runs against the live volume (VSS snapshot); captures C:\ as a generalized WIM
    # suitable for MDT / SCCM / Intune / Azure Local deployment.
    # /Compress:max trades build time for a smaller WIM; typical output is 8-15 GB
    # for a fully customized Windows 11 AVD image.
    Write-Log "Capturing C:\ to '$WimPath' (dism /Capture-Image /Compress:max)..."
    Write-Log "DISM log: $env:SystemRoot\Logs\DISM\dism.log"
    $DismArgs = "/Capture-Image /ImageFile:`"$WimPath`" /CaptureDir:C:\ /Name:`"FederalAVD Golden Image`" /Compress:max"
    $Dism     = Start-Process -FilePath 'dism.exe' -ArgumentList $DismArgs -PassThru -Wait
    if ($Dism.ExitCode -ne 0) {
        throw "DISM /Capture-Image exited with code $($Dism.ExitCode). See '$env:SystemRoot\Logs\DISM\dism.log'."
    }

    $WimSizeMB = [math]::Round((Get-Item $WimPath).Length / 1MB, 1)
    Write-Log "Capture complete. WIM size: $WimSizeMB MB."

    if (-not [string]::IsNullOrEmpty($WimBlobUri)) {
        # Obtain an Azure AD token for Storage via the VM's user-assigned managed identity.
        Write-Log "Acquiring managed identity token (client: $UserAssignedIdentityClientId)..."
        $TokenUri = "http://169.254.169.254/metadata/identity/oauth2/token" `
                  + "?api-version=2018-02-01" `
                  + "&resource=https://storage.$BlobStorageSuffix/" `
                  + "&client_id=$UserAssignedIdentityClientId"
        $Token = (Invoke-RestMethod -Uri $TokenUri -Headers @{Metadata = 'true'} -ErrorAction Stop).access_token
        Write-Log "Token acquired."

        Write-Log "Uploading WIM to blob storage..."
        Send-BlockBlob -FilePath $WimPath -BlobUri $WimBlobUri -BearerToken $Token

        Write-Log "Upload complete. Removing local WIM..."
        Remove-Item -Path $WimPath -Force
        Write-Log "Local WIM removed."
    }
    else {
        Write-Log "WimBlobUri not set. WIM left at '$WimPath' for manual retrieval."
    }

    Write-Log "Completed '$Name' script."
}
catch {
    Write-Log "FATAL: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    if ($_.Exception.InnerException) { Write-Log "Inner exception: $($_.Exception.InnerException.Message)" }
    Write-Log $_.ScriptStackTrace
    Exit 1
}
finally {
    # Always remove the staging directory so it is never baked into the
    # Compute Gallery image, regardless of whether the script succeeded or failed.
    if (Test-Path $WimStagingDir) {
        Remove-Item -Path $WimStagingDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Staging directory '$WimStagingDir' removed."
    }
}
