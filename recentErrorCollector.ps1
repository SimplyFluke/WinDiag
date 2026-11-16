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
            elseif ($columnIndex -eq 1) {
                [System.Drawing.Color]::FromArgb(160, 210, 192)
            }
            elseif ($columnIndex -eq 6) {
                [System.Drawing.Color]::FromArgb(185, 190, 198)
            }
            else {
                [System.Drawing.Color]::FromArgb(210, 213, 218)
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
        if ($columnIndex -in @(1, 5)) {
            $format.Alignment = [System.Drawing.StringAlignment]::Far
        }
        if ($columnIndex -eq 0) {
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

function Get-RecentEventSummary {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Last 24 hours', 'Since last boot')]
        [string]$TimeRange,

        [Parameter(Mandatory)]
        [ValidateSet('Both', 'System', 'Application')]
        [string]$LogSelection,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$ProgressState
    )

    $startTime = [DateTime]::Now.AddHours(-24)
    if ($TimeRange -eq 'Since last boot') {
        $ProgressState.Stage = 'Finding the last boot time...'
        try {
            $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -Property LastBootUpTime -ErrorAction Stop
            $startTime = [DateTime]$operatingSystem.LastBootUpTime
        }
        catch {
            throw "Could not determine the last boot time: $($_.Exception.Message)"
        }
    }

    $logs = @(switch ($LogSelection) {
        'System' { @('System') }
        'Application' { @('Application') }
        default { @('System', 'Application') }
    })
    $errors = [System.Collections.Generic.List[string]]::new()
    $groups = @{}
    $eventsRead = 0

    foreach ($logName in $logs) {
        $ProgressState.Stage = "Reading $logName events..."
        $queryErrors = @()
        try {
            Get-WinEvent -FilterHashtable @{
                LogName = $logName
                Level = @(1, 2)
                StartTime = $startTime
            } -ErrorAction SilentlyContinue -ErrorVariable queryErrors |
                ForEach-Object {
                    $eventsRead++
                    $message = [string]$_.Message
                    if ([string]::IsNullOrWhiteSpace($message)) {
                        $message = 'No event message is available.'
                    }
                    $normalizedMessage = [regex]::Replace($message.Trim(), '\s+', ' ')
                    $provider = [string]$_.ProviderName
                    $eventId = [int]$_.Id
                    $level = [int]$_.Level
                    $key = [string]::Join([string][char]0, [string[]]@(
                        $logName,
                        $provider,
                        $eventId.ToString(),
                        $level.ToString(),
                        $normalizedMessage
                    ))

                    if (-not $groups.ContainsKey($key)) {
                        $groups[$key] = [pscustomobject]@{
                            Severity = if ($level -eq 1) { 'Critical' } else { 'Error' }
                            Level = $level
                            Count = 0
                            FirstSeen = $_.TimeCreated
                            LastSeen = $_.TimeCreated
                            Log = $logName
                            Provider = $provider
                            EventId = $eventId
                            Summary = if ($normalizedMessage.Length -gt 220) {
                                $normalizedMessage.Substring(0, 217) + '...'
                            }
                            else {
                                $normalizedMessage
                            }
                            Message = $message
                        }
                    }

                    $group = $groups[$key]
                    $group.Count++
                    if ($_.TimeCreated -lt $group.FirstSeen) {
                        $group.FirstSeen = $_.TimeCreated
                    }
                    if ($_.TimeCreated -gt $group.LastSeen) {
                        $group.LastSeen = $_.TimeCreated
                        $group.Message = $message
                    }
                }
        }
        catch {
            $errors.Add("$logName log: $($_.Exception.Message)")
        }

        foreach ($queryError in $queryErrors) {
            if ($queryError.FullyQualifiedErrorId -notmatch 'NoMatchingEventsFound') {
                $errors.Add("$logName log: $($queryError.Exception.Message)")
            }
        }
    }

    $groupedEvents = @(
        $groups.Values |
            Sort-Object -Property `
                @{ Expression = { if ($_.Level -eq 1) { 0 } else { 1 } }; Descending = $false },
                @{ Expression = 'Count'; Descending = $true },
                @{ Expression = 'LastSeen'; Descending = $true }
    )
    [pscustomobject]@{
        TimeRange = $TimeRange
        StartTime = $startTime
        Logs = $logs
        EventsRead = $eventsRead
        Groups = $groupedEvents
        Errors = @($errors)
    }
}

$form = [System.Windows.Forms.Form]::new()
$form.Text = 'Recent Error & Critical Event Collector'
$form.StartPosition = 'CenterScreen'
$form.Size = [System.Drawing.Size]::new(1220, 820)
$form.MinimumSize = [System.Drawing.Size]::new(900, 600)
$form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$form.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 230)
$form.Font = [System.Drawing.Font]::new('Segoe UI', 9)
$form.Padding = [System.Windows.Forms.Padding]::new(18)

$layout = [System.Windows.Forms.TableLayoutPanel]::new()
$layout.Dock = [System.Windows.Forms.DockStyle]::Fill
$layout.ColumnCount = 1
$layout.RowCount = 5
$layout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)) | Out-Null
$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 72)) | Out-Null
$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 90)) | Out-Null
$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 65)) | Out-Null
$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 150)) | Out-Null
$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 46)) | Out-Null

$headerPanel = [System.Windows.Forms.Panel]::new()
$headerPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$titleLabel = [System.Windows.Forms.Label]::new()
$titleLabel.Text = 'Recent Error & Critical Events'
$titleLabel.Location = [System.Drawing.Point]::new(0, 2)
$titleLabel.AutoSize = $true
$titleLabel.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 19)
$titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
$headerPanel.Controls.Add($titleLabel)
$subtitleLabel = [System.Windows.Forms.Label]::new()
$subtitleLabel.Text = 'Repeated identical events are grouped by source and message, so recurring issues stand out by count.'
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
$rangeLabel = [System.Windows.Forms.Label]::new()
$rangeLabel.Text = 'TIME RANGE'
$rangeLabel.AutoSize = $true
$rangeLabel.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 8)
$rangeLabel.ForeColor = [System.Drawing.Color]::FromArgb(175, 180, 188)
$rangeLabel.Margin = [System.Windows.Forms.Padding]::new(0, 10, 8, 0)
$toolbarPanel.Controls.Add($rangeLabel)
$timeRangeInput = [System.Windows.Forms.ComboBox]::new()
$timeRangeInput.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$timeRangeInput.Items.AddRange(@('Last 24 hours', 'Since last boot'))
$timeRangeInput.SelectedIndex = 0
$timeRangeInput.Width = 150
$timeRangeInput.Margin = [System.Windows.Forms.Padding]::new(0, 3, 18, 0)
$toolbarPanel.Controls.Add($timeRangeInput)
$logLabel = [System.Windows.Forms.Label]::new()
$logLabel.Text = 'LOGS'
$logLabel.AutoSize = $true
$logLabel.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 8)
$logLabel.ForeColor = [System.Drawing.Color]::FromArgb(175, 180, 188)
$logLabel.Margin = [System.Windows.Forms.Padding]::new(0, 10, 8, 0)
$toolbarPanel.Controls.Add($logLabel)
$logInput = [System.Windows.Forms.ComboBox]::new()
$logInput.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$logInput.Items.AddRange(@('Both', 'System', 'Application'))
$logInput.SelectedIndex = 0
$logInput.Width = 120
$logInput.Margin = [System.Windows.Forms.Padding]::new(0, 3, 18, 0)
$toolbarPanel.Controls.Add($logInput)
$refreshButton = [System.Windows.Forms.Button]::new()
$refreshButton.Text = 'Collect events'
$refreshButton.Size = [System.Drawing.Size]::new(135, 32)
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
$listView.Columns.Add('SEVERITY', 100) | Out-Null
$listView.Columns.Add('OCCURRENCES', 110) | Out-Null
$listView.Columns.Add('LAST SEEN', 160) | Out-Null
$listView.Columns.Add('LOG', 110) | Out-Null
$listView.Columns.Add('SOURCE', 210) | Out-Null
$listView.Columns.Add('EVENT ID', 90) | Out-Null
$listView.Columns.Add('MESSAGE SUMMARY', 500) | Out-Null
$layout.Controls.Add($listView, 0, 2)
$listView.Add_SizeChanged({
    $availableWidth = $listView.ClientSize.Width - 4
    if ($availableWidth -gt 0) {
        $listView.Columns[0].Width = [Math]::Max(90, [int]($availableWidth * 0.09))
        $listView.Columns[1].Width = [Math]::Max(100, [int]($availableWidth * 0.10))
        $listView.Columns[2].Width = [Math]::Max(140, [int]($availableWidth * 0.14))
        $listView.Columns[3].Width = [Math]::Max(90, [int]($availableWidth * 0.09))
        $listView.Columns[4].Width = [Math]::Max(150, [int]($availableWidth * 0.15))
        $listView.Columns[5].Width = [Math]::Max(75, [int]($availableWidth * 0.08))
        $listView.Columns[6].Width = [Math]::Max(200, $availableWidth - $listView.Columns[0].Width - $listView.Columns[1].Width - $listView.Columns[2].Width - $listView.Columns[3].Width - $listView.Columns[4].Width - $listView.Columns[5].Width)
    }
})
Set-PolishedListView -ListView $listView

$detailsPanel = [System.Windows.Forms.TableLayoutPanel]::new()
$detailsPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$detailsPanel.RowCount = 2
$detailsPanel.ColumnCount = 1
$detailsPanel.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 24)) | Out-Null
$detailsPanel.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)) | Out-Null
$detailsTitle = [System.Windows.Forms.Label]::new()
$detailsTitle.Text = 'EVENT DETAILS'
$detailsTitle.Dock = [System.Windows.Forms.DockStyle]::Fill
$detailsTitle.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$detailsTitle.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 8)
$detailsTitle.ForeColor = [System.Drawing.Color]::FromArgb(175, 180, 188)
$detailsPanel.Controls.Add($detailsTitle, 0, 0)
$detailsTextBox = [System.Windows.Forms.TextBox]::new()
$detailsTextBox.Dock = [System.Windows.Forms.DockStyle]::Fill
$detailsTextBox.Multiline = $true
$detailsTextBox.ReadOnly = $true
$detailsTextBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$detailsTextBox.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 38)
$detailsTextBox.ForeColor = [System.Drawing.Color]::FromArgb(215, 218, 224)
$detailsTextBox.BorderStyle = 'FixedSingle'
$detailsPanel.Controls.Add($detailsTextBox, 0, 1)
$layout.Controls.Add($detailsPanel, 0, 3)

$statusLabel = [System.Windows.Forms.Label]::new()
$statusLabel.Text = 'Choose a time range and log scope, then collect events.'
$statusLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
$statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$statusLabel.AutoEllipsis = $true
$statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(175, 180, 188)
$statusLabel.Padding = [System.Windows.Forms.Padding]::new(2, 0, 0, 0)
$layout.Controls.Add($statusLabel, 0, 4)
$form.Controls.Add($layout)

$script:eventGroups = @()
$script:scanPowerShell = $null
$script:scanRunspace = $null
$script:scanAsyncResult = $null
$script:scanProgressState = $null
$scanTimer = [System.Windows.Forms.Timer]::new()
$scanTimer.Interval = 150

function Update-EventDetails {
    if (-not $listView.SelectedItems.Count) {
        $detailsTextBox.Clear()
        return
    }

    $eventGroup = $listView.SelectedItems[0].Tag
    $detailsTextBox.Text = @(
        "Severity: $($eventGroup.Severity)"
        "Log: $($eventGroup.Log)"
        "Provider: $($eventGroup.Provider)"
        "Event ID: $($eventGroup.EventId)"
        "Occurrences: $($eventGroup.Count)"
        "First seen: $($eventGroup.FirstSeen.ToString('yyyy-MM-dd HH:mm:ss'))"
        "Last seen: $($eventGroup.LastSeen.ToString('yyyy-MM-dd HH:mm:ss'))"
        ''
        $eventGroup.Message
    ) -join "`r`n"
}

function Show-EventSummary {
    param([Parameter(Mandatory)]$Report)

    $script:eventGroups = @($Report.Groups)
    $listView.BeginUpdate()
    try {
        $listView.Items.Clear()
        foreach ($eventGroup in $script:eventGroups) {
            $row = [System.Windows.Forms.ListViewItem]::new($eventGroup.Severity)
            $row.SubItems.Add($eventGroup.Count.ToString('N0')) | Out-Null
            $row.SubItems.Add($eventGroup.LastSeen.ToString('yyyy-MM-dd HH:mm:ss')) | Out-Null
            $row.SubItems.Add($eventGroup.Log) | Out-Null
            $row.SubItems.Add($eventGroup.Provider) | Out-Null
            $row.SubItems.Add($eventGroup.EventId.ToString()) | Out-Null
            $row.SubItems.Add($eventGroup.Summary) | Out-Null
            $row.Tag = $eventGroup
            if ($eventGroup.Level -eq 1) {
                $row.ForeColor = [System.Drawing.Color]::FromArgb(255, 125, 115)
            }
            else {
                $row.ForeColor = [System.Drawing.Color]::FromArgb(255, 195, 115)
            }
            $listView.Items.Add($row) | Out-Null
        }
    }
    finally {
        $listView.EndUpdate()
    }

    if ($listView.Items.Count -gt 0) {
        $listView.Items[0].Selected = $true
        $listView.Items[0].Focused = $true
        Update-EventDetails
    }
    else {
        $detailsTextBox.Text = 'No Critical or Error events were found for this time range and log selection.'
    }

    $criticalOccurrences = [long](($script:eventGroups | Where-Object { $_.Level -eq 1 } | Measure-Object -Property Count -Sum).Sum)
    $errorOccurrences = [long](($script:eventGroups | Where-Object { $_.Level -eq 2 } | Measure-Object -Property Count -Sum).Sum)
    $statusLabel.Text = "Found $($script:eventGroups.Count) grouped events from $($Report.EventsRead) records: $criticalOccurrences critical and $errorOccurrences error occurrences since $($Report.StartTime.ToString('yyyy-MM-dd HH:mm'))."
    $exportButton.Enabled = $script:eventGroups.Count -gt 0

    if ($Report.Errors.Count -gt 0) {
        $errorText = ($Report.Errors | Select-Object -First 10) -join "`r`n"
        if ($Report.Errors.Count -gt 10) {
            $errorText += "`r`n...and $($Report.Errors.Count - 10) more."
        }
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            "Some event logs could not be queried ($($Report.Errors.Count) warnings):`r`n$errorText",
            'Collection completed with warnings',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
}

$listView.Add_SelectedIndexChanged({
    Update-EventDetails
})

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
            throw 'The event query completed without returning results.'
        }
        Show-EventSummary -Report $scanOutput[$scanOutput.Count - 1]
    }
    catch {
        $statusLabel.Text = 'Event collection failed.'
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            $_.Exception.Message,
            'Event collection failed',
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
        $timeRangeInput.Enabled = $true
        $logInput.Enabled = $true
    }
})

$form.Add_FormClosed({
    $scanTimer.Stop()
    $scanTimer.Dispose()
})

$refreshButton.Add_Click({
    $refreshButton.Enabled = $false
    $exportButton.Enabled = $false
    $timeRangeInput.Enabled = $false
    $logInput.Enabled = $false
    $listView.Items.Clear()
    $detailsTextBox.Clear()
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $progressBar.Visible = $true
    $statusLabel.Text = 'Starting event collection...'
    $script:scanProgressState = [hashtable]::Synchronized(@{
        Stage = 'Preparing event query...'
    })

    try {
        $functionSource = (Get-Command Get-RecentEventSummary -CommandType Function).ScriptBlock.ToString()
        $workerScript = @"
param([string]`$TimeRange, [string]`$LogSelection, [System.Collections.IDictionary]`$ProgressState)
function Get-RecentEventSummary {
$functionSource
}
Get-RecentEventSummary -TimeRange `$TimeRange -LogSelection `$LogSelection -ProgressState `$ProgressState
"@
        $script:scanRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $script:scanRunspace.Open()
        $script:scanPowerShell = [powershell]::Create()
        $script:scanPowerShell.Runspace = $script:scanRunspace
        $null = $script:scanPowerShell.AddScript($workerScript)
        $null = $script:scanPowerShell.AddArgument([string]$timeRangeInput.SelectedItem)
        $null = $script:scanPowerShell.AddArgument([string]$logInput.SelectedItem)
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
        $timeRangeInput.Enabled = $true
        $logInput.Enabled = $true
        $statusLabel.Text = 'Could not start event collection.'
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            $_.Exception.Message,
            'Could not start event collection',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

$exportDialog = [System.Windows.Forms.SaveFileDialog]::new()
$exportDialog.Filter = 'CSV files (*.csv)|*.csv'
$exportDialog.DefaultExt = 'csv'
$exportDialog.AddExtension = $true
$exportDialog.FileName = 'recent-error-events.csv'
$exportButton.Add_Click({
    if ($script:eventGroups.Count -eq 0) {
        return
    }
    if ($exportDialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) {
        return
    }

    try {
        $script:eventGroups |
            Select-Object Severity, Count, FirstSeen, LastSeen, Log, Provider, EventId, Summary, Message |
            Export-Csv -LiteralPath $exportDialog.FileName -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        $statusLabel.Text = "Exported $($script:eventGroups.Count) event groups to $($exportDialog.FileName)"
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            $_.Exception.Message,
            'Could not export event report',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)
