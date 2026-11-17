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

function New-HijackRow {
    param(
        [string]$Status,
        [string]$Area,
        [string]$Item,
        [string]$Finding,
        [string]$Value = '',
        [string]$FixKind = '',
        [string]$Target = '',
        [string]$TargetName = '',
        [bool]$TargetIsKey = $false,
        [int]$InterfaceIndex = 0
    )

    [pscustomobject]@{
        Status = $Status
        Area = $Area
        Item = $Item
        Finding = $Finding
        Value = if ($Value) { $Value } else { '-' }
        CanFix = if ($FixKind) { 'Yes' } else { '' }
        FixKind = $FixKind
        Target = $Target
        TargetName = $TargetName
        TargetIsKey = $TargetIsKey
        InterfaceIndex = $InterfaceIndex
        Order = 0
    }
}

function Read-SharedText {
    param([Parameter(Mandatory)][string]$Path)

    # Browsers keep their files open while running, so read with full sharing.
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    try {
        $reader = [System.IO.StreamReader]::new($stream, $true)
        try {
            $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function ConvertFrom-JsonToDictionary {
    param([Parameter(Mandatory)][string]$Json)

    # Chromium preference files contain empty property names, which ConvertFrom-Json in PowerShell 5.1 rejects.
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        return ($Json | ConvertFrom-Json -AsHashtable -ErrorAction Stop)
    }
    Add-Type -AssemblyName System.Web.Extensions
    $serializer = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
    $serializer.MaxJsonLength = [int]::MaxValue
    $serializer.RecursionLimit = 1000
    , $serializer.DeserializeObject($Json)
}

function Get-DictionaryValue {
    param($Dictionary, [string[]]$Path)

    $current = $Dictionary
    $containsMethod = [System.Collections.IDictionary].GetMethod('Contains')
    foreach ($part in $Path) {
        if ($current -is [System.Collections.IDictionary] -and $containsMethod.Invoke($current, @($part))) {
            $current = $current[$part]
        }
        else {
            return $null
        }
    }
    , $current
}

function Get-UrlHost {
    param([AllowNull()][string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return ''
    }
    $text = $Url.Trim() -replace '^\{google:baseURL\}', 'https://www.google.com/'
    if ($text -notmatch '^[a-z][a-z0-9+.-]*://') {
        $text = 'http://' + $text
    }
    try {
        ([Uri]$text).Host.ToLowerInvariant()
    }
    catch {
        ''
    }
}

function Test-KnownSearchHost {
    param([string]$HostName)

    if (-not $HostName) {
        return $true
    }
    $HostName -match '(^|\.)(google|bing|duckduckgo|yahoo|ecosia|startpage|brave|yandex|baidu|qwant|naver|seznam|ask|aol|mojeek|swisscows|you|perplexity|kagi|presearch|metager|ecosia|kvasir)\.[a-z.]+$'
}

function Test-PrivateAddress {
    param([string]$Address)

    $Address -match '^(10\.|127\.|169\.254\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)'
}

function Get-KnownResolverName {
    param([string]$Address)

    $known = @{
        '8.8.8.8' = 'Google'; '8.8.4.4' = 'Google'
        '1.1.1.1' = 'Cloudflare'; '1.0.0.1' = 'Cloudflare'; '1.1.1.2' = 'Cloudflare (malware filter)'; '1.0.0.2' = 'Cloudflare (malware filter)'; '1.1.1.3' = 'Cloudflare (family)'; '1.0.0.3' = 'Cloudflare (family)'
        '9.9.9.9' = 'Quad9'; '149.112.112.112' = 'Quad9'; '9.9.9.11' = 'Quad9'; '149.112.112.11' = 'Quad9'
        '208.67.222.222' = 'OpenDNS'; '208.67.220.220' = 'OpenDNS'; '208.67.222.123' = 'OpenDNS FamilyShield'; '208.67.220.123' = 'OpenDNS FamilyShield'
        '94.140.14.14' = 'AdGuard'; '94.140.15.15' = 'AdGuard'; '94.140.14.15' = 'AdGuard (family)'; '94.140.15.16' = 'AdGuard (family)'
        '185.228.168.9' = 'CleanBrowsing'; '185.228.169.9' = 'CleanBrowsing'
    }
    if ($known.ContainsKey($Address)) {
        return $known[$Address]
    }
    if ($Address -match '^45\.90\.(28|30)\.') {
        return 'NextDNS'
    }
    if (Test-PrivateAddress -Address $Address) {
        return 'Local network (usually the router)'
    }
    ''
}

function Get-BrowserPolicyRows {
    param([System.Collections.Generic.List[string]]$Errors)

    $rows = [System.Collections.Generic.List[object]]::new()
    $browsers = @(
        @{ Name = 'Chrome'; SubPath = 'Google\Chrome' },
        @{ Name = 'Edge'; SubPath = 'Microsoft\Edge' },
        @{ Name = 'Brave'; SubPath = 'BraveSoftware\Brave' },
        @{ Name = 'Firefox'; SubPath = 'Mozilla\Firefox' }
    )
    # SOFTWARE\Policies is shared between the 32-bit and 64-bit registry views, so it is read once.
    $roots = @('HKLM:\SOFTWARE\Policies', 'HKCU:\SOFTWARE\Policies')
    $forceInstall = @('ExtensionInstallForcelist', 'ExtensionSettings', 'Extensions', 'ExtensionInstallSources')
    $hijackPolicies = @(
        'DefaultSearchProviderEnabled', 'DefaultSearchProviderSearchURL', 'DefaultSearchProviderName', 'DefaultSearchProviderKeyword',
        'DefaultSearchProviderSuggestURL', 'HomepageLocation', 'HomepageIsNewTabPage', 'RestoreOnStartup', 'RestoreOnStartupURLs',
        'NewTabPageLocation', 'ProxyMode', 'ProxyServer', 'ProxyPacUrl', 'ProxySettings', 'DnsOverHttpsTemplates', 'SearchEngines', 'Homepage',
        'DisableDeveloperTools', 'DeveloperToolsAvailability', 'BrowserSignin', 'ManagedSearchEngines'
    )

    foreach ($browser in $browsers) {
        foreach ($root in $roots) {
            $path = Join-Path $root $browser.SubPath
            if (-not (Test-Path -LiteralPath $path)) {
                continue
            }
            $scope = if ($root -like 'HKCU:*') { 'current user' } else { 'all users' }
            try {
                $key = Get-Item -LiteralPath $path -ErrorAction Stop
                foreach ($valueName in $key.GetValueNames()) {
                    if ([string]::IsNullOrEmpty($valueName)) {
                        continue
                    }
                    $value = [string]$key.GetValue($valueName)
                    $status = 'Info'
                    $finding = "Policy set for $scope. Unusual on a personal PC unless you or a program you trust set it."
                    if ($forceInstall -contains $valueName) {
                        $status = 'Critical'
                        $finding = 'Forces extension settings. Adware uses this to install extensions you cannot remove.'
                    }
                    elseif ($hijackPolicies -contains $valueName) {
                        $status = 'Warning'
                        $finding = "Locks a setting that browser hijackers commonly change ($scope)."
                    }
                    $rows.Add((New-HijackRow -Status $status -Area 'Browser policy' -Item "$($browser.Name): $valueName" -Finding $finding -Value $value -FixKind 'Policy' -Target $path -TargetName $valueName))
                }
                foreach ($subKeyName in $key.GetSubKeyNames()) {
                    $subKey = $key.OpenSubKey($subKeyName)
                    $values = @()
                    if ($subKey) {
                        try {
                            $values = @($subKey.GetValueNames() | ForEach-Object { [string]$subKey.GetValue($_) } | Where-Object { $_ })
                        }
                        finally {
                            $subKey.Dispose()
                        }
                    }
                    $status = 'Info'
                    $finding = "Policy list set for $scope."
                    if ($forceInstall -contains $subKeyName) {
                        $status = 'Critical'
                        $finding = "Force-installs $($values.Count) extension(s). This is the classic sign of an adware extension on a personal PC."
                    }
                    elseif ($hijackPolicies -contains $subKeyName) {
                        $status = 'Warning'
                        $finding = "Locks a setting that browser hijackers commonly change ($scope)."
                    }
                    $rows.Add((New-HijackRow -Status $status -Area 'Browser policy' -Item "$($browser.Name): $subKeyName" -Finding $finding -Value ($values -join '; ') -FixKind 'Policy' -Target $path -TargetName $subKeyName -TargetIsKey $true))
                }
                $key.Dispose()
            }
            catch {
                $Errors.Add("Policies at ${path}: $($_.Exception.Message)")
            }
        }
    }

    foreach ($programFolder in @($env:ProgramFiles, [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')) | Where-Object { $_ }) {
        $policyFile = Join-Path $programFolder 'Mozilla Firefox\distribution\policies.json'
        if (Test-Path -LiteralPath $policyFile) {
            $names = ''
            try {
                $parsed = ConvertFrom-JsonToDictionary -Json (Read-SharedText -Path $policyFile)
                $policies = Get-DictionaryValue -Dictionary $parsed -Path @('policies')
                if ($policies -is [System.Collections.IDictionary]) {
                    $names = (@($policies.Keys) -join ', ')
                }
            }
            catch {
                $names = 'Could not be read'
            }
            $status = if ($names -match 'Extensions|ExtensionSettings|SearchEngines|Homepage|Proxy') { 'Warning' } else { 'Info' }
            $rows.Add((New-HijackRow -Status $status -Area 'Browser policy' -Item 'Firefox: policies.json' -Finding "Firefox policy file found at $policyFile." -Value $names))
        }
    }

    if ($rows.Count -eq 0) {
        $rows.Add((New-HijackRow -Status 'OK' -Area 'Browser policy' -Item 'Chrome, Edge, Brave, Firefox' -Finding 'No browser policies found. This is normal for a personal PC.'))
    }
    , $rows
}

function Get-ChromiumProfileRows {
    param([System.Collections.Generic.List[string]]$Errors)

    $rows = [System.Collections.Generic.List[object]]::new()
    $browsers = @(
        @{ Name = 'Chrome'; Data = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data' },
        @{ Name = 'Edge'; Data = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data' },
        @{ Name = 'Brave'; Data = Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data' },
        @{ Name = 'Vivaldi'; Data = Join-Path $env:LOCALAPPDATA 'Vivaldi\User Data' }
    )

    foreach ($browser in $browsers) {
        if (-not (Test-Path -LiteralPath $browser.Data)) {
            continue
        }
        $profileNames = @{}
        $localState = Join-Path $browser.Data 'Local State'
        if (Test-Path -LiteralPath $localState) {
            try {
                $state = ConvertFrom-JsonToDictionary -Json (Read-SharedText -Path $localState)
                $cache = Get-DictionaryValue -Dictionary $state -Path @('profile', 'info_cache')
                if ($cache -is [System.Collections.IDictionary]) {
                    foreach ($directory in $cache.Keys) {
                        $profileNames[$directory] = [string](Get-DictionaryValue -Dictionary $cache[$directory] -Path @('name'))
                    }
                }
            }
            catch {
                $Errors.Add("$($browser.Name) Local State: $($_.Exception.Message)")
            }
        }

        $profiles = @(Get-ChildItem -LiteralPath $browser.Data -Directory -ErrorAction SilentlyContinue |
            Where-Object { ($_.Name -eq 'Default' -or $_.Name -like 'Profile *') -and (Test-Path -LiteralPath (Join-Path $_.FullName 'Preferences')) })
        foreach ($profileFolder in $profiles) {
            $label = $browser.Name
            if ($profiles.Count -gt 1 -or $profileFolder.Name -ne 'Default') {
                $friendly = $profileNames[$profileFolder.Name]
                $label = "$($browser.Name) ($(if ($friendly) { $friendly } else { $profileFolder.Name }))"
            }
            try {
                $preferences = ConvertFrom-JsonToDictionary -Json (Read-SharedText -Path (Join-Path $profileFolder.FullName 'Preferences'))
            }
            catch {
                $Errors.Add("$label preferences: $($_.Exception.Message)")
                continue
            }

            $searchUrl = [string](Get-DictionaryValue -Dictionary $preferences -Path @('default_search_provider_data', 'template_url_data', 'url'))
            $searchName = [string](Get-DictionaryValue -Dictionary $preferences -Path @('default_search_provider_data', 'template_url_data', 'short_name'))
            if (-not $searchUrl) {
                $rows.Add((New-HijackRow -Status 'OK' -Area 'Search engine' -Item $label -Finding "The browser's built-in default search engine is used."))
            }
            else {
                $searchHost = Get-UrlHost -Url $searchUrl
                if (Test-KnownSearchHost -HostName $searchHost) {
                    $rows.Add((New-HijackRow -Status 'OK' -Area 'Search engine' -Item $label -Finding "Search engine: $(if ($searchName) { $searchName } else { $searchHost })." -Value $searchUrl))
                }
                else {
                    $rows.Add((New-HijackRow -Status 'Warning' -Area 'Search engine' -Item $label -Finding "Unfamiliar search engine ($searchHost). Hijackers swap the search engine to show their own ads; change it in the browser's search settings if you did not choose it." -Value $searchUrl))
                }
            }

            $restore = Get-DictionaryValue -Dictionary $preferences -Path @('session', 'restore_on_startup')
            $startupUrls = @(Get-DictionaryValue -Dictionary $preferences -Path @('session', 'startup_urls') | Where-Object { $_ })
            $homepage = [string](Get-DictionaryValue -Dictionary $preferences -Path @('homepage'))
            $homepageIsNewTab = Get-DictionaryValue -Dictionary $preferences -Path @('homepage_is_newtabpage')
            $pages = [System.Collections.Generic.List[string]]::new()
            if ([string]$restore -eq '4') {
                foreach ($url in $startupUrls) { $pages.Add([string]$url) }
            }
            if ($homepage -and $homepageIsNewTab -ne $true) {
                $pages.Add("Home: $homepage")
            }
            if ($pages.Count -eq 0) {
                $rows.Add((New-HijackRow -Status 'OK' -Area 'Start pages' -Item $label -Finding 'Opens the new tab page or the previous session.'))
            }
            else {
                $suspicious = @($pages | Where-Object { $_ -match '(?i)search|find|query|results' -and -not (Test-KnownSearchHost -HostName (Get-UrlHost -Url ($_ -replace '^Home: ', ''))) })
                $status = if ($suspicious.Count -gt 0) { 'Warning' } else { 'Info' }
                $finding = if ($suspicious.Count -gt 0) { 'Opens a search-style page that is not a known search engine; typical for a hijacker.' } else { 'Opens specific pages at start. Fine if you chose them.' }
                $rows.Add((New-HijackRow -Status $status -Area 'Start pages' -Item $label -Finding $finding -Value ($pages -join '; ')))
            }
        }
    }
    , $rows
}

function Get-FirefoxProfileRows {
    $rows = [System.Collections.Generic.List[object]]::new()
    $profileRoot = Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles'
    if (-not (Test-Path -LiteralPath $profileRoot)) {
        return , $rows
    }
    foreach ($profileFolder in Get-ChildItem -LiteralPath $profileRoot -Directory -ErrorAction SilentlyContinue) {
        $prefsPath = Join-Path $profileFolder.FullName 'prefs.js'
        if (-not (Test-Path -LiteralPath $prefsPath)) {
            continue
        }
        $label = "Firefox ($($profileFolder.Name -replace '^[a-z0-9]+\.', ''))"
        $homepage = ''
        try {
            $match = [regex]::Match((Read-SharedText -Path $prefsPath), 'user_pref\("browser\.startup\.homepage",\s*"([^"]*)"\)')
            if ($match.Success) {
                $homepage = $match.Groups[1].Value
            }
        }
        catch {
            $homepage = ''
        }
        if ($homepage -and $homepage -notmatch '^(about:|chrome:|moz-extension:)') {
            $rows.Add((New-HijackRow -Status 'Info' -Area 'Start pages' -Item $label -Finding 'Custom home page. Fine if you chose it.' -Value $homepage))
        }
        else {
            $rows.Add((New-HijackRow -Status 'OK' -Area 'Start pages' -Item $label -Finding 'Uses the default Firefox home page.'))
        }
        $userJs = Join-Path $profileFolder.FullName 'user.js'
        if (Test-Path -LiteralPath $userJs) {
            $rows.Add((New-HijackRow -Status 'Info' -Area 'Start pages' -Item $label -Finding 'A user.js file re-applies settings every time Firefox starts. Privacy tweak packs use it, and so do some hijackers.' -Value $userJs))
        }
    }
    , $rows
}

function Get-ProxyRows {
    $rows = [System.Collections.Generic.List[object]]::new()
    $settingsPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $proxyEnable = Get-RegistryValueSafe -Path $settingsPath -Name 'ProxyEnable'
    $proxyServer = [string](Get-RegistryValueSafe -Path $settingsPath -Name 'ProxyServer')
    $pacUrl = [string](Get-RegistryValueSafe -Path $settingsPath -Name 'AutoConfigURL')

    if ([int]$proxyEnable -eq 1 -and $proxyServer) {
        $rows.Add((New-HijackRow -Status 'Warning' -Area 'Proxy' -Item 'Manual proxy (current user)' -Finding 'All web traffic is sent through a proxy server. Rare on a home PC; malware uses it to watch or alter traffic.' -Value $proxyServer -FixKind 'ProxyServer'))
    }
    if ($pacUrl) {
        $rows.Add((New-HijackRow -Status 'Warning' -Area 'Proxy' -Item 'Proxy script (current user)' -Finding 'A proxy auto-config script decides where web traffic goes. Rare on a home PC; a known hijacking trick.' -Value $pacUrl -FixKind 'ProxyScript'))
    }
    if ($rows.Count -eq 0) {
        $rows.Add((New-HijackRow -Status 'OK' -Area 'Proxy' -Item 'Windows proxy (current user)' -Finding 'No proxy server or proxy script is set.'))
    }

    # WinHTTP proxy (used by Windows services); the registry value is a binary structure with flags at offset 8.
    $winHttp = Get-RegistryValueSafe -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Connections' -Name 'WinHttpSettings'
    $winHttpProxy = ''
    if ($winHttp -is [byte[]] -and $winHttp.Length -ge 16 -and ($winHttp[8] -band 2)) {
        $length = [BitConverter]::ToInt32($winHttp, 12)
        if ($length -gt 0 -and $winHttp.Length -ge 16 + $length) {
            $winHttpProxy = [System.Text.Encoding]::ASCII.GetString($winHttp, 16, $length)
        }
        else {
            $winHttpProxy = '(set)'
        }
    }
    if ($winHttpProxy) {
        $rows.Add((New-HijackRow -Status 'Warning' -Area 'Proxy' -Item 'WinHTTP proxy (system)' -Finding 'Windows services are sent through a proxy server. Rare on a home PC.' -Value $winHttpProxy -FixKind 'WinHttpProxy'))
    }
    else {
        $rows.Add((New-HijackRow -Status 'OK' -Area 'Proxy' -Item 'WinHTTP proxy (system)' -Finding 'Direct connection (no system proxy).'))
    }
    , $rows
}

function Get-HostsFileRows {
    param([System.Collections.Generic.List[string]]$Errors)

    $rows = [System.Collections.Generic.List[object]]::new()
    $defaultDirectory = Join-Path $env:SystemRoot 'System32\drivers\etc'
    $configuredDirectory = [Environment]::ExpandEnvironmentVariables([string](Get-RegistryValueSafe -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name 'DataBasePath'))
    if ($configuredDirectory -and $configuredDirectory.TrimEnd('\') -ne $defaultDirectory.TrimEnd('\')) {
        $rows.Add((New-HijackRow -Status 'Critical' -Area 'Hosts file' -Item 'Hosts file location' -Finding 'Windows has been pointed at a different hosts file folder. Malware does this to hide its redirects.' -Value $configuredDirectory))
    }
    $hostsPath = Join-Path $(if ($configuredDirectory) { $configuredDirectory } else { $defaultDirectory }) 'hosts'
    if (-not (Test-Path -LiteralPath $hostsPath)) {
        $rows.Add((New-HijackRow -Status 'OK' -Area 'Hosts file' -Item 'hosts' -Finding 'No hosts file; nothing is redirected.' -Value $hostsPath))
        return , $rows
    }

    try {
        $lines = (Read-SharedText -Path $hostsPath) -split "`r?`n"
    }
    catch {
        $Errors.Add("Hosts file: $($_.Exception.Message)")
        return , $rows
    }

    $popular = '(?i)(^|\.)(google|gstatic|googleapis|youtube|bing|microsoft|live|outlook|office|office365|windowsupdate|windows|facebook|instagram|paypal|apple|icloud|amazon|yahoo|twitter|netflix|ebay|whatsapp|github|dropbox|steampowered|steamcommunity|discord|bankid|vipps)\.[a-z.]+$'
    $security = '(?i)(windowsupdate|update\.microsoft|avast|avg|kaspersky|malwarebytes|eset|norton|symantec|mcafee|bitdefender|sophos|trendmicro|f-secure|virustotal|avira|webroot|emsisoft|hitmanpro|adwcleaner|gdata|spybot|superantispyware|bleepingcomputer|defender|wdcp|smartscreen)'
    $telemetry = '(?i)(telemetry|vortex|watson|diagnostic|data\.microsoft\.com|events\.data|settings-win)'
    $blockCount = 0
    $redirectCount = 0
    $flagged = 0
    foreach ($line in $lines) {
        $text = ($line -replace '#.*$', '').Trim()
        if (-not $text) {
            continue
        }
        $parts = @($text -split '\s+')
        if ($parts.Count -lt 2) {
            continue
        }
        $address = $parts[0]
        foreach ($hostName in $parts[1..($parts.Count - 1)]) {
            if ($hostName -eq 'localhost' -or $hostName -eq 'localhost.localdomain') {
                continue
            }
            $isBlock = $address -match '^(0\.0\.0\.0|127\.\d+\.\d+\.\d+|::1?|::)$'
            if ($isBlock) {
                $blockCount++
                if ($hostName -match $security -and $hostName -notmatch $telemetry) {
                    $flagged++
                    if ($flagged -le 40) {
                        $rows.Add((New-HijackRow -Status 'Warning' -Area 'Hosts file' -Item $hostName -Finding 'Blocked in the hosts file. Malware blocks security and update sites so it cannot be removed.' -Value "$address $hostName"))
                    }
                }
            }
            else {
                $redirectCount++
                if ($hostName -match $popular) {
                    $flagged++
                    if ($flagged -le 40) {
                        $rows.Add((New-HijackRow -Status 'Critical' -Area 'Hosts file' -Item $hostName -Finding 'A well-known site is redirected to another server. This is how fake login pages are served.' -Value "$address $hostName"))
                    }
                }
            }
        }
    }

    $total = $blockCount + $redirectCount
    if ($total -eq 0) {
        $rows.Add((New-HijackRow -Status 'OK' -Area 'Hosts file' -Item 'hosts' -Finding 'The hosts file has no active entries.' -Value $hostsPath))
    }
    else {
        $rows.Add((New-HijackRow -Status 'Info' -Area 'Hosts file' -Item 'hosts' -Finding "$total active entr$(if ($total -eq 1) { 'y' } else { 'ies' }): $blockCount blocking, $redirectCount redirecting. Ad blockers and some programs add entries; flagged ones are listed separately." -Value $hostsPath))
    }
    , $rows
}

function Get-DnsRows {
    param([System.Collections.Generic.List[string]]$Errors)

    $rows = [System.Collections.Generic.List[object]]::new()
    try {
        $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })
    }
    catch {
        $Errors.Add("Network adapters: $($_.Exception.Message)")
        return , $rows
    }
    foreach ($adapter in $adapters) {
        $servers = @()
        try {
            $servers = @((Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses | Where-Object { $_ })
        }
        catch {
            $Errors.Add("DNS for $($adapter.Name): $($_.Exception.Message)")
            continue
        }
        if ($servers.Count -eq 0) {
            continue
        }
        $interfaceKey = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($adapter.InterfaceGuid)"
        $isStatic = [bool]([string](Get-RegistryValueSafe -Path $interfaceKey -Name 'NameServer')).Trim()
        $labels = @($servers | ForEach-Object { $name = Get-KnownResolverName -Address $_; if ($name) { "$_ ($name)" } else { $_ } })
        $unknown = @($servers | Where-Object { -not (Get-KnownResolverName -Address $_) })
        $isVirtual = $adapter.InterfaceDescription -match '(?i)Hyper-V|VirtualBox|VMware|TAP-|WireGuard|Cisco|AnyConnect|Fortinet|OpenVPN|Tailscale|ZeroTier|VPN|Wintun'
        $item = "$($adapter.Name)"
        if (-not $isStatic) {
            $rows.Add((New-HijackRow -Status 'OK' -Area 'DNS' -Item $item -Finding 'DNS servers come from the network (router or provider) automatically.' -Value ($labels -join ', ')))
        }
        elseif ($unknown.Count -eq 0) {
            $rows.Add((New-HijackRow -Status 'Info' -Area 'DNS' -Item $item -Finding 'DNS servers are set manually to well-known providers.' -Value ($labels -join ', ') -FixKind 'Dns' -InterfaceIndex $adapter.ifIndex))
        }
        elseif ($isVirtual) {
            $rows.Add((New-HijackRow -Status 'Info' -Area 'DNS' -Item $item -Finding 'A VPN or virtual adapter has its own DNS servers; normal for that software.' -Value ($labels -join ', ')))
        }
        else {
            $rows.Add((New-HijackRow -Status 'Warning' -Area 'DNS' -Item $item -Finding 'DNS servers are set manually to unfamiliar addresses. DNS hijackers do this to send you to fake sites. Reset unless you set them yourself.' -Value ($labels -join ', ') -FixKind 'Dns' -InterfaceIndex $adapter.ifIndex))
        }
    }
    , $rows
}

function Get-ShortcutRows {
    param([System.Collections.Generic.List[string]]$Errors)

    $rows = [System.Collections.Generic.List[object]]::new()
    $browserExecutables = @('chrome.exe', 'msedge.exe', 'firefox.exe', 'brave.exe', 'opera.exe', 'vivaldi.exe', 'iexplore.exe', 'launcher.exe')
    $browserNamePattern = '(?i)chrome|edge|firefox|brave|opera|vivaldi|internet explorer'
    $locations = @(
        @{ Path = [Environment]::GetFolderPath('Desktop'); Recurse = $false },
        @{ Path = [Environment]::GetFolderPath('CommonDesktopDirectory'); Recurse = $false },
        @{ Path = [Environment]::GetFolderPath('Programs'); Recurse = $true },
        @{ Path = [Environment]::GetFolderPath('CommonPrograms'); Recurse = $true },
        @{ Path = (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'); Recurse = $false }
    )
    $shell = $null
    $checked = 0
    try {
        $shell = New-Object -ComObject WScript.Shell
        foreach ($location in $locations) {
            if (-not $location.Path -or -not (Test-Path -LiteralPath $location.Path)) {
                continue
            }
            $files = @(Get-ChildItem -LiteralPath $location.Path -Filter '*.lnk' -File -Recurse:$location.Recurse -ErrorAction SilentlyContinue)
            foreach ($file in $files) {
                try {
                    $shortcut = $shell.CreateShortcut($file.FullName)
                    $target = [string]$shortcut.TargetPath
                    $arguments = [string]$shortcut.Arguments
                    $targetName = [System.IO.Path]::GetFileName($target).ToLowerInvariant()
                    $isBrowserTarget = $browserExecutables -contains $targetName
                    $looksLikeBrowser = $file.BaseName -match $browserNamePattern
                    if (-not $isBrowserTarget -and -not $looksLikeBrowser) {
                        continue
                    }
                    if ($targetName -eq 'launcher.exe' -and $target -notmatch '(?i)opera') {
                        continue
                    }
                    $checked++
                    if ($looksLikeBrowser -and -not $isBrowserTarget -and $target -and $targetName -match '\.(bat|cmd|vbs|js|ps1|hta|wsf)$|^(cmd|powershell|wscript|cscript|mshta|rundll32)\.exe$') {
                        $rows.Add((New-HijackRow -Status 'Critical' -Area 'Shortcut' -Item $file.Name -Finding 'A browser shortcut runs a script instead of the browser.' -Value "$target $arguments".Trim()))
                    }
                    elseif ($arguments -notmatch '(?i)--app-id=|--app=' -and $arguments -match '(?i)https?://|www\.|\.(com|net|org|info|xyz|top)\b') {
                        $rows.Add((New-HijackRow -Status 'Warning' -Area 'Shortcut' -Item $file.Name -Finding 'The browser shortcut opens a web page every time. A common hijacker trick.' -Value $arguments -FixKind 'Shortcut' -Target $file.FullName))
                    }
                }
                catch {
                    $Errors.Add("Shortcut $($file.FullName): $($_.Exception.Message)")
                }
            }
        }
    }
    catch {
        $Errors.Add("Shortcuts: $($_.Exception.Message)")
    }
    finally {
        if ($shell) {
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        }
    }
    if ($rows.Count -eq 0) {
        $rows.Add((New-HijackRow -Status 'OK' -Area 'Shortcut' -Item 'Browser shortcuts' -Finding "$checked browser shortcut(s) checked; none open extra pages or run scripts."))
    }
    , $rows
}

function Get-DefaultBrowserRow {
    $progId = [string](Get-RegistryValueSafe -Path 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice' -Name 'ProgId')
    $name = switch -Wildcard ($progId) {
        'ChromeHTML*' { 'Google Chrome' }
        'MSEdgeHTM*' { 'Microsoft Edge' }
        'FirefoxURL*' { 'Mozilla Firefox' }
        'BraveHTML*' { 'Brave' }
        'Opera*' { 'Opera' }
        'VivaldiHTM*' { 'Vivaldi' }
        '' { 'Not set (Windows default)' }
        default { $progId }
    }
    $status = if ($progId -and $name -eq $progId) { 'Info' } else { 'OK' }
    $finding = if ($status -eq 'Info') { 'Web links open with an unfamiliar program. Fine if you installed it as your browser.' } else { 'Web links open with this browser.' }
    New-HijackRow -Status $status -Area 'Default browser' -Item 'Web links (https)' -Finding $finding -Value $name
}

function Get-ToolReport {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$ProgressState,
        [bool]$IsElevated
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $rows = [System.Collections.Generic.List[object]]::new()
    $steps = @(
        @{ Stage = 'Checking browser policies...'; Block = { Get-BrowserPolicyRows -Errors $errors } },
        @{ Stage = 'Reading browser settings...'; Block = { Get-ChromiumProfileRows -Errors $errors } },
        @{ Stage = 'Reading Firefox settings...'; Block = { Get-FirefoxProfileRows } },
        @{ Stage = 'Checking proxy settings...'; Block = { Get-ProxyRows } },
        @{ Stage = 'Checking the hosts file...'; Block = { Get-HostsFileRows -Errors $errors } },
        @{ Stage = 'Checking DNS servers...'; Block = { Get-DnsRows -Errors $errors } },
        @{ Stage = 'Checking browser shortcuts...'; Block = { Get-ShortcutRows -Errors $errors } },
        @{ Stage = 'Checking the default browser...'; Block = { Get-DefaultBrowserRow } }
    )
    foreach ($step in $steps) {
        $ProgressState.Stage = $step.Stage
        try {
            foreach ($result in @(& $step.Block)) {
                foreach ($row in @($result)) {
                    if ($row) {
                        $row.Order = $rows.Count
                        $rows.Add($row)
                    }
                }
            }
        }
        catch {
            $errors.Add("$($step.Stage.TrimEnd('.')): $($_.Exception.Message)")
        }
    }

    $sortedRows = @($rows | Sort-Object -Property @{ Expression = { Get-StatusRank $_.Status } }, Order)
    $criticalCount = @($sortedRows | Where-Object { $_.Status -eq 'Critical' }).Count
    $warningCount = @($sortedRows | Where-Object { $_.Status -eq 'Warning' }).Count
    $summary = if ($criticalCount + $warningCount -eq 0) {
        'No signs of browser hijacking found.'
    }
    else {
        "$criticalCount critical and $warningCount warning finding(s). Select rows marked 'Yes' under FIX and click 'Fix selected'."
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
    $fixed = 0
    $backups = [System.Collections.Generic.List[string]]::new()
    $backupDirectory = Join-Path $env:LOCALAPPDATA 'WinDiag\Backups'
    $fixable = @($Items | Where-Object { $_.FixKind })
    if ($fixable.Count -eq 0) {
        return [pscustomobject]@{ Message = 'None of the selected rows can be fixed automatically.'; Errors = @(); Rescan = $false }
    }

    foreach ($item in $fixable) {
        $ProgressState.Stage = "Fixing $($item.Item)..."
        try {
            switch ($item.FixKind) {
                'Policy' {
                    if (-not $IsElevated) {
                        # Windows only lets administrators change policy keys, including the per-user ones.
                        throw 'needs administrator rights. Use Relaunch as admin.'
                    }
                    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
                    $safeName = ($item.Item -replace '[^A-Za-z0-9_-]+', '_').Trim('_')
                    $backupFile = Join-Path $backupDirectory ('policy-{0:yyyyMMdd-HHmmss}-{1}.reg' -f (Get-Date), $safeName)
                    $registryPath = $item.Target -replace '^HKLM:\\', 'HKLM\' -replace '^HKCU:\\', 'HKCU\'
                    $null = & reg.exe export $registryPath $backupFile /y 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        throw 'could not back up the policy key first, so nothing was changed.'
                    }
                    if (-not $backups.Contains($backupFile)) { $backups.Add($backupFile) }
                    if ($item.TargetIsKey) {
                        Remove-Item -LiteralPath (Join-Path $item.Target $item.TargetName) -Recurse -Force -ErrorAction Stop
                    }
                    else {
                        Remove-ItemProperty -LiteralPath $item.Target -Name $item.TargetName -Force -ErrorAction Stop
                    }
                    $remaining = Get-Item -LiteralPath $item.Target -ErrorAction SilentlyContinue
                    if ($remaining -and $remaining.ValueCount -eq 0 -and $remaining.SubKeyCount -eq 0) {
                        Remove-Item -LiteralPath $item.Target -Force -ErrorAction SilentlyContinue
                    }
                }
                'ProxyServer' {
                    Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name 'ProxyEnable' -Value 0 -Type DWord -ErrorAction Stop
                }
                'ProxyScript' {
                    Remove-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name 'AutoConfigURL' -ErrorAction Stop
                }
                'WinHttpProxy' {
                    if (-not $IsElevated) {
                        throw 'needs administrator rights. Use Relaunch as admin.'
                    }
                    $output = & netsh.exe winhttp reset proxy 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        throw ($output -join ' ')
                    }
                }
                'Dns' {
                    if (-not $IsElevated) {
                        throw 'needs administrator rights. Use Relaunch as admin.'
                    }
                    Set-DnsClientServerAddress -InterfaceIndex $item.InterfaceIndex -ResetServerAddresses -ErrorAction Stop
                    Clear-DnsClientCache -ErrorAction SilentlyContinue
                }
                'Shortcut' {
                    $shell = New-Object -ComObject WScript.Shell
                    try {
                        $shortcut = $shell.CreateShortcut($item.Target)
                        $cleaned = ([string]$shortcut.Arguments -replace '(?i)"?(https?://|www\.)[^"\s]*"?', '' -replace '\s{2,}', ' ').Trim()
                        $shortcut.Arguments = $cleaned
                        $shortcut.Save()
                    }
                    catch [System.UnauthorizedAccessException] {
                        throw 'needs administrator rights (shared shortcut). Use Relaunch as admin.'
                    }
                    finally {
                        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
                    }
                }
                default {
                    throw 'no automatic fix.'
                }
            }
            $fixed++
        }
        catch {
            $errors.Add("$($item.Item): $($_.Exception.Message)")
        }
    }

    $message = "Fixed $fixed of $($fixable.Count) item(s). Restart the browser for changes to take effect."
    if ($backups.Count -gt 0) {
        $message += "`r`n`r`nRemoved policies were backed up first (double-click a file to restore it):`r`n" + ($backups -join "`r`n")
    }
    [pscustomobject]@{
        Message = $message
        Errors = @($errors)
    }
}

$script:toolDefinition = @{
    Title = 'Browser Hijack Check'
    Subtitle = 'Look for forced browser policies, changed search engines and start pages, proxies, hosts file redirects, DNS changes and tampered shortcuts.'
    ScanButtonText = 'Scan again'
    ExportName = 'browser-hijack-check.csv'
    RequiresAdmin = $false
    IssueFilter = $true
    IssueFilterDefault = $false
    WorkerFunctions = @(
        'Get-ToolReport', 'Invoke-ToolAction', 'New-HijackRow', 'Read-SharedText', 'ConvertFrom-JsonToDictionary', 'Get-DictionaryValue',
        'Get-UrlHost', 'Test-KnownSearchHost', 'Test-PrivateAddress', 'Get-KnownResolverName', 'Get-BrowserPolicyRows', 'Get-ChromiumProfileRows',
        'Get-FirefoxProfileRows', 'Get-ProxyRows', 'Get-HostsFileRows', 'Get-DnsRows', 'Get-ShortcutRows', 'Get-DefaultBrowserRow'
    )
    Columns = @(
        @{ Header = 'STATUS'; Property = 'Status'; Weight = 8; Align = 'Center' }
        @{ Header = 'AREA'; Property = 'Area'; Weight = 11 }
        @{ Header = 'ITEM'; Property = 'Item'; Weight = 18 }
        @{ Header = 'FINDING'; Property = 'Finding'; Weight = 36 }
        @{ Header = 'VALUE'; Property = 'Value'; Weight = 21; Muted = $true }
        @{ Header = 'FIX'; Property = 'CanFix'; Weight = 5; Align = 'Center' }
    )
    Actions = @(
        @{
            Text = 'Fix selected'
            Name = 'Fix'
            Kind = 'Worker'
            RequiresSelection = $true
            Confirm = {
                param($Rows)
                $fixable = @($Rows | Where-Object { $_.FixKind })
                if ($fixable.Count -eq 0) {
                    return 'None of the selected rows has an automatic fix. Continue anyway?'
                }
                $lines = ($fixable | Select-Object -First 10 | ForEach-Object { "  $($_.Area): $($_.Item)" }) -join "`r`n"
                "Fix these $($fixable.Count) item(s)?`r`n$lines`r`n`r`nPolicies are removed (backed up first), proxies turned off, DNS reset to automatic, and web addresses removed from shortcuts."
            }
        }
        @{
            Text = 'Open hosts file'
            Kind = 'Ui'
            Handler = {
                param($Rows)
                $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
                if ($script:isElevated) {
                    Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$hostsPath`""
                }
                else {
                    Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$hostsPath`"" -Verb RunAs
                }
            }
        }
        @{
            Text = 'Proxy settings'
            Kind = 'Ui'
            Handler = {
                param($Rows)
                Start-Process -FilePath 'ms-settings:network-proxy'
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
