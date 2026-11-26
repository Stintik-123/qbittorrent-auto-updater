#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch] $Install,
    [switch] $Uninstall,
    [switch] $HidePopup,
    [switch] $Update,
    [switch] $Check,

    [ValidateSet('stable', 'beta')]
    [string] $Channel = 'stable',

    [ValidateSet('auto', 'lt2', 'lt12')]
    [string] $Variant = 'auto',

    [ValidatePattern('^\d+$')]
    [int] $LogonDelayMinutes = 0,

    [string] $TaskName = 'qBittorrent Auto Updater',

    [string] $LogPath = (Join-Path $env:LOCALAPPDATA 'qBittorrentUpdater\updater.log')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Owner = 'qbittorrent'
$Repo = 'qBittorrent'
$ApiBase = "https://api.github.com/repos/$Owner/$Repo"
$DownloadBase = "https://github.com/$Owner/$Repo/releases/download"
$TempDir = Join-Path $env:TEMP ("qbt-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$InstallDir = Join-Path $env:ProgramData 'qBittorrentUpdater'
$StateFile = Join-Path (Split-Path -Parent $LogPath) 'installed.tag'
$ExitCode = 0

function Write-Log {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')][string] $Level,
        [string] $Message
    )
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN' { Write-Host $line -ForegroundColor Yellow }
        'DEBUG' { Write-Host $line -ForegroundColor DarkGray }
        default { Write-Host $line }
    }
    try {
        $dir = Split-Path -Parent $LogPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch { }
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Elevated {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($pair in @(
        @('-Channel', $Channel), @('-Variant', $Variant),
        @('-LogonDelayMinutes', $LogonDelayMinutes),
        @('-TaskName', "`"$TaskName`""), @('-LogPath', "`"$LogPath`"")
    )) {
        if ($pair[1]) { $argList += $pair[0]; $argList += $pair[1] }
    }
    foreach ($name in @('Install', 'Uninstall', 'HidePopup', 'Update', 'Check')) {
        if ((Get-Variable -Name $name -ValueOnly)) { $argList += "-$name" }
    }

    Write-Log 'INFO' 'Administrator rights required, asking via UAC...'
    try {
        $p = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $argList -Verb RunAs -Wait -PassThru
        return $p.ExitCode
    } catch {
        Write-Log 'WARN' "Elevation failed or was declined: $($_.Exception.Message)"
        return $null
    }
}

function Get-QbtInstall {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $entry = $null
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($key in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
            $p = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if (-not $p) { continue }
            $n = if ($p.PSObject.Properties['DisplayName']) { $p.DisplayName } else { $null }
            if ($n -and $n -match '^qBittorrent\b' -and $n -notmatch 'Enhanced') {
                $entry = [pscustomobject]@{
                    Version = if ($p.PSObject.Properties['DisplayVersion']) { $p.DisplayVersion } else { $null }
                    Path    = if ($p.PSObject.Properties['InstallLocation']) { $p.InstallLocation } else { $null }
                    Icon    = if ($p.PSObject.Properties['DisplayIcon']) { $p.DisplayIcon } else { $null }
                }
                break
            }
        }
        if ($entry) { break }
    }

    $exe = $null
    if ($entry -and $entry.Path) {
        $c = Join-Path $entry.Path 'qbittorrent.exe'
        if (Test-Path -LiteralPath $c) { $exe = $c }
    }
    if (-not $exe -and $entry -and $entry.Icon) {
        $i = ($entry.Icon -split ',')[0].Trim().Trim('"')
        if (Test-Path -LiteralPath $i) { $exe = $i }
    }
    if (-not $exe) {
        foreach ($c in @(
            (Join-Path $env:ProgramFiles 'qBittorrent\qbittorrent.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'qBittorrent\qbittorrent.exe'),
            (Join-Path $env:LOCALAPPDATA 'Programs\qBittorrent\qbittorrent.exe')
        )) {
            if ($c -and (Test-Path -LiteralPath $c)) { $exe = $c; break }
        }
    }
    if (-not $exe) { return $null }

    $ver = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion
    if ($ver) { $ver = ($ver -replace '^[vV]', '') -replace '[^0-9.].*$', '' }
    if (-not $ver -and $entry) { $ver = ($entry.Version -replace '[^0-9.].*$', '') }

    $procs = @(Get-Process -Name 'qbittorrent' -ErrorAction SilentlyContinue)

    [pscustomobject]@{
        Version = $ver
        Exe     = $exe
        Dir     = Split-Path -Parent $exe
        Running = ($procs.Count -gt 0)
    }
}

function Test-Lt12Build {
    param([string] $Dir)
    foreach ($d in @(Get-ChildItem -LiteralPath $Dir -Filter 'libtorrent*.dll' -ErrorAction SilentlyContinue)) {
        if ($d.Name -match '1[._]2') { return $true }
        if ($d.VersionInfo.FileMajorPart -and $d.VersionInfo.FileMajorPart -lt 2) { return $true }
    }
    return $false
}

function Get-LatestRelease {
    $headers = @{ 'User-Agent' = 'qbt-updater'; 'Accept' = 'application/vnd.github+json' }
    $wantPre = ($Channel -eq 'beta')

    try {
        $rels = Invoke-RestMethod -Uri "$ApiBase/releases?per_page=30" -Headers $headers -UseBasicParsing -ErrorAction Stop
        $rel = @($rels) | Where-Object { [bool]$_.prerelease -eq $wantPre } | Select-Object -First 1
        if ($rel -and $rel.tag_name) {
            $ver = ($rel.tag_name -replace '^release-', '')
            $digests = @{}
            foreach ($a in @($rel.assets)) {
                if ($a.PSObject.Properties['digest'] -and $a.digest -match '^sha256:(.+)$') {
                    $digests[$a.name] = $Matches[1].ToLowerInvariant()
                }
            }
            Write-Log 'DEBUG' "GitHub API: latest $ver ($Channel)"
            return [pscustomobject]@{ Version = $ver; Tag = $rel.tag_name; Digests = $digests }
        }
    } catch {
        Write-Log 'WARN' "GitHub API unavailable ($($_.Exception.Message)), using the releases page"
    }

    if ($wantPre) {
        Write-Log 'ERROR' 'The beta channel needs the GitHub API, which is unreachable right now.'
        return $null
    }

    $loc = $null
    try {
        $req = [System.Net.WebRequest]::Create("https://github.com/$Owner/$Repo/releases/latest")
        $req.AllowAutoRedirect = $false
        $req.UserAgent = 'qbt-updater'
        $resp = $req.GetResponse()
        $loc = $resp.Headers['Location']
        $resp.Close()
    } catch { }

    if (-not $loc) {
        Write-Log 'ERROR' 'Cannot reach GitHub to determine the latest version.'
        return $null
    }
    if ($loc -notmatch 'release-([0-9][0-9.]*)') {
        Write-Log 'ERROR' "Cannot parse the latest version from '$loc'"
        return $null
    }
    $ver = $Matches[1]
    Write-Log 'DEBUG' "Releases page: latest $ver"
    return [pscustomobject]@{ Version = $ver; Tag = "release-$ver"; Digests = @{} }
}

function Get-InstallerCandidates {
    param([string] $Version, [string] $Variant)
    $suffixes = if ($Variant -eq 'lt12') { @('_lt12') } else { @('_lt20', '') }
    return @($suffixes | ForEach-Object { "qbittorrent_${Version}$($_)_x64_setup.exe" })
}

function Convert-QbtVersion {
    param([string] $Text)
    if (-not $Text) { return $null }
    $t = ([string]$Text).Trim() -replace '^[vV]', ''
    if ($t -notmatch '^(\d+(?:\.\d+){0,3})(.*)$') { return $null }
    try { $core = [version]$Matches[1] } catch { return $null }
    $pre = $null
    if ($Matches[2] -match '(?i)(alpha|beta|rc|dev)[._-]?(\d+)?') {
        $num = 0
        if ($Matches[2]) { $num = [int]$Matches[2] }
        $pre = [pscustomobject]@{ Kind = $Matches[1].ToLowerInvariant(); Num = $num }
    }
    [pscustomobject]@{ Core = $core; Pre = $pre }
}

function Get-PreRank {
    param($Pre)
    if (-not $Pre) { return 3 }
    switch ($Pre.Kind) {
        'rc' { return 2 }
        'beta' { return 1 }
        default { return 0 }
    }
}

function Test-NeedsUpdate {
    param($Installed, $Candidate)
    if (-not $Candidate) { return $false }
    if (-not $Installed) { return $true }
    if ($Installed.Core -ne $Candidate.Core) { return ($Installed.Core -lt $Candidate.Core) }
    $ir = Get-PreRank -Pre $Installed.Pre
    $cr = Get-PreRank -Pre $Candidate.Pre
    if ($ir -ne $cr) { return ($ir -lt $cr) }
    if (-not $Installed.Pre -or -not $Candidate.Pre) { return $false }
    return ($Installed.Pre.Num -lt $Candidate.Pre.Num)
}

function Set-UpdateCheckKey {
    param([string] $Value)
    $ini = Join-Path $env:APPDATA 'qBittorrent\qBittorrent.ini'
    if (-not (Test-Path -LiteralPath $ini)) {
        Write-Log 'WARN' "qBittorrent.ini not found at $ini"
        return $false
    }
    $content = Get-Content -LiteralPath $ini -Raw -Encoding UTF8
    $key = 'Advanced\updateCheck'
    $esc = [regex]::Escape($key)

    if ($content -match "(?m)^$esc=.*$") {
        if ($Value) {
            $content = [regex]::Replace($content, "(?m)^$esc=.*$", "$key=$Value")
        } else {
            $content = [regex]::Replace($content, "(?m)^$esc=.*\r?\n?", '')
        }
    } elseif ($Value) {
        if ($content -match '(?m)^\[Preferences\]\s*$') {
            $content = [regex]::Replace($content, '(?m)^(\[Preferences\]\s*)$', "`$1`r`n$key=$Value")
        } else {
            $content = $content.TrimEnd() + "`r`n[Preferences]`r`n$key=$Value`r`n"
        }
    } else {
        return $true
    }

    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($ini, $content, $utf8NoBom)
        return $true
    } catch {
        Write-Log 'WARN' "Cannot write qBittorrent.ini: $($_.Exception.Message)"
        return $false
    }
}

function Disable-UpdatePopup {
    if (Set-UpdateCheckKey -Value 'false') {
        Write-Log 'INFO' 'Update popup disabled (Advanced\updateCheck=false).'
        return $true
    }
    return $false
}

function Restore-UpdatePopup {
    if (Set-UpdateCheckKey -Value '') {
        Write-Log 'INFO' 'Update popup restored (Advanced\updateCheck key removed, qBittorrent default applies).'
    }
}

function Stop-Qbt {
    $procs = @(Get-Process -Name 'qbittorrent' -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return $true }
    Write-Log 'INFO' 'Closing qBittorrent...'
    foreach ($p in $procs) { try { $null = $p.CloseMainWindow() } catch { } }

    $until = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $until) {
        if (@(Get-Process -Name 'qbittorrent' -ErrorAction SilentlyContinue).Count -eq 0) {
            Write-Log 'INFO' 'qBittorrent closed.'
            return $true
        }
        Start-Sleep -Seconds 2
    }
    Write-Log 'WARN' 'Closing timed out, forcing termination.'
    Get-Process -Name 'qbittorrent' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    return (@(Get-Process -Name 'qbittorrent' -ErrorAction SilentlyContinue).Count -eq 0)
}

