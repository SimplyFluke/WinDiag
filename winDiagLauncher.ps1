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

$script:launcherFile = 'winDiagLauncher.ps1'
$script:launcherDirectory = $PSScriptRoot
$script:tools = @(
    [pscustomobject]@{
        Category = 'System Health'
        Name = 'System Summary'
        File = 'systemSummary.ps1'
        Description = 'Windows version, uptime, pending reboots, firmware, hardware and drive space.'
    },
    [pscustomobject]@{
        Category = 'System Health'
        Name = 'Disk Health Checker'
        File = 'diskHealthChecker.ps1'
        Description = 'Disk health, SSD wear, temperature, read errors and free space.'
    },
    [pscustomobject]@{
        Category = 'System Health'
        Name = 'Crash & BSOD Analyzer'
        File = 'crashAnalyzer.ps1'
        Description = 'Blue screens, unexpected restarts, hardware errors and dump files.'
    },
    [pscustomobject]@{
        Category = 'System Health'
        Name = 'Reliability History'
        File = 'reliabilityHistory.ps1'
        Description = 'App crashes, hangs and failed installs from Reliability Monitor.'
    },
    [pscustomobject]@{
        Category = 'System Health'
        Name = 'Battery Report'
        File = 'batteryReport.ps1'
        Description = 'Battery wear compared with design capacity, cycles and runtime.'
    },
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
        Category = 'Files & Storage'
        Name = 'Temp & Cache Cleaner'
        File = 'tempCleaner.ps1'
        Description = 'Measure and clear temp files, update caches, browser caches and the Recycle Bin.'
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
        Category = 'Performance & Network'
        Name = 'Network Diagnostics'
        File = 'networkDiagnostics.ps1'
        Description = 'Step through adapter, IP, gateway, DNS, internet and proxy checks.'
    },
    [pscustomobject]@{
        Category = 'Performance & Network'
        Name = 'Wi-Fi Report'
        File = 'wifiReport.ps1'
        Description = 'Current signal and link details plus recent disconnects.'
    },
    [pscustomobject]@{
        Category = 'Updates & Software'
        Name = 'Windows Update Status'
        File = 'windowsUpdateStatus.ps1'
        Description = 'Last update, failed installs, pending restarts and available updates.'
    },
    [pscustomobject]@{
        Category = 'Updates & Software'
        Name = 'Installed Software Inventory'
        File = 'installedSoftware.ps1'
        Description = 'Every installed program and Store app with version, date and size.'
    },
    [pscustomobject]@{
        Category = 'Updates & Software'
        Name = 'Driver Inventory'
        File = 'driverInventory.ps1'
        Description = 'Devices with errors, unsigned drivers and driver versions.'
    },
    [pscustomobject]@{
        Category = 'Security'
        Name = 'Security Posture Check'
        File = 'securityPostureCheck.ps1'
        Description = 'Antivirus, firewall, BitLocker, UAC, admins, RDP and SMBv1.'
    },
    [pscustomobject]@{
        Category = 'Security'
        Name = 'Service Auditor'
        File = 'serviceAuditor.ps1'
        Description = 'Unquoted paths, unsigned or missing executables and failed services.'
    },
    [pscustomobject]@{
        Category = 'Security'
        Name = 'Browser Hijack Check'
        File = 'browserHijackCheck.ps1'
        Description = 'Forced browser policies, search and start pages, proxy, hosts file, DNS and shortcuts.'
    },
    [pscustomobject]@{
        Category = 'Security'
        Name = 'Remote Access Detector'
        File = 'remoteAccessDetector.ps1'
        Description = 'AnyDesk, TeamViewer and other remote control tools, plus Remote Desktop settings.'
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

    # Only the file listing uses the GitHub API (60 unauthenticated requests per hour per IP address).
    # File contents come from raw.githubusercontent.com, which is not counted against that limit, and the
    # listing is cached with its ETag because "304 Not Modified" answers do not count against the limit either.
    $results = [System.Collections.Generic.List[object]]::new()
    $apiUri = 'https://api.github.com/repos/SimplyFluke/WinDiag/contents/?ref=main'
    $rawBaseUri = 'https://raw.githubusercontent.com/SimplyFluke/WinDiag/main/'
    $cachePath = Join-Path $Directory '.windiag-update-cache.json'
    $headers = @{
        Accept = 'application/vnd.github+json'
        'User-Agent' = 'WinDiagLauncher'
    }

    function Get-HttpErrorInfo {
        param($ErrorRecord)
        $info = @{ StatusCode = $null; ResetTime = $null }
        $response = $ErrorRecord.Exception.Response
        if (-not $response) {
            return $info
        }
        try {
            $info.StatusCode = [int]$response.StatusCode
        }
        catch {
        }
        $resetValue = $null
        try {
            $resetValue = $response.Headers['X-RateLimit-Reset']
        }
        catch {
        }
        if (-not $resetValue) {
            try {
                $resetValue = @($response.Headers.GetValues('X-RateLimit-Reset'))[0]
            }
            catch {
            }
        }
        if ($resetValue) {
            try {
                $info.ResetTime = [DateTimeOffset]::FromUnixTimeSeconds([long]$resetValue).LocalDateTime
            }
            catch {
            }
        }
        $info
    }

    function Get-RawFileBytes {
        param([Parameter(Mandatory)][string]$FileName)
        $uri = $rawBaseUri + [System.Uri]::EscapeDataString($FileName)
        $response = Invoke-WebRequest -Uri $uri -Headers @{ 'User-Agent' = 'WinDiagLauncher' } -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop
        $response.RawContentStream.ToArray()
    }

    function Install-ScriptBytes {
        param([Parameter(Mandatory)][byte[]]$Bytes, [Parameter(Mandatory)][string]$FileName)
        $content = [System.Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) {
            $parseSummary = ($parseErrors | Select-Object -First 5 | ForEach-Object { $_.Message }) -join '; '
            throw "The downloaded script has PowerShell syntax errors; the local copy was not changed. $parseSummary"
        }

        $localPath = Join-Path $Directory $FileName
        $temporaryPath = Join-Path $Directory ('.{0}.{1}.tmp' -f $FileName, [guid]::NewGuid().ToString('N'))
        $backupPath = "$temporaryPath.backup"
        try {
            [System.IO.File]::WriteAllBytes($temporaryPath, $Bytes)
            if (Test-Path -LiteralPath $localPath -PathType Leaf) {
                [System.IO.File]::Replace($temporaryPath, $localPath, $backupPath)
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
    }

    $ProgressState.Stage = 'Checking GitHub for script updates...'
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    }
    catch {
    }

    $cache = $null
    if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
        try {
            $cache = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($cachePath))
        }
        catch {
            $cache = $null
        }
    }
    $listingHeaders = $headers.Clone()
    if ($cache -and $cache.ETag -and $cache.Content) {
        $listingHeaders['If-None-Match'] = [string]$cache.ETag
    }

    $listingJson = $null
    $listingProblem = $null
    try {
        $listingResponse = Invoke-WebRequest -Uri $apiUri -Headers $listingHeaders -TimeoutSec 20 -UseBasicParsing -ErrorAction Stop
        if ([int]$listingResponse.StatusCode -eq 304 -and $cache) {
            $listingJson = [string]$cache.Content
        }
        else {
            $listingJson = [string]$listingResponse.Content
            $etag = @($listingResponse.Headers['ETag'])[0]
            if ($etag) {
                try {
                    if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
                        # Hidden files cannot be overwritten with WriteAllText, so clear the attribute first.
                        (Get-Item -LiteralPath $cachePath -Force).Attributes = [System.IO.FileAttributes]::Normal
                    }
                    [System.IO.File]::WriteAllText($cachePath, (ConvertTo-Json -InputObject @{ ETag = [string]$etag; Content = $listingJson } -Compress))
                    (Get-Item -LiteralPath $cachePath -Force).Attributes = [System.IO.FileAttributes]::Hidden
                }
                catch {
                }
            }
        }
    }
    catch {
        $httpInfo = Get-HttpErrorInfo -ErrorRecord $_
        if ($httpInfo.StatusCode -eq 304 -and $cache) {
            $listingJson = [string]$cache.Content
        }
        elseif ($httpInfo.StatusCode -in @(403, 429)) {
            $resetText = if ($httpInfo.ResetTime) { " until $($httpInfo.ResetTime.ToString('HH:mm'))" } else { ' for up to an hour' }
            $listingProblem = "GitHub's hourly limit for update checks from this network is used up; updates are paused$resetText."
        }
        else {
            $listingProblem = "Could not reach GitHub: $($_.Exception.Message)"
        }
    }

    $filesByName = @{}
    if ($listingJson) {
        # Windows PowerShell 5.1 emits a JSON array as a single object; unroll it explicitly.
        foreach ($repositoryFile in @(ConvertFrom-Json -InputObject $listingJson | ForEach-Object { $_ })) {
            if ($repositoryFile.type -eq 'file') {
                $filesByName[[string]$repositoryFile.name] = $repositoryFile
            }
        }
    }

    $checkedCount = 0
    $updatedCount = 0
    $failureCount = 0
    for ($index = 0; $index -lt $Tools.Count; $index++) {
        $tool = $Tools[$index]
        $ProgressState.Stage = "Checking $($tool.Name) ($($index + 1) of $($Tools.Count))..."
        $checkedCount++
        $localPath = Join-Path $Directory $tool.File
        $localExists = Test-Path -LiteralPath $localPath -PathType Leaf

        if (-not $listingJson) {
            # No file list (rate limit or offline): leave existing files alone, but still try to fetch missing ones.
            if ($localExists) {
                $results.Add([pscustomobject]@{ File = $tool.File; Status = 'Not checked'; Detail = '' })
                continue
            }
            try {
                $ProgressState.Stage = "Downloading $($tool.Name)..."
                Install-ScriptBytes -Bytes (Get-RawFileBytes -FileName $tool.File) -FileName $tool.File
                $updatedCount++
                $results.Add([pscustomobject]@{ File = $tool.File; Status = 'Updated'; Detail = 'Downloaded without a checksum check.' })
            }
            catch {
                $failureCount++
                $httpInfo = Get-HttpErrorInfo -ErrorRecord $_
                $detail = if ($httpInfo.StatusCode -eq 404) { 'Not published to GitHub yet, so it could not be downloaded.' } else { $_.Exception.Message }
                $results.Add([pscustomobject]@{ File = $tool.File; Status = 'Download failed'; Detail = $detail })
            }
            continue
        }

        if (-not $filesByName.ContainsKey($tool.File)) {
            $failureCount++
            $missingDetail = if (Test-Path -LiteralPath (Join-Path $Directory $tool.File) -PathType Leaf) {
                'The local copy was left unchanged.'
            }
            else {
                'Not published to GitHub yet, so it could not be downloaded.'
            }
            $results.Add([pscustomobject]@{
                File = $tool.File
                Status = 'Not found in repository'
                Detail = $missingDetail
            })
            continue
        }

        $repositoryFile = $filesByName[$tool.File]
        try {
            if ($localExists) {
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
            $remoteBytes = Get-RawFileBytes -FileName $tool.File
            if ((Get-GitBlobSha1 -Bytes $remoteBytes) -ne [string]$repositoryFile.sha) {
                # raw.githubusercontent.com caches files for a few minutes, so a fresh push can briefly serve the old copy.
                $results.Add([pscustomobject]@{
                    File = $tool.File
                    Status = 'Pending'
                    Detail = 'GitHub is still publishing the latest version; it will be installed on a later launch.'
                })
                continue
            }
            Install-ScriptBytes -Bytes $remoteBytes -FileName $tool.File

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

    $notice = $listingProblem
    $pendingCount = @($results | Where-Object { $_.Status -eq 'Pending' }).Count
    if (-not $notice -and $pendingCount -gt 0) {
        $notice = "$pendingCount update(s) are still being published by GitHub and will install on a later launch."
    }
    [pscustomobject]@{
        Results = @($results)
        CheckedCount = $checkedCount
        UpdatedCount = $updatedCount
        FailureCount = $failureCount
        Notice = $notice
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
        $missingText = if ($script:updateAsyncResult) {
            "$($Tool.Name) is still being downloaded. Try again when the update check in the status bar has finished."
        }
        else {
            "$($Tool.Name) has not been downloaded yet, and the last update check could not fetch it. Check the internet connection and restart WinDiag.`r`n`r`nExpected location: $toolPath"
        }
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            $missingText,
            'Tool not available yet',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
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
        $startInfo.Arguments = '-STA -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $toolPath
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

    $script:currentCategory = $Category
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

        $isDownloaded = Test-Path -LiteralPath (Join-Path $script:launcherDirectory $tool.File) -PathType Leaf
        $launchButton = [System.Windows.Forms.Button]::new()
        $launchButton.Text = if ($isDownloaded) { 'Open tool' } else { 'Not downloaded' }
        $launchButton.Location = [System.Drawing.Point]::new(12, 91)
        $launchButton.Size = [System.Drawing.Size]::new(112, 32)
        $launchButton.Tag = $tool
        $launchButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $launchButton.BackColor = [System.Drawing.Color]::FromArgb(55, 55, 58)
        $launchButton.ForeColor = if ($isDownloaded) { $form.ForeColor } else { [System.Drawing.Color]::FromArgb(140, 145, 152) }
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
        $filesToUpdate = @($script:tools) + @([pscustomobject]@{
            Name = 'WinDiag launcher'
            File = $script:launcherFile
        })
        $null = $script:updatePowerShell.AddArgument([object[]]$filesToUpdate)
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
            $failures = @($report.Results | Where-Object { $_.Status -notin @('Up to date', 'Updated', 'Not checked', 'Pending') })
            if ($report.Notice) {
                $failureText = "$($report.Notice)`r`n`r`n"
            }
            else {
                $failureText = ''
            }
            $failureText += ($failures | ForEach-Object { "$($_.File): $($_.Detail)" }) -join "`r`n"
            $statusLabel.Text = "Update check completed with $($report.FailureCount) issue(s); local tools remain available."
            [System.Windows.Forms.MessageBox]::Show(
                $form,
                "Some updates could not be checked or installed. Current local tools are still available.`r`n`r`n$failureText",
                'Update check completed with issues',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        }
        elseif ($report.Notice) {
            # Rate limits and CDN delays are expected now and then; report them quietly instead of with a dialog.
            $prefix = if ($report.UpdatedCount -gt 0) { "Downloaded $($report.UpdatedCount) script(s). " } else { '' }
            $statusLabel.Text = "$prefix$($report.Notice)"
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

    # Refresh the cards so tools downloaded during this check become available.
    if ($script:currentCategory) {
        Show-ToolCategory -Category $script:currentCategory
    }

    $launcherResult = $null
    if ($report) {
        $launcherResult = @($report.Results | Where-Object { $_.File -eq $script:launcherFile }) | Select-Object -First 1
    }
    if ($launcherResult -and $launcherResult.Status -eq 'Updated') {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $form,
            'A new version of the WinDiag launcher was downloaded. Restart WinDiag now to load it and any new tools?',
            'WinDiag updated',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
            try {
                $powerShellPath = (Get-Process -Id $PID).Path
                $arguments = '-STA -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $script:launcherDirectory $script:launcherFile)
                Start-Process -FilePath $powerShellPath -ArgumentList $arguments -WorkingDirectory $script:launcherDirectory -WindowStyle Hidden
                $form.Close()
            }
            catch {
                $statusLabel.Text = "Could not restart automatically: $($_.Exception.Message)"
            }
        }
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
