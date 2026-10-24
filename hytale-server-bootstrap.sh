#!/usr/bin/env bash
# =============================================================================
# Hytale Server Bootstrap — Linux (Docker) + macOS (native) edition
#
# The script detects the host OS and picks the right runtime:
#
# Linux (CachyOS / Arch, x86_64):
#   1. Installs missing dependencies via pacman (docker, wget, unzip, ufw)
#   2. Ensures Docker daemon is running (systemd)
#   3. Downloads the official Hytale Downloader from downloader.hytale.com
#   4. Runs it interactively — you authenticate with your Hytale account
#   5. Extracts Server/ + Assets.zip + start.sh from the versioned archive
#   6. Writes Dockerfile, docker-compose.yml, docker-entrypoint.sh, jvm.options,
#      .dockerignore and .gitignore
#   7. Configures UFW: enables it and opens UDP 5520 (Hytale) + 22 (SSH)
#   8. Builds the Docker image and starts the server in the background
#   9. Prints instructions for server auth, connecting and copying the folder
#
# macOS (Apple Silicon or Intel):
#   1. Reuses Server/, Assets.zip and start.sh (copy them from the Linux
#      machine, the Hytale launcher, or a JAR bootstrap install)
#   2. Finds Java 25 or downloads Temurin 25 into .jdk/
#   3. Links Server/universe, Server/backups and auth files to data/
#   4. Tunes jvm.options for the Mac's RAM
#   5. Starts the server natively (no Docker/Rosetta) in a screen session
#
# Requirements:
#   - Linux: CachyOS or any Arch-based distro on x86_64, sudo access
#   - macOS: macOS 13+, Java 25 (auto-downloaded on first run)
#   - A Hytale account that owns the game (Standard Edition or higher)
#
# Usage:
#   chmod +x hytale-server-bootstrap.sh && ./hytale-server-bootstrap.sh
#
# Flags:
#   --upgrade   Linux: download the latest Hytale build, rebuild and restart.
#               macOS: print Hytale's built-in /update steps (the official
#               downloader has no macOS build).
#   --stop      Stop the running server (Docker on Linux, screen on macOS).
#   --no-ufw    Linux only: do not modify firewall rules.
# =============================================================================

set -euo pipefail

# ── Platform detection ────────────────────────────────────────────────────────
OS_NAME="$(uname -s)"
ARCH="$(uname -m)"
case "$OS_NAME" in
    Linux)  PLATFORM="linux" ;;
    Darwin) PLATFORM="macos" ;;
    *)      echo "Unsupported operating system: $OS_NAME" >&2; exit 1 ;;
esac

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
BLU='\033[0;34m'
CYN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${BLU}[INFO]${NC}  $*"; }
ok()    { echo -e "${GRN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YLW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERR ]${NC}  $*" >&2; exit 1; }
step()  { echo -e "\n${CYN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${CYN}  $*${NC}"; echo -e "${CYN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; }

usage() {
    cat << EOF
Usage: $0 [--upgrade] [--stop] [--no-ufw]

  (no flags)  Install or repair the server and start it.
  --upgrade   Linux: download the latest Hytale build, rebuild and restart.
              macOS: print Hytale's built-in /update steps.
  --stop      Stop the running server.
  --no-ufw    Linux only: leave firewall rules untouched.
  -h, --help  Show this help.

Detected platform: $PLATFORM ($ARCH)
EOF
}

# ── Flags ─────────────────────────────────────────────────────────────────────
UPGRADE=false
STOP=false
SKIP_UFW=false
for arg in "$@"; do
    case "$arg" in
        --upgrade) UPGRADE=true ;;
        --stop)    STOP=true ;;
        --no-ufw)  SKIP_UFW=true ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "Unknown argument: $arg" ;;
    esac
done

# ── Config ────────────────────────────────────────────────────────────────────
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

DOWNLOADER_URL="https://downloader.hytale.com/hytale-downloader.zip"
DOWNLOADER_ZIP="hytale-downloader.zip"
DOWNLOADER_BIN="hytale-downloader-linux-amd64"
CREDENTIALS_FILE="$PROJECT_DIR/.hytale-downloader-credentials.json"
HYTALE_PORT="5520"
DATA_DIR="$PROJECT_DIR/data"
STAGING_DIR="$PROJECT_DIR/.hytale-staging"
CONTAINER_NAME="hytale-server"
SCREEN_NAME="hytale"

# Linux/Docker JVM heap — adjust to your machine. Hytale requires at least 4 GB.
JVM_XMS="3g"
JVM_XMX="6g"

# macOS native JVM heap. The script lowers this automatically on 8 GB Macs.
MAC_JVM_XMS="1g"
MAC_JVM_XMX="4g"

if [[ $EUID -eq 0 ]]; then
    SUDO=()
else
    SUDO=(sudo)
fi
run_sudo() { "${SUDO[@]}" "$@"; }

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLU}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [[ "$PLATFORM" == "macos" ]]; then
    echo -e "${BLU}  Hytale Server Bootstrap · macOS native edition${NC}"
else
    echo -e "${BLU}  Hytale Server Bootstrap · Linux / Docker edition${NC}"
fi
echo -e "${BLU}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ── Helper: write a managed file, backing up user changes ─────────────────────
backup_and_write() {
    local path="$1"
    local content="$2"

    if [[ -f "$path" ]] && cmp -s <(printf '%s\n' "$content") "$path"; then
        return 0
    fi

    if [[ -f "$path" ]]; then
        local backup="${path}.bak.$(date +%Y%m%d-%H%M%S)"
        cp -p "$path" "$backup" 2>/dev/null || true
        warn "Updated $path (previous version: $(basename "$backup"))"
    fi

    if ! printf '%s\n' "$content" > "$path" 2>/dev/null; then
        printf '%s\n' "$content" | run_sudo tee "$path" >/dev/null
    fi
}

