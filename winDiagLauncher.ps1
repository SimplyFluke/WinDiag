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

$script:tools = @(
    [pscustomobject]@{
        Category = 'Files & Storage'
        Name = 'Duplicate Finder'
        File = 'duplicateFinder.ps1'
        Description = 'Find identical files and review suggested copies.'
    },
    [pscustomobject]@{
        Category = 'Files & Storage'
        Name = 'Large File Finder'
        File = 'largeFileFinder.ps1'
        Description = 'Locate the largest files in a folder or drive.'
    },
    [pscustomobject]@{
        Category = 'Files & Storage'
        Name = 'Folder Size Inspector'
        File = 'folderSizeInspector.ps1'
        Description = 'Compare folder sizes and drill down into contents.'
    },
    [pscustomobject]@{
        Category = 'Startup & Tasks'
        Name = 'Startup Program Auditor'
        File = 'startupProgramAuditor.ps1'
        Description = 'Review Run keys and Startup folder entries.'
    },
    [pscustomobject]@{
        Category = 'Startup & Tasks'
        Name = 'Suspicious Scheduled Task Auditor'
        File = 'suspiciousTaskAuditor.ps1'
        Description = 'Flag unusual task paths and encoded PowerShell.'
    },
    [pscustomobject]@{
        Category = 'Performance & Network'
        Name = 'Resource Hog Finder'
        File = 'resourceHogFinder.ps1'
        Description = 'Rank processes by sampled CPU or RAM usage.'
    },
    [pscustomobject]@{
        Category = 'Performance & Network'
        Name = 'Port Checker / Local Listener'
        File = 'portChecker.ps1'
        Description = 'Map local listening ports to processes and services.'
    },
    [pscustomobject]@{
        Category = 'Event Logs'
        Name = 'Recent Error & Critical Event Collector'
        File = 'recentErrorCollector.ps1'
        Description = 'Group recent Critical and Error events for review.'
    }
)

function Get-GitBlobSha1 {
    param([Parameter(Mandatory)][byte[]]$Bytes)

    $header = [System.Text.Encoding]::ASCII.GetBytes("blob $($Bytes.Length)`0")
    $blob = [byte[]]::new($header.Length + $Bytes.Length)
    [Array]::Copy($header, 0, $blob, 0, $header.Length)
    [Array]::Copy($Bytes, 0, $blob, $header.Length, $Bytes.Length)
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        ([BitConverter]::ToString($sha1.ComputeHash($blob))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha1.Dispose()
    }
}

