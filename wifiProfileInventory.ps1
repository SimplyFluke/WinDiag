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
                [System.Drawing.Color]::FromArgb(220, 230, 238)
            }
            else {
                [System.Drawing.Color]::FromArgb(160, 210, 192)
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

function ConvertFrom-NetshProfileOutput {
    param([string[]]$Lines)

    $profileNames = [System.Collections.Generic.List[string]]::new()
    $seenNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $Lines) {
        $match = [regex]::Match([string]$line, '^\s+[^:\r\n]+:\s*(?<Name>.+?)\s*$')
        if (-not $match.Success) {
            continue
        }

        $profileName = $match.Groups['Name'].Value.Trim()
        if ($profileName -and $profileName -notmatch '^(?i)<none>$' -and $seenNames.Add($profileName)) {
            $profileNames.Add($profileName)
        }
    }

    @($profileNames | Sort-Object)
}

function Get-WifiProfileReport {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$ProgressState)

    $ProgressState.Stage = 'Reading saved Wi-Fi profile names...'
    $netshPath = Join-Path $env:SystemRoot 'System32\netsh.exe'
    if (-not (Test-Path -LiteralPath $netshPath -PathType Leaf)) {
        throw "Could not find netsh.exe at $netshPath"
    }

    $output = @(& $netshPath wlan show profiles 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $details = ($output | Select-Object -First 8 | ForEach-Object { [string]$_ }) -join "`r`n"
        throw "netsh could not list Wi-Fi profiles (exit code $exitCode).`r`n$details"
    }

    $profileNames = @(ConvertFrom-NetshProfileOutput -Lines $output)
    [pscustomobject]@{
        Profiles = @(
            foreach ($profileName in $profileNames) {
                [pscustomobject]@{
                    ProfileName = $profileName
                    Status = 'Saved on this device'
                }
            }
        )
    }
}

$form = [System.Windows.Forms.Form]::new()
$form.Text = 'Wi-Fi Profile Inventory'
$form.StartPosition = 'CenterScreen'
$form.Size = [System.Drawing.Size]::new(900, 640)
$form.MinimumSize = [System.Drawing.Size]::new(700, 450)
$form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$form.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 230)
$form.Font = [System.Drawing.Font]::new('Segoe UI', 9)
$form.Padding = [System.Windows.Forms.Padding]::new(18)

$layout = [System.Windows.Forms.TableLayoutPanel]::new()
$layout.Dock = [System.Windows.Forms.DockStyle]::Fill
$layout.ColumnCount = 1
$layout.RowCount = 4
$layout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)) | Out-Null
$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 92)) | Out-Null
$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 54)) | Out-Null
$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)) | Out-Null
$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 46)) | Out-Null

$headerPanel = [System.Windows.Forms.Panel]::new()
$headerPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$titleLabel = [System.Windows.Forms.Label]::new()
$titleLabel.Text = 'Wi-Fi Profile Inventory'
$titleLabel.Location = [System.Drawing.Point]::new(0, 2)
$titleLabel.AutoSize = $true
$titleLabel.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 19)
$titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
$headerPanel.Controls.Add($titleLabel)
$subtitleLabel = [System.Windows.Forms.Label]::new()
$subtitleLabel.Text = 'Lists saved network names only. Wi-Fi passwords and key material are not read or exported.'
$subtitleLabel.Location = [System.Drawing.Point]::new(2, 44)
$subtitleLabel.AutoSize = $true
$subtitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(165, 170, 178)
$headerPanel.Controls.Add($subtitleLabel)
$layout.Controls.Add($headerPanel, 0, 0)

$toolbarPanel = [System.Windows.Forms.FlowLayoutPanel]::new()
$toolbarPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$toolbarPanel.BackColor = [System.Drawing.Color]::FromArgb(39, 39, 42)
$toolbarPanel.Padding = [System.Windows.Forms.Padding]::new(10, 8, 10, 6)
$toolbarPanel.WrapContents = $false
$refreshButton = [System.Windows.Forms.Button]::new()
$refreshButton.Text = 'Refresh profiles'
$refreshButton.Size = [System.Drawing.Size]::new(145, 32)
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
$listView.Columns.Add('SAVED WI-FI PROFILE', 520) | Out-Null
$listView.Columns.Add('STATUS', 220) | Out-Null
$layout.Controls.Add($listView, 0, 2)
$listView.Add_SizeChanged({
    $availableWidth = $listView.ClientSize.Width - 4
    if ($availableWidth -gt 0) {
        $listView.Columns[0].Width = [Math]::Max(250, [int]($availableWidth * 0.68))
        $listView.Columns[1].Width = [Math]::Max(180, $availableWidth - $listView.Columns[0].Width)
    }
})
Set-PolishedListView -ListView $listView

