if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $powerShellPath = (Get-Process -Id $PID).Path
    if (-not $powerShellPath) {
        throw 'Could not determine the PowerShell executable path needed to start the UI in STA mode.'
    }
    $arguments = '-STA -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
    Start-Process -FilePath $powerShellPath -ArgumentList $arguments -WorkingDirectory (Get-Location).Path -WindowStyle Hidden
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:toolScriptPath = $PSCommandPath

function Format-ByteSize {
    param([AllowNull()][object]$Bytes)

    if ($null -eq $Bytes) {
        return '-'
    }
    $value = [double]$Bytes
    $units = @('B', 'KB', 'MB', 'GB', 'TB')
    $index = 0
    while ($value -ge 1024 -and $index -lt $units.Count - 1) {
        $value /= 1024
        $index++
    }
    if ($index -eq 0) {
        return ('{0:N0} {1}' -f $value, $units[$index])
    }
    '{0:N1} {1}' -f $value, $units[$index]
}

function Get-RegistryValueSafe {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    try {
        (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name
    }
    catch {
        $null
    }
}

function Get-StatusRank {
    param([string]$Status)

    switch ($Status) {
        'Critical' { 0 }
        'Warning' { 1 }
        'Info' { 2 }
        'OK' { 3 }
        default { 4 }
    }
}

$script:commonWorkerFunctions = @('Format-ByteSize', 'Get-RegistryValueSafe', 'Get-StatusRank')

function Get-ToolReport {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$ProgressState,
        [bool]$IsElevated
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    function Add-UpdateRow {
        param([string]$Status, [string]$Category, [string]$Item, [AllowNull()][object]$Date, [string]$Details = '')
        $rows.Add([pscustomobject]@{
            Status = $Status
            Category = $Category
            Item = $Item
            Date = $Date
            Details = $Details
        })
    }
    $resultNames = @{ 0 = 'Not started'; 1 = 'In progress'; 2 = 'Succeeded'; 3 = 'Succeeded with errors'; 4 = 'Failed'; 5 = 'Aborted' }

    $ProgressState.Stage = 'Checking the Windows Update service and policies...'
    try {
        $service = Get-Service -Name 'wuauserv' -ErrorAction Stop
        $startType = [string]$service.StartType
        $serviceStatus = if ($startType -eq 'Disabled') { 'Critical' } else { 'OK' }
        $serviceDetails = if ($startType -eq 'Disabled') { 'The Windows Update service is disabled, so no updates can install.' } else { "Currently $($service.Status)." }
        Add-UpdateRow -Status $serviceStatus -Category 'Status' -Item "Windows Update service: $startType" -Date $null -Details $serviceDetails
    }
    catch {
        $errors.Add("Windows Update service: $($_.Exception.Message)")
    }
    $policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $wsusServer = Get-RegistryValueSafe -Path $policyPath -Name 'WUServer'
    $useWsus = Get-RegistryValueSafe -Path "$policyPath\AU" -Name 'UseWUServer'
    if ($wsusServer -and $useWsus -eq 1) {
        Add-UpdateRow -Status 'Info' -Category 'Status' -Item 'Managed by WSUS' -Date $null -Details $wsusServer
    }
    if ((Get-RegistryValueSafe -Path "$policyPath\AU" -Name 'NoAutoUpdate') -eq 1) {
        Add-UpdateRow -Status 'Warning' -Category 'Status' -Item 'Automatic updates disabled by policy' -Date $null -Details 'NoAutoUpdate is set in Group Policy.'
    }
    $qualityDeferral = Get-RegistryValueSafe -Path $policyPath -Name 'DeferQualityUpdatesPeriodInDays'
    $featureDeferral = Get-RegistryValueSafe -Path $policyPath -Name 'DeferFeatureUpdatesPeriodInDays'
    if ($qualityDeferral -or $featureDeferral) {
        Add-UpdateRow -Status 'Info' -Category 'Status' -Item 'Update deferral policy' -Date $null -Details "Quality updates: $([int]$qualityDeferral) days, feature updates: $([int]$featureDeferral) days."
    }

    $rebootRequired = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    if (-not $rebootRequired) {
        try {
            $rebootRequired = [bool](New-Object -ComObject 'Microsoft.Update.SystemInfo').RebootRequired
        }
        catch {
        }
    }
    if ($rebootRequired) {
        Add-UpdateRow -Status 'Warning' -Category 'Status' -Item 'Restart required' -Date $null -Details 'Updates are waiting for a restart to finish installing.'
    }

    $ProgressState.Stage = 'Reading update history...'
    $historyRows = [System.Collections.Generic.List[object]]::new()
    $lastSuccess = $null
    $failedCount = 0
    $searcher = $null
    try {
        $session = New-Object -ComObject 'Microsoft.Update.Session'
        $searcher = $session.CreateUpdateSearcher()
        $historyCount = $searcher.GetTotalHistoryCount()
        if ($historyCount -gt 0) {
            $definitionUpdateShown = $false
            foreach ($entry in $searcher.QueryHistory(0, [Math]::Min($historyCount, 300))) {
                if (-not $entry.Title) {
                    continue
                }
                $date = ([datetime]$entry.Date).ToLocalTime()
                $resultCode = [int]$entry.ResultCode
                # Defender security intelligence/platform updates arrive several times a day; keep the newest and any failures only.
                $isDefinitionUpdate = [string]$entry.Title -match 'KB2267602|KB4052623|KB2461484'
                if ($isDefinitionUpdate) {
                    if ($resultCode -eq 2 -and $definitionUpdateShown) {
                        continue
                    }
                    if ($resultCode -eq 2) {
                        $definitionUpdateShown = $true
                    }
                }
                $resultText = if ($resultNames.ContainsKey($resultCode)) { $resultNames[$resultCode] } else { "Result $resultCode" }
                $status = switch ($resultCode) {
                    2 { 'OK' }
                    3 { 'Warning' }
                    4 { 'Warning' }
                    5 { 'Warning' }
                    default { 'Info' }
                }
                $operation = if ([int]$entry.Operation -eq 2) { 'Uninstall' } else { 'Install' }
                $details = "$operation $($resultText.ToLower())"
                if ($resultCode -in @(3, 4, 5)) {
                    $details += (' (error 0x{0:X8}); search the code online or rerun Windows Update.' -f [int]$entry.HResult)
                    if ($date -gt (Get-Date).AddDays(-30)) {
                        $failedCount++
                    }
                }
                if ($resultCode -eq 2 -and [int]$entry.Operation -eq 1 -and -not $isDefinitionUpdate -and ($null -eq $lastSuccess -or $date -gt $lastSuccess)) {
                    $lastSuccess = $date
                }
                $historyRows.Add([pscustomobject]@{
                    Status = $status
                    Category = 'History'
                    Item = [string]$entry.Title
                    Date = $date
                    Details = $details
                })
            }
        }
    }
    catch {
        $errors.Add("Update history: $($_.Exception.Message)")
    }
    if ($lastSuccess) {
        $age = [int]((Get-Date) - $lastSuccess).TotalDays
        $lastStatus = if ($age -gt 45) { 'Critical' } elseif ($age -gt 21) { 'Warning' } else { 'OK' }
        Add-UpdateRow -Status $lastStatus -Category 'Status' -Item "Last successful update: $age day(s) ago" -Date $lastSuccess -Details 'Defender definition updates are not counted.'
    }
    if ($failedCount -gt 0) {
        Add-UpdateRow -Status 'Warning' -Category 'Status' -Item "$failedCount failed update(s) in the last 30 days" -Date $null -Details 'See the History rows below for error codes.'
    }

    if ($searcher) {
        $ProgressState.Stage = 'Searching for available updates (this can take a minute or two)...'
        try {
            $searchResult = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
            $available = @($searchResult.Updates)
            if ($available.Count -eq 0) {
                Add-UpdateRow -Status 'OK' -Category 'Status' -Item 'No updates waiting to install' -Date $null -Details ''
            }
            foreach ($update in $available) {
                $severity = [string]$update.MsrcSeverity
                $status = if ($severity -in @('Critical', 'Important')) { 'Warning' } else { 'Info' }
                $kbs = @($update.KBArticleIDs | ForEach-Object { "KB$_" }) -join ', '
                $downloaded = if ($update.IsDownloaded) { 'downloaded' } else { 'not downloaded' }
                $details = (@($severity, $kbs, (Format-ByteSize $update.MaxDownloadSize), $downloaded) | Where-Object { $_ }) -join ', '
                Add-UpdateRow -Status $status -Category 'Available' -Item ([string]$update.Title) -Date $null -Details $details
            }
        }
        catch {
            $errors.Add("Online update search failed: $($_.Exception.Message)")
        }
    }

    $ProgressState.Stage = 'Reading installed KB updates...'
    $hotfixRows = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($hotfix in @(Get-HotFix -ErrorAction Stop)) {
            $hotfixRows.Add([pscustomobject]@{
                Status = 'Info'
                Category = 'Installed KB'
                Item = "$($hotfix.HotFixID) $($hotfix.Description)".Trim()
                Date = $hotfix.InstalledOn
                Details = "Installed by $($hotfix.InstalledBy)"
            })
        }
    }
    catch {
        $errors.Add("Installed KBs: $($_.Exception.Message)")
    }

    $statusRows = @($rows | Where-Object { $_.Category -eq 'Status' })
    $availableRows = @($rows | Where-Object { $_.Category -eq 'Available' })
    $allRows = @($statusRows) + @($availableRows) + @($historyRows | Sort-Object -Property Date -Descending) + @($hotfixRows | Sort-Object -Property Date -Descending)
    $summary = if ($lastSuccess) { "Last successful update $($lastSuccess.ToString('yyyy-MM-dd')). $($availableRows.Count) update(s) available." } else { "$($availableRows.Count) update(s) available." }
    [pscustomobject]@{
        Rows = @($allRows)
        Summary = $summary
        Errors = @($errors)
    }
}

