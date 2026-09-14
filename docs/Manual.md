# 運用手順 — RedmineDocker (redmine スタック)

本番環境（Docker Engine + systemd）における日常運用手順です。パスはリポジトリが `/opt/redmine/containers`、データが `/opt/redmine/data` にある前提です（`REDMINE_DATA_ROOT` / `REDMINE_DATA_DIR` を `.env` で変更している場合はそのパスに読み替えてください）。次の「コマンド集」章のみ、開発環境 (`compose.dev.yaml` 単体) のコマンドも併記しています。

本番のコンテナは **`compose.dev.yaml` + `compose.prod.yaml` の 2 枚重ね**で定義し、起動・停止は systemd ユニット `redmine.service` が行います。本書では次のエイリアスを使っているものとして読んでください（`~/.bashrc` などに入れておくと便利です）。

```bash
alias dcp='sudo docker compose -f /opt/redmine/containers/compose.dev.yaml -f /opt/redmine/containers/compose.prod.yaml'
```

コンテナ名・DB 名・ユーザー名・データルートなどの設定値は、開発・本番とも `.env` 1 ファイルに集約されています。一覧は `docs/Design.md` の「設定パラメータ (.env)」章を参照してください。

---

## コマンド集（Docker が初めての方へ）

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
docker ps                                          # 同じ内容を docker 単体で確認
docker compose -f compose.dev.yaml logs -f redmine-web       # ログをリアルタイム追跡（Ctrl+C で終了）
docker compose -f compose.dev.yaml logs --tail 100 redmine-db  # 直近100行だけ表示
```

#### イメージの削除

```bash
docker images                                      # イメージ一覧（サイズ・作成日時を確認）
docker rmi localhost/redmine-web:7.0.1             # 特定のイメージを削除（DB・添付ファイルには影響しません）
docker compose -f compose.dev.yaml down --rmi all  # このスタックのイメージをまとめて削除（ボリュームは残る）
docker image prune                                 # どのコンテナからも参照されていないイメージだけ安全に削除
```

`docker rmi` はそのイメージを使っているコンテナが実行中だと失敗します。先に `docker compose -f compose.dev.yaml down`（`-v` は付けない）でコンテナを止めてから実行してください。

#### ⚠️ 本当に DB・添付ファイルごと消したいとき（開発環境のリセット）

```bash
docker compose -f compose.dev.yaml down -v   # 名前付きボリューム (pgdata, redmine_files) ごと削除
```

`-v` を付けたときだけデータが消えます。動作確認用の使い捨て環境をまっさらに戻したいとき以外は付けないでください。

### 本番環境 (Docker Engine + systemd)

起動・停止・確認・ログは「サービス制御」章、再ビルドは「更新」章を参照してください（どちらも `/opt/redmine/data` の bind mount とは別物を操作するだけなので、DB・添付ファイルは消えません）。

#### イメージの削除

```bash
sudo docker images
sudo docker rmi localhost/redmine-web:7.0.1   # サービスを停止していないと失敗します（先に sudo systemctl stop redmine）
sudo docker image prune                        # 未使用イメージだけ安全に削除
```

#### ⚠️ 本当に DB・添付ファイルごと消したいとき

`/opt/redmine/data/` を直接削除する以外に方法はありません。**バックアップ（下記「バックアップ」章）を取ってから、内容をよく確認して実行してください。** 通常の運用でここに触れる必要はありません。

---

## サービス制御

スタック全体（redmine-db + redmine-web）は systemd ユニット 1 つで操作します。root 権限が必要です。

```bash
sudo systemctl start   redmine     # docker compose ... up -d --wait（healthy になるまで待つ）
sudo systemctl stop    redmine     # docker compose ... down
sudo systemctl restart redmine
sudo systemctl reload  redmine     # .env やイメージの変更を反映（up -d --wait）
systemctl status redmine
journalctl -u redmine -f           # ユニット自身（compose コマンド）のログ
```

起動・停止順序は compose の `depends_on: {redmine-db: {condition: service_healthy}}` が保証します（`redmine-db` → `redmine-web`、停止は逆順）。

コンテナ単位の操作・ログは compose で行います（`dcp` は冒頭のエイリアス）。

```bash
dcp ps                       # 各コンテナの状態とヘルス
dcp logs -f redmine-web      # アプリケーションログを追跡
dcp restart redmine-web      # web だけ再起動（systemd ユニットはそのまま）
```

---

## 日常確認（まず最初に見る項目）

### 本番 (Docker + systemd)

```bash
systemctl status redmine
dcp ps
sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"   # STATUS 列に (healthy) が出ます
sudo docker exec redmine-web /usr/local/bin/redmine-healthcheck.sh      # ヘルスチェックを手動実行
dcp logs --tail 200 redmine-web
```

### Docker Compose (開発)

```bash
docker compose -f compose.dev.yaml ps
docker compose -f compose.dev.yaml logs -f redmine-web
docker compose -f compose.dev.yaml top
```

---

## イメージビルド手順

### 本番 (Docker)

```bash
cd /opt/redmine/containers
dcp build                      # compose の build 定義（.env のタグ/ベースイメージ）でビルド
sudo docker images | grep -E 'redmine-(db|web)'
```

compose を介さずビルドする場合は次と同じです。

```bash
cd /opt/redmine/containers
set -a; source .env; set +a
sudo docker build -t "${REDMINE_DB_IMAGE}" \
    --build-arg DB_BASE_IMAGE="${REDMINE_DB_BASE_IMAGE}" containers/redmine-db