# ── macOS helpers ─────────────────────────────────────────────────────────────
# The Mac build of Hytale is a normal Java application: HytaleServer.jar ships
# native/osx-arm64 libraries, so no Docker, Rosetta or QEMU is needed.
macos_total_ram_gb() {
    local bytes
    bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
    if [[ "$bytes" =~ ^[0-9]+$ ]] && (( bytes > 0 )); then
        echo $(( bytes / 1024 / 1024 / 1024 ))
    else
        echo 0
    fi
}

macos_jvm_content() {
    local ram_gb="${1:-0}"
    cat << EOF
# Hytale server JVM options (macOS).
# Loaded automatically by start.sh — one argument per line.
# Lines starting with # are comments.
#
# Tuned for a ${ram_gb} GB Mac. Leave memory for macOS and the GPU.
# Raise -Xmx only if you have more RAM and a larger view distance.
-Xms${MAC_JVM_XMS}
-Xmx${MAC_JVM_XMX}

# G1 is a good fit for a small heap on Apple Silicon.
-XX:+UseG1GC
EOF
}

macos_find_java() {
    local candidate version
    if [[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/java" ]]; then
        candidate="$JAVA_HOME/bin/java"
        version="$("$candidate" -version 2>&1 | head -n1 || true)"
        if [[ "$version" == *'version "25'* ]]; then
            echo "$candidate"
            return 0
        fi
    fi
    for candidate in \
        "$PROJECT_DIR/.jdk/Contents/Home/bin/java" \
        "/Library/Java/JavaVirtualMachines/temurin-25.jdk/Contents/Home/bin/java" \
        "/opt/homebrew/opt/openjdk@25/bin/java" \
        "/usr/local/opt/openjdk@25/bin/java"; do
        [[ -x "$candidate" ]] || continue
        version="$("$candidate" -version 2>&1 | head -n1 || true)"
        if [[ "$version" == *'version "25'* ]]; then
            echo "$candidate"
            return 0
        fi
    done
    if command -v java >/dev/null 2>&1; then
        candidate="$(command -v java)"
        version="$("$candidate" -version 2>&1 | head -n1 || true)"
        if [[ "$version" == *'version "25'* ]]; then
            echo "$candidate"
            return 0
        fi
    fi
    return 1
}

macos_download_java() {
    local arch adt_arch tmp java_bin downloaded=false candidate
    arch="$(uname -m)"
    case "$arch" in
        arm64)  adt_arch="aarch64" ;;
        x86_64) adt_arch="x64" ;;
        *) die "Unsupported macOS architecture: $arch" ;;
    esac

    tmp=""
    for candidate in "$PROJECT_DIR"/OpenJDK25U-jdk_*_mac_hotspot_*.tar.gz "$PROJECT_DIR"/temurin25-mac-*.tar.gz; do
        if [[ -f "$candidate" ]]; then
            tmp="$candidate"
            break
        fi
    done

    if [[ -n "$tmp" ]]; then
        info "Using local Java archive: $(basename "$tmp")" >&2
    else
        info "Java 25 not found. Downloading Temurin 25 for macOS ${arch}..." >&2
        tmp="$PROJECT_DIR/.jdk-download.tar.gz"
        downloaded=true
        if ! curl -fL --progress-bar -o "$tmp" \
            "https://api.adoptium.net/v3/binary/latest/25/ga/mac/${adt_arch}/jdk/hotspot/normal/eclipse"; then
            rm -f "$tmp"
            die "Could not download Java 25. Install Temurin 25 manually or copy a .jdk folder into $PROJECT_DIR."
        fi
    fi

    rm -rf "$PROJECT_DIR/.jdk"
    mkdir -p "$PROJECT_DIR/.jdk"
    if ! tar -xzf "$tmp" -C "$PROJECT_DIR/.jdk" --strip-components=1; then
        if [[ "$downloaded" == true ]]; then rm -f "$tmp"; fi
        die "Could not extract Java 25."
    fi
    if [[ "$downloaded" == true ]]; then rm -f "$tmp"; fi
    xattr -dr com.apple.quarantine "$PROJECT_DIR/.jdk" 2>/dev/null || true

    java_bin="$PROJECT_DIR/.jdk/Contents/Home/bin/java"
    [[ -x "$java_bin" ]] || die "Java extraction did not produce $java_bin."
    echo "$java_bin"
}

macos_link_dir() {
    local link="$1" target="$2" current
    if [[ -L "$link" ]]; then
        current="$(readlink "$link")"
        if [[ "$current" == "$target" ]]; then
            ok "$link -> $target"
            return 0
        fi
        warn "Replacing $link (was -> $current)"
        rm -f "$link"
    elif [[ -e "$link" ]]; then
        if [[ -d "$link" && -z "$(ls -A "$link" 2>/dev/null)" ]]; then
            rmdir "$link"
        else
            warn "$link exists and is not a symlink; leaving it untouched."
            warn "Move its contents into $target if you want data/ to be authoritative."
            return 1
        fi
    fi
    ln -s "$target" "$link"
    ok "$link -> $target"
}

macos_link_auth_file() {
    local name="$1" link="Server/$1" target="../data/auth/$1" data_file="$DATA_DIR/auth/$1"
    if [[ -L "$link" ]]; then
        rm -f "$link"
    elif [[ -e "$link" ]]; then
        if [[ ! -s "$data_file" ]]; then
            mv "$link" "$data_file"
            chmod 600 "$data_file"
            ok "Moved Server/$name into data/auth/."
        else
            local backup="$link.bak.$(date +%Y%m%d-%H%M%S)"
            mv "$link" "$backup"
            warn "Server/$name and data/auth/$name both exist; kept the latter."
            warn "Previous file saved as $(basename "$backup")."
        fi
    fi
    ln -s "$target" "$link"
    ok "$link -> $target"
}

