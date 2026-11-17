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
            $foreColor = switch ([string]$item.Tag.Startup) {
                'Enabled' { [System.Drawing.Color]::FromArgb(155, 210, 165) }
                'Disabled' { [System.Drawing.Color]::FromArgb(150, 150, 158) }
                default { [System.Drawing.Color]::FromArgb(120, 124, 132) }
            }
        }
        elseif ($Sender.Tag -eq 'startup' -and $columnIndex -eq 3) {
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
        if ($Sender.Tag -eq 'startup' -and $columnIndex -in @(2, 3)) {
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

function Get-FileTargetStatus {
    param([string]$TargetPath)

    if ([string]::IsNullOrWhiteSpace($TargetPath)) {
        return 'Unresolved'
    }
    if ($TargetPath -match '^(?i:https?|file|shell):') {
        return 'URL or shell target'
    }
    if (Test-Path -LiteralPath $TargetPath -PathType Leaf -ErrorAction SilentlyContinue) {
        return 'Target present'
    }
    if (Test-Path -LiteralPath $TargetPath -PathType Container -ErrorAction SilentlyContinue) {
        return 'Target present'
    }

    if (-not [System.IO.Path]::IsPathRooted($TargetPath) -and $TargetPath -notmatch '[\\/]') {
        $application = Get-Command -Name $TargetPath -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($application) {
            return 'Target present'
        }
    }

    'Target missing'
}

function Resolve-StartupCommand {
    param([string]$Command)

    $expandedCommand = [Environment]::ExpandEnvironmentVariables([string]$Command).Trim()
    if ([string]::IsNullOrWhiteSpace($expandedCommand)) {
        return [pscustomobject]@{
            TargetPath = ''
            Status = 'Unresolved'
        }
    }

    if ($expandedCommand -match '^(?i:https?|file|shell):') {
        return [pscustomobject]@{
            TargetPath = $expandedCommand
            Status = 'URL or shell target'
        }
    }

    $targetPath = ''
    if ($expandedCommand.StartsWith('"')) {
        $closingQuote = $expandedCommand.IndexOf('"', 1)
        if ($closingQuote -gt 1) {
            $targetPath = $expandedCommand.Substring(1, $closingQuote - 1)
        }
    }
    else {
        $targetMatch = [regex]::Match(
            $expandedCommand,
            '^\s*(?<target>.+?\.(?:exe|com|bat|cmd|ps1|vbs|js|wsf|scr|msc|cpl|jar))(?=\s|$)',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        if ($targetMatch.Success) {
            $targetPath = $targetMatch.Groups['target'].Value.Trim('"')
        }
        else {
            $targetPath = ($expandedCommand -split '\s+', 2)[0].Trim('"')
        }
    }

    $targetPath = [Environment]::ExpandEnvironmentVariables($targetPath)
    if (-not [string]::IsNullOrWhiteSpace($targetPath) -and
        -not [System.IO.Path]::IsPathRooted($targetPath) -and
        $targetPath -match '[\\/]') {
        $targetPath = Join-Path (Get-Location).Path $targetPath
    }

    [pscustomobject]@{
        TargetPath = $targetPath
        Status = Get-FileTargetStatus -TargetPath $targetPath
    }
}

$script:startupApprovedPath = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'

function Get-NativeRegistryView {
    if ([Environment]::Is64BitOperatingSystem) {
        return [Microsoft.Win32.RegistryView]::Registry64
    }
    [Microsoft.Win32.RegistryView]::Default
}

function Get-StartupApprovalState {
    # Windows (Task Manager, Settings > Apps > Startup) records enabled/disabled startup items under
    # StartupApproved. The first byte of the binary value is even when enabled and odd when disabled;
    # a missing value means enabled.
    param(
        [Parameter(Mandatory)][string]$Hive,
        [Parameter(Mandatory)][string]$KeyName,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ValueName
    )

    $hiveValue = if ($Hive -eq 'HKLM') { [Microsoft.Win32.RegistryHive]::LocalMachine } else { [Microsoft.Win32.RegistryHive]::CurrentUser }
    $baseKey = $null
    $key = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hiveValue, (Get-NativeRegistryView))
        $key = $baseKey.OpenSubKey("$script:startupApprovedPath\$KeyName")
        if (-not $key) {
            return 'Enabled'
        }
        $data = $key.GetValue($ValueName, $null)
        if ($data -is [byte[]] -and $data.Length -gt 0 -and ($data[0] -band 1)) {
            return 'Disabled'
        }
        'Enabled'
    }
    catch {
        'Enabled'
    }
    finally {
        if ($key) { $key.Dispose() }
        if ($baseKey) { $baseKey.Dispose() }
    }
}

function Set-StartupApprovalState {
    param(
        [Parameter(Mandatory)][object]$Entry,
        [Parameter(Mandatory)][bool]$Enable
    )

    $hiveValue = if ($Entry.ApprovalHive -eq 'HKLM') { [Microsoft.Win32.RegistryHive]::LocalMachine } else { [Microsoft.Win32.RegistryHive]::CurrentUser }
    $baseKey = $null
    $key = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hiveValue, (Get-NativeRegistryView))
        $key = $baseKey.CreateSubKey("$script:startupApprovedPath\$($Entry.ApprovalKey)")
        $data = [byte[]]::new(12)
        if ($Enable) {
            $data[0] = 2
        }
        else {
            # Disabled entries carry the time they were disabled, the same way Task Manager writes them.
            $data[0] = 3
            [BitConverter]::GetBytes([DateTime]::UtcNow.ToFileTimeUtc()).CopyTo($data, 4)
        }
        $key.SetValue($Entry.ApprovalName, $data, [Microsoft.Win32.RegistryValueKind]::Binary)
    }
    finally {
        if ($key) { $key.Dispose() }
        if ($baseKey) { $baseKey.Dispose() }
    }
}

