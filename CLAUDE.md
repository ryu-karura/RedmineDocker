# CLAUDE.md

Guidance for AI assistants working in this repository.

## What this repository is

RedmineDocker (the **redmine stack**) is container infrastructure for running
**Redmine 6.1.3** on RHEL 9.5+ in production (rehearsable on WSL AlmaLinux
9.5+; see the three paths below). There is **no Redmine application
source code here** — Redmine, its Ruby/Puma runtime, and its gems come from the
official `redmine:6.1.3` image. This repo is the *packaging and operations*
layer around it: Containerfiles, rendered config templates, an entrypoint,
systemd Quadlet units, host Apache config, and operational shell scripts.

The design follows the [redmine.jp 6.1 Docker guide](https://blog.redmine.jp/articles/6_1/redmine-6_1-docker/),
extended into a **two-tier** stack with file-based secrets.

Three paths share the **same two images** and only differ in orchestration +
data placement:
- **Development A — WSL (AlmaLinux 9.5+)** — Docker Compose
  (`compose.dev.yaml`), named volumes, Podman emulating `docker`.
- **Development B — GitHub Codespaces** — Docker Compose
  (`compose.dev.yaml`), named volumes, real Docker Engine via the devcontainer's
  docker-in-docker feature.
- **Production — RHEL 9.5+** — rootless Podman + systemd Quadlets
  (`quadlets/`), host bind mounts under `/opt/redmine`.

When no RHEL host is available, the production (Quadlets) path can be
rehearsed on the same WSL (AlmaLinux 9.5+) box used for Development A — see
`docs/Setup.md`, "本番相当の動作確認 (WSL)". It's the identical procedure, not
a fourth variant; the only WSL-specific requirement is `systemd=true` in
`/etc/wsl.conf`, and it cannot run at the same time as Development A on that
box (both use the container names `redmine-db`/`redmine-web` and the network
`redmine-net` — stop one before starting the other).

## Architecture (two tiers)

```
client ──443──► Host Apache ──/redmine──► redmine-web (Apache 2.4 + Redmine 6.1.3)
                (TLS, HSTS)   127.0.0.1:80  │  REDMINE_WEB_SERVER selects one of:
                                            │    puma      → ProxyPass to Puma :3000
                                            │    passenger → mod_passenger spawns the app
                                            ▼
                                     Redmine (sub-URI /redmine)
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
├── docs/                        # Design.md / Setup.md / Manual.md / Upgrade.md (Japanese)
├── .github/copilot-instructions.md # pointer to this file, no duplicated content
├── containers/
│   ├── redmine-db/                # Containerfile + init-redmine.sh (PostGIS ext)
│   ├── redmine-db-mysql/          # MySQL 8.0 CE — migration-source rehearsal only
│   └── redmine-web/           # Containerfile.v5/.v6/.v7/.v5-mysql, entrypoint.sh, healthcheck.sh, *.tmpl (db/config/httpd)
├── quadlets/                    # production Podman Quadlet units (*.container, *.network; v5/ and v7/ hold series-specific web units)
├── host-apache/                 # host-side TLS reverse proxy vhost
├── scripts/                     # generate-secrets, backup, restore, migrate-mysql-to-postgres, test-*, pgloader/
├── logrotate/                   # /etc/logrotate.d config
├── compose.dev.yaml             # development orchestration
├── compose.legacy.yaml          # migration-source stack (Redmine 5.1.6 + MySQL 8.0)
├── .devcontainer/               # Codespaces / VS Code dev container
├── .env.example                 # non-secret config reference (see docs/Design.md)
└── .gitignore
```

## Component versions

| Component | Value |
|-----------|-------|
| Host OS | Production: RHEL 9.5+ / Dev A: WSL AlmaLinux 9.5+ / Dev B: Codespaces |
| Redmine | 6.1.3 (`docker.io/library/redmine:6.1.3`) |
| PostgreSQL / PostGIS | 18 + 3.6 (`postgis/postgis:18-3.6`) |
| Web tier | Apache httpd 2.4 (Debian `apt` package baked into `redmine-web`, not version-pinned) |
| App server | Puma (default) or Passenger (`libapache2-mod-passenger`: 6.0.26 from trixie on v5/v6, 6.1.x from forky on v7), selected by `REDMINE_WEB_SERVER` |
| Node.js / Yarn | Debian `nodejs` + Yarn 1.22.22 — **Redmine 5 series only**, for `redmine_gtt` 6.0.3's webpack build |

`redmine-web` bakes in 13 plugins (see the numbered list in
`containers/redmine-web/Containerfile.v6`) plus the `farend_fancy` theme. All
plugins/themes are `git clone`d **at build time** so they are reproducible in
the image — update a plugin by editing the Containerfile and rebuilding, not by
mounting a volume. The one exception is `redmine_gtt` in the 6/7-series images,
which is unpacked from its release tarball (see the series section below).

### Redmine series (5 / 6 / 7)

`redmine-web` has **one Containerfile per Redmine major series**, because the
plugin/theme versions that actually work differ per series:

| Series | Containerfile | Base image | Ruby / Rails | Plugins |
|--------|---------------|------------|--------------|---------|
| 5 | `Containerfile.v5` | `redmine:5.1.12` | 3.2 / 6.1.7.10 | 11 |
| 6 (default) | `Containerfile.v6` | `redmine:6.1.3` | 3.4 / 7.2.3.1 | 13 |
| 7 | `Containerfile.v7` | `redmine:7.0.0` | 4.0 / 8.1.3 | 12 |

A fourth Containerfile, `Containerfile.v5-mysql` (Redmine 5.1.6 + MySQL 8.0 CE,
16 plugins — the 10 shared with `Containerfile.v5` minus `redmine_gtt`, plus 6
more pinned to match a real legacy production plugin set), exists **only to
rehearse the upgrade** from a legacy MySQL install
— see "Upgrade rehearsal path" below and `docs/Upgrade.md`. It is not part of
the normal dev/prod stack and has no Quadlet unit.

`entrypoint.sh`, `healthcheck.sh`, `config.ru`, the `*.tmpl` files and
`redmine-db` are shared by all three — keep it that way; series differences
belong in the Containerfiles only. Selection is `.env`'s
`REDMINE_WEB_CONTAINERFILE` + `REDMINE_VERSION` (always change both), compose
reads it as `dockerfile: ${REDMINE_WEB_CONTAINERFILE:-Containerfile.v6}`,
production has `quadlets/v5/` and `quadlets/v7/` drop-in replacements for the
web unit only, and `scripts/test-stack.sh --series 5|6|7` sets the whole
triple. **Only one series can run at a time** (shared container names, ports,
volumes) and the database is not backward-compatible across series.

Series-specific facts that are easy to get wrong (full evidence in
`docs/Design.md`, "Redmine シリーズの切り替え"):

- Redmine 6.0 moved themes from `public/themes/` to `themes/`. The v5 image
  clones `farend_fancy` (tag `redmine5.1`) into `public/themes/`, and must not
  `chown` a top-level `themes/` that doesn't exist there.
- The official 5.1 image line ended at **5.1.12** (docker-library commit
  `ac72cc3` "Remove 5.1 (Ruby 3.2 EOL)", 2026-04-20). Redmine source has
  5.1.13 but no image, so the v5 image is pinned to an unmaintained base.
- `redmine_solid_queue` cannot run on Redmine 5 (the `solid_queue` gem needs
  activerecord >= 7.1, Redmine 5.1 is Rails 6.1) and `redmine_login_audit2`
  declares `requires_redmine 6.0.0` in every release — both are omitted from v5.
- `redmine_banner` is omitted from v7: master has no Redmine 7 support and the
  fix lives only in the unmerged branch `test_fix_for_redmine_7_0`.
- `redmine_gtt` 6.0.3 on Redmine 5 needs the geo gem stack pinned via
  **`ENV`** (not ARG — Redmine re-evaluates `plugins/*/Gemfile` on every
  bundler run, including at runtime): `GEM_RGEO_ACTIVERECORD_VERSION=7.0.1`,
  `GEM_ACTIVERECORD_POSTGIS_ADAPTER_VERSION=7.1.1`, the values gtt's own CI
  uses for `5.1-stable`. Without them the Gemfile defaults to
  activerecord-postgis-adapter 10.x (activerecord ~> 7.2) and won't resolve.
- `redmine_gtt` 7.x switched the frontend from webpack+yarn to **Vite+pnpm**
  (`corepack enable pnpm && pnpm install && pnpm build`, Node >= 22). Debian
  trixie only has nodejs 20.19, so the v6/v7 images install the plugin from the
  release tarball (`redmine_gtt-v7.1.0.tar.gz`), which ships prebuilt
  `assets/javascripts/main.js` + `assets/stylesheets/main.css` and needs no
  Node toolchain at all. Don't reintroduce yarn/webpack there.
- Redmine 7's `mod_passenger` comes from **forky (Debian 14 / testing), not
  trixie**: trixie ships Passenger 6.0.26 and Ruby 4 support landed in 6.1.1, so
  the v7 base (Ruby 4.0) needs forky's 6.1.x. `Containerfile.v7` adds a forky
  apt source plus `/etc/apt/preferences.d/passenger-suite.pref` that pins
  everything from forky to `-10` (uninstallable) except the `passenger`
  packages at `990` — so a dependency that trixie cannot satisfy fails the
  build instead of silently dragging in a forky `libc6`. Both files are removed
  in the same `RUN`, and the layer asserts
  `dpkg --compare-versions <installed> ge 6.1`. Suite and floor are
  `ARG PASSENGER_APT_SUITE` / `ARG PASSENGER_MIN_VERSION`. v5/v6 keep trixie's
  6.0.26 (Ruby 3.4). Verify with
  `bash scripts/test-stack.sh --series 7 --web-server passenger`, which also
  re-checks the installed version inside the running container.

## Development workflow (Docker Compose: WSL or Codespaces)

WSL (Development A):

```bash
bash scripts/generate-secrets.sh                    # creates ./secrets/*.txt (git-ignored)
docker compose -f compose.dev.yaml up --build -d    # first build is slow: plugin gems + webpack
docker compose -f compose.dev.yaml logs -f redmine-web   # watch migrations run
# Open http://localhost:8080/redmine/   (initial login: admin / admin)
```

Codespaces (Development B, external/public via port 80):

```bash
bash scripts/generate-secrets.sh
docker compose -f compose.dev.yaml -f compose.codespaces.yaml up --build -d
docker compose -f compose.dev.yaml -f compose.codespaces.yaml logs -f redmine-web
# Open http://localhost/redmine/   (initial login: admin / admin)
```

- `docker compose ... down` keeps data (named volumes `pgdata`, `redmine_files`);
  `down -v` destroys it.
- **Development A (WSL)**: requires `systemd=true` in `/etc/wsl.conf` (needed
  later if this box is also used to rehearse Production, below) and rootless
  Podman; `docker`/`docker compose` are an alias emulating Podman.
- **Development B (Codespaces)**: the dev container (`.devcontainer/`)
  provisions real docker-in-docker and installs `shellcheck`; `compose.codespaces.yaml`
  overrides the web publish to host port **80** (all interfaces) for forwarding/public access.

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
  `.env` holds only NON-secret overrides — see `.env.example`.
- **`.env` is the single reference for non-secret config** (container/network
  naming, `REDMINE_DB_NAME`/`REDMINE_DB_USER`, `REDMINE_SUBURI`
  (`RAILS_RELATIVE_URL_ROOT`), `REDMINE_WEB_HOST_PORT`,
  `REDMINE_DATA_DIR`, `TZ`, SMTP) — full table and rationale in `docs/Design.md`,
  "設定パラメータ (.env)". Three different things read it: `compose.dev.yaml`
  (Compose's built-in `.env` autoload, used by every `${VAR:-default}` in that
  file), `quadlets/redmine-web.container`'s `EnvironmentFile=` (container
  process env only — `SMTP_*`/`TZ`), and `scripts/backup.sh`/`restore.sh`
  (plain bash, `source` it directly). **Podman Quadlet `*.container` units have
  no envsubst/variable-substitution pass over their own directives** — only
  `Environment=`/`EnvironmentFile=` reach the container's process env, never
  `Image=`/`ContainerName=`/`Volume=`/`PublishPort=`/`Network=`/`Timezone=`/
  `HealthCmd=`. So in production, container/network names, DB name/user, the
  sub-URI, and data paths stay hardcoded in `quadlets/*.container` (and, for
  the sub-URI, in `host-apache/redmine-proxy.conf`) — change those files
  directly, in lockstep, if you ever need to. Don't try to make Quadlet units
  read `.env` for these; that requires a template-render step that doesn't
  exist yet and is a bigger change than a config tweak.
