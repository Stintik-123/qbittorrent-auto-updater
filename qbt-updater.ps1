<#
.SYNOPSIS
    qBittorrent auto-updater for Windows - single file, no dependencies.

.DESCRIPTION
    One script that does everything:
      * checks the latest official qBittorrent release on GitHub
      * downloads the official installer and verifies its SHA-256
      * installs it silently and restarts the client
      * switches off the built-in "Do you want to update?" popup
      * can register itself as a scheduled task that runs at every PC start

    Uses only built-in PowerShell. No winget, no modules, nothing to install.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File qbt-updater.ps1 -Install
    Installs the scheduled task and disables the update popup. Done once.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File qbt-updater.ps1 -Update
    Checks and installs an update right now.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File qbt-updater.ps1 -Check
    Only reports versions, changes nothing.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch] $Install,      # set up the scheduled task + disable the popup
    [switch] $Uninstall,    # remove the scheduled task
    [switch] $Update,       # perform an update now (default action)
    [switch] $Check,        # only report, change nothing

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

# --- constants ---------------------------------------------------------------

$Owner       = 'qbittorrent'
$Repo        = 'qBittorrent'
$ApiBase     = "https://api.github.com/repos/$Owner/$Repo"
$DownloadBase = "https://github.com/$Owner/$Repo/releases/download"
$TempDir     = Join-Path $env:TEMP ("qbt-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$ExitCode    = 0

# --- logging ----------------------------------------------------------------

function Write-Log {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')][string] $Level,
        [string] $Message
    )
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
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

# --- privileges -------------------------------------------------------------

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Elevated {
    <# Re-runs this script elevated, returns the child's exit code or $null if declined. #>
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($pair in @(
        @('-Channel', $Channel), @('-Variant', $Variant),
        @('-LogonDelayMinutes', $LogonDelayMinutes),
        @('-TaskName', "`"$TaskName`""), @('-LogPath', "`"$LogPath`"")
    )) {
        if ($pair[1]) { $args += $pair[0]; $args += $pair[1] }
    }
    foreach ($name in @('Install', 'Uninstall', 'Update', 'Check')) {
        if ((Get-Variable -Name $name -ValueOnly)) { $args += "-$name" }
    }

    Write-Log 'INFO' 'Administrator rights required, asking via UAC...'
    try {
        $p = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $args -Verb RunAs -Wait -PassThru
        return $p.ExitCode
    } catch {
        Write-Log 'WARN' "Elevation failed or was declined: $($_.Exception.Message)"
        return $null
    }
}

# --- installed version ------------------------------------------------------

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
            if ($n -and $n -like 'qBittorrent*') {
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
    }
    return $false
}

# --- latest release ---------------------------------------------------------

function Get-LatestRelease {
    <#
        Version source 1: GitHub releases API (gives SHA-256 digests too).
        Version source 2: the /releases/latest redirect (works without the API
        and without any rate limit), asset URLs are built from the tag.
    #>
    $headers = @{ 'User-Agent' = 'qbt-updater'; 'Accept' = 'application/vnd.github+json' }

    # --- API ---
    try {
        $rel = Invoke-RestMethod -Uri "$ApiBase/releases/latest" -Headers $headers -UseBasicParsing -ErrorAction Stop
        if ($rel -and $rel.tag_name) {
            $ver = ($rel.tag_name -replace '^release-', '') -replace '[^0-9.].*$', ''
            $digests = @{}
            foreach ($a in @($rel.assets)) {
                if ($a.digest -and $a.digest -match '^sha256:(.+)$') { $digests[$a.name] = $Matches[1].ToLowerInvariant() }
            }
            Write-Log 'DEBUG' "GitHub API: latest $ver"
            return [pscustomobject]@{ Version = $ver; Tag = $rel.tag_name; Digests = $digests }
        }
    } catch {
        Write-Log 'WARN' "GitHub API unavailable ($($_.Exception.Message)), using the releases page"
    }

    # --- redirect ---
    $loc = $null
    try {
        $resp = Invoke-WebRequest -Uri "https://github.com/$Owner/$Repo/releases/latest" -UseBasicParsing -ErrorAction Stop
        $loc = $resp.BaseResponse.RequestMessage.RequestUri.AbsoluteUri
    } catch {
        $err = $_.Exception
        while ($err -and -not $loc) {
            $headers = $null
            if ($err.Response -and $err.Response.Headers) { $headers = $err.Response.Headers }
            if ($headers) {
                $loc = $null
                try { $loc = $headers.Location } catch { $loc = $null }
                if (-not $loc) {
                    try { $loc = $headers['Location'] } catch { $loc = $null }
                }
            }
            $err = $err.InnerException
        }
        if (-not $loc) {
            Write-Log 'ERROR' "Cannot reach GitHub: $($_.Exception.Message)"
            return $null
        }
    }

    if ($loc -notmatch 'release-([0-9][0-9.]*)') {
        Write-Log 'ERROR' "Cannot parse the latest version from '$loc'"
        return $null
    }
    $ver = $Matches[1]
    Write-Log 'DEBUG' "Releases page: latest $ver"
    return [pscustomobject]@{ Version = $ver; Tag = "release-$ver"; Digests = @{} }
}

function Get-InstallerUrl {
    param([string] $Tag, [string] $Version, [string] $Variant, [string] $Arch)
    $suffix = if ($Arch -eq 'arm64') { 'arm64' } else { 'x64' }
    $lt = if ($Variant -eq 'lt12') { '_lt12' } else { '' }
    return "$DownloadBase/$Tag/qbittorrent_${Version}${lt}_${suffix}_setup.exe"
}

# --- update popup -----------------------------------------------------------

function Disable-UpdatePopup {
    <# Writes Advanced\updateCheck=false so qBittorrent stops asking to update. #>
    $ini = Join-Path $env:APPDATA 'qBittorrent\qBittorrent.ini'
    if (-not (Test-Path -LiteralPath $ini)) {
        Write-Log 'WARN' "qBittorrent.ini not found at $ini"
        return $false
    }
    $content = Get-Content -LiteralPath $ini -Raw -Encoding UTF8
    $key = 'Advanced\updateCheck'

    if ($content -match "(?m)^$([regex]::Escape($key))=.*$") {
        $content = [regex]::Replace($content, "(?m)^$([regex]::Escape($key))=.*$", "$key=false")
    } elseif ($content -match '(?m)^\[Preferences\]\s*$') {
        $content = [regex]::Replace($content, '(?m)^(\[Preferences\]\s*)$', "`$1`r`n$key=false")
    } else {
        $content = $content.TrimEnd() + "`r`n[Preferences]`r`n$key=false`r`n"
    }

    try {
        Set-Content -LiteralPath $ini -Value $content -Encoding UTF8 -NoNewline
        Write-Log 'INFO' 'Update popup disabled (Advanced\updateCheck=false).'
        return $true
    } catch {
        Write-Log 'WARN' "Cannot write qBittorrent.ini: $($_.Exception.Message)"
        return $false
    }
}

# --- process handling -------------------------------------------------------

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
    Write-Log 'INFO' 'Starting qBittorrent...'
    Start-Process -FilePath $Exe -WorkingDirectory (Split-Path -Parent $Exe) | Out-Null
}