$script:toolDefinition = @{
    Title = 'Windows Update Status'
    Subtitle = 'Last successful update, failed installs with error codes, pending restarts, available updates and installed KBs.'
    ScanButtonText = 'Refresh'
    ExportName = 'windows-update-status.csv'
    RequiresAdmin = $false
    IssueFilter = $true
    WorkerFunctions = @('Get-ToolReport')
    Columns = @(
        @{ Header = 'STATUS'; Property = 'Status'; Weight = 8; Align = 'Center' }
        @{ Header = 'CATEGORY'; Property = 'Category'; Weight = 10 }
        @{ Header = 'ITEM'; Property = 'Item'; Weight = 42 }
        @{ Header = 'DATE'; Property = 'Date'; Weight = 12 }
        @{ Header = 'DETAILS'; Property = 'Details'; Weight = 28; Muted = $true }
    )
    Actions = @(
        @{
            Text = 'Open Windows Update'
            Kind = 'Ui'
            Handler = {
                param($Rows)
                Start-Process -FilePath 'ms-settings:windowsupdate'
            }
        }
    )
}

#region Shared report window
$script:isElevated = ([System.Security.Principal.WindowsPrincipal][System.Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [System.Security.Principal.WindowsBuiltInRole]::Administrator
)
$script:columns = @($script:toolDefinition.Columns)
$script:statusColors = @{
    Critical = [System.Drawing.Color]::FromArgb(240, 125, 125)
    Warning = [System.Drawing.Color]::FromArgb(235, 185, 125)
    Info = [System.Drawing.Color]::FromArgb(150, 205, 230)
    OK = [System.Drawing.Color]::FromArgb(140, 205, 160)
}
$script:defaultTextColor = [System.Drawing.Color]::FromArgb(205, 208, 214)
$script:mutedTextColor = [System.Drawing.Color]::FromArgb(170, 176, 185)

function Set-PolishedListView {
    param([Parameter(Mandatory)][System.Windows.Forms.ListView]$ListView)

    $ListView.OwnerDraw = $true
    $ListView.GridLines = $false
    $ListView.Add_DrawColumnHeader({
        param($source, $drawArgs)
        $backBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(48, 48, 52))
        $textBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(195, 200, 208))
        $separatorPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(65, 65, 70))
        $bounds = [System.Drawing.RectangleF]::new(
            [single]($drawArgs.Bounds.X + 9),
            [single]$drawArgs.Bounds.Y,
            [single]($drawArgs.Bounds.Width - 14),
            [single]$drawArgs.Bounds.Height
        )
        $format = [System.Drawing.StringFormat]::new()
        $format.LineAlignment = [System.Drawing.StringAlignment]::Center
        $format.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
        $format.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
        try {
            $drawArgs.Graphics.FillRectangle($backBrush, $drawArgs.Bounds)
            $drawArgs.Graphics.DrawString($drawArgs.Header.Text, $source.Font, $textBrush, $bounds, $format)
            $drawArgs.Graphics.DrawLine(
                $separatorPen,
                $drawArgs.Bounds.Left,
                $drawArgs.Bounds.Bottom - 1,
                $drawArgs.Bounds.Right,
                $drawArgs.Bounds.Bottom - 1
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
        param($source, $drawArgs)
        if ($source.View -ne [System.Windows.Forms.View]::Details) {
            $drawArgs.DrawDefault = $true
        }
    })
    $ListView.Add_DrawSubItem({
        param($source, $drawArgs)
        $item = $drawArgs.Item
        $columnIndex = $drawArgs.ColumnIndex
        $column = $script:columns[$columnIndex]
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
            elseif ($column.Muted) {
                $script:mutedTextColor
            }
            else {
                $script:defaultTextColor
            }
        }

        $backBrush = [System.Drawing.SolidBrush]::new($backColor)
        $foreBrush = [System.Drawing.SolidBrush]::new($foreColor)
        $separatorPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(48, 48, 52))
        $textBounds = [System.Drawing.RectangleF]::new(
            [single]($drawArgs.Bounds.X + 9),
            [single]$drawArgs.Bounds.Y,
            [single]($drawArgs.Bounds.Width - 14),
            [single]$drawArgs.Bounds.Height
        )
        $format = [System.Drawing.StringFormat]::new()
        $format.LineAlignment = [System.Drawing.StringAlignment]::Center
        $format.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
        $format.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
        if ($column.Align -eq 'Right') {
            $format.Alignment = [System.Drawing.StringAlignment]::Far
        }
        elseif ($column.Align -eq 'Center') {
            $format.Alignment = [System.Drawing.StringAlignment]::Center
        }
        try {
            $drawArgs.Graphics.FillRectangle($backBrush, $drawArgs.Bounds)
            $drawArgs.Graphics.DrawString($drawArgs.SubItem.Text, $source.Font, $foreBrush, $textBounds, $format)
            $drawArgs.Graphics.DrawLine(
                $separatorPen,
                $drawArgs.Bounds.Left,
                $drawArgs.Bounds.Bottom - 1,
                $drawArgs.Bounds.Right,
                $drawArgs.Bounds.Bottom - 1
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

function New-ToolButton {
    param(
        [Parameter(Mandatory)][string]$Text,
        [switch]$Accent
    )

    $button = [System.Windows.Forms.Button]::new()
    $button.Text = $Text
    $button.AutoSize = $true
    $button.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowOnly
    $button.MinimumSize = [System.Drawing.Size]::new(100, 32)
    $button.Height = 32
    $button.Padding = [System.Windows.Forms.Padding]::new(6, 0, 6, 0)
    $button.Margin = [System.Windows.Forms.Padding]::new(0, 0, 8, 0)
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 230)
    $button.UseVisualStyleBackColor = $false
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    if ($Accent) {
        $button.BackColor = [System.Drawing.Color]::FromArgb(45, 105, 95)
        $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(60, 130, 118)
    }
    else {
        $button.BackColor = [System.Drawing.Color]::FromArgb(55, 55, 58)
        $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(80, 80, 85)
    }
    $button
}

function Show-ToolMessage {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Caption,
        [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Information,
        [System.Windows.Forms.MessageBoxButtons]$Buttons = [System.Windows.Forms.MessageBoxButtons]::OK
    )

    [System.Windows.Forms.MessageBox]::Show($form, $Text, $Caption, $Buttons, $Icon)
}

$form = [System.Windows.Forms.Form]::new()
$form.Text = $script:toolDefinition.Title
$form.StartPosition = 'CenterScreen'
$form.Size = [System.Drawing.Size]::new(1240, 760)
$form.MinimumSize = [System.Drawing.Size]::new(900, 560)
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
$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 52)) | Out-Null
$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)) | Out-Null
$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 128)) | Out-Null
$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 46)) | Out-Null