- **The Apache sub-URI config is templated, like `database.yml`.** There are two
  templates in `containers/redmine-web/`, one per app-server mode, and
  `entrypoint.sh` renders exactly one of them via `envsubst` on every container
  start: `httpd-redmine.conf.tmpl` → `/etc/apache2/conf-available/redmine-proxy.conf`
  (mode `puma`) and `httpd-redmine-passenger.conf.tmpl` →
  `.../redmine-passenger.conf` (mode `passenger`). Both define a `*:80`
  VirtualHost, so only one may be `a2enconf`'d at a time — the entrypoint also
  `a2disconf`s the other one (with `|| true`, since a fresh container may never
  have rendered it). The Containerfile pre-renders a build-time default of the
  proxy variant so `a2enconf` has a file to enable, but that copy is never
  actually served as-is. Edit the `.tmpl`, not a generated `.conf`.
- **`REDMINE_WEB_SERVER` picks the app server at *runtime*: `puma` (default) or
  `passenger`.** The image bakes in *both* — the official image's Puma plus
  `libapache2-mod-passenger` (v5/v6: Debian trixie's Passenger 6.0.26 — those
  base images are `ruby:3.4-slim-trixie` and Ruby 3.4 support landed in 6.0.25;
  v7: forky's 6.1.x, because that base is Ruby 4.0 — see the series section. No
  third-party APT repo is involved either way). Switching is an env change plus a container
  restart, never a rebuild — that is deliberate, because Quadlet units can pass
  `Environment=` but cannot template `Image=`, so a build-arg switch would be
  unusable in production. The Containerfile `a2dismod -f passenger`s at build
  time (the Debian postinst enables it) and `entrypoint.sh` does the
  `a2enmod`/`a2dismod` per mode. In `passenger` mode there is no Puma and no
  `:3000`; the entrypoint `source`s `/etc/apache2/envvars` and
  `exec apache2 -DFOREGROUND` so Apache is PID 1. Passenger's native-support
  extension is not built at image build time — it self-compiles on first spawn
  and falls back to pure Ruby with a log warning if that fails, which is fine.
