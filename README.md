# qBittorrent Auto Updater for Windows

A tiny tool that keeps qBittorrent up to date by itself and removes the
*"A new version is available — do you want to update?"* prompt, so you never see it again.

You set it up once with a single command. After that, every time you turn on your PC the
tool quietly checks for a new qBittorrent release and installs it before you even open the
program. No windows, no popups, no manual downloads.

It is one PowerShell file and uses only what Windows already has. Nothing extra to install.

---

## What it does

* Checks the official qBittorrent page on GitHub every time you sign in to Windows.
* Downloads the official installer and verifies its SHA-256 checksum before running it —
  if the checksum cannot be verified, it does nothing rather than install something unverified.
* Installs the update silently while qBittorrent is closed, then opens qBittorrent again if
  it was running — with normal user rights, never as administrator.
* Hides the update prompt inside qBittorrent, because checking for updates is now this tool's job.
* Picks the right installer automatically for your system.

## Requirements

* Windows 10 or 11 (64-bit)
* qBittorrent installed and started at least once
* Internet access to `github.com`

## Command 1 — set up auto-updating (recommended)

1. Download `qbt-updater.ps1` into any folder (or double-click `install.cmd` and skip to step 4).
2. Open PowerShell in that folder: hold `Shift`, right-click an empty spot in the folder,
   choose **"Open PowerShell window here"** (or type `powershell` into the Explorer address bar).
3. Run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\qbt-updater.ps1 -Install
   ```

4. Windows asks for administrator permission once — click **Yes**.

That's it. The tool copies itself to `C:\ProgramData\qBittorrentUpdater` (its permanent home,
so you can delete the downloaded copy), creates a hidden scheduled task, and disables the
update prompt in qBittorrent. From now on updates happen by themselves at every sign-in.

## Command 2 — just remove the update prompt (no auto-updating)

If you only want the *"do you want to update?"* question to disappear:

```powershell
powershell -ExecutionPolicy Bypass -File .\qbt-updater.ps1 -HidePopup
```

This changes one setting inside qBittorrent and nothing else. It does not create any
scheduled task and does not install anything. Administrator rights are not needed.
If qBittorrent is running, it will close for a moment and open again — this is required,
because qBittorrent overwrites its settings file when it exits.

## How to undo everything

1. Press `Win + R`, type `taskschd.msc`, press Enter.
2. In **Task Scheduler Library** find **qBittorrent Auto Updater**, right-click it,
   choose **Delete**.
3. Delete the folder `C:\ProgramData\qBittorrentUpdater` if you want the files gone too.
4. To see update prompts again: close qBittorrent, open the file
   `%APPDATA%\qBittorrent\qBittorrent.ini` in Notepad, and delete the line
   `Advanced\updateCheck=false`.

qBittorrent itself is never modified or uninstalled by this tool.

## If something goes wrong

Everything the tool does is written to a log file:

```
%LOCALAPPDATA%\qBittorrentUpdater\updater.log
```

Open it in Notepad and check the last lines. The outcome of each run is also stored in an
exit code:

| Code | Meaning |
|---|---|
| `0` | Success, or already up to date |
| `1` | Unexpected error |
| `2` | qBittorrent is not installed |
| `3` | Could not determine the latest version |
| `4` | The update prompt could not be disabled |
| `5` | Administrator permission was not granted |
| `6` | qBittorrent could not be closed |
| `7` | Download or installation failed |
| `8` | Installer finished but the result is unexpected |
| `9` | Checksum could not be verified, update refused |

If qBittorrent is set to "minimize to tray", it may not close on the first try; the tool
then closes it forcefully — your torrents resume from where they were afterwards.

## Roadmap

* **Windows** — done, this is what the script does today.
* **macOS** — planned: the same two commands, using a LaunchAgent instead of Task Scheduler.
* **Linux** — planned: a shell version using systemd user timers.

## License

MIT — see [LICENSE](LICENSE).
