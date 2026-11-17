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
    param([Parameter(Mandatory)][System.Windows.Forms.ListView]$ListView)

    $ListView.OwnerDraw = $true
    $ListView.GridLines = $false
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
            $foreColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
        }
        else {
            $backColor = if ($item.Index % 2 -eq 0) {
                [System.Drawing.Color]::FromArgb(35, 35, 38)
            }
            else {
                [System.Drawing.Color]::FromArgb(40, 40, 44)
            }
            $foreColor = switch ($columnIndex) {
                0 { [System.Drawing.Color]::FromArgb(230, 232, 236) }
                2 { [System.Drawing.Color]::FromArgb(160, 210, 192) }
                { $_ -in 3, 4 } { [System.Drawing.Color]::FromArgb(190, 205, 220) }
                6 { [System.Drawing.Color]::FromArgb(170, 176, 185) }
                default { [System.Drawing.Color]::FromArgb(205, 208, 214) }
            }
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
        if ($columnIndex -in @(1, 2, 3, 4)) {
            $format.Alignment = [System.Drawing.StringAlignment]::Far
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

function Format-ProcessMemory {
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

    '{0:N1} {1}' -f $size, $units[$unitIndex]
}

function Get-ResourceConsumers {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('CPU', 'Memory')]
        [string]$SortBy,

        [Parameter(Mandatory)]
        [int]$Limit,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$ProgressState
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $cpuReadErrors = [System.Collections.Generic.List[string]]::new()
    $memoryReadErrors = [System.Collections.Generic.List[string]]::new()
    $processErrors = @()
    $ProgressState.Stage = 'Collecting processes...'
    $initialProcesses = @(
        Get-Process -ErrorAction SilentlyContinue -ErrorVariable processErrors
    )
    foreach ($errorRecord in $processErrors) {
        $errors.Add($errorRecord.ToString())
    }

    $baselineCpu = @{}
    $elapsedSeconds = 0.0
    if ($SortBy -eq 'CPU') {
        foreach ($process in $initialProcesses) {
            try {
                if ($null -ne $process.CPU) {
                    $baselineCpu[[int]$process.Id] = [double]$process.CPU
                }
            }
            catch {
                $cpuReadErrors.Add("PID $($process.Id): $($_.Exception.Message)")
            }
        }

        $ProgressState.Stage = 'Sampling CPU for one second...'
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Start-Sleep -Milliseconds 1000
        $processErrors = @()
        $processes = @(
            Get-Process -ErrorAction SilentlyContinue -ErrorVariable processErrors
        )
        $stopwatch.Stop()
        $elapsedSeconds = [Math]::Max(0.001, $stopwatch.Elapsed.TotalSeconds)
        foreach ($errorRecord in $processErrors) {
            $errors.Add($errorRecord.ToString())
        }
    }
    else {
        $processes = $initialProcesses
    }

    $ProgressState.Stage = 'Reading memory and service details...'
    $servicesByProcess = @{}
    $totalPhysicalMemory = $null
    if ($SortBy -eq 'Memory') {
        try {
            $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -Property TotalPhysicalMemory -ErrorAction Stop
            if ([long]$computerSystem.TotalPhysicalMemory -gt 0) {
                $totalPhysicalMemory = [long]$computerSystem.TotalPhysicalMemory
            }
            else {
                $errors.Add('Windows did not report total physical memory; RAM percentages will be unavailable.')
            }
        }
        catch {
            $errors.Add("Could not read total physical memory: $($_.Exception.Message)")
        }
    }

    try {
        Get-CimInstance -ClassName Win32_Service -ErrorAction Stop |
            ForEach-Object {
                $processId = [int]$_.ProcessId
                if ($processId -gt 0) {
                    if (-not $servicesByProcess.ContainsKey($processId)) {
                        $servicesByProcess[$processId] = [System.Collections.Generic.List[string]]::new()
                    }
                    $servicesByProcess[$processId].Add([string]$_.Name)
                }
            }
    }
    catch {
        $errors.Add("Could not read Windows service assignments: $($_.Exception.Message)")
    }

    $ProgressState.Stage = 'Sorting process results...'
    $resultRows = [System.Collections.Generic.List[object]]::new()
    foreach ($process in $processes) {
        $cpuPercent = $null
        if ($SortBy -eq 'CPU' -and $baselineCpu.ContainsKey([int]$process.Id)) {
            $cpuPercent = 0.0
            try {
                $cpuDelta = [double]$process.CPU - [double]$baselineCpu[[int]$process.Id]
                if ($cpuDelta -gt 0) {
                    $cpuPercent = 100.0 * $cpuDelta / $elapsedSeconds / [Math]::Max(1, [Environment]::ProcessorCount)
                }
            }
            catch {
                $cpuReadErrors.Add("PID $($process.Id): $($_.Exception.Message)")
            }
        }

        $executablePath = 'Unavailable'
        try {
            if (-not [string]::IsNullOrWhiteSpace([string]$process.Path)) {
                $executablePath = [string]$process.Path
            }
        }
        catch {
            $executablePath = 'Access denied'
        }

        $serviceNames = '-'
        if ($servicesByProcess.ContainsKey([int]$process.Id)) {
            $serviceNames = $servicesByProcess[[int]$process.Id] -join ', '
        }
        $workingSet = [long]0
        $privateBytes = [long]0
        $memoryAvailable = $true
        try {
            $workingSet = [long]$process.WorkingSet64
            $privateBytes = [long]$process.PrivateMemorySize64
        }
        catch {
            $memoryAvailable = $false
            $memoryReadErrors.Add("PID $($process.Id): $($_.Exception.Message)")
        }
        $ramPercent = $null
        if ($SortBy -eq 'Memory' -and $memoryAvailable -and $totalPhysicalMemory) {
            $ramPercent = 100.0 * $workingSet / $totalPhysicalMemory
        }

        $resultRows.Add([pscustomobject]@{
            ProcessName = [string]$process.ProcessName
            Id = [int]$process.Id
            CpuPercent = $cpuPercent
            RamPercent = $ramPercent
            WorkingSet = $workingSet
            PrivateBytes = $privateBytes
            TotalPhysicalMemory = $totalPhysicalMemory
            Services = $serviceNames
            ExecutablePath = $executablePath
        })
    }

    if ($cpuReadErrors.Count -gt 0) {
        $cpuExamples = ($cpuReadErrors | Select-Object -First 3) -join '; '
        $errors.Add("CPU usage could not be read for $($cpuReadErrors.Count) process samples. $cpuExamples")
    }
    if ($memoryReadErrors.Count -gt 0) {
        $memoryExamples = ($memoryReadErrors | Select-Object -First 3) -join '; '
        $errors.Add("Memory usage could not be read for $($memoryReadErrors.Count) processes. $memoryExamples")
    }

    if ($SortBy -eq 'CPU') {
        $sortedRows = @(
            $resultRows |
                Sort-Object -Property @{ Expression = 'CpuPercent'; Descending = $true }, ProcessName, Id |
                Select-Object -First $Limit
        )
    }
    else {
        $sortedRows = @(
            $resultRows |
                Sort-Object -Property @{ Expression = 'WorkingSet'; Descending = $true }, ProcessName, Id |
                Select-Object -First $Limit
        )
    }

    [pscustomobject]@{
        SortBy = $SortBy
        Processes = $sortedRows
        ProcessCount = $resultRows.Count
        SampleSeconds = $elapsedSeconds
        Errors = @($errors)
    }
}

$form = [System.Windows.Forms.Form]::new()
$form.Text = 'Resource Hog Finder'
$form.StartPosition = 'CenterScreen'
$form.Size = [System.Drawing.Size]::new(1240, 720)
$form.MinimumSize = [System.Drawing.Size]::new(900, 500)
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
$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 60)) | Out-Null
$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)) | Out-Null
$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 46)) | Out-Null

