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
            $foreColor = if ($columnIndex -eq 0) {
                $item.ForeColor
            }
            elseif ($columnIndex -eq 2) {
                [System.Drawing.Color]::FromArgb(160, 210, 192)
            }
            elseif ($columnIndex -eq 7) {
                [System.Drawing.Color]::FromArgb(170, 176, 185)
            }
            else {
                [System.Drawing.Color]::FromArgb(205, 208, 214)
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
        if ($columnIndex -in @(2, 4)) {
            $format.Alignment = [System.Drawing.StringAlignment]::Far
        }
        if ($columnIndex -in @(0, 3)) {
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

function Get-LocalPortReport {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [int[]]$Ports,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$ProgressState
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $connections = [System.Collections.Generic.List[object]]::new()
    $tcpErrors = @()
    $ProgressState.Stage = 'Reading TCP listeners...'
    try {
        Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue -ErrorVariable tcpErrors |
            ForEach-Object {
                if ($Ports.Count -eq 0 -or $Ports -contains [int]$_.LocalPort) {
                    $connections.Add([pscustomobject]@{
                        Protocol = 'TCP'
                        LocalAddress = [string]$_.LocalAddress
                        Port = [int]$_.LocalPort
                        State = [string]$_.State
                        ProcessId = [int]$_.OwningProcess
                    })
                }
            }
    }
    catch {
        $errors.Add("Could not read TCP listeners: $($_.Exception.Message)")
    }
    foreach ($errorRecord in $tcpErrors) {
        $errors.Add("TCP listeners: $($errorRecord.Exception.Message)")
    }

    $udpErrors = @()
    $ProgressState.Stage = 'Reading UDP endpoints...'
    try {
        Get-NetUDPEndpoint -ErrorAction SilentlyContinue -ErrorVariable udpErrors |
            ForEach-Object {
                if ($Ports.Count -eq 0 -or $Ports -contains [int]$_.LocalPort) {
                    $connections.Add([pscustomobject]@{
                        Protocol = 'UDP'
                        LocalAddress = [string]$_.LocalAddress
                        Port = [int]$_.LocalPort
                        State = 'Bound'
                        ProcessId = [int]$_.OwningProcess
                    })
                }
            }
    }
    catch {
        $errors.Add("Could not read UDP endpoints: $($_.Exception.Message)")
    }
    foreach ($errorRecord in $udpErrors) {
        $errors.Add("UDP endpoints: $($errorRecord.Exception.Message)")
    }

    $ProgressState.Stage = 'Associating processes and services...'
    $servicesByProcess = @{}
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

    $processInfoById = @{}
    foreach ($processId in @($connections | Select-Object -ExpandProperty ProcessId -Unique)) {
        try {
            $process = Get-Process -Id $processId -ErrorAction Stop
            $processPath = 'Unavailable'
            try {
                if (-not [string]::IsNullOrWhiteSpace([string]$process.Path)) {
                    $processPath = [string]$process.Path
                }
            }
            catch {
                $processPath = 'Access denied'
            }

            $serviceNames = '-'
            if ($servicesByProcess.ContainsKey([int]$processId)) {
                $serviceNames = $servicesByProcess[[int]$processId] -join ', '
            }
            $processInfoById[[int]$processId] = [pscustomobject]@{
                ProcessName = [string]$process.ProcessName
                ExecutablePath = $processPath
                Services = $serviceNames
            }
        }
        catch {
            $errors.Add("Could not resolve process PID ${processId}: $($_.Exception.Message)")
            $processInfoById[[int]$processId] = [pscustomobject]@{
                ProcessName = 'Unavailable'
                ExecutablePath = 'Unavailable'
                Services = '-'
            }
        }
    }

    $rows = @(
        foreach ($connection in $connections) {
            $processInfo = $processInfoById[[int]$connection.ProcessId]
            [pscustomobject]@{
                Protocol = $connection.Protocol
                LocalAddress = $connection.LocalAddress
                Port = $connection.Port
                State = $connection.State
                ProcessId = $connection.ProcessId
                ProcessName = $processInfo.ProcessName
                Services = $processInfo.Services
                ExecutablePath = $processInfo.ExecutablePath
            }
        }
    )
    $sortedRows = @($rows | Sort-Object -Property Port, Protocol, LocalAddress, ProcessId)

    [pscustomobject]@{
        Rows = $sortedRows
        ListenerCount = $sortedRows.Count
        Ports = @($Ports)
        Errors = @($errors)
    }
}

function ConvertTo-PortFilter {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return [int[]]@()
    }

    $portValues = [System.Collections.Generic.List[int]]::new()
    foreach ($value in $Text.Split(',')) {
        $trimmedValue = $value.Trim()
        if ($trimmedValue -notmatch '^\d+$') {
            throw "Invalid port '$trimmedValue'. Enter comma-separated port numbers from 1 to 65535."
        }

        $port = 0
        if (-not [int]::TryParse($trimmedValue, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
            throw "Port '$trimmedValue' is outside the valid range of 1 to 65535."
        }
        if (-not $portValues.Contains($port)) {
            $portValues.Add($port)
        }
    }

    [int[]]@($portValues)
}

$form = [System.Windows.Forms.Form]::new()
$form.Text = 'Port Checker / Local Listener'
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
$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 100)) | Out-Null
$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)) | Out-Null
$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 46)) | Out-Null

