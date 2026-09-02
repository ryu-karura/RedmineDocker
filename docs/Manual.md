# 運用手順 — RedmineDocker (redmine スタック)

本番環境の Podman デプロイにおける日常運用手順です。パスはリポジトリが `/opt/redmine/containers`、データが `/opt/redmine/data` にある前提です（`REDMINE_DATA_DIR` を `.env` で変更している場合はそのパスに読み替えてください）。次の「コマンド集」章のみ、開発環境 (`compose.dev.yaml`) のコマンドも併記しています。

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
podman build -t "${REDMINE_WEB_IMAGE}" \
    -f "containers/redmine-web/${REDMINE_WEB_CONTAINERFILE}" \
    --build-arg WEB_BASE_IMAGE="${REDMINE_WEB_BASE_IMAGE}" containers/redmine-web
podman images | grep -E 'redmine-(db|web)'
```

`REDMINE_WEB_CONTAINERFILE` は Redmine の系列に対応します
（`Containerfile.v5` / `Containerfile.v6`（既定）/ `Containerfile.v7`）。

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

### ケース B-2: 別 DB 製品からの移行 / Redmine メジャーバージョンのアップグレード

対象: 既存の **Redmine 5.1.1 + MySQL 8.0 CE** をこの構成（PostgreSQL 18 + PostGIS 3.6）へ
移し、さらに Redmine 7.0.0 へ上げる場合。

手順は独立したドキュメントにまとめています → **[docs/Upgrade.md](Upgrade.md)**

要点だけ:

- 移行元は `compose.legacy.yaml` でコンテナとして再現できます（`:8081`。通常スタックと同時起動可）。
- DB のコンバートは `bash scripts/migrate-mysql-to-postgres.sh`
  （スキーマは Rails のマイグレーションで作り、データだけ pgloader で転送します）。
- Redmine 7 へ上げる前に、7 系イメージに無いプラグインをアンインストールしてください
  （マイグレーションを持つのは `redmine_theme_changer` だけです。
  `rake redmine:plugins:migrate NAME=redmine_theme_changer VERSION=0`）。
- アプリを公開せずにマイグレーションだけ先に流したい場合は `REDMINE_MIGRATE_ONLY=1` で単発起動します。
- 通しの自動検証は `bash scripts/test-upgrade.sh`。

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

### ケース E: アプリサーバー切り替え（Puma ⇄ Passenger）

対象: `REDMINE_WEB_SERVER` を `puma`（既定: Apache → ProxyPass → Puma :3000）と
`passenger`（Apache + mod_passenger が Redmine を直接起動、:3000 なし）で切り替える場合。
イメージには両方式が同梱されているため **再ビルドは不要** で、コンテナ再起動のみで反映されます。

開発 (Compose):

```bash
# .env の REDMINE_WEB_SERVER を puma / passenger に変更してから
docker compose -f compose.dev.yaml up -d --force-recreate redmine-web
docker compose -f compose.dev.yaml logs -f redmine-web
```

本番 (Quadlet):

```bash
# ~/.config/containers/systemd/redmine-web.container の
#   Environment=REDMINE_WEB_SERVER=puma
# を passenger に書き換える（または /opt/redmine/containers/.env に記述する）
systemctl --user daemon-reload
systemctl --user restart redmine-web
```

切り替え後の確認:

```bash
podman exec redmine-web apache2ctl -M | grep passenger   # passenger のときだけ passenger_module が出る
podman exec redmine-web passenger-status                 # passenger のときのみ成功（アプリのプロセス一覧）
podman exec redmine-web curl -sf http://127.0.0.1:3000/redmine/login >/dev/null \
  && echo "puma listening" || echo "no puma (passenger mode)"
podman healthcheck run redmine-web                       # どちらのモードでも 0 で終了すること
```

ヘルスチェックはイメージ内の `/usr/local/bin/redmine-healthcheck.sh` が担当し、
モードに応じて Puma 直叩きの検証を自動で省きます。

なお **Redmine 7 系の mod_passenger は forky (Debian 14) の 6.1.x** です（ベースが Ruby 4.0 で、
Passenger の Ruby 4 対応が 6.1.1 以降のため。5 系 / 6 系は trixie の 6.0.26）。
稼働中のバージョンは次で確認できます。

```bash
podman exec redmine-web dpkg-query -W -f='${Version}\n' libapache2-mod-passenger
```

7 系を本番へ出す前に
`bash scripts/test-stack.sh --series 7 --web-server passenger` で実測してください
（このテストは 6.1 以上であることも検証します）。

### ケース F: Redmine のメジャーバージョン系列切り替え（5 ⇄ 6 ⇄ 7）

対象: `Containerfile.v5` / `Containerfile.v6` / `Containerfile.v7` を切り替える場合。
系列ごとにベースイメージとプラグイン構成が違うため、**再ビルドが必要** です。

> **注意**: 起動できるのは一度に 1 系列だけです（コンテナ名・ポート・データが共通）。
> また DB の中身は系列間で互換ではありません。上位系列を起動すると起動時の
> `db:migrate` が走り、**元の系列へは戻せません**。必ず先にバックアップを取ってください。

開発 (Compose):

```bash
# 0) 事前バックアップ（系列を戻せるようにするため必須）
bash scripts/backup.sh

