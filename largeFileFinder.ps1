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

function Set-PolishedListView {
    param(
        [Parameter(Mandatory)]
        [System.Windows.Forms.ListView]$ListView,

        [Parameter(Mandatory)]
        [ValidateSet('large', 'startup', 'folder')]
        [string]$Style
    )

    $ListView.OwnerDraw = $true
    $ListView.GridLines = $false
    $ListView.Tag = $Style
    $ListView.Add_DrawColumnHeader({
        param($Sender, $EventArgs)
        $backBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(48, 48, 52))
        $textBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(195, 200, 208))
        $separatorPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(65, 65, 70))
        $bounds = [System.Drawing.RectangleF]::new(
            [single]($EventArgs.Bounds.X + 9),
            [single]$EventArgs.Bounds.Y,
            [single]($EventArgs.Bounds.Width - 14),
            [single]$EventArgs.Bounds.Height
        )
        $format = [System.Drawing.StringFormat]::new()
        $format.LineAlignment = [System.Drawing.StringAlignment]::Center
        $format.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
        try {
            $EventArgs.Graphics.FillRectangle($backBrush, $EventArgs.Bounds)
            $EventArgs.Graphics.DrawString($EventArgs.Header.Text, $Sender.Font, $textBrush, $bounds, $format)
            $EventArgs.Graphics.DrawLine(
                $separatorPen,
                $EventArgs.Bounds.Left,
                $EventArgs.Bounds.Bottom - 1,
                $EventArgs.Bounds.Right,
                $EventArgs.Bounds.Bottom - 1
            )
        }
        finally {
            $format.Dispose()
            $separatorPen.Dispose()
            $backBrush.Dispose()
            $textBrush.Dispose()
        }
    })
    $ListView.Add_DrawItem({
        param($Sender, $EventArgs)
        if ($Sender.View -ne [System.Windows.Forms.View]::Details) {
            $EventArgs.DrawDefault = $true
        }
    })
    $ListView.Add_DrawSubItem({
        param($Sender, $EventArgs)
        $item = $EventArgs.Item
        $columnIndex = $EventArgs.ColumnIndex
        if ($item.Selected) {
            $backColor = [System.Drawing.Color]::FromArgb(65, 78, 88)
        }
        elseif ($item.Index % 2 -eq 0) {
            $backColor = [System.Drawing.Color]::FromArgb(35, 35, 38)
        }
        else {
            $backColor = [System.Drawing.Color]::FromArgb(40, 40, 44)
        }

        if ($item.Selected) {
            $foreColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
        }
        elseif ($Sender.Tag -eq 'large' -and $columnIndex -eq 1) {
            $foreColor = [System.Drawing.Color]::FromArgb(160, 210, 192)
        }
        elseif ($Sender.Tag -eq 'folder' -and $columnIndex -eq 0) {
            $foreColor = $item.ForeColor
        }
        elseif ($columnIndex -eq 0) {
            $foreColor = [System.Drawing.Color]::FromArgb(230, 232, 236)
        }
        elseif ($Sender.Tag -eq 'folder' -and $columnIndex -eq 4) {
            $foreColor = [System.Drawing.Color]::FromArgb(170, 176, 185)
        }
        elseif ($Sender.Tag -eq 'startup' -and $columnIndex -eq 2) {
            $foreColor = $item.ForeColor
        }
        else {
            $foreColor = [System.Drawing.Color]::FromArgb(205, 208, 214)
        }

        $backBrush = [System.Drawing.SolidBrush]::new($backColor)
        $foreBrush = [System.Drawing.SolidBrush]::new($foreColor)
        $separatorPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(48, 48, 52))
        $font = $EventArgs.SubItem.Font
        if (-not $font) {
            $font = $Sender.Font
        }
        $textBounds = [System.Drawing.RectangleF]::new(
            [single]($EventArgs.Bounds.X + 9),
            [single]$EventArgs.Bounds.Y,
            [single]($EventArgs.Bounds.Width - 14),
            [single]$EventArgs.Bounds.Height
        )
        $format = [System.Drawing.StringFormat]::new()
        $format.LineAlignment = [System.Drawing.StringAlignment]::Center
        $format.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
        if ($Sender.Tag -eq 'folder' -and $columnIndex -in @(1, 2, 3)) {
            $format.Alignment = [System.Drawing.StringAlignment]::Far
        }
        if ($Sender.Tag -eq 'startup' -and $columnIndex -eq 2) {
            $format.Alignment = [System.Drawing.StringAlignment]::Center
        }
        try {
            $EventArgs.Graphics.FillRectangle($backBrush, $EventArgs.Bounds)
            $EventArgs.Graphics.DrawString($EventArgs.SubItem.Text, $font, $foreBrush, $textBounds, $format)
            $EventArgs.Graphics.DrawLine(
                $separatorPen,
                $EventArgs.Bounds.Left,
                $EventArgs.Bounds.Bottom - 1,
                $EventArgs.Bounds.Right,
                $EventArgs.Bounds.Bottom - 1
            )
        }
        finally {
            $format.Dispose()
            $separatorPen.Dispose()
            $backBrush.Dispose()
            $foreBrush.Dispose()
        }
    })
}

