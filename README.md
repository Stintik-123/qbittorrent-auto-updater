# qBittorrent Auto Updater for Windows

Tired of qBittorrent asking *"A new version is available — do you want to update?"* every other
week, and of downloading installers by hand afterwards? This script does both jobs for you.

It's a single PowerShell file. No winget, no modules, no installer of its own — if you have
Windows and PowerShell, you already have everything it needs.

**What it does:**

* ✅ Checks the latest official release on the qBittorrent GitHub page (every sign-in).
* ✅ Downloads the official installer, verifies its SHA-256 checksum, and installs it silently.
* ✅ Restarts qBittorrent afterwards if it was running — torrents resume from where they were.
* ✅ Switches off the built-in update popup, so the question never appears again.
* ✅ Follows the **stable** or the **beta** channel — your choice.
* ✅ Picks the right build automatically: libtorrent 2.x or 1.2.x, matching what you have installed.

---

## Quick start (one command, once)

```powershell
powershell -ExecutionPolicy Bypass -File .\qbt-updater.ps1 -Install
```

You can also just double-click `install.cmd`.

Windows will show one UAC prompt (the scheduled task needs admin rights to update a
machine-wide installation). Approve it, and that's the last time you'll think about
updating qBittorrent. The command does two things:

1. Registers a scheduled task that silently checks for updates **every time you sign in to
   Windows**. Turn the PC on, and a fresh release — if any — is installed before you even
   open the client.
2. Writes `Advanced\updateCheck=false` into `qBittorrent.ini`, so qBittorrent itself stops
   nagging about updates. The script takes over that job.

## Everyday commands

You'll rarely need these — everything below is optional.

```powershell
# Check for and install an update right now
powershell -ExecutionPolicy Bypass -File .\qbt-updater.ps1 -Update

# Just show the installed and the latest version, change nothing
powershell -ExecutionPolicy Bypass -File .\qbt-updater.ps1 -Check

# Remove the scheduled task (the updater stops working, qBittorrent is untouched)
powershell -ExecutionPolicy Bypass -File .\qbt-updater.ps1 -Uninstall
```

## Options

| Parameter | Values | Default | Meaning |
|---|---|---|---|
| `-Install` | switch | - | Create the scheduled task and disable the update popup. |
| `-Uninstall` | switch | - | Remove the scheduled task. |
| `-Update` | switch | - | Check for an update and install it (default action). |
| `-Check` | switch | - | Report versions only, change nothing. |
| `-Channel` | `stable`, `beta` | `stable` | `beta` also follows pre-releases like `5.3.0beta1`. |
| `-Variant` | `auto`, `lt2`, `lt12` | `auto` | Which libtorrent build to install. `auto` detects it from the installed DLL. |
| `-LogonDelayMinutes` | minutes | `0` | Delay after sign-in. `0` means the check starts immediately. |
| `-TaskName` | string | `qBittorrent Auto Updater` | Scheduled task name. |
| `-LogPath` | path | `%LOCALAPPDATA%\qBittorrentUpdater\updater.log` | Log file location. |

For example, to follow beta releases and give the system five minutes to settle at sign-in:

```powershell
powershell -ExecutionPolicy Bypass -File .\qbt-updater.ps1 -Install -Channel beta -LogonDelayMinutes 5
```

## How the update works

1. The installed version is read from the registry and from `qbittorrent.exe`.
2. The latest release is fetched from the GitHub API — or, if the API rate limit is hit,
   from the `/releases/latest` redirect, so the check keeps working either way.
3. The matching official installer is chosen: libtorrent 2.x or 1.2.x, 64-bit x64
   (that's the only Windows architecture qBittorrent publishes).
4. qBittorrent is closed gracefully (it gets 25 seconds, then a force-kill).
5. The installer is downloaded, its SHA-256 is verified against the digest published with
   the release, and it is run silently (`/S`).
6. The resulting version is verified and qBittorrent is restarted if it was running.

## If something goes wrong

Everything the script does is written to the log:

```
%LOCALAPPDATA%\qBittorrentUpdater\updater.log
```

The script also reports its outcome through an exit code:

| Code | Meaning |
|---|---|
| `0` | Success, or already up to date |
| `1` | Unexpected error |
| `2` | qBittorrent is not installed |
| `3` | Could not determine the latest version |
| `5` | Administrator rights were required but not granted |
| `6` | qBittorrent could not be stopped |
| `7` | Download or installation failed |
| `8` | Installer finished but the resulting version is unexpected |

## Requirements

* Windows 10 / 11, 64-bit
* PowerShell 5.1 or newer — nothing else
* Internet access to `github.com`
* Administrator rights, once, during setup

## Notes

* If qBittorrent is set to minimise to the tray when closed, it may not exit on the first
  request; the script then closes it forcefully. Torrents resume from their saved state.
* The script never stores credentials. It writes only to its temp folder, the log file, the
  qBittorrent installation folder and the single `Advanced\updateCheck` key in
  `qBittorrent.ini`.

## License

MIT — see [LICENSE](LICENSE).