macos_prepare_jvm_options() {
    local ram_gb xmx
    ram_gb="$(macos_total_ram_gb)"
    if [[ ! -f "jvm.options" ]]; then
        backup_and_write "jvm.options" "$(macos_jvm_content "$ram_gb")"
        ok "jvm.options written for ${ram_gb} GB RAM (${MAC_JVM_XMS}-${MAC_JVM_XMX}, G1)."
        return 0
    fi

    xmx="$(grep -E '^-Xmx' "jvm.options" | tail -n1 | sed 's/^-Xmx//' || true)"
    if grep -q "Hytale server JVM options" "jvm.options" && (( ram_gb > 0 && ram_gb <= 10 )); then
        if grep -qE '^-Xmx([6-9]|[1-9][0-9]+)g' "jvm.options"; then
            backup_and_write "jvm.options" "$(macos_jvm_content "$ram_gb")"
            warn "Adjusted jvm.options for ${ram_gb} GB RAM (was -Xmx${xmx}; set to ${MAC_JVM_XMX}, G1)."
        else
            ok "jvm.options already suitable for ${ram_gb} GB RAM (-Xmx${xmx:-unknown})."
        fi
    else
        warn "jvm.options exists; preserving custom settings (-Xmx${xmx:-unknown})."
        if (( ram_gb > 0 && ram_gb <= 10 )) && [[ "$xmx" =~ ^([6-9]|[1-9][0-9]+)g$ ]]; then
            warn "This Mac has ${ram_gb} GB RAM; -Xmx${xmx} may be too large."
        fi
    fi
}

macos_ensure_gitignore() {
    local patterns=(".jdk/" ".jdk-download.tar.gz" "screenlog.*")
    local pattern changed=false
    for pattern in "${patterns[@]}"; do
        if ! grep -qxF "$pattern" ".gitignore" 2>/dev/null; then
            if [[ "$changed" == false ]]; then
                printf '\n# macOS native runtime\n' >> ".gitignore"
                changed=true
            fi
            printf '%s\n' "$pattern" >> ".gitignore"
        fi
    done
    if [[ "$changed" == true ]]; then
        ok "Added macOS runtime files to .gitignore."
    fi
    return 0
}

macos_server_running() {
    pgrep -f '[H]ytaleServer.jar' >/dev/null 2>&1
}

macos_stop() {
    local i
    if ! macos_server_running; then
        ok "Hytale server is not running."
        screen -wipe >/dev/null 2>&1 || true
        return 0
    fi
    info "Stopping Hytale server..."
    if screen -ls 2>/dev/null | grep -q "[.]${SCREEN_NAME}[[:space:]]"; then
        screen -S "$SCREEN_NAME" -p 0 -X stuff $'/stop\n' 2>/dev/null || true
        for i in $(seq 1 10); do
            if ! macos_server_running; then break; fi
            sleep 1
        done
    fi
    if macos_server_running; then
        info "Console stop was not accepted; sending SIGTERM so the server can save."
        pkill -TERM -f '[H]ytaleServer.jar' 2>/dev/null || true
        for i in $(seq 1 15); do
            if ! macos_server_running; then break; fi
            sleep 1
        done
    fi
    if macos_server_running; then
        warn "Server still running; sending SIGKILL."
        pkill -KILL -f '[H]ytaleServer.jar' 2>/dev/null || true
        sleep 1
    fi
    screen -S "$SCREEN_NAME" -X quit 2>/dev/null || true
    screen -wipe >/dev/null 2>&1 || true
    ok "Server stopped."
}

macos_start() {
    local java_bin="$1" log_file="$DATA_DIR/server.log" i
    mkdir -p "$DATA_DIR"
    screen -wipe >/dev/null 2>&1 || true
    if macos_server_running; then
        ok "Hytale server is already running."
        return 0
    fi
    : > "$log_file"
    info "Starting Hytale server in screen session '$SCREEN_NAME'..."
    screen -dmS "$SCREEN_NAME" bash -c "cd '$PROJECT_DIR' && export JAVA_HOME='$JAVA_HOME' && export PATH='$JAVA_HOME/bin':\$PATH && exec script -q '$log_file' ./start.sh"
    for i in $(seq 1 15); do
        if macos_server_running; then break; fi
        sleep 1
    done
    if ! macos_server_running; then
        warn "Server process exited immediately. Last log lines:"
        tail -n 80 "$log_file" 2>/dev/null || true
        die "Server failed to start."
    fi
    ok "Server process started (PID(s): $(pgrep -f '[H]ytaleServer.jar' | tr '\n' ' ' || true))."
}

