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

## 日常確認（まず最初に見る項目）

### Podman (本番 / Quadlet)

```bash
systemctl --user status redmine-db redmine-web
podman ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
podman healthcheck run redmine-db
podman healthcheck run redmine-web
journalctl --user -u redmine-web -n 200 --no-pager
```

### Docker Compose (開発)

```bash
docker compose -f compose.dev.yaml ps
docker compose -f compose.dev.yaml logs -f redmine-web
docker compose -f compose.dev.yaml top
```

---

## イメージビルド手順

### Podman (本番)

```bash
cd /opt/redmine/containers
set -a; source .env; set +a
podman build -t "${REDMINE_DB_IMAGE}"  --build-arg DB_BASE_IMAGE="${REDMINE_DB_BASE_IMAGE}"   containers/redmine-db
podman build -t "${REDMINE_WEB_IMAGE}" --build-arg WEB_BASE_IMAGE="${REDMINE_WEB_BASE_IMAGE}" containers/redmine-web
podman images | grep -E 'redmine-(db|web)'
```

### Docker Compose (開発)

```bash
cd /workspaces/RedmineDocker
docker compose -f compose.dev.yaml build --pull
docker compose -f compose.dev.yaml up -d
```

---

## 更新・再作成のケース別手順

### ケース A: アプリ更新（通常更新。DBデータは保持）

対象: Redmine 本体の軽微更新、プラグイン更新、Apache 設定変更、`.env` の SMTP/TZ 変更。

手順 (Podman):

```bash
cd /opt/redmine/containers
# 1) 必要なら .env/Containerfile を更新
set -a; source .env; set +a
podman build -t "${REDMINE_WEB_IMAGE}" --build-arg WEB_BASE_IMAGE="${REDMINE_WEB_BASE_IMAGE}" containers/redmine-web
systemctl --user restart redmine-web
```

手順 (Docker Compose):

```bash
cd /workspaces/RedmineDocker
docker compose -f compose.dev.yaml up -d --build redmine-web
```

ポイント:
- `redmine-web` 再起動時に `entrypoint.sh` が `db:migrate` と plugin migrate を冪等実行します。
- DB ボリュームは削除しません（データ保持）。

### ケース B: DB も含む更新（PostgreSQL/PostGIS 変更、または破壊的変更の可能性）

対象: `REDMINE_DB_PG_MAJOR` や `REDMINE_DB_POSTGIS_VERSION` を変更する場合。

推奨手順（安全側）:

```bash
# 1) 事前バックアップ
bash /opt/redmine/containers/scripts/backup.sh

# 2) 新バージョンでイメージ再ビルド
cd /opt/redmine/containers
set -a; source .env; set +a
podman build -t "${REDMINE_DB_IMAGE}"  --build-arg DB_BASE_IMAGE="${REDMINE_DB_BASE_IMAGE}"   containers/redmine-db
podman build -t "${REDMINE_WEB_IMAGE}" --build-arg WEB_BASE_IMAGE="${REDMINE_WEB_BASE_IMAGE}" containers/redmine-web

# 3) サービス再起動
systemctl --user restart redmine-db redmine-web

# 4) 必要なら restore（互換性問題が出た場合）
# bash /opt/redmine/containers/scripts/restore.sh <db_dump> <files_archive>
```

注意:
- メジャーアップデートは DB 内部フォーマット変更を伴う可能性があるため、事前バックアップを必須にしてください。
- 既存データを使っての移行（migrate）で進めるか、復元ベースで作り直すかは、ダウンタイム要件と検証結果で決めます。

### ケース C: 完全再作成（データを消して作り直す）

対象: 検証環境を初期化したい場合、設定汚染をリセットしたい場合。

Docker Compose (開発) で全削除:

```bash
cd /workspaces/RedmineDocker
docker compose -f compose.dev.yaml down -v
docker compose -f compose.dev.yaml up -d --build
```

Podman (本番相当) で全削除:

```bash
systemctl --user stop redmine-web redmine-db
# 本番データ削除は非常に危険。必ず backup 実施後に行う。
rm -rf /opt/redmine/data/postgres/18/*
rm -rf /opt/redmine/data/redmine/files/*
rm -rf /opt/redmine/data/redmine/log/*
systemctl --user start redmine-db redmine-web
```

### ケース D: SUBURI / ポート / コンテナ名変更

対象: `.env` の `REDMINE_SUBURI`、`REDMINE_WEB_HOST_PORT`、`REDMINE_DB_CONTAINER` などを変更する場合。

手順:

```bash
# 1) .env 変更後に構成確認
docker compose -f compose.dev.yaml config

# 2) 再ビルド・再作成
docker compose -f compose.dev.yaml up -d --build --force-recreate
```

ポイント:
- SUBURI 変更時は `host-apache/redmine-proxy.conf` の転送先パスも合わせて更新してください。
- コンテナ名変更時は、既存コンテナとの衝突回避のため `down` 後の再作成が安全です。

---

## 更新

### Redmine / プラグイン / テーマ
`containers/redmine-web/Containerfile`（イメージタグやプラグイン参照）を変更し、再ビルドして再起動します。

```bash
cd /opt/redmine/containers
set -a; source .env; set +a
podman build -t "${REDMINE_WEB_IMAGE}" --build-arg WEB_BASE_IMAGE="${REDMINE_WEB_BASE_IMAGE}" containers/redmine-web
systemctl --user restart redmine-web     # entrypoint でマイグレーションを再実行
```

マイグレーションを実行せずに起動したい場合（アップグレード前の DB 確認など）は、
公式イメージと同じく `REDMINE_NO_DB_MIGRATE` に値を設定します
（`quadlets/redmine-web.container` のコメント行を参照）。値を空にする / 未設定に戻すと
再びコアの `db:migrate` を実行します。

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
bash /opt/redmine/containers/scripts/restore.sh \
  /opt/redmine/backup/db/redmine_YYYYMMDD_HHMMSS.dump \
  /opt/redmine/backup/files/redmine_YYYYMMDD_HHMMSS.tar.gz
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
podman exec -e PGPASSWORD="$(cat /opt/redmine/containers/secrets/db_password.txt)" \
	redmine-db psql -U redmine -d redmine -c '\\dx'   # 拡張機能を表示（postgis を期待）
curl -sf http://127.0.0.1:80/redmine/login >/dev/null && echo OK
```

メンテナンス用の Rails コンソール:

```bash
podman exec -it redmine-web bundle exec rails console -e production
```
