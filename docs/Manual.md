# Operations Manual — RedmineDocker (hwins stack)

Day-to-day operation of the production Podman deployment. Paths assume the
repository is at `/opt/hwins/containers` and data at `/opt/hwins/data`.

---

## Service control

```bash
systemctl start   hwins-db hwins-redmine hwins-static
systemctl stop    hwins-static hwins-redmine hwins-db
systemctl restart hwins-redmine
systemctl status  hwins-redmine
journalctl -u hwins-redmine -f          # follow application logs
podman ps                               # running containers + health
```

Dependencies (`Requires=`/`After=`) start the stack bottom-up and stop it
top-down automatically.

---

## Updating

### Redmine / plugins / theme
Edit `containers/hwins-redmine/Containerfile` (image tag or plugin refs), rebuild,
and restart:

```bash
cd /opt/hwins/containers
podman build -t localhost/hwins-redmine:6.1.3 containers/hwins-redmine
systemctl restart hwins-redmine     # entrypoint re-runs migrations
```

### httpd base image (re-pin digest)
```bash
bash scripts/pin-static-image.sh
podman build -t localhost/hwins-static:2.4 containers/hwins-static
systemctl restart hwins-static
```

---

## Backup

`scripts/backup.sh` dumps the `redmine` database (pg_dump custom format) and
archives `/opt/hwins/data/redmine/files`, keeping 7 generations under
`/opt/hwins/backup/`. It reads the DB password from
`secrets/db_password.txt`.

```bash
sudo bash /opt/hwins/containers/scripts/backup.sh
```

Schedule daily at 02:00:

```bash
echo "0 2 * * * root /opt/hwins/containers/scripts/backup.sh >> /var/log/hwins-backup.log 2>&1" \
    | sudo tee /etc/cron.d/hwins-backup
sudo chmod 644 /etc/cron.d/hwins-backup
```

---

## Restore

`scripts/restore.sh` drops and recreates the `redmine` database, restores the
dump, and unpacks the files archive. **It destroys current data** — it prompts
for a `RESTORE` confirmation.

```bash
sudo bash /opt/hwins/containers/scripts/restore.sh \
    /opt/hwins/backup/db/redmine_YYYYMMDD_HHMMSS.dump \
    /opt/hwins/backup/files/redmine_YYYYMMDD_HHMMSS.tar.gz
```

The script stops `hwins-redmine`, recreates the DB (with PostGIS extensions),
runs `pg_restore`, restores files, and restarts the service.

---

## Logs

| Log                              | Location                                   |
|----------------------------------|--------------------------------------------|
| Redmine application              | `/opt/hwins/data/redmine/log/production.log` |
| Redmine / Puma stdout            | `journalctl -u hwins-redmine`              |
| Reverse proxy (container)        | `journalctl -u hwins-static`               |
| Host Apache (TLS front)          | `/var/log/httpd/redmine_{access,error}.log` |

Rotation is configured by `logrotate/redmine` (install to
`/etc/logrotate.d/hwins-redmine`): daily, 60 generations, `copytruncate` for the
container-held application log.

```bash
sudo logrotate --debug /etc/logrotate.d/hwins-redmine     # dry run
```

---

## Health & diagnostics

```bash
podman healthcheck run hwins-redmine
podman exec -e PGPASSWORD="$(cat /opt/hwins/containers/secrets/db_password.txt)" \
    hwins-db psql -U redmine -d redmine -c '\dx'          # list extensions (expect postgis)
curl -sf http://127.0.0.1:18080/redmine/login >/dev/null && echo OK
```

Rails console (for maintenance):

```bash
podman exec -it hwins-redmine bundle exec rails console -e production
```
