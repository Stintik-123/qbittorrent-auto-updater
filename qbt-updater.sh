#!/usr/bin/env bash
set -euo pipefail

COMMAND="${1:-}"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
OS_NAME="$(uname -s)"

if [[ "$OS_NAME" == "Darwin" ]]; then
    PLATFORM="macos"
    INSTALL_DIR="$HOME/Library/Application Support/qBittorrentUpdater"
    LOG_FILE="$HOME/Library/Logs/qBittorrentUpdater.log"
    INI_FILE="$HOME/Library/Preferences/qBittorrent/qBittorrent.ini"
    APP_DIR="/Applications/qBittorrent.app"
elif [[ "$OS_NAME" == "Linux" ]]; then
    PLATFORM="linux"
    INSTALL_DIR="$HOME/.local/share/qBittorrentUpdater"
    LOG_FILE="$HOME/.local/state/qbittorrent-updater.log"
    INI_FILE="$HOME/.config/qBittorrent/qBittorrent.ini"
    APP_DIR=""
else
    echo "Unsupported platform: $OS_NAME" >&2
    exit 1
fi

STATE_FILE="$INSTALL_DIR/installed.tag"
EXIT_CODE=0
INSTALL_PATH=""
INSTALL_VERSION=""
VARIANT=""
RUNNING="no"
LATEST_TAG=""
LATEST_VERSION=""
DIGESTS_FILE=""
ASSET_NAME=""
ASSET_DIGEST=""

log() {
    local level="$1" message="$2"
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"
    if [[ "$level" == "ERROR" ]]; then
        echo "$line" >&2
    else
        echo "$line"
    fi
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "$line" >> "$LOG_FILE"
}

usage() {
    echo "Usage: $(basename "$0") install | hide-popup | update"
}

detect_install() {
    if [[ "$PLATFORM" == "macos" ]]; then
        if [[ ! -d "$APP_DIR" ]]; then
            log ERROR "qBittorrent is not installed in /Applications."
            return 2
        fi
        INSTALL_PATH="$APP_DIR"
        INSTALL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist" 2>/dev/null || true)"
        INSTALL_VERSION="${INSTALL_VERSION// /}"
        VARIANT=""
    else
        local candidate
        for candidate in \
            "$HOME/Applications/qbittorrent"*.AppImage \
            "$HOME/.local/bin/qbittorrent"*.AppImage \
            "$HOME/bin/qbittorrent"*.AppImage \
            "/opt/qbittorrent"*.AppImage \
            "$HOME/Desktop/qbittorrent"*.AppImage \
            "$HOME/Downloads/qbittorrent"*.AppImage; do
            if [[ -f "$candidate" ]]; then
                INSTALL_PATH="$candidate"
                break
            fi
        done
        if [[ -z "$INSTALL_PATH" ]]; then
            if command -v qbittorrent >/dev/null 2>&1; then
                log ERROR "qBittorrent is installed from distribution packages; this tool updates the official AppImage only."
            else
                log ERROR "qBittorrent AppImage not found."
            fi
            return 2
        fi
        local name
        name="$(basename "$INSTALL_PATH")"
        INSTALL_VERSION=""
        if [[ "$name" =~ ^qbittorrent-([0-9][0-9.]*) ]]; then
            INSTALL_VERSION="${BASH_REMATCH[1]}"
        fi
        if [[ "$name" == *_lt12* ]]; then
            VARIANT="_lt12"
        else
            VARIANT=""
        fi
    fi
    if pgrep -x qbittorrent >/dev/null 2>&1; then
        RUNNING="yes"
    fi
    return 0
}