$headerPanel = [System.Windows.Forms.Panel]::new()
$headerPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$titleLabel = [System.Windows.Forms.Label]::new()
$titleLabel.Text = 'Port Checker / Local Listener'
$titleLabel.Location = [System.Drawing.Point]::new(0, 2)
$titleLabel.AutoSize = $true
$titleLabel.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 19)
$titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
$headerPanel.Controls.Add($titleLabel)
$subtitleLabel = [System.Windows.Forms.Label]::new()
$subtitleLabel.Text = 'Inspect local TCP listeners and UDP-bound ports, including their owning process and services.'
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

$portsLabel = [System.Windows.Forms.Label]::new()
$portsLabel.Text = 'PORTS'
$portsLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
$portsLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$portsLabel.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 8)
$portsLabel.ForeColor = [System.Drawing.Color]::FromArgb(175, 180, 188)
$toolbarLayout.Controls.Add($portsLabel, 0, 0)

$portsTextBox = [System.Windows.Forms.TextBox]::new()
$portsTextBox.Dock = [System.Windows.Forms.DockStyle]::Fill
$portsTextBox.Margin = [System.Windows.Forms.Padding]::new(0, 4, 8, 4)
$portsTextBox.Text = '80, 443, 3389'
$portsTextBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$portsTextBox.ForeColor = $form.ForeColor
$portsTextBox.BorderStyle = 'FixedSingle'
$toolbarLayout.Controls.Add($portsTextBox, 1, 0)

$checkButton = [System.Windows.Forms.Button]::new()
$checkButton.Text = 'Check ports'
$checkButton.Dock = [System.Windows.Forms.DockStyle]::Fill
$checkButton.Margin = [System.Windows.Forms.Padding]::new(0, 2, 0, 2)
$toolbarLayout.Controls.Add($checkButton, 2, 0)

$actionsPanel = [System.Windows.Forms.FlowLayoutPanel]::new()
$actionsPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$actionsPanel.WrapContents = $false
$actionsPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$actionsPanel.Padding = [System.Windows.Forms.Padding]::new(0, 2, 0, 0)
$filterHint = [System.Windows.Forms.Label]::new()
$filterHint.Text = 'Comma-separated ports; leave blank to show all.'
$filterHint.AutoSize = $true
$filterHint.ForeColor = [System.Drawing.Color]::FromArgb(175, 180, 188)
$filterHint.Margin = [System.Windows.Forms.Padding]::new(0, 8, 12, 0)
$actionsPanel.Controls.Add($filterHint)
$exportButton = [System.Windows.Forms.Button]::new()
$exportButton.Text = 'Export CSV...'
$exportButton.Size = [System.Drawing.Size]::new(120, 32)
$exportButton.Enabled = $false
$actionsPanel.Controls.Add($exportButton)
$toolbarLayout.Controls.Add($actionsPanel, 0, 1)
$toolbarLayout.SetColumnSpan($actionsPanel, 3)

