# Operations Manual — RedmineDocker

## 1. Daily Operations

### Check Container Status

```bash
# View all Redmine-related containers
podman ps --filter label=app=redmine

# View systemd service status
sudo systemctl status redmine-db redmine-prod redmine-test redmine-next

# View recent logs for production
sudo journalctl -u redmine-prod --since "1 hour ago"
```

### Start / Stop / Restart Services

```bash
# Restart production Redmine (graceful — Puma drains connections)
sudo systemctl restart redmine-prod

# Restart all Redmine services
sudo systemctl restart redmine-db redmine-prod redmine-test redmine-next

# Stop a specific environment (e.g., upgrade test)
sudo systemctl stop redmine-next

# Start it again
sudo systemctl start redmine-next
```

### View Application Logs

```bash
# Redmine production application log (Rails)
tail -f /opt/redmine/data/redmine1/log/production.log

# Redmine test environment log
tail -f /opt/redmine/data/redmine2/log/production.log

# Apache access log inside production container
podman exec redmine-prod tail -f /var/log/httpd/access_log

# Puma log
tail -f /opt/redmine/data/redmine1/log/puma.log

# Systemd journal for production container
sudo journalctl -u redmine-prod -n 100 --no-pager
```

---

## 2. Backup Procedures

### Automated Backup

A daily backup runs at 02:00 via cron (`/etc/cron.d/redmine-backup`). It retains exactly **7 generations**.

```bash
# Verify the cron job is installed
cat /etc/cron.d/redmine-backup

# Manually trigger a backup (useful for pre-upgrade snapshots)
sudo /opt/redmine/containers/scripts/backup.sh
```

### What Gets Backed Up

| Item                    | Backup Location                              | Method         |
|-------------------------|----------------------------------------------|----------------|
| Production DB           | `/opt/redmine/backup/db/redmine_prod_YYYYMMDD_HHMMSS.dump` | pg_dump (custom format) |
| Plugin Test DB          | `/opt/redmine/backup/db/redmine_test_YYYYMMDD_HHMMSS.dump` | pg_dump        |
| Upgrade Test DB         | `/opt/redmine/backup/db/redmine_next_YYYYMMDD_HHMMSS.dump` | pg_dump        |
| Production files        | `/opt/redmine/backup/files/redmine1_YYYYMMDD_HHMMSS.tar.gz` | tar+gzip       |
| Plugin Test files       | `/opt/redmine/backup/files/redmine2_YYYYMMDD_HHMMSS.tar.gz` | tar+gzip       |
| Upgrade Test files      | `/opt/redmine/backup/files/redmine3_YYYYMMDD_HHMMSS.tar.gz` | tar+gzip       |

### List Existing Backups

```bash
# Database backups
ls -lht /opt/redmine/backup/db/ | head -20

# File backups
ls -lht /opt/redmine/backup/files/ | head -20
```

### Backup Rotation

The script automatically deletes backups older than 7 generations. Verify the rotation is working:

```bash
ls /opt/redmine/backup/db/redmine_prod_*.dump | wc -l
# Expected: exactly 7 (after 7+ days of operation)
```

---

## 3. Disaster Recovery (Restore from Backup)

### Full Restore Procedure

Use `scripts/restore.sh` for guided restore. The script accepts the database name and backup file as arguments.

```bash
# Syntax:
sudo /opt/redmine/containers/scripts/restore.sh <env> <db_dump_file> <files_archive>

# Example: restore production from a specific backup
sudo /opt/redmine/containers/scripts/restore.sh \
    prod \
    /opt/redmine/backup/db/redmine_prod_20260620_020000.dump \
    /opt/redmine/backup/files/redmine1_20260620_020000.tar.gz
```

### Manual Step-by-Step Restore

If the script is unavailable, perform these steps manually:

#### Step 1: Stop Redmine Application

```bash
sudo systemctl stop redmine-prod
```

#### Step 2: Restore the Database