$statusLabel = [System.Windows.Forms.Label]::new()
$statusLabel.Text = 'Refresh to list saved Wi-Fi profiles.'
$statusLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
$statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$statusLabel.AutoEllipsis = $true
$statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(175, 180, 188)
$statusLabel.Padding = [System.Windows.Forms.Padding]::new(2, 0, 0, 0)
$layout.Controls.Add($statusLabel, 0, 3)
$form.Controls.Add($layout)

$script:wifiProfiles = @()
$script:scanPowerShell = $null
$script:scanRunspace = $null
$script:scanAsyncResult = $null
$script:scanProgressState = $null
$scanTimer = [System.Windows.Forms.Timer]::new()
$scanTimer.Interval = 150

function Show-WifiProfiles {
    param([Parameter(Mandatory)]$Report)

    $script:wifiProfiles = @($Report.Profiles)
    $listView.BeginUpdate()
    try {
        $listView.Items.Clear()
        foreach ($profile in $script:wifiProfiles) {
            $row = [System.Windows.Forms.ListViewItem]::new($profile.ProfileName)
            $row.SubItems.Add($profile.Status) | Out-Null
            $listView.Items.Add($row) | Out-Null
        }
    }
    finally {
        $listView.EndUpdate()
    }

    if ($script:wifiProfiles.Count -eq 0) {
        $statusLabel.Text = 'No saved Wi-Fi profile names were found.'
    }
    else {
        $statusLabel.Text = "Found $($script:wifiProfiles.Count) saved Wi-Fi profiles. Passwords were not accessed."
    }
    $exportButton.Enabled = $script:wifiProfiles.Count -gt 0
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
            throw 'The profile query completed without returning results.'
        }
        Show-WifiProfiles -Report $scanOutput[$scanOutput.Count - 1]
    }
    catch {
        $statusLabel.Text = 'Profile collection failed.'
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            $_.Exception.Message,
            'Profile collection failed',
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
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $refreshButton.Enabled = $true
    }
})

$form.Add_FormClosed({
    $scanTimer.Stop()
    $scanTimer.Dispose()
})

$refreshButton.Add_Click({
    $refreshButton.Enabled = $false
    $exportButton.Enabled = $false
    $listView.Items.Clear()
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $statusLabel.Text = 'Starting Wi-Fi profile query...'
    $script:scanProgressState = [hashtable]::Synchronized(@{
        Stage = 'Reading saved Wi-Fi profile names...'
    })

    try {
        $reportFunctionSource = (Get-Command Get-WifiProfileReport -CommandType Function).ScriptBlock.ToString()
        $parserFunctionSource = (Get-Command ConvertFrom-NetshProfileOutput -CommandType Function).ScriptBlock.ToString()
        $workerScript = @"
param([System.Collections.IDictionary]`$ProgressState)
function ConvertFrom-NetshProfileOutput {
$parserFunctionSource
}
function Get-WifiProfileReport {
$reportFunctionSource
}
Get-WifiProfileReport -ProgressState `$ProgressState
"@
        $script:scanRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $script:scanRunspace.Open()
        $script:scanPowerShell = [powershell]::Create()
        $script:scanPowerShell.Runspace = $script:scanRunspace
        $null = $script:scanPowerShell.AddScript($workerScript)
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
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $refreshButton.Enabled = $true
        $statusLabel.Text = 'Could not start profile query.'
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            $_.Exception.Message,
            'Could not start profile query',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

$exportDialog = [System.Windows.Forms.SaveFileDialog]::new()
$exportDialog.Filter = 'CSV files (*.csv)|*.csv'
$exportDialog.DefaultExt = 'csv'
$exportDialog.AddExtension = $true
$exportDialog.FileName = 'saved-wifi-profiles.csv'
$exportButton.Add_Click({
    if ($script:wifiProfiles.Count -eq 0) {
        return
    }
    if ($exportDialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) {
        return
    }

    try {
        $script:wifiProfiles |
            Select-Object ProfileName, Status |
            Export-Csv -LiteralPath $exportDialog.FileName -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        $statusLabel.Text = "Exported $($script:wifiProfiles.Count) profile names to $($exportDialog.FileName)"
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            $_.Exception.Message,
            'Could not export profile list',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)