foreach ($button in @($checkButton, $exportButton)) {
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.BackColor = [System.Drawing.Color]::FromArgb(55, 55, 58)
    $button.ForeColor = $form.ForeColor
    $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(80, 80, 85)
    $button.UseVisualStyleBackColor = $false
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
}
$checkButton.BackColor = [System.Drawing.Color]::FromArgb(45, 105, 95)
$checkButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(60, 130, 118)
$layout.Controls.Add($toolbarPanel, 0, 1)
$toolbarPanel.Controls.Add($toolbarLayout)

$listView = [System.Windows.Forms.ListView]::new()
$listView.Dock = [System.Windows.Forms.DockStyle]::Fill
$listView.Margin = [System.Windows.Forms.Padding]::new(0, 12, 0, 8)
$listView.View = [System.Windows.Forms.View]::Details
$listView.FullRowSelect = $true
$listView.HideSelection = $false
$listView.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 38)
$listView.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 230)
$listView.BorderStyle = 'FixedSingle'
$listView.Columns.Add('PROTOCOL', 90) | Out-Null
$listView.Columns.Add('LOCAL ADDRESS', 180) | Out-Null
$listView.Columns.Add('PORT', 80) | Out-Null
$listView.Columns.Add('STATE', 100) | Out-Null
$listView.Columns.Add('PID', 80) | Out-Null
$listView.Columns.Add('PROCESS', 180) | Out-Null
$listView.Columns.Add('SERVICES', 180) | Out-Null
$listView.Columns.Add('EXECUTABLE PATH', 420) | Out-Null
$layout.Controls.Add($listView, 0, 2)
$listView.Add_SizeChanged({
    $availableWidth = $listView.ClientSize.Width - 4
    if ($availableWidth -gt 0) {
        $listView.Columns[0].Width = [Math]::Max(75, [int]($availableWidth * 0.08))
        $listView.Columns[1].Width = [Math]::Max(140, [int]($availableWidth * 0.15))
        $listView.Columns[2].Width = [Math]::Max(65, [int]($availableWidth * 0.07))
        $listView.Columns[3].Width = [Math]::Max(80, [int]($availableWidth * 0.08))
        $listView.Columns[4].Width = [Math]::Max(65, [int]($availableWidth * 0.07))
        $listView.Columns[5].Width = [Math]::Max(130, [int]($availableWidth * 0.14))
        $listView.Columns[6].Width = [Math]::Max(140, [int]($availableWidth * 0.15))
        $listView.Columns[7].Width = [Math]::Max(180, $availableWidth - $listView.Columns[0].Width - $listView.Columns[1].Width - $listView.Columns[2].Width - $listView.Columns[3].Width - $listView.Columns[4].Width - $listView.Columns[5].Width - $listView.Columns[6].Width)
    }
})
Set-PolishedListView -ListView $listView

$statusLabel = [System.Windows.Forms.Label]::new()
$statusLabel.Text = 'Enter ports to check, or leave blank for all ports.'
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

$script:portRows = @()
$script:scanPowerShell = $null
$script:scanRunspace = $null
$script:scanAsyncResult = $null
$script:scanProgressState = $null
$scanTimer = [System.Windows.Forms.Timer]::new()
$scanTimer.Interval = 150

