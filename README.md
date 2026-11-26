# qBittorrent Auto Updater

A tiny tool that keeps qBittorrent up to date by itself and removes the
*"A new version is available — do you want to update?"* prompt, so you never see it again.

You set it up once with a single command. After that, every time you turn on your computer
the tool quietly checks for a new qBittorrent release and installs it before you even open
the program. No windows, no popups, no manual downloads.

Works on **Windows**, **macOS** and **Linux**. It is one script per platform and uses only
what the system already has. Nothing extra to install.

## What it does

* Checks the official qBittorrent page on GitHub every time you sign in.
* Downloads the official installer and verifies its SHA-256 checksum before running it —
  if the checksum cannot be verified, it does nothing rather than install something unverified.
* Installs the update silently while qBittorrent is closed, then opens qBittorrent again if
  it was running — with normal user rights.
* Hides the update prompt inside qBittorrent, because checking for updates is now this tool's job.
* Picks the right installer automatically for your system.

---

## Windows

**Requirements:** Windows 10 or 11 (64-bit), qBittorrent installed and started at least once.

### Command 1 — set up auto-updating (recommended)

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

### Command 2 — just remove the update prompt (no auto-updating)

```powershell
powershell -ExecutionPolicy Bypass -File .\qbt-updater.ps1 -HidePopup
```

This changes one setting inside qBittorrent and nothing else. It does not create any
scheduled task and does not install anything. Administrator rights are not needed.
If qBittorrent is running, it will close for a moment and open again — this is required,
because qBittorrent overwrites its settings file when it exits.

### How to undo everything

1. Press `Win + R`, type `taskschd.msc`, press Enter.
2. In **Task Scheduler Library** find **qBittorrent Auto Updater**, right-click it,
   choose **Delete**.
3. Delete the folder `C:\ProgramData\qBittorrentUpdater` if you want the files gone too.
4. To see update prompts again: close qBittorrent, open the file
   `%APPDATA%\qBittorrent\qBittorrent.ini` in Notepad, and delete the line
   `Advanced\updateCheck=false`.

---

## macOS

**Requirements:** macOS with qBittorrent installed in `/Applications` and started at least
once. The tool needs `python3` or `jq` (one of them is usually already present) to verify
checksums.

### Command 1 — set up auto-updating (recommended)

1. Download `qbt-updater.sh` into any folder.
2. Open Terminal, go to that folder (`cd ~/Downloads` if you downloaded it there).
3. Run:

   ```bash
   bash qbt-updater.sh install
   ```

That's it. The tool copies itself to `~/Library/Application Support/qBittorrentUpdater`,
registers a LaunchAgent that runs at every sign-in, and disables the update prompt in
qBittorrent. Updates are installed from the official `.dmg` into `/Applications` — no
administrator password needed, the tool never asks for one.

### Command 2 — just remove the update prompt (no auto-updating)

```bash
bash qbt-updater.sh hide-popup
```

Only the setting inside qBittorrent changes; no LaunchAgent, no updates. If qBittorrent is
running, it will close for a moment and open again.

### How to undo everything

1. Open Terminal and run:
   `launchctl unload ~/Library/LaunchAgents/com.qbittorrent.autoupdater.plist`
2. Delete the files:
   `rm ~/Library/LaunchAgents/com.qbittorrent.autoupdater.plist`
   and the folder `~/Library/Application Support/qBittorrentUpdater`.
3. To see update prompts again: close qBittorrent, open the file
   `~/Library/Preferences/qBittorrent/qBittorrent.ini` in a text editor, and delete the line
   `Advanced\updateCheck=false`.

---

## Linux

**Requirements:** any distribution with qBittorrent installed as the **official AppImage**,
started at least once. qBittorrent installed from distribution packages (apt, dnf, pacman…)
is updated by your package manager, and this tool does not touch it. The tool needs
`python3` or `jq` to verify checksums — one of them is present on almost any system.

### Command 1 — set up auto-updating (recommended)

1. Download `qbt-updater.sh` into any folder.
2. Open a terminal, go to that folder.
3. Run:

   ```bash
   bash qbt-updater.sh install
   ```

That's it. The tool copies itself to `~/.local/share/qBittorrentUpdater`, adds an autostart
entry that runs at every sign-in, and disables the update prompt in qBittorrent. Updates
replace your AppImage in place.

### Command 2 — just remove the update prompt (no auto-updating)

```bash
bash qbt-updater.sh hide-popup
```

Only the setting inside qBittorrent changes; no autostart entry, no updates. If qBittorrent
is running, it will close for a moment and open again.

### How to undo everything

1. Delete the autostart entry:
   `rm ~/.config/autostart/qbittorrent-auto-updater.desktop`
2. Delete the folder `~/.local/share/qBittorrentUpdater`.
3. To see update prompts again: close qBittorrent, open the file
   `~/.config/qBittorrent/qBittorrent.ini` in a text editor, and delete the line
   `Advanced\updateCheck=false`.

---

## If something goes wrong

Everything the tool does is written to a log file:

| Platform | Log file |
|---|---|
| Windows | `%LOCALAPPDATA%\qBittorrentUpdater\updater.log` |
| macOS | `~/Library/Logs/qBittorrentUpdater.log` |
| Linux | `~/.local/state/qbittorrent-updater.log` |

Open it and check the last lines. The outcome of each run is also stored in an exit code:

| Code | Meaning |
|---|---|
| `0` | Success, or already up to date |
| `1` | Unexpected error or wrong usage |
| `2` | qBittorrent is not installed (or is not a supported installation) |
| `3` | Could not determine the latest version |
| `4` | The update prompt could not be disabled |
| `5` | Administrator permission was not granted (Windows only) |
| `6` | qBittorrent could not be closed |
| `7` | Download or installation failed |
| `8` | Installer finished but the result is unexpected |
| `9` | Checksum could not be verified, update refused |

If qBittorrent is set to "minimize to tray", it may not close on the first try; the tool
then closes it forcefully — your torrents resume from where they were afterwards.

## License

MIT — see [LICENSE](LICENSE).