- **`config.ru` must NOT `map` the sub-URI under Passenger.** `mod_passenger`
  with `PassengerBaseURI` sets `SCRIPT_NAME` and hands the app a `PATH_INFO`
  that already has the prefix stripped, so a `Rack::URLMap` (`map "/redmine"`)
  never matches `/login` and every request 404s — the mirror image of the Puma
  bug described below. `config.ru` branches on `defined?(PhusionPassenger)`
  (Passenger `require`s it before evaluating `config.ru`; this is the upstream
  idiom). Also: Passenger's user switching would otherwise run the app as the
  owner of `config.ru`, so the Containerfile `chown`s it to `redmine` *and* the
  template sets `PassengerUser`/`PassengerGroup` — a root-owned `config.ru`
  silently demotes the app to `nobody`, which then can't write `files/` or `log/`.
  `PassengerRuby` must point at `/usr/local/bin/ruby` (the official image's Ruby
  3.4), not Debian's `/usr/bin/ruby`, which has none of Redmine's gems.
- **The container healthcheck lives in the image
  (`containers/redmine-web/healthcheck.sh` → `/usr/local/bin/redmine-healthcheck.sh`),
  not inline in compose/quadlet.** Quadlet's `HealthCmd=` gets no variable
  substitution, so an inline command cannot honour `REDMINE_SUBURI` or
  `REDMINE_WEB_SERVER` — and duplicating the same shell one-liner in
  `compose.dev.yaml` and `quadlets/redmine-web.container` broke lockstep. Both
  now just invoke the script; it curls Apache always, and Puma directly only in
  `puma` mode (that direct curl is the regression test for the `config.ru`
  sub-URI mount, so keep it).