$headerPanel = [System.Windows.Forms.Panel]::new()
$headerPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$titleLabel = [System.Windows.Forms.Label]::new()
$titleLabel.Text = 'Resource Hog Finder'
$titleLabel.Location = [System.Drawing.Point]::new(0, 2)
$titleLabel.AutoSize = $true
$titleLabel.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 19)
$titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
$headerPanel.Controls.Add($titleLabel)
$subtitleLabel = [System.Windows.Forms.Label]::new()
$subtitleLabel.Text = 'CPU is sampled for one second; RAM % is working set divided by installed physical memory.'
$subtitleLabel.Location = [System.Drawing.Point]::new(2, 42)
$subtitleLabel.AutoSize = $true
$subtitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(165, 170, 178)
$headerPanel.Controls.Add($subtitleLabel)
$layout.Controls.Add($headerPanel, 0, 0)

$toolbarPanel = [System.Windows.Forms.FlowLayoutPanel]::new()
$toolbarPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$toolbarPanel.BackColor = [System.Drawing.Color]::FromArgb(39, 39, 42)
$toolbarPanel.Padding = [System.Windows.Forms.Padding]::new(10, 8, 10, 6)
$toolbarPanel.WrapContents = $false
$sortLabel = [System.Windows.Forms.Label]::new()
$sortLabel.Text = 'SORT BY'
$sortLabel.AutoSize = $true
$sortLabel.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 8)
$sortLabel.ForeColor = [System.Drawing.Color]::FromArgb(175, 180, 188)
$sortLabel.Margin = [System.Windows.Forms.Padding]::new(0, 10, 8, 0)
$toolbarPanel.Controls.Add($sortLabel)
$sortByInput = [System.Windows.Forms.ComboBox]::new()
$sortByInput.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$sortByInput.Items.AddRange(@('CPU', 'Memory'))
$sortByInput.SelectedIndex = 0
$sortByInput.Width = 110
$sortByInput.Margin = [System.Windows.Forms.Padding]::new(0, 3, 18, 0)
$toolbarPanel.Controls.Add($sortByInput)
$limitLabel = [System.Windows.Forms.Label]::new()
$limitLabel.Text = 'TOP'
$limitLabel.AutoSize = $true
$limitLabel.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 8)
$limitLabel.ForeColor = [System.Drawing.Color]::FromArgb(175, 180, 188)
$limitLabel.Margin = [System.Windows.Forms.Padding]::new(0, 10, 8, 0)
$toolbarPanel.Controls.Add($limitLabel)
$limitInput = [System.Windows.Forms.NumericUpDown]::new()
$limitInput.Minimum = 1
$limitInput.Maximum = 100
$limitInput.Value = 25
$limitInput.Width = 72
$limitInput.Margin = [System.Windows.Forms.Padding]::new(0, 3, 18, 0)
$toolbarPanel.Controls.Add($limitInput)
$refreshButton = [System.Windows.Forms.Button]::new()
$refreshButton.Text = 'Refresh list'
$refreshButton.Size = [System.Drawing.Size]::new(130, 32)
$exportButton = [System.Windows.Forms.Button]::new()
$exportButton.Text = 'Export CSV...'
$exportButton.Size = [System.Drawing.Size]::new(120, 32)
$exportButton.Enabled = $false
$toolbarPanel.Controls.Add($refreshButton)
$toolbarPanel.Controls.Add($exportButton)

