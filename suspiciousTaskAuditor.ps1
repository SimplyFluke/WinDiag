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
            $foreColor = if ($EventArgs.ColumnIndex -eq 0) {
                $item.ForeColor
            }
            elseif ($EventArgs.ColumnIndex -eq 3) {
                [System.Drawing.Color]::FromArgb(170, 176, 185)
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
        if ($EventArgs.ColumnIndex -eq 1) {
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

function Get-SuspiciousTaskReport {
    param(
        [Parameter(Mandatory)]
        [bool]$IncludeMicrosoftTasks,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$ProgressState
    )

    $ProgressState.Stage = 'Listing scheduled tasks...'
    $tasks = @(Get-ScheduledTask -ErrorAction Stop)
    $microsoftCount = 0
    $rows = [System.Collections.Generic.List[object]]::new()
    $taskCount = $tasks.Count

    for ($index = 0; $index -lt $tasks.Count; $index++) {
        $task = $tasks[$index]
        $ProgressState.Stage = "Inspecting task $($index + 1) of $taskCount..."
        $taskPath = [string]$task.TaskPath
        $isMicrosoftTask = $taskPath -match '(?i)^\\Microsoft\\'
        if ($isMicrosoftTask) {
            $microsoftCount++
            if (-not $IncludeMicrosoftTasks) {
                continue
            }
        }

        $actions = [System.Collections.Generic.List[object]]::new()
        $executables = [System.Collections.Generic.List[string]]::new()
        $arguments = [System.Collections.Generic.List[string]]::new()
        $workingDirectories = [System.Collections.Generic.List[string]]::new()
        foreach ($action in @($task.Actions)) {
            $execute = [string]$action.Execute
            $actionArguments = [string]$action.Arguments
            $workingDirectory = [string]$action.WorkingDirectory
            $actionType = if ($action.CimClass.CimClassName) {
                [string]$action.CimClass.CimClassName
            }
            else {
                $action.GetType().Name
            }
            if (-not [string]::IsNullOrWhiteSpace($execute)) {
                $executables.Add($execute)
            }
            if (-not [string]::IsNullOrWhiteSpace($actionArguments)) {
                $arguments.Add($actionArguments)
            }
            if (-not [string]::IsNullOrWhiteSpace($workingDirectory)) {
                $workingDirectories.Add($workingDirectory)
            }

            $actionDescription = if ($execute) {
                $execute
            }
            elseif ($action.ClassId) {
                "COM handler $($action.ClassId)"
            }
            else {
                $actionType
            }
            $actions.Add([pscustomobject]@{
                Type = $actionType
                Execute = $execute
                Arguments = $actionArguments
                WorkingDirectory = $workingDirectory
                Description = $actionDescription
            })
        }

        $combinedActionText = @(
            $executables
            $arguments
            $workingDirectories
        ) -join "`r`n"
        $expandedActionText = [Environment]::ExpandEnvironmentVariables($combinedActionText)
        $flags = [System.Collections.Generic.List[string]]::new()
        if ($expandedActionText -match '(?i)(?:%appdata%|%localappdata%|[\\/]+AppData[\\/])') {
            $flags.Add('References AppData')
        }
        if ($expandedActionText -match '(?i)(?:%temp%|%tmp%|[\\/]+(?:Temp|Tmp)[\\/])') {
            $flags.Add('References a Temp directory')
        }
        if ($expandedActionText -match '(?i)(?:%public%|[\\/]+Users[\\/]Public(?:[\\/]|$))') {
            $flags.Add('References the Public folder')
        }
        if ($expandedActionText -match '(?i)\b(?:powershell|pwsh)(?:\.exe)?\b' -and
            $expandedActionText -match '(?i)(?:^|\s)-(?:enc(?:odedcommand)?)(?::|\s|$)') {
            $flags.Add('Uses an encoded PowerShell command')
        }

        $triggerDescriptions = [System.Collections.Generic.List[string]]::new()
        foreach ($trigger in @($task.Triggers)) {
            $triggerType = if ($trigger.CimClass.CimClassName) {
                [string]$trigger.CimClass.CimClassName
            }
            else {
                $trigger.GetType().Name
            }
            $triggerDescriptions.Add($triggerType)
        }

        $author = [string]$task.Author
        $description = [string]$task.Description
        $state = [string]$task.State
        $actionSummary = if ($actions.Count -gt 0) {
            ($actions | ForEach-Object { $_.Description }) -join ' | '
        }
        else {
            'No action details'
        }
        $argumentSummary = $arguments -join ' | '
        $workingDirectorySummary = $workingDirectories -join ' | '
        $rows.Add([pscustomobject]@{
            Finding = if ($flags.Count -gt 0) { 'Flagged' } else { 'Review' }
            Flags = if ($flags.Count -gt 0) { $flags -join '; ' } else { 'No known indicators' }
            TaskName = [string]$task.TaskName
            TaskPath = $taskPath
            State = $state
            Author = $author
            Description = $description
            Actions = @($actions)
            ActionSummary = $actionSummary
            Arguments = $argumentSummary
            WorkingDirectory = $workingDirectorySummary
            Triggers = @($triggerDescriptions)
            IsMicrosoftTask = $isMicrosoftTask
        })
    }

    $sortedRows = @(
        $rows |
            Sort-Object -Property @{ Expression = { if ($_.Finding -eq 'Flagged') { 0 } else { 1 } }; Descending = $false }, TaskName, TaskPath
    )
    [pscustomobject]@{
        TasksScanned = $taskCount
        MicrosoftTasksExcluded = if ($IncludeMicrosoftTasks) { 0 } else { $microsoftCount }
        Rows = $sortedRows
    }
}

$form = [System.Windows.Forms.Form]::new()
$form.Text = 'Suspicious Scheduled Task Auditor'
$form.StartPosition = 'CenterScreen'
$form.Size = [System.Drawing.Size]::new(1220, 800)
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
$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 60)) | Out-Null
$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 65)) | Out-Null
$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 150)) | Out-Null
$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 46)) | Out-Null

