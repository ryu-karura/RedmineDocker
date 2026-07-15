# Setup Guide — RedmineDocker

This guide covers the **production** deployment with Podman + systemd
Quadlets. For development in GitHub Codespaces (Docker + Compose), see
[Development in GitHub Codespaces](#development-in-github-codespaces) at the
end of this document.

## Prerequisites

- Red Hat Enterprise Linux 9.5 (production) or AlmaLinux 9.5 on WSL2 (development)
- Root or sudo access
- Internet access from the host (to pull container images and clone repositories)
- A valid FQDN with TLS certificate for the host Apache
- Git installed on the host

---

## Step 0: Clone This Repository

```bash
sudo mkdir -p /opt/redmine
sudo git clone https://github.com/ryu-karura/RedmineDocker.git /opt/redmine/containers
```

---

## Step 1: Generate Environment Variables

All passwords are 16-character random alphanumeric strings. Never edit `.env` by hand for passwords — use the provided script.

```bash
cd /opt/redmine/containers
sudo bash scripts/generate-env.sh
```

This creates `/opt/redmine/containers/.env` with:
- `POSTGRES_SUPERUSER_PASSWORD` / `POSTGRES_PASSWORD` — PostgreSQL `postgres` superuser password
- `REDMINE_DB_PASSWORD` — Redmine database user password
- `REDMINE_SECRET_TOKEN` — Redmine production secret key base

> `.env` is excluded from git via `.gitignore`. Keep it secure. Back it up separately.

---

## Step 2: Install Podman on the Host

### RHEL9 / AlmaLinux9

```bash
sudo dnf install -y podman podman-compose
sudo systemctl enable --now podman.socket
```

Verify:

```bash
podman --version
# Expected: podman version 4.9.x or newer
```

### WSL2 (AlmaLinux9) — Development Only

On WSL2 the systemd integration requires WSL2 with systemd enabled. Edit `/etc/wsl.conf`:

```ini
[boot]
systemd=true
```

Restart WSL2 (`wsl --shutdown` from Windows, then reopen the distribution), then install Podman as above.

---

## Step 3: Create Host System Users

```bash
# Create redmine group and redmine_adm user
sudo groupadd --gid 1001 redmine
sudo useradd --uid 1001 --gid 1001 --home /opt/redmine --no-create-home \
    --shell /sbin/nologin redmine_adm

# The postgres user (UID 26) is used for host-side bind-mount ownership
# compatibility with the redmine-db container. Ensure it exists or create it if needed:
# sudo groupadd --gid 26 postgres
# sudo useradd --uid 26 --gid 26 --home /var/lib/pgsql --no-create-home \
#     --shell /bin/bash postgres
```

---

## Step 4: Create Data Directory Structure

```bash
# The redmine-db container mounts /opt/redmine/data/postgres/18 at /var/lib/postgresql.
# The upstream PostgreSQL 18 image stores PGDATA in the 18/docker subdirectory.
sudo mkdir -p /opt/redmine/data/postgres/18/docker
sudo mkdir -p /opt/redmine/data/redmine1/{files,log,public/{assets,plugin_assets},tmp}
sudo mkdir -p /opt/redmine/backup/{db,files}

# Set ownership
sudo chown -R postgres:postgres /opt/redmine/data/postgres
sudo chmod -R 700 /opt/redmine/data/postgres

sudo chown -R redmine_adm:redmine /opt/redmine/data/redmine1
sudo chmod -R 755 /opt/redmine/data/redmine1

sudo chown -R root:root /opt/redmine/backup
sudo chmod -R 750 /opt/redmine/backup
```

---

## Step 5: Build Container Images

Build all container images from the repository root. Source the `.env` file first to pass build arguments:

```bash
cd /opt/redmine/containers
source .env

# Build Database container (redmine-db)
podman build \
    -f containers/redmine-db/Containerfile \
    -t localhost/redmine-db:18-master \
    containers/redmine-db/

# Build Production Redmine container (redmine-prod)
podman build \
    -t localhost/redmine-prod:6.1.3 \
    containers/redmine-prod/
```

> Build times are significant (15–40 minutes per Redmine image) due to Ruby compilation, gem installation, and plugin asset compilation. Ensure adequate disk space (≥10 GB free per image).

---

## Step 6: Install Systemd Quadlet Unit Files

Quadlet files are placed in `/etc/containers/systemd/` for system-wide management.

```bash
sudo cp /opt/redmine/containers/quadlets/redmine.network /etc/containers/systemd/
sudo cp /opt/redmine/containers/quadlets/redmine-db.container /etc/containers/systemd/
sudo cp /opt/redmine/containers/quadlets/redmine-prod.container /etc/containers/systemd/

# Reload systemd to process the Quadlet files
sudo systemctl daemon-reload
```

Verify the generated service units:

```bash
systemctl list-unit-files | grep redmine
# Expected output:
# redmine-db.service       generated
# redmine-prod.service     generated
```

---

## Step 7: Configure the .env File for Quadlets

The Quadlet container files reference `/opt/redmine/containers/.env` for environment variable injection. Verify the path:

```bash
grep EnvironmentFile /etc/containers/systemd/redmine-prod.container
# Expected: EnvironmentFile=/opt/redmine/containers/.env
```

---

## Step 8: Start the Database Container

```bash
sudo systemctl start redmine-db
sudo systemctl status redmine-db

# Verify PostgreSQL is accepting connections
podman exec redmine-db psql -U postgres -c "\l"
# Should list: redmine_prod
```

---

## Step 9: Initialize Redmine Databases

Database migrations are run automatically on first start via the container entrypoint. However, you must start the containers once to perform the initial setup:

```bash
# Start production environment
sudo systemctl start redmine-prod
sudo journalctl -u redmine-prod -f
# Wait for: "Puma 6.x.x ... Listening on unix:///opt/redmine/app/tmp/puma.sock"
```

---

## Step 10: Enable Auto-Start on Boot

```bash
sudo systemctl enable redmine-db
sudo systemctl enable redmine-prod
```

---

## Step 11: Configure Host Apache as Reverse Proxy

### Install Apache and Required Modules

```bash
sudo dnf install -y httpd mod_ssl
sudo systemctl enable --now httpd
```

### Install the Reverse Proxy Configuration

```bash
sudo cp /opt/redmine/containers/host-apache/redmine-proxy.conf \
    /etc/httpd/conf.d/redmine-proxy.conf
```

Edit the file to set your actual hostname and TLS certificate paths:

```bash
sudo vi /etc/httpd/conf.d/redmine-proxy.conf
# Replace: ServerName redmine.example.com
# Replace: SSLCertificateFile and SSLCertificateKeyFile paths
```

### Enable Required Apache Modules

```bash
# Verify these are loaded (they should be with mod_ssl package):
sudo httpd -M | grep -E 'proxy|ssl|alias|headers'
# Expected: proxy_module, proxy_http_module, ssl_module, alias_module, headers_module
```

### Add X-Forwarded-For Protection (Security)

The `redmine_ip_filter` plugin requires that `X-Forwarded-For` headers not be spoofed. Ensure the reverse proxy config includes:

```apache
RequestHeader unset X-Forwarded-For
RequestHeader set X-Forwarded-For "%{REMOTE_ADDR}s"
```

This is already included in `host-apache/redmine-proxy.conf`.

### Test and Reload Apache

```bash
sudo httpd -t
sudo systemctl reload httpd
```

---

## Step 12: Install Log Rotation

```bash
sudo cp /opt/redmine/containers/logrotate/redmine /etc/logrotate.d/redmine
sudo logrotate --debug /etc/logrotate.d/redmine
```

---

## Step 13: Install Backup Cron Job

```bash
# Install backup script
sudo chmod +x /opt/redmine/containers/scripts/backup.sh
sudo chmod +x /opt/redmine/containers/scripts/restore.sh

# Add daily cron job at 02:00
echo "0 2 * * * root /opt/redmine/containers/scripts/backup.sh >> /var/log/redmine-backup.log 2>&1" \
    | sudo tee /etc/cron.d/redmine-backup

sudo chmod 644 /etc/cron.d/redmine-backup
```

---

## Step 14: Post-Installation Redmine Configuration

Access the Redmine instance through the browser and complete initial setup:

### Production (redmine-prod)

1. Browse to `https://your-host/redmine`
2. Log in with default credentials: `admin` / `admin`
3. **Immediately change the admin password**
4. Go to **Administration → Settings → Display** → Theme: select **Farend fancy** → Save
5. Go to **Administration → Plugins** and verify all 13 plugins are listed
6. Go to **Administration → IP Filter** → configure allowed IP ranges
7. Go to **Administration → Message Customize** → review default messages
8. Go to **Administration → Information** → verify Solid Queue is enabled

---

## Step 15: SELinux Configuration (RHEL9)

RHEL9 runs SELinux in enforcing mode by default. The following contexts are required:

```bash
# Allow httpd to connect to network (for ProxyPass to container ports)
sudo setsebool -P httpd_can_network_connect 1

# Allow httpd to read the bind-mounted static files
sudo semanage fcontext -a -t httpd_sys_content_t \
    "/opt/redmine/data/redmine1/public(/.*)?"
sudo semanage fcontext -a -t httpd_sys_content_t \
    "/opt/redmine/data/redmine1/files(/.*)?"

sudo restorecon -Rv /opt/redmine/data/

# Allow Podman containers to read/write bind-mount directories
# (Podman uses container_file_t; the data dirs need to allow this)
sudo semanage fcontext -a -t container_file_t \
    "/opt/redmine/data(/.*)?"
sudo restorecon -Rv /opt/redmine/data/
```

---

## Verification Checklist

After completing all steps, verify the following:

- [ ] `podman ps` shows both containers as `Up`
- [ ] `systemctl status redmine-db` shows `active (running)`
- [ ] `systemctl status redmine-prod` shows `active (running)`
- [ ] `https://your-host/redmine` loads the Redmine login page
- [ ] All 13 plugins appear in Administration → Plugins in production
- [ ] Farend fancy theme is active in production
- [ ] Solid Queue is shown as enabled in Administration → Information
- [ ] Backup cron job is installed: `cat /etc/cron.d/redmine-backup`
- [ ] Log rotation is installed: `cat /etc/logrotate.d/redmine`
- [ ] `logrotate --debug /etc/logrotate.d/redmine` exits without error

---

## Upgrading Redmine

To upgrade to a new Redmine patch release (e.g., 6.1.3 → 6.1.4):

1. Update `REDMINE_VERSION` build argument in `containers/redmine-prod/Containerfile`
2. Rebuild the image: `podman build -t localhost/redmine-prod:6.1.4 containers/redmine-prod/`
3. Update the image reference in `quadlets/redmine-prod.container`
4. `sudo systemctl daemon-reload && sudo systemctl restart redmine-prod`

---

## Firewall Configuration

```bash
# Allow HTTPS (443) from outside
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --reload

# Container port (10080) is bound to 127.0.0.1 — no firewall rule needed
# as it is only accessed by the local host Apache

# Verify
sudo firewall-cmd --list-all
```

---

## Development in GitHub Codespaces

GitHub Codespaces runs the workspace inside a dev container, and Podman
does not work in that nested, rootless environment. Development therefore
uses **Docker** (provided by the `docker-in-docker` dev container feature
in `.devcontainer/devcontainer.json`) with **`compose.dev.yaml`** in place
of the Quadlet units. The container images themselves are identical — the
same Containerfiles are built by both runtimes.

Differences from production:

| Aspect            | Production (this guide)          | Codespaces development          |
|-------------------|----------------------------------|---------------------------------|
| Runtime           | Podman 4.9.x                     | Docker (docker-in-docker)       |
| Orchestration     | systemd Quadlets (`quadlets/`)   | `compose.dev.yaml`              |
| Persistent data   | Bind mounts under `/opt/redmine` | Named Docker volumes            |
| Reverse proxy/TLS | Host Apache on port 443          | None — port 10080 is forwarded  |
| `.env` location   | `/opt/redmine/containers/.env`   | Repository root `./.env`        |

Steps:

```bash
# 1. Generate .env in the repository root (no sudo needed)
bash scripts/generate-env.sh

# 2. Build and start the stack (first build takes 15–40 minutes)
docker compose -f compose.dev.yaml up --build -d

# 3. Follow the logs until Puma is listening
docker compose -f compose.dev.yaml logs -f redmine-prod
# Wait for: "Puma 6.x.x ... Listening on unix:///opt/redmine/app/tmp/puma.sock"
```

Then open the forwarded port **10080** in the Codespaces "Ports" panel and
browse to `/redmine` (default login: `admin` / `admin`).

To stop and reset:

```bash
docker compose -f compose.dev.yaml down        # keep data volumes
docker compose -f compose.dev.yaml down -v     # discard data volumes
```