- **`REDMINE_DB_ADAPTER` picks the DB template at runtime; the default (`postgis`)
  is the only one `Containerfile.v5`/`.v6`/`.v7` ever use.** `entrypoint.sh` renders
  `config/database.${REDMINE_DB_ADAPTER}.yml.tmpl` when that file exists in the
  image and falls back to `config/database.yml.tmpl` (postgis) otherwise — so
  which adapters an image supports is decided by *which templates its
  Containerfile COPYs*, and the entrypoint keeps no per-series branching. Only
  `Containerfile.v5-mysql` ships the `mysql2`/`postgresql` templates (no
  `postgis` — it carries no `redmine_gtt`, the only plugin that needs actual
  PostGIS geometry types, so `postgresql` against the `redmine-db` PostGIS
  container is functionally sufficient). `compose.dev.yaml` passes
  `REDMINE_DB_ADAPTER` straight through to `redmine-web` (default `postgis`),
  which is what lets `Containerfile.v5-mysql` + `REDMINE_DB_ADAPTER=postgresql`
  run indefinitely against `redmine-db` — the supported way to keep the source
  Redmine version and plugin set unchanged while retiring MySQL, without
  upgrading to the 6/7 series (`docs/Upgrade.md` §4.1).
  `REDMINE_MIGRATE_ONLY` (non-empty, `!= 0`) makes the entrypoint stop right
  after migrations instead of starting a web server — used by the conversion's
  schema step, and useful for migrating before exposing the app on an upgrade.
