---
name: redmine-image-build
description: >-
  Build/troubleshoot the redmine-web and redmine-db container images, and the
  dev/prod boot sequence. Use when editing containers/redmine-web/Containerfile,
  containers/redmine-db/Containerfile, bumping or adding a Redmine plugin or
  theme, or diagnosing image-build failures — especially "Remote branch ... not
  found" from a git clone, `pg_config`/native-gem (`pg`, `rgeo`) build errors
  during `bundle install` — or boot-time crash-loops after a successful build:
  a plugin LoadError, "Peer authentication failed for user ...", "Permission
  denied @ rb_sysopen - config/database.yml", or "No route matches [GET]
  .../login". Covers git-tag pinning discipline, the native build dependencies
  the `postgis` database adapter requires, and known runtime footguns in
  entrypoint.sh / config.ru / POSTGRES_INITDB_ARGS.
---

# Building the redmine-web image

The `redmine-web` image (`containers/redmine-web/Containerfile`) layers a
plugin/theme stack and native-gem build tooling onto the official
`redmine:6.1.3` base. Two classes of mistake break the build; both are avoidable
with the checks below.

## 1. Git tag pinning — verify before you pin

All 13 plugins and the `farend_fancy` theme are `git clone`d **at build time** so
the code is baked into the image. Each plugin is pinned with
`git clone --depth 1 --branch <TAG> <url>`.

**Before adding or bumping any `--branch <TAG>`, confirm the tag exists upstream:**

```bash
git ls-remote --tags --heads https://github.com/<owner>/<repo>.git
```

Pitfalls this catches:

- **The `v`-prefix convention varies per repository.** There is no global rule.
  Some repos tag `v1.2.1` (e.g. `redmica/*`, `gtt-project/redmine_gtt`,
  `nishidayuya/redmine_solid_queue`); others tag `0.3.4` with **no** `v`
  (e.g. `tkusukawa/redmine_wiki_lists`, `agileware-jp/redmine_banner`,
  `haru/redmine_wiki_extensions`). Copy the exact string upstream uses.
- **A `--branch` on a nonexistent tag with no fallback fails the whole build.**
  `git clone --branch <bad-tag>` errors with `Remote branch <bad-tag> not found`
  and aborts. Always confirm the exact tag string with `git ls-remote` first —
  don't assume a `v` prefix (or its absence).
- **Fallback pattern.** Several clones use
  `git clone --branch <tag> <url> || git clone <url>` so a missing/renamed tag
  degrades to the default branch instead of failing. Prefer this for any plugin
  whose tagging you're unsure about. (Trade-off: a wrong tag then silently clones
  the default branch instead of failing loudly — so still verify the tag.)
- **A tag existing upstream doesn't mean the code at that tag actually boots
  on this Redmine/Rails version.** `agileware-jp/redmine_banner` at `0.3.4`
  clones fine and `bundle install` succeeds, but its `init.rb` does a bare
  `require 'banners/application_hooks'`, relying on the plugin's `lib/` being
  on Ruby's `$LOAD_PATH`. Redmine 6.x / Rails 7.2's Zeitwerk-based boot no
  longer adds plugin `lib/` dirs to it, so the container boots, runs
  migrations, then crash-loops with `LoadError: cannot load such file --
  banners/application_hooks` the moment Puma starts. Upstream fixed this in
  `0.3.5` (switched to a `File.dirname(__FILE__)`-relative require) — that's
  why the Containerfile pins `0.3.5`, not the newest-looking `0.3.4`. If a
  future plugin bump crash-loops with a similar `LoadError` right after
  migrations finish, suspect the same `$LOAD_PATH` assumption and look for a
  newer tag/branch that fixed it upstream before patching locally.

The `farend_fancy` **theme has no `--branch`** and is cloned from its default
branch, which is `master` (the repo has **no** `main` branch — don't "fix" the
comment back to `main`).

## 2. Native gem build dependencies (the `postgis` adapter)

The stack uses `adapter: postgis` in `database.yml.tmpl` (required by
`redmine_gtt`; see the CLAUDE.md convention). That adapter pulls in native gems
that must compile during `bundle install`:

| Gem | Needs | apt package(s) |
|-----|-------|----------------|
| `pg` | `libpq` headers + `pg_config` | **`libpq-dev`** (installs `/usr/bin/pg_config`, on PATH) |
| `rgeo` | GEOS + PROJ | `libgeos-dev`, `libproj-dev` |
| `activerecord-postgis-adapter` | — (pure Ruby) | none |

**`pg_config` PATH consistency — the classic trap.** `pg_config` is what the `pg`
gem's `extconf.rb` shells out to. `postgresql-client` (installed for the
entrypoint's `pg_isready` DB-wait) does **not** provide it. Only `libpq-dev` puts
`pg_config` at `/usr/bin/pg_config`, which is already on the default PATH — so no
`ENV PATH` change is needed. Avoid the alternative of a versioned PGDG dev package
(e.g. `postgresql-server-dev-18`): that drops `pg_config` under
`/usr/lib/postgresql/18/bin/`, which is **not** on PATH, producing the
"installed but cannot be executed / not found" symptom. If you ever must use it,
prepend that dir to PATH (`ENV PATH="/usr/lib/postgresql/18/bin:${PATH}"`) before
`bundle install`, or pass `gem install pg -- --with-pg-config=<path>`.

