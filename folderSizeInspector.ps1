if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $powerShellPath = (Get-Process -Id $PID).Path
    if (-not $powerShellPath) {
        throw 'Could not determine the PowerShell executable path needed to start the UI in STA mode.'
    }
    $arguments = '-WindowStyle Hidden -STA -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
    Start-Process -FilePath $powerShellPath -ArgumentList $arguments -WorkingDirectory (Get-Location).Path
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

function Format-ByteSize {
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

function Get-FolderSizeData {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$ProgressState
    )

    $rootPath = [System.IO.Path]::GetFullPath($Path)
    $pathRoot = [System.IO.Path]::GetPathRoot($rootPath)
    if ($rootPath.Length -gt $pathRoot.Length) {
        $rootPath = $rootPath.TrimEnd('\', '/')
    }
    if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) {
        throw "The selected folder does not exist: $rootPath"
    }

    $folderSizes = @{}
    $fileCounts = @{}
    $directFileStats = @{}
    $folderSizes[$rootPath] = [long]0
    $fileCounts[$rootPath] = [long]0
    $directFileStats[$rootPath] = @{ Bytes = [long]0; Count = [long]0 }
    $errors = [System.Collections.Generic.List[string]]::new()
    $enumerationErrors = @()
    $ProgressState.Stage = 'Scanning folder contents...'
    $ProgressState.Current = 0
    $ProgressState.CurrentPath = $rootPath

    try {
        Get-ChildItem -LiteralPath $rootPath -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable enumerationErrors |
            ForEach-Object {
                $ProgressState.Current = [long]$ProgressState.Current + 1
                $ProgressState.CurrentPath = $_.FullName

                if ($_.PSIsContainer) {
                    if (-not $folderSizes.ContainsKey($_.FullName)) {
                        $folderSizes[$_.FullName] = [long]0
                        $fileCounts[$_.FullName] = [long]0
                    }
                    return
                }

                $parentPath = $_.DirectoryName
                if (-not $directFileStats.ContainsKey($parentPath)) {
                    $directFileStats[$parentPath] = @{ Bytes = [long]0; Count = [long]0 }
                }
                $directFileStats[$parentPath].Bytes += [long]$_.Length
                $directFileStats[$parentPath].Count++

                $currentPath = $parentPath
                while ($currentPath) {
                    if (-not $folderSizes.ContainsKey($currentPath)) {
                        $folderSizes[$currentPath] = [long]0
                        $fileCounts[$currentPath] = [long]0
                    }
                    $folderSizes[$currentPath] += [long]$_.Length
                    $fileCounts[$currentPath]++
                    if ($currentPath -ieq $rootPath) {
                        break
                    }
                    $parent = [System.IO.Directory]::GetParent($currentPath)
                    if (-not $parent) {
                        break
                    }
                    $currentPath = $parent.FullName
                }
            }
    }
    catch {
        $errors.Add($_.Exception.Message)
    }

    foreach ($errorRecord in $enumerationErrors) {
        $errors.Add($errorRecord.ToString())
    }

    $ProgressState.Stage = 'Preparing folder breakdown...'
    $ProgressState.CurrentPath = ''
    [pscustomobject]@{
        RootPath = $rootPath
        FolderSizes = $folderSizes
        FileCounts = $fileCounts
        DirectFileStats = $directFileStats
        Errors = @($errors)
        ItemsScanned = [long]$ProgressState.Current
    }
}