macos_main() {
    step "macOS native mode"
    ok "macOS $(sw_vers -productVersion) on $(uname -m)"

    if [[ "$STOP" == true ]]; then
        macos_stop
        exit 0
    fi

    if [[ "$UPGRADE" == true ]]; then
        step "Upgrade on macOS"
        warn "The official Hytale downloader has no macOS build."
        if macos_server_running; then
            info "Sending /update check to the running server..."
            screen -S "$SCREEN_NAME" -p 0 -X stuff $'/update check\n' 2>/dev/null || true
            echo "  Watch: tail -f data/server.log"
            echo "  Then attach and run: screen -r $SCREEN_NAME"
        else
            echo "  Start the server first: ./$(basename "$0")"
            echo "  Then attach and run: screen -r $SCREEN_NAME"
        fi
        echo ""
        echo "  /update download"
        echo "  /update apply --confirm"
        echo ""
        echo "  The start.sh wrapper applies the staged update and restarts."
        return 0
    fi

    if [[ ! -f "Server/HytaleServer.jar" ]]; then
        die "Server/HytaleServer.jar not found. Copy Server/, Assets.zip and start.sh from the Linux installation (the official downloader is Linux/Windows-only), or from the Hytale launcher."
    fi
    if [[ ! -f "Assets.zip" ]]; then
        die "Assets.zip not found. Copy it from the Linux installation or the Hytale launcher."
    fi
    if [[ ! -f "start.sh" ]]; then
        die "start.sh not found. Copy it from the Linux installation, or run /update setup on a server console."
    fi
    chmod +x "start.sh"

    local java_bin java_home version
    if java_bin="$(macos_find_java)"; then
        ok "Java 25 found: $java_bin"
    else
        java_bin="$(macos_download_java)"
        ok "Java 25 installed under .jdk/."
    fi
    java_home="$(cd "$(dirname "$java_bin")/.." && pwd)"
    export JAVA_HOME="$java_home"
    export PATH="$JAVA_HOME/bin:$PATH"
    version="$("$java_bin" -version 2>&1 | head -n1)"
    ok "$version"

    step "Preparing persistent data"
    mkdir -p "$DATA_DIR/universe" "$DATA_DIR/backups" "$DATA_DIR/auth"
    for auth_file in auth.key auth.enc; do
        if [[ ! -e "$DATA_DIR/auth/$auth_file" ]]; then
            : > "$DATA_DIR/auth/$auth_file"
        fi
    done
    chmod 700 "$DATA_DIR/auth"
    chmod 600 "$DATA_DIR/auth/auth.key" "$DATA_DIR/auth/auth.enc"

    macos_link_dir "Server/universe" "../data/universe" \
        || die "Server/universe is a real directory. Merge it into data/universe or move it aside, then re-run."
    macos_link_dir "Server/backups" "../data/backups" \
        || warn "Using existing Server/backups (data/backups is not linked)."
    macos_link_auth_file "auth.key"
    macos_link_auth_file "auth.enc"

    echo "  World:      data/universe"
    echo "  Backups:    data/backups"
    echo "  Auth files: data/auth  ← never commit this folder"

    macos_prepare_jvm_options
    macos_ensure_gitignore

    step "Starting Hytale Server"
    macos_start "$java_bin"

    info "Waiting for the server to finish booting..."
    local booted=false auth_ready=false i
    for i in $(seq 1 90); do
        if grep -q "Hytale Server Booted!" "$DATA_DIR/server.log" 2>/dev/null; then
            booted=true
            break
        fi
        if ! macos_server_running; then
            warn "Server stopped unexpectedly. Last log lines:"
            tail -n 80 "$DATA_DIR/server.log" 2>/dev/null || true
            die "Server failed to start."
        fi
        sleep 2
    done
    if [[ "$booted" == true ]]; then
        ok "Server booted."
    else
        warn "Boot message not seen yet — check: tail -f data/server.log"
    fi

    sleep 3
    if grep -q "Authentication successful" "$DATA_DIR/server.log" 2>/dev/null; then
        auth_ready=true
    fi

    local lan_ip
    lan_ip="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
    if [[ -z "$lan_ip" ]]; then
        lan_ip="$(ifconfig 2>/dev/null | awk '/inet / && $2 != "127.0.0.1" {print $2; exit}')"
    fi
    if [[ -z "$lan_ip" ]]; then
        lan_ip="<your-lan-ip>"
    fi

    step "Server is running (macOS native)"
    if [[ "$auth_ready" == false ]]; then
        echo -e "  ${YLW}ONE-TIME SERVER AUTHORIZATION${NC}"
        echo ""
        echo "  The server needs its own token before players can connect."
        echo "  Attach to its console:"
        echo ""
        echo -e "    ${GRN}screen -r ${SCREEN_NAME}${NC}"
        echo ""
        echo "  Then type:"
        echo ""
        echo -e "    ${GRN}/auth login device${NC}"
        echo ""
        echo "  Open the URL it prints, approve the code, then detach WITHOUT"
        echo "  stopping the server:"
        echo ""
        echo -e "    ${GRN}Ctrl+A${NC} then ${GRN}D${NC}"
        echo ""
        echo "  The token is saved in data/auth/ and survives restarts and copies."
        echo ""
    else
        echo -e "  ${GRN}Server authorization is already configured.${NC}"
        echo ""
    fi

    echo -e "  ${YLW}CONNECT${NC}"
    echo -e "    LAN:          ${GRN}${lan_ip}:${HYTALE_PORT}${NC}"
    echo -e "    This machine: ${GRN}127.0.0.1:${HYTALE_PORT}${NC}"
    echo ""

    echo -e "  ${YLW}COMMON COMMANDS${NC}"
    echo "    Live logs:       tail -f data/server.log"
    echo "    Attach console:  screen -r ${SCREEN_NAME}"
    echo "    Detach:          Ctrl+A then D"
    echo "    Stop:            ./$(basename "$0") --stop"
    echo "    Start:           ./$(basename "$0")"
    echo "    Upgrade:         /update check, /update download, /update apply --confirm"
    echo ""

    echo -e "  ${YLW}macOS NOTES${NC}"
    echo "    HytaleServer.jar contains native/osx-arm64 libraries. The server is"
    echo "    running natively — no Docker, Rosetta or QEMU is involved."
    echo "    The official Hytale downloader has no macOS build; keep the server"
    echo "    files updated via the /update commands or copy them from Linux."
    echo "    Allow incoming UDP ${HYTALE_PORT} if the macOS firewall prompts."
    echo "    Keep the Mac awake (System Settings → Energy) so the server stays up."
    echo ""

    echo -e "  ${YLW}SECURITY${NC}"
    echo "    Never commit .hytale-downloader-credentials.json or data/auth/."
    echo "    Both are already listed in .gitignore."
    echo ""
}

# ── Linux / Docker mode ───────────────────────────────────────────────────────
if [[ "$PLATFORM" == "linux" ]]; then

if [[ "$STOP" == true ]]; then
    step "Stopping Hytale Server"
    if command -v docker &>/dev/null; then
        docker compose down 2>/dev/null || docker stop "$CONTAINER_NAME" 2>/dev/null || true
    fi
    ok "Server stopped."
    exit 0
fi

# ── 0. Upgrade mode — stop the server; keep world and auth ───────────────────
if [[ "$UPGRADE" == true ]]; then
    step "Upgrade mode"
    if [[ -f "docker-compose.yml" ]]; then
        docker compose down 2>/dev/null || true
    else
        docker stop "$CONTAINER_NAME" 2>/dev/null || true
    fi
    ok "Server stopped. World data and auth token in data/ are untouched."
    echo ""
fi

# ── 1. Architecture guard ─────────────────────────────────────────────────────
ARCH="$(uname -m)"
[[ "$ARCH" == "x86_64" ]] \
    || die "This script requires x86_64. Detected: $ARCH"
ok "Architecture: x86_64"

