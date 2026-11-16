if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $powerShellPath = (Get-Process -Id $PID).Path
    if (-not $powerShellPath) {
        throw 'Could not determine the PowerShell executable path needed to start the UI in STA mode.'
    }
    $arguments = '-STA -NoProfile -File "{0}"' -f $PSCommandPath
    Start-Process -FilePath $powerShellPath -ArgumentList $arguments -WorkingDirectory (Get-Location).Path -WindowStyle Hidden
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Get-DuplicateGroups {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [System.Collections.IDictionary]$ProgressState
    )

    $ProgressState.Stage = 'Listing files...'
    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction Stop)
    $ProgressState.Total = $files.Count
    $ProgressState.Current = 0
    $hashes = @{}
    $errors = [System.Collections.Generic.List[string]]::new()

    for ($index = 0; $index -lt $files.Count; $index++) {
        $file = $files[$index]
        if ($ProgressState) {
            $ProgressState.Stage = 'Hashing files...'
            $ProgressState.Current = $index + 1
            $ProgressState.CurrentFile = $file.FullName
        }

        try {
            $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
            if (-not $hashes.ContainsKey($hash)) {
                $hashes[$hash] = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
            }
            $hashes[$hash].Add($file)
        }
        catch {
            $errors.Add("$($file.FullName): $($_.Exception.Message)")
        }
    }

    if ($ProgressState) {
        $ProgressState.Stage = 'Grouping duplicate files...'
        $ProgressState.CurrentFile = ''
    }

    $groups = [System.Collections.Generic.List[object]]::new()
    foreach ($hash in $hashes.Keys) {
        $groupFiles = @($hashes[$hash] | Sort-Object -Property Name, FullName)
        if ($groupFiles.Count -lt 2) {
            continue
        }

        $copyFiles = @($groupFiles | Where-Object { $_.BaseName -match '(?i)Kopi|Copy|\(\d+\)' })
        if ($copyFiles.Count -eq $groupFiles.Count) {
            $copyFiles = @($groupFiles | Select-Object -Skip 1)
        }
        $copyPaths = @{}
        foreach ($copyFile in $copyFiles) {
            $copyPaths[$copyFile.FullName] = $true
        }

        $items = @(
            foreach ($groupFile in $groupFiles) {
                [pscustomobject]@{
                    File = $groupFile
                    ShouldDelete = $copyPaths.ContainsKey($groupFile.FullName)
                }
            }
        )
        $groups.Add([pscustomobject]@{
            Hash = $hash
            Items = $items
        })
    }

    [pscustomobject]@{
        Groups = @($groups | Sort-Object -Property Hash)
        Errors = @($errors)
        FileCount = $files.Count
    }
}

$form = [System.Windows.Forms.Form]::new()
$form.Text = 'Duplicate Finder'
$form.StartPosition = 'CenterScreen'
$form.Size = [System.Drawing.Size]::new(1040, 720)
$form.MinimumSize = [System.Drawing.Size]::new(760, 500)
$form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$form.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 230)
$form.Font = [System.Drawing.Font]::new('Segoe UI', 9)
$form.Padding = [System.Windows.Forms.Padding]::new(18)

$layout = [System.Windows.Forms.TableLayoutPanel]::new()
$layout.Dock = [System.Windows.Forms.DockStyle]::Fill
$layout.ColumnCount = 1
$layout.RowCount = 4
$layout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)) | Out-Null
$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 72)) | Out-Null
$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 100)) | Out-Null
$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)) | Out-Null
$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 46)) | Out-Null

$headerPanel = [System.Windows.Forms.Panel]::new()
$headerPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$headerPanel.BackColor = $form.BackColor
$titleLabel = [System.Windows.Forms.Label]::new()
$titleLabel.Text = 'Duplicate Finder'
$titleLabel.Location = [System.Drawing.Point]::new(0, 2)
$titleLabel.AutoSize = $true
$titleLabel.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 19)
$titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
$headerPanel.Controls.Add($titleLabel)
$subtitleLabel = [System.Windows.Forms.Label]::new()
$subtitleLabel.Text = 'Find identical files, review suggested copies, and remove them safely.'
$subtitleLabel.Location = [System.Drawing.Point]::new(2, 42)
$subtitleLabel.AutoSize = $true
$subtitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(165, 170, 178)
$headerPanel.Controls.Add($subtitleLabel)
$layout.Controls.Add($headerPanel, 0, 0)

