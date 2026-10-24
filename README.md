# Hytale Server Bootstrap

One-script self-hosted Hytale dedicated server setup for **CachyOS / Arch Linux (Docker)** and **macOS (native Java 25)**.

Run a single command and get a fully configured Hytale server with persistent world data, automatic restarts, portable authentication, and a working firewall setup.

---

## Requirements

**Linux:**

- CachyOS or any Arch-based distro on **x86_64**
- A Hytale account that **owns the game** (Standard Edition or higher)
- `sudo` access
- Internet connection (~1.6 GB download for server files)

**macOS:**

- macOS 13 or newer on Apple Silicon or Intel
- Java 25 (the script downloads Temurin 25 into `.jdk/` if it is missing)
- A Hytale account that **owns the game** (Standard Edition or higher)
- `Server/`, `Assets.zip`, and `start.sh` copied from the Linux installation, the
  Hytale launcher, or a JAR bootstrap install

> **macOS runs natively.** `HytaleServer.jar` contains `native/osx-arm64` libraries,
> so the server does **not** need Docker, Rosetta, or QEMU on an M1/M2/M3/M4 Mac.
> The Linux Docker path is unchanged. If you deliberately run Docker on Apple
> Silicon, `docker-compose.yml` sets `platform: linux/amd64` so Docker uses
> Rosetta instead of trying to run an arm64 container.

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

Re-running the script is safe. Use `--upgrade` to fetch a new Hytale build, `--stop` to stop the server, and `--no-ufw` to leave firewall rules untouched.

---

## macOS Quick Start

Copy the whole server folder from the Linux machine (including `data/`), then:

```bash
cd ~/Documents/Hytale_server
chmod +x hytale-server-bootstrap.sh
./hytale-server-bootstrap.sh
```

The script detects macOS and:

1. Finds Java 25 or downloads Temurin 25 for the Mac's architecture into `.jdk/`
2. Keeps `Server/universe`, `Server/backups`, `Server/auth.key`, and
   `Server/auth.enc` linked to the portable `data/` directory
3. Tunes `jvm.options` for the Mac's RAM (1–4 GB heap on an 8 GB machine)
4. Starts the server natively in a `screen` session named `hytale`

Useful commands:

```bash
# Attach to the server console (detach with Ctrl+A then D)
screen -r hytale

# Live log
tail -f data/server.log

# Stop cleanly
./hytale-server-bootstrap.sh --stop

# Start again
./hytale-server-bootstrap.sh
```

The official Hytale downloader is Linux/Windows-only, so macOS upgrades use the
server's built-in update commands instead:

```bash
screen -r hytale
/update check
/update download
/update apply --confirm
```

`start.sh` applies the staged update and restarts automatically. You can also
copy a fresh `Server/`, `Assets.zip`, and `start.sh` from the Linux machine.

---

## First Boot — Server Authentication

After the server starts you need to authenticate it **once** with your Hytale account.
This is separate from your account login and authorises the server itself to accept connections.

If the script reports that authorization is not configured, attach to the server console.

**Linux / Docker:**

```bash
docker attach hytale-server
```

**macOS:**

```bash
screen -r hytale
```

Inside the server console type:

```
/auth login device
```

> **Important:** use `/auth login device`, not `/auth login`. The plain form tries to open
> a localhost callback URL which doesn't work on a headless server.

Visit the URL shown, enter the code, and approve it in your browser. The server confirms
with `Authentication successful!` and saves the token. Then detach **without stopping the server**:

- Linux/Docker: `Ctrl+P` then `Ctrl+Q`
- macOS: `Ctrl+A` then `D`

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

**Linux (Docker):**

```bash
cd hytale-server
docker compose up -d --build
```

`--build` recreates the image because Docker images are not stored in the folder.
The entrypoint repairs bind-mount ownership automatically, so the server runs as the
user who owns `data/universe`.

**macOS:**

```bash
cd ~/Documents/Hytale_server
./hytale-server-bootstrap.sh
```

The script creates the `Server/universe`, `Server/backups`, and auth symlinks into
`data/`, downloads Java 25 if needed, and starts the server natively. Your world and
authorization are already in `data/`; no re-download and no re-authentication are needed.

If you only want to migrate the world, copy `data/` to a fresh folder and run
`./hytale-server-bootstrap.sh` there. On Linux the script re-downloads the server
binaries; on macOS it expects `Server/`, `Assets.zip`, and `start.sh` to be present.

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
├── .jdk/                           # macOS only — Temurin Java 25 (auto-downloaded)
├── Server/                         # from Hytale archive
│   ├── HytaleServer.jar
│   ├── HytaleServer.aot.config
│   ├── Licenses/
│   ├── universe -> ../data/universe   # macOS symlink
│   ├── backups  -> ../data/backups    # macOS symlink
│   ├── auth.key -> ../data/auth/auth.key  # macOS symlink
│   └── auth.enc -> ../data/auth/auth.enc  # macOS symlink
└── data/                           # persistent state
    ├── universe/                   # ← world data (the only thing you need to back up)
    │   ├── players/                #   player profiles
    │   └── worlds/default/         #   world chunks, resources, config
    ├── backups/                    # ← periodic snapshots from start.sh
    ├── server.log                  # macOS native console log
    └── auth/                       # ← server authorization (never commit)
        ├── auth.key                #   encryption key
        └── auth.enc                #   encrypted server token