function Get-StartupAuditReport {
    $entries = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()

    # Per-user Run keys are shared between the 32-bit and 64-bit views, so they are read once.
    # All-users Run keys are separate; the 32-bit one is approved under StartupApproved\Run32.
    $registrySources = [System.Collections.Generic.List[object]]::new()
    $registrySources.Add([pscustomobject]@{ Hive = [Microsoft.Win32.RegistryHive]::CurrentUser; Label = 'Current user'; Prefix = 'HKCU'; View = (Get-NativeRegistryView); ViewLabel = ''; ApprovalKey = 'Run' })
    if ([Environment]::Is64BitOperatingSystem) {
        $registrySources.Add([pscustomobject]@{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; Label = 'All users'; Prefix = 'HKLM'; View = [Microsoft.Win32.RegistryView]::Registry64; ViewLabel = ' (64-bit)'; ApprovalKey = 'Run' })
        $registrySources.Add([pscustomobject]@{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; Label = 'All users'; Prefix = 'HKLM'; View = [Microsoft.Win32.RegistryView]::Registry32; ViewLabel = ' (32-bit)'; ApprovalKey = 'Run32' })
    }
    else {
        $registrySources.Add([pscustomobject]@{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; Label = 'All users'; Prefix = 'HKLM'; View = [Microsoft.Win32.RegistryView]::Default; ViewLabel = ''; ApprovalKey = 'Run' })
    }
    $runKeys = @(
        'Software\Microsoft\Windows\CurrentVersion\Run',
        'Software\Microsoft\Windows\CurrentVersion\RunOnce'
    )

    foreach ($hiveInfo in $registrySources) {
        foreach ($view in @($hiveInfo.View)) {
            $baseKey = $null
            $viewLabel = if ($hiveInfo.ViewLabel) { $hiveInfo.ViewLabel.Trim(' ()') + ' view' } else { 'registry' }
            try {
                $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hiveInfo.Hive, $view)
                foreach ($subKeyPath in $runKeys) {
                    $registryKey = $null
                    try {
                        $registryKey = $baseKey.OpenSubKey($subKeyPath)
                        if (-not $registryKey) {
                            continue
                        }

                        $keyName = ($subKeyPath -split '\\')[-1]
                        foreach ($valueName in $registryKey.GetValueNames()) {
                            try {
                                $valueKind = $registryKey.GetValueKind($valueName)
                                $rawValue = $registryKey.GetValue(
                                    $valueName,
                                    $null,
                                    [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
                                )
                                $command = if ($rawValue -is [string]) {
                                    $rawValue
                                }
                                else {
                                    [string]$rawValue
                                }
                                $resolved = Resolve-StartupCommand -Command $command
                                if ($valueKind -notin @(
                                    [Microsoft.Win32.RegistryValueKind]::String,
                                    [Microsoft.Win32.RegistryValueKind]::ExpandString
                                )) {
                                    $resolved.Status = 'Unresolved'
                                }

                                $canToggle = $keyName -eq 'Run'
                                $entries.Add([pscustomobject]@{
                                    Source = "$($hiveInfo.Label) - $keyName$($hiveInfo.ViewLabel)"
                                    Entry = if ([string]::IsNullOrEmpty($valueName)) { '(Default)' } else { $valueName }
                                    Startup = if ($canToggle) { Get-StartupApprovalState -Hive $hiveInfo.Prefix -KeyName $hiveInfo.ApprovalKey -ValueName $valueName } else { 'Runs once' }
                                    Status = $resolved.Status
                                    TargetPath = $resolved.TargetPath
                                    Command = $command
                                    EntryPath = "$($hiveInfo.Prefix):\$subKeyPath"
                                    ApprovalHive = if ($canToggle) { $hiveInfo.Prefix } else { '' }
                                    ApprovalKey = if ($canToggle) { $hiveInfo.ApprovalKey } else { '' }
                                    ApprovalName = $valueName
                                })
                            }
                            catch {
                                $errors.Add("$($hiveInfo.Label) $subKeyPath\$valueName ($viewLabel): $($_.Exception.Message)")
                            }
                        }
                    }
                    catch {
                        $errors.Add("$($hiveInfo.Label) $subKeyPath ($viewLabel): $($_.Exception.Message)")
                    }
                    finally {
                        if ($registryKey) {
                            $registryKey.Dispose()
                        }
                    }
                }
            }
            catch {
                $errors.Add("$($hiveInfo.Label) registry ($viewLabel): $($_.Exception.Message)")
            }
            finally {
                if ($baseKey) {
                    $baseKey.Dispose()
                }
            }
        }
    }

    $startupFolders = @(
        [pscustomobject]@{
            Path = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
            Source = 'Current user - Startup folder'
            Prefix = 'HKCU'
        },
        [pscustomobject]@{
            Path = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonStartup)
            Source = 'All users - Startup folder'
            Prefix = 'HKLM'
        }
    )
    $shell = $null
    foreach ($startupFolder in $startupFolders) {
        if ([string]::IsNullOrWhiteSpace($startupFolder.Path)) {
            continue
        }
        if (-not (Test-Path -LiteralPath $startupFolder.Path -PathType Container)) {
            continue
        }

        try {
            $folderItems = @(Get-ChildItem -LiteralPath $startupFolder.Path -Force -ErrorAction Stop)
        }
        catch {
            $errors.Add("$($startupFolder.Path): $($_.Exception.Message)")
            continue
        }

        foreach ($item in $folderItems) {
            if ($item.Name -ieq 'desktop.ini' -or $item.PSIsContainer) {
                continue
            }
            $targetPath = $item.FullName
            $command = $item.FullName
            $status = 'Target present'

            if ($item.Extension -ieq '.lnk') {
                $shortcut = $null
                try {
                    if (-not $shell) {
                        $shell = New-Object -ComObject WScript.Shell -ErrorAction Stop
                    }
                    $shortcut = $shell.CreateShortcut($item.FullName)
                    $targetPath = [Environment]::ExpandEnvironmentVariables([string]$shortcut.TargetPath)
                    $workingDirectory = [Environment]::ExpandEnvironmentVariables([string]$shortcut.WorkingDirectory)
                    if (-not [string]::IsNullOrWhiteSpace($targetPath) -and
                        -not [System.IO.Path]::IsPathRooted($targetPath) -and
                        -not [string]::IsNullOrWhiteSpace($workingDirectory)) {
                        $targetPath = Join-Path $workingDirectory $targetPath
                    }
                    $arguments = [string]$shortcut.Arguments
                    if (-not [string]::IsNullOrWhiteSpace($arguments)) {
                        $command = '"{0}" {1}' -f $targetPath, $arguments
                    }
                    else {
                        $command = $targetPath
                    }
                    $status = Get-FileTargetStatus -TargetPath $targetPath
                }
                catch {
                    $targetPath = ''
                    $command = $item.FullName
                    $status = 'Unresolved'
                    $errors.Add("$($item.FullName): $($_.Exception.Message)")
                }
                finally {
                    if ($shortcut -and [Runtime.InteropServices.Marshal]::IsComObject($shortcut)) {
                        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut)
                    }
                }
            }
            elseif ($item.Extension -ieq '.url') {
                try {
                    $urlLine = Get-Content -LiteralPath $item.FullName -ErrorAction Stop |
                        Where-Object { $_ -match '^\s*URL=' } |
                        Select-Object -First 1
                    if ($urlLine) {
                        $targetPath = ($urlLine -replace '^\s*URL=', '').Trim()
                        $command = $targetPath
                        $status = 'URL or shell target'
                    }
                    else {
                        $targetPath = ''
                        $status = 'Unresolved'
                    }
                }
                catch {
                    $targetPath = ''
                    $status = 'Unresolved'
                    $errors.Add("$($item.FullName): $($_.Exception.Message)")
                }
            }

            $entries.Add([pscustomobject]@{
                Source = $startupFolder.Source
                Entry = $item.Name
                Startup = Get-StartupApprovalState -Hive $startupFolder.Prefix -KeyName 'StartupFolder' -ValueName $item.Name
                Status = $status
                TargetPath = $targetPath
                Command = $command
                EntryPath = $item.FullName
                ApprovalHive = $startupFolder.Prefix
                ApprovalKey = 'StartupFolder'
                ApprovalName = $item.Name
            })
        }
    }

    if ($shell -and [Runtime.InteropServices.Marshal]::IsComObject($shell)) {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }

    [pscustomobject]@{
        Entries = @($entries | Sort-Object -Property Source, Entry)
        Errors = @($errors)
    }
}