$headerPanel = [System.Windows.Forms.Panel]::new()
$headerPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$titleLabel = [System.Windows.Forms.Label]::new()
$titleLabel.Text = 'Suspicious Scheduled Task Auditor'
$titleLabel.Location = [System.Drawing.Point]::new(0, 2)
$titleLabel.AutoSize = $true
$titleLabel.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 19)
$titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
$headerPanel.Controls.Add($titleLabel)
$subtitleLabel = [System.Windows.Forms.Label]::new()
$subtitleLabel.Text = 'Flags unusual launch paths and encoded PowerShell for review; flagged tasks are not automatically malicious.'
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
$includeMicrosoftCheckBox = [System.Windows.Forms.CheckBox]::new()
$includeMicrosoftCheckBox.Text = 'Include Microsoft task paths'
$includeMicrosoftCheckBox.AutoSize = $true
$includeMicrosoftCheckBox.Checked = $false
$includeMicrosoftCheckBox.ForeColor = [System.Drawing.Color]::FromArgb(200, 204, 210)
$includeMicrosoftCheckBox.Margin = [System.Windows.Forms.Padding]::new(0, 7, 18, 0)
$toolbarPanel.Controls.Add($includeMicrosoftCheckBox)
$refreshButton = [System.Windows.Forms.Button]::new()
$refreshButton.Text = 'Scan scheduled tasks'
$refreshButton.Size = [System.Drawing.Size]::new(155, 32)
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
$listView.Columns.Add('FINDING', 95) | Out-Null
$listView.Columns.Add('STATE', 95) | Out-Null
$listView.Columns.Add('TASK', 190) | Out-Null
$listView.Columns.Add('ACTION', 230) | Out-Null
$listView.Columns.Add('FLAGS', 230) | Out-Null
$listView.Columns.Add('TASK PATH', 260) | Out-Null
$layout.Controls.Add($listView, 0, 2)
$listView.Add_SizeChanged({
    $availableWidth = $listView.ClientSize.Width - 4
    if ($availableWidth -gt 0) {
        $listView.Columns[0].Width = [Math]::Max(85, [int]($availableWidth * 0.09))
        $listView.Columns[1].Width = [Math]::Max(85, [int]($availableWidth * 0.09))
        $listView.Columns[2].Width = [Math]::Max(140, [int]($availableWidth * 0.16))
        $listView.Columns[3].Width = [Math]::Max(180, [int]($availableWidth * 0.20))
        $listView.Columns[4].Width = [Math]::Max(190, [int]($availableWidth * 0.20))
        $listView.Columns[5].Width = [Math]::Max(180, $availableWidth - $listView.Columns[0].Width - $listView.Columns[1].Width - $listView.Columns[2].Width - $listView.Columns[3].Width - $listView.Columns[4].Width)
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
$detailsTitle.Text = 'TASK DETAILS'
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
$statusLabel.Text = 'Scan scheduled tasks to review non-Microsoft entries.'
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
$layout.Controls.Add($statusPanel, 0, 4)
$form.Controls.Add($layout)

$script:taskRows = @()
$script:scanPowerShell = $null
$script:scanRunspace = $null
$script:scanAsyncResult = $null
$script:scanProgressState = $null
$scanTimer = [System.Windows.Forms.Timer]::new()
$scanTimer.Interval = 150

function Update-TaskDetails {
    if (-not $listView.SelectedItems.Count) {
        $detailsTextBox.Clear()
        return
    }

    $task = $listView.SelectedItems[0].Tag
    $actionDetails = @(
        foreach ($action in $task.Actions) {
            "Type: $($action.Type)"
            "Execute: $($action.Execute)"
            "Arguments: $($action.Arguments)"
            "Working directory: $($action.WorkingDirectory)"
            ''
        }
    ) -join "`r`n"
    $detailsTextBox.Text = @(
        "Task: $($task.TaskPath)$($task.TaskName)"
        "State: $($task.State)"
        "Author: $($task.Author)"
        "Description: $($task.Description)"
        "Flags: $($task.Flags)"
        "Triggers: $($task.Triggers -join ', ')"
        ''
        $actionDetails
    ) -join "`r`n"
}

function Show-TaskReport {
    param([Parameter(Mandatory)]$Report)

    $script:taskRows = @($Report.Rows)
    $listView.BeginUpdate()
    try {
        $listView.Items.Clear()
        foreach ($task in $script:taskRows) {
            $row = [System.Windows.Forms.ListViewItem]::new($task.Finding)
            $row.SubItems.Add($task.State) | Out-Null
            $row.SubItems.Add($task.TaskName) | Out-Null
            $row.SubItems.Add($task.ActionSummary) | Out-Null
            $row.SubItems.Add($task.Flags) | Out-Null
            $row.SubItems.Add($task.TaskPath) | Out-Null
            $row.Tag = $task
            if ($task.Finding -eq 'Flagged') {
                $row.ForeColor = [System.Drawing.Color]::FromArgb(255, 155, 120)
            }
            else {
                $row.ForeColor = [System.Drawing.Color]::FromArgb(180, 195, 210)
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
        Update-TaskDetails
    }
    else {
        $detailsTextBox.Text = 'No scheduled tasks matched the current filter.'
    }

    $flaggedCount = @($script:taskRows | Where-Object { $_.Finding -eq 'Flagged' }).Count
    $statusLabel.Text = "Scanned $($Report.TasksScanned) tasks; excluded $($Report.MicrosoftTasksExcluded) Microsoft task paths; $flaggedCount flagged for review."
    $exportButton.Enabled = $script:taskRows.Count -gt 0
}

$listView.Add_SelectedIndexChanged({
    Update-TaskDetails
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
            throw 'The scheduled-task scan completed without returning results.'
        }
        Show-TaskReport -Report $scanOutput[$scanOutput.Count - 1]
    }
    catch {
        $statusLabel.Text = 'Task scan failed.'
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            $_.Exception.Message,
            'Task scan failed',
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
        $includeMicrosoftCheckBox.Enabled = $true
    }
})

$form.Add_FormClosed({
    $scanTimer.Stop()
    $scanTimer.Dispose()
})

$refreshButton.Add_Click({
    $refreshButton.Enabled = $false
    $includeMicrosoftCheckBox.Enabled = $false
    $exportButton.Enabled = $false
    $listView.Items.Clear()
    $detailsTextBox.Clear()
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $progressBar.Visible = $true
    $statusLabel.Text = 'Starting scheduled-task scan...'
    $script:scanProgressState = [hashtable]::Synchronized(@{
        Stage = 'Listing scheduled tasks...'
    })

    try {
        $functionSource = (Get-Command Get-SuspiciousTaskReport -CommandType Function).ScriptBlock.ToString()
        $workerScript = @"
param([bool]`$IncludeMicrosoftTasks, [System.Collections.IDictionary]`$ProgressState)
function Get-SuspiciousTaskReport {
$functionSource
}
Get-SuspiciousTaskReport -IncludeMicrosoftTasks `$IncludeMicrosoftTasks -ProgressState `$ProgressState
"@
        $script:scanRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $script:scanRunspace.Open()
        $script:scanPowerShell = [powershell]::Create()
        $script:scanPowerShell.Runspace = $script:scanRunspace
        $null = $script:scanPowerShell.AddScript($workerScript)
        $null = $script:scanPowerShell.AddArgument([bool]$includeMicrosoftCheckBox.Checked)
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
        $includeMicrosoftCheckBox.Enabled = $true
        $statusLabel.Text = 'Could not start scheduled-task scan.'
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            $_.Exception.Message,
            'Could not start task scan',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

$exportDialog = [System.Windows.Forms.SaveFileDialog]::new()
$exportDialog.Filter = 'CSV files (*.csv)|*.csv'
$exportDialog.DefaultExt = 'csv'
$exportDialog.AddExtension = $true
$exportDialog.FileName = 'scheduled-task-audit.csv'
$exportButton.Add_Click({
    if ($script:taskRows.Count -eq 0) {
        return
    }
    if ($exportDialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) {
        return
    }

    try {
        $script:taskRows |
            Select-Object Finding, Flags, TaskName, TaskPath, State, Author, Description, ActionSummary, Arguments, WorkingDirectory, Triggers |
            Export-Csv -LiteralPath $exportDialog.FileName -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        $statusLabel.Text = "Exported $($script:taskRows.Count) tasks to $($exportDialog.FileName)"
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            $_.Exception.Message,
            'Could not export task report',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)