$headerPanel = [System.Windows.Forms.Panel]::new()
$headerPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$titleLabel = [System.Windows.Forms.Label]::new()
$titleLabel.Text = $script:toolDefinition.Title
$titleLabel.Location = [System.Drawing.Point]::new(0, 2)
$titleLabel.AutoSize = $true
$titleLabel.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 19)
$titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
$headerPanel.Controls.Add($titleLabel)
$subtitleLabel = [System.Windows.Forms.Label]::new()
$subtitleLabel.Text = $script:toolDefinition.Subtitle
$subtitleLabel.Location = [System.Drawing.Point]::new(2, 42)
$subtitleLabel.AutoSize = $true
$subtitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(165, 170, 178)
$headerPanel.Controls.Add($subtitleLabel)
$layout.Controls.Add($headerPanel, 0, 0)

$toolbarPanel = [System.Windows.Forms.Panel]::new()
$toolbarPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$toolbarPanel.BackColor = [System.Drawing.Color]::FromArgb(39, 39, 42)
$toolbarPanel.Padding = [System.Windows.Forms.Padding]::new(12, 10, 12, 8)
$toolbarFlow = [System.Windows.Forms.FlowLayoutPanel]::new()
$toolbarFlow.Dock = [System.Windows.Forms.DockStyle]::Fill
$toolbarFlow.WrapContents = $false
$toolbarFlow.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$toolbarPanel.Controls.Add($toolbarFlow)
$layout.Controls.Add($toolbarPanel, 0, 1)