fetch_latest() {
    local tmp
    tmp="$(mktemp)"
    if ! curl -fsSL --max-time 30 -H 'Accept: application/vnd.github+json' \
        'https://api.github.com/repos/qbittorrent/qBittorrent/releases/latest' -o "$tmp"; then
        rm -f "$tmp"
        log ERROR 'Cannot reach GitHub to determine the latest version.'
        return 3
    fi
    if command -v python3 >/dev/null 2>&1; then
        if ! python3 - "$tmp" > "$tmp.out" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
print(d.get("tag_name", ""))
for a in d.get("assets", []):
    dig = a.get("digest") or ""
    if dig.startswith("sha256:"):
        print(a["name"] + "\t" + dig.split("sha256:", 1)[1].lower())
PYEOF
        then
            rm -f "$tmp" "$tmp.out"
            log ERROR 'Cannot parse the GitHub API response.'
            return 3
        fi
    elif command -v jq >/dev/null 2>&1; then
        if ! jq -r '.tag_name, (.assets[]? | select(.digest != null and (.digest | startswith("sha256:"))) | (.name + "\t" + (.digest | ltrimstr("sha256:"))))' \
            "$tmp" > "$tmp.out"; then
            rm -f "$tmp" "$tmp.out"
            log ERROR 'Cannot parse the GitHub API response.'
            return 3
        fi
    else
        rm -f "$tmp"
        log ERROR 'python3 or jq is required to verify checksums; update refused.'
        return 3
    fi
    rm -f "$tmp"
    LATEST_TAG="$(head -n 1 "$tmp.out")"
    tail -n +2 "$tmp.out" > "$tmp.digests"
    rm -f "$tmp.out"
    LATEST_VERSION="${LATEST_TAG#release-}"
    if [[ ! "$LATEST_VERSION" =~ ^[0-9] ]]; then
        log ERROR 'Cannot parse the latest version.'
        return 3
    fi
    DIGESTS_FILE="$tmp.digests"
    log DEBUG "GitHub API: latest $LATEST_VERSION"
    return 0
}

pre_rank() {
    case "$1" in
        *rc*) echo 2 ;;
        *beta*) echo 1 ;;
        *alpha*|*dev*) echo 0 ;;
        *) echo 3 ;;
    esac
}