sudo docker build -t "${REDMINE_WEB_IMAGE}" \
    -f "containers/redmine-web/${REDMINE_WEB_CONTAINERFILE}" \
    --build-arg WEB_BASE_IMAGE="${REDMINE_WEB_BASE_IMAGE}" containers/redmine-web
```

`REDMINE_WEB_CONTAINERFILE` は Redmine の系列に対応します
（`Containerfile.v5` / `Containerfile.v6` / `Containerfile.v7`（既定））。

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

手順 (本番: Docker + systemd):

```bash
cd /opt/redmine/containers
# 1) 必要なら .env/Containerfile を更新
dcp build redmine-web         # 変更を反映してビルド
sudo systemctl reload redmine # up -d --wait で差分だけ作り直し、healthy を待つ
```

手順 (開発: Docker Compose):

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
dcp build

# 3) サービス再起動
sudo systemctl restart redmine

# 4) 必要なら restore（互換性問題が出た場合）
# bash /opt/redmine/containers/scripts/restore.sh <db_dump> <files_archive>
```

注意:
- メジャーアップデートは DB 内部フォーマット変更を伴う可能性があるため、事前バックアップを必須にしてください。
- 既存データを使っての移行（migrate）で進めるか、復元ベースで作り直すかは、ダウンタイム要件と検証結果で決めます。

### ケース B-2: 別 DB 製品からの移行 / Redmine メジャーバージョンのアップグレード

対象: 既存の **Redmine 5.1.1 + MySQL 8.0 CE** をこの構成（PostgreSQL 18 + PostGIS 3.6）へ
移し、さらに Redmine 7.0.1 へ上げる場合。

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

本番で全削除:

```bash
sudo systemctl stop redmine
# 本番データ削除は非常に危険。必ず backup 実施後に行う。
sudo rm -rf /opt/redmine/data/postgres/18/*
sudo rm -rf /opt/redmine/data/redmine/files/*
sudo rm -rf /opt/redmine/data/redmine/log/*
sudo chown -R 999:999 /opt/redmine/data/redmine   # 消した後も所有者を戻しておく
sudo systemctl start redmine
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

対象: `REDMINE_WEB_SERVER` を `passenger`（7 系の既定: Apache + mod_passenger が
Redmine を直接起動、:3000 なし）と `puma`（Apache → ProxyPass → Puma :3000。
5 系 / 6 系の既定）で切り替える場合。
イメージには両方式が同梱されているため **再ビルドは不要** で、コンテナ再起動のみで反映されます。

開発 (Compose):

```bash
# .env の REDMINE_WEB_SERVER を passenger / puma に変更してから
docker compose -f compose.dev.yaml up -d --force-recreate redmine-web
docker compose -f compose.dev.yaml logs -f redmine-web
```

本番 (Docker + systemd):

```bash
# /opt/redmine/containers/.env の REDMINE_WEB_SERVER を変更してから
# （7 系イメージの既定は passenger。.env に書けば上書きできます）
sudo systemctl reload redmine
dcp logs -f redmine-web
```

切り替え後の確認:

```bash
sudo docker exec redmine-web apache2ctl -M | grep passenger   # passenger のときだけ passenger_module が出る
sudo docker exec redmine-web passenger-status                 # passenger のときのみ成功（アプリのプロセス一覧）
sudo docker exec redmine-web curl -sf http://127.0.0.1:3000/redmine/login >/dev/null \
  && echo "puma listening" || echo "no puma (passenger mode)"
sudo docker exec redmine-web /usr/local/bin/redmine-healthcheck.sh   # どちらのモードでも 0 で終了すること
```

ヘルスチェックはイメージ内の `/usr/local/bin/redmine-healthcheck.sh` が担当し、
モードに応じて Puma 直叩きの検証を自動で省きます。

なお **mod_passenger は 3 系列とも Debian trixie の 6.0.26** です（Ruby 4.0 の 7 系でも
同じ版で動作することを確認済みで、7 系ではこれを既定にしています。根拠は
`docs/Design.md`「9. Redmine シリーズの切り替え」）。
稼働中のバージョンは次で確認できます。

```bash
sudo docker exec redmine-web dpkg-query -W -f='${Version}\n' libapache2-mod-passenger
```

7 系を本番へ出す前に
`bash scripts/test-stack.sh --series 7` で実測してください（`--web-server` を省くと
そのシリーズの既定 = 7 系なら passenger で検証します。このテストは稼働中コンテナの
`libapache2-mod-passenger` が 6.0.25 以上であることも検証します）。

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

# 1) .env を 2 つセットで変更（例: 既定の 7 系から 6 系へ下げる）
#      REDMINE_VERSION=6.1.4
#      REDMINE_WEB_CONTAINERFILE=Containerfile.v6
#    ※ 6 系 → 7 系へ上げる場合は .env から 2 行を消して既定に戻すだけでも構いません

# 2) 再ビルドして再作成
docker compose -f compose.dev.yaml up --build -d
docker compose -f compose.dev.yaml logs -f redmine-web   # マイグレーションの進行を確認
```

本番 (Docker + systemd):

```bash
# 0) 事前バックアップ
sudo bash /opt/redmine/containers/scripts/backup.sh

# 1) .env を 2 つセットで変更（REDMINE_VERSION / REDMINE_WEB_CONTAINERFILE）
#    ユニット側の差し替えは不要です。系列の指定は .env だけで完結します。

# 2) 再ビルドして再作成
cd /opt/redmine/containers
dcp build
sudo systemctl restart redmine
systemctl status redmine
```

切り替え後の確認:

```bash
sudo docker exec redmine-web cat /usr/src/redmine/lib/redmine/version.rb | head -8   # 本体バージョン
sudo docker exec redmine-web ls /usr/src/redmine/plugins                             # 同梱プラグイン
sudo docker exec redmine-web /usr/local/bin/redmine-healthcheck.sh
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
dcp build redmine-web
sudo systemctl reload redmine     # entrypoint でマイグレーションを再実行
```

マイグレーションを実行せずに起動したい場合（アップグレード前の DB 確認など）は、
公式イメージと同じく `REDMINE_NO_DB_MIGRATE` に値を設定します
（`.env` に `REDMINE_NO_DB_MIGRATE=1` と書き、`sudo systemctl reload redmine`）。
値を空にする / 行を消すと再びコアの `db:migrate` を実行します。