$scanButtonText = if ($script:toolDefinition.ScanButtonText) { $script:toolDefinition.ScanButtonText } else { 'Refresh' }
$scanButton = New-ToolButton -Text $scanButtonText -Accent
$toolbarFlow.Controls.Add($scanButton)

$script:actionButtons = [System.Collections.Generic.List[object]]::new()
foreach ($action in @($script:toolDefinition.Actions)) {
    if (-not $action) {
        continue
    }
    $actionButton = New-ToolButton -Text $action.Text
    $actionButton.Tag = $action
    $actionButton.Add_Click({
        param($source, $clickArgs)
        Invoke-ToolActionButton -Action $source.Tag
    })
    $toolbarFlow.Controls.Add($actionButton)
    $script:actionButtons.Add($actionButton)
}

$filterLabel = [System.Windows.Forms.Label]::new()
$filterLabel.Text = 'FILTER'
$filterLabel.AutoSize = $true
$filterLabel.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 8)
$filterLabel.ForeColor = [System.Drawing.Color]::FromArgb(175, 180, 188)
$filterLabel.Margin = [System.Windows.Forms.Padding]::new(10, 9, 6, 0)
$toolbarFlow.Controls.Add($filterLabel)
$filterTextBox = [System.Windows.Forms.TextBox]::new()
$filterTextBox.Width = 200
$filterTextBox.Margin = [System.Windows.Forms.Padding]::new(0, 5, 10, 0)
$filterTextBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$filterTextBox.ForeColor = $form.ForeColor
$filterTextBox.BorderStyle = 'FixedSingle'
$toolbarFlow.Controls.Add($filterTextBox)

