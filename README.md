# RedmineDocker

**Redmine Container Project powered by Podman on RHEL9 / AlmaLinux9**

This repository contains the complete infrastructure-as-code to build, deploy, and operate a Redmine platform using Podman containers managed by systemd Quadlets.

---

## Overview

| Container | Name          | Role                              | Redmine | DB             |
|-----------|---------------|-----------------------------------|---------|----------------|
| Docker0   | redmine-db    | PostgreSQL 17.5 + PostGIS 3.5.2   | —       | —              |
| Docker1   | redmine-prod  | Production Redmine 6.1.3          | 6.1.3   | redmine_prod   |

All containers run under Podman (not Docker) and are managed as systemd services using Quadlet unit files.

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
| PostgreSQL  | **17.5**  |
| PostGIS     | **3.5.2** |
| Redmine     | **6.1.3** |
| Ruby        | 3.4.4     |
| Bundler     | 2.6.8     |
| Node.js     | 22.23.1   |
| Yarn        | 1.22.22   |
| Apache      | 2.4.62    |
| Puma        | (bundled with Redmine 6.1.3) |

---

## Repository Structure

```
RedmineDocker/
├── README.md                     # This file
├── docs/
│   ├── Design.md                 # Architecture and design decisions
│   ├── Setup.md                  # Step-by-step installation guide
│   └── Manual.md                 # Day-to-day operational procedures
├── containers/
│   ├── docker0/                  # PostgreSQL 17.5 + PostGIS 3.5.2 container
│   └── docker1/                  # Production Redmine 6.1.3 container
├── quadlets/                     # Systemd Quadlet unit files
├── host-apache/                  # Host Apache reverse proxy configuration
├── scripts/                      # Operational scripts
├── logrotate/                    # Log rotation configuration
├── .env.example                  # Environment variable template
└── .gitignore
```

---

## Quick Start

1. Clone this repository to `/opt/redmine/containers` on the host.
2. Run `scripts/generate-env.sh` to generate `.env` with random passwords.
3. Follow `docs/Setup.md` for the complete setup procedure.

---

## Documentation

- **[Design Document](docs/Design.md)** — Architecture, network design, user/permission model, directory layout.
- **[Setup Guide](docs/Setup.md)** — Step-by-step installation and configuration.
- **[Operations Manual](docs/Manual.md)** — Backup, restore, log management.

---

## License

See [LICENSE](LICENSE).
