# RedmineDocker

**Redmine Container Project powered by Podman on RHEL9 / AlmaLinux9**

This repository contains the complete infrastructure-as-code to build, deploy, and operate a Redmine platform using Podman containers managed by systemd Quadlets.

---

## Overview

| Container      | Build Context             | Role                              | Redmine | DB             |
|----------------|---------------------------|-----------------------------------|---------|----------------|
| `redmine-db`   | `containers/redmine-db/`  | PostgreSQL 18 + PostGIS master    | —       | —              |
| `redmine-prod` | `containers/redmine-prod/`| Production Redmine 6.1.3          | 6.1.3   | redmine_prod   |

In production all containers run under Podman (not Docker) and are managed as systemd services using Quadlet unit files. For development in GitHub Codespaces the same images are built and run with Docker Compose instead — see [Development in GitHub Codespaces](#development-in-github-codespaces).

---

## Sub-URI Mapping

| Environment       | Sub-URI          | Host Port |
|-------------------|------------------|-----------|
| Production        | `/redmine`       | 10080     |

External HTTPS traffic arrives at port 443 on the host Apache, which terminates TLS and proxies requests to the container's Apache instance on the mapped host port.

---

## Component Versions

| Component   | Version   |
|-------------|-----------|
| RHEL/Alma   | 9.5       |
| Podman      | 4.9.x     |
| PostgreSQL  | **18**    |
| PostGIS     | **master** |
| Redmine     | **6.1.3** |
| Ruby        | 3.4.4     |
| Bundler     | 2.6.8     |
| Node.js     | 22.23.1   |
| Yarn        | 1.22.22   |
| Apache      | 2.4.62    |
| Puma        | (bundled with Redmine 6.1.3) |

---

## Repository Structure

Directory names under `containers/` match the container/image names used by
the Quadlet units (`redmine-db`, `redmine-prod`), so a directory, its image
(`localhost/redmine-db`, `localhost/redmine-prod`), and its systemd service
always share the same name.

```
RedmineDocker/
├── README.md                     # This file
├── docs/
│   ├── Design.md                 # Architecture and design decisions
│   ├── Setup.md                  # Step-by-step installation guide
│   └── Manual.md                 # Day-to-day operational procedures
├── containers/
│   ├── redmine-db/               # PostgreSQL 18 + PostGIS master container
│   └── redmine-prod/             # Production Redmine 6.1.3 container
├── quadlets/                     # Systemd Quadlet unit files (production)
├── host-apache/                  # Host Apache reverse proxy configuration
├── scripts/                      # Operational scripts
├── logrotate/                    # Log rotation configuration
├── compose.dev.yaml              # Docker Compose file (development only)
├── .devcontainer/                # GitHub Codespaces / VS Code dev container
├── .env.example                  # Environment variable template
└── .gitignore
```

---

## Quick Start (Production)

1. Clone this repository to `/opt/redmine/containers` on the host.
2. Run `scripts/generate-env.sh` to generate `.env` with random passwords.
3. Follow `docs/Setup.md` for the complete setup procedure.

---

## Development in GitHub Codespaces

Podman cannot run inside a Codespaces dev container (nested rootless
containers are not supported there), so development uses Docker via the
official `docker-in-docker` dev container feature instead. The
Containerfiles are standard OCI files and build identically with both
runtimes; only the orchestration differs (Compose in development, Quadlets
in production).

1. Open the repository in a Codespace. The dev container installs Docker
   and shellcheck automatically.
2. Generate the environment file and start the stack:

   ```bash
   bash scripts/generate-env.sh
   docker compose -f compose.dev.yaml up --build -d
   ```

3. Open the forwarded port **10080** and browse to `/redmine`
   (default login: `admin` / `admin`).

The first build takes 15–40 minutes (Ruby compilation, gems, plugin
assets). `compose.dev.yaml` uses named Docker volumes, so data survives
`docker compose down` but is discarded with the Codespace. See
`docs/Setup.md` for the production procedure with Podman + Quadlets.

---

## Documentation

- **[Design Document](docs/Design.md)** — Architecture, network design, user/permission model, directory layout.
- **[Setup Guide](docs/Setup.md)** — Step-by-step installation and configuration.
- **[Operations Manual](docs/Manual.md)** — Backup, restore, log management.

---

## License

See [LICENSE](LICENSE).
