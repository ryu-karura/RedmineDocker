# 運用手順 — RedmineDocker (hwins スタック)

本番環境の Podman デプロイにおける日常運用手順です。パスはリポジトリが `/opt/hwins/containers`、データが `/opt/hwins/data` にある前提です。

---

## サービス制御

`hwins` ユーザーとして実行します（rootless のため `--user` を付けます）。

```bash
systemctl --user start   hwins-db hwins-redmine
systemctl --user stop    hwins-redmine hwins-db
systemctl --user restart hwins-redmine
systemctl --user status  hwins-redmine
journalctl --user -u hwins-redmine -f     # アプリケーションログを追跡
podman ps                                 # 実行中コンテナとヘルス状態を表示
```

依存関係 (`Requires=` / `After=`) により、スタックは下から上へ起動し、上から下へ停止します。

---

## 更新

### Redmine / プラグイン / テーマ
`containers/hwins-redmine/Containerfile`（イメージタグやプラグイン参照）を変更し、再ビルドして再起動します。

```bash
cd /opt/hwins/containers
podman build -t localhost/hwins-redmine:6.1.3 containers/hwins-redmine
systemctl --user restart hwins-redmine     # entrypoint でマイグレーションを再実行
```

### Apache フロントエンド
`hwins-redmine` イメージに Apache の設定を入れたため、個別の `hwins-static` イメージは不要です。変更後は Redmine イメージを再ビルドして再起動します。

---

## バックアップ

`scripts/backup.sh` は `redmine` データベースのダンプ（pg_dump のカスタム形式）を作成し、`/opt/hwins/data/redmine/files` をアーカイブして `/opt/hwins/backup/` 配下に 7 世代保存します。DB パスワードは `secrets/db_password.txt` から読み取ります。

`hwins` ユーザーとして実行します（rootless Podman のため `sudo` 不要）。

```bash
bash /opt/hwins/containers/scripts/backup.sh
```

`hwins` ユーザーの crontab で毎日 02:00 に実行するように設定できます（`crontab -e` を実行）。

```cron
0 2 * * * /opt/hwins/containers/scripts/backup.sh >> /opt/hwins/backup/backup.log 2>&1
```

---

## 復元

`scripts/restore.sh` は `redmine` データベースを削除して再作成し、ダンプを復元してファイルアーカイブを展開します。**現在のデータは破壊されます**。`RESTORE` 確認プロンプトが表示されます。

```bash
bash /opt/hwins/containers/scripts/restore.sh      /opt/hwins/backup/db/redmine_YYYYMMDD_HHMMSS.dump      /opt/hwins/backup/files/redmine_YYYYMMDD_HHMMSS.tar.gz
```

このスクリプトは `hwins-redmine` を停止し、DB（PostGIS 拡張込み）を再作成して `pg_restore` を実行し、ファイルを復元してサービスを再起動します。

---

## ログ

| ログ | 配置先 |
|------|--------|
| Redmine アプリケーション | `/opt/hwins/data/redmine/log/production.log` |
| Redmine / Puma の標準出力 | `journalctl --user -u hwins-redmine` |
| Apache フロントエンド（コンテナ） | `journalctl --user -u hwins-redmine` |
| ホスト Apache（TLS フロント） | `/var/log/httpd/redmine_{access,error}.log` |

ログローテーションは `logrotate/redmine` で設定されています（`/etc/logrotate.d/hwins-redmine` に配置）。日次、60 世代、コンテナ内のアプリケーションログには `copytruncate` を使います。

```bash
sudo logrotate --debug /etc/logrotate.d/hwins-redmine     # ドライラン
```

---

## ヘルスチェックと診断

```bash
podman healthcheck run hwins-redmine
podman exec -e PGPASSWORD="$(cat /opt/hwins/containers/secrets/db_password.txt)"     hwins-db psql -U redmine -d redmine -c '\dx'          # 拡張機能を表示（postgis を期待）
curl -sf http://127.0.0.1:18080/redmine/login >/dev/null && echo OK
```

メンテナンス用の Rails コンソール:

```bash
podman exec -it hwins-redmine bundle exec rails console -e production
```