$issuesCheckBox = $null
if ($script:toolDefinition.IssueFilter) {
    $issuesCheckBox = [System.Windows.Forms.CheckBox]::new()
    $issuesCheckBox.Text = 'Only show issues'
    $issuesCheckBox.AutoSize = $true
    $issuesCheckBox.Checked = [bool]$script:toolDefinition.IssueFilterDefault
    $issuesCheckBox.ForeColor = $form.ForeColor
    $issuesCheckBox.Margin = [System.Windows.Forms.Padding]::new(0, 7, 12, 0)
    $issuesCheckBox.Cursor = [System.Windows.Forms.Cursors]::Hand
    $toolbarFlow.Controls.Add($issuesCheckBox)
}

$exportButton = New-ToolButton -Text 'Export CSV...'
$exportButton.Enabled = $false
$toolbarFlow.Controls.Add($exportButton)
$warningsButton = New-ToolButton -Text 'Warnings'
$warningsButton.Visible = $false
$warningsButton.ForeColor = $script:statusColors.Warning
$toolbarFlow.Controls.Add($warningsButton)
$adminButton = $null
if ($script:toolDefinition.RequiresAdmin -and -not $script:isElevated) {
    $adminButton = New-ToolButton -Text 'Relaunch as admin'
    $toolbarFlow.Controls.Add($adminButton)
}

$listView = [System.Windows.Forms.ListView]::new()
$listView.Dock = [System.Windows.Forms.DockStyle]::Fill
$listView.Margin = [System.Windows.Forms.Padding]::new(0, 12, 0, 8)
$listView.View = [System.Windows.Forms.View]::Details
$listView.FullRowSelect = $true
$listView.HideSelection = $false
$listView.MultiSelect = $true
$listView.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 38)
$listView.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 230)
$listView.BorderStyle = 'FixedSingle'
foreach ($column in $script:columns) {
    $listView.Columns.Add($column.Header, 100) | Out-Null
}
$layout.Controls.Add($listView, 0, 2)
$listView.Add_SizeChanged({
    $availableWidth = $listView.ClientSize.Width - 4
    if ($availableWidth -le 0) {
        return
    }
    $totalWeight = 0
    foreach ($column in $script:columns) {
        $totalWeight += [double]$column.Weight
    }
    $usedWidth = 0
    for ($index = 0; $index -lt $script:columns.Count; $index++) {
        if ($index -eq $script:columns.Count - 1) {
            $width = [Math]::Max(80, $availableWidth - $usedWidth)
        }
        else {
            $width = [Math]::Max(60, [int]($availableWidth * [double]$script:columns[$index].Weight / $totalWeight))
        }
        $listView.Columns[$index].Width = $width
        $usedWidth += $width
    }
})
Set-PolishedListView -ListView $listView

$detailsBox = [System.Windows.Forms.TextBox]::new()
$detailsBox.Dock = [System.Windows.Forms.DockStyle]::Fill
$detailsBox.Multiline = $true
$detailsBox.ReadOnly = $true
$detailsBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$detailsBox.WordWrap = $true
$detailsBox.BackColor = [System.Drawing.Color]::FromArgb(33, 33, 36)
$detailsBox.ForeColor = $script:mutedTextColor
$detailsBox.BorderStyle = 'FixedSingle'
$detailsBox.Font = [System.Drawing.Font]::new('Consolas', 9)
$detailsBox.Margin = [System.Windows.Forms.Padding]::new(0, 0, 0, 4)
$script:detailsPlaceholder = 'Select a row to see all of its details. Click a column header to sort.'
$detailsBox.Text = $script:detailsPlaceholder
$layout.Controls.Add($detailsBox, 0, 3)

$statusLabel = [System.Windows.Forms.Label]::new()
$statusLabel.Text = 'Ready.'
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

$script:allRows = @()
$script:visibleCount = 0
$script:reportSummary = ''
$script:reportWarnings = @()
$script:sortColumnIndex = -1
$script:sortDescending = $false
$script:workerPowerShell = $null
$script:workerRunspace = $null
$script:workerAsyncResult = $null
$script:workerProgressState = $null
$script:workerMode = $null
$workerTimer = [System.Windows.Forms.Timer]::new()
$workerTimer.Interval = 150

function Get-RowDisplayValue {
    param($Row, $Column)

    $value = $Row.($Column.Property)
    if ($null -eq $value) {
        return '-'
    }
    if ($value -is [datetime]) {
        if ($value.TimeOfDay.Ticks -eq 0) {
            return $value.ToString('yyyy-MM-dd')
        }
        return $value.ToString('yyyy-MM-dd HH:mm')
    }
    if ($value -is [array]) {
        $value = $value -join ', '
    }
    $text = ([string]$value) -replace '\s*\r?\n\s*', ' '
    if ($text -eq '') {
        return '-'
    }
    $text
}

function Get-SelectedToolRows {
    @($listView.SelectedItems | ForEach-Object { $_.Tag })
}