function Get-LauncherUpdates {
    param(
        [Parameter(Mandatory)]
        [object[]]$Tools,

        [Parameter(Mandatory)]
        [string]$Directory,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$ProgressState
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $apiUri = 'https://api.github.com/repos/SimplyFluke/WinDiag/contents/?ref=main'
    $headers = @{
        Accept = 'application/vnd.github+json'
        'User-Agent' = 'WinDiagLauncher'
    }
    $ProgressState.Stage = 'Checking GitHub for script updates...'
    try {
        $repositoryResponse = Invoke-WebRequest -Uri $apiUri -Headers $headers -TimeoutSec 20 -UseBasicParsing -ErrorAction Stop
        $repositoryFiles = @(ConvertFrom-Json -InputObject $repositoryResponse.Content)
    }
    catch {
        return [pscustomobject]@{
            Results = @([pscustomobject]@{
                File = 'GitHub'
                Status = 'Check failed'
                Detail = $_.Exception.Message
            })
            CheckedCount = 0
            UpdatedCount = 0
            FailureCount = 1
        }
    }

    $filesByName = @{}
    foreach ($repositoryFile in $repositoryFiles) {
        if ($repositoryFile.type -eq 'file') {
            $filesByName[[string]$repositoryFile.name] = $repositoryFile
        }
    }

    $checkedCount = 0
    $updatedCount = 0
    $failureCount = 0
    for ($index = 0; $index -lt $Tools.Count; $index++) {
        $tool = $Tools[$index]
        $ProgressState.Stage = "Checking $($tool.Name) ($($index + 1) of $($Tools.Count))..."
        $checkedCount++
        if (-not $filesByName.ContainsKey($tool.File)) {
            $failureCount++
            $results.Add([pscustomobject]@{
                File = $tool.File
                Status = 'Not found in repository'
                Detail = 'The local copy was left unchanged.'
            })
            continue
        }

        $repositoryFile = $filesByName[$tool.File]
        $localPath = Join-Path $Directory $tool.File
        try {
            if (Test-Path -LiteralPath $localPath -PathType Leaf) {
                $localBytes = [System.IO.File]::ReadAllBytes($localPath)
                $localSha = Get-GitBlobSha1 -Bytes $localBytes
                if ($localSha -eq [string]$repositoryFile.sha) {
                    $results.Add([pscustomobject]@{
                        File = $tool.File
                        Status = 'Up to date'
                        Detail = ''
                    })
                    continue
                }
            }

            $ProgressState.Stage = "Downloading $($tool.Name)..."
            $response = Invoke-RestMethod -Uri ([string]$repositoryFile.git_url) -Headers $headers -TimeoutSec 20 -ErrorAction Stop
            if ($response.encoding -ne 'base64') {
                throw "GitHub returned an unsupported encoding for $($tool.File)."
            }
            $remoteBytes = [System.Convert]::FromBase64String([string]$response.content)
            $remoteContent = [System.Text.UTF8Encoding]::new($false, $true).GetString($remoteBytes)
            $downloadSha = Get-GitBlobSha1 -Bytes $remoteBytes
            if ($downloadSha -ne [string]$repositoryFile.sha) {
                throw 'The downloaded content did not match the repository file hash; the local copy was not changed.'
            }

            $tokens = $null
            $parseErrors = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput(
                $remoteContent,
                [ref]$tokens,
                [ref]$parseErrors
            )
            if ($parseErrors.Count -gt 0) {
                $parseSummary = ($parseErrors | Select-Object -First 5 | ForEach-Object { $_.Message }) -join '; '
                throw "The downloaded script has PowerShell syntax errors; the local copy was not changed. $parseSummary"
            }

            $temporaryPath = Join-Path $Directory ('.{0}.{1}.tmp' -f $tool.File, [guid]::NewGuid().ToString('N'))
            $backupPath = "$temporaryPath.backup"
            try {
                [System.IO.File]::WriteAllBytes($temporaryPath, $remoteBytes)
                if (Test-Path -LiteralPath $localPath -PathType Leaf) {
                    [System.IO.File]::Replace($temporaryPath, $localPath, $backupPath)
                    if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                        [System.IO.File]::Delete($backupPath)
                    }
                }
                else {
                    [System.IO.File]::Move($temporaryPath, $localPath)
                }
            }
            finally {
                if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
                    [System.IO.File]::Delete($temporaryPath)
                }
                if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                    [System.IO.File]::Delete($backupPath)
                }
            }

            $updatedCount++
            $results.Add([pscustomobject]@{
                File = $tool.File
                Status = 'Updated'
                Detail = ''
            })
        }
        catch {
            $failureCount++
            $results.Add([pscustomobject]@{
                File = $tool.File
                Status = 'Update failed'
                Detail = $_.Exception.Message
            })
        }
    }

    [pscustomobject]@{
        Results = @($results)
        CheckedCount = $checkedCount
        UpdatedCount = $updatedCount
        FailureCount = $failureCount
    }
}

$form = [System.Windows.Forms.Form]::new()
$form.Text = 'WinDiag'
$form.StartPosition = 'CenterScreen'
$form.Size = [System.Drawing.Size]::new(1080, 720)
$form.MinimumSize = [System.Drawing.Size]::new(820, 560)
$form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$form.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 230)
$form.Font = [System.Drawing.Font]::new('Segoe UI', 9)
$form.Padding = [System.Windows.Forms.Padding]::new(18)

$layout = [System.Windows.Forms.TableLayoutPanel]::new()
$layout.Dock = [System.Windows.Forms.DockStyle]::Fill
$layout.ColumnCount = 1
$layout.RowCount = 3
$layout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)) | Out-Null
$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 76)) | Out-Null
$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)) | Out-Null
$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 52)) | Out-Null

