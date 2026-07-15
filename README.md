# RedmineDocker (hwins stack)

**Redmine 6.1 container platform for rootless Podman on RHEL9 / AlmaLinux9**

This repository builds, deploys, and operates a Redmine platform as three
containers managed by systemd Quadlets in production, and by Docker Compose in
development. The design follows the [redmine.jp Docker guide](https://blog.redmine.jp/articles/6_1/redmine-6_1-docker/)
(official Redmine image + Docker secrets), extended into a three-tier topology.

---

## Architecture

```
 client ──443──► Host Apache ──/redmine──► hwins-static (httpd 2.4)
                 (TLS, HSTS)   127.0.0.1:18080   │  ProxyPass /redmine
                                                 ▼
                                          hwins-redmine (Redmine 6.1.3 + plugins)
                                          Puma :3000  (sub-URI /redmine)
                                                 │
                                                 ▼
                                          hwins-db (PostgreSQL 18 + PostGIS 3.6)
                                          :5432   DB=redmine / owner=redmine
```

| Container       | Build context               | Image                         | Role                                  | Published            |
|-----------------|-----------------------------|-------------------------------|---------------------------------------|----------------------|
| `hwins-db`      | `containers/hwins-db/`      | `postgis/postgis:18-3.6`      | PostgreSQL 18 + PostGIS 3.6           | no (internal 5432)   |
| `hwins-redmine` | `containers/hwins-redmine/` | `redmine:6.1.3` + plugin stack | Redmine app, Puma                     | no (internal 3000)   |
| `hwins-static`  | `containers/hwins-static/`  | `httpd:2.4` (digest-pinned)   | Reverse proxy / public web tier       | `127.0.0.1:18080`    |

Only `hwins-static` is published, on loopback. The host Apache terminates TLS on
443 and proxies `/redmine` to it. Neither PostgreSQL (5432) nor Puma (3000) is
reachable from the host.

- **Network:** `hwins-net` (Podman quadlet network / Compose bridge). Containers
  resolve each other by name.
- **Public URL:** `http://localhost/redmine/` (sub-URI `/redmine`).
- **Secrets:** `db_password` and `secret_key_base` are file-based secrets
  (Docker secrets in dev, Podman secrets in prod) — never plain environment
  variables. Generate them with `scripts/generate-secrets.sh`.

---

## Component versions

| Component     | Value                              |
|---------------|------------------------------------|
| OS (host/WSL) | AlmaLinux9 / RHEL9                  |
| Redmine       | 6.1.3 (`docker.io/library/redmine:6.1.3`) |
| PostgreSQL    | 18 + PostGIS 3.6 (`postgis/postgis:18-3.6`) |
| Web tier      | Apache httpd 2.4 (`httpd:2.4`, digest-pinned) |
| Ruby / Puma   | bundled with the official Redmine image |
| Node.js/Yarn  | Debian `nodejs` + Yarn 1.22.22 (redmine_gtt webpack build) |

Plugins baked into `hwins-redmine` (13): redmine_wiki_lists, redmine_banner,
redmine_issues_panel, redmica_ui_extension, redmine_ip_filter,
redmine_message_customize, redmine_issue_templates, view_customize, redmine_logs,
redmine_login_audit2, redmine_wiki_extensions, redmine_solid_queue, redmine_gtt.
Theme: farend_fancy. `redmine_gtt` requires PostGIS and the `postgis` database
adapter (configured in `containers/hwins-redmine/database.yml.tmpl`).

---

## Repository structure

```
RedmineDocker/
├── README.md
├── docs/                         # Design / Setup / Manual
├── containers/
│   ├── hwins-db/                 # PostgreSQL 18 + PostGIS 3.6
│   ├── hwins-redmine/            # Redmine 6.1.3 + plugin/theme stack
│   └── hwins-static/             # Apache httpd 2.4 reverse proxy
├── quadlets/                     # Podman Quadlet units (production)
│   ├── hwins.network
│   ├── hwins-db.container
│   ├── hwins-redmine.container
│   └── hwins-static.container
├── host-apache/                  # Host Apache reverse proxy (TLS)
├── scripts/                      # generate-secrets, pin-static-image, backup, restore
├── logrotate/                    # Log rotation
├── compose.dev.yaml              # Docker Compose (development)
├── .devcontainer/                # GitHub Codespaces / VS Code dev container
├── .env.example                  # Optional non-secret (SMTP/TZ) template
└── .gitignore
```

---

## Quick start (development / Codespaces)

```bash
bash scripts/generate-secrets.sh                 # creates ./secrets/*.txt
docker compose -f compose.dev.yaml up --build -d  # first build is slow (plugins + webpack)
# then open the forwarded port:
#   http://localhost:18080/redmine/   (default login: admin / admin)
```

`compose.dev.yaml` uses named volumes, so data survives `docker compose down`.

Optional, on a networked host, to pin the httpd base image by digest (issue #18):

```bash
bash scripts/pin-static-image.sh
```

---

## Quick start (production, Podman + Quadlets)

1. Clone this repository to `/opt/hwins/containers` on the AlmaLinux9 host.
2. `bash scripts/generate-secrets.sh`, then register the secrets:
   `podman secret create db_password secrets/db_password.txt` and
   `podman secret create secret_key_base secrets/secret_key_base.txt`.
3. Build the images and install the Quadlet units — see `docs/Setup.md`.

---

## Documentation

- **[Design](docs/Design.md)** — architecture, network, data layout, secrets.
- **[Setup](docs/Setup.md)** — installation for production and development.
- **[Manual](docs/Manual.md)** — backup, restore, log management.

## License

See [LICENSE](LICENSE).
