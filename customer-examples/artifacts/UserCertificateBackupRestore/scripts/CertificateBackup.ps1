#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InputPath,
    [string]$DefaultInputPath = '{Documents}\CertificateBackups',
    [ValidateRange(1, 365)][int]$ExpiryWarningDays = 30,
    [switch]$CheckRenewals,
    $Owner
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop' -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'Run the backup helper with Windows PowerShell 5.1: powershell.exe -NoProfile -STA -File CertificateBackup.ps1.'
}
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$backupModule = Join-Path $PSScriptRoot 'CertificateBackup.Core.psm1'
$explicitFolder = $PSBoundParameters.ContainsKey('InputPath')
Import-Module (Join-Path $PSScriptRoot 'CertificateSignIn.Core.psm1') -ErrorAction Stop
Import-Module $backupModule -ErrorAction Stop
$backupState = @{ Busy = $false; Worker = $null; Operation = $null; Secret = $null; FolderSource = 'Default' }
$backupForm = $null
$backupTimer = $null
$backupMutex = [Threading.Mutex]::new($false, ('Local\UserCertificateBackupRestore-Backup-' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value))
$backupAcquired = $false
$backupFont = $null
$backupArtwork = $null
$backupWindowIcon = $null
$backupHeadingFont = $null
try {
    $folderPolicy = Get-CertificatePolicy
    $backupManaged = $null -ne $folderPolicy.CertificateFolder
    if ($null -ne $folderPolicy.ExpiryWarningDays) { $ExpiryWarningDays = $folderPolicy.ExpiryWarningDays }
    $savedFolder = ''
    $backupState.FolderSource = if ($backupManaged) { 'Managed' } elseif ($PSBoundParameters.ContainsKey('InputPath')) { 'Explicit' } else { 'Default' }
    if (-not $backupManaged -and -not $PSBoundParameters.ContainsKey('InputPath')) {
        $settings = Get-CertificateSettings -IncludeSource
        $savedFolder = $settings.InputPath
        $backupState.FolderSource = $settings.Source
    }
    $initialFolder = Resolve-CertificateInputPath -InputPath $InputPath -SavedInputPath $savedFolder -DefaultInputPath $DefaultInputPath -ManagedInputPath $folderPolicy.CertificateFolder -PreserveEnvironmentReferences
    if ($CheckRenewals) {
        $initialHealth = Get-CertificateBackupStatus -Folder $initialFolder -ExpiryWarningDays $ExpiryWarningDays
        if (-not $initialHealth.NeedsAttention) { Write-Verbose 'Managed backup is current and no expiry/renewal warnings were detected.'; return }
    }
    try { $backupAcquired = $backupMutex.WaitOne(0, $false) } catch [Threading.AbandonedMutexException] { $backupAcquired = $true }
    if (-not $backupAcquired) { Write-Verbose 'A backup helper is already open for this user/session.'; return }
    $backupForm = [Windows.Forms.Form]::new()
    $backupForm.Text = 'Back up certificates - User Certificate Backup & Restore'
    $backupWindowIcon = [Drawing.Icon]::new((Join-Path $PSScriptRoot 'assets\certificate-backup.ico'), 32, 32)
    $backupForm.Icon = $backupWindowIcon
    $backupForm.ClientSize = [Drawing.Size]::new(900, 680)
    $backupForm.StartPosition = 'CenterScreen'
    $backupForm.FormBorderStyle = 'FixedDialog'
    $backupForm.MaximizeBox = $false
    $backupForm.MinimizeBox = $false
    $backupFont = [Drawing.Font]::new('Segoe UI', 10)
    $backupForm.Font = $backupFont
    $backupForm.AutoScaleMode = 'Dpi'
    $backupHighContrast = [Windows.Forms.SystemInformation]::HighContrast
    $backupBlue = [Drawing.ColorTranslator]::FromHtml('#0078D4')
    if (-not $backupHighContrast) { $backupForm.BackColor = [Drawing.Color]::White }
    $backupLayout = [Windows.Forms.TableLayoutPanel]::new()
    $backupLayout.Dock = 'Fill'
    $backupLayout.Padding = [Windows.Forms.Padding]::new(18)
    $backupLayout.ColumnCount = 1
    $backupLayout.RowCount = 7
    foreach ($height in @(140, 62, 190, 40, 72)) {
        [void]$backupLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, $height))
    }
    [void]$backupLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 100))
    [void]$backupLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, 44))
    $backupForm.Controls.Add($backupLayout)
    $backupHero = [Windows.Forms.PictureBox]::new()
    $backupHero.Dock = 'Fill'
    $backupHero.SizeMode = 'StretchImage'
    $backupHero.TabStop = $false
    $backupHero.AccessibleName = 'Certificate document with a backup arrow and archive box'
    $backupHero.BackColor = if ($backupHighContrast) { [Drawing.SystemColors]::Window } else { [Drawing.ColorTranslator]::FromHtml('#003B71') }
    if (-not $backupHighContrast) {
        $backupArtwork = [Drawing.Image]::FromFile((Join-Path $PSScriptRoot 'assets\certificate-backup-banner.png'))
        $backupHero.Image = $backupArtwork
    }
    $backupHeadingFont = [Drawing.Font]::new('Segoe UI', 16, [Drawing.FontStyle]::Bold)
    $backupHeading = [Windows.Forms.Label]::new()
    $backupHeading.Location = [Drawing.Point]::new(18, 16)
    $backupHeading.Size = [Drawing.Size]::new(540, 62)
    $backupHeading.Font = $backupHeadingFont
    $backupHeading.Text = "Protect your certificates.`r`nKeep a recoverable backup."
    $backupHeading.BackColor = [Drawing.Color]::Transparent
    $backupHeading.ForeColor = if ($backupHighContrast) { [Drawing.SystemColors]::WindowText } else { [Drawing.Color]::White }
    $backupCaption = [Windows.Forms.Label]::new()
    $backupCaption.Location = [Drawing.Point]::new(18, 88)
    $backupCaption.Size = [Drawing.Size]::new(540, 40)
    $backupCaption.Text = 'Choose identities. Encrypt a complete backup.'
    $backupCaption.BackColor = [Drawing.Color]::Transparent
    $backupCaption.ForeColor = $backupHeading.ForeColor
    $backupHero.Controls.AddRange([Windows.Forms.Control[]]@($backupHeading, $backupCaption))
    $backupLayout.Controls.Add($backupHero, 0, 0)
    $folderPanel = [Windows.Forms.TableLayoutPanel]::new()
    $folderPanel.Dock = 'Fill'
    $folderPanel.ColumnCount = 2
    $folderPanel.RowCount = 2
    [void]$folderPanel.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, 26))
    [void]$folderPanel.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 100))
    [void]$folderPanel.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100))
    [void]$folderPanel.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, 100))
    $folderLabel = [Windows.Forms.Label]::new()
    $folderLabel.Text = if ($backupManaged) { 'Backup folder managed by your organization' } else { 'Persistent, user-protected backup folder' }
    $folderLabel.AutoSize = $true
    $folderPanel.Controls.Add($folderLabel, 0, 0)
    $backupFolder = [Windows.Forms.TextBox]::new()
    $backupFolder.Dock = 'Fill'
    $backupFolder.Text = $initialFolder
    $backupFolder.ReadOnly = $backupManaged
    $backupFolder.AccessibleName = 'Certificate backup destination'
    $folderPanel.Controls.Add($backupFolder, 0, 1)
    $backupBrowse = [Windows.Forms.Button]::new()
    $backupBrowse.Text = 'Browse...'
    $backupBrowse.Dock = 'Fill'
    $backupBrowse.Enabled = -not $backupManaged
    $folderPanel.Controls.Add($backupBrowse, 1, 1)
    $backupLayout.Controls.Add($folderPanel, 0, 1)
    $certificateGrid = [Windows.Forms.DataGridView]::new()
    $certificateGrid.Dock = 'Fill'
    $certificateGrid.AllowUserToAddRows = $false
    $certificateGrid.AllowUserToDeleteRows = $false
    $certificateGrid.RowHeadersVisible = $false
    $certificateGrid.SelectionMode = 'FullRowSelect'
    $certificateGrid.AutoGenerateColumns = $false
    $certificateGrid.AccessibleName = 'Certificates available for backup'
    $selectedColumn = [Windows.Forms.DataGridViewCheckBoxColumn]::new()
    $selectedColumn.HeaderText = ''
    $selectedColumn.Width = 34
    [void]$certificateGrid.Columns.Add($selectedColumn)
    foreach ($column in @(
        @{ Name = 'Identity'; Width = 290 },
        @{ Name = 'Expires'; Width = 115 },
        @{ Name = 'Thumbprint'; Width = 265 },
        @{ Name = 'Selection'; Width = 155 }
    )) {
        $textColumn = [Windows.Forms.DataGridViewTextBoxColumn]::new()
        $textColumn.HeaderText = $column.Name
        $textColumn.Width = $column.Width
        if ($column.Name -eq 'Identity') { $textColumn.AutoSizeMode = 'Fill' }
        $textColumn.ReadOnly = $true
        $textColumn.SortMode = 'NotSortable'
        [void]$certificateGrid.Columns.Add($textColumn)
    }
    if (-not $backupHighContrast) {
        $certificateGrid.BackgroundColor = [Drawing.Color]::White
        $certificateGrid.EnableHeadersVisualStyles = $false
        $certificateGrid.ColumnHeadersDefaultCellStyle.BackColor = $backupBlue
        $certificateGrid.ColumnHeadersDefaultCellStyle.ForeColor = [Drawing.Color]::White
        $certificateGrid.AlternatingRowsDefaultCellStyle.BackColor = [Drawing.ColorTranslator]::FromHtml('#F1F7FC')
    }
    $backupLayout.Controls.Add($certificateGrid, 0, 2)
    $selectionNote = [Windows.Forms.Label]::new()
    $selectionNote.Dock = 'Fill'
    $selectionNote.Text = 'Checked identities form one backup. Use the current backup password for retained identities; newly enrolled keys must be exportable.'
    $backupLayout.Controls.Add($selectionNote, 0, 3)
    $passwordPanel = [Windows.Forms.TableLayoutPanel]::new()
    $passwordPanel.Dock = 'Fill'
    $passwordPanel.ColumnCount = 2
    $passwordPanel.RowCount = 2
    [void]$passwordPanel.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, 28))
    [void]$passwordPanel.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 100))
    [void]$passwordPanel.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 50))
    [void]$passwordPanel.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 50))
    $backupPassword = [Windows.Forms.TextBox]::new()
    $backupConfirmation = [Windows.Forms.TextBox]::new()
    $backupPassword.AccessibleName = 'Backup password'
    $backupConfirmation.AccessibleName = 'Confirm backup password'
    for ($index = 0; $index -lt 2; $index++) {
        $label = [Windows.Forms.Label]::new()
        $label.Text = if ($index -eq 0) { 'Backup password (12+ characters)' } else { 'Confirm password (case-sensitive)' }
        $label.Dock = 'Fill'
        $passwordPanel.Controls.Add($label, $index, 0)
        $entry = if ($index -eq 0) { $backupPassword } else { $backupConfirmation }
        $entry.UseSystemPasswordChar = $true
        $entry.Dock = 'Fill'
        $passwordPanel.Controls.Add($entry, $index, 1)
    }
    $backupLayout.Controls.Add($passwordPanel, 0, 4)
    $backupStatus = [Windows.Forms.TextBox]::new()
    $backupStatus.Multiline = $true
    $backupStatus.ReadOnly = $true
    $backupStatus.ScrollBars = 'Vertical'
    $backupStatus.Dock = 'Fill'
    $backupStatus.AccessibleName = 'Backup status and renewal warnings'
    $backupLayout.Controls.Add($backupStatus, 0, 5)
    $backupActions = [Windows.Forms.FlowLayoutPanel]::new()
    $backupActions.Dock = 'Fill'
    $backupActions.FlowDirection = 'RightToLeft'
    $backupClose = [Windows.Forms.Button]::new()
    $backupClose.Text = 'Done'
    $backupClose.Size = [Drawing.Size]::new(90, 34)
    $backupSubmit = [Windows.Forms.Button]::new()
    $backupSubmit.Text = 'Back up certificates'
    $backupSubmit.Size = [Drawing.Size]::new(190, 34)
    if (-not $backupHighContrast) {
        $backupSubmit.FlatStyle = 'Flat'
        $backupSubmit.BackColor = $backupBlue
        $backupSubmit.ForeColor = [Drawing.Color]::White
    }
    $backupRefresh = [Windows.Forms.Button]::new()
    $backupRefresh.Text = 'Check renewals'
    $backupRefresh.Size = [Drawing.Size]::new(150, 34)
    $backupRemember = [Windows.Forms.Button]::new()
    $backupRemember.Text = 'Remember folder'
    $backupRemember.Size = [Drawing.Size]::new(150, 34)
    $backupRemember.Enabled = -not $backupManaged
    $backupActions.Controls.AddRange([Windows.Forms.Control[]]@($backupClose, $backupSubmit, $backupRefresh, $backupRemember))
    $backupLayout.Controls.Add($backupActions, 0, 6)
    $backupForm.AcceptButton = $backupSubmit

    function Update-BackupFolderPresentation {
        $presentation = Get-CertificateFolderPresentation -Role Backup -Source $backupState.FolderSource -ExplicitInputPath:$explicitFolder
        $backupForm.Text = $presentation.WindowTitle
        $folderLabel.Text = $presentation.FolderTitle
        $backupCaption.Text = $presentation.Hint
        $backupRemember.Text = $presentation.SaveText
    }
    function Set-BackupStatus([string]$Message, [bool]$Failed = $false) {
        $backupStatus.Text = $Message
        if (-not $backupHighContrast) {
            $backupStatus.ForeColor = if ($Failed) { [Drawing.ColorTranslator]::FromHtml('#A4262C') } else { [Drawing.ColorTranslator]::FromHtml('#243746') }
        }
    }
    function Set-BackupBusy([bool]$Busy) {
        $backupState.Busy = $Busy
        foreach ($control in @($backupFolder, $backupBrowse, $certificateGrid, $backupPassword, $backupConfirmation, $backupClose, $backupSubmit, $backupRefresh, $backupRemember)) {
            $control.Enabled = -not $Busy
        }
        $backupFolder.ReadOnly = $backupManaged
        $backupBrowse.Enabled = -not $Busy -and -not $backupManaged
        $backupRemember.Enabled = -not $Busy -and -not $backupManaged
        $backupForm.UseWaitCursor = $Busy
    }
    function Refresh-BackupCatalog {
        $certificateGrid.Rows.Clear()
        $catalog = @(Get-UserBackupCertificates)
        $health = $null
        $healthError = $null
        try { $health = Get-CertificateBackupStatus -Folder $backupFolder.Text -Certificates $catalog -ExpiryWarningDays $ExpiryWarningDays }
        catch {
            if ($_.Exception.Data['CertificateKfmPending'] -eq $true) {
                Set-BackupStatus "$($_.Exception.Message)`r`nSelect Check renewals after work OneDrive is ready." $true
                return
            }
            $healthError = $_.Exception.Message
        }
        if ($null -ne $health -and $null -ne $health.Manifest) {
            $catalog += @($health.Manifest.Certificates | Where-Object { $_.Thumbprint -notin @($catalog | ForEach-Object { $_.Thumbprint }) })
        }
        foreach ($identity in $catalog) {
            $approved = $null -ne $health -and $identity.Thumbprint -in $health.ApprovedThumbprints
            $renewal = $null -ne $health -and $identity.Thumbprint -in $health.RenewalThumbprints
            $selection = if ($approved) { 'Remembered selection' } elseif ($renewal) { 'Review renewal' } else { 'Not managed' }
            $rowIndex = $certificateGrid.Rows.Add([object[]]@($approved, $identity.Subject,
                [DateTimeOffset]::Parse($identity.NotAfterUtc).LocalDateTime.ToString('d'), $identity.Thumbprint, $selection))
            $certificateGrid.Rows[$rowIndex].Tag = $identity
            $certificateGrid.Rows[$rowIndex].Cells[1].ToolTipText = $identity.Subject + "`r`nIssuer: " + $identity.Issuer
        }
        if ($null -ne $healthError) {
            Set-BackupStatus "Could not validate the previous backup: $healthError`r`nReview your current certificate selection before creating a fresh backup." $true
        } elseif ($catalog.Count -eq 0) {
            Set-BackupStatus 'No RSA/ECDSA user certificates with private keys were found. Complete enrollment on this host before backing up.'
        } else {
            $last = if ($null -ne $health.Manifest) { "Last validated backup: $($health.Manifest.CreatedUtc)`r`nUse its password when retaining previously backed-up identities.`r`n" } else { '' }
            Set-BackupStatus ($last + ($health.Warnings -join "`r`n") + "`r`nPrevious PFX versions are retained. Passwords are never stored.")
        }
    }
    $backupBrowse.Add_Click({
        $dialog = [Windows.Forms.FolderBrowserDialog]::new()
        try {
            if ($dialog.ShowDialog($backupForm) -eq [Windows.Forms.DialogResult]::OK) { $backupFolder.Text = $dialog.SelectedPath; Refresh-BackupCatalog }
        } catch { Set-BackupStatus $_.Exception.Message $true } finally { $dialog.Dispose() }
    })
    $backupRefresh.Add_Click({ try { Refresh-BackupCatalog } catch { Set-BackupStatus $_.Exception.Message $true } })
    $backupFolder.Add_TextChanged({
        if (-not $backupManaged) {
            $backupState.FolderSource = 'Custom'
            Update-BackupFolderPresentation
        }
    })
    $backupRemember.Add_Click({
        try {
            if ($backupManaged) { return }
            Save-CertificateSettings -InputPath $backupFolder.Text
            $backupState.FolderSource = 'Saved'
            Update-BackupFolderPresentation
            Set-BackupStatus 'Folder remembered for backup and restore when no managed folder or explicit input path overrides it. No certificates or passwords were saved.'
        } catch { Set-BackupStatus "Could not remember folder: $($_.Exception.Message)" $true }
    })
    $backupClose.Add_Click({ $backupForm.Close() })
    Update-BackupFolderPresentation
    $backupTimer = [Windows.Forms.Timer]::new()
    $backupTimer.Interval = 200
    $backupTimer.Add_Tick({
        if ($null -eq $backupState.Operation -or -not $backupState.Operation.IsCompleted) { return }
        $backupTimer.Stop()
        try {
            $results = @($backupState.Worker.EndInvoke($backupState.Operation))
            if ($backupState.Worker.HadErrors) { throw $backupState.Worker.Streams.Error[0] }
            if ($results.Count -ne 1) { throw 'Backup did not return one validated bundle result.' }
            $warning = $results[0].OfflinePinStatus -eq 'Failed'
            try {
                Refresh-BackupCatalog
                $catalogText = $backupStatus.Text
            } catch {
                $warning = $true
                $catalogText = "Backup succeeded; refreshing backup details failed: $($_.Exception.Message)"
            }
            Set-BackupStatus ("Success: $($results[0].Count) identities backed up and verified.`r`n$($results[0].Path)`r`n`r`n" +
                $results[0].OfflinePinMessage + "`r`n`r`n" + $catalogText) $warning
        } catch { Set-BackupStatus "Backup failed: $($_.Exception.Message)" $true }
        finally {
            $backupState.Worker.Dispose()
            $backupState.Secret.Dispose()
            $backupState.Worker = $backupState.Operation = $backupState.Secret = $null
            Set-BackupBusy $false
        }
    })
    $backupSubmit.Add_Click({
        if ($backupState.Busy) { return }
        try {
            [void]$certificateGrid.EndEdit()
            $thumbprints = @($certificateGrid.Rows | Where-Object { $_.Cells[0].Value -eq $true } | ForEach-Object { $_.Tag.Thumbprint })
            if ($thumbprints.Count -eq 0) { throw 'Select at least one certificate explicitly.' }
            if (-not [string]::Equals($backupPassword.Text, $backupConfirmation.Text, [StringComparison]::Ordinal)) {
                throw 'The password confirmation does not match exactly.'
            }
            if ($backupPassword.TextLength -lt 12) { throw 'Use at least 12 characters. A long, unique passphrase is recommended.' }
            if ([string]::IsNullOrWhiteSpace($backupFolder.Text)) { throw 'Choose a backup folder.' }
            $backupState.Secret = [Security.SecureString]::new()
            for ($index = 0; $index -lt $backupPassword.TextLength; $index++) { $backupState.Secret.AppendChar($backupPassword.Text[$index]) }
            $backupState.Secret.MakeReadOnly()
            $backupPassword.Clear(); $backupConfirmation.Clear()
            Set-BackupBusy $true
            Set-BackupStatus 'Exporting selected keys, validating the AES-encrypted bundle, and publishing a new backup version...'
            $backupState.Worker = [Management.Automation.PowerShell]::Create()
            [void]$backupState.Worker.AddCommand('Import-Module').AddParameter('Name', $backupModule).AddParameter('ErrorAction', 'Stop').
                AddStatement().AddCommand('Backup-UserCertificates').AddParameter('Thumbprints', $thumbprints).
                AddParameter('Password', $backupState.Secret).AddParameter('Folder', $backupFolder.Text)
            $backupState.Operation = $backupState.Worker.BeginInvoke()
            $backupTimer.Start()
        } catch {
            if ($null -ne $backupState.Worker) { $backupState.Worker.Dispose() }
            if ($null -ne $backupState.Secret) { $backupState.Secret.Dispose() }
            $backupState.Worker = $backupState.Operation = $backupState.Secret = $null
            Set-BackupBusy $false
            Set-BackupStatus $_.Exception.Message $true
        }
    })
    $backupForm.Add_FormClosing({
        param($sender, $eventArgs)
        if ($backupState.Busy -and $eventArgs.CloseReason -notin [Windows.Forms.CloseReason]::WindowsShutDown,
            [Windows.Forms.CloseReason]::TaskManagerClosing) { $eventArgs.Cancel = $true; Set-BackupStatus 'Wait for backup validation to finish before closing.' }
    })
    $backupForm.Add_Shown({ try { Refresh-BackupCatalog } catch { Set-BackupStatus $_.Exception.Message $true } })
    if ($null -ne $Owner) { [void]$backupForm.ShowDialog($Owner) } else { [void]$backupForm.ShowDialog() }
} catch {
    [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Certificate backup', [Windows.Forms.MessageBoxButtons]::OK,
        [Windows.Forms.MessageBoxIcon]::Error)
    throw
} finally {
    if ($null -ne $backupTimer) { $backupTimer.Dispose() }
    if ($null -ne $backupState.Worker) { $backupState.Worker.Dispose() }
    if ($null -ne $backupState.Secret) { $backupState.Secret.Dispose() }
    if ($null -ne $backupForm) { $backupForm.Dispose() }
    if ($null -ne $backupFont) { $backupFont.Dispose() }
    if ($null -ne $backupArtwork) { $backupArtwork.Dispose() }
    if ($null -ne $backupWindowIcon) { $backupWindowIcon.Dispose() }
    if ($null -ne $backupHeadingFont) { $backupHeadingFont.Dispose() }
    if ($backupAcquired) { $backupMutex.ReleaseMutex() }
    $backupMutex.Dispose()
}
