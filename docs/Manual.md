# 運用手順 — RedmineDocker (redmine スタック)

本番環境の Podman デプロイにおける日常運用手順です。パスはリポジトリが `/opt/redmine/containers`、データが `/opt/redmine/data` にある前提です。

---

## サービス制御

`redmine` ユーザーとして実行します（rootless のため `--user` を付けます）。

```bash
systemctl --user start   redmine-db redmine-web
systemctl --user stop    redmine-web redmine-db
systemctl --user restart redmine-web
systemctl --user status  redmine-web
journalctl --user -u redmine-web -f     # アプリケーションログを追跡
podman ps                                 # 実行中コンテナとヘルス状態を表示
```

依存関係 (`Requires=` / `After=`) により、スタックは下から上へ起動し、上から下へ停止します。

---

## 更新

### Redmine / プラグイン / テーマ
`containers/redmine-web/Containerfile`（イメージタグやプラグイン参照）を変更し、再ビルドして再起動します。

```bash
cd /opt/redmine/containers
podman build -t localhost/redmine-web:6.1.3 containers/redmine-web
systemctl --user restart redmine-web     # entrypoint でマイグレーションを再実行
```

### Apache フロントエンド
`redmine-web` イメージに Apache の設定を入れたため、個別の `redmine-static` イメージは不要です。変更後は Redmine イメージを再ビルドして再起動します。

---

## バックアップ

`scripts/backup.sh` は `redmine` データベースのダンプ（pg_dump のカスタム形式）を作成し、`/opt/redmine/data/redmine/files` をアーカイブして `/opt/redmine/backup/` 配下に 7 世代保存します。DB パスワードは `secrets/db_password.txt` から読み取ります。

`redmine` ユーザーとして実行します（rootless Podman のため `sudo` 不要）。

```bash
bash /opt/redmine/containers/scripts/backup.sh
```

`redmine` ユーザーの crontab で毎日 02:00 に実行するように設定できます（`crontab -e` を実行）。

```cron
0 2 * * * /opt/redmine/containers/scripts/backup.sh >> /opt/redmine/backup/backup.log 2>&1
```

---

## 復元

`scripts/restore.sh` は `redmine` データベースを削除して再作成し、ダンプを復元してファイルアーカイブを展開します。**現在のデータは破壊されます**。`RESTORE` 確認プロンプトが表示されます。

```bash
bash /opt/redmine/containers/scripts/restore.sh      /opt/redmine/backup/db/redmine_YYYYMMDD_HHMMSS.dump      /opt/redmine/backup/files/redmine_YYYYMMDD_HHMMSS.tar.gz
```

このスクリプトは `redmine-web` を停止し、DB（PostGIS 拡張込み）を再作成して `pg_restore` を実行し、ファイルを復元してサービスを再起動します。

---

## ログ

| ログ | 配置先 |
|------|--------|
| Redmine アプリケーション | `/opt/redmine/data/redmine/log/production.log` |
| Redmine / Puma の標準出力 | `journalctl --user -u redmine-web` |
| Apache フロントエンド（コンテナ） | `journalctl --user -u redmine-web` |
| ホスト Apache（TLS フロント） | `/var/log/httpd/redmine_{access,error}.log` |

ログローテーションは `logrotate/redmine` で設定されています（`/etc/logrotate.d/redmine-web` に配置）。日次、60 世代、コンテナ内のアプリケーションログには `copytruncate` を使います。

```bash
sudo logrotate --debug /etc/logrotate.d/redmine-web     # ドライラン
```

---

## ヘルスチェックと診断

```bash
podman healthcheck run redmine-web
podman exec -e PGPASSWORD="$(cat /opt/redmine/containers/secrets/db_password.txt)"     redmine-db psql -U redmine -d redmine -c '\dx'          # 拡張機能を表示（postgis を期待）
curl -sf http://127.0.0.1:80/redmine/login >/dev/null && echo OK
```

メンテナンス用の Rails コンソール:

```bash
podman exec -it redmine-web bundle exec rails console -e production
```