### Apache フロントエンド
`redmine-web` イメージに Apache の設定を入れたため、個別の `redmine-static` イメージは不要です。変更後は Redmine イメージを再ビルドして再起動します。設定は
`containers/redmine-web/httpd-redmine.conf.tmpl`（`puma` 用）と
`containers/redmine-web/httpd-redmine-passenger.conf.tmpl`（`passenger` 用）の
テンプレートから `entrypoint.sh` が起動時に描画します。生成後の `.conf` ではなく
`.tmpl` を編集してください。

---

## バックアップ

`scripts/backup.sh` は `redmine` データベースのダンプ（pg_dump のカスタム形式）を作成し、`/opt/redmine/data/redmine/files` をアーカイブして `/opt/redmine/backup/` 配下に 7 世代保存します。DB パスワードは `secrets/db_password.txt` から読み取ります。DB 名・ユーザー名・コンテナ名・データルートは `/opt/redmine/containers/.env` があればそこから読み込みます（既定値は上記の通り。`docs/Design.md` 参照）。

docker デーモンを操作するため、root（または docker グループのユーザー）で実行します。

```bash
sudo bash /opt/redmine/containers/scripts/backup.sh
```

root の crontab で毎日 02:00 に実行するように設定できます（`sudo crontab -e` を実行）。

```cron
0 2 * * * /opt/redmine/containers/scripts/backup.sh >> /opt/redmine/backup/backup.log 2>&1
```

---

## 復元

`scripts/restore.sh` は `redmine` データベースを削除して再作成し、ダンプを復元してファイルアーカイブを展開します。**現在のデータは破壊されます**。`RESTORE` 確認プロンプトが表示されます。

```bash
sudo bash /opt/redmine/containers/scripts/restore.sh \
  /opt/redmine/backup/db/redmine_YYYYMMDD_HHMMSS.dump \
  /opt/redmine/backup/files/redmine_YYYYMMDD_HHMMSS.tar.gz
```

このスクリプトは `redmine-web` コンテナだけを停止し（`redmine-db` は DB 操作のため起動したまま、systemd ユニットも触りません）、DB（PostGIS 拡張込み）を再作成して `pg_restore` を実行し、ファイルを復元して `redmine-web` を再起動します。展開した添付ファイルの所有者は root 実行時に自動で `999:999`（コンテナ内 redmine）へ揃えます。

---

## ログ

| ログ | 配置先 |
|------|--------|
| Redmine アプリケーション（Rails ログ） | コンテナの標準出力 → `dcp logs redmine-web`（= `docker logs redmine-web`） |
| Apache フロントエンド（コンテナ） | 同上（`dcp logs redmine-web`） |
| systemd ユニット（compose コマンド自体） | `journalctl -u redmine` |
| ホスト Apache（TLS フロント） | `/var/log/httpd/redmine_{access,error}.log` |

★ **Rails ログはファイルではなく標準出力に出ます。** 公式 Redmine イメージが
`RAILS_LOG_TO_STDOUT=true` を設定しており、`config/environments/production.rb` は
この変数があるとロガーを STDOUT に差し替えるため、`log/production.log` は書かれません
（bind mount した `/opt/redmine/data/redmine/log` も通常は空のままです）。
ファイルに出したい場合は `.env` に `RAILS_LOG_TO_STDOUT=` （空）を設定してコンテナを
再作成してください。その場合はコンテナの標準出力側が空になります。

ログの保存期間は docker のログドライバ設定（`/etc/docker/daemon.json` の
`log-driver` / `log-opts`、既定は `json-file`）で制御します。例えば 1 ファイル 100MB・
3 世代で回すなら `{"log-driver":"json-file","log-opts":{"max-size":"100m","max-file":"3"}}`
を設定して `systemctl restart docker` します。

ログローテーションは `logrotate/redmine` で設定されています（`/etc/logrotate.d/redmine-web` に配置）。
日次・60 世代で、対象はホスト Apache のログと、上記のように**ファイル出力へ切り替えた場合の**
`production.log` です（未切り替えならファイルが無いだけで `missingok` により何もしません）。