function Get-LargestFiles {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [int]$Limit,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$ProgressState
    )

    $ProgressState.Stage = 'Scanning files...'
    $ProgressState.Current = 0
    $ProgressState.CurrentFile = ''
    $files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    $enumerationErrors = @()

    try {
        Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue -ErrorVariable enumerationErrors |
            ForEach-Object {
                $files.Add($_)
                $ProgressState.Current = $files.Count
                $ProgressState.CurrentFile = $_.FullName
            }
    }
    catch {
        $errors.Add($_.Exception.Message)
    }

    foreach ($errorRecord in $enumerationErrors) {
        $errors.Add($errorRecord.ToString())
    }

    $ProgressState.Stage = 'Sorting results...'
    $ProgressState.CurrentFile = ''
    $largestFiles = @(
        $files |
            Sort-Object -Property @{ Expression = 'Length'; Descending = $true }, @{ Expression = 'FullName'; Descending = $false } |
            Select-Object -First $Limit
    )

    [pscustomobject]@{
        Files = $largestFiles
        FileCount = $files.Count
        Errors = @($errors)
    }
}

function Format-FileSize {
    param([long]$Bytes)

    if ($Bytes -lt 1KB) {
        return "$Bytes B"
    }

    $units = @('KB', 'MB', 'GB', 'TB', 'PB')
    $size = [double]$Bytes
    $unitIndex = -1
    do {
        $size /= 1KB
        $unitIndex++
    } while ($size -ge 1KB -and $unitIndex -lt ($units.Count - 1))

    '{0:N2} {1}' -f $size, $units[$unitIndex]
}

$form = [System.Windows.Forms.Form]::new()
$form.Text = 'Large File Finder'
$form.StartPosition = 'CenterScreen'
$form.Size = [System.Drawing.Size]::new(1080, 720)
$form.MinimumSize = [System.Drawing.Size]::new(780, 500)
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
$titleLabel = [System.Windows.Forms.Label]::new()
$titleLabel.Text = 'Large File Finder'
$titleLabel.Location = [System.Drawing.Point]::new(0, 2)
$titleLabel.AutoSize = $true
$titleLabel.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 19)
$titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
$headerPanel.Controls.Add($titleLabel)
$subtitleLabel = [System.Windows.Forms.Label]::new()
$subtitleLabel.Text = 'Find the largest files in a folder or drive and review them before reclaiming space.'
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
$toolbarLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, 90)) | Out-Null
$toolbarLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)) | Out-Null
$toolbarLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, 150)) | Out-Null
$toolbarLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 50)) | Out-Null
$toolbarLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 50)) | Out-Null

$folderLabel = [System.Windows.Forms.Label]::new()
$folderLabel.Text = 'LOCATION'
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

$actionsPanel = [System.Windows.Forms.FlowLayoutPanel]::new()
$actionsPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$actionsPanel.WrapContents = $false
$actionsPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$actionsPanel.Padding = [System.Windows.Forms.Padding]::new(0, 2, 0, 0)
$topNLabel = [System.Windows.Forms.Label]::new()
$topNLabel.Text = 'Show largest'
$topNLabel.AutoSize = $true
$topNLabel.Margin = [System.Windows.Forms.Padding]::new(0, 7, 6, 0)
$actionsPanel.Controls.Add($topNLabel)
$topNInput = [System.Windows.Forms.NumericUpDown]::new()
$topNInput.Minimum = 1
$topNInput.Maximum = 1000
$topNInput.Value = 50
$topNInput.Width = 72
$topNInput.Margin = [System.Windows.Forms.Padding]::new(0, 3, 14, 0)
$actionsPanel.Controls.Add($topNInput)
$scanButton = [System.Windows.Forms.Button]::new()
$scanButton.Text = 'Find large files'
$scanButton.Size = [System.Drawing.Size]::new(140, 32)
$scanButton.Enabled = $false
$actionsPanel.Controls.Add($scanButton)
$toolbarLayout.Controls.Add($actionsPanel, 0, 1)
$toolbarLayout.SetColumnSpan($actionsPanel, 3)

foreach ($button in @($browseButton, $scanButton)) {
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.BackColor = [System.Drawing.Color]::FromArgb(55, 55, 58)
    $button.ForeColor = $form.ForeColor
    $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(80, 80, 85)
    $button.UseVisualStyleBackColor = $false
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
}
$scanButton.BackColor = [System.Drawing.Color]::FromArgb(45, 105, 95)
$scanButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(60, 130, 118)
$layout.Controls.Add($toolbarPanel, 0, 1)
$toolbarPanel.Controls.Add($toolbarLayout)

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
$listView.Columns.Add('FILE NAME', 260) | Out-Null
$listView.Columns.Add('SIZE', 110) | Out-Null
$listView.Columns.Add('LAST MODIFIED', 150) | Out-Null
$listView.Columns.Add('LOCATION', 450) | Out-Null
$layout.Controls.Add($listView, 0, 2)
$listView.Add_SizeChanged({
    $availableWidth = $listView.ClientSize.Width - 4
    if ($availableWidth -gt 0) {
        $listView.Columns[0].Width = [Math]::Max(150, [int]($availableWidth * 0.25))
        $listView.Columns[1].Width = [Math]::Max(90, [int]($availableWidth * 0.11))
        $listView.Columns[2].Width = [Math]::Max(130, [int]($availableWidth * 0.16))
        $listView.Columns[3].Width = [Math]::Max(180, $availableWidth - $listView.Columns[0].Width - $listView.Columns[1].Width - $listView.Columns[2].Width)
    }
})
Set-PolishedListView -ListView $listView -Style 'large'