$toolbarPanel = [System.Windows.Forms.Panel]::new()
$toolbarPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$toolbarPanel.BackColor = [System.Drawing.Color]::FromArgb(39, 39, 42)
$toolbarPanel.Padding = [System.Windows.Forms.Padding]::new(12, 9, 12, 8)
$toolbarLayout = [System.Windows.Forms.TableLayoutPanel]::new()
$toolbarLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
$toolbarLayout.ColumnCount = 3
$toolbarLayout.RowCount = 2
$toolbarLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, 60)) | Out-Null
$toolbarLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)) | Out-Null
$toolbarLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, 150)) | Out-Null
$toolbarLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 50)) | Out-Null
$toolbarLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 50)) | Out-Null

$folderLabel = [System.Windows.Forms.Label]::new()
$folderLabel.Text = 'FOLDER'
$folderLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
$folderLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$folderLabel.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 8)
$folderLabel.ForeColor = [System.Drawing.Color]::FromArgb(175, 180, 188)
$toolbarLayout.Controls.Add($folderLabel, 0, 0)

$folderTextBox = [System.Windows.Forms.TextBox]::new()
$folderTextBox.Dock = [System.Windows.Forms.DockStyle]::Fill
$folderTextBox.Margin = [System.Windows.Forms.Padding]::new(0, 4, 8, 4)
$folderTextBox.ReadOnly = $true
$folderTextBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$folderTextBox.ForeColor = $form.ForeColor
$folderTextBox.BorderStyle = 'FixedSingle'
$toolbarLayout.Controls.Add($folderTextBox, 1, 0)

$browseButton = [System.Windows.Forms.Button]::new()
$browseButton.Text = 'Choose folder...'
$browseButton.Dock = [System.Windows.Forms.DockStyle]::Fill
$browseButton.Margin = [System.Windows.Forms.Padding]::new(0, 2, 0, 2)
$toolbarLayout.Controls.Add($browseButton, 2, 0)

$scanButton = [System.Windows.Forms.Button]::new()
$scanButton.Text = 'Find duplicates'
$scanButton.Size = [System.Drawing.Size]::new(140, 32)
$scanButton.Enabled = $false

$deleteButton = [System.Windows.Forms.Button]::new()
$deleteButton.Text = 'Delete copies'
$deleteButton.Size = [System.Drawing.Size]::new(140, 32)
$deleteButton.Enabled = $false
$actionsPanel = [System.Windows.Forms.FlowLayoutPanel]::new()
$actionsPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$actionsPanel.WrapContents = $false
$actionsPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$actionsPanel.Padding = [System.Windows.Forms.Padding]::new(0, 2, 0, 0)
$actionsPanel.Controls.Add($scanButton)
$actionsPanel.Controls.Add($deleteButton)
$toolbarLayout.Controls.Add($actionsPanel, 0, 1)
$toolbarLayout.SetColumnSpan($actionsPanel, 3)
$toolbarPanel.Controls.Add($toolbarLayout)

foreach ($button in @($browseButton, $scanButton, $deleteButton)) {
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.BackColor = [System.Drawing.Color]::FromArgb(55, 55, 58)
    $button.ForeColor = $form.ForeColor
    $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(80, 80, 85)
    $button.UseVisualStyleBackColor = $false
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
}
$scanButton.BackColor = [System.Drawing.Color]::FromArgb(45, 105, 95)
$scanButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(60, 130, 118)
$deleteButton.BackColor = [System.Drawing.Color]::FromArgb(105, 55, 52)
$deleteButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(135, 70, 65)
$layout.Controls.Add($toolbarPanel, 0, 1)

$listView = [System.Windows.Forms.ListView]::new()
$listView.Dock = [System.Windows.Forms.DockStyle]::Fill
$listView.Margin = [System.Windows.Forms.Padding]::new(0, 12, 0, 8)
$listView.View = [System.Windows.Forms.View]::Details
$listView.FullRowSelect = $true
$listView.GridLines = $false
$listView.HideSelection = $false
$listView.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 38)
$listView.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 230)
$listView.BorderStyle = 'FixedSingle'
$listView.OwnerDraw = $true
$listView.Columns.Add('FILE NAME', 300) | Out-Null
$listView.Columns.Add('STATUS', 130) | Out-Null
$listView.Columns.Add('LOCATION', 400) | Out-Null
$layout.Controls.Add($listView, 0, 2)
$listView.Add_SizeChanged({
    $availableWidth = $listView.ClientSize.Width - 4
    if ($availableWidth -gt 0) {
        $listView.Columns[0].Width = [Math]::Max(180, [int]($availableWidth * 0.30))
        $listView.Columns[1].Width = [Math]::Max(100, [int]($availableWidth * 0.15))
        $listView.Columns[2].Width = [Math]::Max(220, $availableWidth - $listView.Columns[0].Width - $listView.Columns[1].Width)
    }
})