function Update-ActionButtons {
    $busy = $null -ne $script:workerAsyncResult
    $selectedCount = $listView.SelectedItems.Count
    $scanButton.Enabled = -not $busy
    foreach ($button in $script:actionButtons) {
        $action = $button.Tag
        $button.Enabled = (-not $busy) -and ((-not $action.RequiresSelection) -or $selectedCount -gt 0)
    }
    $exportButton.Enabled = (-not $busy) -and $listView.Items.Count -gt 0
}

function Update-StatusText {
    $parts = [System.Collections.Generic.List[string]]::new()
    $total = @($script:allRows).Count
    if ($script:visibleCount -ne $total) {
        $parts.Add("Showing $($script:visibleCount) of $total rows.")
    }
    else {
        $parts.Add("$total rows.")
    }
    if ($script:reportSummary) {
        $parts.Add($script:reportSummary)
    }
    if ($script:reportWarnings.Count -gt 0) {
        $parts.Add("$($script:reportWarnings.Count) warning(s); click Warnings for details.")
    }
    if ($script:toolDefinition.RequiresAdmin -and -not $script:isElevated) {
        $parts.Add('Run as administrator for complete results.')
    }
    $statusLabel.Text = $parts -join '  '
}

function Update-RowView {
    $rows = @($script:allRows)
    if ($issuesCheckBox -and $issuesCheckBox.Checked) {
        $rows = @($rows | Where-Object { $_.Status -eq 'Critical' -or $_.Status -eq 'Warning' })
    }
    $filterText = $filterTextBox.Text.Trim()
    if ($filterText) {
        $rows = @($rows | Where-Object {
            $row = $_
            foreach ($column in $script:columns) {
                if ((Get-RowDisplayValue -Row $row -Column $column).IndexOf($filterText, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    return $true
                }
            }
            return $false
        })
    }
    if ($script:sortColumnIndex -ge 0) {
        $sortColumn = $script:columns[$script:sortColumnIndex]
        $sortKey = if ($sortColumn.SortProperty) { $sortColumn.SortProperty } else { $sortColumn.Property }
        $rows = @($rows | Sort-Object -Property @{ Expression = { $_.$sortKey } } -Descending:$script:sortDescending)
    }

    $items = [System.Collections.Generic.List[System.Windows.Forms.ListViewItem]]::new()
    foreach ($row in $rows) {
        $item = [System.Windows.Forms.ListViewItem]::new((Get-RowDisplayValue -Row $row -Column $script:columns[0]))
        for ($index = 1; $index -lt $script:columns.Count; $index++) {
            $item.SubItems.Add((Get-RowDisplayValue -Row $row -Column $script:columns[$index])) | Out-Null
        }
        $item.Tag = $row
        $statusName = [string]$row.Status
        $item.ForeColor = if ($statusName -and $script:statusColors.ContainsKey($statusName)) {
            $script:statusColors[$statusName]
        }
        else {
            $script:defaultTextColor
        }
        $items.Add($item)
    }

    $listView.BeginUpdate()
    try {
        $listView.Items.Clear()
        if ($items.Count -gt 0) {
            $listView.Items.AddRange($items.ToArray())
        }
    }
    finally {
        $listView.EndUpdate()
    }
    $script:visibleCount = $rows.Count
    $detailsBox.Text = $script:detailsPlaceholder
    Update-StatusText
    Update-ActionButtons
}

function Show-RowDetails {
    param($Row)

    $lines = foreach ($property in $Row.PSObject.Properties) {
        if ($property.Name.StartsWith('_')) {
            continue
        }
        $value = $property.Value
        if ($value -is [datetime]) {
            $value = $value.ToString('yyyy-MM-dd HH:mm:ss')
        }
        elseif ($value -is [array]) {
            $value = $value -join ', '
        }
        if ($null -eq $value -or [string]$value -eq '') {
            $value = '-'
        }
        $label = $property.Name -creplace '(?<=[a-z])(?=[A-Z])', ' '
        '{0}: {1}' -f $label, (([string]$value) -replace '\r?\n', "`r`n    ")
    }
    $detailsBox.Text = $lines -join "`r`n"
}

function Stop-ToolWorkerResources {
    if ($script:workerPowerShell) {
        $script:workerPowerShell.Dispose()
        $script:workerPowerShell = $null
    }
    if ($script:workerRunspace) {
        $script:workerRunspace.Close()
        $script:workerRunspace.Dispose()
        $script:workerRunspace = $null
    }
    $script:workerAsyncResult = $null
    $script:workerProgressState = $null
    $progressBar.Visible = $false
    $form.Cursor = [System.Windows.Forms.Cursors]::Default
}

function Start-ToolWorker {
    param(
        [Parameter(Mandatory)][ValidateSet('Scan', 'Action')][string]$Mode,
        [string]$ActionName = '',
        [object[]]$Items = @(),
        [string]$StartText = 'Working...'
    )

    if ($script:workerAsyncResult) {
        return
    }

    $script:workerMode = $Mode
    $script:workerProgressState = [hashtable]::Synchronized(@{ Stage = $StartText })
    $statusLabel.Text = $StartText
    $progressBar.Visible = $true
    $form.Cursor = [System.Windows.Forms.Cursors]::AppStarting

    try {
        $functionNames = @(@($script:commonWorkerFunctions) + @($script:toolDefinition.WorkerFunctions) | Select-Object -Unique)
        $definitions = foreach ($functionName in $functionNames) {
            $source = (Get-Command $functionName -CommandType Function -ErrorAction Stop).ScriptBlock.ToString()
            "function $functionName {`n$source`n}"
        }
        $workerScript = "param([string]`$Mode, [string]`$ActionName, [object[]]`$Items, [System.Collections.IDictionary]`$ProgressState, [bool]`$IsElevated)`n" +
            ($definitions -join "`n") +
            "`nif (`$Mode -eq 'Action') { Invoke-ToolAction -Action `$ActionName -Items `$Items -ProgressState `$ProgressState -IsElevated `$IsElevated }" +
            "`nelse { Get-ToolReport -ProgressState `$ProgressState -IsElevated `$IsElevated }"

        $script:workerRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $script:workerRunspace.ApartmentState = [System.Threading.ApartmentState]::STA
        $script:workerRunspace.Open()
        $script:workerPowerShell = [powershell]::Create()
        $script:workerPowerShell.Runspace = $script:workerRunspace
        $null = $script:workerPowerShell.AddScript($workerScript)
        $null = $script:workerPowerShell.AddArgument($Mode)
        $null = $script:workerPowerShell.AddArgument($ActionName)
        $null = $script:workerPowerShell.AddArgument([object[]]$Items)
        $null = $script:workerPowerShell.AddArgument($script:workerProgressState)
        $null = $script:workerPowerShell.AddArgument([bool]$script:isElevated)
        $script:workerAsyncResult = $script:workerPowerShell.BeginInvoke()
        Update-ActionButtons
        $workerTimer.Start()
    }
    catch {
        Stop-ToolWorkerResources
        $statusLabel.Text = 'Could not start the background task.'
        Update-ActionButtons
        Show-ToolMessage -Text $_.Exception.Message -Caption 'Could not start' -Icon Error | Out-Null
    }
}

function Invoke-ToolActionButton {
    param([Parameter(Mandatory)]$Action)

    $selected = @(Get-SelectedToolRows)
    if ($Action.RequiresSelection -and $selected.Count -eq 0) {
        return
    }
    if ($Action.RequiresAdmin -and -not $script:isElevated) {
        Show-ToolMessage -Text "'$($Action.Text)' needs administrator rights. Relaunch the tool as administrator and try again." -Caption 'Administrator rights required' -Icon Warning | Out-Null
        return
    }
    $confirmText = $Action.Confirm
    if ($confirmText -is [scriptblock]) {
        $confirmText = & $confirmText $selected
    }
    if ($confirmText) {
        $answer = Show-ToolMessage -Text ([string]$confirmText) -Caption $Action.Text -Icon Question -Buttons YesNo
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            return
        }
    }
    if ($Action.Kind -eq 'Ui') {
        try {
            & $Action.Handler $selected
        }
        catch {
            Show-ToolMessage -Text $_.Exception.Message -Caption "Could not run '$($Action.Text)'" -Icon Error | Out-Null
        }
        return
    }
    Start-ToolWorker -Mode Action -ActionName $Action.Name -Items $selected -StartText "$($Action.Text)..."
}

