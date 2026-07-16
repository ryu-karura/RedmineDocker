---
name: redmine-image-build
description: >-
  Build/troubleshoot the redmine-web container image. Use when editing
  containers/redmine-web/Containerfile, bumping or adding a Redmine plugin or
  theme, or diagnosing image-build failures — especially "Remote branch ... not
  found" from a git clone, or `pg_config`/native-gem (`pg`, `rgeo`) build errors
  during `bundle install`. Covers git-tag pinning discipline and the native build
  dependencies the `postgis` database adapter requires.
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