# --- update -----------------------------------------------------------------

function Invoke-Update {
    $qbt = Get-QbtInstall
    if (-not $qbt) {
        Write-Log 'ERROR' 'qBittorrent is not installed on this machine.'
        return 2
    }
    Write-Log 'INFO' "Installed: $($qbt.Version) ($($qbt.Exe))"

    $rel = Get-LatestRelease
    if (-not $rel) { return 3 }
    Write-Log 'INFO' "Latest:    $($rel.Version)"

    $cur = [version]($qbt.Version -replace '[^0-9.].*$', '')
    $new = [version]($rel.Version -replace '[^0-9.].*$', '')
    if ($cur -ge $new) {
        Write-Log 'INFO' "Already up to date ($cur)."
        return 0
    }

    $variant = $Variant
    if ($variant -eq 'auto') {
        $variant = if (Test-Lt12Build -Dir $qbt.Dir) { 'lt12' } else { 'lt2' }
    }
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { 'arm64' } else { 'x64' }

    $url = Get-InstallerUrl -Tag $rel.Tag -Version $rel.Version -Variant $variant -Arch $arch
    Write-Log 'INFO' "Installer: $url"

    if ($Check) {
        Write-Log 'INFO' "Update available: $cur -> $new. Check only, nothing changed."
        return 0
    }

    if (-not (Stop-Qbt)) {
        Write-Log 'ERROR' 'Cannot stop qBittorrent, aborting.'
        return 6
    }

    if (-not (Test-Path -LiteralPath $TempDir)) {
        New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
    }
    $file = Join-Path $TempDir 'qbittorrent-setup.exe'

    Write-Log 'INFO' 'Downloading...'
    try {
        $old = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing -ErrorAction Stop
        $ProgressPreference = $old
    } catch {
        Write-Log 'ERROR' "Download failed: $($_.Exception.Message)"
        return 7
    }

    $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    $ltTag = if ($variant -eq 'lt12') { '_lt12' } else { '' }
    $assetName = "qbittorrent_$($rel.Version)$ltTag`_$arch`_setup.exe"
    $expected = if ($rel.Digests.ContainsKey($assetName)) { $rel.Digests[$assetName] } else { $null }
    if ($expected) {
        if ($hash -ne $expected) {
            Write-Log 'ERROR' "Checksum mismatch: expected $expected, got $hash"
            return 7
        }
        Write-Log 'INFO' 'Checksum verified.'
    } else {
        Write-Log 'INFO' "SHA-256: $hash"
    }

    Write-Log 'INFO' 'Installing silently...'
    try {
        $proc = Start-Process -FilePath $file -ArgumentList '/S' -Wait -PassThru -ErrorAction Stop
        Write-Log 'INFO' "Installer exit code: $($proc.ExitCode)"
    } catch {
        Write-Log 'ERROR' "Installer failed: $($_.Exception.Message)"
        return 7
    }

    Start-Sleep -Seconds 3
    $after = Get-QbtInstall
    if ($after -and $after.Version -eq $rel.Version) {
        Write-Log 'INFO' "Updated to $($after.Version)."
        if ($qbt.Running) { Start-Qbt -Exe $after.Exe }
        return 0
    }
    $got = if ($after) { $after.Version } else { 'unknown' }
    Write-Log 'WARN' "Installer finished but the version is $got (expected $($rel.Version))."
    if ($qbt.Running) { Start-Qbt -Exe $qbt.Exe }
    return 8
}