$form = [System.Windows.Forms.Form]::new()
$form.Text = 'Startup Program Auditor'
$form.StartPosition = 'CenterScreen'
$form.Size = [System.Drawing.Size]::new(1180, 720)
$form.MinimumSize = [System.Drawing.Size]::new(820, 500)
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
$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 58)) | Out-Null
$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)) | Out-Null
$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 46)) | Out-Null

$headerPanel = [System.Windows.Forms.Panel]::new()
$headerPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$titleLabel = [System.Windows.Forms.Label]::new()
$titleLabel.Text = 'Startup Program Auditor'
$titleLabel.Location = [System.Drawing.Point]::new(0, 2)
$titleLabel.AutoSize = $true
$titleLabel.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 19)
$titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
$headerPanel.Controls.Add($titleLabel)
$subtitleLabel = [System.Windows.Forms.Label]::new()
$subtitleLabel.Text = 'Review Run and RunOnce entries and Startup folder items, and turn programs on or off at sign-in (same switch as Task Manager).'
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
$refreshButton = [System.Windows.Forms.Button]::new()
$refreshButton.Text = 'Refresh report'
$refreshButton.Size = [System.Drawing.Size]::new(140, 32)
$exportButton = [System.Windows.Forms.Button]::new()
$exportButton.Text = 'Export CSV...'
$exportButton.Size = [System.Drawing.Size]::new(120, 32)
$exportButton.Enabled = $false
$disableButton = [System.Windows.Forms.Button]::new()
$disableButton.Text = 'Disable at startup'
$disableButton.Size = [System.Drawing.Size]::new(140, 32)
$disableButton.Enabled = $false
$enableButton = [System.Windows.Forms.Button]::new()
$enableButton.Text = 'Enable at startup'
$enableButton.Size = [System.Drawing.Size]::new(140, 32)
$enableButton.Enabled = $false
$adminButton = [System.Windows.Forms.Button]::new()
$adminButton.Text = 'Relaunch as admin'
$adminButton.Size = [System.Drawing.Size]::new(140, 32)
$script:isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$adminButton.Visible = -not $script:isElevated
foreach ($button in @($refreshButton, $disableButton, $enableButton, $exportButton, $adminButton)) {
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.BackColor = [System.Drawing.Color]::FromArgb(55, 55, 58)
    $button.ForeColor = $form.ForeColor
    $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(80, 80, 85)
    $button.UseVisualStyleBackColor = $false
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
}
$refreshButton.BackColor = [System.Drawing.Color]::FromArgb(45, 105, 95)
$refreshButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(60, 130, 118)
$toolbarPanel.Controls.Add($refreshButton)
$toolbarPanel.Controls.Add($disableButton)
$toolbarPanel.Controls.Add($enableButton)
$toolbarPanel.Controls.Add($exportButton)
$toolbarPanel.Controls.Add($adminButton)
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
$listView.MultiSelect = $true
$listView.Columns.Add('SOURCE', 200) | Out-Null
$listView.Columns.Add('ENTRY', 180) | Out-Null
$listView.Columns.Add('STARTUP', 90) | Out-Null
$listView.Columns.Add('STATUS', 130) | Out-Null
$listView.Columns.Add('TARGET PATH', 280) | Out-Null
$listView.Columns.Add('LAUNCH COMMAND', 320) | Out-Null
$layout.Controls.Add($listView, 0, 2)
$listView.Add_SizeChanged({
    $availableWidth = $listView.ClientSize.Width - 4
    if ($availableWidth -gt 0) {
        $listView.Columns[0].Width = [Math]::Max(150, [int]($availableWidth * 0.17))
        $listView.Columns[1].Width = [Math]::Max(130, [int]($availableWidth * 0.16))
        $listView.Columns[2].Width = [Math]::Max(80, [int]($availableWidth * 0.08))
        $listView.Columns[3].Width = [Math]::Max(110, [int]($availableWidth * 0.11))
        $listView.Columns[4].Width = [Math]::Max(180, [int]($availableWidth * 0.22))
        $listView.Columns[5].Width = [Math]::Max(200, $availableWidth - $listView.Columns[0].Width - $listView.Columns[1].Width - $listView.Columns[2].Width - $listView.Columns[3].Width - $listView.Columns[4].Width)
    }
})
Set-PolishedListView -ListView $listView -Style 'startup'

