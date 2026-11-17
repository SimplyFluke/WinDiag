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
    function Add-CheckRow {
        param([string]$Status, [string]$Area, [string]$Check, [AllowNull()][object]$Value, [string]$Recommendation = '')
        $rows.Add([pscustomobject]@{
            Status = $Status
            Area = $Area
            Check = $Check
            Value = [string]$Value
            Recommendation = $Recommendation
        })
    }

    $ProgressState.Stage = 'Checking antivirus...'
    $thirdPartyAntivirus = $false
    try {
        foreach ($product in @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop)) {
            $state = [int]$product.productState
            $enabled = ($state -band 0x1000) -ne 0
            $outOfDate = ($state -band 0x10) -ne 0
            if ($product.displayName -notmatch 'Defender') {
                $thirdPartyAntivirus = $thirdPartyAntivirus -or $enabled
            }
            $status = if (-not $enabled) { 'Info' } elseif ($outOfDate) { 'Warning' } else { 'OK' }
            $value = '{0}, {1}' -f $(if ($enabled) { 'enabled' } else { 'not active' }), $(if ($outOfDate) { 'out of date' } else { 'up to date' })
            Add-CheckRow -Status $status -Area 'Antivirus' -Check "Registered: $($product.displayName)" -Value $value
        }
    }
    catch {
        $errors.Add("Security Center: $($_.Exception.Message)")
    }

    try {
        $defender = Get-MpComputerStatus -ErrorAction Stop
        $mode = [string]$defender.AMRunningMode
        if ($mode) {
            Add-CheckRow -Status 'Info' -Area 'Antivirus' -Check 'Defender running mode' -Value $mode
        }
        $defenderPrimary = -not $thirdPartyAntivirus -and $mode -notmatch 'Passive|EDR'
        if ($defenderPrimary) {
            $realTimeStatus = if ($defender.RealTimeProtectionEnabled) { 'OK' } else { 'Critical' }
            $realTimeText = if ($defender.RealTimeProtectionEnabled) { 'On' } else { 'Off' }
            Add-CheckRow -Status $realTimeStatus -Area 'Antivirus' -Check 'Defender real-time protection' -Value $realTimeText -Recommendation $(if ($realTimeStatus -ne 'OK') { 'Turn on real-time protection in Windows Security.' } else { '' })

            $signatureAge = [int]$defender.AntivirusSignatureAge
            $signatureStatus = if ($signatureAge -gt 7) { 'Critical' } elseif ($signatureAge -gt 2) { 'Warning' } else { 'OK' }
            Add-CheckRow -Status $signatureStatus -Area 'Antivirus' -Check 'Defender definitions' -Value "$signatureAge day(s) old ($($defender.AntivirusSignatureVersion))" -Recommendation $(if ($signatureStatus -ne 'OK') { 'Run Windows Update or update definitions in Windows Security.' } else { '' })

            $scanAge = [long]$defender.QuickScanAge
            $scanText = if ($scanAge -ge 4294967295 -or $scanAge -lt 0) { 'Never' } else { "$scanAge day(s) ago" }
            $scanStatus = if ($scanText -eq 'Never' -or $scanAge -gt 14) { 'Warning' } else { 'OK' }
            Add-CheckRow -Status $scanStatus -Area 'Antivirus' -Check 'Last quick scan' -Value $scanText
        }
        $tamperStatus = if ($defender.IsTamperProtected) { 'OK' } elseif ($defenderPrimary) { 'Warning' } else { 'Info' }
        $tamperText = if ($defender.IsTamperProtected) { 'On' } else { 'Off' }
        Add-CheckRow -Status $tamperStatus -Area 'Antivirus' -Check 'Tamper protection' -Value $tamperText -Recommendation $(if ($tamperStatus -eq 'Warning') { 'Turn on Tamper Protection to stop malware disabling Defender.' } else { '' })
    }
    catch {
        if (-not $thirdPartyAntivirus) {
            $errors.Add("Microsoft Defender status: $($_.Exception.Message)")
        }
    }

    $ProgressState.Stage = 'Checking the firewall...'
    try {
        foreach ($firewallProfile in @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop)) {
            $enabled = [string]$firewallProfile.Enabled -eq 'True'
            $status = if ($enabled) { 'OK' } else { 'Critical' }
            $value = if ($enabled) { 'On' } else { 'Off' }
            Add-CheckRow -Status $status -Area 'Firewall' -Check "$($firewallProfile.Name) profile" -Value $value -Recommendation $(if (-not $enabled) { 'Turn the Windows Firewall on for this profile unless another firewall replaces it.' } else { '' })
        }
    }
    catch {
        $errors.Add("Firewall: $($_.Exception.Message)")
    }

    $ProgressState.Stage = 'Checking BitLocker...'
    $bitLockerDone = $false
    if ($IsElevated) {
        try {
            foreach ($volume in @(Get-BitLockerVolume -ErrorAction Stop | Where-Object { [string]$_.VolumeType -ne 'Removable' })) {
                $protected = [string]$volume.ProtectionStatus -eq 'On'
                $isOsVolume = [string]$volume.VolumeType -eq 'OperatingSystem'
                $status = if ($protected) { 'OK' } elseif ($isOsVolume) { 'Warning' } else { 'Info' }
                $value = '{0}, {1} ({2}% encrypted)' -f $(if ($protected) { 'Protected' } else { 'Not protected' }), $volume.VolumeStatus, $volume.EncryptionPercentage
                Add-CheckRow -Status $status -Area 'Encryption' -Check "BitLocker $($volume.MountPoint)" -Value $value -Recommendation $(if (-not $protected -and $isOsVolume) { 'Encrypt the system drive, especially on laptops.' } else { '' })
            }
            $bitLockerDone = $true
        }
        catch {
            $errors.Add("BitLocker: $($_.Exception.Message)")
        }
    }
    if (-not $bitLockerDone) {
        try {
            $shell = New-Object -ComObject 'Shell.Application'
            $driveText = $env:SystemDrive
            $protection = $shell.NameSpace("$driveText\").Self.ExtendedProperty('System.Volume.BitLockerProtection')
            $states = @{ 0 = 'Not encryptable'; 1 = 'On'; 2 = 'Off'; 3 = 'Encrypting'; 4 = 'Decrypting'; 5 = 'Suspended'; 6 = 'On (locked)'; 8 = 'Waiting for activation' }
            $stateText = if ($null -ne $protection -and $states.ContainsKey([int]$protection)) { $states[[int]$protection] } else { 'Unknown' }
            $status = switch ($stateText) {
                'On' { 'OK' }
                'On (locked)' { 'OK' }
                'Encrypting' { 'Info' }
                'Unknown' { 'Info' }
                default { 'Warning' }
            }
            Add-CheckRow -Status $status -Area 'Encryption' -Check "BitLocker $driveText" -Value $stateText -Recommendation $(if ($status -eq 'Warning') { 'Encrypt the system drive, especially on laptops.' } else { '' })
        }
        catch {
            $errors.Add("BitLocker (basic check): $($_.Exception.Message)")
        }
    }

    $ProgressState.Stage = 'Checking account and sign-in settings...'
    $systemPolicies = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $enableLua = Get-RegistryValueSafe -Path $systemPolicies -Name 'EnableLUA'
    $consentAdmin = Get-RegistryValueSafe -Path $systemPolicies -Name 'ConsentPromptBehaviorAdmin'
    if ($enableLua -eq 0) {
        Add-CheckRow -Status 'Critical' -Area 'Accounts' -Check 'User Account Control' -Value 'Disabled' -Recommendation 'Re-enable UAC; with it off every program runs with full admin rights.'
    }
    elseif ($consentAdmin -eq 0) {
        Add-CheckRow -Status 'Warning' -Area 'Accounts' -Check 'User Account Control' -Value 'Elevates without prompting' -Recommendation 'Set UAC back to at least the default notification level.'
    }
    else {
        Add-CheckRow -Status 'OK' -Area 'Accounts' -Check 'User Account Control' -Value 'Enabled'
    }

    try {
        $adminSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
        $adminGroupName = $adminSid.Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]
        $group = [ADSI]"WinNT://$env:COMPUTERNAME/$adminGroupName,group"
        $members = @($group.Invoke('Members') | ForEach-Object {
            $path = [string]$_.GetType().InvokeMember('AdsPath', 'GetProperty', $null, $_, $null)
            $pathParts = @(($path -replace '^WinNT://', '').Split('/') | Where-Object { $_ })
            $memberName = ($pathParts | Select-Object -Last 2) -join '\'
            if ($memberName -match '^(S-1-[\d-]+)$') {
                try {
                    $memberName = ([System.Security.Principal.SecurityIdentifier]::new($Matches[1])).Translate([System.Security.Principal.NTAccount]).Value
                }
                catch {
                    if ($memberName -like 'S-1-12-1-*') {
                        $memberName = "$memberName (Entra ID user or group)"
                    }
                }
            }
            $memberName
        })
        $status = if ($members.Count -gt 3) { 'Warning' } else { 'Info' }
        Add-CheckRow -Status $status -Area 'Accounts' -Check "Local administrators ($($members.Count))" -Value ($members -join '; ') -Recommendation $(if ($status -eq 'Warning') { 'Review that every member really needs admin rights.' } else { '' })
    }
    catch {
        $errors.Add("Local administrators: $($_.Exception.Message)")
    }

    try {
        foreach ($account in @(Get-CimInstance -ClassName Win32_UserAccount -Filter 'LocalAccount=True' -ErrorAction Stop)) {
            if ($account.SID -like '*-501' -and -not $account.Disabled) {
                Add-CheckRow -Status 'Warning' -Area 'Accounts' -Check "Built-in Guest account ($($account.Name))" -Value 'Enabled' -Recommendation 'Disable the Guest account.'
            }
            elseif ($account.SID -like '*-500' -and -not $account.Disabled) {
                Add-CheckRow -Status 'Info' -Area 'Accounts' -Check "Built-in Administrator ($($account.Name))" -Value 'Enabled' -Recommendation 'Disable it unless it is needed; use named admin accounts instead.'
            }
        }
    }
    catch {
        $errors.Add("Local accounts: $($_.Exception.Message)")
    }

    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    if ([string](Get-RegistryValueSafe -Path $winlogon -Name 'AutoAdminLogon') -eq '1') {
        if (Get-RegistryValueSafe -Path $winlogon -Name 'DefaultPassword') {
            Add-CheckRow -Status 'Critical' -Area 'Accounts' -Check 'Automatic sign-in' -Value 'Enabled with a stored plain-text password' -Recommendation 'Remove AutoAdminLogon and DefaultPassword from the Winlogon registry key.'
        }
        else {
            Add-CheckRow -Status 'Warning' -Area 'Accounts' -Check 'Automatic sign-in' -Value 'Enabled' -Recommendation 'Anyone with physical access gets a signed-in session.'
        }
    }

    $ProgressState.Stage = 'Checking network exposure...'
    $denyRdp = Get-RegistryValueSafe -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections'
    if ($denyRdp -eq 0) {
        $nla = Get-RegistryValueSafe -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'UserAuthentication'
        if ($nla -eq 0) {
            Add-CheckRow -Status 'Warning' -Area 'Network' -Check 'Remote Desktop' -Value 'Enabled without Network Level Authentication' -Recommendation 'Require Network Level Authentication, or turn Remote Desktop off if unused.'
        }
        else {
            Add-CheckRow -Status 'Info' -Area 'Network' -Check 'Remote Desktop' -Value 'Enabled (NLA required)' -Recommendation 'Fine if intended; make sure it is not exposed directly to the internet.'
        }
    }
    else {
        Add-CheckRow -Status 'OK' -Area 'Network' -Check 'Remote Desktop' -Value 'Disabled'
    }

    $smb1Server = $null
    if ($IsElevated) {
        try {
            $smb1Server = [bool](Get-SmbServerConfiguration -ErrorAction Stop).EnableSMB1Protocol
        }
        catch {
        }
    }
    if ($null -eq $smb1Server) {
        $smb1Server = (Get-RegistryValueSafe -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' -Name 'SMB1') -eq 1
    }
    $smb1ClientStart = Get-RegistryValueSafe -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\mrxsmb10' -Name 'Start'
    $smb1Client = $null -ne $smb1ClientStart -and $smb1ClientStart -ne 4
    if ($smb1Server -or $smb1Client) {
        $parts = @()
        if ($smb1Server) { $parts += 'server' }
        if ($smb1Client) { $parts += 'client' }
        Add-CheckRow -Status 'Warning' -Area 'Network' -Check 'SMBv1' -Value "Enabled ($($parts -join ' and '))" -Recommendation 'Remove the SMB 1.0/CIFS feature unless an old device truly needs it.'
    }
    else {
        Add-CheckRow -Status 'OK' -Area 'Network' -Check 'SMBv1' -Value 'Disabled'
    }

    $ProgressState.Stage = 'Checking platform protections...'
    $secureBoot = Get-RegistryValueSafe -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -Name 'UEFISecureBootEnabled'
    $secureBootStatus = if ($secureBoot -eq 1) { 'OK' } elseif ($secureBoot -eq 0) { 'Warning' } else { 'Info' }
    $secureBootText = if ($secureBoot -eq 1) { 'Enabled' } elseif ($secureBoot -eq 0) { 'Disabled' } else { 'Not supported or unknown' }
    Add-CheckRow -Status $secureBootStatus -Area 'Platform' -Check 'Secure Boot' -Value $secureBootText -Recommendation $(if ($secureBootStatus -eq 'Warning') { 'Enable Secure Boot in the UEFI settings.' } else { '' })

    try {
        $deviceGuard = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
        $vbsRunning = [int]$deviceGuard.VirtualizationBasedSecurityStatus -eq 2
        $services = @($deviceGuard.SecurityServicesRunning)
        $vbsStatus = if ($vbsRunning) { 'OK' } else { 'Info' }
        $vbsValue = if ($vbsRunning) { 'Running' } else { 'Not running' }
        Add-CheckRow -Status $vbsStatus -Area 'Platform' -Check 'Virtualization-based security' -Value $vbsValue
        $credentialGuard = if ($services -contains 1) { 'Running' } else { 'Not running' }
        Add-CheckRow -Status $(if ($services -contains 1) { 'OK' } else { 'Info' }) -Area 'Platform' -Check 'Credential Guard' -Value $credentialGuard
        $hvci = if ($services -contains 2) { 'Running' } else { 'Not running' }
        Add-CheckRow -Status $(if ($services -contains 2) { 'OK' } else { 'Info' }) -Area 'Platform' -Check 'Memory integrity (HVCI)' -Value $hvci -Recommendation $(if ($services -notcontains 2) { 'Consider enabling Memory integrity under Windows Security > Device security > Core isolation.' } else { '' })
    }
    catch {
        $errors.Add("Device Guard: $($_.Exception.Message)")
    }

    $runAsPpl = Get-RegistryValueSafe -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'RunAsPPL'
    $lsaStatus = if ($runAsPpl -in @(1, 2)) { 'OK' } else { 'Info' }
    $lsaValue = if ($runAsPpl -in @(1, 2)) { 'Enabled' } else { 'Not configured' }
    Add-CheckRow -Status $lsaStatus -Area 'Platform' -Check 'LSA protection' -Value $lsaValue -Recommendation $(if ($lsaStatus -ne 'OK') { 'LSA protection makes credential theft harder; enable it under Core isolation if supported.' } else { '' })

    if ((Get-RegistryValueSafe -Path 'HKLM:\SOFTWARE\Microsoft\PowerShell\1\PowerShellEngine' -Name 'PowerShellVersion') -eq '2.0') {
        Add-CheckRow -Status 'Warning' -Area 'Platform' -Check 'Windows PowerShell 2.0 engine' -Value 'Installed' -Recommendation 'Remove the PowerShell 2.0 feature; attackers use it to bypass logging.'
    }

    $issueCount = @($rows | Where-Object { $_.Status -in @('Critical', 'Warning') }).Count
    [pscustomobject]@{
        Rows = @($rows)
        Summary = if ($issueCount -gt 0) { "$issueCount item(s) need attention." } else { 'No security issues found.' }
        Errors = @($errors)
    }
}