# --- scheduled task ---------------------------------------------------------

function Install-Task {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Update -Channel {1} -Variant {2} -LogPath "{3}"' -f $PSCommandPath, $Channel, $Variant, $LogPath)

    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1)

    # Single trigger: run right after the PC starts (the user signs in).
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    if ($LogonDelayMinutes -gt 0) {
        # Optional delay, in case the system needs a moment to settle.
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
    Write-Log 'INFO' "Scheduled task '$TaskName' created: runs $when on every PC start."
}

function Uninstall-Task {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Log 'INFO' "Scheduled task '$TaskName' removed."
    } else {
        Write-Log 'INFO' "Scheduled task '$TaskName' not found."
    }
}

# --- main -------------------------------------------------------------------

try {
    Write-Log 'INFO' '=== qbt-updater ==='

    $needsAdmin = ($Install -or $Uninstall -or $Update) -and -not $Check
    if ($needsAdmin -and -not (Test-Admin)) {
        $code = Invoke-Elevated
        if ($null -eq $code) { $ExitCode = 5 } else { $ExitCode = $code }
        throw 'elevated'
    }

    if ($Uninstall) {
        Uninstall-Task
    }
    elseif ($Install) {
        Install-Task
        # The popup is written into the ini, so the client must be closed first,
        # otherwise it overwrites our change when it exits.
        $qbt = Get-QbtInstall
        if ($qbt -and $qbt.Running) {
            $null = Stop-Qbt
        }
        $null = Disable-UpdatePopup
        if ($qbt -and $qbt.Running) { Start-Qbt -Exe $qbt.Exe }
        Write-Log 'INFO' 'Setup complete. The client is updated automatically every time the PC starts.'
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