function Start-Qbt {
    param([string] $Exe)
    if (-not (Test-Path -LiteralPath $Exe)) { return }
    Write-Log 'INFO' 'Starting qBittorrent with normal user rights...'
    try {
        Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$Exe`"" | Out-Null
    } catch {
        Write-Log 'WARN' "Shell launch failed, starting directly: $($_.Exception.Message)"
        Start-Process -FilePath $Exe -WorkingDirectory (Split-Path -Parent $Exe) | Out-Null
    }
}

function Invoke-Update {
    $qbt = Get-QbtInstall
    if (-not $qbt) {
        Write-Log 'ERROR' 'qBittorrent is not installed on this machine.'
        return 2
    }

    $rel = Get-LatestRelease
    if (-not $rel) { return 3 }
    Write-Log 'INFO' "Latest:    $($rel.Version)"

    $candidate = Convert-QbtVersion -Text $rel.Version
    if (-not $candidate) {
        Write-Log 'ERROR' "Cannot parse the version '$($rel.Version)'."
        return 3
    }

    $stateTag = $null
    if (Test-Path -LiteralPath $StateFile) {
        try { $stateTag = (Get-Content -LiteralPath $StateFile -Raw).Trim() } catch { $stateTag = $null }
    }
    $installed = $null
    if ($qbt.Version) {
        $installed = Convert-QbtVersion -Text $qbt.Version
        if ($installed -and $stateTag) {
            $state = Convert-QbtVersion -Text $stateTag
            if ($state -and $state.Pre -and $state.Core -eq $installed.Core) { $installed = $state }
        }
    }

    if ($installed) {
        Write-Log 'INFO' "Installed: $($qbt.Version) ($($qbt.Exe))"
        if (-not (Test-NeedsUpdate -Installed $installed -Candidate $candidate)) {
            Write-Log 'INFO' "Already up to date ($($qbt.Version))."
            return 0
        }
    } else {
        Write-Log 'WARN' "Installed version unknown ($($qbt.Exe)), updating anyway."
    }

    if ($Check) {
        Write-Log 'INFO' "Update available: $($qbt.Version) -> $($rel.Version). Check only, nothing changed."
        return 0
    }

    $variant = $Variant
    if ($variant -eq 'auto') {
        $variant = if (Test-Lt12Build -Dir $qbt.Dir) { 'lt12' } else { 'lt2' }
    }

    $candidates = Get-InstallerCandidates -Version $rel.Version -Variant $variant
    $known = @($candidates | Where-Object { $rel.Digests.ContainsKey($_) })
    if (-not $known) {
        Write-Log 'ERROR' 'No trusted SHA-256 digest for the installer; refusing to run an unverified file.'
        return 9
    }
    Write-Log 'INFO' "Installer: $($known[0])"

    if (-not (Stop-Qbt)) {
        Write-Log 'ERROR' 'Cannot stop qBittorrent, aborting.'
        return 6
    }

    try {
        if (-not (Test-Path -LiteralPath $TempDir)) {
            New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
        }
        $file = Join-Path $TempDir 'qbittorrent-setup.exe'

        Write-Log 'INFO' 'Downloading...'
        $assetName = $null
        $old = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        foreach ($asset in $known) {
            $url = "$DownloadBase/$($rel.Tag)/$asset"
            try {
                Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing -ErrorAction Stop
                $assetName = $asset
                break
            } catch {
                Write-Log 'WARN' "Download of $asset failed: $($_.Exception.Message)"
            }
        }
        $ProgressPreference = $old
        if (-not $assetName) {
            Write-Log 'ERROR' 'All download attempts failed.'
            return 7
        }

        $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        $expected = $rel.Digests[$assetName]
        if ($hash -ne $expected) {
            Write-Log 'ERROR' "Checksum mismatch: expected $expected, got $hash"
            return 7
        }
        Write-Log 'INFO' 'Checksum verified.'

        Write-Log 'INFO' 'Installing silently...'
        $proc = Start-Process -FilePath $file -ArgumentList '/S' -Wait -PassThru
        Write-Log 'INFO' "Installer exit code: $($proc.ExitCode)"

        Start-Sleep -Seconds 3
        $after = Get-QbtInstall
        $afterCore = $null
        if ($after -and $after.Version) { $afterCore = (Convert-QbtVersion -Text $after.Version).Core }
        if (-not $afterCore -or $afterCore -lt $candidate.Core) {
            $got = if ($after) { $after.Version } else { 'unknown' }
            Write-Log 'WARN' "Installer finished but the version is $got (expected $($rel.Version))."
            return 8
        }

        try { Set-Content -LiteralPath $StateFile -Value $rel.Version -Encoding ASCII } catch { }
        Write-Log 'INFO' "Updated to $($after.Version)."
        return 0
    }
    finally {
        if ($qbt.Running) {
            $now = Get-QbtInstall
            $exe = if ($now) { $now.Exe } else { $qbt.Exe }
            Start-Qbt -Exe $exe
        }
    }
}

function Install-Task {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    $target = Join-Path $InstallDir 'qbt-updater.ps1'
    Copy-Item -LiteralPath $PSCommandPath -Destination $target -Force

    $psArgs = ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Update -Channel {1} -Variant {2} -LogPath "{3}"' -f $target, $Channel, $Variant, $LogPath)
    $launcher = Join-Path $InstallDir 'run-updater.vbs'
    $vbsArgs = $psArgs.Replace('"', '""')
    $vbs = "Set shell = CreateObject(`"WScript.Shell`")`r`nshell.Run `"powershell.exe $vbsArgs`", 0, False"
    Set-Content -LiteralPath $launcher -Value $vbs -Encoding ASCII

    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$launcher`""

    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1)

    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    if ($LogonDelayMinutes -gt 0) {
        try { $trigger.Delay = "PT${LogonDelayMinutes}M" } catch { }
    }

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
    Register-ScheduledTask -TaskName $TaskName -Action $action `
        -Trigger $trigger `
        -Principal $principal -Settings $settings `
        -Description 'Automatically updates qBittorrent to the latest official release.' | Out-Null

    $when = if ($LogonDelayMinutes -gt 0) { "${LogonDelayMinutes} minute(s) after sign-in" } else { 'immediately at sign-in' }
    Write-Log 'INFO' "Scheduled task '$TaskName' created: runs $when on every PC start, fully hidden, from $target."
}