- **Redmine's `Gemfile` derives the DB gem set from `config/database.yml`.** It
  scans every `adapter:` line and declares `mysql2` + `with_advisory_lock` /
  `pg` accordingly (`postgis` matches no branch — that's why the normal stack
  gets `pg` from `redmine_gtt`'s Gemfile instead). Consequence: **the adapter
  set visible at build time must equal the set visible at runtime**, or bundler
  re-resolves `Gemfile.lock` at boot and fails without network access.
  `Containerfile.v5-mysql` therefore writes a dummy two-adapter `database.yml`
  before `bundle install` (and asserts the three gems landed), and both of its
  runtime templates carry a `gem_pin_*` stanza for the other adapter. Don't
  delete those stanzas.
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
  the stock one-liner.** `httpd-redmine.conf.tmpl` (rendered to
  `redmine-proxy.conf`, see above) proxies the sub-URI to Puma *without*
  stripping the prefix (`ProxyPass ${RAILS_RELATIVE_URL_ROOT}
  http://127.0.0.1:3000${RAILS_RELATIVE_URL_ROOT}`), and the container
  healthcheck also curls Puma directly at `/redmine/login`.
  `config.relative_url_root` (defaulted
  from `RAILS_RELATIVE_URL_ROOT`) only affects URL *generation*, not request
  dispatch, so with the stock `run Rails.application` config.ru, Puma 404s
  on every request (`No route matches [GET] "/redmine/login"`). Our
  `config.ru` wraps the app in `map ENV["RAILS_RELATIVE_URL_ROOT"] do ... end`
  so Puma itself serves the sub-URI. (Under `REDMINE_WEB_SERVER=passenger` that
  `map` is skipped — see the Passenger note above.)
- **The Apache frontend is built into `redmine-web`**. The separate
  `redmine-static` image is no longer part of the stack.
- **Keep dev and prod in lockstep.** `compose.dev.yaml` and the `quadlets/`
  units deliberately use the same images, env vars, secrets, and healthchecks.
  A change to one tier's runtime contract should be mirrored in the other.
  `compose.dev.yaml`'s `${VAR:-default}` values must keep matching whatever's
  hardcoded in `quadlets/*.container` — the `.env.example` defaults are the
  same literals as the quadlets, so lockstep holds as long as nobody edits an
  `.env` (dev-only customization is fine; it just no longer mirrors prod).
  The one deliberate divergence: `compose.dev.yaml` publishes `redmine-web` on
  host port **8080** (not 80), because rootless Podman/Docker cannot bind a
  loopback listener to a privileged port (<1024) without host prep
  (`CAP_NET_BIND_SERVICE` or `net.ipv4.ip_unprivileged_port_start`), and the
  dev compose file is meant to run with **no host prep**. Production's Quadlet
  unit keeps host port 80 and expects that prep to be done once during setup
  (see `docs/Setup.md`). In Codespaces, use `compose.codespaces.yaml` as an
  additional override when you need forwarded/public host port 80.
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
- **`compose.dev.yaml`'s project name comes from `COMPOSE_PROJECT_NAME` in `.env`, not a
  `name:` field with variable substitution.** `podman-compose` 1.5.0 resolves the top-level
  `name:` attribute *before* substituting `.env` variables into it, so `name:
  ${STACK_NAME:-redmine}` got normalized as a literal string and produced the invalid project
  name `_-redmine` (stripped `$`, `{`, `}`, `:`, and every uppercase letter, since its
  normalization regex only keeps `[-_a-z0-9]`) — which then made `podman volume create` fail
  outright. `COMPOSE_PROJECT_NAME` is a Compose-spec special variable that both real Docker
  Compose and podman-compose read directly out of `.env`, taking precedence over `name:` and
  never touching the buggy substitution path, so `compose.dev.yaml` keeps a static `name:
  redmine` fallback and relies on `.env`'s `COMPOSE_PROJECT_NAME` for overrides. Two
  independent dev stacks can be run from one checkout with two separate `.env` files (passed
  via `--env-file`) as long as `COMPOSE_PROJECT_NAME`, `REDMINE_NETWORK`,
  `REDMINE_DB_CONTAINER`/`REDMINE_WEB_CONTAINER`, `REDMINE_DB_VOLUME`/`REDMINE_FILES_VOLUME`,
  and `REDMINE_WEB_HOST_PORT` all differ — see `docs/Design.md`, "設定パラメータ (.env)".
- **`redmine:6.1.3`'s Ruby 3.4 ships YJIT compiled in but disabled by default**, and Redmine's
  own `config/environments/production.rb` never sets `config.yjit`, so JIT never turns on
  unless something asks for it (verified: `ruby -e "puts RubyVM::YJIT.enabled?"` prints
  `false` with no flags, `true` with `RUBY_YJIT_ENABLE=1`, including through `bundle exec`).
  `RUBY_YJIT_ENABLE` is a Ruby-native env var — no entrypoint.sh or Containerfile change is
  needed, it just has to reach the Puma process env. Set to `1` by default in both
  `compose.dev.yaml` and `quadlets/redmine-web.container` (override via `.env`'s
  `RUBY_YJIT_ENABLE`); a container restart picks it up, no rebuild required.
- **Plugins/themes are pinned by git tag/branch at build time.** When adding or
  bumping one, edit the affected `containers/redmine-web/Containerfile.v*`
  (each series pins its own versions — check whether the change applies to all
  three), keep the numbered comment list accurate, and note that
  `view_customize`'s clone directory **must** be named `view_customize`
  (required by its `init.rb`). **Verify compatibility against real upstream
  evidence** — `requires_redmine` in the plugin's `init.rb` plus its CI matrix
  — not by assumption; when a plugin's CI targets RedMica, the mapping is
  RedMica 3.0 = Redmine 5.1, 3.1 = 6.0, 4.0/4.1 = 6.1, and `redmine/redmine`
  `master` = 7.0-devel.
  **Verify every `--branch` tag actually exists upstream** with
  `git ls-remote --tags --heads <url>` before pinning — the `v`-prefix convention
  varies per repo (some tags are `v1.2.1`, others `0.3.4`), and a `--branch` on a
  nonexistent tag with no `|| git clone` fallback fails the whole build. The four
  clones carrying a `|| git clone <url>` fallback degrade to the default branch if
  the tag is missing; add one when unsure of a tag.
- **Migrations run automatically on start, gated by the same switches as the
  official image.** `entrypoint.sh` runs `rake db:migrate` **unless**
  `REDMINE_NO_DB_MIGRATE` is set (non-empty), and runs
  `rake redmine:plugins:migrate` when `REDMINE_PLUGINS_MIGRATE` is set
  (non-empty, `!= 0`) — both mirroring `docker-entrypoint.sh` upstream. The one
  deliberate divergence is the default: upstream leaves both unset (plugins do
  not migrate), while this stack bakes in 13 plugins and so defaults
  `REDMINE_PLUGINS_MIGRATE=1`. Restarting `redmine-web` re-applies migrations
  idempotently — that is the intended upgrade path; set `REDMINE_NO_DB_MIGRATE=1`
  to boot without migrating (e.g. to inspect a DB before an upgrade).

## Upgrade rehearsal path (legacy MySQL → PostgreSQL → Redmine 7)

Full procedure: `docs/Upgrade.md`; rationale: `docs/Design.md` §10. In short, the
repo can reproduce a **Redmine 5.1.6 + MySQL 8.0 CE** source system
(`compose.legacy.yaml`, its own containers/network/volumes/port 8081 so it can run
*alongside* `compose.dev.yaml`), convert its database to PostgreSQL 18 + PostGIS,
and then upgrade straight to Redmine 7.0.0. **The Redmine 7 upgrade is optional**:
converting the DB and then staying on `Containerfile.v5-mysql` (source version and
plugin set unchanged, `REDMINE_DB_ADAPTER=postgresql` against `redmine-db`) is a
supported long-term end state — see `docs/Upgrade.md` §4.1 — for anyone who only
wants off MySQL, not onto a newer Redmine. Things worth not re-deriving:

- **"Schema by Rails, data by pgloader."** The target schema is created by running
  `rake db:migrate` with the *same* 5.1.6 image and plugin set
  (`REDMINE_DB_ADAPTER=postgresql` + `REDMINE_MIGRATE_ONLY=1`); pgloader then runs
  `WITH data only, truncate`. Letting pgloader build the schema yields non-serial
  `id` columns and `smallint` booleans, which breaks the later 5.1→7.0 migrations.
  `schema_migrations`/`ar_internal_metadata` are excluded from the copy.
- **The legacy image excludes plugins that can't work there**: `redmine_gtt`
  (PostGIS-only), `redmine_login_audit2` and `redmine_solid_queue` (both need
  Redmine ≥ 6.0 / Rails ≥ 7.1). Anything the *source* database has beyond the
  image's 16 plugins makes the load fail — the `schema` step diffs the table sets
  and stops first.
- **`redmine_banner` must be uninstalled before switching to the v7 image**
  (`rake redmine:plugins:migrate NAME=redmine_banner VERSION=0`), because v7 does
  not ship it and plugin migrations can't be rolled back once the code is gone.
- **MySQL is pinned to 8.0, not 8.4**, because pgloader 3.6.7 can't speak
  `caching_sha2_password`; `redmine.cnf` sets `default_authentication_plugin =
  mysql_native_password` and the migration script creates a temporary
  native-password user for pgloader (dropped afterwards). 8.4 removed that option.
- Sequences must be reset after a data-only load
  (`scripts/pgloader/reset-sequences.sql`) or the first insert after migration
  fails on a duplicate primary key.
- The legacy image is **puma-only** (no `mod_passenger`: its Debian 12 base
  predates Passenger's Ruby 3.2 support). `entrypoint.sh` tolerates the missing
  module in puma mode and fails with a clear message if `passenger` is requested.

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
  (`Design.md`, `Setup.md`, `Manual.md`, `Upgrade.md`), and the comment blocks inside the
  `quadlets/*.container` units. When editing those, keep them in Japanese and
  consistent with the existing tone.
- **`.github/copilot-instructions.md` is a pointer, not a second source of
  truth.** It exists only so GitHub Copilot picks up repo instructions; it
  must keep referring here rather than restating guidance. If AI-assistant
  guidance changes, edit this file — never fork content into that one.
- When you change architecture, versions, ports, plugin lists, or workflows,
  update the affected docs in the same change: `docs/Design.md` (architecture),
  `docs/Setup.md` (install), `docs/Manual.md` (operations), `docs/Upgrade.md`
  (migration from Redmine 5.1.6 + MySQL), `README.md` (overview), and this file.

## Verification (no CI pipeline; one integration test script)

There is no CI pipeline, but two self-contained integration tests exist:
`scripts/test-stack.sh` for the normal dev (Compose) path, and
`scripts/test-upgrade.sh` for the legacy-MySQL upgrade path (builds the 5.1.6 +
MySQL stack, seeds Japanese/boolean test data, runs
`scripts/migrate-mysql-to-postgres.sh`, boots 5.1.6 on the converted PostgreSQL,
uninstalls `redmine_banner`, then upgrades to 7.0.0 and re-checks the data —
run it after touching `compose.legacy.yaml`, `Containerfile.v5-mysql`, the
`database.*.yml.tmpl` files, or the migration script). It uses its own project,
DB name, volumes and ports (8081/8082/8083), so it never touches a real stack.

`scripts/test-stack.sh` is a self-contained
integration test for the dev (Compose) path — run it after any change to
`compose.dev.yaml`, the Containerfiles, `entrypoint.sh`, or `config.ru`:

```bash
bash scripts/test-stack.sh                # build, boot, verify, tear down (destroys dev volumes)
bash scripts/test-stack.sh --keep         # ... and leave the stack running
bash scripts/test-stack.sh --skip-build   # reuse existing images for faster iteration
bash scripts/test-stack.sh --web-server passenger --skip-build   # same image, Passenger mode
bash scripts/test-stack.sh --series 7      # Redmine 7 image (5 / 6 / 7, default 6)
```

It rebuilds both images, boots them, and checks every boot-time bug this
stack has actually hit once: `pg_config` on PATH, `redmine-db` creating the
`redmine` database + PostGIS extensions without a "Peer authentication
failed" regression, `redmine-web` free of plugin `LoadError`/permission/
routing errors and not crash-looping, and the login page reachable both
through Apache and directly on Puma. `--web-server passenger` runs the same
boot sequence against `REDMINE_WEB_SERVER=passenger` and swaps the Puma-direct
check for "nothing is listening on `:3000`", "`passenger_module` is loaded",
and "Apache serves a static asset out of `public/`" (`public/404.html` — the
only static file present in all three series, since Redmine 6.0 moved
stylesheets out of `public/`); on `--series 7` it additionally asserts the
container's `libapache2-mod-passenger` is 6.1+ (the forky pin) — both modes
share one image, so run it with
`--skip-build` right after the default run. `--series 5|6|7` swaps the
Containerfile, base image and image tag together; because each series has its
own image tag, `--skip-build` only reuses an image of that same series. It only
exercises **default** `.env` values otherwise — it does not verify that a
`.env` override (`REDMINE_SUBURI`, `REDMINE_DB_NAME`, etc., see
`docs/Design.md`) actually takes effect.

For a quicker manual check, or when investigating a single failure:

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
