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
#   6. Writes Dockerfile, docker-compose.yml, jvm.options, .dockerignore
#   7. Configures UFW: enables it and opens UDP 5520 (Hytale) + 22 (SSH)
#   8. Builds the Docker image and starts the server
#   9. Prints full instructions for server auth and connecting
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
#   --upgrade   Stop the server, remove old binaries, re-download and rebuild.
#               Your world data in data/ is never touched.
# =============================================================================

set -euo pipefail

# ── Flags ─────────────────────────────────────────────────────────────────────
UPGRADE=false
for arg in "$@"; do
    case "$arg" in
        --upgrade) UPGRADE=true ;;
        *) die "Unknown argument: $arg. Usage: $0 [--upgrade]" ;;
    esac
done

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

# ── Config ────────────────────────────────────────────────────────────────────
DOWNLOADER_URL="https://downloader.hytale.com/hytale-downloader.zip"
DOWNLOADER_ZIP="hytale-downloader.zip"
DOWNLOADER_BIN="hytale-downloader-linux-amd64"
HYTALE_PORT="5520"
DATA_DIR="$(pwd)/data"

# JVM heap — adjust to your machine. Hytale requires at least 4 GB.
# Values below assume ~16 GB RAM; scale up or down as needed.
JVM_XMS="3g"
JVM_XMX="6g"

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLU}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLU}  Hytale Server Bootstrap · CachyOS / Arch edition${NC}"
echo -e "${BLU}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ── 0. Upgrade mode — wipe old binaries so the downloader fetches fresh ones ──
if [[ "$UPGRADE" == true ]]; then
    step "Upgrade mode"
    echo "  Stopping server (if running)..."
    docker compose down 2>/dev/null || true

    echo "  Removing old server binaries..."
    rm -rf Server/ Assets.zip start.sh start.bat
    rm -f "$DOWNLOADER_BIN"

    ok "Old binaries removed. Proceeding with fresh download and rebuild."
    echo "  Your world data in data/ is untouched."
    echo ""
fi

# ── 1. Architecture guard ─────────────────────────────────────────────────────
ARCH="$(uname -m)"
[[ "$ARCH" == "x86_64" ]] \
    || die "This script requires x86_64. Detected: $ARCH"
ok "Architecture: x86_64"

# ── 2. Install missing dependencies via pacman ────────────────────────────────
info "Checking and installing dependencies..."

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
    info "Installing via pacman: ${PKGS_NEEDED[*]}"
    sudo pacman -Sy --needed --noconfirm "${PKGS_NEEDED[@]}" \
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
    sudo systemctl enable docker
    ok "Docker service enabled (will start on boot)."
fi

if ! systemctl is-active --quiet docker; then
    sudo systemctl start docker
    ok "Docker service started."
else
    ok "Docker is already running."
fi

if ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
    sudo usermod -aG docker "$USER"
    warn "Added '$USER' to the docker group."
    warn "Re-execing script in docker group context — no logout needed."
    exec sg docker "$0" "$@"
fi

ok "Docker ready."

# ── 4. Configure UFW ──────────────────────────────────────────────────────────
info "Configuring UFW firewall..."

if ! sudo ufw status | grep -q "Status: active"; then
    info "UFW is inactive — enabling it now."
    sudo ufw allow 22/tcp comment 'SSH' &>/dev/null
    sudo ufw --force enable
    ok "UFW enabled."
else
    ok "UFW already active."
fi

if ! sudo ufw status | grep -q "22/tcp"; then
    sudo ufw allow 22/tcp comment 'SSH' &>/dev/null
    ok "UFW: SSH (TCP 22) allowed."
fi

if ! sudo ufw status | grep -q "${HYTALE_PORT}/udp"; then
    sudo ufw allow "${HYTALE_PORT}/udp" comment 'Hytale server' &>/dev/null
    ok "UFW: Hytale (UDP ${HYTALE_PORT}) allowed."
else
    ok "UFW: Hytale UDP ${HYTALE_PORT} rule already present."
fi

echo ""
info "Current UFW status:"
sudo ufw status numbered | grep -E "Status|${HYTALE_PORT}|22" || true
echo ""

# ── 5. Download the official Hytale Downloader ────────────────────────────────
info "Fetching Hytale Downloader from official source..."

if [[ -f "$DOWNLOADER_BIN" ]]; then
    warn "Downloader binary already exists — skipping download. Delete it to re-fetch."