pre_num() {
    if [[ "$1" =~ ([0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo 0
    fi
}

version_lt() {
    local a_core b_core
    a_core="${1%%[a-zA-Z]*}"
    b_core="${2%%[a-zA-Z]*}"
    if [[ "$a_core" != "$b_core" ]]; then
        local -a A B
        IFS=. read -r -a A <<< "$a_core"
        IFS=. read -r -a B <<< "$b_core"
        local i x y
        for i in 0 1 2 3; do
            x="${A[i]:-0}"
            y="${B[i]:-0}"
            if (( x < y )); then return 0; fi
            if (( x > y )); then return 1; fi
        done
        return 1
    fi
    local ar br an bn
    ar="$(pre_rank "$1")"
    br="$(pre_rank "$2")"
    if (( ar < br )); then return 0; fi
    if (( ar > br )); then return 1; fi
    an="$(pre_num "$1")"
    bn="$(pre_num "$2")"
    if (( an < bn )); then return 0; fi
    return 1
}

choose_asset() {
    local prefix="qbittorrent-${LATEST_VERSION}"
    local -a names
    if [[ "$PLATFORM" == "macos" ]]; then
        names=("${prefix}.dmg" "${prefix}_lt20.dmg")
    else
        if [[ "$(uname -m)" != "x86_64" ]]; then
            log ERROR 'Official Linux AppImages are published for x86_64 only; update refused.'
            return 9
        fi
        if [[ "$VARIANT" == "_lt12" ]]; then
            names=("${prefix}_lt12_x86_64.AppImage")
        else
            names=("${prefix}_x86_64.AppImage" "${prefix}_lt20_x86_64.AppImage")
        fi
    fi
    ASSET_NAME=""
    ASSET_DIGEST=""
    local n d
    for n in "${names[@]}"; do
        d="$(awk -F '\t' -v name="$n" '$1 == name { print $2; exit }' "$DIGESTS_FILE")"
        if [[ -n "$d" ]]; then
            ASSET_NAME="$n"
            ASSET_DIGEST="$d"
            break
        fi
    done
    if [[ -z "$ASSET_NAME" ]]; then
        if [[ "$PLATFORM" == "macos" ]] && ! grep -q '\.dmg' "$DIGESTS_FILE"; then
            log ERROR 'The official release does not include a macOS installer (.dmg); nothing can be installed.'
            return 10
        fi
        log ERROR 'No trusted SHA-256 digest for the installer; refusing to run an unverified file.'
        return 9
    fi
    log INFO "Installer: $ASSET_NAME"
    return 0
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{ print $1 }'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{ print $1 }'
    else
        log ERROR 'sha256sum or shasum is required to verify checksums.'
        return 1
    fi
}

stop_app() {
    pgrep -x qbittorrent >/dev/null 2>&1 || return 0
    log INFO 'Closing qBittorrent...'
    if [[ "$PLATFORM" == "macos" ]]; then
        osascript -e 'tell application "qBittorrent" to quit' >/dev/null 2>&1 || true
    else
        pkill -15 -x qbittorrent 2>/dev/null || true
    fi
    local waited=0
    while pgrep -x qbittorrent >/dev/null 2>&1; do
        sleep 2
        waited=$((waited + 2))
        if (( waited >= 25 )); then
            log WARN 'Closing timed out, forcing termination.'
            pkill -9 -x qbittorrent 2>/dev/null || true
            sleep 2
            break
        fi
    done
    if pgrep -x qbittorrent >/dev/null 2>&1; then
        log ERROR 'qBittorrent could not be closed.'
        return 1
    fi
    log INFO 'qBittorrent closed.'
    return 0
}

start_app() {
    if [[ "$PLATFORM" == "macos" ]]; then
        open "$APP_DIR" >/dev/null 2>&1 || true
    else
        nohup "$INSTALL_PATH" >/dev/null 2>&1 & disown || true
    fi
    log INFO 'qBittorrent started.'
}

disable_popup() {
    if [[ ! -f "$INI_FILE" ]]; then
        log WARN "qBittorrent.ini not found at $INI_FILE"
        return 1
    fi
    local tmp
    tmp="$(mktemp)"
    if grep -q '^Advanced\\updateCheck=' "$INI_FILE"; then
        awk '{ if ($0 ~ /^Advanced\\updateCheck=/) print "Advanced\\updateCheck=false"; else print }' "$INI_FILE" > "$tmp"
    elif grep -q '^\[Preferences\]' "$INI_FILE"; then
        awk '!done && $0 ~ /^\[Preferences\]/ { print; print "Advanced\\updateCheck=false"; done = 1; next } { print }' "$INI_FILE" > "$tmp"
    else
        { cat "$INI_FILE"; echo ""; echo "[Preferences]"; echo "Advanced\\updateCheck=false"; } > "$tmp"
    fi
    mv "$tmp" "$INI_FILE"
    log INFO 'Update popup disabled (Advanced\updateCheck=false).'
    return 0
}

perform_update() {
    local tmp
    tmp="$(mktemp -d)"
    local file="$tmp/installer"
    log INFO 'Downloading...'
    if ! curl -fsSL --max-time 600 -o "$file" \
        "https://github.com/qbittorrent/qBittorrent/releases/download/$LATEST_TAG/$ASSET_NAME"; then
        log ERROR 'Download failed.'
        rm -rf "$tmp"
        return 7
    fi
    local hash
    hash="$(sha256_of "$file")" || { rm -rf "$tmp"; return 7; }
    if [[ "$hash" != "$ASSET_DIGEST" ]]; then
        log ERROR "Checksum mismatch: expected $ASSET_DIGEST, got $hash"
        rm -rf "$tmp"
        return 7
    fi
    log INFO 'Checksum verified.'
    log INFO 'Installing...'
    if [[ "$PLATFORM" == "macos" ]]; then
        local mnt="$tmp/mnt" staged="$mnt/qBittorrent.app"
        mkdir -p "$mnt"
        if ! hdiutil attach "$file" -nobrowse -quiet -mountpoint "$mnt"; then
            log ERROR 'Cannot mount the downloaded disk image.'
            rm -rf "$tmp"
            return 7
        fi
        if [[ ! -d "$staged" ]]; then
            log ERROR 'The disk image does not contain qBittorrent.app.'
            hdiutil detach "$mnt" -quiet || true
            rm -rf "$tmp"
            return 7
        fi
        local newver
        newver="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$staged/Contents/Info.plist" 2>/dev/null || true)"
        if [[ "$newver" != "$LATEST_VERSION" ]]; then
            log ERROR "The downloaded app reports version ${newver:-unknown} (expected $LATEST_VERSION)."
            hdiutil detach "$mnt" -quiet || true
            rm -rf "$tmp"
            return 8
        fi
        local backup="$APP_DIR.backup-$$"
        local had_old=0
        if [[ -d "$APP_DIR" ]]; then
            if ! mv "$APP_DIR" "$backup"; then
                log ERROR 'Cannot move the current qBittorrent.app aside.'
                hdiutil detach "$mnt" -quiet || true
                rm -rf "$tmp"
                return 7
            fi
            had_old=1
        fi
        if ! ditto "$staged" "$APP_DIR"; then
            if [[ "$had_old" == "1" ]]; then
                rm -rf "$APP_DIR"
                mv "$backup" "$APP_DIR"
                log ERROR 'Cannot install the new version; your previous qBittorrent.app was restored.'
            else
                log ERROR 'Cannot install the new version.'
            fi
            hdiutil detach "$mnt" -quiet || true
            rm -rf "$tmp"
            return 7
        fi
        rm -rf "$backup"
        xattr -dr com.apple.quarantine "$APP_DIR" 2>/dev/null || true
        hdiutil detach "$mnt" -quiet || true
    else
        if ! install -m 755 "$file" "$INSTALL_PATH"; then
            log ERROR "Cannot replace $INSTALL_PATH."
            rm -rf "$tmp"
            return 7
        fi
    fi
    rm -rf "$tmp"
    mkdir -p "$INSTALL_DIR"
    echo "$LATEST_VERSION" > "$STATE_FILE" 2>/dev/null || true
    log INFO "Updated to $LATEST_VERSION."
    return 0
}

install_task() {
    mkdir -p "$INSTALL_DIR"
    cp "$SELF" "$INSTALL_DIR/qbt-updater.sh"
    chmod 755 "$INSTALL_DIR/qbt-updater.sh"
    if [[ "$PLATFORM" == "macos" ]]; then
        local plist="$HOME/Library/LaunchAgents/com.qbittorrent.autoupdater.plist"
        cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.qbittorrent.autoupdater</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$INSTALL_DIR/qbt-updater.sh</string>
        <string>update</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF
        launchctl unload "$plist" 2>/dev/null || true
        launchctl load "$plist"
        log INFO "LaunchAgent installed: qBittorrent is updated at every sign-in, from $INSTALL_DIR."
    else
        mkdir -p "$HOME/.config/autostart"
        cat > "$HOME/.config/autostart/qbittorrent-auto-updater.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=qBittorrent Auto Updater
Exec="$INSTALL_DIR/qbt-updater.sh" update
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
        log INFO "Autostart entry installed: qBittorrent is updated at every sign-in, from $INSTALL_DIR."
    fi
}

cmd_install() {
    detect_install
    install_task
    local was_running="$RUNNING" stopped=1
    if [[ "$was_running" == "yes" ]]; then
        if stop_app; then
            stopped=0
        fi
    fi
    if [[ "$stopped" == "0" ]]; then
        if disable_popup; then
            log INFO 'Setup complete. The client is updated automatically every time you sign in.'
        else
            log WARN 'Setup finished, but the update popup could not be disabled.'
        fi
        if [[ "$was_running" == "yes" ]]; then
            start_app
        fi
    else
        log WARN 'qBittorrent could not be closed; the update popup was left unchanged.'
        EXIT_CODE=6
    fi
    return 0
}

cmd_hide_popup() {
    detect_install
    local was_running="$RUNNING"
    if [[ "$was_running" == "yes" ]]; then
        if ! stop_app; then
            EXIT_CODE=6
            return 0
        fi
    fi
    if disable_popup; then
        log INFO 'Update popup disabled. Auto-update is not set up.'
    else
        EXIT_CODE=4
    fi
    if [[ "$was_running" == "yes" ]]; then
        start_app
    fi
    return 0
}

cmd_update() {
    detect_install
    fetch_latest
    log INFO "Latest:    $LATEST_VERSION"
    if [[ -n "$INSTALL_VERSION" ]] && ! version_lt "$INSTALL_VERSION" "$LATEST_VERSION"; then
        log INFO "Already up to date ($INSTALL_VERSION)."
        exit 0
    fi
    log INFO "Installed: ${INSTALL_VERSION:-unknown} ($INSTALL_PATH)"
    choose_asset
    if ! stop_app; then
        exit 6
    fi
    local update_code=0
    perform_update || update_code=$?
    if [[ "$RUNNING" == "yes" ]]; then
        start_app
    fi
    exit "$update_code"
}

if [[ "${QBT_SKIP_MAIN:-0}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi

case "$COMMAND" in
    install)
        cmd_install
        ;;
    hide-popup)
        cmd_hide_popup
        ;;
    update)
        cmd_update
        ;;
    *)
        usage
        exit 1
        ;;
esac

exit "$EXIT_CODE"
