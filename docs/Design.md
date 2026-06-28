# Design Document — RedmineDocker

## 1. Overview

This document describes the complete architecture for a Redmine platform running on Podman containers, managed by systemd Quadlets, on Red Hat Enterprise Linux 9 (RHEL9) in production and AlmaLinux9 on WSL2 for development.

---

## 2. Component Version Matrix

| Component          | Version    | Notes                                                        |
|--------------------|------------|--------------------------------------------------------------|
| Host OS (Prod)     | RHEL 9.5   | Red Hat Enterprise Linux                                     |
| Host OS (Dev)      | AlmaLinux 9.5 | Running inside WSL2                                       |
| Podman             | 4.9.x      | As shipped with RHEL9 / AlmaLinux9                          |
| PostgreSQL         | **18**     | Provided by the upstream `postgis/postgis:18-master` base image |
| PostGIS            | **master** | Provided by the upstream `postgis/postgis:18-master` base image |
| Redmine            | **6.1.3**  | Latest stable (2026-06-15)                                  |
| Ruby               | **3.4.4**  | Installed via rbenv                                          |
| Bundler            | **2.6.8**  | System gem                                                   |
| Node.js            | **22.23.1** | Active LTS "Jod"; Node.js 18 is EOL as of March 2025       |
| Yarn               | **1.22.22** | Classic Yarn (required by redmine_gtt webpack build)        |
| Apache httpd       | **2.4.62** | Both inside containers and on host                          |
| Puma               | (bundled)  | Ships with Redmine 6.1.3 Gemfile                            |
| Solid Queue        | (via plugin) | Managed by `redmine_solid_queue` plugin                   |

---

## 3. Container Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Host (RHEL9 / AlmaLinux9)            │
│                                                         │
│  Host Apache 2.4 (Port 443 HTTPS)                       │
│  ┌──────────────────────────────────────────────────┐   │
│  │  ProxyPass /redmine       → 127.0.0.1:10080      │   │
│  │  Alias /redmine/files, /assets → host filesystem  │   │
│  └──────────────────────────────────────────────────┘   │
│                                                         │
│  Podman Network: redmine_net (10.89.1.0/24)             │
│  ┌──────────────────┐  ┌──────────────────────────────┐ │
│  │ Docker0          │  │ Docker1 (redmine-prod)        │ │
│  │ redmine-db       │  │ Port: 10080 → 80              │ │
│  │ 10.89.1.10:5432  │  │ Apache + Puma + Redmine 6.1.3 │ │
│  │ PostgreSQL 18    │  │ Sub-URI: /redmine             │ │
│  │ PostGIS master   │  │ DB: redmine_prod              │ │
│  └──────────────────┘  └──────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

---

## 4. Network Design

| Parameter     | Value                       |
|---------------|-----------------------------|
| Network name  | `redmine_net`               |
| Driver        | bridge                      |
| Subnet        | `10.89.1.0/24`              |
| Gateway       | `10.89.1.1`                 |

| Container     | Hostname      | IP Address    | Exposed Port (Host→Container) |
|---------------|---------------|---------------|-------------------------------|
| Docker0       | `redmine-db`  | `10.89.1.10`  | None (internal only)          |
| Docker1       | `redmine-prod`| `10.89.1.11`  | `127.0.0.1:10080 → 80`        |

The database port (5432) is **not** exposed to the host. The Redmine container connects to the database exclusively via the internal `redmine_net` bridge network using hostname `redmine-db`.

---

## 5. Directory Layout on Host

```
/opt/redmine/
├── containers/             # This repository (git clone target)
│   ├── docker0/
│   ├── docker1/
│   ├── quadlets/
│   ├── host-apache/
│   ├── scripts/
│   └── logrotate/
├── data/
│   ├── postgres/           # PostgreSQL 18 data directory (PGDATA root)
│   │   └── 18/
│   │       └── docker/
│   └── redmine1/           # Production Redmine persistent data
│       ├── files/          # Uploaded attachments
│       ├── log/            # Application logs
│       ├── public/
│       │   ├── assets/     # Compiled CSS/JS assets
│       │   └── plugin_assets/
│       └── tmp/
└── backup/
    ├── db/                 # Database dump archives (7 generations)
    └── files/              # Uploaded files archives (7 generations)
```

