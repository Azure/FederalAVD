#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$InputPath,
    [ValidateNotNullOrEmpty()]
    [string]$DefaultInputPath = '%USERPROFILE%\Documents\CertificateBackups',
    [switch]$Startup
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'Run this application with Windows PowerShell 5.1 (powershell.exe), not PowerShell 7.'
}
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'Windows Forms requires STA. Launch with powershell.exe -NoProfile -STA -File CertificateSignIn.ps1.'
}
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Write-Verbose 'Windows Forms assemblies loaded.'
[Windows.Forms.Application]::EnableVisualStyles()
$modulePath = Join-Path $PSScriptRoot 'CertificateSignIn.Core.psm1'
$scriptPath = $PSCommandPath
$explicitFolder = $PSBoundParameters.ContainsKey('InputPath')
$mutex = $null
$acquired = $false
$form = $null
$timer = $null
$artwork = $null
$windowIcon = $null
$fonts = [Collections.Generic.List[IDisposable]]::new()
$state = @{ Candidate = $null; Busy = $false; Verified = $false; Worker = $null; Operation = $null; Secret = $null; FolderSource = 'Default' }
try {
    Import-Module $modulePath -Force -ErrorAction Stop
    Import-Module (Join-Path $PSScriptRoot 'CertificateBackup.Core.psm1') -ErrorAction Stop
    $folderPolicy = Get-CertificatePolicy
    $folderManaged = $null -ne $folderPolicy.RestoreFolder
    $expiryWarningDays = if ($null -ne $folderPolicy.ExpiryWarningDays) { $folderPolicy.ExpiryWarningDays } else { 30 }
    Write-Verbose 'Certificate module loaded.'
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $mutex = [Threading.Mutex]::new($false, "Local\CertificateSignIn-$sid")
    try { $acquired = $mutex.WaitOne(0, $false) } catch [Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { Write-Verbose 'Another copy is already running for this user/session.'; return }
    $form = [Windows.Forms.Form]::new()
    $form.Text = 'Restore certificates - User Certificate Backup & Restore'
    $windowIcon = [Drawing.Icon]::new((Join-Path $PSScriptRoot 'assets\certificate-restore.ico'), 32, 32)
    $form.Icon = $windowIcon
    $form.ClientSize = [Drawing.Size]::new(820, 700)
    $form.MinimumSize = [Drawing.Size]::new(820, 720)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ControlBox = -not $Startup
    $form.Font = [Drawing.Font]::new('Segoe UI', 10)
    $fonts.Add($form.Font)
    $form.AutoScaleMode = 'Dpi'
    $highContrast = [Windows.Forms.SystemInformation]::HighContrast
    $blue = [Drawing.ColorTranslator]::FromHtml('#0078D4')
    $ink = [Drawing.ColorTranslator]::FromHtml('#243746')
    if (-not $highContrast) {
        $form.BackColor = [Drawing.Color]::White
        $form.ForeColor = $ink
    }
    $layout = [Windows.Forms.TableLayoutPanel]::new()
    $layout.Dock = 'Fill'
    $layout.Padding = [Windows.Forms.Padding]::new(18)
    $layout.ColumnCount = 3
    $layout.RowCount = 9
    [void]$layout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100))
    [void]$layout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, 120))
    [void]$layout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, 174))
    foreach ($height in @(38, 46, 38, 38, 30, 38, 38, 52)) {
        [void]$layout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, $height))
    }
    [void]$layout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 100))
    $form.Controls.Add($layout)
    $hero = [Windows.Forms.PictureBox]::new()
    $hero.Dock = 'Top'
    $hero.Height = 190
    $hero.SizeMode = 'StretchImage'
    $hero.BackColor = [Drawing.ColorTranslator]::FromHtml('#003B71')
    $hero.TabStop = $false
    $hero.AccessibleName = 'Certificate document with an open padlock and restore arrow'
    if (-not $highContrast) {
        $artwork = [Drawing.Image]::FromFile((Join-Path $PSScriptRoot 'assets\certificate-banner.png'))
        $hero.Image = $artwork
    } else { $hero.BackColor = [Drawing.SystemColors]::Window }
    $form.Controls.Add($hero)

    function Add-WideControl($Control, [int]$Row) {
        $layout.Controls.Add($Control, 0, $Row)
        $layout.SetColumnSpan($Control, 3)
    }
    function New-Label([string]$Text) {
        $label = [Windows.Forms.Label]::new()
        $label.Text = $Text
        $label.AutoSize = $true
        if (-not $highContrast) { $label.ForeColor = $ink }
        return $label
    }
    function New-Button([string]$Text) {
        $button = [Windows.Forms.Button]::new()
        $button.Text = $Text
        $button.Dock = 'Fill'
        $button.FlatStyle = 'Flat'
        $button.FlatAppearance.BorderSize = 1
        if (-not $highContrast) {
            $button.BackColor = [Drawing.Color]::White
            $button.ForeColor = [Drawing.ColorTranslator]::FromHtml('#005A9E')
            $button.FlatAppearance.BorderColor = [Drawing.ColorTranslator]::FromHtml('#B5D6EF')
        }
        return $button
    }
    foreach ($definition in @(
        @{ Text = 'SOFTWARE CERTIFICATE RESTORE'; Y = 20; Size = 9; Height = 24; Bold = $true },
        @{ Text = "Unlock your certificates.`r`nReady for this session."; Y = 49; Size = 22; Height = 86; Bold = $true },
        @{ Text = 'Restore from your backup. Keep your password private.'; Y = 150; Size = 10; Height = 28; Bold = $false }
    )) {
        $heading = New-Label $definition.Text
        $heading.AutoSize = $false
        $heading.Location = [Drawing.Point]::new(26, $definition.Y)
        $heading.Size = [Drawing.Size]::new(500, $definition.Height)
        $style = if ($definition.Bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }
        $heading.Font = [Drawing.Font]::new('Segoe UI', $definition.Size, $style)
        $fonts.Add($heading.Font)
        $heading.BackColor = [Drawing.Color]::Transparent
        $heading.ForeColor = if ($highContrast) { [Drawing.SystemColors]::WindowText } else { [Drawing.Color]::White }
        $hero.Controls.Add($heading)
    }
    $title = New-Label '1  YOUR CERTIFICATE BACKUP'
    $title.Font = [Drawing.Font]::new($form.Font, [Drawing.FontStyle]::Bold)
    $fonts.Add($title.Font)
    if (-not $highContrast) { $title.ForeColor = $blue }
    Add-WideControl $title 0
    $folderHint = New-Label ''
    $folderHint.AutoSize = $false
    $folderHint.Dock = 'Fill'
    Add-WideControl $folderHint 1
    $folder = [Windows.Forms.TextBox]::new()
    $folder.Dock = 'Fill'
    $browse = New-Button 'Browse...'
    $scan = New-Button 'Find newest'
    $layout.Controls.Add($folder, 0, 2)
    $layout.Controls.Add($browse, 1, 2)
    $layout.Controls.Add($scan, 2, 2)
    $selected = [Windows.Forms.TextBox]::new()
    $selected.ReadOnly = $true
    $selected.Dock = 'Fill'
    Add-WideControl $selected 3
    $unlock = New-Label '2  UNLOCK FOR THIS SESSION'
    $unlock.Font = $title.Font
    if (-not $highContrast) { $unlock.ForeColor = $blue }
    Add-WideControl $unlock 4
    $password = [Windows.Forms.TextBox]::new()
    $password.UseSystemPasswordChar = $true
    $password.Dock = 'Fill'
    $password.AccessibleName = 'Certificate backup password'
    $import = New-Button 'Restore certificate'
    if (-not $highContrast) {
        $import.BackColor = $blue
        $import.ForeColor = [Drawing.Color]::White
        $import.FlatAppearance.BorderColor = $blue
    }
    $import.Enabled = $false
    $layout.Controls.Add($password, 0, 5)
    $layout.SetColumnSpan($password, 2)
    $layout.Controls.Add($import, 2, 5)
    $startupBox = [Windows.Forms.CheckBox]::new()
    $startupBox.Text = 'Start at sign-in for this user'
    $startupBox.AutoSize = $true
    $startupBox.Visible = -not $Startup
    $backupButton = New-Button 'Back up certificates'
    $backupButton.Dock = 'None'
    $backupButton.Size = [Drawing.Size]::new(180, 30)
    $save = New-Button 'Remember folder'
    $options = [Windows.Forms.FlowLayoutPanel]::new()
    $options.Dock = 'Fill'
    $options.WrapContents = $false
    $options.Controls.AddRange([Windows.Forms.Control[]]@($backupButton, $startupBox))
    $layout.Controls.Add($options, 0, 6)
    $layout.SetColumnSpan($options, 2)
    $layout.Controls.Add($save, 2, 6)
    Add-WideControl (New-Label 'Software certificate restore, not a smart card. Current User > Personal only. Your password is never saved.') 7
    $status = [Windows.Forms.TextBox]::new()
    $status.Multiline = $true
    $status.ReadOnly = $true
    $status.ScrollBars = 'Vertical'
    $status.Dock = 'Fill'
    $status.AccessibleName = 'Certificate restore status'
    if (-not $highContrast) {
        $selected.BackColor = $status.BackColor = [Drawing.ColorTranslator]::FromHtml('#F1F7FC')
        $selected.ForeColor = $status.ForeColor = $ink
    }
    Add-WideControl $status 8
    $form.AcceptButton = $import

    function Update-RestoreFolderPresentation {
        $presentation = Get-CertificateFolderPresentation -Role Restore -Source $state.FolderSource -Startup:$Startup -ExplicitInputPath:$explicitFolder
        $form.Text = $presentation.WindowTitle
        $title.Text = '1  ' + $presentation.FolderTitle.ToUpperInvariant()
        $folderHint.Text = $presentation.Hint
        $save.Text = $presentation.SaveText
    }
    function Set-ImportBusy([bool]$Busy) {
        $state.Busy = $Busy
        foreach ($control in @($folder, $browse, $scan, $password, $startupBox, $save, $backupButton)) {
            $control.Enabled = -not $Busy -and -not $state.Verified
        }
        $folder.ReadOnly = $folderManaged
        $browse.Enabled = -not $Busy -and -not $state.Verified -and -not $folderManaged
        $save.Enabled = -not $Busy -and -not $state.Verified -and (-not $folderManaged -or -not $Startup)
        $import.Enabled = -not $Busy -and ($state.Verified -or $null -ne $state.Candidate)
        $import.Text = if ($state.Verified) { 'Continue' } else { 'Restore certificate' }
        $form.UseWaitCursor = $Busy
    }
    function Set-RestoreStatus([string]$Text, [bool]$ErrorState = $false) {
        $status.Text = $Text
        if (-not $highContrast) {
            $status.ForeColor = if ($ErrorState) { [Drawing.ColorTranslator]::FromHtml('#A4262C') } else { $ink }
        }
    }
    function Find-SelectedCertificate {
        $password.Clear()
        $state.Candidate = $null
        $import.Enabled = $false
        try {
            $state.Candidate = Find-NewestCertificate -InputPath $folder.Text
            $selected.Text = $state.Candidate
            $health = Get-CertificateBackupStatus -Folder $folder.Text -ExpiryWarningDays $expiryWarningDays
            Set-RestoreStatus ("Ready to restore:`r`n$($state.Candidate)`r`n`r`nEnter the backup password and select Restore certificate. Blank passwords are allowed.`r`n`r`n" +
                ($health.Warnings -join "`r`n"))
            $import.Enabled = $true
            [void]$password.Focus()
        } catch {
            $selected.Clear()
            $guidance = if ($folderManaged) { 'Place your backed-up PFX/P12 in the managed folder, or contact your administrator.' } else { 'Place your backed-up PFX/P12 in this folder, or browse to another folder.' }
            Set-RestoreStatus "Backup not available: $($_.Exception.Message)`r`n$guidance For a network folder, wait for connectivity and select Find newest." $true
        }
    }
    $folder.Add_TextChanged({
        if (-not $folderManaged) {
            $state.FolderSource = 'Custom'
            Update-RestoreFolderPresentation
        }
        $state.Candidate = $null
        $state.Verified = $false
        $selected.Clear()
        $password.Clear()
        $import.Enabled = $false
    })
    $browse.Add_Click({
        $dialog = [Windows.Forms.FolderBrowserDialog]::new()
        try {
            $dialog.Description = 'Select the folder containing your PFX or P12 files'
            if ($dialog.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) {
                $folder.Text = $dialog.SelectedPath
                Find-SelectedCertificate
            }
        } catch { Set-RestoreStatus "Folder selection failed: $($_.Exception.Message)" $true }
        finally { $dialog.Dispose() }
    })
    $scan.Add_Click({ Find-SelectedCertificate })
    $backupButton.Add_Click({
        try {
            if ($folderManaged) {
                & (Join-Path $PSScriptRoot 'CertificateBackup.ps1') -DefaultInputPath $DefaultInputPath -Owner $form
            } else {
                & (Join-Path $PSScriptRoot 'CertificateBackup.ps1') -InputPath $folder.Text -Owner $form
            }
            Find-SelectedCertificate
        } catch { Set-RestoreStatus "Backup helper failed: $($_.Exception.Message)" $true }
    })
    $save.Add_Click({
        try {
            if (-not $folderManaged) {
                Save-CertificateSettings -InputPath $folder.Text
                $state.FolderSource = 'Saved'
                Update-RestoreFolderPresentation
            }
            if (-not $Startup) {
                Set-CertificateStartup -Enabled $startupBox.Checked -ScriptPath $scriptPath -DefaultInputPath $DefaultInputPath
            }
            $message = if ($folderManaged) { 'Startup option saved. The restore folder is managed by your organization.' } else { 'Folder saved in HKCU for backup and restore. Managed or launch-supplied paths still take precedence. No password was saved.' }
            Set-RestoreStatus $message
        } catch { Set-RestoreStatus "Could not save all settings: $($_.Exception.Message)" $true }
    })

    # Import in a separate PowerShell runspace so provider/network delays do not freeze the form.
    $timer = [Windows.Forms.Timer]::new()
    $timer.Interval = 200
    $timer.Add_Tick({
        if ($null -eq $state.Operation -or -not $state.Operation.IsCompleted) { return }
        $timer.Stop()
        try {
            $results = @($state.Worker.EndInvoke($state.Operation))
            if ($state.Worker.HadErrors) { throw $state.Worker.Streams.Error[0] }
            if ($results.Count -eq 0) { throw 'Import completed without a verified identity.' }
            $state.Verified = $true
            Set-RestoreStatus ("Restored: $($results.Count) certificate(s). Private-key signing and store read-back verified.`r`n`r`n" +
                ($results -join "`r`n`r`n") + "`r`n`r`nReview any validity warnings above, then select Continue. Restart the consuming application if needed.")
            if ($Startup) { $form.Text = 'User Certificate Backup & Restore - restore complete' }
        } catch {
            Set-RestoreStatus "Restore failed: $($_.Exception.Message)`r`n`r`nCheck the password and file format, then retry. Contact your administrator for keyset/access errors. A later failure can leave a partial import." $true
        } finally {
            $state.Worker.Dispose()
            $state.Secret.Dispose()
            $state.Worker = $null
            $state.Operation = $null
            $state.Secret = $null
            Set-ImportBusy $false
            if ($state.Verified) { [void]$import.Focus() } else { [void]$password.Focus() }
        }
    })
    $import.Add_Click({
        if ($state.Verified -and -not $state.Busy) { $form.Close(); return }
        if ($null -eq $state.Candidate -or $state.Busy) { return }
        try {
            $state.Secret = [Security.SecureString]::new()
            for ($i = 0; $i -lt $password.TextLength; $i++) { $state.Secret.AppendChar($password.Text[$i]) }
            $state.Secret.MakeReadOnly()
            $password.Clear()
            Set-ImportBusy $true
            Set-RestoreStatus 'Restoring your software certificate and verifying private-key access...'
            $state.Worker = [Management.Automation.PowerShell]::Create()
            [void]$state.Worker.AddCommand('Import-Module').AddParameter('Name', $modulePath).
                AddParameter('ErrorAction', 'Stop').AddStatement().
                AddCommand('Import-UserCertificate').AddParameter('Path', $state.Candidate).
                AddParameter('Password', $state.Secret)
            $state.Operation = $state.Worker.BeginInvoke()
            $timer.Start()
        } catch {
            if ($null -ne $state.Worker) { $state.Worker.Dispose(); $state.Worker = $null }
            if ($null -ne $state.Secret) { $state.Secret.Dispose(); $state.Secret = $null }
            $state.Operation = $null
            $password.Clear()
            Set-ImportBusy $false
            Set-RestoreStatus "Could not start restore: $($_.Exception.Message)" $true
        }
    })
    $form.Add_FormClosing({
        param($sender, $eventArgs)
        if ($eventArgs.CloseReason -in [Windows.Forms.CloseReason]::WindowsShutDown,
            [Windows.Forms.CloseReason]::TaskManagerClosing) { return }
        if (-not (Test-CertificateFormCloseAllowed -Startup $Startup.IsPresent -Busy $state.Busy -Verified $state.Verified)) {
            $eventArgs.Cancel = $true
            $message = 'Complete certificate restore, then select Continue to finish.'
            if (-not $status.Text.Contains($message)) { $status.AppendText("`r`n`r`n$message") }
        } else { $password.Clear() }
    })
    $loadError = $null
    $folder.Text = Resolve-CertificateInputPath -InputPath $InputPath -DefaultInputPath $DefaultInputPath -ManagedInputPath $folderPolicy.RestoreFolder -PreserveEnvironmentReferences
    $state.FolderSource = if ($folderManaged) { 'Managed' } elseif ($PSBoundParameters.ContainsKey('InputPath')) { 'Explicit' } else { 'Default' }
    try {
        if (-not $folderManaged -and -not $PSBoundParameters.ContainsKey('InputPath')) {
            $settings = Get-CertificateSettings -IncludeSource
            $folder.Text = Resolve-CertificateInputPath -SavedInputPath $settings.InputPath -DefaultInputPath $DefaultInputPath -PreserveEnvironmentReferences
            $state.FolderSource = $settings.Source
        }
        $startupBox.Checked = Get-CertificateStartupEnabled
    } catch { $loadError = "Could not load settings: $($_.Exception.Message)" }
    Update-RestoreFolderPresentation
    Set-ImportBusy $false
    $form.Add_Shown({
        Write-Verbose 'Form shown; initializing certificate discovery.'
        [void]$form.Activate()
        if ($null -ne $loadError) { Set-RestoreStatus $loadError $true }
        elseif (-not [string]::IsNullOrWhiteSpace($folder.Text)) { Find-SelectedCertificate }
        else { Set-RestoreStatus 'Choose your certificate backup folder to begin.' }
    })
    Write-Verbose 'Opening User Certificate Backup & Restore form.'
    [void]$form.ShowDialog()
} catch {
    Write-Verbose ("Startup failure: " + $_.Exception.Message)
    [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'User Certificate Backup & Restore',
        [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error)
    throw
} finally {
    if ($null -ne $timer) { $timer.Dispose() }
    if ($null -ne $state.Worker) { $state.Worker.Dispose() }
    if ($null -ne $state.Secret) { $state.Secret.Dispose() }
    if ($null -ne $form) { $form.Dispose() }
    if ($null -ne $artwork) { $artwork.Dispose() }
    if ($null -ne $windowIcon) { $windowIcon.Dispose() }
    foreach ($font in $fonts) { $font.Dispose() }
    if ($acquired) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