function Show-PortReport {
    param([Parameter(Mandatory)]$Result)

    $script:portRows = @($Result.Rows)
    $listView.BeginUpdate()
    try {
        $listView.Items.Clear()
        foreach ($entry in $script:portRows) {
            $row = [System.Windows.Forms.ListViewItem]::new($entry.Protocol)
            $row.SubItems.Add($entry.LocalAddress) | Out-Null
            $row.SubItems.Add($entry.Port.ToString()) | Out-Null
            $row.SubItems.Add($entry.State) | Out-Null
            $row.SubItems.Add($entry.ProcessId.ToString()) | Out-Null
            $row.SubItems.Add($entry.ProcessName) | Out-Null
            $row.SubItems.Add($entry.Services) | Out-Null
            $row.SubItems.Add($entry.ExecutablePath) | Out-Null
            $row.Tag = $entry
            if ($entry.Protocol -eq 'TCP') {
                $row.ForeColor = [System.Drawing.Color]::FromArgb(150, 205, 230)
            }
            else {
                $row.ForeColor = [System.Drawing.Color]::FromArgb(235, 185, 125)
            }
            $listView.Items.Add($row) | Out-Null
        }
    }
    finally {
        $listView.EndUpdate()
    }

    $filterDescription = if ($Result.Ports.Count -eq 0) { 'all ports' } else { "ports $($Result.Ports -join ', ')" }
    $statusLabel.Text = "Found $($Result.ListenerCount) local endpoints for $filterDescription."
    $exportButton.Enabled = $script:portRows.Count -gt 0

    if ($Result.Errors.Count -gt 0) {
        $errorText = ($Result.Errors | Select-Object -First 10) -join "`r`n"
        if ($Result.Errors.Count -gt 10) {
            $errorText += "`r`n...and $($Result.Errors.Count - 10) more."
        }
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            "Some endpoint or process details could not be read ($($Result.Errors.Count) warnings):`r`n$errorText",
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
        Show-PortReport -Result $scanOutput[$scanOutput.Count - 1]
    }
    catch {
        $statusLabel.Text = 'Port scan failed.'
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            $_.Exception.Message,
            'Port scan failed',
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
        $checkButton.Enabled = $true
        $portsTextBox.Enabled = $true
    }
})

$form.Add_FormClosed({
    $scanTimer.Stop()
    $scanTimer.Dispose()
})

$checkButton.Add_Click({
    try {
        $ports = ConvertTo-PortFilter -Text $portsTextBox.Text
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            $_.Exception.Message,
            'Invalid port filter',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    $checkButton.Enabled = $false
    $portsTextBox.Enabled = $false
    $exportButton.Enabled = $false
    $listView.Items.Clear()
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $progressBar.Visible = $true
    $statusLabel.Text = 'Starting port scan...'
    $script:scanProgressState = [hashtable]::Synchronized(@{
        Stage = 'Reading TCP listeners...'
    })

    try {
        $functionSource = (Get-Command Get-LocalPortReport -CommandType Function).ScriptBlock.ToString()
        $workerScript = @"
param([int[]]`$Ports, [System.Collections.IDictionary]`$ProgressState)
function Get-LocalPortReport {
$functionSource
}
Get-LocalPortReport -Ports `$Ports -ProgressState `$ProgressState
"@
        $script:scanRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $script:scanRunspace.Open()
        $script:scanPowerShell = [powershell]::Create()
        $script:scanPowerShell.Runspace = $script:scanRunspace
        $null = $script:scanPowerShell.AddScript($workerScript)
        $null = $script:scanPowerShell.AddArgument($ports)
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
        $checkButton.Enabled = $true
        $portsTextBox.Enabled = $true
        $statusLabel.Text = 'Could not start port scan.'
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            $_.Exception.Message,
            'Could not start port scan',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

$exportDialog = [System.Windows.Forms.SaveFileDialog]::new()
$exportDialog.Filter = 'CSV files (*.csv)|*.csv'
$exportDialog.DefaultExt = 'csv'
$exportDialog.AddExtension = $true
$exportDialog.FileName = 'local-port-report.csv'
$exportButton.Add_Click({
    if ($script:portRows.Count -eq 0) {
        return
    }
    if ($exportDialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) {
        return
    }

    try {
        $script:portRows |
            Select-Object Protocol, LocalAddress, Port, State, ProcessId, ProcessName, Services, ExecutablePath |
            Export-Csv -LiteralPath $exportDialog.FileName -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        $statusLabel.Text = "Exported $($script:portRows.Count) endpoints to $($exportDialog.FileName)"
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