```bash
source /opt/redmine/containers/.env

# Drop and recreate the database
podman exec redmine-db psql -U postgres -c "DROP DATABASE IF EXISTS redmine_prod;"
podman exec redmine-db psql -U postgres \
    -c "CREATE DATABASE redmine_prod OWNER redmine_adm ENCODING 'UTF8';"
podman exec redmine-db psql -U postgres -d redmine_prod \
    -c "CREATE EXTENSION IF NOT EXISTS postgis;"
podman exec redmine-db psql -U postgres -d redmine_prod \
    -c "CREATE EXTENSION IF NOT EXISTS postgis_topology;"
podman exec redmine-db psql -U postgres -d redmine_prod \
    -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO redmine_adm;"
podman exec redmine-db psql -U postgres -d redmine_prod \
    -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO redmine_adm;"

# Restore from pg_dump custom-format backup
# Copy dump file into the container first
podman cp /opt/redmine/backup/db/redmine_prod_20260620_020000.dump \
    redmine-db:/tmp/restore.dump

podman exec redmine-db pg_restore \
    -U postgres \
    -d redmine_prod \
    --no-owner \
    --role=redmine_adm \
    /tmp/restore.dump

# Clean up
podman exec redmine-db rm /tmp/restore.dump
```

#### Step 3: Restore Uploaded Files

```bash
# Remove current files
rm -rf /opt/redmine/data/redmine1/files/*

# Extract backup archive
tar -xzf /opt/redmine/backup/files/redmine1_20260620_020000.tar.gz \
    -C /opt/redmine/data/redmine1/files/

# Fix ownership
chown -R redmine_adm:redmine /opt/redmine/data/redmine1/files/
```

#### Step 4: Clear Caches and Restart

```bash
# Clear Redmine cache (inside container at next start — entrypoint handles this)
rm -rf /opt/redmine/data/redmine1/tmp/cache/*

# Restart the application
sudo systemctl start redmine-prod

# Monitor startup
sudo journalctl -u redmine-prod -f
```

#### Step 5: Verify Restoration

```bash
# Check container is running
sudo systemctl status redmine-prod

# Verify database row counts (quick sanity check)
podman exec redmine-db psql -U postgres -d redmine_prod \
    -c "SELECT relname, n_live_tup FROM pg_stat_user_tables ORDER BY n_live_tup DESC LIMIT 10;"

# Check application is responding
curl -sk https://localhost/redmine | grep -i 'redmine\|login'
```

---

## 4. Log Management

### Log Rotation Configuration

Log rotation is configured in `/etc/logrotate.d/redmine` and runs daily via the system logrotate cron job. Logs are retained for exactly **60 days**.

```bash
# View the logrotate config
cat /etc/logrotate.d/redmine

# Force an immediate rotation (for testing)
sudo logrotate --force /etc/logrotate.d/redmine

# Verify rotation is working (check for .1, .2, .gz files)
ls -la /opt/redmine/data/redmine1/log/
```

### Accessing Rotated Logs

```bash
# Current log
tail -f /opt/redmine/data/redmine1/log/production.log

# Yesterday's log
zcat /opt/redmine/data/redmine1/log/production.log.1.gz 2>/dev/null \
    || cat /opt/redmine/data/redmine1/log/production.log.1

# Search for errors in all rotated logs
zgrep -h "ERROR\|FATAL" /opt/redmine/data/redmine1/log/production.log* | head -50
```

### Container Journal Logs (systemd)

```bash
# Last 100 lines of journal for production container
sudo journalctl -u redmine-prod -n 100

# Since a specific date
sudo journalctl -u redmine-prod --since "2026-06-20 00:00:00"

# Export to file
sudo journalctl -u redmine-prod --since "7 days ago" > /tmp/redmine-prod-journal.log
```

---

## 5. Environment Synchronization

### Purpose

- **Prod → Test (Docker2)**: Refresh the plugin verification environment with current production data to test new plugins against real data.
- **Prod → Next (Docker3)**: Refresh the upgrade test environment with current production data to test a new Redmine version.

### Sync Procedure (Automated)

```bash
# Sync production to plugin test environment (Docker2)
sudo /opt/redmine/containers/scripts/sync-env.sh prod test

# Sync production to upgrade test environment (Docker3)
sudo /opt/redmine/containers/scripts/sync-env.sh prod next
```

### Manual Sync Step-by-Step

#### Step 1: Stop Target Environment

```bash
sudo systemctl stop redmine-test   # or redmine-next
```

#### Step 2: Dump Production Database

```bash
source /opt/redmine/containers/.env

podman exec redmine-db pg_dump \
    -U postgres \
    -F c \
    -f /tmp/prod_snapshot.dump \
    redmine_prod

podman cp redmine-db:/tmp/prod_snapshot.dump /tmp/prod_snapshot.dump
podman exec redmine-db rm /tmp/prod_snapshot.dump
```

#### Step 3: Restore into Target Database

