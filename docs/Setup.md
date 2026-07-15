# Setup Guide — RedmineDocker (hwins stack)

Two deployment paths are covered:

- **Development** — Docker Compose (GitHub Codespaces or any Docker host).
- **Production** — rootless Podman + systemd Quadlets on AlmaLinux9 / RHEL9.

Both build the same three images from `containers/` and differ only in
orchestration and where data lives.

---

## Development (Docker Compose)

Prerequisites: Docker Engine + Docker Compose v2.

```bash
# 1. Generate the secret files (db_password.txt, secret_key_base.txt)
bash scripts/generate-secrets.sh

# 2. Build and start the three containers
docker compose -f compose.dev.yaml up --build -d
#    The first build is slow: it compiles plugin gems and runs the
#    redmine_gtt webpack build.

# 3. Watch startup (migrations run in hwins-redmine's entrypoint)
docker compose -f compose.dev.yaml logs -f hwins-redmine

# 4. Open the app
#    http://localhost:18080/redmine/     (default login: admin / admin)
```

Stop with `docker compose -f compose.dev.yaml down` (named volumes persist), or
`down -v` to discard data.

Optional — pin the httpd base image by digest (needs registry access):

```bash
bash scripts/pin-static-image.sh
```

---

## Production (Podman + Quadlets)

Prerequisites: AlmaLinux9 / RHEL9 with Podman 4.9+, an admin user `hwins`, and a
host Apache for TLS termination.

### 1. Place the repository

```bash
sudo mkdir -p /opt/hwins/containers
sudo git clone <this-repo> /opt/hwins/containers
sudo mkdir -p /opt/hwins/data/postgres/18 \
              /opt/hwins/data/redmine/files \
              /opt/hwins/data/redmine/log \
              /opt/hwins/backup/db /opt/hwins/backup/files
```

### 2. Generate and register secrets

```bash
cd /opt/hwins/containers
bash scripts/generate-secrets.sh
podman secret create db_password     secrets/db_password.txt
podman secret create secret_key_base secrets/secret_key_base.txt
```

Optionally create `/opt/hwins/containers/.env` (from `.env.example`) for SMTP.

### 3. Build the images

```bash
cd /opt/hwins/containers
# Pin the httpd digest first (recommended):
bash scripts/pin-static-image.sh
podman build -t localhost/hwins-db:18-3.6      containers/hwins-db
podman build -t localhost/hwins-redmine:6.1.3  containers/hwins-redmine
podman build -t localhost/hwins-static:2.4     containers/hwins-static
```

### 4. Install the Quadlet units

```bash
sudo cp quadlets/hwins.network            /etc/containers/systemd/
sudo cp quadlets/hwins-db.container       /etc/containers/systemd/
sudo cp quadlets/hwins-redmine.container  /etc/containers/systemd/
sudo cp quadlets/hwins-static.container   /etc/containers/systemd/
sudo systemctl daemon-reload
sudo systemctl start hwins-db hwins-redmine hwins-static
```

Startup order is enforced by the units (`hwins-static` → `hwins-redmine` →
`hwins-db`). Check health with `systemctl status hwins-redmine` and
`podman healthcheck run hwins-redmine`.

### 5. Configure the host Apache (TLS)

Edit `host-apache/redmine-proxy.conf` (set `YOUR_HOSTNAME` and certificate
paths), then:

```bash
sudo cp host-apache/redmine-proxy.conf /etc/httpd/conf.d/redmine-proxy.conf
sudo systemctl reload httpd
```

The host Apache proxies `https://<host>/redmine` to `127.0.0.1:18080`.

### 6. Post-install

- Log in at the public URL as `admin` / `admin` and change the password.
- Load Japanese default data if desired:
  ```bash
  podman exec -e RAILS_ENV=production hwins-redmine \
      bundle exec rake redmine:load_default_data REDMINE_LANG=ja
  ```
- Install log rotation: `sudo cp logrotate/redmine /etc/logrotate.d/hwins-redmine`.
- Schedule backups: see `docs/Manual.md`.

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| hwins-redmine restarts / migrations fail | `podman logs hwins-redmine`; verify `db_password` secret matches hwins-db |
| 503 from `/redmine` | hwins-redmine not healthy yet (first boot builds/migrates); wait for its healthcheck |
| redmine_gtt map errors | confirm `hwins-db` has PostGIS and database.yml uses the `postgis` adapter |
| Static image not pinned | run `scripts/pin-static-image.sh` on a networked host |