### Volume Mount Map

| Host Path                              | Container Path                      | Container       |
|----------------------------------------|-------------------------------------|-----------------|
| `/opt/redmine/data/postgres/18`        | `/var/lib/postgresql`               | Docker0         |
| `/opt/redmine/data/redmine1/files`     | `/opt/redmine/app/files`            | Docker1         |
| `/opt/redmine/data/redmine1/log`       | `/opt/redmine/app/log`              | Docker1         |
| `/opt/redmine/data/redmine1/public/assets` | `/opt/redmine/app/public/assets` | Docker1         |
| `/opt/redmine/data/redmine1/public/plugin_assets` | `/opt/redmine/app/public/plugin_assets` | Docker1 |
| `/opt/redmine/data/redmine1/tmp`       | `/opt/redmine/app/tmp`              | Docker1         |

---

## 6. User Accounts, Groups, and Permissions

### Host System Users

| User           | UID  | GID  | Group    | Home             | Purpose                          |
|----------------|------|------|----------|------------------|----------------------------------|
| `postgres`     | 26   | 26   | postgres | `/var/lib/pgsql` | Host bind-mount owner for the PostgreSQL container |
| `redmine_adm`  | 1001 | 1001 | redmine  | `/opt/redmine`   | Redmine app process owner        |

> **Note:** Docker0 remaps the upstream image's `postgres` user to UID 26 so existing host-side bind-mount ownership remains compatible. The `redmine_adm` UID/GID 1001 must still be created identically on the host and inside each Redmine container to ensure bind-mount permissions are consistent.

### Directory Permissions

| Directory                              | Owner              | Mode  | Notes                                  |
|----------------------------------------|--------------------|-------|----------------------------------------|
| `/opt/redmine/`                        | `root:root`        | `755` | Base directory                         |
| `/opt/redmine/containers/`             | `root:root`        | `755` | Repository checkout                    |
| `/opt/redmine/data/`                   | `root:root`        | `755` | Data root                              |
| `/opt/redmine/data/postgres/`          | `postgres:postgres`| `700` | PostgreSQL data root (must be 700)     |
| `/opt/redmine/data/redmine1/`          | `redmine_adm:redmine` | `755` | Redmine1 data root                  |
| `/opt/redmine/data/redmine1/files/`    | `redmine_adm:redmine` | `755` | Uploads (writable by app)            |
| `/opt/redmine/data/redmine1/log/`      | `redmine_adm:redmine` | `755` | Logs (writable by app)               |
| `/opt/redmine/data/redmine1/public/`   | `redmine_adm:redmine` | `755` | Static assets                         |
| `/opt/redmine/data/redmine1/tmp/`      | `redmine_adm:redmine` | `755` | Puma socket, pid                      |
| `/opt/redmine/backup/`                 | `root:root`        | `750` | Backup archive root                   |
| `/opt/redmine/backup/db/`              | `root:root`        | `750` | DB dumps                              |
| `/opt/redmine/backup/files/`           | `root:root`        | `750` | Files archives                        |

### Inside Containers

| Path                      | Owner              | Mode  |
|---------------------------|--------------------|-------|
| `/opt/redmine/app/`       | `redmine_adm:redmine` | `755` |
| `/opt/redmine/app/config/`| `redmine_adm:redmine` | `750` |
| `/opt/redmine/app/files/` | `redmine_adm:redmine` | `755` |
| `/opt/redmine/app/log/`   | `redmine_adm:redmine` | `755` |
| `/opt/redmine/app/tmp/`   | `redmine_adm:redmine` | `755` |
| `/opt/redmine/app/public/`| `redmine_adm:redmine` | `755` |

---

## 7. Database Design

### Databases

| Database Name   | Owner        | Encoding | Extensions        | Used By     |
|-----------------|--------------|----------|-------------------|-------------|
| `redmine_prod`  | `redmine_adm`| UTF8     | postgis, postgis_topology | Docker1 |

