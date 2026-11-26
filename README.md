# qBittorrent Auto Updater for Windows

One small PowerShell script that keeps qBittorrent updated automatically - and stops the
"A new version is available, do you want to update?" popup from ever appearing again.

* **One file.** No dependencies, no winget, no modules, nothing to install.
* **Unattended.** Runs from Task Scheduler with the highest privileges, so no UAC popup.
* **Official sources only.** The installer is downloaded from the official GitHub release and
  its SHA-256 checksum is verified before it runs.

---

## Install (one command, once)

```powershell
powershell -ExecutionPolicy Bypass -File .\qbt-updater.ps1 -Install
```

That single command:

1. Registers a scheduled task that updates qBittorrent silently **the moment you sign in**,
   so a fresh release is picked up every time you boot the machine.
2. Writes `Advanced\updateCheck=false` into `qBittorrent.ini` so the client stops asking you
   to update - this script takes over that job.

You will get one UAC prompt, because the scheduled task needs administrator rights to be able
to update a machine-wide installation. After that, updates happen on their own.

Double-clicking `install.cmd` does the same thing.

## Other commands

```powershell
# Update right now
powershell -ExecutionPolicy Bypass -File .\qbt-updater.ps1 -Update

# Just show the versions, change nothing
powershell -ExecutionPolicy Bypass -File .\qbt-updater.ps1 -Check

# Remove the scheduled task
powershell -ExecutionPolicy Bypass -File .\qbt-updater.ps1 -Uninstall
```

## Options

| Parameter | Values | Default | Meaning |
|---|---|---|---|
| `-Install` | switch | - | Create the scheduled task and disable the update popup. |
| `-Uninstall` | switch | - | Remove the scheduled task. |
| `-Update` | switch | - | Check for an update and install it (default action). |
| `-Check` | switch | - | Report versions only, change nothing. |
| `-Channel` | `stable`, `beta` | `stable` | Which releases to follow. `beta` includes pre-releases. |
| `-Variant` | `auto`, `lt2`, `lt12` | `auto` | `auto` detects the installed libtorrent build from the bundled DLL. |
| `-LogonDelayMinutes` | minutes | `0` | Delay after sign-in. `0` means the check starts immediately. |
| `-TaskName` | string | `qBittorrent Auto Updater` | Scheduled task name. |
| `-LogPath` | path | `%LOCALAPPDATA%\qBittorrentUpdater\updater.log` | Log file location. |

## When does it run?

One mode only: **the moment you sign in to Windows**. Turn the PC on, log in, and the updater
immediately checks for a new qBittorrent release and installs it if there is one. Nothing to
remember, no fixed time of day.

If you would rather let the system settle first, add a delay in minutes:

```powershell
powershell -ExecutionPolicy Bypass -File .\qbt-updater.ps1 -Install -LogonDelayMinutes 5
```

## How the update is performed

1. The installed version is read from the registry and from `qbittorrent.exe`.
2. The latest release is taken from the GitHub API, with a fallback to the `/releases/latest`
   redirect so it still works when the API rate limit is hit.
3. The matching official installer is chosen (libtorrent 2.x or 1.2.x, x64 or arm64).
4. qBittorrent is closed, the installer is downloaded, its SHA-256 is verified against the
   digest published with the release, and it is run silently (`/S`).
5. The resulting version is verified and qBittorrent is restarted if it was running.

## Exit codes

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

* Windows 10 / 11 (also Windows 7 with PowerShell 5.1)
* PowerShell 5.1 or newer - nothing else
* Internet access to `github.com`
* Administrator rights, only once, for the setup

## Notes

* If qBittorrent is set to minimise to the tray when closed, the client may not exit on the
  first request; the script then terminates it. Torrents resume from their saved state.
* The script never stores credentials. It writes only to the temporary folder, the log file,
  the qBittorrent installation folder and the single `Advanced\updateCheck` key in
  `qBittorrent.ini`.

## License

MIT - see [LICENSE](LICENSE).
