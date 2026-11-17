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

function Get-RemoteToolSignatures {
    # Name, process names, service names/display names, installed program names and downloaded file names (wildcards allowed).
    @(
        @{ Name = 'AnyDesk'; Processes = @('AnyDesk'); Services = @('AnyDesk*'); Programs = @('AnyDesk*'); Files = @('AnyDesk*.exe') }
        @{ Name = 'TeamViewer'; Processes = @('TeamViewer', 'TeamViewer_Service', 'tv_w32', 'tv_x64', 'TeamViewer_Desktop'); Services = @('TeamViewer*'); Programs = @('TeamViewer*'); Files = @('TeamViewer*.exe') }
        @{ Name = 'UltraViewer'; Processes = @('UltraViewer_Desktop', 'UltraViewer_Service', 'UltraViewer*'); Services = @('UltraViewService*', 'UltraViewer*'); Programs = @('UltraViewer*'); Files = @('UltraViewer*.exe') }
        @{ Name = 'ScreenConnect / ConnectWise Control'; Processes = @('ScreenConnect.ClientService', 'ScreenConnect.WindowsClient'); Services = @('ScreenConnect Client*'); Programs = @('ScreenConnect Client*', 'ConnectWise Control*'); Files = @('ScreenConnect*.exe', 'ConnectWiseControl*.exe') }
        @{ Name = 'LogMeIn'; Processes = @('LogMeIn', 'LMIGuardianSvc', 'LogMeInSystray'); Services = @('LogMeIn', 'LMIGuardianSvc', 'LMIMaint'); Programs = @('LogMeIn'); Files = @('LogMeIn*.exe') }
        @{ Name = 'LogMeIn Rescue'; Processes = @('LMI_Rescue*', 'lmi_rescue_srv', 'LMIR*'); Services = @('LMIRescue*'); Programs = @('LogMeIn Rescue*'); Files = @('Support-LogMeInRescue*.exe') }
        @{ Name = 'GoTo Resolve / GoToAssist'; Processes = @('g2ax_*', 'GoTo*Resolve*', 'GoToAssist*'); Services = @('GoTo*Resolve*', 'GoToAssist*'); Programs = @('GoTo Resolve*', 'GoToAssist*'); Files = @('GoToAssist*.exe', 'GoTo*Resolve*.exe') }
        @{ Name = 'Splashtop'; Processes = @('SRService', 'SRManager', 'SRAgent', 'SRServer'); Services = @('SplashtopRemoteService', 'Splashtop*'); Programs = @('Splashtop*'); Files = @('Splashtop*.exe') }
        @{ Name = 'RustDesk'; Processes = @('rustdesk'); Services = @('RustDesk'); Programs = @('RustDesk*'); Files = @('rustdesk*.exe') }
        @{ Name = 'HopToDesk'; Processes = @('HopToDesk'); Services = @('HopToDesk*'); Programs = @('HopToDesk*'); Files = @('HopToDesk*.exe') }
        @{ Name = 'Supremo'; Processes = @('Supremo', 'SupremoService', 'SupremoHelper'); Services = @('Supremo*'); Programs = @('Supremo*'); Files = @('Supremo*.exe') }
        @{ Name = 'AeroAdmin'; Processes = @('AeroAdmin'); Services = @('AeroAdmin*'); Programs = @('AeroAdmin*'); Files = @('AeroAdmin*.exe') }
        @{ Name = 'Ammyy Admin'; Processes = @('AA_v3', 'Ammyy*'); Services = @('AmmyyAdmin*'); Programs = @('Ammyy*'); Files = @('AA_v3*.exe', 'Ammyy*.exe') }
        @{ Name = 'RemotePC'; Processes = @('RemotePCService', 'RemotePCDesktop', 'RPCSuite'); Services = @('RPCService', 'RemotePC*'); Programs = @('RemotePC*'); Files = @('RemotePC*.exe') }
        @{ Name = 'Zoho Assist'; Processes = @('ZA_Connect', 'ZohoMeeting', 'ZAService'); Services = @('Zoho Assist*', 'ZohoAssist*'); Programs = @('Zoho Assist*'); Files = @('ZA_Connect*.exe', 'ZohoAssist*.exe') }
        @{ Name = 'BeyondTrust Remote Support (Bomgar)'; Processes = @('bomgar-scc', 'bomgar-rep', 'bomgar-pac', 'bomgar-rdp'); Services = @('bomgar-ps-*', 'bomgar*', 'BeyondTrust*'); Programs = @('*Bomgar*', '*BeyondTrust*', 'Representative Console*'); Files = @('bomgar*.exe') }
        @{ Name = 'Chrome Remote Desktop'; Processes = @('remoting_host'); Services = @('chromoting'); Programs = @('Chrome Remote Desktop Host*'); Files = @('chromeremotedesktophost*.msi') }
        @{ Name = 'VNC server (RealVNC, TightVNC, UltraVNC, TigerVNC)'; Processes = @('vncserver', 'winvnc*', 'tvnserver', 'vncserverui'); Services = @('vncserver', 'tvnserver', 'uvnc_service', 'TigerVNC*', 'WinVNC*'); Programs = @('*VNC Server*', 'TightVNC*', 'UltraVNC*', 'TigerVNC*'); Files = @('tightvnc*.exe', 'UltraVNC*.exe', 'VNC-Server*.exe') }
        @{ Name = 'Remote Utilities'; Processes = @('rutserv', 'rfusclient'); Services = @('RManService'); Programs = @('Remote Utilities*'); Files = @('rutserv*.exe', 'host*remote*utilities*.exe') }
        @{ Name = 'MeshCentral agent'; Processes = @('MeshAgent'); Services = @('Mesh Agent*'); Programs = @('Mesh Agent*'); Files = @('meshagent*.exe') }
        @{ Name = 'DWService'; Processes = @('dwagent', 'dwagsvc'); Services = @('DWAgent*'); Programs = @('DWAgent*'); Files = @('dwagent*.exe') }
        @{ Name = 'Getscreen.me'; Processes = @('getscreen'); Services = @('Getscreen*'); Programs = @('Getscreen*'); Files = @('getscreen*.exe') }
        @{ Name = 'Iperius Remote'; Processes = @('IperiusRemote'); Services = @('Iperius*Remote*'); Programs = @('Iperius Remote*'); Files = @('IperiusRemote*.exe') }
        @{ Name = 'ShowMyPC'; Processes = @('ShowMyPC*'); Services = @(); Programs = @('ShowMyPC*'); Files = @('ShowMyPC*.exe') }
        @{ Name = 'NoMachine'; Processes = @('nxservice*', 'nxserver'); Services = @('nxservice'); Programs = @('NoMachine*'); Files = @() }
        @{ Name = 'Parsec'; Processes = @('parsecd'); Services = @('Parsec*'); Programs = @('Parsec'); Files = @() }
        @{ Name = 'Atera agent (remote management)'; Processes = @('AteraAgent'); Services = @('AteraAgent'); Programs = @('AteraAgent*'); Files = @() }
        @{ Name = 'NinjaOne agent (remote management)'; Processes = @('NinjaRMMAgent', 'NinjaRMMAgentPatcher'); Services = @('NinjaRMMAgent'); Programs = @('NinjaRMMAgent*'); Files = @() }
        @{ Name = 'Kaseya / Datto agent (remote management)'; Processes = @('AgentMon', 'CagService'); Services = @('Kaseya Agent*', 'CagService'); Programs = @('Kaseya*', 'Datto RMM*'); Files = @() }
        @{ Name = 'Action1 agent (remote management)'; Processes = @('action1_agent'); Services = @('A1Agent'); Programs = @('Action1*'); Files = @() }
    )
}