$headerPanel = [System.Windows.Forms.Panel]::new()
$headerPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$titleLabel = [System.Windows.Forms.Label]::new()
$titleLabel.Text = 'WinDiag'
$titleLabel.Location = [System.Drawing.Point]::new(0, 0)
$titleLabel.AutoSize = $true
$titleLabel.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 21)
$titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
$headerPanel.Controls.Add($titleLabel)
$subtitleLabel = [System.Windows.Forms.Label]::new()
$subtitleLabel.Text = 'A collection of lightweight Windows diagnostics and cleanup tools.'
$subtitleLabel.Location = [System.Drawing.Point]::new(2, 45)
$subtitleLabel.AutoSize = $true
$subtitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(165, 170, 178)
$headerPanel.Controls.Add($subtitleLabel)
$layout.Controls.Add($headerPanel, 0, 0)

$contentLayout = [System.Windows.Forms.TableLayoutPanel]::new()
$contentLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
$contentLayout.ColumnCount = 2
$contentLayout.RowCount = 1
$contentLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, 205)) | Out-Null
$contentLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)) | Out-Null

$categoryPanel = [System.Windows.Forms.FlowLayoutPanel]::new()
$categoryPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$categoryPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
$categoryPanel.WrapContents = $false
$categoryPanel.AutoScroll = $true
$categoryPanel.Padding = [System.Windows.Forms.Padding]::new(0, 4, 8, 0)
$categoryPanel.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$contentLayout.Controls.Add($categoryPanel, 0, 0)

$toolsPanel = [System.Windows.Forms.FlowLayoutPanel]::new()
$toolsPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$toolsPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$toolsPanel.WrapContents = $true
$toolsPanel.AutoScroll = $true
$toolsPanel.Padding = [System.Windows.Forms.Padding]::new(12)
$toolsPanel.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 38)
$contentLayout.Controls.Add($toolsPanel, 1, 0)
$layout.Controls.Add($contentLayout, 0, 1)

$footerPanel = [System.Windows.Forms.TableLayoutPanel]::new()
$footerPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$footerPanel.ColumnCount = 2
$footerPanel.RowCount = 1
$footerPanel.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100)) | Out-Null
$footerPanel.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, 180)) | Out-Null
$statusLabel = [System.Windows.Forms.Label]::new()
$statusLabel.Text = 'Tools are ready; checking for updates...'
$statusLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
$statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$statusLabel.AutoEllipsis = $true
$statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(175, 180, 188)
$statusLabel.Padding = [System.Windows.Forms.Padding]::new(2, 0, 0, 0)
$footerPanel.Controls.Add($statusLabel, 0, 0)
$progressBar = [System.Windows.Forms.ProgressBar]::new()
$progressBar.Dock = [System.Windows.Forms.DockStyle]::Fill
$progressBar.Margin = [System.Windows.Forms.Padding]::new(12, 14, 8, 14)
$progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
$progressBar.MarqueeAnimationSpeed = 25
$progressBar.Visible = $false
$footerPanel.Controls.Add($progressBar, 1, 0)
$layout.Controls.Add($footerPanel, 0, 2)
$form.Controls.Add($layout)

$script:categoryButtons = @{}
$script:updatePowerShell = $null
$script:updateRunspace = $null
$script:updateAsyncResult = $null
$script:updateProgressState = $null
$updateTimer = [System.Windows.Forms.Timer]::new()
$updateTimer.Interval = 150