```bash
# For plugin test environment (target: redmine_test)
podman exec redmine-db psql -U postgres -c "DROP DATABASE IF EXISTS redmine_test;"
podman exec redmine-db psql -U postgres \
    -c "CREATE DATABASE redmine_test OWNER redmine_adm ENCODING 'UTF8';"
podman exec redmine-db psql -U postgres -d redmine_test \
    -c "CREATE EXTENSION IF NOT EXISTS postgis;"
podman exec redmine-db psql -U postgres -d redmine_test \
    -c "CREATE EXTENSION IF NOT EXISTS postgis_topology;"

podman cp /tmp/prod_snapshot.dump redmine-db:/tmp/restore.dump
podman exec redmine-db pg_restore \
    -U postgres \
    -d redmine_test \
    --no-owner \
    --role=redmine_adm \
    /tmp/restore.dump
podman exec redmine-db rm /tmp/restore.dump
rm /tmp/prod_snapshot.dump
```

#### Step 4: Sync Uploaded Files

```bash
rsync -a --delete \
    /opt/redmine/data/redmine1/files/ \
    /opt/redmine/data/redmine2/files/

chown -R redmine_adm:redmine /opt/redmine/data/redmine2/files/
```

#### Step 5: Run Any Pending Migrations (for Docker3 upgrade testing)

For the upgrade test environment, after syncing data, new Redmine migrations may need to run:

```bash
sudo systemctl start redmine-next
# The entrypoint will run `bundle exec rake db:migrate` if needed
sudo journalctl -u redmine-next -f
```

#### Step 6: Restart Target Environment

```bash
sudo systemctl start redmine-test   # or redmine-next
sudo systemctl status redmine-test
```

---

## 6. Plugin Deployment Workflow

### Testing a New Plugin (Docker2 → Docker1)

1. **Add the plugin to Docker2's Containerfile** in `containers/docker2/Containerfile`.
2. **Rebuild Docker2 image**:
   ```bash
   podman build -t localhost/redmine-test:6.1.3-with-newplugin containers/docker2/
   ```
3. **Update `quadlets/redmine-test.container`** to reference the new image tag.
4. **Reload and restart**:
   ```bash
   sudo systemctl daemon-reload && sudo systemctl restart redmine-test
   ```
5. **Test the plugin thoroughly** in the Docker2 environment.
6. **If approved**, add the plugin to Docker1's Containerfile and repeat for production.

### Installing a Plugin Without Rebuilding (Quick Test)

For rapid iteration, install a plugin directly into the running Docker2 container:

```bash
# Open a shell in the test container
podman exec -it --user redmine_adm redmine-test /bin/bash

# Inside the container:
cd /opt/redmine/app/plugins
git clone https://github.com/some-author/some-plugin.git
cd /opt/redmine/app
bundle install
RAILS_ENV=production bundle exec rake redmine:plugins:migrate

# Restart the container (triggers entrypoint)
exit
sudo systemctl restart redmine-test
```

> Note: Changes made this way are **not persistent** across image rebuilds. Add the plugin to the Containerfile for a permanent installation.

---

## 7. Redmine Version Upgrade Testing (Docker3)

### Workflow

Docker3 (`redmine-next`) tracks the Redmine development branch (`main`). Use it to validate the upgrade path before applying it to production.

#### Step 1: Sync Data from Production

```bash
sudo /opt/redmine/containers/scripts/sync-env.sh prod next
```

#### Step 2: Rebuild Docker3 Image

```bash
# Edit containers/docker3/Containerfile to update REDMINE_VERSION or branch
vi /opt/redmine/containers/containers/docker3/Containerfile

# Rebuild
podman build -t localhost/redmine-next:dev /opt/redmine/containers/containers/docker3/
```

#### Step 3: Update Quadlet and Restart

```bash
sudo systemctl daemon-reload
sudo systemctl restart redmine-next
sudo journalctl -u redmine-next -f
```

#### Step 4: Validate

- Browse to `https://your-host/redmine-next`
- Test all critical workflows: issue creation, wiki, file upload, GTT maps
- Verify all plugins load without errors in Administration → Plugins
- Run plugin-specific tests where applicable

#### Step 5: Promote to Production

When satisfied with the upgrade:

1. Update `REDMINE_VERSION` in `containers/docker1/Containerfile`
2. Run a manual backup: `sudo /opt/redmine/containers/scripts/backup.sh`
3. Rebuild Docker1: `podman build -t localhost/redmine-prod:X.Y.Z containers/docker1/`
4. Update `quadlets/redmine-prod.container` with new image tag
5. `sudo systemctl daemon-reload && sudo systemctl restart redmine-prod`

---

## 8. Container Maintenance