$workerTimer.Add_Tick({
    if ($script:workerProgressState) {
        $statusLabel.Text = [string]$script:workerProgressState.Stage
    }
    if (-not $script:workerAsyncResult -or -not $script:workerAsyncResult.IsCompleted) {
        return
    }

    $workerTimer.Stop()
    $mode = $script:workerMode
    $result = $null
    $failure = $null
    $streamErrors = @()
    try {
        $output = $script:workerPowerShell.EndInvoke($script:workerAsyncResult)
        $streamErrors = @($script:workerPowerShell.Streams.Error | ForEach-Object { $_.ToString() })
        if ($output.Count -gt 0) {
            $result = $output[$output.Count - 1]
        }
        elseif ($streamErrors.Count -gt 0) {
            $failure = $streamErrors -join "`r`n"
        }
        else {
            $failure = 'The background task finished without returning a result.'
        }
    }
    catch {
        $failure = $_.Exception.Message
    }
    finally {
        Stop-ToolWorkerResources
    }

    if ($failure) {
        $statusLabel.Text = if ($mode -eq 'Action') { 'The action failed.' } else { 'The scan failed.' }
        Update-ActionButtons
        Show-ToolMessage -Text $failure -Caption $statusLabel.Text -Icon Error | Out-Null
        return
    }

    if ($mode -eq 'Action') {
        $messages = @(@($result.Errors) + $streamErrors | Where-Object { $_ })
        $text = [string]$result.Message
        $icon = [System.Windows.Forms.MessageBoxIcon]::Information
        if ($messages.Count -gt 0) {
            $icon = [System.Windows.Forms.MessageBoxIcon]::Warning
            $text += "`r`n`r`nWarnings:`r`n" + (($messages | Select-Object -First 15) -join "`r`n")
            if ($messages.Count -gt 15) {
                $text += "`r`n...and $($messages.Count - 15) more."
            }
        }
        if ($text.Trim()) {
            Show-ToolMessage -Text $text -Caption $script:toolDefinition.Title -Icon $icon | Out-Null
        }
        if ($result.Rescan -ne $false) {
            Start-ToolWorker -Mode Scan -StartText 'Refreshing...'
        }
        else {
            Update-StatusText
            Update-ActionButtons
        }
        return
    }

    $script:allRows = @($result.Rows | Where-Object { $_ })
    $script:reportSummary = [string]$result.Summary
    $script:reportWarnings = @(@($result.Errors) + $streamErrors | Where-Object { $_ })
    $warningsButton.Visible = $script:reportWarnings.Count -gt 0
    Update-RowView
})

