# qBittorrent Auto Updater for Windows

Tired of qBittorrent asking *"A new version is available — do you want to update?"* every other
week? This script gets rid of that question — and, if you want, keeps the client updated for
you. Silently, in the background, with no windows ever appearing.

It's a single PowerShell file. No winget, no modules, no installer of its own — if you have
Windows and PowerShell, you already have everything it needs.

---

## Command 1 — auto-update + no more popup

```powershell
powershell -ExecutionPolicy Bypass -File .\qbt-updater.ps1 -Install
```

Windows will show one UAC prompt (the scheduled task needs admin rights to update a
machine-wide installation). Approve it — and that's the last time you'll think about updating
qBittorrent. The command:

1. Copies the script to `%ProgramData%\qBittorrentUpdater` — a permanent home, so you can
   delete the downloaded copy afterwards without breaking anything.
2. Registers a hidden scheduled task that checks for updates **every time you sign in to
   Windows**. Nothing flashes, nothing opens — if there is a fresh release, it is installed
   before you even open the client.
3. Writes `Advanced\updateCheck=false` into `qBittorrent.ini`, so the *"do you want to
   update?"* text never appears again.

## Command 2 — just hide the popup (no auto-update)

```powershell
powershell -ExecutionPolicy Bypass -File .\qbt-updater.ps1 -HidePopup
```

Only writes `Advanced\updateCheck=false` into `qBittorrent.ini` — no scheduled task, no
updates, nothing else. Administrator rights are not needed for this one, because the file
lives in your own user profile.

If qBittorrent is running, it is closed for a moment and opened again — the client overwrites
its settings file on exit, so the key cannot be written while it runs.

Note: the setting file appears after the first launch of qBittorrent, so the client must have
been run at least once.

---

## Removal

```powershell
powershell -ExecutionPolicy Bypass -File .\qbt-updater.ps1 -Uninstall
```

Removes the scheduled task and its files and restores qBittorrent's own update check (the
popup comes back). qBittorrent itself is not touched.

## Options (all optional)

| Parameter | Values | Default | Meaning |
|---|---|---|---|
| `-Channel` | `stable`, `beta` | `stable` | `beta` also follows pre-releases like `5.3.0beta1`, including beta1 → beta2 → rc1 steps. |
| `-Variant` | `auto`, `lt2`, `lt12` | `auto` | Which libtorrent build to install. `auto` detects it from the installed DLL. |
| `-LogonDelayMinutes` | minutes | `0` | Delay after sign-in. `0` means the check starts immediately. |
| `-TaskName` | string | `qBittorrent Auto Updater` | Scheduled task name. |
| `-LogPath` | path | `%LOCALAPPDATA%\qBittorrentUpdater\updater.log` | Log file location. |

For example, to follow beta releases and give the system five minutes to settle at sign-in:

```powershell
powershell -ExecutionPolicy Bypass -File .\qbt-updater.ps1 -Install -Channel beta -LogonDelayMinutes 5
```

Two more switches exist for manual runs: `-Update` (check and install right now) and
`-Check` (show versions, change nothing).

## How the update works

1. The installed version is read from the registry and from `qbittorrent.exe`, prerelease
   versions (beta/rc) are compared properly, not just numerically.
2. The latest release is fetched from the GitHub API together with the official SHA-256
   digests of its files.
3. The matching official installer is chosen: libtorrent 2.x or 1.2.x, 64-bit x64
   (that's the only Windows architecture qBittorrent publishes).
4. qBittorrent is closed gracefully (it gets 25 seconds, then a force-kill).
5. The installer is downloaded, its SHA-256 is verified against the official digest — if no
   trusted digest is available (for example, the API is unreachable), the update is refused
   rather than run unverified.
6. The installer is run silently (`/S`), the resulting version is verified, and qBittorrent
   is restarted with normal user rights if it was running — no matter how the update ended.

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
| `4` | The update popup could not be disabled |
| `5` | Administrator rights were required but not granted |
| `6` | qBittorrent could not be stopped |
| `7` | Download or installation failed |
| `8` | Installer finished but the resulting version is unexpected |
| `9` | No trusted SHA-256 digest available, update refused |

## Requirements

* Windows 10 / 11, 64-bit
* PowerShell 5.1 or newer — nothing else
* Internet access to `github.com` (only for the auto-update command)
* Administrator rights, once, during setup

## Notes

* If qBittorrent is set to minimise to the tray when closed, it may not exit on the first
  request; the script then closes it forcefully. Torrents resume from their saved state.
* The script never stores credentials. It writes only to its temp folder, the log file, the
  state file next to the log, the qBittorrent installation folder and the single
  `Advanced\updateCheck` key in `qBittorrent.ini`.

## License

MIT — see [LICENSE](LICENSE).