$statusLabel = [System.Windows.Forms.Label]::new()
$statusLabel.Text = 'Refresh to collect startup entries.'
$statusLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
$statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$statusLabel.AutoEllipsis = $true
$statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(175, 180, 188)
$statusLabel.Padding = [System.Windows.Forms.Padding]::new(2, 0, 0, 0)
$layout.Controls.Add($statusLabel, 0, 3)
$form.Controls.Add($layout)

$script:startupEntries = @()
$script:lastReportErrors = @()

function Update-ToggleButtons {
    $selected = @($listView.SelectedItems | ForEach-Object { $_.Tag })
    $disableButton.Enabled = @($selected | Where-Object { $_.Startup -eq 'Enabled' }).Count -gt 0
    $enableButton.Enabled = @($selected | Where-Object { $_.Startup -eq 'Disabled' }).Count -gt 0
}

function Restart-AsAdministrator {
    $powerShellPath = (Get-Process -Id $PID).Path
    try {
        Start-Process -FilePath $powerShellPath -Verb RunAs -ArgumentList ('-STA -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath) -WindowStyle Hidden -ErrorAction Stop
        $form.Close()
    }
    catch {
        $statusLabel.Text = 'Relaunch as administrator was cancelled.'
    }
}

function Set-SelectedStartupState {
    param([Parameter(Mandatory)][bool]$Enable)

    $fromState = if ($Enable) { 'Disabled' } else { 'Enabled' }
    $targets = @($listView.SelectedItems | ForEach-Object { $_.Tag } | Where-Object { $_.Startup -eq $fromState })
    if ($targets.Count -eq 0) {
        return
    }

    $allUsersTargets = @($targets | Where-Object { $_.ApprovalHive -eq 'HKLM' })
    if (-not $script:isElevated -and $allUsersTargets.Count -gt 0) {
        $names = ($allUsersTargets | Select-Object -First 8 | ForEach-Object { '  ' + $_.Entry }) -join "`r`n"
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $form,
            "These entries start for all users, so changing them needs administrator rights:`r`n$names`r`n`r`nRelaunch as administrator now?`r`n(No = only change the entries for the current user.)",
            'Administrator rights needed',
            [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
            Restart-AsAdministrator
            return
        }
        if ($answer -ne [System.Windows.Forms.DialogResult]::No) {
            return
        }
        $targets = @($targets | Where-Object { $_.ApprovalHive -ne 'HKLM' })
        if ($targets.Count -eq 0) {
            return
        }
    }

    $failures = [System.Collections.Generic.List[string]]::new()
    $changed = 0
    foreach ($target in $targets) {
        try {
            Set-StartupApprovalState -Entry $target -Enable $Enable
            $changed++
        }
        catch {
            $failures.Add("$($target.Entry): $($_.Exception.Message)")
        }
    }

    $verb = if ($Enable) { 'Enabled' } else { 'Disabled' }
    $message = "$verb $changed entr$(if ($changed -eq 1) { 'y' } else { 'ies' }); takes effect at the next sign-in."
    Show-StartupReport -Message $message
    if ($failures.Count -gt 0) {
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            "Some entries could not be changed:`r`n$($failures -join "`r`n")",
            'Startup change failed',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
}

function Show-StartupReport {
    param([string]$Message)

    $refreshButton.Enabled = $false
    $disableButton.Enabled = $false
    $enableButton.Enabled = $false
    $exportButton.Enabled = $false
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $statusLabel.Text = 'Reading startup locations...'
    $listView.Items.Clear()

    try {
        $report = Get-StartupAuditReport
        $script:startupEntries = @($report.Entries)
        $script:lastReportErrors = @($report.Errors)
        $listView.BeginUpdate()
        try {
            foreach ($entry in $script:startupEntries) {
                $row = [System.Windows.Forms.ListViewItem]::new($entry.Source)
                $row.SubItems.Add($entry.Entry) | Out-Null
                $row.SubItems.Add($entry.Startup) | Out-Null
                $row.SubItems.Add($entry.Status) | Out-Null
                $row.SubItems.Add($entry.TargetPath) | Out-Null
                $row.SubItems.Add($entry.Command) | Out-Null
                $row.Tag = $entry
                switch ($entry.Status) {
                    'Target present' { $row.ForeColor = [System.Drawing.Color]::FromArgb(155, 210, 165) }
                    'Target missing' { $row.ForeColor = [System.Drawing.Color]::FromArgb(255, 135, 125) }
                    'Unresolved' { $row.ForeColor = [System.Drawing.Color]::FromArgb(255, 195, 115) }
                    default { $row.ForeColor = [System.Drawing.Color]::FromArgb(180, 195, 220) }
                }
                $listView.Items.Add($row) | Out-Null
            }
        }
        finally {
            $listView.EndUpdate()
        }

        $missingCount = @($script:startupEntries | Where-Object { $_.Status -eq 'Target missing' }).Count
        $unresolvedCount = @($script:startupEntries | Where-Object { $_.Status -eq 'Unresolved' }).Count
        $disabledCount = @($script:startupEntries | Where-Object { $_.Startup -eq 'Disabled' }).Count
        $statusLabel.Text = "Found $($script:startupEntries.Count) entries ($disabledCount disabled); $missingCount missing targets, $unresolvedCount unresolved."
        if ($Message) {
            $statusLabel.Text = "$Message  $($statusLabel.Text)"
        }
        $exportButton.Enabled = $script:startupEntries.Count -gt 0

        if ($script:lastReportErrors.Count -gt 0) {
            $errorText = ($script:lastReportErrors | Select-Object -First 10) -join "`r`n"
            if ($script:lastReportErrors.Count -gt 10) {
                $errorText += "`r`n...and $($script:lastReportErrors.Count - 10) more."
            }
            [System.Windows.Forms.MessageBox]::Show(
                $form,
                "Some startup locations could not be read ($($script:lastReportErrors.Count) errors):`r`n$errorText",
                'Report completed with warnings',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        }
    }
    catch {
        $statusLabel.Text = 'Report failed.'
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            $_.Exception.Message,
            'Could not create report',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $refreshButton.Enabled = $true
    }
}

$refreshButton.Add_Click({
    Show-StartupReport
})
$listView.Add_SelectedIndexChanged({
    Update-ToggleButtons
})
$disableButton.Add_Click({
    Set-SelectedStartupState -Enable $false
})
$enableButton.Add_Click({
    Set-SelectedStartupState -Enable $true
})
$adminButton.Add_Click({
    Restart-AsAdministrator
})

$exportDialog = [System.Windows.Forms.SaveFileDialog]::new()
$exportDialog.Filter = 'CSV files (*.csv)|*.csv'
$exportDialog.DefaultExt = 'csv'
$exportDialog.AddExtension = $true
$exportDialog.FileName = 'startup-program-report.csv'
$exportButton.Add_Click({
    if ($exportDialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) {
        return
    }
    try {
        $script:startupEntries |
            Select-Object Source, Entry, Startup, Status, TargetPath, Command, EntryPath |
            Export-Csv -LiteralPath $exportDialog.FileName -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        $statusLabel.Text = "Exported $($script:startupEntries.Count) entries to $($exportDialog.FileName)"
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
Show-StartupReport
[System.Windows.Forms.Application]::Run($form)