```bash
sudo logrotate --debug /etc/logrotate.d/redmine-web     # ドライラン
```

---

## ヘルスチェックと診断

```bash
sudo docker exec redmine-web /usr/local/bin/redmine-healthcheck.sh
sudo docker exec -e PGPASSWORD="$(sudo cat /opt/redmine/containers/secrets/db_password.txt)" \
	redmine-db psql -U redmine -d redmine -c '\\dx'   # 拡張機能を表示（postgis を期待）
curl -sf http://127.0.0.1:80/redmine/login >/dev/null && echo OK
```

メンテナンス用の Rails コンソール:

```bash
sudo docker exec -it redmine-web bundle exec rails console -e production
```

### Passenger モード特有のトラブルシューティング

| 症状 | 原因と対処 |
|------|------------|
| どの URL も 404（ログに `No route matches [GET] "/login"`） | `config.ru` が Passenger 配下でも `map` してしまっています。`mod_passenger` は `PassengerBaseURI` で `PATH_INFO` からプレフィックスを除去済みのため、`map` を挟むとマッチしません。`containers/redmine-web/config.ru` の `defined?(PhusionPassenger)` 分岐が消えていないか確認してください。 |
| 添付ファイルのアップロードやログ出力が権限エラーになる | Passenger がアプリを `nobody` で起動しています。`config.ru` の所有者が `redmine` であること（`sudo docker exec redmine-web ls -l /usr/src/redmine/config.ru`）と、`redmine-passenger.conf` に `PassengerUser redmine` があることを確認してください。 |
| gem が見つからない / bundler エラーで起動しない | `PassengerRuby` が Debian のシステム Ruby (`/usr/bin/ruby`) を向いています。`redmine-passenger.conf` の `PassengerRuby /usr/local/bin/ruby` を確認してください。 |
| CSS/JS/テーマだけ 404 になる | Apache が `public/` を配信できていません。`redmine-passenger.conf` の `Alias` と `<Directory>` の `Require all granted` を確認してください。 |
| コンテナが起動直後に終了し、ログの最後が `/etc/apache2/envvars: line 7: APACHE_CONFDIR: unbound variable` | `entrypoint.sh` が `set -u` のまま `/etc/apache2/envvars` を `source` しています。`envvars` は `apache2ctl` が設定する `APACHE_CONFDIR` を未設定のまま参照するため、`source` の前後で `set +u` / `set -u` する実装（`docs/Design.md`「アプリサーバーの切り替え」参照）に戻っているか確認してください。 |
| Passenger 起動後にアプリが `invalid byte sequence in US-ASCII`（`Gemfile` の解析エラー）で落ちる | `/etc/apache2/envvars` の `LANG=C` がアプリまで継承されています。`entrypoint.sh` が `source` 後に `LANG`（`C.UTF-8`）を復元しているか確認してください。日本語コメントを含む `config/database.yml` を bundler が読めなくなるのが原因です。 |
| error log に native support のコンパイル警告が出る | 想定内です。Passenger は pure-Ruby 実装へフォールバックして動作を継続します（わずかに遅くなるのみ）。 |
| `scripts/test-stack.sh`（7 系の既定 = passenger）が `mod_passenger is 6.0.25+` で落ちる | ベースイメージの Debian が `libapache2-mod-passenger` を 6.0.25 より古い版へ戻しています（6.0.25 で Ruby 3.4 対応が入ったため下限にしています）。ベースイメージを更新して再ビルドし、それでも戻らない場合は `docs/Design.md`「9. Redmine シリーズの切り替え」の代替案（Phusion の APT リポジトリ / `puma` 専用運用）を検討してください。 |

現在有効な Apache 設定は次で確認できます:

```bash
sudo docker exec redmine-web ls -l /etc/apache2/conf-enabled/
sudo docker exec redmine-web apache2ctl -S      # VirtualHost の解決結果
```
