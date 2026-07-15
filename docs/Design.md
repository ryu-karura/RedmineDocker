# Design Document — RedmineDocker (hwins stack)

## 1. Overview

RedmineDocker runs Redmine 6.1.3 as three cooperating containers. The design
follows the [redmine.jp Docker guide](https://blog.redmine.jp/articles/6_1/redmine-6_1-docker/)
— use the **official** `redmine` image (no custom Ruby build), keep credentials
in **file-based secrets**, and drive everything from a single compose/quadlet
definition — extended into a three-tier topology and adjusted to the values
mandated for this deployment.

| Item                     | Value                                   |
|--------------------------|-----------------------------------------|
| WSL distribution         | `AlmaLinux9`                            |
| Linux admin user         | `hwins`                                 |
| Linux root directory     | `/opt/hwins`                            |
| Rootless Podman network  | `hwins-net`                             |
| Redmine image            | `docker.io/library/redmine:6.1.3`       |
| PostgreSQL / PostGIS     | `docker.io/postgis/postgis:18-3.6`      |
| Container Apache         | `docker.io/library/httpd:2.4` (digest-pinned) |
| DB name / owner          | `redmine` / `redmine`                   |
| DB container             | `hwins-db`                              |
| Redmine / Puma container | `hwins-redmine`                         |
| Static / proxy container | `hwins-static`                          |
| Puma internal port       | `3000` (not published)                  |
| PostgreSQL internal port | `5432` (not published)                  |
| Static host port         | `127.0.0.1:18080`                       |
| Public URL               | `http://localhost/redmine/`             |

## 2. Topology

```
 client ──443──► Host Apache ──/redmine──► hwins-static (httpd 2.4, :18080)
                                                   │ ProxyPass /redmine → hwins-redmine:3000
                                                   ▼
                                            hwins-redmine (Puma :3000, sub-URI /redmine)
                                                   │ postgis adapter
                                                   ▼
                                            hwins-db (PostgreSQL 18 + PostGIS 3.6, :5432)
```

- Only `hwins-static` is published, bound to loopback `127.0.0.1:18080`. The host
  Apache (`host-apache/redmine-proxy.conf`) terminates TLS and proxies `/redmine`.
- PostgreSQL (5432) and Puma (3000) are never exposed to the host.
- Containers communicate over the `hwins-net` bridge and resolve each other by
  name (`hwins-db`, `hwins-redmine`, `hwins-static`).

## 3. Container responsibilities

### hwins-db (`containers/hwins-db/`)
- Base `postgis/postgis:18-3.6`. `POSTGRES_USER=redmine`, `POSTGRES_DB=redmine`,
  `POSTGRES_PASSWORD_FILE=/run/secrets/db_password`.
- The single `redmine` role owns the `redmine` database (blog's single-user
  model). `init-redmine.sh` ensures the `postgis`/`postgis_topology` extensions
  exist (idempotent; the base image already enables them at first init).

### hwins-redmine (`containers/hwins-redmine/`)
- Base `redmine:6.1.3` (official; bundles Ruby, Bundler, Puma, gems).
- Adds: Japanese CJK fonts (PDF/Gantt), the 13-plugin stack + `farend_fancy`
  theme, and the `redmine_gtt` webpack build (yarn). Plugin gems are baked via
  `bundle install`.
- Runs as the image's `redmine` user; Puma listens on `:3000` under sub-URI
  `/redmine` (`RAILS_RELATIVE_URL_ROOT`).
- `entrypoint.sh` resolves secrets (supports `*_FILE`), renders
  `config/database.yml` with the **`postgis`** adapter (required by redmine_gtt —
  the official image's env-driven database.yml only knows `postgresql`), renders
  `config/configuration.yml` (SMTP), waits for the DB, runs core + plugin
  migrations, and execs `rails server` (Puma).

### hwins-static (`containers/hwins-static/`)
- Base `httpd:2.4`, pinned by digest via `scripts/pin-static-image.sh`.
- Reverse-proxies `/redmine` to `hwins-redmine:3000`. Redmine serves its own
  static assets on that port (as the official image does when run directly), so
  no shared asset volume is required. Adds baseline security headers.

## 4. Data & persistence

| Path (host, production)              | Mounted in       | Contents                    |
|--------------------------------------|------------------|-----------------------------|
| `/opt/hwins/data/postgres/18`        | hwins-db         | PostgreSQL data directory   |
| `/opt/hwins/data/redmine/files`      | hwins-redmine    | Uploaded attachments        |
| `/opt/hwins/data/redmine/log`        | hwins-redmine    | Redmine `production.log`    |
| `/opt/hwins/backup/{db,files}`       | host             | Backups (see Manual)        |

In development (`compose.dev.yaml`) these are named volumes (`pgdata`,
`hwins_files`) instead of host bind-mounts. Plugins and the theme are baked into
the image and are **not** volume-mounted (a volume would shadow them).

## 5. Secrets

Two secrets, as files, never plain env:

| Secret            | Consumed by                | Source file                      |
|-------------------|----------------------------|----------------------------------|
| `db_password`     | hwins-db, hwins-redmine    | `secrets/db_password.txt`        |
| `secret_key_base` | hwins-redmine              | `secrets/secret_key_base.txt`    |

`scripts/generate-secrets.sh` creates the files (mode 600, git-ignored). In dev
they are wired via Compose `secrets:`; in prod they are registered with
`podman secret create` and referenced by the quadlet `Secret=` directives, which
mount them at `/run/secrets/<name>`.

## 6. Users & permissions

- Inside the containers the official images' own users apply: `redmine` (Redmine
  app) and `postgres`/`redmine` (database). No custom UID/GID remap is performed
  — this is a deliberate simplification over the previous rbenv-based image.
- On the host, the `hwins` admin user owns `/opt/hwins`. With rootless Podman the
  container users map to the invoking user's subordinate UID range; host
  bind-mount ownership is managed with `:Z` SELinux relabeling.

## 7. Notes / caveats

- The httpd base image ships as the moving `2.4` tag and must be pinned by
  digest after the first pull (`scripts/pin-static-image.sh`), per project policy.
- Serving Redmine static assets directly from `hwins-static` (via a shared
  `public/` volume) is a possible future optimization; the current design keeps
  asset serving in Redmine for robustness.