function Test-WildcardMatch {
    param([AllowNull()][string]$Text, [string[]]$Patterns)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }
    foreach ($pattern in $Patterns) {
        if ($Text -like $pattern) {
            return $true
        }
    }
    $false
}

function Get-ConnectionLogSummary {
    param([string]$ToolName)

    # AnyDesk and TeamViewer keep plain-text logs of incoming sessions; useful after a support scam.
    $count = 0
    $latest = ''
    if ($ToolName -eq 'AnyDesk') {
        foreach ($path in @((Join-Path $env:ProgramData 'AnyDesk\connection_trace.txt'), (Join-Path $env:APPDATA 'AnyDesk\connection_trace.txt'))) {
            if (-not (Test-Path -LiteralPath $path)) {
                continue
            }
            foreach ($line in @(Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)) {
                if ($line -match '^\s*(Incoming|Innkommende|Eingehend|Entrante|Entrant)') {
                    $count++
                    $dateMatch = [regex]::Match($line, '\d{4}-\d{2}-\d{2},?\s+\d{1,2}:\d{2}')
                    if ($dateMatch.Success) {
                        $latest = $dateMatch.Value -replace ',', ''
                    }
                }
            }
        }
    }
    elseif ($ToolName -eq 'TeamViewer') {
        foreach ($folder in @($env:ProgramFiles, [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')) | Where-Object { $_ }) {
            $path = Join-Path $folder 'TeamViewer\Connections_incoming.txt'
            if (-not (Test-Path -LiteralPath $path)) {
                continue
            }
            foreach ($line in @(Get-Content -LiteralPath $path -ErrorAction SilentlyContinue | Where-Object { $_.Trim() })) {
                $count++
                $fields = $line -split "`t"
                if ($fields.Count -ge 3) {
                    $latest = $fields[2]
                }
            }
        }
    }
    else {
        return $null
    }
    if ($count -eq 0) {
        return $null
    }
    $isRecent = $false
    $parsed = [datetime]::MinValue
    foreach ($format in @('yyyy-MM-dd HH:mm', 'yyyy-MM-dd H:mm', 'dd-MM-yyyy HH:mm:ss', 'dd-MM-yyyy HH:mm')) {
        if ([datetime]::TryParseExact($latest.Trim(), $format, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            $isRecent = $parsed -gt (Get-Date).AddDays(-30)
            break
        }
    }
    [pscustomobject]@{
        Text = "$count incoming connection(s) logged$(if ($latest) { ", latest $latest" })."
        IsRecent = $isRecent
    }
}

function Get-DownloadsFolder {
    $path = [string](Get-RegistryValueSafe -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -Name '{374DE290-123F-4565-9164-39C4925E467B}')
    if ($path) {
        return [Environment]::ExpandEnvironmentVariables($path)
    }
    Join-Path $env:USERPROFILE 'Downloads'
}

function New-RemoteRow {
    param(
        [string]$Status,
        [string]$Tool,
        [string]$State,
        [string]$FoundAs,
        [string]$Findings,
        [string]$Location = '',
        [string]$FixKind = '',
        [string]$ServiceNames = '',
        [string]$ProcessPatterns = '',
        [string]$Details = ''
    )

    [pscustomobject]@{
        Status = $Status
        Tool = $Tool
        State = $State
        FoundAs = $FoundAs
        Findings = $Findings
        Location = if ($Location) { $Location } else { '-' }
        FixKind = $FixKind
        ServiceNames = $ServiceNames
        ProcessPatterns = $ProcessPatterns
        Details = $Details
    }
}

function Get-ToolReport {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$ProgressState,
        [bool]$IsElevated
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()

    $ProgressState.Stage = 'Reading running programs...'
    $processes = @()
    try {
        $processes = @(Get-Process -ErrorAction Stop | Select-Object ProcessName, Id, @{ Name = 'Path'; Expression = { try { $_.Path } catch { '' } } })
    }
    catch {
        $errors.Add("Processes: $($_.Exception.Message)")
    }

    $ProgressState.Stage = 'Reading services...'
    $services = @()
    try {
        $services = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop)
    }
    catch {
        $errors.Add("Services: $($_.Exception.Message)")
    }

    $ProgressState.Stage = 'Reading installed programs...'
    $programs = [System.Collections.Generic.List[object]]::new()
    foreach ($uninstallPath in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )) {
        foreach ($entry in @(Get-ItemProperty -Path $uninstallPath -ErrorAction SilentlyContinue)) {
            if ($entry.DisplayName -and -not $entry.SystemComponent) {
                $programs.Add($entry)
            }
        }
    }

    $ProgressState.Stage = 'Looking for downloaded remote access programs...'
    $looseFiles = [System.Collections.Generic.List[object]]::new()
    foreach ($folder in @((Get-DownloadsFolder), [Environment]::GetFolderPath('Desktop'), $env:TEMP) | Where-Object { $_ } | Select-Object -Unique) {
        if (Test-Path -LiteralPath $folder) {
            foreach ($file in @(Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(exe|msi)$' })) {
                $looseFiles.Add($file)
            }
        }
    }

    $ProgressState.Stage = 'Matching known remote access tools...'
    foreach ($signature in Get-RemoteToolSignatures) {
        $matchedProcesses = @($processes | Where-Object { Test-WildcardMatch -Text $_.ProcessName -Patterns $signature.Processes })
        $matchedServices = @($services | Where-Object { (Test-WildcardMatch -Text $_.Name -Patterns $signature.Services) -or (Test-WildcardMatch -Text $_.DisplayName -Patterns $signature.Services) })
        $matchedPrograms = @($programs | Where-Object { Test-WildcardMatch -Text $_.DisplayName -Patterns $signature.Programs })
        $matchedFiles = @($looseFiles | Where-Object { Test-WildcardMatch -Text $_.Name -Patterns $signature.Files })
        if ($matchedProcesses.Count + $matchedServices.Count + $matchedPrograms.Count + $matchedFiles.Count -eq 0) {
            continue
        }

        $foundAs = [System.Collections.Generic.List[string]]::new()
        $findings = [System.Collections.Generic.List[string]]::new()
        $details = [System.Collections.Generic.List[string]]::new()
        if ($matchedPrograms.Count) { $foundAs.Add('installed') }
        if ($matchedServices.Count) { $foundAs.Add('service') }
        if ($matchedProcesses.Count) { $foundAs.Add('running') }
        if ($matchedFiles.Count) { $foundAs.Add('downloaded file') }

        $autoServices = @($matchedServices | Where-Object { $_.StartMode -eq 'Auto' })
        $runningServices = @($matchedServices | Where-Object { $_.State -eq 'Running' })
        $status = 'Info'
        if ($autoServices.Count -gt 0 -or $runningServices.Count -gt 0) {
            $status = 'Warning'
            $state = 'Always on'
            $findings.Add('Runs as a service, so it can accept connections whenever the PC is on, without anyone at the keyboard. Remove it if you did not set this up.')
        }
        elseif ($matchedProcesses.Count -gt 0) {
            $status = 'Warning'
            $state = 'Running now'
            $findings.Add('Running right now. If someone you do not know asked you to start it, disconnect from the internet and close it.')
        }
        elseif ($matchedPrograms.Count -gt 0 -or $matchedServices.Count -gt 0) {
            $state = 'Installed'
            $findings.Add('Installed but not running.')
        }
        else {
            $state = 'Downloaded'
            $findings.Add('A downloaded copy was found; these run without installing. Delete it if you no longer need it.')
        }

        $log = Get-ConnectionLogSummary -ToolName $signature.Name
        if ($log) {
            $findings.Add($log.Text)
            if ($log.IsRecent) {
                $status = 'Warning'
                $findings.Add('Someone connected in the last 30 days.')
            }
        }

        $location = ''
        foreach ($program in $matchedPrograms) {
            $details.Add("Installed: $($program.DisplayName) $($program.DisplayVersion) ($($program.Publisher))".Trim())
            if (-not $location -and $program.InstallLocation) { $location = ([string]$program.InstallLocation).Trim('"') }
        }
        foreach ($service in $matchedServices) {
            $details.Add("Service: $($service.Name) [$($service.StartMode), $($service.State)] $($service.PathName)")
            if (-not $location -and $service.PathName) {
                $location = ([string]$service.PathName).Trim() -replace '^"([^"]+)".*$', '$1' -replace '^(\S+\.exe).*$', '$1'
            }
        }
        foreach ($process in $matchedProcesses) {
            $details.Add("Process: $($process.ProcessName) (PID $($process.Id)) $($process.Path)")
            if (-not $location -and $process.Path) { $location = $process.Path }
        }
        foreach ($file in $matchedFiles) {
            $details.Add("File: $($file.FullName) ($('{0:yyyy-MM-dd}' -f $file.LastWriteTime))")
            if (-not $location) { $location = $file.FullName }
        }

        $rows.Add((New-RemoteRow -Status $status -Tool $signature.Name -State $state -FoundAs ($foundAs -join ', ') -Findings ($findings -join ' ') -Location $location `
            -FixKind 'Product' -ServiceNames (($matchedServices | ForEach-Object { $_.Name }) -join ';') -ProcessPatterns ($signature.Processes -join ';') -Details ($details -join ' | ')))
    }

    $toolCount = $rows.Count
    if ($toolCount -eq 0) {
        $rows.Add((New-RemoteRow -Status 'OK' -Tool 'Third-party remote access tools' -State 'None found' -FoundAs '-' -Findings "None of the $(@(Get-RemoteToolSignatures).Count) known remote access tools were found running, installed or downloaded."))
    }

    $ProgressState.Stage = 'Checking built-in Windows remote access...'
    $rdpDenied = Get-RegistryValueSafe -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections'
    $edition = [string](Get-RegistryValueSafe -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'EditionID')
    if ($edition -match '^Core') {
        $rows.Add((New-RemoteRow -Status 'OK' -Tool 'Remote Desktop' -State 'Not available' -FoundAs 'Windows' -Findings 'Windows Home cannot accept Remote Desktop connections.'))
    }
    elseif ($null -ne $rdpDenied -and [int]$rdpDenied -eq 0) {
        $rows.Add((New-RemoteRow -Status 'Warning' -Tool 'Remote Desktop' -State 'On' -FoundAs 'Windows' -Findings 'Other computers can sign in to this PC with Remote Desktop. Turn it off unless you use it.' -FixKind 'Rdp'))
    }
    else {
        $rows.Add((New-RemoteRow -Status 'OK' -Tool 'Remote Desktop' -State 'Off' -FoundAs 'Windows' -Findings 'Remote Desktop connections to this PC are turned off.'))
    }

    $assistance = Get-RegistryValueSafe -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance' -Name 'fAllowToGetHelp'
    if ($null -ne $assistance -and [int]$assistance -eq 1) {
        $rows.Add((New-RemoteRow -Status 'Info' -Tool 'Remote Assistance' -State 'Allowed' -FoundAs 'Windows' -Findings 'Remote Assistance invitations can be sent from this PC. On by default on many PCs; it only works when someone here sends an invitation.' -FixKind 'RemoteAssistance'))
    }
    else {
        $rows.Add((New-RemoteRow -Status 'OK' -Tool 'Remote Assistance' -State 'Off' -FoundAs 'Windows' -Findings 'Remote Assistance invitations are turned off.'))
    }

    $quickAssist = @($processes | Where-Object { $_.ProcessName -eq 'QuickAssist' })
    if ($quickAssist.Count -gt 0) {
        $rows.Add((New-RemoteRow -Status 'Warning' -Tool 'Quick Assist' -State 'Running now' -FoundAs 'Windows' -Findings 'Quick Assist is open. Only share your screen with people you know; Microsoft never calls you unasked.' -FixKind 'Product' -ProcessPatterns 'QuickAssist'))
    }

    $ssh = @($services | Where-Object { $_.Name -eq 'sshd' })
    if ($ssh.Count -gt 0) {
        $sshStatus = if ($ssh[0].StartMode -eq 'Auto' -or $ssh[0].State -eq 'Running') { 'Warning' } else { 'Info' }
        $rows.Add((New-RemoteRow -Status $sshStatus -Tool 'OpenSSH Server' -State "$($ssh[0].StartMode), $($ssh[0].State)" -FoundAs 'Windows' -Findings 'The OpenSSH server lets others sign in to a command line on this PC. Rare on a home PC.' -FixKind 'Product' -ServiceNames 'sshd'))
    }

    $sortedRows = @($rows | Sort-Object -Property @{ Expression = { Get-StatusRank $_.Status } }, Tool)
    $alwaysOn = @($sortedRows | Where-Object { $_.State -eq 'Always on' }).Count
    $summary = if ($toolCount -eq 0) {
        'No third-party remote access tools found.'
    }
    else {
        "$toolCount remote access tool(s) found; $alwaysOn can be reached without anyone at the keyboard."
    }
    [pscustomobject]@{
        Rows = $sortedRows
        Summary = $summary
        Errors = @($errors)
    }
}

function Invoke-ToolAction {
    param(
        [Parameter(Mandatory)][string]$Action,
        [object[]]$Items,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ProgressState,
        [bool]$IsElevated
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $done = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($Items | Where-Object { $_.FixKind })) {
        $ProgressState.Stage = "Turning off $($item.Tool)..."
        try {
            switch ($item.FixKind) {
                'Product' {
                    foreach ($serviceName in @($item.ServiceNames -split ';' | Where-Object { $_ })) {
                        Set-Service -Name $serviceName -StartupType Disabled -ErrorAction Stop
                        Stop-Service -Name $serviceName -Force -ErrorAction Stop
                    }
                    $patterns = @($item.ProcessPatterns -split ';' | Where-Object { $_ })
                    if ($patterns.Count -gt 0) {
                        Get-Process -ErrorAction SilentlyContinue |
                            Where-Object { Test-WildcardMatch -Text $_.ProcessName -Patterns $patterns } |
                            Stop-Process -Force -ErrorAction Stop
                    }
                }
                'Rdp' {
                    Set-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 1 -Type DWord -ErrorAction Stop
                }
                'RemoteAssistance' {
                    Set-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance' -Name 'fAllowToGetHelp' -Value 0 -Type DWord -ErrorAction Stop
                }
            }
            $done.Add($item.Tool)
        }
        catch {
            $errors.Add("$($item.Tool): $($_.Exception.Message)")
        }
    }

    $message = if ($done.Count -gt 0) {
        "Turned off: $($done -join ', ').`r`n`r`nServices are disabled, not removed. Uninstall programs you do not need from Settings > Apps, and delete downloaded copies."
    }
    else {
        'Nothing was changed.'
    }
    [pscustomobject]@{
        Message = $message
        Errors = @($errors)
    }
}

$script:toolDefinition = @{
    Title = 'Remote Access Detector'
    Subtitle = 'Find remote control tools (AnyDesk, TeamViewer, ScreenConnect and others) that are running, installed or downloaded, plus Windows remote access settings.'
    ScanButtonText = 'Scan again'
    ExportName = 'remote-access-report.csv'
    RequiresAdmin = $false
    IssueFilter = $true
    IssueFilterDefault = $false
    WorkerFunctions = @('Get-ToolReport', 'Invoke-ToolAction', 'Get-RemoteToolSignatures', 'Test-WildcardMatch', 'Get-ConnectionLogSummary', 'Get-DownloadsFolder', 'New-RemoteRow')
    Columns = @(
        @{ Header = 'STATUS'; Property = 'Status'; Weight = 8; Align = 'Center' }
        @{ Header = 'TOOL'; Property = 'Tool'; Weight = 20 }
        @{ Header = 'STATE'; Property = 'State'; Weight = 9 }
        @{ Header = 'FOUND AS'; Property = 'FoundAs'; Weight = 14 }
        @{ Header = 'FINDINGS'; Property = 'Findings'; Weight = 32 }
        @{ Header = 'LOCATION'; Property = 'Location'; Weight = 17; Muted = $true }
    )
    Actions = @(
        @{
            Text = 'Turn off selected'
            Name = 'TurnOff'
            Kind = 'Worker'
            RequiresSelection = $true
            RequiresAdmin = $true
            Confirm = {
                param($Rows)
                $fixable = @($Rows | Where-Object { $_.FixKind })
                if ($fixable.Count -eq 0) {
                    return 'None of the selected rows can be turned off here. Continue anyway?'
                }
                "Turn off $(($fixable | ForEach-Object { $_.Tool }) -join ', ')?`r`n`r`nRunning copies are closed and their services disabled so they cannot be reached remotely. Programs are not uninstalled."
            }
        }
        @{
            Text = 'Open location'
            Kind = 'Ui'
            RequiresSelection = $true
            Handler = {
                param($Rows)
                $path = [string]$Rows[0].Location
                if (-not $path -or $path -eq '-') {
                    throw 'No file location is known for this row.'
                }
                if (Test-Path -LiteralPath $path -PathType Container) {
                    Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$path`""
                }
                else {
                    Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$path`""
                }
            }
        }
        @{
            Text = 'Uninstall programs'
            Kind = 'Ui'
            Handler = {
                param($Rows)
                Start-Process -FilePath 'ms-settings:appsfeatures'
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