$statusLabel = [System.Windows.Forms.Label]::new()
$statusLabel.Text = 'Choose a folder or drive to scan.'
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

$scanTimer = [System.Windows.Forms.Timer]::new()
$scanTimer.Interval = 150
$script:scanPowerShell = $null
$script:scanRunspace = $null
$script:scanAsyncResult = $null
$script:scanProgressState = $null

function Add-ScanResults {
    param([Parameter(Mandatory)]$Result)

    $listView.BeginUpdate()
    try {
        foreach ($file in $Result.Files) {
            $row = [System.Windows.Forms.ListViewItem]::new($file.Name)
            $row.SubItems.Add((Format-FileSize -Bytes $file.Length)) | Out-Null
            $row.SubItems.Add($file.LastWriteTime.ToString('yyyy-MM-dd HH:mm')) | Out-Null
            $row.SubItems.Add($file.DirectoryName) | Out-Null
            $row.Tag = $file.FullName
            $listView.Items.Add($row) | Out-Null
        }
    }
    finally {
        $listView.EndUpdate()
    }

    if ($Result.FileCount -eq 0) {
        $statusLabel.Text = 'No files found.'
    }
    else {
        $statusLabel.Text = "Showing $($Result.Files.Count) largest of $($Result.FileCount) files."
    }

    if ($Result.Errors.Count -gt 0) {
        $errorText = ($Result.Errors | Select-Object -First 10) -join "`r`n"
        if ($Result.Errors.Count -gt 10) {
            $errorText += "`r`n...and $($Result.Errors.Count - 10) more."
        }
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            "Some locations could not be scanned ($($Result.Errors.Count) errors):`r`n$errorText",
            'Scan completed with warnings',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
}

$scanTimer.Add_Tick({
    if ($script:scanProgressState) {
        $statusLabel.Text = "Scanning $($script:scanProgressState.Current) files: $([System.IO.Path]::GetFileName($script:scanProgressState.CurrentFile))"
        if ($script:scanProgressState.Stage -eq 'Sorting results...') {
            $statusLabel.Text = 'Sorting results...'
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
        $topNInput.Enabled = $true
    }
})

$form.Add_FormClosed({
    $scanTimer.Stop()
    $scanTimer.Dispose()
})

$folderDialog = [System.Windows.Forms.FolderBrowserDialog]::new()
$folderDialog.ShowNewFolderButton = $false
$folderDialog.SelectedPath = (Get-Location).Path

$browseButton.Add_Click({
    if ($folderDialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $folderTextBox.Text = $folderDialog.SelectedPath
        $scanButton.Enabled = $true
        $listView.Items.Clear()
        $statusLabel.Text = 'Ready to scan.'
    }
})

$scanButton.Add_Click({
    if (-not (Test-Path -LiteralPath $folderTextBox.Text -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            'Choose an existing folder or drive to scan.',
            'Location not found',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    $listView.Items.Clear()
    $browseButton.Enabled = $false
    $scanButton.Enabled = $false
    $topNInput.Enabled = $false
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $progressBar.Visible = $true
    $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $progressBar.MarqueeAnimationSpeed = 25
    $statusLabel.Text = 'Starting scan...'
    $script:scanProgressState = [hashtable]::Synchronized(@{
        Stage = 'Starting scan...'
        Current = 0
        CurrentFile = ''
    })

    try {
        $functionSource = (Get-Command Get-LargestFiles -CommandType Function).ScriptBlock.ToString()
        $formatFunctionSource = (Get-Command Format-FileSize -CommandType Function).ScriptBlock.ToString()
        $workerScript = @"
param([string]`$ScanPath, [int]`$Limit, [System.Collections.IDictionary]`$ProgressState)
function Get-LargestFiles {
$functionSource
}
function Format-FileSize {
$formatFunctionSource
}
Get-LargestFiles -Path `$ScanPath -Limit `$Limit -ProgressState `$ProgressState
"@
        $script:scanRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $script:scanRunspace.Open()
        $script:scanPowerShell = [powershell]::Create()
        $script:scanPowerShell.Runspace = $script:scanRunspace
        $null = $script:scanPowerShell.AddScript($workerScript)
        $null = $script:scanPowerShell.AddArgument($folderTextBox.Text)
        $null = $script:scanPowerShell.AddArgument([int]$topNInput.Value)
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
        $topNInput.Enabled = $true
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

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)
