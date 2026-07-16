# 運用手順 — RedmineDocker (redmine スタック)

本番環境の Podman デプロイにおける日常運用手順です。パスはリポジトリが `/opt/redmine/containers`、データが `/opt/redmine/data` にある前提です（`DATA_ROOT` を `.env` で変更している場合はそのパスに読み替えてください）。次の「コマンド集」章のみ、開発環境 (`compose.dev.yaml`) のコマンドも併記しています。

コンテナ名・DB 名・ユーザー名・データルートなどの設定値の一覧と、`.env` に集約できるもの/できないもの（`quadlets/*.container` 自体は `.env` を読めません）は `docs/Design.md` の「設定項目 (Configuration)」章を参照してください。

---

## コマンド集（Podman/Docker が初めての方へ）

### まず基礎知識: イメージ・コンテナ・ボリュームは別物

- **イメージ (image)** — アプリの「設計図」。`build` で作られます。
- **コンテナ (container)** — イメージから実際に動いている（動いていた）実体。
- **ボリューム / bind mount** — DB データや添付ファイルの実体。**イメージともコンテナとも別の場所に保存されています。**

**つまり「ビルドし直す」「コンテナを作り直す」だけでは DB も添付ファイルも消えません。** データが消えるのはボリューム自体を明示的に削除する操作（後述の `down -v` や `/opt/redmine/data` の手動削除）を行ったときだけです。開発環境は名前付きボリューム `pgdata`/`redmine_files`、本番環境は `/opt/redmine/data/` 配下の bind mount にデータが入っています。

### 開発環境 (WSL / Codespaces, `compose.dev.yaml`)

#### 実行・停止

```bash
docker compose -f compose.dev.yaml up -d           # 起動（イメージがあればそのまま使う）
docker compose -f compose.dev.yaml up --build -d   # Containerfile の変更を反映してビルドしてから起動
                                                    #   ※ DB・添付ファイルは消えません（上記参照）
docker compose -f compose.dev.yaml stop            # コンテナを止めるだけ（イメージ・データはそのまま、再開が速い）
docker compose -f compose.dev.yaml down            # コンテナとネットワークを削除（名前付きボリュームは残る＝DB・添付は消えない）
```

#### 確認・ログ

```bash
docker compose -f compose.dev.yaml ps              # 起動状況とヘルスチェック結果
podman ps                                          # 同じ内容を podman 単体で確認
docker compose -f compose.dev.yaml logs -f redmine-web       # ログをリアルタイム追跡（Ctrl+C で終了）
docker compose -f compose.dev.yaml logs --tail 100 redmine-db  # 直近100行だけ表示
```

#### イメージの削除

```bash
podman images                                      # イメージ一覧（サイズ・作成日時を確認）
podman rmi localhost/redmine-web:6.1.3             # 特定のイメージを削除（DB・添付ファイルには影響しません）
docker compose -f compose.dev.yaml down --rmi all  # このスタックのイメージをまとめて削除（ボリュームは残る）
podman image prune                                 # どのコンテナからも参照されていないイメージだけ安全に削除
```

`podman rmi` はそのイメージを使っているコンテナが実行中だと失敗します。先に `docker compose -f compose.dev.yaml down`（`-v` は付けない）でコンテナを止めてから実行してください。

#### ⚠️ 本当に DB・添付ファイルごと消したいとき（開発環境のリセット）

```bash
docker compose -f compose.dev.yaml down -v   # 名前付きボリューム (pgdata, redmine_files) ごと削除
```

`-v` を付けたときだけデータが消えます。動作確認用の使い捨て環境をまっさらに戻したいとき以外は付けないでください。

### 本番環境 (systemd Quadlets)

起動・停止・確認・ログは「サービス制御」章、再ビルドは「更新」章を参照してください（どちらも `/opt/redmine/data` の bind mount とは別物を操作するだけなので、DB・添付ファイルは消えません）。

#### イメージの削除

```bash
podman images
podman rmi localhost/redmine-web:6.1.3   # サービスを停止していないと失敗します（先に systemctl --user stop redmine-web）
podman image prune                        # 未使用イメージだけ安全に削除
```

#### ⚠️ 本当に DB・添付ファイルごと消したいとき

`/opt/redmine/data/` を直接削除する以外に方法はありません。**バックアップ（下記「バックアップ」章）を取ってから、内容をよく確認して実行してください。** 通常の運用でここに触れる必要はありません。

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

`scripts/backup.sh` は `redmine` データベースのダンプ（pg_dump のカスタム形式）を作成し、`/opt/redmine/data/redmine/files` をアーカイブして `/opt/redmine/backup/` 配下に 7 世代保存します。DB パスワードは `secrets/db_password.txt` から読み取ります。DB 名・ユーザー名・コンテナ名・データルートは `/opt/redmine/containers/.env` があればそこから読み込みます（既定値は上記の通り。`docs/Design.md` 参照）。

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