function Get-FolderBreakdown {
    param(
        [Parameter(Mandatory)]$Data,
        [Parameter(Mandatory)][string]$CurrentPath
    )

    if (-not $Data.FolderSizes.ContainsKey($CurrentPath)) {
        throw "Folder data is not available for: $CurrentPath"
    }

    $totalBytes = [long]$Data.FolderSizes[$CurrentPath]
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($folderPath in $Data.FolderSizes.Keys) {
        if ($folderPath -ieq $CurrentPath) {
            continue
        }
        $parent = [System.IO.Directory]::GetParent($folderPath)
        if (-not $parent -or $parent.FullName -ine $CurrentPath) {
            continue
        }

        $size = [long]$Data.FolderSizes[$folderPath]
        $percent = if ($totalBytes -gt 0) { 100.0 * $size / $totalBytes } else { 0.0 }
        $rows.Add([pscustomobject]@{
            Name = [System.IO.Path]::GetFileName($folderPath)
            Path = $folderPath
            Type = 'Folder'
            Bytes = $size
            Percent = $percent
            Files = [long]$Data.FileCounts[$folderPath]
        })
    }

    if ($Data.DirectFileStats.ContainsKey($CurrentPath) -and $Data.DirectFileStats[$CurrentPath].Count -gt 0) {
        $directStats = $Data.DirectFileStats[$CurrentPath]
        $percent = if ($totalBytes -gt 0) { 100.0 * $directStats.Bytes / $totalBytes } else { 0.0 }
        $rows.Add([pscustomobject]@{
            Name = 'Files in this folder'
            Path = $CurrentPath
            Type = 'Files'
            Bytes = [long]$directStats.Bytes
            Percent = $percent
            Files = [long]$directStats.Count
        })
    }

    [pscustomobject]@{
        TotalBytes = $totalBytes
        Rows = @(
            $rows |
                Sort-Object -Property `
                    @{ Expression = { if ($_.Type -eq 'Files') { 0 } else { 1 } }; Descending = $false },
                    @{ Expression = 'Bytes'; Descending = $true },
                    @{ Expression = 'Name'; Descending = $false }
        )
    }
}

$form = [System.Windows.Forms.Form]::new()
$form.Text = 'Folder Size Inspector'
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
$titleLabel.Text = 'Folder Size Inspector'
$titleLabel.Location = [System.Drawing.Point]::new(0, 2)
$titleLabel.AutoSize = $true
$titleLabel.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 19)
$titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
$headerPanel.Controls.Add($titleLabel)
$subtitleLabel = [System.Windows.Forms.Label]::new()
$subtitleLabel.Text = 'See where space is going, then drill into the largest folders.'
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

$actionsPanel = [System.Windows.Forms.FlowLayoutPanel]::new()
$actionsPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$actionsPanel.WrapContents = $false
$actionsPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$actionsPanel.Padding = [System.Windows.Forms.Padding]::new(0, 2, 0, 0)
$backButton = [System.Windows.Forms.Button]::new()
$backButton.Text = 'Up'
$backButton.Size = [System.Drawing.Size]::new(72, 32)
$backButton.Enabled = $false
$scanButton = [System.Windows.Forms.Button]::new()
$scanButton.Text = 'Scan folder'
$scanButton.Size = [System.Drawing.Size]::new(125, 32)
$scanButton.Enabled = $false
$exportButton = [System.Windows.Forms.Button]::new()
$exportButton.Text = 'Export view...'
$exportButton.Size = [System.Drawing.Size]::new(120, 32)
$exportButton.Enabled = $false
$actionsPanel.Controls.Add($backButton)
$actionsPanel.Controls.Add($scanButton)
$actionsPanel.Controls.Add($exportButton)
$toolbarLayout.Controls.Add($actionsPanel, 0, 1)
$toolbarLayout.SetColumnSpan($actionsPanel, 3)

foreach ($button in @($browseButton, $backButton, $scanButton, $exportButton)) {
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
$listView.Columns.Add('FOLDER / CONTENTS', 350) | Out-Null
$listView.Columns.Add('SIZE', 130) | Out-Null
$listView.Columns.Add('% OF FOLDER', 130) | Out-Null
$listView.Columns.Add('FILES', 110) | Out-Null
$listView.Columns.Add('PATH', 400) | Out-Null
$layout.Controls.Add($listView, 0, 2)
$listView.Add_SizeChanged({
    $availableWidth = $listView.ClientSize.Width - 4
    if ($availableWidth -gt 0) {
        $listView.Columns[0].Width = [Math]::Max(200, [int]($availableWidth * 0.27))
        $listView.Columns[1].Width = [Math]::Max(100, [int]($availableWidth * 0.13))
        $listView.Columns[2].Width = [Math]::Max(110, [int]($availableWidth * 0.14))
        $listView.Columns[3].Width = [Math]::Max(80, [int]($availableWidth * 0.10))
        $listView.Columns[4].Width = [Math]::Max(180, $availableWidth - $listView.Columns[0].Width - $listView.Columns[1].Width - $listView.Columns[2].Width - $listView.Columns[3].Width)
    }
})
Set-PolishedListView -ListView $listView -Style 'folder'

$statusPanel = [System.Windows.Forms.TableLayoutPanel]::new()
$statusPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$statusPanel.ColumnCount = 2
$statusPanel.RowCount = 1
$statusPanel.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)) | Out-Null
$statusPanel.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, 180)) | Out-Null
$statusPanel.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)) | Out-Null
$statusLabel = [System.Windows.Forms.Label]::new()
$statusLabel.Text = 'Choose a folder to inspect.'
$statusLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
$statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$statusLabel.AutoEllipsis = $true
$statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(175, 180, 188)
$statusLabel.Padding = [System.Windows.Forms.Padding]::new(2, 0, 0, 0)
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

$script:folderData = $null
$script:currentFolderPath = ''
$script:scanPowerShell = $null
$script:scanRunspace = $null
$script:scanAsyncResult = $null
$script:scanProgressState = $null
$scanTimer = [System.Windows.Forms.Timer]::new()
$scanTimer.Interval = 150

function Show-FolderBreakdown {
    param([Parameter(Mandatory)][string]$FolderPath)

    $breakdown = Get-FolderBreakdown -Data $script:folderData -CurrentPath $FolderPath
    $script:currentFolderPath = $FolderPath
    $folderTextBox.Text = $FolderPath
    $backButton.Enabled = $FolderPath -ine $script:folderData.RootPath
    $listView.BeginUpdate()
    try {
        $listView.Items.Clear()
        foreach ($entry in $breakdown.Rows) {
            $row = [System.Windows.Forms.ListViewItem]::new($entry.Name)
            $row.SubItems.Add((Format-ByteSize -Bytes $entry.Bytes)) | Out-Null
            $row.SubItems.Add(('{0:N1}%' -f $entry.Percent)) | Out-Null
            $row.SubItems.Add($entry.Files.ToString('N0')) | Out-Null
            $row.SubItems.Add($entry.Path) | Out-Null
            $row.Tag = $entry
            if ($entry.Type -eq 'Folder') {
                $row.ForeColor = [System.Drawing.Color]::FromArgb(160, 205, 230)
            }
            else {
                $row.ForeColor = [System.Drawing.Color]::FromArgb(190, 190, 195)
            }
            $listView.Items.Add($row) | Out-Null
        }
    }
    finally {
        $listView.EndUpdate()
    }

    $statusLabel.Text = "Folder total: $(Format-ByteSize -Bytes $breakdown.TotalBytes) - $($breakdown.Rows.Count) items shown."
    $exportButton.Enabled = $breakdown.Rows.Count -gt 0
}

function Show-FolderScanErrors {
    param([string[]]$Errors)

    if ($Errors.Count -eq 0) {
        return
    }

    $errorText = ($Errors | Select-Object -First 10) -join "`r`n"
    if ($Errors.Count -gt 10) {
        $errorText += "`r`n...and $($Errors.Count - 10) more."
    }
    [System.Windows.Forms.MessageBox]::Show(
        $form,
        "Some paths could not be scanned ($($Errors.Count) errors):`r`n$errorText",
        'Scan completed with warnings',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    ) | Out-Null
}

$scanTimer.Add_Tick({
    if ($script:scanProgressState) {
        $statusLabel.Text = "Scanning $($script:scanProgressState.Current) items: $([System.IO.Path]::GetFileName($script:scanProgressState.CurrentPath))"
        if ($script:scanProgressState.Stage -eq 'Preparing folder breakdown...') {
            $statusLabel.Text = 'Preparing folder breakdown...'
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

        $script:folderData = $scanOutput[$scanOutput.Count - 1]
        Show-FolderBreakdown -FolderPath $script:folderData.RootPath
        Show-FolderScanErrors -Errors $script:folderData.Errors
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
})

$folderDialog = [System.Windows.Forms.FolderBrowserDialog]::new()
$folderDialog.ShowNewFolderButton = $false
$folderDialog.SelectedPath = (Get-Location).Path

$browseButton.Add_Click({
    if ($folderDialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $folderTextBox.Text = $folderDialog.SelectedPath
        $script:folderData = $null
        $script:currentFolderPath = ''
        $listView.Items.Clear()
        $backButton.Enabled = $false
        $scanButton.Enabled = $true
        $exportButton.Enabled = $false
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
    $browseButton.Enabled = $false
    $scanButton.Enabled = $false
    $backButton.Enabled = $false
    $exportButton.Enabled = $false
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $progressBar.Visible = $true
    $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $progressBar.MarqueeAnimationSpeed = 25
    $statusLabel.Text = 'Starting scan...'
    $script:scanProgressState = [hashtable]::Synchronized(@{
        Stage = 'Starting scan...'
        Current = 0
        CurrentPath = ''
    })

    try {
        $functionSource = (Get-Command Get-FolderSizeData -CommandType Function).ScriptBlock.ToString()
        $workerScript = @"
param([string]`$ScanPath, [System.Collections.IDictionary]`$ProgressState)
function Get-FolderSizeData {
$functionSource
}
Get-FolderSizeData -Path `$ScanPath -ProgressState `$ProgressState
"@
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

$backButton.Add_Click({
    if (-not $script:folderData -or $script:currentFolderPath -ieq $script:folderData.RootPath) {
        return
    }
    $parent = [System.IO.Directory]::GetParent($script:currentFolderPath)
    if ($parent) {
        Show-FolderBreakdown -FolderPath $parent.FullName
    }
})

$listView.Add_DoubleClick({
    if (-not $listView.SelectedItems.Count) {
        return
    }
    $selectedEntry = $listView.SelectedItems[0].Tag
    if ($selectedEntry.Type -eq 'Folder') {
        Show-FolderBreakdown -FolderPath $selectedEntry.Path
    }
})

$exportDialog = [System.Windows.Forms.SaveFileDialog]::new()
$exportDialog.Filter = 'CSV files (*.csv)|*.csv'
$exportDialog.DefaultExt = 'csv'
$exportDialog.AddExtension = $true
$exportDialog.FileName = 'folder-size-breakdown.csv'
$exportButton.Add_Click({
    if (-not $script:folderData) {
        return
    }
    if ($exportDialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) {
        return
    }

    try {
        $breakdown = Get-FolderBreakdown -Data $script:folderData -CurrentPath $script:currentFolderPath
        @(
            foreach ($entry in $breakdown.Rows) {
                [pscustomobject]@{
                    Name = $entry.Name
                    Type = $entry.Type
                    SizeBytes = $entry.Bytes
                    FormattedSize = Format-ByteSize -Bytes $entry.Bytes
                    PercentOfFolder = [Math]::Round($entry.Percent, 1)
                    Files = $entry.Files
                    Path = $entry.Path
                }
            }
        ) | Export-Csv -LiteralPath $exportDialog.FileName -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        $statusLabel.Text = "Exported $($breakdown.Rows.Count) items to $($exportDialog.FileName)"
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            $_.Exception.Message,
            'Could not export breakdown',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)