$statusLabel = [System.Windows.Forms.Label]::new()
$statusLabel.Text = 'Choose a folder to scan.'
$statusLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
$statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$statusLabel.AutoEllipsis = $true
$statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(175, 180, 188)
$statusLabel.Padding = [System.Windows.Forms.Padding]::new(2, 0, 0, 0)
$statusPanel = [System.Windows.Forms.TableLayoutPanel]::new()
$statusPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$statusPanel.ColumnCount = 2
$statusPanel.RowCount = 1
$statusPanel.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)) | Out-Null
$statusPanel.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, 180)) | Out-Null
$statusPanel.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)) | Out-Null
$statusPanel.Controls.Add($statusLabel, 0, 0)
$progressBar = [System.Windows.Forms.ProgressBar]::new()
$progressBar.Dock = [System.Windows.Forms.DockStyle]::Fill
$progressBar.Margin = [System.Windows.Forms.Padding]::new(12, 14, 0, 14)
$progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
$progressBar.MarqueeAnimationSpeed = 25
$progressBar.Visible = $false
$statusPanel.Controls.Add($progressBar, 1, 0)
$layout.Controls.Add($statusPanel, 0, 3)
$form.Controls.Add($layout)

$listView.Add_DrawColumnHeader({
    param($Sender, $EventArgs)
    $headerBack = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(48, 48, 52))
    $headerFore = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(190, 195, 202))
    try {
        $EventArgs.Graphics.FillRectangle($headerBack, $EventArgs.Bounds)
        $textBounds = [System.Drawing.RectangleF]::new(
            [single]($EventArgs.Bounds.X + 9),
            [single]$EventArgs.Bounds.Y,
            [single]($EventArgs.Bounds.Width - 14),
            [single]$EventArgs.Bounds.Height
        )
        $EventArgs.Graphics.DrawString($EventArgs.Header.Text, $form.Font, $headerFore, $textBounds)
    }
    finally {
        $headerBack.Dispose()
        $headerFore.Dispose()
    }
})

$listView.Add_DrawItem({
    param($Sender, $EventArgs)
    if ($Sender.View -ne [System.Windows.Forms.View]::Details) {
        $EventArgs.DrawDefault = $true
    }
})

$listView.Add_DrawSubItem({
    param($Sender, $EventArgs)
    $item = $EventArgs.Item
    $isGroup = $item.Tag -and $item.Tag.IsGroup
    $isSelected = $item.Selected
    if ($isSelected) {
        $backColor = [System.Drawing.Color]::FromArgb(65, 78, 88)
    }
    elseif ($isGroup) {
        $backColor = [System.Drawing.Color]::FromArgb(47, 53, 58)
    }
    else {
        $backColor = [System.Drawing.Color]::FromArgb(35, 35, 38)
    }

    $backBrush = [System.Drawing.SolidBrush]::new($backColor)
    $foreColor = if ($isSelected) {
        [System.Drawing.Color]::FromArgb(245, 245, 245)
    }
    elseif ($isGroup) {
        [System.Drawing.Color]::FromArgb(145, 210, 195)
    }
    else {
        $item.ForeColor
    }
    $foreBrush = [System.Drawing.SolidBrush]::new($foreColor)
    $font = if ($isGroup) { $item.Font } else { $EventArgs.SubItem.Font }
    if (-not $font) {
        $font = $listView.Font
    }
    $textBounds = [System.Drawing.RectangleF]::new(
        [single]($EventArgs.Bounds.X + 9),
        [single]($EventArgs.Bounds.Y),
        [single]($EventArgs.Bounds.Width - 14),
        [single]($EventArgs.Bounds.Height)
    )
    $format = [System.Drawing.StringFormat]::new()
    $gridPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(48, 48, 52))
    $format.LineAlignment = [System.Drawing.StringAlignment]::Center
    $format.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
    try {
        $EventArgs.Graphics.FillRectangle($backBrush, $EventArgs.Bounds)
        $EventArgs.Graphics.DrawString($EventArgs.SubItem.Text, $font, $foreBrush, $textBounds, $format)
        $EventArgs.Graphics.DrawLine(
            $gridPen,
            $EventArgs.Bounds.Left,
            $EventArgs.Bounds.Bottom - 1,
            $EventArgs.Bounds.Right,
            $EventArgs.Bounds.Bottom - 1
        )
    }
    finally {
        $format.Dispose()
        $gridPen.Dispose()
        $backBrush.Dispose()
        $foreBrush.Dispose()
    }
})