### Update Container Images

```bash
# Rebuild all images (e.g., after base OS security updates)
source /opt/redmine/containers/.env
podman build --no-cache -t localhost/redmine-db:17.5-3.5.2 containers/docker0/
podman build --no-cache -t localhost/redmine-prod:6.1.3 containers/docker1/

# Update quadlet to use new image
# (If tag hasn't changed, just restart to use same tag)
sudo systemctl restart redmine-prod
```

### Prune Unused Container Layers

```bash
# Remove stopped containers and dangling images
podman container prune -f
podman image prune -f

# More aggressive cleanup (removes all unused images)
podman system prune -f
```

### Check Disk Usage

```bash
# Container storage
podman system df

# Data directories
du -sh /opt/redmine/data/redmine1/
du -sh /opt/redmine/data/redmine2/
du -sh /opt/redmine/data/redmine3/
du -sh /opt/redmine/backup/

# PostgreSQL data
du -sh /opt/redmine/data/postgres/
```

---

## 9. Database Maintenance

### PostgreSQL Vacuum and Analyze

```bash
# Run vacuum on all Redmine databases (recommended weekly)
podman exec redmine-db vacuumdb -U postgres --all --analyze --verbose
```

### Check Database Size

```bash
podman exec redmine-db psql -U postgres -c \
    "SELECT datname, pg_size_pretty(pg_database_size(datname)) AS size \
     FROM pg_database WHERE datname LIKE 'redmine%';"
```

### Connect to Database Directly

```bash
# Production database
podman exec -it redmine-db psql -U postgres -d redmine_prod

# Plugin test database
podman exec -it redmine-db psql -U postgres -d redmine_test
```

### PostgreSQL Configuration Reload (without restart)

```bash
podman exec redmine-db psql -U postgres -c "SELECT pg_reload_conf();"
```

---

## 10. Troubleshooting

### Container Fails to Start

```bash
# Check systemd journal for errors
sudo journalctl -u redmine-prod -n 50 --no-pager

# Check container logs directly
podman logs redmine-prod

# Check if the container image exists
podman images | grep redmine
```

### Puma Socket Not Created

```bash
# Check if puma.sock exists
ls -la /opt/redmine/data/redmine1/tmp/puma.sock

# If missing, check Puma log
cat /opt/redmine/data/redmine1/log/puma.log

# Manually test Puma startup inside the container
podman exec -it --user redmine_adm redmine-prod /bin/bash
cd /opt/redmine/app
RAILS_ENV=production bundle exec puma -C config/puma.rb
```

### "502 Bad Gateway" from Host Apache

```bash
# Verify container is running and port is accessible
curl -sk http://127.0.0.1:10080/redmine | head -20

# Check host Apache error log
sudo tail -50 /var/log/httpd/error_log

# Check Apache is loading the proxy config
sudo httpd -S | grep redmine
```

### Database Connection Error

```bash
# Verify database container is running
sudo systemctl status redmine-db

# Test connectivity from production container
podman exec redmine-prod /bin/bash -c \
    "PGPASSWORD=\$REDMINE_DB_PASSWORD psql -U redmine_adm -h redmine-db -d redmine_prod -c '\q' && echo OK"
```

### Plugin Fails to Load

```bash
# Check Rails error log for plugin errors
grep -i "error\|exception\|plugin" /opt/redmine/data/redmine1/log/production.log | tail -30

# Verify plugin directory exists and has correct permissions
podman exec redmine-prod ls -la /opt/redmine/app/plugins/

# Re-run plugin migrations for a specific plugin
podman exec --user redmine_adm redmine-prod /bin/bash -c \
    "cd /opt/redmine/app && RAILS_ENV=production bundle exec rake redmine:plugins:migrate NAME=plugin_name"
```

### Redmine_gtt Map Not Displaying

The `redmine_gtt` plugin requires:
- PostGIS extensions enabled on the database
- `database.yml` using `postgis` adapter (not `postgresql`)
- Yarn and webpack build completed during image build

```bash
# Verify PostGIS extension
podman exec redmine-db psql -U postgres -d redmine_prod \
    -c "SELECT PostGIS_Version();"

# Verify adapter in use (from container)
podman exec redmine-prod grep adapter /opt/redmine/app/config/database.yml
# Expected: adapter: postgis
```

### SELinux Denials

```bash
# Check for recent SELinux denials related to Redmine
sudo ausearch -m avc -ts recent | grep -i redmine

# View audit2allow suggestions
sudo audit2allow -a | grep -A5 redmine
```