# ── 2. Install missing dependencies via pacman ────────────────────────────────
info "Checking and installing dependencies..."

if [[ $EUID -ne 0 ]] && ! command -v sudo &>/dev/null; then
    die "sudo is required (or run this script as root)."
fi

PKGS_NEEDED=()

if ! command -v docker &>/dev/null; then
    PKGS_NEEDED+=(docker)
fi

if ! docker compose version &>/dev/null 2>&1; then
    PKGS_NEEDED+=(docker-compose)
fi

# docker-buildx is required by docker compose build
if ! docker buildx version &>/dev/null 2>&1; then
    PKGS_NEEDED+=(docker-buildx)
fi

for pkg in wget unzip ufw; do
    if ! command -v "$pkg" &>/dev/null; then
        PKGS_NEEDED+=("$pkg")
    fi
done

if [[ ${#PKGS_NEEDED[@]} -gt 0 ]]; then
    command -v pacman &>/dev/null \
        || die "Missing packages (${PKGS_NEEDED[*]}) and pacman is unavailable. This script targets Arch-based distros."
    info "Installing via pacman: ${PKGS_NEEDED[*]}"
    run_sudo pacman -Sy --needed --noconfirm "${PKGS_NEEDED[@]}" \
        || die "pacman install failed. Check your mirrors or run 'sudo pacman -Sy' manually."
    ok "Packages installed."

    # pacman -Sy may have pulled in a kernel update. If the running kernel
    # no longer matches the installed modules, Docker bridge/veth networking
    # will fail with "operation not supported" until the machine is rebooted.
    RUNNING_KERNEL="$(uname -r)"
    INSTALLED_KERNEL="$(ls -1t /lib/modules/ | head -n1)"
    if [[ "$RUNNING_KERNEL" != "$INSTALLED_KERNEL" ]]; then
        echo ""
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${RED}  REBOOT REQUIRED${NC}"
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo "  A kernel update was installed during dependency setup."
        echo "  Running kernel  : $RUNNING_KERNEL"
        echo "  Installed kernel: $INSTALLED_KERNEL"
        echo ""
        echo "  Docker bridge networking will fail until the new kernel is booted."
        echo "  Please reboot and re-run this script:"
        echo ""
        echo -e "    ${GRN}sudo reboot${NC}"
        echo ""
        exit 1
    fi
else
    ok "All dependencies already installed."
fi

docker compose version &>/dev/null     || die "Docker Compose plugin still not found after install. Try: sudo pacman -S docker-compose"
docker buildx version &>/dev/null     || die "docker-buildx not found after install. Try: sudo pacman -S docker-buildx"

# ── 3. Enable and start Docker ────────────────────────────────────────────────
info "Ensuring Docker daemon is running..."

if ! systemctl is-enabled --quiet docker; then
    run_sudo systemctl enable docker
    ok "Docker service enabled (will start on boot)."
fi

if ! systemctl is-active --quiet docker; then
    run_sudo systemctl start docker
    ok "Docker service started."
else
    ok "Docker is already running."
fi

if [[ $EUID -ne 0 ]] && ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
    run_sudo usermod -aG docker "$USER"
    warn "Added '$USER' to the docker group."
    warn "Re-execing script in docker group context — no logout needed."
    exec sg docker "$PROJECT_DIR/$(basename "${BASH_SOURCE[0]}")" "$@"
fi

ok "Docker ready."

# ── 4. Configure UFW ──────────────────────────────────────────────────────────
if [[ "$SKIP_UFW" == true ]]; then
    warn "Skipping firewall configuration (--no-ufw)."
elif ! command -v ufw &>/dev/null; then
    warn "ufw is not installed — skipping firewall configuration."
else
    info "Configuring UFW firewall..."

    if ! run_sudo ufw status | grep -q "Status: active"; then
        info "UFW is inactive — enabling it now."
        run_sudo ufw allow 22/tcp comment 'SSH' &>/dev/null
        run_sudo ufw --force enable
        ok "UFW enabled."
    else
        ok "UFW already active."
    fi

    if ! run_sudo ufw status | grep -q "22/tcp"; then
        run_sudo ufw allow 22/tcp comment 'SSH' &>/dev/null
        ok "UFW: SSH (TCP 22) allowed."
    fi

    if ! run_sudo ufw status | grep -q "${HYTALE_PORT}/udp"; then
        run_sudo ufw allow "${HYTALE_PORT}/udp" comment 'Hytale server' &>/dev/null
        ok "UFW: Hytale (UDP ${HYTALE_PORT}) allowed."
    else
        ok "UFW: Hytale UDP ${HYTALE_PORT} rule already present."
    fi

    echo ""
    info "Current UFW status:"
    run_sudo ufw status numbered | grep -E "Status|${HYTALE_PORT}|22" || true
    echo ""
fi

# ── 5. Download the official Hytale Downloader ────────────────────────────────
ensure_downloader() {
    if [[ -x "$DOWNLOADER_BIN" && "$UPGRADE" == false ]]; then
        ok "Downloader binary already present."
        return 0
    fi

    info "Fetching Hytale Downloader from official source..."
    local tmp="${DOWNLOADER_ZIP}.tmp"
    if ! wget -q --show-progress -O "$tmp" "$DOWNLOADER_URL"; then
        rm -f "$tmp"
        if [[ -x "$DOWNLOADER_BIN" ]]; then
            warn "Downloader update failed — using the existing binary."
            return 0
        fi
        return 1
    fi

    if ! unzip -qo "$tmp" "$DOWNLOADER_BIN" -d "$PROJECT_DIR"; then
        rm -f "$tmp"
        if [[ -x "$DOWNLOADER_BIN" ]]; then
            warn "Downloader archive could not be extracted — using the existing binary."
            return 0
        fi
        return 1
    fi

    rm -f "$tmp"
    chmod +x "$DOWNLOADER_BIN"
    ok "Downloader binary ready."
    return 0
}

# ── 6. Download and stage the server archive ─────────────────────────────────
download_server() {
    rm -rf "$STAGING_DIR"
    mkdir -p "$STAGING_DIR"
    local log="$STAGING_DIR/download.log"

    info "Downloading the latest Hytale server (this can take a while)..."
    local rc=0

    set +e
    ( cd "$STAGING_DIR" && "$PROJECT_DIR/$DOWNLOADER_BIN" -credentials-path "$CREDENTIALS_FILE" ) 2>&1 | tee "$log"
    rc=${PIPESTATUS[0]}
    set -e

    # The downloader stores an OAuth refresh token. If it expired, move the old
    # file aside and retry: the downloader then starts a fresh device login.
    if [[ $rc -ne 0 ]] && grep -qE 'invalid_grant|refresh token expired|authorization grant' "$log"; then
        warn "Saved Hytale downloader credentials expired."
        warn "Starting a fresh Hytale account login..."
        mv "$CREDENTIALS_FILE" "${CREDENTIALS_FILE}.expired.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
        rm -f "$STAGING_DIR"/*.zip
        set +e
        ( cd "$STAGING_DIR" && "$PROJECT_DIR/$DOWNLOADER_BIN" -credentials-path "$CREDENTIALS_FILE" ) 2>&1 | tee "$log"
        rc=${PIPESTATUS[0]}
        set -e
    fi

    if [[ $rc -ne 0 ]]; then
        warn "Hytale Downloader failed. Check the output above."
        return 1
    fi

    chmod 600 "$CREDENTIALS_FILE" 2>/dev/null || true

    local zip
    zip="$(find "$STAGING_DIR" -maxdepth 1 -type f -name '*.zip' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
    if [[ -z "$zip" ]]; then
        warn "No server archive was downloaded."
        return 1
    fi

    info "Extracting $(basename "$zip")..."
    local extract="$STAGING_DIR/extracted"
    rm -rf "$extract"
    mkdir -p "$extract"
    if ! unzip -qo "$zip" -d "$extract"; then
        warn "Extraction failed."
        return 1
    fi

    # Some archives contain a single top-level directory.
    local root="$extract"
    if [[ ! -d "$root/Server" ]]; then
        local candidate
        candidate="$(find "$extract" -mindepth 1 -maxdepth 1 -type d | head -n1)"
        if [[ -n "$candidate" && -d "$candidate/Server" ]]; then
            root="$candidate"
        fi
    fi

    if [[ ! -d "$root/Server" || ! -f "$root/Assets.zip" || ! -f "$root/start.sh" ]]; then
        warn "Downloaded archive is missing Server/, Assets.zip, or start.sh."
        return 1
    fi

    # Keep the old binaries until the new ones have been fully verified.
    rm -rf "$STAGING_DIR/old"
    mkdir -p "$STAGING_DIR/old"
    local item
    for item in Server Assets.zip start.sh start.bat; do
        [[ -e "$item" ]] && mv "$item" "$STAGING_DIR/old/"
    done

    if ! mv "$root/Server" . \
        || ! mv "$root/Assets.zip" . \
        || ! mv "$root/start.sh" .; then
        warn "Failed to install the new server files. Restoring previous files..."
        for item in Server Assets.zip start.sh start.bat; do
            if [[ -e "$STAGING_DIR/old/$item" ]]; then
                mv "$STAGING_DIR/old/$item" .
            fi
        done
        return 1
    fi

    if [[ -f "$root/start.bat" ]]; then
        mv "$root/start.bat" .
    fi

    rm -rf "$STAGING_DIR"
    ok "Server files installed."
    return 0
}

if [[ "$UPGRADE" == false && -d "Server" && -f "Assets.zip" && -f "start.sh" ]]; then
    warn "Server/, Assets.zip, and start.sh already present — skipping download."
    warn "Use --upgrade to fetch the latest Hytale version."
else
    ensure_downloader || die "Could not obtain the Hytale Downloader. Check your internet connection."
    if ! download_server; then
        if [[ "$UPGRADE" == true ]]; then
            warn "Upgrade failed — restarting the previous server image..."
            docker compose up -d --no-build 2>/dev/null || true
        fi
        die "Could not download a new server. Your previous files were preserved."
    fi
fi

# ── 7. Persistent data and auth files ─────────────────────────────────────────
step "Preparing persistent data"

# Files owned by the invoking user so the container can run as that user and
# the whole folder remains readable/copyable.
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    DATA_UID="$(id -u "$SUDO_USER")"
    DATA_GID="$(id -g "$SUDO_USER")"
elif [[ $EUID -eq 0 ]]; then
    # Running directly as root: use the fallback in-container user so data and
    # runtime UID stay consistent.
    DATA_UID=1500
    DATA_GID=1500
else
    DATA_UID="$(id -u)"
    DATA_GID="$(id -g)"
fi

if ! mkdir -p "$DATA_DIR/universe" "$DATA_DIR/backups" "$DATA_DIR/auth" 2>/dev/null; then
    run_sudo mkdir -p "$DATA_DIR/universe" "$DATA_DIR/backups" "$DATA_DIR/auth"
fi

for auth_file in auth.key auth.enc; do
    if [[ ! -e "$DATA_DIR/auth/$auth_file" ]]; then
        if [[ $EUID -eq 0 ]]; then
            : > "$DATA_DIR/auth/$auth_file"
        else
            run_sudo touch "$DATA_DIR/auth/$auth_file"
        fi
    fi
done

# Older versions of this project used UID 1500 for everything. The container
# now runs as the data owner, so normalize ownership to the invoking user.
if [[ $EUID -eq 0 ]]; then
    chown -R "$DATA_UID:$DATA_GID" "$DATA_DIR"
else
    run_sudo chown -R "$DATA_UID:$DATA_GID" "$DATA_DIR"
fi
if [[ $EUID -eq 0 ]]; then
    chmod 700 "$DATA_DIR/auth"
    chmod 600 "$DATA_DIR/auth/auth.key" "$DATA_DIR/auth/auth.enc"
else
    run_sudo chmod 700 "$DATA_DIR/auth"
    run_sudo chmod 600 "$DATA_DIR/auth/auth.key" "$DATA_DIR/auth/auth.enc"
fi

ok "Persistent data ready under data/ (owner UID $DATA_UID)."
echo "  World:      data/universe"
echo "  Backups:    data/backups"
echo "  Auth files: data/auth  ← never commit this folder"

# ── 8. Write configuration files ─────────────────────────────────────────────
info "Writing configuration files..."

# -- jvm.options ---------------------------------------------------------------
if [[ ! -f "jvm.options" ]]; then
    cat > "jvm.options" << EOF
# Hytale server JVM options.
# Loaded automatically by start.sh — one argument per line.
# Lines starting with # are comments.

# Heap — adjust to your machine (minimum: -Xmx4g).
# Values below assume ~16 GB RAM; scale as needed.
-Xms${JVM_XMS}
-Xmx${JVM_XMX}

# ZGC: low-pause GC — ideal for a game server.
-XX:+UseZGC
-XX:+ZGenerational
EOF
    ok "jvm.options written (heap: ${JVM_XMS}–${JVM_XMX})."
else
    warn "jvm.options already exists — preserving your heap/GC settings."
fi

# -- docker-entrypoint.sh ------------------------------------------------------
ENTRYPOINT_CONTENT="$(cat << 'EOF'
#!/bin/sh
# Runs as root, prepares bind-mounted data, then drops to the data owner.
set -eu

AUTH_DIR=/server/auth
AUTH_KEY="$AUTH_DIR/auth.key"
AUTH_ENC="$AUTH_DIR/auth.enc"

mkdir -p "$AUTH_DIR"
for file in "$AUTH_KEY" "$AUTH_ENC"; do
    if [ ! -e "$file" ]; then
        : > "$file"
    fi
done

# Run the server as the user that owns the world data. This keeps bind-mounted
# data writable and makes auth files readable by the same host user after the
# folder is copied to another machine.
HOST_UID="$(stat -c '%u' /server/Server/universe 2>/dev/null || echo 1500)"
HOST_GID="$(stat -c '%g' /server/Server/universe 2>/dev/null || echo 1500)"
if [ "$HOST_UID" = "0" ]; then
    HOST_UID=1500
    HOST_GID=1500
fi

# Image-owned files must be writable by the runtime user (config, logs, cache).
chown -R "$HOST_UID:$HOST_GID" /server/Server 2>/dev/null || true
chmod -R u+rwX /server/Server/universe /server/Server/backups 2>/dev/null || true

# Auth files belong to the runtime user and stay private.
chown "$HOST_UID:$HOST_GID" "$AUTH_DIR" "$AUTH_KEY" "$AUTH_ENC" 2>/dev/null || true
chmod 700 "$AUTH_DIR" 2>/dev/null || true
chmod 600 "$AUTH_KEY" "$AUTH_ENC" 2>/dev/null || true

exec setpriv --reuid="$HOST_UID" --regid="$HOST_GID" --clear-groups /server/start.sh "$@"
EOF
)"
backup_and_write "docker-entrypoint.sh" "$ENTRYPOINT_CONTENT"
chmod +x "docker-entrypoint.sh"

# -- Dockerfile ----------------------------------------------------------------
DOCKERFILE_CONTENT="$(cat << 'EOF'
# eclipse-temurin 25 — official Adoptium build, matches the Hytale Java requirement.
FROM eclipse-temurin:25-jre-noble

# Fallback user used if the data directory is not accessible (UID 1500).
RUN useradd -m -u 1500 hytale

WORKDIR /server

# start.sh sits alongside Server/ and Assets.zip — mirrors the extracted layout.
COPY --chown=hytale:hytale start.sh ./
# jvm.options is read by start.sh from the server root (../jvm.options from Server/).
COPY --chown=hytale:hytale jvm.options ./
# Server/ contains HytaleServer.jar, HytaleServer.aot.config, Licenses/
COPY --chown=hytale:hytale Server/ ./Server/
# Asset bundle — referenced as ../Assets.zip by start.sh (relative to Server/)
COPY --chown=hytale:hytale Assets.zip ./
# Entrypoint repairs bind-mount ownership after a folder copy, then drops to the data owner.
COPY --chown=root:root docker-entrypoint.sh /usr/local/bin/hytale-entrypoint

RUN chmod +x start.sh /usr/local/bin/hytale-entrypoint \
    && mkdir -p /server/auth \
    && ln -sf /server/auth/auth.key /server/Server/auth.key \
    && ln -sf /server/auth/auth.enc /server/Server/auth.enc

# Hytale uses QUIC/UDP on 5520.
EXPOSE 5520/udp

# root entrypoint fixes permissions then drops to the unprivileged data owner.
ENTRYPOINT ["/usr/local/bin/hytale-entrypoint"]
EOF
)"
backup_and_write "Dockerfile" "$DOCKERFILE_CONTENT"

# -- docker-compose.yml --------------------------------------------------------
COMPOSE_CONTENT="$(cat << EOF
services:
  hytale:
    build: .
    container_name: ${CONTAINER_NAME}
    # Hytale ships Linux native libraries for x86_64 only. On Apple Silicon this
    # makes Docker use Rosetta/QEMU instead of failing on an arm64 container.
    platform: linux/amd64
    restart: unless-stopped
    ports:
      - "${HYTALE_PORT}:${HYTALE_PORT}/udp"
    volumes:
      # World data — the only thing needed to migrate your world
      - ./data/universe:/server/Server/universe
      # Periodic backups written by start.sh (--backup-dir backups)
      - ./data/backups:/server/Server/backups
      # Server auth — auth.key decrypts auth.enc. Mount the directory so both
      # files survive rebuilds and travel with a copied server folder.
      - ./data/auth:/server/auth
      # JVM heap/GC settings — edit on the host, restart to apply.
      - ./jvm.options:/server/jvm.options:ro
    stdin_open: true
    tty: true

networks:
  default:
    ipam:
      config:
        - subnet: 172.30.0.0/16
EOF
)"
backup_and_write "docker-compose.yml" "$COMPOSE_CONTENT"

# -- .dockerignore -------------------------------------------------------------
DOCKERIGNORE_CONTENT="$(cat << 'EOF'
hytale-server-bootstrap.sh
hytale-downloader-linux-amd64
hytale-downloader.zip
.hytale-downloader-credentials.json*
.hytale-staging/
data/
.git
.gitignore
docker-compose.yml
*.md
*.zip
!Assets.zip
*.bak.*
EOF
)"
backup_and_write ".dockerignore" "$DOCKERIGNORE_CONTENT"

# -- .gitignore — make sure secrets can never be committed ----------------------
GITIGNORE_PATTERNS=(
    ".hytale-downloader-credentials.json*"
    "data/"
    "data/auth/"
    "Dockerfile"
    "docker-compose.yml"
    "docker-entrypoint.sh"
    ".dockerignore"
    "jvm.options"
    "Assets.zip"
    "Server/"
    "start.*"
    "hytale-downloader-linux-amd64"
    "*.zip"
    ".hytale-staging/"
    ".jdk/"
    ".jdk-download.tar.gz"
    "screenlog.*"
    "*.bak.*"
)
if [[ ! -f ".gitignore" ]]; then
    {
        echo "# Hytale secrets and generated files — never commit"
        printf '%s\n' "${GITIGNORE_PATTERNS[@]}"
    } > ".gitignore"
    ok ".gitignore written (credentials and data excluded)."
else
    GITIGNORE_CHANGED=false
    for pattern in "${GITIGNORE_PATTERNS[@]}"; do
        if ! grep -qxF "$pattern" ".gitignore"; then
            if [[ "$GITIGNORE_CHANGED" == false ]]; then
                printf '\n# Hytale secrets and generated files — never commit\n' >> ".gitignore"
                GITIGNORE_CHANGED=true
            fi
            printf '%s\n' "$pattern" >> ".gitignore"
        fi
    done
    if [[ "$GITIGNORE_CHANGED" == true ]]; then
        ok "Added missing secret/generated patterns to .gitignore."
    else
        ok ".gitignore already excludes credentials and runtime data."
    fi
fi

ok "Configuration files ready."

# ── 9. Build Docker image ─────────────────────────────────────────────────────
step "Building Docker image..."

if ! docker compose build; then
    warn "Docker build failed. Check the output above."
    if [[ "$UPGRADE" == true ]]; then
        warn "Attempting to restart the previous image..."
        docker compose up -d --no-build 2>/dev/null || true
    fi
    die "Build failed."
fi

ok "Image built."

# ── 10. Launch ────────────────────────────────────────────────────────────────
step "Starting Hytale Server"

docker compose up -d || die "Could not start the server."

info "Waiting for the server to finish booting..."
BOOTED=false
for _ in $(seq 1 90); do
    if docker compose logs --no-color 2>&1 | grep -q "Hytale Server Booted!"; then
        BOOTED=true
        break
    fi
    if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo false)" != "true" ]]; then
        warn "Container stopped unexpectedly. Last log lines:"
        docker compose logs --tail=60 --no-color 2>&1 || true
        die "Server failed to start."
    fi
    sleep 2
done

if [[ "$BOOTED" == true ]]; then
    ok "Server booted."
else
    warn "Boot message not seen yet — the server may still be loading. Check: docker compose logs -f"
fi

sleep 3
AUTH_READY=false
if docker compose logs --no-color 2>&1 | grep -q "Authentication successful"; then
    AUTH_READY=true
fi

# ── 11. Post-launch instructions ─────────────────────────────────────────────
LAN_IP="$(ip -4 route get 1 2>/dev/null | sed -n 's/.*src \([0-9][0-9.]*\).*/\1/p' | head -n1 || true)"
[[ -n "$LAN_IP" ]] || LAN_IP="<your-lan-ip>"

step "Server is running"

if [[ "$AUTH_READY" == false ]]; then
    echo -e "  ${YLW}ONE-TIME SERVER AUTHORIZATION${NC}"
    echo ""
    echo "  The server needs its own token before players can connect."
    echo "  Attach to its console:"
    echo ""
    echo -e "    ${GRN}docker attach ${CONTAINER_NAME}${NC}"
    echo ""
    echo "  Then type:"
    echo ""
    echo -e "    ${GRN}/auth login device${NC}"
    echo ""
    echo "  Open the URL it prints, approve the code, then detach WITHOUT"
    echo "  stopping the server:"
    echo ""
    echo -e "    ${GRN}Ctrl+P${NC} then ${GRN}Ctrl+Q${NC}"
    echo ""
    echo "  The token is saved in data/auth/ and survives restarts, rebuilds"
    echo "  and copying the whole folder to another machine."
    echo ""
else
    echo -e "  ${GRN}Server authorization is already configured.${NC}"
    echo ""
fi

echo -e "  ${YLW}CONNECT${NC}"
echo -e "    LAN:          ${GRN}${LAN_IP}:${HYTALE_PORT}${NC}"
echo -e "    This machine: ${GRN}127.0.0.1:${HYTALE_PORT}${NC}"
echo ""

echo -e "  ${YLW}COMMON COMMANDS${NC}"
echo "    Live logs:       docker compose logs -f"
echo "    Attach console:  docker attach ${CONTAINER_NAME}"
echo "    Detach:          Ctrl+P then Ctrl+Q"
echo "    Stop:            docker compose down"
echo "    Start:           docker compose up -d"
echo "    Upgrade:         ./hytale-server-bootstrap.sh --upgrade"
echo ""

echo -e "  ${YLW}COPYING TO ANOTHER MACHINE${NC}"
echo "    Copy the entire folder (including data/) and run:"
echo -e "      ${GRN}docker compose up -d --build${NC}"
echo "    The entrypoint fixes file ownership automatically. World and auth"
echo "    stay in data/; nothing else needs to be copied."
echo ""

echo -e "  ${YLW}SECURITY${NC}"
echo "    Never commit .hytale-downloader-credentials.json or data/auth/."
echo "    Both are already listed in .gitignore."
echo ""

else
    macos_main
fi
