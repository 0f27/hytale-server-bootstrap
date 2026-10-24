# Hytale Server Bootstrap

One-script self-hosted Hytale dedicated server setup for **CachyOS / Arch Linux** using Docker.

Run a single command and get a fully configured, containerised Hytale server with persistent world data, automatic restarts, portable authentication, and UFW firewall rules.

---

## Requirements

- CachyOS or any Arch-based distro on **x86_64**
- A Hytale account that **owns the game** (Standard Edition or higher)
- `sudo` access
- Internet connection (~1.6 GB download for server files)

> **macOS / Apple Silicon:** the bootstrap script itself targets Arch Linux, but a
> fully populated server folder can be started on macOS with Docker. Hytale only
> ships Linux native libraries for x86_64, so `docker-compose.yml` sets
> `platform: linux/amd64`. Enable Rosetta in OrbStack or Docker Desktop, then run
> `docker compose up -d --build` from the copied folder. Expect emulation overhead.

---

## Quick Start

```bash
mkdir hytale-server && cd hytale-server
curl -O https://raw.githubusercontent.com/0f27/hytale-server-bootstrap/main/hytale-server-bootstrap.sh
chmod +x hytale-server-bootstrap.sh
./hytale-server-bootstrap.sh
```

The script handles everything:

1. Installs missing dependencies via `pacman` (`docker`, `docker-compose`, `docker-buildx`, `wget`, `unzip`, `ufw`)
2. Detects kernel updates and prompts for reboot if needed (prevents Docker networking failures)
3. Enables and starts the Docker daemon via systemd
4. Downloads the official Hytale Downloader from `downloader.hytale.com`
5. Authenticates with your Hytale account (interactive, browser-based, skipped if already done)
6. Downloads and extracts the server files (~1.6 GB; staged so a failed upgrade keeps the old files)
7. Writes `Dockerfile`, `docker-compose.yml`, `docker-entrypoint.sh`, `jvm.options`, `.dockerignore`, and `.gitignore`
8. Configures UFW: opens UDP 5520 (Hytale) and TCP 22 (SSH)
9. Builds the Docker image and starts the server **in the background**
10. Detects whether the server token is already present and prints the remaining steps

Re-running the script is safe. Use `--upgrade` to fetch a new Hytale build, and `--no-ufw` to leave firewall rules untouched.

---

## First Boot — Server Authentication

After the server starts you need to authenticate it **once** with your Hytale account.
This is separate from your account login and authorises the server itself to accept connections.

If the script reports that authorization is not configured, attach to the server console:

```bash
docker attach hytale-server
```

Inside the server console type:

```
/auth login device
```

> **Important:** use `/auth login device`, not `/auth login`. The plain form tries to open
> a localhost callback URL which doesn't work inside Docker.

Visit the URL shown, enter the code, and approve it in your browser. The server confirms
with `Authentication successful!` and saves the token. Then detach **without stopping the server**:

```
Ctrl+P  then  Ctrl+Q
```

No restart is needed. The server keeps running in the background.

The credentials live in `data/auth/`:

- `auth.key` — encryption key
- `auth.enc` — encrypted server token

Both files are bind-mounted. They survive restarts, rebuilds, and copying the whole
server folder to another machine. You only need to authenticate again if you delete
`data/auth/`.

---

## Connecting

From the **same machine**: `127.0.0.1:5520`

From **other devices on your LAN**: `<host-machine-ip>:5520`

In Hytale: **Servers → Direct Connect** and enter the address above.

> Share codes (the invite link from singleplayer) are not available on dedicated servers.
> Players always connect via Direct Connect.

---

## Copying the Server Folder

The folder is self-contained apart from the Docker image:

```bash
# Stop cleanly before copying
docker compose down

# Copy the whole directory (including data/) to the new machine
rsync -a hytale-server/ user@new-host:/path/to/hytale-server/
```

On the new machine:

```bash
cd hytale-server
docker compose up -d --build
```

`--build` recreates the image because Docker images are not stored in the folder.
The entrypoint repairs bind-mount ownership automatically, so the server runs as the
user who owns `data/universe`. Your world and authorization are already in `data/`;
no re-download and no re-authentication are needed.

If you only want to migrate the world, copy `data/` to a fresh folder and run
`./hytale-server-bootstrap.sh` there. The script re-downloads the server binaries.

> Never commit `.hytale-downloader-credentials.json` or anything under `data/`.
> Both are excluded by `.gitignore`.

---

## Directory Layout

After first run the folder looks like this:

```
hytale-server/
├── hytale-server-bootstrap.sh      # this script
├── Dockerfile                      # generated
├── docker-compose.yml              # generated
├── docker-entrypoint.sh            # generated — ownership repair + privilege drop
├── .dockerignore                   # generated
├── start.sh                        # from Hytale archive
├── Assets.zip                      # from Hytale archive (~3.7 GB)
├── jvm.options                     # generated — edit heap/GC here
├── Server/                         # from Hytale archive
│   ├── HytaleServer.jar
│   ├── HytaleServer.aot.config
│   └── Licenses/
└── data/                           # persistent state mounted from host
    ├── universe/                   # ← world data (the only thing you need to back up)
    │   ├── players/                #   player profiles
    │   └── worlds/default/         #   world chunks, resources, config
    ├── backups/                    # ← periodic snapshots from start.sh
    └── auth/                       # ← server authorization (never commit)
        ├── auth.key                #   encryption key
        └── auth.enc                #   encrypted server token
```

`data/` is owned by the user who ran the bootstrap. The container starts as root only
long enough to repair mount ownership, then drops to that same user before launching
the server.

---

## JVM Memory

Edit `jvm.options` in the **server root** (not `Server/`). Default values assume ~16 GB RAM:

```
-Xms3g
-Xmx6g
```

Hytale requires a minimum of **4 GB heap** (`-Xmx4g`). The file is mounted read-only
into the container, so apply changes with:

```bash
docker compose restart
```

No rebuild is needed.

---

## Upgrading

When a new version of Hytale is released, run:

```bash
./hytale-server-bootstrap.sh --upgrade
```

This will:

1. Stop the server
2. Download the latest build into a staging directory
3. Verify the archive before touching the existing `Server/`, `Assets.zip`, or `start.sh`
4. Rebuild the Docker image
5. Start the server in the background

If the download or build fails, the previous files/image are kept and the script tries
to restart the old server. If the saved Hytale **downloader** refresh token has expired,
the script detects `invalid_grant`, moves the old credentials aside, and starts a fresh
device login automatically.

Your world data and server auth in `data/` are never touched. `auth.key` and `auth.enc`
travel with the folder, so no server re-authentication is needed after an upgrade.

---

## Auth Files

The server token is stored as two files in a bind-mounted directory:

```
data/auth/auth.key  →  /server/auth/auth.key  →  /server/Server/auth.key (symlink)
data/auth/auth.enc  →  /server/auth/auth.enc  →  /server/Server/auth.enc (symlink)
```

`auth.key` decrypts `auth.enc`. Both are required. Mounting the **directory** instead
of individual files avoids Docker's "missing source file becomes a directory" trap and
makes the pair easy to copy.

Once you authenticate with `/auth login device`, the server writes the token directly
into `data/auth/auth.enc` on the host. It persists across all restarts, rebuilds, and
folder copies.

---

## Common Commands

```bash
# Start in background
docker compose up -d

# Stop
docker compose down

# Tail live logs
docker compose logs -f

# Attach to server console (detach with Ctrl+P Ctrl+Q)
docker attach hytale-server

# Apply jvm.options changes
docker compose restart

# Upgrade to a new Hytale version
./hytale-server-bootstrap.sh --upgrade

# Rebuild and start after copying the folder to a new machine
docker compose up -d --build

# Re-authenticate if token is missing or expired
docker attach hytale-server
# then: /auth login device
```

---

## Troubleshooting

**`Module bridge not found` / `veth` errors on build**
Your kernel modules don't match the running kernel — the system was updated without rebooting.
The script detects this automatically and exits with a reboot prompt. After rebooting, re-run the script.

**`serverAuthUnavailable` when connecting**
The server hasn't been authenticated yet, or `data/auth/` was deleted. Attach and run
`/auth login device` — see First Boot above.

**World regenerated / empty after restart**
The volume mount for `universe` wasn't in place when the world was first created, so it lived
only inside the container. Copy it out before stopping:
```bash
docker cp hytale-server:/server/Server/universe/. data/universe/
```
Then restart with the correct `docker-compose.yml`.

**Server constantly restarting**
Check `docker compose logs`. The entrypoint repairs ownership of `data/universe` and
`data/backups` automatically. If you have an old compose file without that entrypoint,
fix ownership manually:
```bash
sudo chown -R "$USER:$USER" data/
```

**`jvm.options: is a directory`**
Compose creates a directory if the file is missing. Re-run the bootstrap script
(or create an empty `jvm.options`) and restart.

**Downloader says `invalid_grant` / refresh token expired**
The bootstrap script handles this automatically on `--upgrade`. To force it manually:
```bash
rm .hytale-downloader-credentials.json
./hytale-server-bootstrap.sh --upgrade
```

---

## Notes

- The server runs on **UDP port 5520** using the QUIC protocol
- For internet play: forward UDP 5520 on your router, or use [Tailscale](https://tailscale.com) for zero-config peer-to-peer VPN — no port forwarding needed
- Hytale's built-in backup runs every 30 minutes by default (`--backup-frequency 30` in `start.sh`) and writes to `data/backups/`