### Shared Database Account

| Parameter | Value                    |
|-----------|--------------------------|
| Username  | `redmine_adm`            |
| Password  | 16-char random (see `.env`) |
| Grants    | ALL on respective database |
| Roles     | NOSUPERUSER NOCREATEDB NOCREATEROLE |

The `database.yml` adapter is set to `postgis` (not `postgresql`) to enable spatial features required by the `redmine_gtt` plugin.

---

## 8. Reverse Proxy and Sub-URI Design

### Traffic Flow

```
Client Browser
    │
    ▼ HTTPS :443
Host Apache (TLS termination)
    │  ├── Alias /redmine/files        → /opt/redmine/data/redmine1/files/
    │  ├── Alias /redmine/assets       → /opt/redmine/data/redmine1/public/assets/
    │  ├── Alias /redmine/plugin_assets → /opt/redmine/data/redmine1/public/plugin_assets/
    │  │
    │  └── ProxyPass /redmine          → http://127.0.0.1:10080/redmine (Container1 Apache)
    │
    ▼ HTTP :80 (container-internal)
Container Apache (mod_proxy_http)
    │  ├── Alias /redmine/files        → /opt/redmine/app/files/ (bind-mount)
    │  ├── Alias /redmine/assets       → /opt/redmine/app/public/assets/
    │  ├── Alias /redmine/plugin_assets → /opt/redmine/app/public/plugin_assets/
    │  └── ProxyPass /redmine          → unix:/opt/redmine/app/tmp/puma.sock|http://localhost
    │
    ▼ Unix socket
Puma (RAILS_RELATIVE_URL_ROOT=/redmine)
```

### Sub-URI Assignment

| Container | Sub-URI         | RAILS_RELATIVE_URL_ROOT | Host Port |
|-----------|-----------------|-------------------------|-----------|
| Docker1   | `/redmine`      | `/redmine`              | `10080`   |

---

## 9. Process Management and Fault Tolerance

### Systemd Integration (Quadlets)

All containers are managed via Podman Quadlet unit files placed in `/etc/containers/systemd/`. Systemd auto-generates `.service` units from `.container` and `.network` files on `systemctl daemon-reload`.

| Quadlet File                      | Generated Service              | Restart Policy     |
|-----------------------------------|--------------------------------|--------------------|
| `redmine.network`                 | `redmine-network.service`      | —                  |
| `redmine-db.container`            | `redmine-db.service`           | `on-failure`       |
| `redmine-prod.container`          | `redmine-prod.service`         | `on-failure`       |

### Puma Application Server

Puma is configured with:
- **Workers**: 2 (pre-fork mode for memory efficiency)
- **Threads per worker**: 1–5
- **Socket**: Unix domain socket at `/opt/redmine/app/tmp/puma.sock`
- **PID file**: `/opt/redmine/app/tmp/puma.pid`
- **On-restart**: `touch tmp/restart.txt` triggers graceful restart
- **Solid Queue**: Automatically started as a Puma plugin (via `redmine_solid_queue`)

### Recovery Behavior

| Failure Scenario              | Recovery Action                                            |
|-------------------------------|------------------------------------------------------------|
| Container process crash       | systemd restarts container (RestartSec=10s, max 5 attempts)|
| Puma worker crash             | Puma master restarts the failed worker automatically       |
| Database connection lost      | Puma retries; persistent failure triggers container restart|
| Host reboot                   | All containers auto-start via `WantedBy=multi-user.target` |

---

## 10. Plugins and Themes

### Themes

| Theme         | Branch  | Install Path              | Redmine 6.1 | Notes                        |
|---------------|---------|---------------------------|-------------|------------------------------|
| farend_fancy  | `main`  | `themes/farend_fancy`     | ✅ Verified  | Uses `main` (not `redmine6.0`) for Redmine 6.1 |

### Plugins