foreach ($button in @($refreshButton, $exportButton)) {
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.BackColor = [System.Drawing.Color]::FromArgb(55, 55, 58)
    $button.ForeColor = $form.ForeColor
    $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(80, 80, 85)
    $button.UseVisualStyleBackColor = $false
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
}
$refreshButton.BackColor = [System.Drawing.Color]::FromArgb(45, 105, 95)
$refreshButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(60, 130, 118)
$layout.Controls.Add($toolbarPanel, 0, 1)

$listView = [System.Windows.Forms.ListView]::new()
$listView.Dock = [System.Windows.Forms.DockStyle]::Fill
$listView.Margin = [System.Windows.Forms.Padding]::new(0, 12, 0, 8)
$listView.View = [System.Windows.Forms.View]::Details
$listView.FullRowSelect = $true
$listView.HideSelection = $false
$listView.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 38)
$listView.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 230)
$listView.BorderStyle = 'FixedSingle'
$listView.Columns.Add('PROCESS', 180) | Out-Null
$listView.Columns.Add('PID', 80) | Out-Null
$listView.Columns.Add('CPU %', 100) | Out-Null
$listView.Columns.Add('WORKING SET', 130) | Out-Null
$listView.Columns.Add('PRIVATE BYTES', 140) | Out-Null
$listView.Columns.Add('SERVICES', 180) | Out-Null
$listView.Columns.Add('EXECUTABLE PATH', 420) | Out-Null
$layout.Controls.Add($listView, 0, 2)
$listView.Add_SizeChanged({
    $availableWidth = $listView.ClientSize.Width - 4
    if ($availableWidth -gt 0) {
        $listView.Columns[0].Width = [Math]::Max(130, [int]($availableWidth * 0.14))
        $listView.Columns[1].Width = [Math]::Max(65, [int]($availableWidth * 0.07))
        $listView.Columns[2].Width = [Math]::Max(85, [int]($availableWidth * 0.09))
        $listView.Columns[3].Width = [Math]::Max(110, [int]($availableWidth * 0.12))
        $listView.Columns[4].Width = [Math]::Max(120, [int]($availableWidth * 0.13))
        $listView.Columns[5].Width = [Math]::Max(150, [int]($availableWidth * 0.16))
        $listView.Columns[6].Width = [Math]::Max(160, $availableWidth - $listView.Columns[0].Width - $listView.Columns[1].Width - $listView.Columns[2].Width - $listView.Columns[3].Width - $listView.Columns[4].Width - $listView.Columns[5].Width)
    }
})
Set-PolishedListView -ListView $listView