```

On Linux, `data/universe`, `data/backups`, and `data/auth` are bind-mounted into the
container. On macOS they are exposed to the native server through symlinks inside
`Server/`. `data/` is owned by the user who ran the bootstrap; the container starts as
root only long enough to repair mount ownership, then drops to that same user before
launching the server.

---

## JVM Memory

Edit `jvm.options` in the **server root** (not `Server/`).

Linux defaults assume ~16 GB RAM:

```
-Xms3g
-Xmx6g
```

macOS defaults are tuned automatically for the machine's RAM. On an 8 GB Mac the
script writes:

```
-Xms1g
-Xmx4g
-XX:+UseG1GC
```

Hytale recommends at least **4 GB of RAM** for the server. Leave headroom for macOS
and the GPU on smaller machines.

Apply changes with:

```bash
# Linux
docker compose restart

# macOS
./hytale-server-bootstrap.sh --stop
./hytale-server-bootstrap.sh
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

### macOS

The official Hytale downloader has no macOS build. Use Hytale's built-in updater from
the server console:

```bash
screen -r hytale
/update check
/update download
/update apply --confirm
```

`start.sh` applies the staged update and restarts the server automatically. You can also
copy fresh `Server/`, `Assets.zip`, and `start.sh` files from the Linux machine. Keep
`data/` unchanged.

Your world data and server auth in `data/` are never touched. `auth.key` and `auth.enc`
travel with the folder, so no server re-authentication is needed after an upgrade.

---

## Auth Files

The server token is stored as two files under `data/auth/`:

- `auth.key` — encryption key
- `auth.enc` — encrypted server token

`auth.key` decrypts `auth.enc`. Both are required.

**Linux / Docker:** `data/auth` is bind-mounted to `/server/auth`, and the container
entrypoint links `/server/Server/auth.key` and `auth.enc` to it:

```
data/auth/auth.key  →  /server/auth/auth.key  →  /server/Server/auth.key (symlink)
data/auth/auth.enc  →  /server/auth/auth.enc  →  /server/Server/auth.enc (symlink)
```

Mounting the **directory** instead of individual files avoids Docker's "missing source
file becomes a directory" trap and makes the pair easy to copy.

**macOS:** the script creates the links directly:

```
Server/auth.key  ->  ../data/auth/auth.key
Server/auth.enc  ->  ../data/auth/auth.enc
```

Once you authenticate with `/auth login device`, the server writes the token directly
into `data/auth/auth.enc`. It persists across all restarts, rebuilds, and folder copies.
The server may refresh `auth.enc` while it runs; copy the whole `data/` folder to keep
another installation in sync.

---

## Common Commands

Linux:

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

macOS:

```bash
# Start in background (screen)
./hytale-server-bootstrap.sh

# Attach to console (detach with Ctrl+A then D)
screen -r hytale

# Tail live logs
tail -f data/server.log

# Stop
./hytale-server-bootstrap.sh --stop

# Apply jvm.options changes
./hytale-server-bootstrap.sh --stop
./hytale-server-bootstrap.sh

# Built-in updater
screen -r hytale
# then: /update check
#       /update download
#       /update apply --confirm
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

**macOS: Java 25 download fails**
The script downloads Temurin 25 from Adoptium into `.jdk/`. If the Mac cannot reach
GitHub, download `OpenJDK25U-jdk_aarch64_mac_hotspot_*.tar.gz` on another machine and
put it in the server folder, then re-run the script. It also accepts a pre-installed
JDK 25 under `/Library/Java/JavaVirtualMachines/temurin-25.jdk` or Homebrew's
`openjdk@25`.

**macOS: `Server/universe is a real directory`**
The script refuses to overwrite an existing world directory. Merge it into the portable
data directory, then re-run:
```bash
mv Server/universe/* data/universe/
rmdir Server/universe
./hytale-server-bootstrap.sh
```

**macOS: players cannot connect**
Allow incoming UDP `5520` if the macOS firewall prompts, and check that the Mac is awake.
The server listens on `0.0.0.0:5520`. For internet play, forward UDP 5520 on the router.

**macOS: server stops when the Mac sleeps**
Disable sleep in System Settings → Energy, or keep the server alive with:
```bash
caffeinate -dimsu
```

**Downloader says `invalid_grant` / refresh token expired**
The bootstrap script handles this automatically on Linux `--upgrade`. To force it manually:
```bash
rm .hytale-downloader-credentials.json
./hytale-server-bootstrap.sh --upgrade
```

---

## Notes

- The server runs on **UDP port 5520** using the QUIC protocol
- Linux uses Docker; macOS runs natively with Java 25 and the `native/osx-arm64` libraries in `HytaleServer.jar`
- For internet play: forward UDP 5520 on your router, or use [Tailscale](https://tailscale.com) for zero-config peer-to-peer VPN — no port forwarding needed
- Hytale's built-in backup runs every 30 minutes by default (`--backup-frequency 30` in `start.sh`) and writes to `data/backups/`