$script:toolDefinition = @{
    Title = 'Security Posture Check'
    Subtitle = 'Antivirus, firewall, BitLocker, UAC, admin accounts, Remote Desktop, SMBv1 and platform protections at a glance.'
    ScanButtonText = 'Refresh'
    ExportName = 'security-posture.csv'
    RequiresAdmin = $true
    IssueFilter = $true
    WorkerFunctions = @('Get-ToolReport')
    Columns = @(
        @{ Header = 'STATUS'; Property = 'Status'; Weight = 8; Align = 'Center' }
        @{ Header = 'AREA'; Property = 'Area'; Weight = 10 }
        @{ Header = 'CHECK'; Property = 'Check'; Weight = 22 }
        @{ Header = 'VALUE'; Property = 'Value'; Weight = 24 }
        @{ Header = 'RECOMMENDATION'; Property = 'Recommendation'; Weight = 36; Muted = $true }
    )
    Actions = @(
        @{
            Text = 'Open Windows Security'
            Kind = 'Ui'
            Handler = {
                param($Rows)
                Start-Process -FilePath 'windowsdefender:'
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
            $arguments = '-WindowStyle Hidden -STA -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $script:toolScriptPath
            Start-Process -FilePath $powerShellPath -ArgumentList $arguments -Verb RunAs -ErrorAction Stop
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