else
    wget -q --show-progress -O "$DOWNLOADER_ZIP" "$DOWNLOADER_URL" \
        || die "Download failed. Check your internet connection or try again."

    unzip -q "$DOWNLOADER_ZIP" "$DOWNLOADER_BIN" \
        || die "Could not extract '$DOWNLOADER_BIN' from the zip."

    rm -f "$DOWNLOADER_ZIP"
    chmod +x "$DOWNLOADER_BIN"
    ok "Downloader binary ready."
fi

# ── 6. Run the downloader — interactive OAuth2 auth ───────────────────────────
step "ACTION REQUIRED — Hytale Account Authentication"
echo "  The downloader will show you a URL and a short code."
echo "  Open the URL in your browser, log in with your Hytale account,"
echo "  and enter the code. You must own Hytale to proceed."
echo "  This authentication step happens only once."
echo ""

# find_server_zip — returns the newest *.zip that isn't the downloader zip itself
find_server_zip() {
    local zips
    zips=$(ls -1t ./*.zip 2>/dev/null || true)

    echo "$zips" |
        grep -v "^\./${DOWNLOADER_ZIP}$" |
        grep -v '^$' |
        head -n1 || true
}

if [[ -d "Server" && -f "Assets.zip" && -f "start.sh" ]]; then
    warn "Server/, Assets.zip, and start.sh already present — skipping download step."
    warn "Delete them and re-run if you need a fresh copy."
else
    EXISTING_ZIP="$(find_server_zip)"
    if [[ -n "$EXISTING_ZIP" ]]; then
        warn "Found existing server archive: $EXISTING_ZIP — skipping download."
        warn "Delete it and re-run if you want a fresh copy."
    else
        "./$DOWNLOADER_BIN" \
            || die "Hytale Downloader failed. Check the output above."
    fi

    VERSIONED_ZIP="$(find_server_zip)"
    [[ -n "$VERSIONED_ZIP" ]] \
        || die "No server archive found after download. Something went wrong."

    info "Extracting '$VERSIONED_ZIP'..."
    unzip -qo "$VERSIONED_ZIP" \
        || die "Extraction failed."

    rm -f "$VERSIONED_ZIP"
    ok "Server files extracted."
fi


[[ -d "Server" ]]     || die "Expected Server/ directory not found after extraction."
[[ -f "Assets.zip" ]] || die "Expected Assets.zip not found after extraction."
[[ -f "start.sh" ]]   || die "Expected start.sh not found after extraction."

ok "Server/, Assets.zip, and start.sh confirmed present."

# ── 7. Write all configuration files ─────────────────────────────────────────
echo ""
info "Writing configuration files..."

# -- Server/jvm.options --------------------------------------------------------
if [[ ! -f "Server/jvm.options" ]]; then
cat > "Server/jvm.options" << EOF
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
    ok "Server/jvm.options written (heap: ${JVM_XMS}–${JVM_XMX})."
else
    warn "Server/jvm.options already exists — leaving it untouched."
fi

# -- Dockerfile ----------------------------------------------------------------
if [[ ! -f "Dockerfile" ]]; then
cat > "Dockerfile" << 'EOF'
# eclipse-temurin 25 — official Adoptium build, matches Hytale's Java requirement.
FROM eclipse-temurin:25-jre-noble

# Non-root user — UID 1500 avoids conflicts with existing base image users.
RUN useradd -m -u 1500 hytale

WORKDIR /server

# start.sh sits alongside Server/ and Assets.zip — mirrors the extracted layout.
COPY --chown=hytale:hytale start.sh ./
# Server/ contains HytaleServer.jar, HytaleServer.aot.config, Licenses/, jvm.options
COPY --chown=hytale:hytale Server/ ./Server/
# Asset bundle — referenced as ../Assets.zip by start.sh (relative to Server/)
COPY --chown=hytale:hytale Assets.zip ./

RUN chmod +x start.sh

USER hytale

# Hytale uses QUIC/UDP on 5520.
EXPOSE 5520/udp

# start.sh handles staged updates, reads Server/jvm.options, restarts on exit code 8.
ENTRYPOINT ["./start.sh"]
EOF
    ok "Dockerfile written."
else
    warn "Dockerfile already exists — leaving it untouched."
fi

# -- docker-compose.yml --------------------------------------------------------
if [[ ! -f "docker-compose.yml" ]]; then
cat > "docker-compose.yml" << EOF
services:
  hytale:
    build: .
    container_name: hytale-server
    restart: unless-stopped
    ports:
      - "${HYTALE_PORT}:${HYTALE_PORT}/udp"
    volumes:
      # World data — the only thing needed to migrate your world
      - ./data/universe:/server/Server/universe
      # Periodic backups written by start.sh (--backup-dir backups)
      - ./data/backups:/server/Server/backups
    stdin_open: true
    tty: true
EOF
    ok "docker-compose.yml written."
else
    warn "docker-compose.yml already exists — leaving it untouched."
fi

# -- .dockerignore -------------------------------------------------------------
if [[ ! -f ".dockerignore" ]]; then
cat > ".dockerignore" << 'EOF'
hytale-server-bootstrap.sh
hytale-downloader-linux-amd64
hytale-downloader.zip
data/
.git
.gitignore
*.md
EOF
    ok ".dockerignore written."
else
    warn ".dockerignore already exists — leaving it untouched."
fi

# -- Persistent volume directories ---------------------------------------------
# UID 1500 matches the hytale user created in the Dockerfile.
# The mounted dirs must be writable by that UID or the server cannot save.
for dir in universe backups; do
    mkdir -p "${DATA_DIR}/${dir}"
done
# UID 1500 = hytale user inside the container — must own all mounted dirs
sudo chown -R 1500:1500 "${DATA_DIR}"
ok "Persistent data directories ready under data/. (owned by UID 1500 — hytale)"

# ── 8. Build Docker image ─────────────────────────────────────────────────────
step "Building Docker image..."

docker compose build \
    || die "Docker build failed. Check the output above."

ok "Image built."

# ── 9. Pre-launch instructions ────────────────────────────────────────────────
LAN_IP="$(ip -4 route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1 || echo '<your-lan-ip>')"

step "Almost there — read this before the server starts"

echo -e "  ${YLW}STEP 1 — Authenticate the server (first run only)${NC}"
echo ""
echo "  The server needs its own auth token to allow players to connect."
echo "  Once it has started, attach to its console and run a command:"
echo ""
echo -e "    ${GRN}docker attach hytale-server${NC}"
echo ""
echo "  Then type this inside the server console:"
echo ""
echo -e "    ${GRN}/auth login device${NC}"
echo ""
echo "  You will see a short URL and a code like:"
echo ""
echo "    Visit: https://oauth.accounts.hytale.com/oauth2/device/verify"
echo "    Code:  XXXX-XXXX"
echo ""
echo "  Open that URL in your browser, log in with your Hytale account,"
echo "  and enter the code. The server will confirm authentication."
echo ""
echo "  Detach from the console WITHOUT stopping the server:"
echo -e "    Press ${GRN}Ctrl+P${NC} then ${GRN}Ctrl+Q${NC}  (not Ctrl+C — that kills the server)"
echo ""
echo -e "  ${YLW}STEP 2 — Connect from this machine or your kids' devices${NC}"
echo ""
echo -e "    Open Hytale → Multiplayer → Direct Connect"
echo -e "    Enter: ${GRN}${LAN_IP}:${HYTALE_PORT}${NC}  (or just ${GRN}127.0.0.1${NC} from this machine)"
echo ""
echo -e "  ${YLW}STEP 3 — Restart in background after auth is done${NC}"
echo ""
echo "  After auth succeeds, stop and restart detached:"
echo ""
echo -e "    ${GRN}docker compose down${NC}"
echo -e "    ${GRN}docker compose up -d${NC}"
echo ""
echo "  Subsequent starts skip auth entirely — the token is persisted."
echo ""

# ── 10. Launch ────────────────────────────────────────────────────────────────
step "Starting Hytale Server"

echo "  Starting in foreground so you can complete auth (Step 1 above)."
echo "  When done: Ctrl+P then Ctrl+Q to detach, then 'docker compose up -d'."
echo ""

docker compose up

# ── Done — cheatsheet ─────────────────────────────────────────────────────────
echo ""
echo -e "${GRN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GRN}  Cheatsheet${NC}"
echo -e "${GRN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Start server in background:    docker compose up -d"
echo "  Stop server:                   docker compose down"
echo "  Tail live logs:                docker compose logs -f"
echo "  Attach to server console:      docker attach hytale-server"
echo "  Detach from console:           Ctrl+P then Ctrl+Q"
echo "  Rebuild after game update:     docker compose build && docker compose up -d"
echo "  Re-authenticate server:        docker attach hytale-server → /auth login device"
echo ""
echo -e "  LAN address for your kids:     ${GRN}${LAN_IP}:${HYTALE_PORT}${NC}"
echo ""