function Start-Tool {
    param([Parameter(Mandatory)]$Tool)

    $toolPath = Join-Path $PSScriptRoot $Tool.File
    if (-not (Test-Path -LiteralPath $toolPath -PathType Leaf)) {
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            "The tool script could not be found:`r`n$toolPath",
            'Tool not found',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return
    }

    $powerShellPath = (Get-Process -Id $PID).Path
    if (-not $powerShellPath) {
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            'Could not determine the PowerShell executable path.',
            'Could not launch tool',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return
    }

    try {
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $powerShellPath
        $startInfo.Arguments = '-STA -NoProfile -File "{0}"' -f $toolPath
        $startInfo.WorkingDirectory = $PSScriptRoot
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $toolProcess = [System.Diagnostics.Process]::Start($startInfo)
        if (-not $toolProcess) {
            throw 'PowerShell did not return a process handle.'
        }
        $toolProcess.Dispose()
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            $_.Exception.Message,
            'Could not launch tool',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
}

function Show-ToolCategory {
    param([Parameter(Mandatory)][string]$Category)

    foreach ($control in @($toolsPanel.Controls)) {
        $toolsPanel.Controls.Remove($control)
        $control.Dispose()
    }
    foreach ($categoryName in $script:categoryButtons.Keys) {
        $button = $script:categoryButtons[$categoryName]
        if ($categoryName -eq $Category) {
            $button.BackColor = [System.Drawing.Color]::FromArgb(45, 105, 95)
            $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(60, 130, 118)
        }
        else {
            $button.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
            $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(70, 70, 75)
        }
    }

    foreach ($tool in @($script:tools | Where-Object { $_.Category -eq $Category })) {
        $card = [System.Windows.Forms.Panel]::new()
        $card.Size = [System.Drawing.Size]::new(335, 142)
        $card.Margin = [System.Windows.Forms.Padding]::new(0, 0, 12, 12)
        $card.Padding = [System.Windows.Forms.Padding]::new(12)
        $card.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)

        $toolTitle = [System.Windows.Forms.Label]::new()
        $toolTitle.Text = $tool.Name
        $toolTitle.Location = [System.Drawing.Point]::new(12, 10)
        $toolTitle.Size = [System.Drawing.Size]::new(305, 24)
        $toolTitle.AutoEllipsis = $true
        $toolTitle.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 10)
        $toolTitle.ForeColor = [System.Drawing.Color]::FromArgb(240, 240, 242)
        $card.Controls.Add($toolTitle)

        $description = [System.Windows.Forms.Label]::new()
        $description.Text = $tool.Description
        $description.Location = [System.Drawing.Point]::new(12, 39)
        $description.Size = [System.Drawing.Size]::new(305, 40)
        $description.ForeColor = [System.Drawing.Color]::FromArgb(175, 180, 188)
        $card.Controls.Add($description)

        $launchButton = [System.Windows.Forms.Button]::new()
        $launchButton.Text = 'Open tool'
        $launchButton.Location = [System.Drawing.Point]::new(12, 91)
        $launchButton.Size = [System.Drawing.Size]::new(112, 32)
        $launchButton.Tag = $tool
        $launchButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $launchButton.BackColor = [System.Drawing.Color]::FromArgb(55, 55, 58)
        $launchButton.ForeColor = $form.ForeColor
        $launchButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(80, 80, 85)
        $launchButton.UseVisualStyleBackColor = $false
        $launchButton.Cursor = [System.Windows.Forms.Cursors]::Hand
        $launchButton.Add_Click({
            param($Sender, $EventArgs)
            Start-Tool -Tool $Sender.Tag
        })
        $card.Controls.Add($launchButton)
        $toolsPanel.Controls.Add($card)
    }
}