Note the base image ships a precompiled `pg`; a recompile is only triggered when
Bundler resolves a different `pg` version for the plugin set — so a build can
"work" without `libpq-dev` and then break on a dependency bump. Keep `libpq-dev`
in the image so the outcome is stable.

## 3. redmine_gtt frontend

`redmine_gtt` also builds frontend assets with **classic Yarn 1.22.22** + webpack
(`yarn install --frozen-lockfile && npx webpack --mode production`). The
Containerfile installs `nodejs`/`npm` and pins Yarn to 1.22.22 — keep that pin.

## 4. Build succeeds, but the container crash-loops on boot

A green `podman build`/`docker compose build` only proves the image *compiles*.
These three bugs all look like "it built fine but won't start" and have
already bitten this stack once each — check them in this order before
assuming a new regression:

1. **`redmine-db` never creates the `redmine` database at all** —
   `redmine-web` then fails every migration with `PG::ConnectionBad: FATAL:
   database "redmine" does not exist`, and `redmine-db`'s own logs show `Peer
   authentication failed for user "redmine"` right after `initdb`.
   Root cause: `containers/redmine-db/Containerfile`'s `POSTGRES_INITDB_ARGS`
   must **never** contain `--auth-local=peer`. The upstream postgres/postgis
   entrypoint runs `initdb --username="$POSTGRES_USER"` (`redmine`, not
   `postgres`) and then does its own bootstrap SQL — `CREATE DATABASE`, plus
   `containers/redmine-db/init-redmine.sh` — via `psql --username redmine`
   over the **local Unix socket**, while the OS process user inside the
   container is always `postgres`. `peer` auth requires those two names to
   match, so it rejects the entrypoint's own setup. Local auth must stay
   password-based (`scram-sha-256`); the entrypoint exports `PGPASSWORD`
   before running any setup SQL, so scram-sha-256 works locally too.
2. **Puma crashes immediately with `Permission denied @ rb_sysopen -
   config/database.yml`** (visible right after `Starting Puma via rails
   server`, even though `rake db:migrate` just read the same file fine).
   Root cause: `entrypoint.sh` renders `config/database.yml` /
   `config/configuration.yml` as **root** (migrations also run as root, so
   they don't notice), but Puma is started as the unprivileged `redmine` user
   via `runuser`/`su`. If the render step's `chmod 640` isn't preceded by
   `chown redmine:redmine`, the files stay `root:root` and `redmine` can't
   read them. Keep the `chown` before the `chmod` in `entrypoint.sh`.
3. **Every request 404s with `No route matches [GET] ".../login"`**, whether
   curled through Apache on :80 or straight at Puma on :3000 — Puma boots
   cleanly, migrations succeeded, healthcheck just never goes green.
   Root cause: `httpd-redmine.conf` proxies `/redmine` to Puma **without**
   stripping the prefix (`ProxyPass /redmine http://127.0.0.1:3000/redmine`),
   and the container healthcheck also curls Puma directly at
   `/redmine/login`. `config.relative_url_root` (defaulted from
   `RAILS_RELATIVE_URL_ROOT`) only affects Rails' URL *generation*, not
   request *dispatch* — the stock `redmine:6.1.3` image's `config.ru` is a
   bare `run Rails.application`, which only answers at `/login`, not
   `/redmine/login`. This repo replaces `config.ru`
   (`containers/redmine-web/config.ru`) with one that wraps the app in
   `map ENV["RAILS_RELATIVE_URL_ROOT"] do ... end`. If you ever regenerate or
   `COPY` over `config.ru` from the upstream image, you will silently
   reintroduce this 404.

## Verify

```bash
# Tag exists upstream (do this for any --branch you touch)
git ls-remote --tags https://github.com/haru/redmine_logs.git | grep -E 'v1\.0\.0$'

# Build the image end-to-end (must pass the plugin clones AND `bundle install`)
docker compose -f compose.dev.yaml build redmine-web
#   or: podman build -t localhost/redmine-web:6.1.3 containers/redmine-web

# pg_config is present and on PATH inside the built image
docker compose -f compose.dev.yaml run --rm --entrypoint sh redmine-web \
    -c 'command -v pg_config && pg_config --version'

# Full boot + reachability
docker compose -f compose.dev.yaml up --build -d
curl -sf http://localhost:8080/redmine/login && echo OK
```

**`up -d` after a rebuild can silently keep running the old container/image.**
`podman-compose up -d` (the external compose provider `podman compose` uses)
does not reliably recreate a container just because its image was rebuilt
under the same tag — you can fix a bug, rebuild, `up -d`, and still be
looking at the old image's crash. Confirm with
`podman inspect --format '{{.Image}}' redmine-web` vs.
`podman images localhost/redmine-web:6.1.3 --format '{{.ID}}'`; if they
differ, force it: `podman compose -f compose.dev.yaml up -d --force-recreate
redmine-web`. When troubleshooting a "residue" boot failure, tear all the way
down first (`podman compose -f compose.dev.yaml down -v`, and clear any
stray anonymous volumes with `podman volume ls` / `podman volume rm`) so
you're always diagnosing a clean start, not a stale container or a
half-initialized `pgdata` volume from a previous failed boot.