$groupFont = [System.Drawing.Font]::new('Segoe UI Semibold', 9)
$scanToolTip = [System.Windows.Forms.ToolTip]::new()
$scanTimer = [System.Windows.Forms.Timer]::new()
$scanTimer.Interval = 150
$script:scanPowerShell = $null
$script:scanRunspace = $null
$script:scanAsyncResult = $null
$script:scanProgressState = $null

function Add-ScanResults {
    param([Parameter(Mandatory)]$Result)

    foreach ($group in $Result.Groups) {
        $groupRow = [System.Windows.Forms.ListViewItem]::new('Duplicate group')
        $groupRow.SubItems.Add("$($group.Items.Count) identical files") | Out-Null
        $groupRow.SubItems.Add("SHA-256  $($group.Hash)") | Out-Null
        $groupRow.Tag = [pscustomobject]@{ IsGroup = $true }
        $groupRow.Font = $groupFont
        $listView.Items.Add($groupRow) | Out-Null

        foreach ($item in $group.Items) {
            $file = $item.File
            $action = if ($item.ShouldDelete) { 'Delete copy' } else { 'Keep' }
            $row = [System.Windows.Forms.ListViewItem]::new($file.Name)
            $row.SubItems.Add($action) | Out-Null
            $row.SubItems.Add($file.DirectoryName) | Out-Null
            $row.Tag = [pscustomobject]@{
                Path = $file.FullName
                ShouldDelete = $item.ShouldDelete
            }
            if ($item.ShouldDelete) {
                $row.ForeColor = [System.Drawing.Color]::FromArgb(255, 190, 100)
            }
            $listView.Items.Add($row) | Out-Null
        }
    }

    $deleteCount = @($listView.Items | Where-Object { $_.Tag.ShouldDelete }).Count
    $deleteButton.Enabled = $deleteCount -gt 0
    if ($Result.Groups.Count -eq 0) {
        $statusLabel.Text = "Scanned $($Result.FileCount) files. No duplicates found."
    }
    else {
        $statusLabel.Text = "Scanned $($Result.FileCount) files. Found $($Result.Groups.Count) duplicate groups; $deleteCount marked as copies."
    }

    if ($Result.Errors.Count -gt 0) {
        $errorText = ($Result.Errors | Select-Object -First 10) -join "`r`n"
        if ($Result.Errors.Count -gt 10) {
            $errorText += "`r`n...and $($Result.Errors.Count - 10) more."
        }
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            "Some files could not be hashed:`r`n$errorText",
            'Scan completed with errors',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
}

$scanTimer.Add_Tick({
    if ($script:scanProgressState) {
        $progressState = $script:scanProgressState
        if ($progressState.Stage -eq 'Hashing files...' -and $progressState.Total -gt 0) {
            $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
            $progressBar.Maximum = [Math]::Max(1, [int]$progressState.Total)
            $progressBar.Value = [Math]::Min($progressBar.Maximum, [Math]::Max(0, [int]$progressState.Current))
            $statusLabel.Text = "Hashing $($progressState.Current) of $($progressState.Total): $([System.IO.Path]::GetFileName($progressState.CurrentFile))"
            $scanToolTip.SetToolTip($statusLabel, [string]$progressState.CurrentFile)
        }
        else {
            $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
            $statusLabel.Text = [string]$progressState.Stage
            $scanToolTip.SetToolTip($statusLabel, '')
        }
    }

    if (-not $script:scanAsyncResult -or -not $script:scanAsyncResult.IsCompleted) {
        return
    }

    $scanTimer.Stop()
    try {
        $scanOutput = $script:scanPowerShell.EndInvoke($script:scanAsyncResult)
        $workerErrors = @($script:scanPowerShell.Streams.Error)
        if ($workerErrors.Count -gt 0) {
            throw ($workerErrors | ForEach-Object { $_.ToString() }) -join "`r`n"
        }
        if ($scanOutput.Count -eq 0) {
            throw 'The scan completed without returning results.'
        }

        $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
        $progressBar.Value = $progressBar.Maximum
        Add-ScanResults -Result $scanOutput[$scanOutput.Count - 1]
    }
    catch {
        $statusLabel.Text = 'Scan failed.'
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            $_.Exception.Message,
            'Scan failed',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    finally {
        if ($script:scanPowerShell) {
            $script:scanPowerShell.Dispose()
            $script:scanPowerShell = $null
        }
        if ($script:scanRunspace) {
            $script:scanRunspace.Close()
            $script:scanRunspace.Dispose()
            $script:scanRunspace = $null
        }
        $script:scanAsyncResult = $null
        $script:scanProgressState = $null
        $progressBar.Visible = $false
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $browseButton.Enabled = $true
        $scanButton.Enabled = $true
    }
})

$form.Add_FormClosed({
    $scanTimer.Stop()
    $scanTimer.Dispose()
    $scanToolTip.Dispose()
    $groupFont.Dispose()
})

$folderDialog = [System.Windows.Forms.FolderBrowserDialog]::new()
$folderDialog.ShowNewFolderButton = $false
$folderDialog.SelectedPath = (Get-Location).Path

$browseButton.Add_Click({
    if ($folderDialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $folderTextBox.Text = $folderDialog.SelectedPath
        $scanButton.Enabled = $true
        $listView.Items.Clear()
        $deleteButton.Enabled = $false
        $statusLabel.Text = 'Ready to scan.'
    }
})

$scanButton.Add_Click({
    if (-not (Test-Path -LiteralPath $folderTextBox.Text -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            'Choose an existing folder to scan.',
            'Folder not found',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    $listView.Items.Clear()
    $deleteButton.Enabled = $false
    $browseButton.Enabled = $false
    $scanButton.Enabled = $false
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $progressBar.Visible = $true
    $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $progressBar.MarqueeAnimationSpeed = 25
    $statusLabel.Text = 'Starting scan...'
    $script:scanProgressState = [hashtable]::Synchronized(@{
        Stage = 'Starting scan...'
        Current = 0
        Total = 0
        CurrentFile = ''
    }
    )

    try {
        $functionSource = (Get-Command Get-DuplicateGroups -CommandType Function).ScriptBlock.ToString()
        $workerScript = "param([string]`$ScanPath, [System.Collections.IDictionary]`$ProgressState)`r`nfunction Get-DuplicateGroups {`r`n$functionSource`r`n}`r`nGet-DuplicateGroups -Path `$ScanPath -ProgressState `$ProgressState"
        $script:scanRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $script:scanRunspace.Open()
        $script:scanPowerShell = [powershell]::Create()
        $script:scanPowerShell.Runspace = $script:scanRunspace
        $null = $script:scanPowerShell.AddScript($workerScript)
        $null = $script:scanPowerShell.AddArgument($folderTextBox.Text)
        $null = $script:scanPowerShell.AddArgument($script:scanProgressState)
        $script:scanAsyncResult = $script:scanPowerShell.BeginInvoke()
        $scanTimer.Start()
    }
    catch {
        if ($script:scanPowerShell) {
            $script:scanPowerShell.Dispose()
            $script:scanPowerShell = $null
        }
        if ($script:scanRunspace) {
            $script:scanRunspace.Close()
            $script:scanRunspace.Dispose()
            $script:scanRunspace = $null
        }
        $script:scanAsyncResult = $null
        $script:scanProgressState = $null
        $progressBar.Visible = $false
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $browseButton.Enabled = $true
        $scanButton.Enabled = $true
        $statusLabel.Text = 'Could not start scan.'
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            $_.Exception.Message,
            'Could not start scan',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

$deleteButton.Add_Click({
    $rowsToDelete = @($listView.Items | Where-Object { $_.Tag.ShouldDelete })
    if ($rowsToDelete.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            'No files are marked as copies. Files without a copy name are kept.',
            'Nothing to delete',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        return
    }

    $confirmation = [System.Windows.Forms.MessageBox]::Show(
        $form,
        "Delete $($rowsToDelete.Count) files marked as copies? Files marked Keep will not be deleted.",
        'Confirm deletion',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2
    )
    if ($confirmation -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    $deletedCount = 0
    $deleteErrors = [System.Collections.Generic.List[string]]::new()
    foreach ($row in $rowsToDelete) {
        try {
            Remove-Item -LiteralPath $row.Tag.Path -ErrorAction Stop
            $row.SubItems[1].Text = 'Deleted'
            $row.Tag.ShouldDelete = $false
            $row.ForeColor = [System.Drawing.Color]::FromArgb(130, 200, 140)
            $deletedCount++
        }
        catch {
            $row.SubItems[1].Text = 'Failed'
            $row.ForeColor = [System.Drawing.Color]::FromArgb(255, 110, 110)
            $deleteErrors.Add("$($row.Tag.Path): $($_.Exception.Message)")
        }
    }

    $deleteButton.Enabled = $false
    foreach ($row in $listView.Items) {
        if ($row.Tag.ShouldDelete) {
            $deleteButton.Enabled = $true
            break
        }
    }
    $statusLabel.Text = "Deleted $deletedCount copies."
    if ($deleteErrors.Count -gt 0) {
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            "Deleted $deletedCount files. Some files could not be deleted:`r`n$($deleteErrors -join "`r`n")",
            'Deletion completed with errors',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
})

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)
