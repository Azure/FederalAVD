<#
.SYNOPSIS
Compress Scripts and Executable files to a zip archive.

.DESCRIPTION
This cmdlet performs compression for all content of each subfolder of a specified source folder into a specified destination folder.

.PARAMETER SourceFolderPath
Specifies the location containing subfolders to be compressed.

.PARAMETER DestinationFolderPath
Specifies the location for the .zip files.

.PARAMETER CompressionLevel
Specifies how much compression to apply when creating the archive file. Fastest as default.

.PARAMETER Confirm
Will prompt user to confirm the action to create invisible commands

.PARAMETER WhatIf
Dry run of the script

.EXAMPLE
    Compress-SubFolderContents -SourceFolderPath "\\path\to\sourcefolder" -DestinationFolderPath "\\path\to\destinationfolder"

    Creates the "\\path\to\destinationfolder" if not existing
    For each subfolder in "\\path\to\sourcefolder" creates an archive with the fastest compression level named "subfolder.zip" in the "\\path\to\destinationfolder".
#>

function ConvertTo-LongSafePath {
    param([string] $Path)
    $trimmed = $Path.TrimEnd('\')

    # Already prefixed — return as-is to prevent double-prefixing
    if ($trimmed.StartsWith('\\?\')) {
        return $trimmed
    }

    if (-not [System.IO.Path]::IsPathRooted($trimmed)) {
        throw "ConvertTo-LongSafePath requires an absolute path. Received: '$trimmed'"
    }

    if ($trimmed.StartsWith('\\')) {
        # UNC path: \\server\share → \\?\UNC\server\share
        $uncBody = $trimmed.Substring(2)
        return "\\?\UNC\" + $uncBody
    } else {
        # Local path: C:\foo → \\?\C:\foo
        return "\\?\" + $trimmed
    }
}

function Remove-LongSafePrefix {
    <#
    .SYNOPSIS
    Strips any \\?\ or \\?\UNC\ prefix from a path so it can be used for
    relative-path substring math. Both the base path and child paths must be
    normalised through this function before Substring() calls are made,
    guaranteeing a consistent format regardless of how Get-ChildItem resolves
    long-safe roots on different PS versions / OS configurations.
    #>
    param([string] $Path)
    if ($Path.StartsWith('\\?\UNC\')) {
        return '\\' + $Path.Substring(8)   # \\?\UNC\server\share → \\server\share
    }
    if ($Path.StartsWith('\\?\')) {
        return $Path.Substring(4)           # \\?\C:\foo → C:\foo
    }
    return $Path
}

function Compress-SubFolderContents {

    [CmdletBinding(SupportsShouldProcess = $True)]
    param(
        [Parameter(
            Mandatory,
            HelpMessage = "Specifies the location containing subfolders to be compressed."
        )]
        [string] $SourceFolderPath,

        [Parameter(
            Mandatory,
            HelpMessage = "Specifies the location for the .zip files."
        )]
        [string] $DestinationFolderPath,

        [Parameter(
            Mandatory = $false,
            HelpMessage = "Specifies how much compression to apply when creating the archive file. Fastest as default."
        )]
        [ValidateSet("Optimal", "Fastest", "NoCompression")]
        [string] $CompressionLevel = "Fastest"
    )

    try {

        # Always call Add-Type unconditionally — it is idempotent and safe to
        # call even when the assembly is already loaded. The previous guard
        # (-not ([System.IO.Compression.ZipFile] -as [type])) was unreliable:
        # referencing the type literal throws if the assembly is not loaded,
        # so the condition itself would error before the Add-Type could run.
        Add-Type -AssemblyName System.IO.Compression.FileSystem

        # Map compression level string to enum once, outside the loop.
        # ValidateSet guarantees only valid values reach this switch.
        $compressionLevelEnum = switch ($CompressionLevel) {
            "Optimal"       { [System.IO.Compression.CompressionLevel]::Optimal }
            "Fastest"       { [System.IO.Compression.CompressionLevel]::Fastest }
            "NoCompression" { [System.IO.Compression.CompressionLevel]::NoCompression }
        }

        if (!(Test-Path -Path $SourceFolderPath)) {
            throw "Source folder not found: '$SourceFolderPath'"
        }

        Write-Verbose "## Checking destination folder existence: $DestinationFolderPath"
        if (!(Test-Path -Path $DestinationFolderPath)) {
            Write-Verbose "Not existing, creating..."
            New-Item -ItemType Directory -Path $DestinationFolderPath | Out-Null
        }

        Write-Verbose "## Creating archives"
        $subfolders = Get-ChildItem -Path $SourceFolderPath -Directory

        foreach ($sf in $subfolders) {
            try {
                $destinationFilePath = Join-Path -Path $DestinationFolderPath -ChildPath ($sf.Name + ".zip")
                $tempFilePath        = $destinationFilePath + ".tmp"
                $safeTempFilePath    = ConvertTo-LongSafePath $tempFilePath

                Write-Verbose "Working on subfolder: $($sf.Name)"
                Write-Verbose "Archive will be created from: $($sf.FullName)"
                Write-Verbose "Archive will be stored as: $destinationFilePath"

                # Normalise the base path by stripping any \\?\ prefix that
                # Get-ChildItem may have added. Both the base and each child's
                # FullName are stripped through Remove-LongSafePrefix before
                # Substring() is called, ensuring consistent path math regardless
                # of how PowerShell resolves long-safe roots on this system/version.
                $baseFullName = (Remove-LongSafePrefix $sf.FullName).TrimEnd('\')
                $baseLen      = $baseFullName.Length + 1

                Write-Verbose "Starting compression..."

                # $zipArchive is initialised to $null so the finally block can
                # safely call Dispose() even if ZipFile::Open() throws before
                # the variable is assigned.
                $zipArchive  = $null
                $failedFiles = [System.Collections.Generic.List[string]]::new()

                if ($PSCmdlet.ShouldProcess($destinationFilePath, "Create archive from $($sf.FullName)")) {

                    # Write to a .tmp file first. The old zip (if any) is only
                    # replaced after all entries are written successfully and the
                    # archive is disposed, so a failed compression never leaves
                    # the destination in a partial or missing state.
                    if (Test-Path -Path $tempFilePath) {
                        Remove-Item -Path $tempFilePath -Force
                    }

                    $zipArchive = [System.IO.Compression.ZipFile]::Open(
                        $safeTempFilePath,
                        [System.IO.Compression.ZipArchiveMode]::Create
                    )

                    try {
                        # Detect truly-empty subdirectories (no files anywhere in subtree)
                        # and add placeholder entries so the directory is preserved in the zip.
                        # EnumerateFiles+MoveNext short-circuits on the first file found,
                        # avoiding a full recursive scan for non-empty directories.
                        # ConvertTo-LongSafePath is applied here because EnumerateFiles is a
                        # .NET I/O call and must receive a long-safe path for deep trees.
                        Get-ChildItem -Path $sf.FullName -Directory -Recurse -Force |
                        Where-Object {
                            -not [System.IO.Directory]::EnumerateFiles(
                                (ConvertTo-LongSafePath $_.FullName), '*', 'AllDirectories'
                            ).GetEnumerator().MoveNext()
                        } |
                        ForEach-Object {
                            # Strip any long-safe prefix before substring math, then
                            # normalise to forward slashes — ZIP spec requires '/' separators.
                            $normalFull  = (Remove-LongSafePrefix $_.FullName).TrimEnd('\')
                            $relativeDir = ($normalFull.Substring($baseLen) -replace '\\', '/') + '/'
                            $zipArchive.CreateEntry($relativeDir) | Out-Null
                        }

                        # Add all files. Long-safe path is used for the .NET I/O call;
                        # the plain normalised path is used for the in-zip entry name.
                        Get-ChildItem -Path $sf.FullName -File -Recurse -Force | ForEach-Object {
                            try {
                                $longSafePath = ConvertTo-LongSafePath $_.FullName
                                $normalFull   = (Remove-LongSafePrefix $_.FullName).TrimEnd('\')
                                $relativePath = $normalFull.Substring($baseLen) -replace '\\', '/'

                                [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                                    $zipArchive,
                                    $longSafePath,
                                    $relativePath,
                                    $compressionLevelEnum
                                ) | Out-Null
                            }
                            catch {
                                # Collect failures rather than silently swallowing them.
                                # Write-Error (not Write-Warning) ensures automation pipelines
                                # can detect that the archive is incomplete.
                                $failedFiles.Add($_.FullName)
                                Write-Error "Failed to add file '$($_.FullName)': $_"
                            }
                        }
                    }
                    finally {
                        # Ensures the zip stream is flushed and closed even if an
                        # error occurs mid-archive. Safe to call when $zipArchive is
                        # $null (i.e. if Open() itself threw).
                        if ($null -ne $zipArchive) {
                            $zipArchive.Dispose()
                            $zipArchive = $null
                        }
                    }

                    # Only promote the temp file to the final destination if all
                    # files were written successfully. A partial archive is removed
                    # and an error is raised so automation is not misled.
                    if ($failedFiles.Count -gt 0) {
                        Remove-Item -Path $tempFilePath -Force -ErrorAction SilentlyContinue
                        throw "Archive for '$($sf.Name)' is incomplete — $($failedFiles.Count) file(s) could not be added."
                    }

                    # Atomically replace the old zip only after a clean write.
                    if (Test-Path -Path $destinationFilePath) {
                        Remove-Item -Path $destinationFilePath -Force
                    }
                    Move-Item -Path $tempFilePath -Destination $destinationFilePath

                    Write-Verbose "Compression completed: $destinationFilePath"
                }
            }
            catch {
                # Clean up orphaned temp file if something went wrong after it was created.
                if (Test-Path -LiteralPath $tempFilePath) {
                    Remove-Item -Path $tempFilePath -Force -ErrorAction SilentlyContinue
                }
                Write-Error "Compression FAILED for '$($sf.Name)': $_"
            }
        }
    }
    catch {
        Write-Error "Fatal error in Compress-SubFolderContents: $_"
    }
}