$scanButton.Add_Click({
    Start-ToolWorker -Mode Scan -StartText 'Starting scan...'
})

$listView.Add_SelectedIndexChanged({
    Update-ActionButtons
    $selected = @(Get-SelectedToolRows)
    if ($selected.Count -eq 1) {
        Show-RowDetails -Row $selected[0]
    }
    elseif ($selected.Count -gt 1) {
        $detailsBox.Text = "$($selected.Count) rows selected."
    }
    else {
        $detailsBox.Text = $script:detailsPlaceholder
    }
})

$listView.Add_ColumnClick({
    param($source, $columnArgs)
    if ($script:sortColumnIndex -eq $columnArgs.Column) {
        $script:sortDescending = -not $script:sortDescending
    }
    else {
        $script:sortColumnIndex = $columnArgs.Column
        $script:sortDescending = $false
    }
    for ($index = 0; $index -lt $script:columns.Count; $index++) {
        $headerText = $script:columns[$index].Header
        if ($index -eq $script:sortColumnIndex) {
            $headerText += if ($script:sortDescending) { ' ' + [char]0x25BC } else { ' ' + [char]0x25B2 }
        }
        $listView.Columns[$index].Text = $headerText
    }
    Update-RowView
})

$filterTextBox.Add_TextChanged({
    Update-RowView
})
if ($issuesCheckBox) {
    $issuesCheckBox.Add_CheckedChanged({
        Update-RowView
    })
}

$warningsButton.Add_Click({
    $text = ($script:reportWarnings | Select-Object -First 25) -join "`r`n"
    if ($script:reportWarnings.Count -gt 25) {
        $text += "`r`n...and $($script:reportWarnings.Count - 25) more."
    }
    Show-ToolMessage -Text $text -Caption "Warnings ($($script:reportWarnings.Count))" -Icon Warning | Out-Null
})

if ($adminButton) {
    $adminButton.Add_Click({
        try {
            $powerShellPath = (Get-Process -Id $PID).Path
            $arguments = '-STA -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $script:toolScriptPath
            Start-Process -FilePath $powerShellPath -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -ErrorAction Stop
            $form.Close()
        }
        catch {
            $statusLabel.Text = 'Elevation was cancelled or failed.'
        }
    })
}

$exportDialog = [System.Windows.Forms.SaveFileDialog]::new()
$exportDialog.Filter = 'CSV files (*.csv)|*.csv'
$exportDialog.DefaultExt = 'csv'
$exportDialog.AddExtension = $true
$exportButton.Add_Click({
    $rowsToExport = @($listView.Items | ForEach-Object { $_.Tag })
    if ($rowsToExport.Count -eq 0) {
        return
    }
    $exportDialog.FileName = $script:toolDefinition.ExportName
    if ($exportDialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) {
        return
    }
    try {
        $propertyNames = @($rowsToExport[0].PSObject.Properties.Name | Where-Object { -not $_.StartsWith('_') })
        $rowsToExport |
            Select-Object -Property $propertyNames |
            Export-Csv -LiteralPath $exportDialog.FileName -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        $statusLabel.Text = "Exported $($rowsToExport.Count) rows to $($exportDialog.FileName)"
    }
    catch {
        Show-ToolMessage -Text $_.Exception.Message -Caption 'Could not export report' -Icon Error | Out-Null
    }
})

$form.Add_Shown({
    Update-ActionButtons
    if ($script:toolDefinition.AutoScan -ne $false) {
        Start-ToolWorker -Mode Scan -StartText 'Starting scan...'
    }
    else {
        $statusLabel.Text = $script:toolDefinition.IdleText
    }
})

$form.Add_FormClosed({
    $workerTimer.Stop()
    $workerTimer.Dispose()
    if ($script:workerPowerShell -and $script:workerAsyncResult -and -not $script:workerAsyncResult.IsCompleted) {
        try {
            $null = $script:workerPowerShell.BeginStop($null, $null)
        }
        catch {
        }
    }
})

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)
#endregion