| # | Plugin                   | Version  | Redmine 6.1 | Migration | Node.js  | Risk    |
|---|--------------------------|----------|-------------|-----------|----------|---------|
| 1 | redmine_wiki_lists       | 0.0.11   | ⚠️ Unverified| No        | No       | Medium  |
| 2 | redmine_banner           | 0.3.4    | ⚠️ Likely    | Yes       | No       | Medium  |
| 3 | redmine_issues_panel     | 1.2.1    | ✅ CI-tested | No        | No       | Low     |
| 4 | redmica_ui_extension     | 0.6.0    | ✅ CI-tested | No        | No       | Low     |
| 5 | redmine_ip_filter        | 1.1.1    | ✅ CI-tested | No        | No       | Low     |
| 6 | redmine_message_customize| 1.1.0    | ✅ Declared  | No        | No       | Low     |
| 7 | redmine_issue_templates  | 1.2.2    | ✅ CI-tested | Yes       | No*      | Low     |
| 8 | view_customize           | latest   | ✅ Active    | Yes       | No       | Low     |
| 9 | redmine_logs             | 0.4.0    | ✅ CI-tested | No        | No       | Low     |
|10 | redmine_login_audit2     | 1.0.0    | ✅ Declared  | Yes       | No       | Medium† |
|11 | redmine_wiki_extensions  | 1.2.0    | ✅ CI-tested | Yes       | No       | Low     |
|12 | redmine_solid_queue      | 1.0.0    | ✅ Likely    | Yes       | No       | Low     |
|13 | redmine_gtt              | 6.0.3    | ⚠️ Partial   | Yes       | **Yes**  | High‡   |

> *`redmine_issue_templates` JS assets are pre-built in the repo; Node.js is only needed for rebuilding.  
> †`redmine_login_audit2` is a brand-new plugin (initial release April 2026, 3 commits, no CI). Validate thoroughly before production use.  
> ‡`redmine_gtt` is critically important and requires the `postgis` adapter plus a PostGIS-enabled PostgreSQL server.

**Note on `redmine-view-customize-scripts`:** This is a **code example library**, not an installable plugin. The actual plugin to install is `view_customize` (from `https://github.com/onozaty/redmine-view-customize`). After installing the plugin, administrators can paste scripts from the `redmine-view-customize-scripts` repository via Administration → View Customize.

### Plugin Installation Order

Plugins that require database migrations must be installed before running `rake redmine:plugins:migrate`. The recommended installation order within the Containerfile is:

1. Clone all plugins/themes
2. Run `bundle install` (picks up all plugin Gemfiles including `redmine_gtt`, `redmine_solid_queue`)
3. Build `redmine_gtt` frontend: `yarn` + `npx webpack`
4. Run `bundle exec rake redmine:plugins:migrate` (initial setup only)
5. Run `bundle exec rake assets:precompile` with correct `RAILS_RELATIVE_URL_ROOT`

---

## 11. Log Management

- **Application logs** (`production.log`, `puma_access.log`): stored in bind-mounted `/opt/redmine/data/redmine1/log/`
- **Log rotation**: configured via `/etc/logrotate.d/redmine` on the host
- **Retention**: exactly **60 days** (`rotate 60` with `daily`)
- **Container stdout/stderr**: captured by systemd journal (accessible via `journalctl -u redmine-prod`)

---

## 12. Backup Strategy

- **Frequency**: Daily (cron at 02:00)
- **Retention**: exactly **7 generations** (weekly full + daily, pruned to 7)
- **Scope**:
  - PostgreSQL: `pg_dump` of `redmine_prod` to a compressed `.dump` file
  - Files: tar+gzip of `/opt/redmine/data/redmine1/files/`
- **Storage**: `/opt/redmine/backup/db/` and `/opt/redmine/backup/files/`
- **Rotation**: after each backup, files older than 7 backups are deleted

---

## 13. Security Considerations

- The database port 5432 is not exposed outside the Podman network.
- Host Apache adds `X-Forwarded-For` headers; `redmine_ip_filter` must be configured accordingly.
- TLS is terminated at the host Apache (certificate managed on host).
- Container filesystems are read-only except for bind-mounted data volumes.
- `REDMINE_SECRET_TOKEN` is generated once (`bundle exec rake secret`) and stored in `.env`.
- All passwords are 16-character random alphanumeric strings generated by `scripts/generate-env.sh`.