function Uninstall-Task {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Log 'INFO' "Scheduled task '$TaskName' removed."
    } else {
        Write-Log 'INFO' "Scheduled task '$TaskName' not found."
    }
    foreach ($f in @((Join-Path $InstallDir 'run-updater.vbs'), (Join-Path $InstallDir 'qbt-updater.ps1'))) {
        if ($f -ne $PSCommandPath -and (Test-Path -LiteralPath $f)) {
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        }
    }
}

function Hide-UpdatePopupOnly {
    $qbt = Get-QbtInstall
    if ($qbt -and $qbt.Running) {
        $null = Stop-Qbt
    }
    $ok = Disable-UpdatePopup
    if ($ok) {
        Write-Log 'INFO' 'Update popup disabled. Auto-update is not set up.'
    } else {
        $script:ExitCode = 4
    }
    if ($qbt -and $qbt.Running) { Start-Qbt -Exe $qbt.Exe }
    return $ok
}

try {
    Write-Log 'INFO' '=== qbt-updater ==='

    $isDefault = -not ($Install -or $Uninstall -or $HidePopup -or $Update -or $Check)
    $needsAdmin = ($Install -or $Uninstall -or $Update -or $isDefault) -and -not $Check
    if ($needsAdmin -and -not (Test-Admin)) {
        $code = Invoke-Elevated
        if ($null -eq $code) { $ExitCode = 5 } else { $ExitCode = $code }
        throw 'elevated'
    }

    if ($HidePopup) {
        $null = Hide-UpdatePopupOnly
    }
    elseif ($Uninstall) {
        Uninstall-Task
        Restore-UpdatePopup
    }
    elseif ($Install) {
        Install-Task
        $qbt = Get-QbtInstall
        if ($qbt -and $qbt.Running) {
            $null = Stop-Qbt
        }
        if (Disable-UpdatePopup) {
            Write-Log 'INFO' 'Setup complete. The client is updated automatically every time the PC starts.'
        } else {
            Write-Log 'WARN' 'Setup finished, but the update popup could not be disabled.'
        }
        if ($qbt -and $qbt.Running) { Start-Qbt -Exe $qbt.Exe }
    }
    else {
        $ExitCode = Invoke-Update
    }
}
catch {
    if ($_.Exception.Message -notin @('elevated')) {
        Write-Log 'ERROR' $_.Exception.Message
        if ($ExitCode -eq 0) { $ExitCode = 1 }
    }
}
finally {
    if (Test-Path -LiteralPath $TempDir) {
        Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Log 'INFO' "=== done (exit $ExitCode) ==="
}

exit $ExitCode