# 1) .env を 2 つセットで変更（例: 6 系 → 7 系）
#      REDMINE_VERSION=7.0.0
#      REDMINE_WEB_CONTAINERFILE=Containerfile.v7

# 2) 再ビルドして再作成
docker compose -f compose.dev.yaml up --build -d
docker compose -f compose.dev.yaml logs -f redmine-web   # マイグレーションの進行を確認
```

本番 (Quadlet):

```bash
# 0) 事前バックアップ
bash /opt/redmine/containers/scripts/backup.sh

# 1) .env を変更してイメージを再ビルド（「イメージビルド手順」参照）

# 2) 系列に対応する web ユニットへ差し替え（db / network は共通）
cp quadlets/v7/redmine-web.container ~/.config/containers/systemd/
systemctl --user daemon-reload
systemctl --user restart redmine-web
systemctl --user status redmine-web
```

切り替え後の確認:

```bash
podman exec redmine-web cat /usr/src/redmine/lib/redmine/version.rb | head -8   # 本体バージョン
podman exec redmine-web ls /usr/src/redmine/plugins                             # 同梱プラグイン
podman healthcheck run redmine-web
```

系列ごとの同梱プラグインの違い（5 系は `redmine_login_audit2` と `redmine_solid_queue` が
入らない、7 系の `redmine_banner` はタグではなく master 固定、等）は `docs/Design.md`
「Redmine シリーズの切り替え」を参照してください。6 系 → 7 系では `redmine_gtt` が
6.0.3 から 7.1.0 に上がるため、MDI グリフを直接指定していたトラッカーアイコンは
既定マーカーに戻ります。管理画面のトラッカー設定で選び直してください。

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
`redmine-web` イメージに Apache の設定を入れたため、個別の `redmine-static` イメージは不要です。変更後は Redmine イメージを再ビルドして再起動します。設定は
`containers/redmine-web/httpd-redmine.conf.tmpl`（`puma` 用）と
`containers/redmine-web/httpd-redmine-passenger.conf.tmpl`（`passenger` 用）の
テンプレートから `entrypoint.sh` が起動時に描画します。生成後の `.conf` ではなく
`.tmpl` を編集してください。

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

### Passenger モード特有のトラブルシューティング

| 症状 | 原因と対処 |
|------|------------|
| どの URL も 404（ログに `No route matches [GET] "/login"`） | `config.ru` が Passenger 配下でも `map` してしまっています。`mod_passenger` は `PassengerBaseURI` で `PATH_INFO` からプレフィックスを除去済みのため、`map` を挟むとマッチしません。`containers/redmine-web/config.ru` の `defined?(PhusionPassenger)` 分岐が消えていないか確認してください。 |
| 添付ファイルのアップロードやログ出力が権限エラーになる | Passenger がアプリを `nobody` で起動しています。`config.ru` の所有者が `redmine` であること（`podman exec redmine-web ls -l /usr/src/redmine/config.ru`）と、`redmine-passenger.conf` に `PassengerUser redmine` があることを確認してください。 |
| gem が見つからない / bundler エラーで起動しない | `PassengerRuby` が Debian のシステム Ruby (`/usr/bin/ruby`) を向いています。`redmine-passenger.conf` の `PassengerRuby /usr/local/bin/ruby` を確認してください。 |
| CSS/JS/テーマだけ 404 になる | Apache が `public/` を配信できていません。`redmine-passenger.conf` の `Alias` と `<Directory>` の `Require all granted` を確認してください。 |
| error log に native support のコンパイル警告が出る | 想定内です。Passenger は pure-Ruby 実装へフォールバックして動作を継続します（わずかに遅くなるのみ）。 |
| 7 系のビルドが `ERROR: libapache2-mod-passenger <版> < 6.1` で止まる | forky の `libapache2-mod-passenger` が 6.1 未満に戻っています。`Containerfile.v7` の `ARG PASSENGER_APT_SUITE` を 6.1 以上を持つスイート（例: `sid`）へ変えるか、`docs/Design.md`「9. Redmine シリーズの切り替え」の代替案（Phusion の APT リポジトリ / 7 系は `puma` 専用）を検討してください。 |
| 7 系のビルドが forky の `apt-get install` で依存関係エラーになる | forky の passenger が trixie では満たせない依存を要求しています。APT pin が意図どおり働いて部分アップグレードを止めた状態です（`libc6` 等が黙って上がることはありません）。上と同じ代替案を検討してください。 |
| 7 系のビルドが forky の `apt-get update` で `NO_PUBKEY` になる | ベースイメージの `debian-archive-keyring` に forky の署名鍵が入っていません。ベースイメージを更新（`podman pull docker.io/library/redmine:7.0.0`）してから再ビルドしてください。 |

現在有効な Apache 設定は次で確認できます:

```bash
podman exec redmine-web ls -l /etc/apache2/conf-enabled/
podman exec redmine-web apache2ctl -S      # VirtualHost の解決結果
```
