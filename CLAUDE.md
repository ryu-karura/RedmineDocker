# CLAUDE.md

Guidance for AI assistants working in this repository.

## What this repository is

RedmineDocker (the **redmine stack**) is container infrastructure for running
**Redmine 6.1.3** on RHEL9 / AlmaLinux9. There is **no Redmine application
source code here** — Redmine, its Ruby/Puma runtime, and its gems come from the
official `redmine:6.1.3` image. This repo is the *packaging and operations*
layer around it: Containerfiles, rendered config templates, an entrypoint,
systemd Quadlet units, host Apache config, and operational shell scripts.

The design follows the [redmine.jp 6.1 Docker guide](https://blog.redmine.jp/articles/6_1/redmine-6_1-docker/),
extended into a **two-tier** stack with file-based secrets.

Two orchestration paths share the **same two images** and only differ in
orchestration + data placement:
- **Development** — Docker Compose (`compose.dev.yaml`), named volumes.
- **Production** — rootless Podman + systemd Quadlets (`quadlets/`), host bind
  mounts under `/opt/redmine`.

## Architecture (two tiers)

```
client ──443──► Host Apache ──/redmine──► redmine-web (Apache 2.4 + Redmine 6.1.3)
                (TLS, HSTS)   127.0.0.1:80  │  ProxyPass /redmine
                                               ▼
                                        Puma :3000 (sub-URI /redmine)
                                               │  postgis adapter
                                               ▼
                                        redmine-db (PostgreSQL 18 + PostGIS 3.6, :5432)
```

| Container | Build context | Base image | Role | Exposed |
|-----------|---------------|------------|------|---------|
| `redmine-db` | `containers/redmine-db/` | `postgis/postgis:18-3.6` | PostgreSQL 18 + PostGIS 3.6 | internal `:5432` only |
| `redmine-web` | `containers/redmine-web/` | `redmine:6.1.3` | Redmine app + 13 plugins + theme, Apache 2.4 frontend, Puma | `127.0.0.1:80` |

**Only `redmine-web` is published**, and only to loopback. In production the
host Apache terminates TLS on 443 and forwards `/redmine` there. PostgreSQL
(5432) and Puma (3000) are never reachable from the host. Containers resolve
each other by name on the `redmine-net` bridge network. Public URL:
`http://localhost/redmine/` (sub-URI `/redmine`).

## Repository layout

```
RedmineDocker/
├── README.md                    # overview (Japanese)
├── docs/                        # Design.md / Setup.md / Manual.md (Japanese)
├── containers/
│   ├── redmine-db/                # Containerfile + init-redmine.sh (PostGIS ext)
│   └── redmine-web/           # Containerfile, entrypoint.sh, httpd-redmine.conf, *.yml.tmpl
├── quadlets/                    # production Podman Quadlet units (*.container, *.network)
├── host-apache/                 # host-side TLS reverse proxy vhost
├── scripts/                     # generate-secrets, backup, restore
├── logrotate/                   # /etc/logrotate.d config
├── compose.dev.yaml             # development orchestration
├── .devcontainer/               # Codespaces / VS Code dev container
├── .env.example                 # optional NON-secret overrides (SMTP, TZ)
└── .gitignore
```

## Component versions

| Component | Value |
|-----------|-------|
| Host OS | AlmaLinux9 / RHEL9 |
| Redmine | 6.1.3 (`docker.io/library/redmine:6.1.3`) |
| PostgreSQL / PostGIS | 18 + 3.6 (`postgis/postgis:18-3.6`) |
| Web tier | Apache httpd 2.4 (digest-pinned) |
| Node.js / Yarn | Debian `nodejs` + Yarn 1.22.22 (for `redmine_gtt` webpack build) |

`redmine-web` bakes in 13 plugins (see the numbered list in
`containers/redmine-web/Containerfile`) plus the `farend_fancy` theme. All
plugins/themes are `git clone`d **at build time** so they are reproducible in
the image — update a plugin by editing the Containerfile and rebuilding, not by
mounting a volume.

## Development workflow (Docker Compose / Codespaces)

```bash
bash scripts/generate-secrets.sh                    # creates ./secrets/*.txt (git-ignored)
docker compose -f compose.dev.yaml up --build -d    # first build is slow: plugin gems + webpack
docker compose -f compose.dev.yaml logs -f redmine-web   # watch migrations run
# Open http://localhost:8080/redmine/   (initial login: admin / admin)
```

- `docker compose ... down` keeps data (named volumes `pgdata`, `redmine_files`);
  `down -v` destroys it.
- The dev container (`.devcontainer/`) provisions docker-in-docker and installs
  `shellcheck`; port 80 is auto-forwarded for the local development endpoint.

## Production workflow (rootless Podman + Quadlets)

Runs **rootless** as the unprivileged `redmine` user; all Podman state, secrets,
and Quadlet units are per-user (`systemctl --user`). Only the host Apache is a
system service. Full steps are in `docs/Setup.md`; the shape:

1. `sudo` once: create `/opt/redmine` owned by `redmine`, `loginctl enable-linger redmine`.
2. Clone repo to `/opt/redmine/containers`; create `/opt/redmine/data/{postgres/18,redmine/{files,log}}` and `/opt/redmine/backup/{db,files}`.
3. `bash scripts/generate-secrets.sh` then `podman secret create db_password …` / `secret_key_base …`.
4. `podman build` the two images (`redmine-db` and `redmine-web`).
5. Copy `quadlets/*` to `~/.config/containers/systemd/`, `systemctl --user daemon-reload`, start.

Start/stop order is enforced by `Requires=`/`After=` in the units:
`redmine-db → redmine-web` up, reverse down.

## Key conventions — follow these

- **Secrets are files, never plain env vars, never committed.** Two secrets:
  `db_password` and `secret_key_base`, produced by
  `scripts/generate-secrets.sh` under `secrets/` (mode 600, git-ignored). They
  reach containers via Docker/Podman secrets mounted at `/run/secrets/<name>`.
  Code reads them through **`*_FILE` indirection** (e.g.
  `REDMINE_DB_PASSWORD_FILE`); `entrypoint.sh::resolve_secret` reads the file if
  `${VAR}_FILE` is set, else falls back to `${VAR}`. Never introduce a plaintext
  password into a Containerfile, compose file, quadlet, or committed `.env`.
  `.env` holds only NON-secret overrides (SMTP, TZ) — see `.env.example`.
- **The database adapter is `postgis`, not `postgresql`.** Required by the
  `redmine_gtt` plugin; using `postgresql` breaks startup. This is why
  `entrypoint.sh` renders `config/database.yml` from
  `database.yml.tmpl` (adapter `postgis`, `schema_search_path: public,topology`)
  instead of relying on the official image's env-driven config.
- **The `postgis` adapter needs native gem build deps in the image.** It pulls in
  `activerecord-postgis-adapter` → `rgeo` (needs `libgeos-dev`, `libproj-dev`) and
  the `pg` gem (needs `libpq-dev`, which provides `/usr/bin/pg_config` **on PATH**).
  All three must be `apt-get install`ed in `redmine-web`'s Containerfile before
  `bundle install`. `postgresql-client` (used by the entrypoint for `pg_isready`)
  does **not** ship `pg_config` — omitting `libpq-dev` makes `bundle install` fail
  compiling `pg`. Prefer `libpq-dev` (PATH-clean) over a versioned PGDG dev package
  whose `pg_config` lands under `/usr/lib/postgresql/<v>/bin` off the default PATH.
- **Config is rendered from `*.tmpl` at container start** via `envsubst` in
  `entrypoint.sh` — edit the `.tmpl` files (`database.yml.tmpl`,
  `configuration.yml.tmpl`), not any generated `.yml`. After rendering,
  `entrypoint.sh` `chown`s them to `redmine:redmine` before `chmod 640` —
  Puma runs as the unprivileged `redmine` user (started via `runuser`/`su`),
  so a root-owned 640 file it can't read makes `rails server` crash on boot
  with `Permission denied @ rb_sysopen - config/database.yml`.
- **`config.ru` is replaced (`containers/redmine-web/config.ru`), not left as
  the stock one-liner.** `httpd-redmine.conf` proxies `/redmine` to Puma
  *without* stripping the prefix (`ProxyPass /redmine
  http://127.0.0.1:3000/redmine`), and the container healthcheck also curls
  Puma directly at `/redmine/login`. `config.relative_url_root` (defaulted
  from `RAILS_RELATIVE_URL_ROOT`) only affects URL *generation*, not request
  dispatch, so with the stock `run Rails.application` config.ru, Puma 404s
  on every request (`No route matches [GET] "/redmine/login"`). Our
  `config.ru` wraps the app in `map ENV["RAILS_RELATIVE_URL_ROOT"] do ... end`
  so Puma itself serves the sub-URI.
- **The Apache frontend is built into `redmine-web`**. The separate
  `redmine-static` image is no longer part of the stack.
- **Keep dev and prod in lockstep.** `compose.dev.yaml` and the `quadlets/`
  units deliberately use the same images, env vars, secrets, and healthchecks.
  A change to one tier's runtime contract should be mirrored in the other.
  The one deliberate divergence: `compose.dev.yaml` publishes `redmine-web` on
  host port **8080** (not 80), because rootless Podman/Docker cannot bind a
  loopback listener to a privileged port (<1024) without host prep
  (`CAP_NET_BIND_SERVICE` or `net.ipv4.ip_unprivileged_port_start`), and the
  dev compose file is meant to run with **no host prep**. Production's Quadlet
  unit keeps host port 80 and expects that prep to be done once during setup
  (see `docs/Setup.md`).
- **PostgreSQL 18+ images changed their data-directory layout.** They expect a
  single volume mounted at `/var/lib/postgresql` (the image manages a
  version-specific subdirectory under it, e.g. `/var/lib/postgresql/18/docker`)
  instead of the older convention of mounting directly at
  `/var/lib/postgresql/data`. Mounting at `.../data` makes the entrypoint
  refuse to start (`in 18+, these Docker images are configured to store
  database data in a format which is compatible with "pg_ctlcluster"...`).
  Both `compose.dev.yaml` and `quadlets/redmine-db.container` mount the
  volume at `/var/lib/postgresql` and leave `PGDATA` at the image default —
  don't reintroduce a `.../data` mount or an explicit `PGDATA` override.
- **`redmine-db`'s local (Unix-socket) Postgres auth must stay password-based
  (`scram-sha-256`), never `peer`.** The upstream `postgres`/`postgis` image
  entrypoint runs `initdb --username="$POSTGRES_USER"` (here, `redmine`, not
  `postgres`) and then does its own setup — `CREATE DATABASE`, running
  `containers/redmine-db/init-redmine.sh` — via `psql --username redmine` over
  the local socket, while the OS process user inside the container is always
  `postgres`. `peer` auth requires the OS user and the Postgres role name to
  match, so with `--auth-local=peer` **every** local connection is rejected,
  including the entrypoint's own bootstrap (`Peer authentication failed for
  user "redmine"`) — `POSTGRES_DB` never gets created and `redmine-web` then
  fails with `database "redmine" does not exist`. `scram-sha-256` works
  locally too because the entrypoint exports `PGPASSWORD` before running any
  setup SQL.
- **Plugins/themes are pinned by git tag/branch at build time.** When adding or
  bumping one, edit `containers/redmine-web/Containerfile`, keep the numbered
  comment list accurate, and note that `view_customize`'s clone directory
  **must** be named `view_customize` (required by its `init.rb`).
  **Verify every `--branch` tag actually exists upstream** with
  `git ls-remote --tags --heads <url>` before pinning — the `v`-prefix convention
  varies per repo (some tags are `v1.2.1`, others `0.3.4`), and a `--branch` on a
  nonexistent tag with no `|| git clone` fallback fails the whole build. The four
  clones carrying a `|| git clone <url>` fallback degrade to the default branch if
  the tag is missing; add one when unsure of a tag.
- **Migrations run automatically on start.** `entrypoint.sh` runs
  `rake db:migrate` and (when `REDMINE_PLUGINS_MIGRATE=1`)
  `rake redmine:plugins:migrate`. Restarting `redmine-web` re-applies them
  idempotently — that is the intended upgrade path.

## Shell script conventions

- Every script is bash with `set -euo pipefail` and a header comment block
  (purpose, usage, install path). Match that style for new scripts.
- **`shellcheck` is the linter** (installed by `.devcontainer/post-create.sh`);
  run `shellcheck scripts/*.sh containers/**/*.sh` before committing shell
  changes.
- Structured logging via `log()`/`die()` helpers with timestamps; user-facing
  destructive actions require an explicit typed confirmation (see `restore.sh`
  requiring the literal `RESTORE`).
- Operational scripts (`backup.sh`, `restore.sh`) run **rootless as `redmine`**
  and drive Podman directly — no `sudo`. Backups keep 7 generations; restore is
  destructive and recreates the DB with PostGIS extensions.

## Documentation & language conventions

- **File-header comments and this CLAUDE.md are in English.**
- **User-facing docs are in Japanese**: `README.md`, everything in `docs/`
  (`Design.md`, `Setup.md`, `Manual.md`), and the comment blocks inside the
  `quadlets/*.container` units. When editing those, keep them in Japanese and
  consistent with the existing tone.
- When you change architecture, versions, ports, plugin lists, or workflows,
  update the affected docs in the same change: `docs/Design.md` (architecture),
  `docs/Setup.md` (install), `docs/Manual.md` (operations), `README.md`
  (overview), and this file.

## Verification (no CI / test suite)

There is no automated test suite or CI pipeline. Verify changes by exercising
the stack:

```bash
shellcheck scripts/*.sh                                    # lint shell
docker compose -f compose.dev.yaml config                 # validate compose syntax
docker compose -f compose.dev.yaml up --build -d           # full build + boot
curl -sf http://localhost:8080/redmine/login && echo OK   # app reachable
```

Healthchecks are defined for both services; `docker compose ps` /
`podman healthcheck run redmine-web` report status. A Rails console for
diagnostics: `podman exec -it redmine-web bundle exec rails console -e production`.

## Git & branch workflow

- Do all work on the assigned feature branch; create it locally if needed.
- Push with `git push -u origin <branch>`; retry network failures with
  exponential backoff.
- **Do not open a pull request unless explicitly asked.**
- Commit messages: clear and descriptive, imperative mood, matching the concise
  style already in the history.
