#!/usr/bin/env bash
# =============================================================================
# Hytale Server Bootstrap — CachyOS / Arch Linux edition
#
# What this script does:
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
# Requirements:
#   - CachyOS (or any Arch-based distro) on x86_64
#   - A Hytale account that owns the game (Standard Edition or higher)
#   - sudo access
#
# Usage:
#   chmod +x hytale-server-bootstrap.sh && ./hytale-server-bootstrap.sh
#
# Flags:
#   --upgrade   Stop the server, download the latest Hytale build, rebuild and
#               restart. World data and server auth in data/ are never touched.
#   --no-ufw    Do not modify firewall rules.
# =============================================================================

set -euo pipefail

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
Usage: $0 [--upgrade] [--no-ufw]

  (no flags)  Install or repair the server, build the image and start it.
  --upgrade   Download the latest Hytale build, rebuild and restart.
  --no-ufw    Leave firewall rules untouched.
  -h, --help  Show this help.
EOF
}

# ── Flags ─────────────────────────────────────────────────────────────────────
UPGRADE=false
SKIP_UFW=false
for arg in "$@"; do
    case "$arg" in
        --upgrade) UPGRADE=true ;;
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

# JVM heap — adjust to your machine. Hytale requires at least 4 GB.
JVM_XMS="3g"
JVM_XMX="6g"

if [[ $EUID -eq 0 ]]; then
    SUDO=()
else
    SUDO=(sudo)
fi
run_sudo() { "${SUDO[@]}" "$@"; }

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLU}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLU}  Hytale Server Bootstrap · CachyOS / Arch edition${NC}"
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
# eclipse-temurin 25 — official Adoptium build, matches Hytale's Java requirement.
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
LAN_IP="$(ip -4 route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1 || true)"
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