function Start-UpdateCheck {
    if ($script:updateAsyncResult -and -not $script:updateAsyncResult.IsCompleted) {
        return
    }

    $progressBar.Visible = $true
    $statusLabel.Text = 'Tools are ready; checking for updates...'
    $script:updateProgressState = [hashtable]::Synchronized(@{
        Stage = 'Contacting GitHub...'
        Current = 0
    })

    try {
        $hashFunctionSource = (Get-Command Get-GitBlobSha1 -CommandType Function).ScriptBlock.ToString()
        $updateFunctionSource = (Get-Command Get-LauncherUpdates -CommandType Function).ScriptBlock.ToString()
        $workerScript = @"
param([object[]]`$Tools, [string]`$Directory, [System.Collections.IDictionary]`$ProgressState)
function Get-GitBlobSha1 {
$hashFunctionSource
}
function Get-LauncherUpdates {
$updateFunctionSource
}
Get-LauncherUpdates -Tools `$Tools -Directory `$Directory -ProgressState `$ProgressState
"@
        $script:updateRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $script:updateRunspace.Open()
        $script:updatePowerShell = [powershell]::Create()
        $script:updatePowerShell.Runspace = $script:updateRunspace
        $null = $script:updatePowerShell.AddScript($workerScript)
        $null = $script:updatePowerShell.AddArgument([object[]]$script:tools)
        $null = $script:updatePowerShell.AddArgument($PSScriptRoot)
        $null = $script:updatePowerShell.AddArgument($script:updateProgressState)
        $script:updateAsyncResult = $script:updatePowerShell.BeginInvoke()
        $updateTimer.Start()
    }
    catch {
        if ($script:updatePowerShell) {
            $script:updatePowerShell.Dispose()
            $script:updatePowerShell = $null
        }
        if ($script:updateRunspace) {
            $script:updateRunspace.Close()
            $script:updateRunspace.Dispose()
            $script:updateRunspace = $null
        }
        $script:updateAsyncResult = $null
        $script:updateProgressState = $null
        $progressBar.Visible = $false
        $statusLabel.Text = 'Could not start update check; local tools are available.'
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            $_.Exception.Message,
            'Could not start update check',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
}

$categoryNames = @($script:tools | Select-Object -ExpandProperty Category -Unique)
foreach ($categoryName in $categoryNames) {
    $categoryButton = [System.Windows.Forms.Button]::new()
    $categoryButton.Text = $categoryName
    $categoryButton.Tag = $categoryName
    $categoryButton.Size = [System.Drawing.Size]::new(180, 42)
    $categoryButton.Margin = [System.Windows.Forms.Padding]::new(0, 0, 0, 8)
    $categoryButton.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $categoryButton.Padding = [System.Windows.Forms.Padding]::new(10, 0, 0, 0)
    $categoryButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $categoryButton.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
    $categoryButton.ForeColor = $form.ForeColor
    $categoryButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(70, 70, 75)
    $categoryButton.UseVisualStyleBackColor = $false
    $categoryButton.Cursor = [System.Windows.Forms.Cursors]::Hand
    $categoryButton.Add_Click({
        param($Sender, $EventArgs)
        Show-ToolCategory -Category ([string]$Sender.Tag)
    })
    $script:categoryButtons[$categoryName] = $categoryButton
    $categoryPanel.Controls.Add($categoryButton)
}

$updateTimer.Add_Tick({
    if ($script:updateProgressState) {
        $statusLabel.Text = [string]$script:updateProgressState.Stage
    }
    if (-not $script:updateAsyncResult -or -not $script:updateAsyncResult.IsCompleted) {
        return
    }

    $updateTimer.Stop()
    $report = $null
    try {
        $output = $script:updatePowerShell.EndInvoke($script:updateAsyncResult)
        $workerErrors = @($script:updatePowerShell.Streams.Error)
        if ($workerErrors.Count -gt 0) {
            throw ($workerErrors | ForEach-Object { $_.ToString() }) -join "`r`n"
        }
        if ($output.Count -eq 0) {
            throw 'The update check completed without returning a report.'
        }
        $report = $output[$output.Count - 1]
        if ($report.FailureCount -gt 0) {
            $failures = @($report.Results | Where-Object { $_.Status -notin @('Up to date', 'Updated') })
            $failureText = ($failures | ForEach-Object { "$($_.File): $($_.Detail)" }) -join "`r`n"
            $statusLabel.Text = "Update check completed with $($report.FailureCount) issue(s); local tools remain available."
            [System.Windows.Forms.MessageBox]::Show(
                $form,
                "Some updates could not be checked or installed. Current local tools are still available.`r`n`r`n$failureText",
                'Update check completed with issues',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        }
        elseif ($report.UpdatedCount -gt 0) {
            $statusLabel.Text = "Updated $($report.UpdatedCount) script(s); checked $($report.CheckedCount) tools."
        }
        else {
            $statusLabel.Text = "All $($report.CheckedCount) scripts are up to date."
        }
    }
    catch {
        $statusLabel.Text = 'Update check failed; local tools remain available.'
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            "Could not check for or install updates. Current local tools are still available.`r`n`r`n$($_.Exception.Message)",
            'Update check failed',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
    finally {
        if ($script:updatePowerShell) {
            $script:updatePowerShell.Dispose()
            $script:updatePowerShell = $null
        }
        if ($script:updateRunspace) {
            $script:updateRunspace.Close()
            $script:updateRunspace.Dispose()
            $script:updateRunspace = $null
        }
        $script:updateAsyncResult = $null
        $script:updateProgressState = $null
        $progressBar.Visible = $false
    }
})

$form.Add_FormClosed({
    $updateTimer.Stop()
    $updateTimer.Dispose()
})

Show-ToolCategory -Category $categoryNames[0]
[System.Windows.Forms.Application]::EnableVisualStyles()
Start-UpdateCheck
[System.Windows.Forms.Application]::Run($form)