$statusLabel = [System.Windows.Forms.Label]::new()
$statusLabel.Text = 'Choose CPU or memory, then refresh the list.'
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

$script:processRows = @()
$script:scanPowerShell = $null
$script:scanRunspace = $null
$script:scanAsyncResult = $null
$script:scanProgressState = $null
$scanTimer = [System.Windows.Forms.Timer]::new()
$scanTimer.Interval = 150

function Add-ProcessResults {
    param([Parameter(Mandatory)]$Result)

    $listView.Columns[2].Text = if ($Result.SortBy -eq 'CPU') { 'CPU %' } else { 'RAM %' }
    $script:processRows = @($Result.Processes)
    $listView.BeginUpdate()
    try {
        $listView.Items.Clear()
        foreach ($process in $script:processRows) {
            $row = [System.Windows.Forms.ListViewItem]::new($process.ProcessName)
            $row.SubItems.Add($process.Id.ToString()) | Out-Null
            $metricPercent = if ($Result.SortBy -eq 'CPU') { $process.CpuPercent } else { $process.RamPercent }
            $metricText = if ($null -eq $metricPercent) { 'Unavailable' } else { '{0:N1}%' -f $metricPercent }
            $row.SubItems.Add($metricText) | Out-Null
            $row.SubItems.Add((Format-ProcessMemory -Bytes $process.WorkingSet)) | Out-Null
            $row.SubItems.Add((Format-ProcessMemory -Bytes $process.PrivateBytes)) | Out-Null
            $row.SubItems.Add($process.Services) | Out-Null
            $row.SubItems.Add($process.ExecutablePath) | Out-Null
            $row.Tag = $process
            $listView.Items.Add($row) | Out-Null
        }
    }
    finally {
        $listView.EndUpdate()
    }

    $sortDescription = if ($Result.SortBy -eq 'CPU') {
        "CPU over $([Math]::Max(1, [int][Math]::Round($Result.SampleSeconds))) second sample"
    }
    else {
        'working set (RAM % of physical memory)'
    }
    $statusLabel.Text = "Showing $($Result.Processes.Count) of $($Result.ProcessCount) processes, sorted by $sortDescription."
    $exportButton.Enabled = $script:processRows.Count -gt 0

    if ($Result.Errors.Count -gt 0) {
        $errorText = ($Result.Errors | Select-Object -First 10) -join "`r`n"
        if ($Result.Errors.Count -gt 10) {
            $errorText += "`r`n...and $($Result.Errors.Count - 10) more."
        }
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            "Some process or service details could not be read ($($Result.Errors.Count) warnings):`r`n$errorText",
            'Report completed with warnings',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
}

$scanTimer.Add_Tick({
    if ($script:scanProgressState) {
        $statusLabel.Text = [string]$script:scanProgressState.Stage
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
        Add-ProcessResults -Result $scanOutput[$scanOutput.Count - 1]
    }
    catch {
        $statusLabel.Text = 'Process scan failed.'
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            $_.Exception.Message,
            'Process scan failed',
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
        $refreshButton.Enabled = $true
        $sortByInput.Enabled = $true
        $limitInput.Enabled = $true
    }
})

$form.Add_FormClosed({
    $scanTimer.Stop()
    $scanTimer.Dispose()
})

$refreshButton.Add_Click({
    $refreshButton.Enabled = $false
    $exportButton.Enabled = $false
    $sortByInput.Enabled = $false
    $limitInput.Enabled = $false
    $listView.Items.Clear()
    $listView.Columns[2].Text = if ([string]$sortByInput.SelectedItem -eq 'CPU') { 'CPU %' } else { 'RAM %' }
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $progressBar.Visible = $true
    $statusLabel.Text = 'Starting process scan...'
    $script:scanProgressState = [hashtable]::Synchronized(@{
        Stage = 'Collecting processes...'
    })

    $sortByInput.Add_SelectedIndexChanged({
        if ($refreshButton.Enabled) {
            $refreshButton.PerformClick()
        }
    })

    try {
        $functionSource = (Get-Command Get-ResourceConsumers -CommandType Function).ScriptBlock.ToString()
        $workerScript = @"
param([string]`$SortBy, [int]`$Limit, [System.Collections.IDictionary]`$ProgressState)
function Get-ResourceConsumers {
$functionSource
}
Get-ResourceConsumers -SortBy `$SortBy -Limit `$Limit -ProgressState `$ProgressState
"@
        $script:scanRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $script:scanRunspace.Open()
        $script:scanPowerShell = [powershell]::Create()
        $script:scanPowerShell.Runspace = $script:scanRunspace
        $null = $script:scanPowerShell.AddScript($workerScript)
        $null = $script:scanPowerShell.AddArgument([string]$sortByInput.SelectedItem)
        $null = $script:scanPowerShell.AddArgument([int]$limitInput.Value)
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
        $refreshButton.Enabled = $true
        $sortByInput.Enabled = $true
        $limitInput.Enabled = $true
        $statusLabel.Text = 'Could not start process scan.'
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            $_.Exception.Message,
            'Could not start process scan',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

$exportDialog = [System.Windows.Forms.SaveFileDialog]::new()
$exportDialog.Filter = 'CSV files (*.csv)|*.csv'
$exportDialog.DefaultExt = 'csv'
$exportDialog.AddExtension = $true
$exportDialog.FileName = 'resource-hog-report.csv'
$exportButton.Add_Click({
    if ($script:processRows.Count -eq 0) {
        return
    }
    if ($exportDialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) {
        return
    }

    try {
        $script:processRows |
            Select-Object ProcessName, Id, CpuPercent, RamPercent, WorkingSet, PrivateBytes, TotalPhysicalMemory, Services, ExecutablePath |
            Export-Csv -LiteralPath $exportDialog.FileName -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        $statusLabel.Text = "Exported $($script:processRows.Count) processes to $($exportDialog.FileName)"
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            $_.Exception.Message,
            'Could not export report',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)
