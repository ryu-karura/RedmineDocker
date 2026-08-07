# アップグレード検証手順 — Redmine 5.1.6 + MySQL 8.0 → PostgreSQL 18 → Redmine 7.0.0

このドキュメントは、**既存の Redmine 5.1.6 (MySQL 8.0 CE) を、このリポジトリの標準構成
である Redmine 7.0.0 + PostgreSQL 18 + PostGIS 3.6 へ移行する**ための手順書です。

移行を 3 段階に分け、各段階を単独で検証・切り戻しできるようにしています。

| 段階 | 内容 | 使うもの |
|------|------|----------|
| 1 | 移行元 (as-is) をコンテナで再現する | `compose.legacy.yaml` + `containers/redmine-web/Containerfile.v5-mysql` + `containers/redmine-db-mysql/` |
| 2 | DB を MySQL 8.0 → PostgreSQL 18 + PostGIS へコンバートする | `scripts/migrate-mysql-to-postgres.sh` + `scripts/pgloader/` |
| 3 | Redmine 5.1.6 → 7.0.0 へアップグレードする | `compose.dev.yaml`（`Containerfile.v7`） |

通しの自動検証は `bash scripts/test-upgrade.sh` です（段階 1〜3 を実データ入りで流し、
各段の結果を検査します）。

> **注意**: 本番 (Quadlet) 構成には MySQL 版のユニットはありません。移行元の再現は
> 開発 / リハーサル用の Compose のみで行います。移行完了後の本番構成はこれまでどおり
> PostgreSQL 18 + PostGIS 3.6 です（`docs/Setup.md`）。

---

## 0. 全体像

```
【段階 1】移行元の再現                    【段階 2】DB コンバート          【段階 3】アップグレード

 redmine-legacy-web (5.1.6)                                              redmine-web (7.0.0)
   plugins x10                                                            plugins x12
        │ mysql2                                                               │ postgis
        ▼                                                                      ▼
 redmine-legacy-db  ──── pgloader (data only) ────►  redmine-db (PostgreSQL 18 + PostGIS 3.6)
 (MySQL 8.0 CE)             ▲                              ▲
                            │                              │
                     ① 空 DB に 5.1.6 のまま          ② 5.1.6 のまま起動して確認
                       rake db:migrate でスキーマ作成    → banner を外す
                                                        → 7.0.0 イメージへ差し替え
                                                          （起動時に 5.1→7.0 の
                                                            マイグレーションが走る）
```

**方式の要点 — 「スキーマは Rails、データは pgloader」**

pgloader にスキーマ生成まで任せると、MySQL の型からの機械変換になり、
`id` 列が `serial` にならない・`tinyint(1)` が `boolean` にならない、といった
「Rails から見ると壊れているスキーマ」ができます。そのままだと段階 3 の
マイグレーションで破綻します。

そこで移行先には、**移行元とまったく同じ Redmine 5.1.6・同じプラグイン構成で
`rake db:migrate` を流して**スキーマを作らせ、pgloader には
`data only` でデータだけを流し込ませます。両者は同じマイグレーション列で作られる
ため、テーブル・列・列順まで一致します。

---

## 1. 前提と準備

### 1.1 必要なもの

- Docker Compose もしくは Podman（`docker` エミュレーション）が動く環境
- 移行元 Redmine の **mysqldump**（実データで検証する場合。無くてもテスト用データで手順確認は可能）
- ディスク空き: イメージ 3 種 + DB 2 種で 10 GB 程度

### 1.2 シークレット生成

```bash
bash scripts/generate-secrets.sh
```

生成されるファイル:

| ファイル | 用途 |
|----------|------|
| `secrets/db_password.txt` | Redmine 用 DB ユーザーのパスワード（MySQL / PostgreSQL 共通） |
| `secrets/secret_key_base.txt` | Rails の `secret_key_base` |
| `secrets/db_root_password.txt` | **MySQL の root パスワード（この移行手順専用）** |

> `db_root_password.txt` は、コンバート時に pgloader 用の一時ユーザーを作るために使います
> （理由は「9. 既知の落とし穴」）。通常の PostgreSQL 構成では使いません。

---

## 2. 段階 1 — 移行元 (Redmine 5.1.6 + MySQL 8.0 CE) の再現

```bash
docker compose -f compose.legacy.yaml up --build -d
docker compose -f compose.legacy.yaml logs -f redmine-legacy-web
# http://localhost:8081/redmine/   (初期ログイン: admin / admin)
```

初回ビルドはプラグインの gem 解決を含むため 10〜20 分程度かかります。

| コンテナ | イメージ | 役割 | 公開 |
|----------|----------|------|------|
| `redmine-legacy-db` | `mysql:8.0` + `containers/redmine-db-mysql/` | MySQL 8.0 CE | 非公開（同一ネットワークのみ） |
| `redmine-legacy-web` | `redmine:5.1.6` + `Containerfile.v5-mysql` | Redmine 5.1.6 + Apache + Puma | `127.0.0.1:8081` |

通常の開発スタック（`compose.dev.yaml`、`:8080`）とは、コンテナ名・ネットワーク・
ボリューム・ポートがすべて別なので同時起動できます。段階 2 では実際に両方を起動します。

### 2.1 プラグイン構成（16 個）と、除外したもの

`Containerfile.v5` の 11 個から `redmine_gtt` を除いた 10 個に、実際の移行元環境
（本番相当）のプラグイン構成に合わせて 6 個を追加したものです。

| # | プラグイン | バージョン |
|---|-----------|-----------|
| 1 | redmine_wiki_lists | 0.0.11 |
| 2 | redmine_banner | 0.3.5 |
| 3 | redmine_issues_panel | v1.0.4 |
| 4 | redmica_ui_extension | v0.3.10 |
| 5 | redmine_ip_filter | v1.1.0 |
| 6 | redmine_message_customize | v1.0.1 |
| 7 | redmine_issue_templates | master (1.2.2) |
| 8 | view_customize | v3.6.0 |
| 9 | redmine_logs | 0.3.0 |
| 10 | redmine_wiki_extensions | 0.9.5 |
| 11 | redmine_xlsx_format_issue_exporter | 0.2.1 |
| 12 | redmine_issue_assign_notice | v2.2.1 |
| 13 | redmine_theme_changer | 0.6.0 |
| 14 | redmine_absolute_dates | 0.0.4 |
| 15 | redmine_vividtone_my_page_blocks | 1.3 |
| 16 | redmine_hide_sidebar | master（タグ無し） |

**未対応のため除外したプラグイン**

| プラグイン | 除外理由 |
|-----------|---------|
| `redmine_gtt` | **PostGIS 必須**。geometry 型と PostGIS 関数を使うため MySQL では動作しません。DB を PostgreSQL へ移したあと、段階 3 の Redmine 7 イメージで導入されます。 |
| `redmine_login_audit2` | 全リリースが `requires_redmine 6.0.0` を宣言しており、5.1 対応版がありません。 |
| `redmine_solid_queue` | 依存する `solid_queue` gem が activerecord >= 7.1 を要求します（Redmine 5.1 は Rails 6.1）。 |

`redmine_gtt` を外したことで、このイメージには `libgeos-dev` / `libproj-dev` /
yarn / webpack も不要になっています（`Containerfile.v5` との差分）。

> このイメージは `REDMINE_WEB_SERVER=puma` 専用です（`mod_passenger` 非同梱）。
> 理由は `Containerfile.v5-mysql` のヘッダコメントを参照してください。

### 2.2 実データ（既存環境の mysqldump）を入れる場合

テスト用データではなく実データで検証する場合は、空の状態で起動した直後に投入します。

```bash
# 1. 移行元スタックを起動し、初回マイグレーション完了を待つ
docker compose -f compose.legacy.yaml up --build -d
docker compose -f compose.legacy.yaml logs -f redmine-legacy-web   # "Starting Puma" まで待つ

# 2. Redmine を止める（DB だけ動かしておく）
docker compose -f compose.legacy.yaml stop redmine-legacy-web

# 3. ダンプを投入（DB は作り直す）
DBPW="$(cat secrets/db_root_password.txt)"
docker exec -i -e MYSQL_PWD="$DBPW" redmine-legacy-db \
    mysql -u root -e 'DROP DATABASE IF EXISTS redmine; CREATE DATABASE redmine CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;'
docker exec -i -e MYSQL_PWD="$DBPW" redmine-legacy-db \
    mysql -u root redmine < /path/to/redmine_backup.sql

# 4. 添付ファイルをボリュームへ展開
docker run --rm -v redmine_legacy_web_files:/to -v /path/to/files:/from:ro \
    --entrypoint /bin/bash localhost/redmine-web:5.1.6-mysql \
    -c 'cp -a /from/. /to/ && chown -R redmine:redmine /to'

# 5. Redmine を起動（不足しているマイグレーションがあれば適用されます）
docker compose -f compose.legacy.yaml start redmine-legacy-web
```

> **重要**: 実データの Redmine に、上の 16 個以外のプラグインが入っていた場合、その
> プラグインのテーブルが移行先に存在せずコンバートが失敗します。
> `scripts/migrate-mysql-to-postgres.sh` の `schema` ステップがこれを検出して止めるので、
> 検出されたら「そのプラグインを `Containerfile.v5-mysql` に追加して再ビルドする」か
> 「移行元でアンインストールする」かを選んでください。

### 2.3 文字コードの事前確認（重要）

移行元が `latin1` や 3 バイトの `utf8` の場合、pgloader が不正なバイト列で失敗します。
コンバート前に MySQL 側で utf8mb4 に揃えておいてください。

```bash
docker exec -e MYSQL_PWD="$(cat secrets/db_password.txt)" redmine-legacy-db \
    mysql -u redmine -D redmine -e "
      SELECT table_name, table_collation
      FROM information_schema.tables
      WHERE table_schema = 'redmine' AND table_collation NOT LIKE 'utf8mb4%';"
# 出力があれば ALTER TABLE <name> CONVERT TO CHARACTER SET utf8mb4; を実行
```

---

## 3. 段階 2 — MySQL 8.0 → PostgreSQL 18 コンバート

### 3.1 実行

```bash
# 移行先 DB（PostgreSQL 18 + PostGIS 3.6）だけを起動する
docker compose -f compose.dev.yaml up --build -d redmine-db

# 移行元スタックも起動したまま、コンバートを実行する
bash scripts/migrate-mysql-to-postgres.sh
#   → 破壊的操作なので MIGRATE の入力を求められます（--yes で省略可）
```

移行先 Web (`redmine-web`) は**起動しないでください**。マイグレーションが競合します。

### 3.2 ステップの内訳

`--steps` で個別に実行できます（既定は全部）。

| ステップ | 内容 |
|----------|------|
| `preflight` | 両コンテナの稼働・接続・移行元が Redmine の DB であることを確認 |
| `schema` | 移行元と同じ 5.1.6 イメージを `REDMINE_DB_ADAPTER=postgresql` / `REDMINE_MIGRATE_ONLY=1` で単発起動し、空の PostgreSQL に Rails スキーマを作る。作成後、**移行元の全テーブルが移行先に存在するか**を突き合わせる |
| `data` | pgloader を `data only, truncate` で実行し、データだけを転送する |
| `sequences` | `serial` 列のシーケンスを `max(id)` に合わせ直す |
| `files` | 添付ファイルのボリュームを移行先ボリュームへコピーする |
| `verify` | テーブルごとの件数一致・シーケンス・`boolean` 型・`schema_migrations` 件数を検証する |

```bash
# 例: 検証だけやり直す
bash scripts/migrate-mysql-to-postgres.sh --steps verify
```

### 3.3 pgloader の設定（何を変換しているか）

`scripts/pgloader/redmine-data-only.load.tmpl` の要点:

| 設定 | 意味 |
|------|------|
| `WITH data only, truncate` | スキーマは作らせない。投入前に対象テーブルを truncate する |
| `CAST type tinyint when (= 1 precision) to boolean` | MySQL の `tinyint(1)`（Rails の boolean 表現）を PostgreSQL の `boolean` へ |
| `CAST type datetime to timestamp using zero-dates-to-null` | `0000-00-00 00:00:00` は PostgreSQL に存在しないため NULL に落とす |
| `EXCLUDING TABLE NAMES MATCHING 'schema_migrations', 'ar_internal_metadata'` | 移行先は `rake db:migrate` が作った正しい内容を保持する |
| `ALTER SCHEMA '<db>' RENAME TO 'public'` | MySQL のデータベース名を PostgreSQL の `public` スキーマへ対応づける |

### 3.4 手動で同じことをする場合

スクリプトを使わない場合の等価な手順です（トラブル時の切り分け用）。

```bash
# ① スキーマ作成（移行元と同じ 5.1.6 イメージ、Web は起動しない）
docker run --rm --network redmine-net \
  -v "$PWD/secrets:/run/secrets:ro" \
  -e REDMINE_DB_ADAPTER=postgresql -e REDMINE_DB_HOST=redmine-db \
  -e REDMINE_DB_NAME=redmine -e REDMINE_DB_USER=redmine \
  -e REDMINE_DB_PASSWORD_FILE=/run/secrets/db_password.txt \
  -e REDMINE_SECRET_KEY_BASE_FILE=/run/secrets/secret_key_base.txt \
  -e REDMINE_PLUGINS_MIGRATE=1 -e REDMINE_LOAD_DEFAULT_DATA=0 \
  -e REDMINE_MIGRATE_ONLY=1 \
  localhost/redmine-web:5.1.6-mysql

# ② pgloader 用の native password ユーザーを作る（理由は 9 章）
docker exec -e MYSQL_PWD="$(cat secrets/db_root_password.txt)" redmine-legacy-db \
  mysql -u root -e "CREATE USER IF NOT EXISTS 'redmine_pgloader'@'%'
      IDENTIFIED WITH mysql_native_password BY '$(cat secrets/db_password.txt)';
    GRANT SELECT, SHOW VIEW, LOCK TABLES ON redmine.* TO 'redmine_pgloader'@'%';"

# ③ pgloader を両ネットワークに接続して実行
#    （コマンドファイルは scripts/pgloader/redmine-data-only.load.tmpl を envsubst で描画）
docker create --name redmine-pgloader --network redmine-legacy-net \
  -v "$PWD/work:/work:ro" docker.io/dimitri/pgloader:v3.6.7 pgloader --verbose /work/redmine.load
docker network connect redmine-net redmine-pgloader
docker start -a redmine-pgloader && docker rm -f redmine-pgloader

# ④ シーケンス再設定
docker exec -i -e PGPASSWORD="$(cat secrets/db_password.txt)" redmine-db \
  psql -U redmine -d redmine -v ON_ERROR_STOP=1 -f - < scripts/pgloader/reset-sequences.sql

# ⑤ 添付ファイル
docker run --rm -v redmine_legacy_web_files:/from:ro -v redmine_web_files:/to \
  --entrypoint /bin/bash localhost/redmine-web:5.1.6-mysql \
  -c 'cp -a /from/. /to/ && chown -R redmine:redmine /to'
```

---

## 4. 段階 2 の確認 — 5.1.6 のまま PostgreSQL で動かす

Redmine 7 へ進む前に、**アプリのバージョンを変えないまま** DB だけが替わった状態を
確認します。ここで問題が出たら原因はコンバートにあります（アップグレードではない）。

```bash
docker run -d --name redmine-legacy-on-pg \
  --network redmine-net -p 127.0.0.1:8083:80 \
  -v "$PWD/secrets:/run/secrets:ro" \
  -e RAILS_ENV=production -e RAILS_RELATIVE_URL_ROOT=/redmine \
  -e REDMINE_DB_ADAPTER=postgresql -e REDMINE_DB_HOST=redmine-db \
  -e REDMINE_DB_NAME=redmine -e REDMINE_DB_USER=redmine \
  -e REDMINE_DB_PASSWORD_FILE=/run/secrets/db_password.txt \
  -e REDMINE_SECRET_KEY_BASE_FILE=/run/secrets/secret_key_base.txt \
  -e REDMINE_LOAD_DEFAULT_DATA=0 \
  localhost/redmine-web:5.1.6-mysql

# http://localhost:8083/redmine/ を開いて確認
```

確認項目:

- [ ] ログインできる（既存ユーザーのパスワードがそのまま使える）
- [ ] プロジェクト一覧・チケット一覧・チケット詳細が表示される
- [ ] 添付ファイルがダウンロードできる
- [ ] Wiki の日本語本文が文字化けしていない
- [ ] **新規チケットを作成できる**（= シーケンスが正しく再設定されている）
- [ ] プライベートチケットがプライベートのまま（= boolean 変換が正しい）

---

## 5. 段階 3 — Redmine 7.0.0 へのアップグレード

### 5.1 事前: Redmine 7 に無いプラグインをアンインストールする

`redmine_banner` は Redmine 7 イメージ (`Containerfile.v7`) に含まれません（master が
7.0 未対応で、対応は未マージのブランチにしかないため）。**プラグインを外す前に、
そのプラグインのマイグレーションを戻しておく必要があります。**
プラグイン本体が消えた後では戻せません。

```bash
# 上の redmine-legacy-on-pg コンテナ（5.1.6、プラグインを持っている）で実行する
docker exec redmine-legacy-on-pg \
  bundle exec rake redmine:plugins:migrate NAME=redmine_banner VERSION=0 RAILS_ENV=production

docker rm -f redmine-legacy-on-pg
```

### 5.2 バックアップ（切り戻し用）

```bash
docker exec -e PGPASSWORD="$(cat secrets/db_password.txt)" redmine-db \
  pg_dump -U redmine -F c -Z 6 redmine > redmine_before_v7.dump
```

### 5.3 Redmine 7 イメージで起動する

`.env` で系列を 7 に切り替えます（`REDMINE_VERSION` と `REDMINE_WEB_CONTAINERFILE` は
必ずセットで変更。`docs/Design.md`「Redmine シリーズの切り替え」参照）。

```ini
REDMINE_VERSION=7.0.0
REDMINE_WEB_CONTAINERFILE=Containerfile.v7
```

```bash
docker compose -f compose.dev.yaml up --build -d
docker compose -f compose.dev.yaml logs -f redmine-web
```

起動時に `entrypoint.sh` が以下を順に実行します。

1. `rake db:migrate` — Redmine 5.1 のスキーマから 7.0 までのコアマイグレーションを一括適用
   （Redmine は 001 以降の全マイグレーションを保持しているため、5.1 → 7.0 の直接適用が可能です）
2. `rake redmine:plugins:migrate` — プラグインのマイグレーション

データ量によっては数分〜数十分かかります。**途中で止めないでください。**

マイグレーションだけ先に流してからアプリを公開したい場合は、
`REDMINE_MIGRATE_ONLY=1` を付けて単発起動します（Web サーバーを起動せずに終了します）。

### 5.4 プラグイン構成の変化

| プラグイン | 5.1.6 (移行元) | 7.0.0 (移行先) | 備考 |
|-----------|:---:|:---:|------|
| redmine_wiki_lists | 0.0.11 | 0.0.11 | |
| redmine_banner | 0.3.5 | — | **7.0 未対応。事前にアンインストール（5.1 参照）** |
| redmine_issues_panel | v1.0.4 | v1.2.1 | |
| redmica_ui_extension | v0.3.10 | v0.6.0 | |
| redmine_ip_filter | v1.1.0 | v1.2.0 | |
| redmine_message_customize | v1.0.1 | v1.1.0 | |
| redmine_issue_templates | master | master | |
| view_customize | v3.6.0 | v3.6.0 | |
| redmine_logs | 0.3.0 | 0.4.0 | |
| redmine_wiki_extensions | 0.9.5 | 1.3.0 | |
| redmine_login_audit2 | — | 1.0.2 | 新規（5.1 では導入不可だった） |
| redmine_solid_queue | — | v1.0.0 | 新規（5.1 では導入不可だった） |
| redmine_gtt | — | v7.1.0 | 新規（PostGIS が必要なため MySQL 環境では不可だった） |

### 5.5 確認項目

- [ ] `docker compose -f compose.dev.yaml ps` で `redmine-web` が `healthy`
- [ ] `http://localhost:8080/redmine/` にログインできる
- [ ] 管理 → 情報 で Redmine 7.0.0、プラグイン 12 個が表示される
- [ ] チケット・Wiki・添付ファイル・ユーザーが移行前と同じ件数
- [ ] 新規チケットを作成できる
- [ ] `docker compose -f compose.dev.yaml logs redmine-web | grep -iE "LoadError|No route matches"` が空

---

## 6. 切り戻し

| 段階 | 切り戻し方 |
|------|-----------|
| 段階 3 の途中で失敗 | `docker compose -f compose.dev.yaml down` → `.env` を 5 系相当に戻す前に、5.3 で取った `redmine_before_v7.dump` を `scripts/restore.sh` 相当の手順でリストアし、`localhost/redmine-web:5.1.6-mysql` を PostgreSQL 向けに起動（4 章）して確認 |
| 段階 2 の途中で失敗 | 移行元 (MySQL) には一切書き込んでいないため、移行先の DB を捨てて (`docker compose -f compose.dev.yaml down -v`) やり直す |
| 全体を中止 | 移行元スタックはそのまま動いています（`:8081`）。移行先を `down -v` で破棄するだけです |

移行元 MySQL に対しては、pgloader 用の一時ユーザー作成以外の書き込みを行いません
（その一時ユーザーもコンバート後に削除されます）。

---

## 7. 一括検証

```bash
bash scripts/test-upgrade.sh              # 段階 1〜3 を通しで実行し検査する
bash scripts/test-upgrade.sh --keep       # 片付けずに残す（調査用）
bash scripts/test-upgrade.sh --skip-build # 既存イメージを再利用
```

専用のプロジェクト名・DB 名・ボリューム・ポート（8081 / 8082 / 8083）を使うため、
通常の開発スタックや `scripts/test-stack.sh` とは干渉しません。

検査する内容:

1. 移行元スタックが起動し、Redmine 5.1.6 / プラグイン 16 個 / mysql2 アダプタで動く
2. 検証データ（日本語・boolean を含む）を投入できる
3. コンバートが成功し、件数・シーケンス・boolean 型が一致する
4. コンバート後の DB で 5.1.6 が起動し、データが見え、新規チケットを作成できる
5. `redmine_banner` をアンインストールできる
6. Redmine 7.0.0 が起動し、マイグレーションが完了し、データが保持されている

---

## 8. `.env` / 環境変数の対応表（この手順で使うもの）

| 変数 | 既定 | 意味 |
|------|------|------|
| `REDMINE_DB_ADAPTER` | `postgis` | `postgis`（6/7 系の通常構成） / `postgresql`（コンバート時の 5.1.6） / `mysql2`（移行元） |
| `REDMINE_MIGRATE_ONLY` | 未設定 | 設定するとマイグレーションだけ実行して終了（Web サーバーを起動しない） |
| `REDMINE_LEGACY_WEB_HOST_PORT` | `8081` | 移行元 Redmine の公開ポート |
| `REDMINE_LEGACY_DB_CONTAINER` | `redmine-legacy-db` | 移行元 MySQL のコンテナ名 |
| `REDMINE_LEGACY_NETWORK` | `redmine-legacy-net` | 移行元スタックのネットワーク |
| `REDMINE_LEGACY_FILES_VOLUME` | `redmine_legacy_web_files` | 移行元の添付ファイルボリューム |
| `PGLOADER_IMAGE` | `docker.io/dimitri/pgloader:v3.6.7` | pgloader のイメージ |
| `SKIP_ENV_FILE` | `0` | `1` にすると `migrate-mysql-to-postgres.sh` が `.env` を読まない（呼び出し側の値を優先） |

---

## 9. 既知の落とし穴

### 9.1 pgloader は MySQL 8 の `caching_sha2_password` を話せない

pgloader 3.6.7 の MySQL ドライバは `mysql_native_password` にしか対応していません。
MySQL 8.0 の既定認証は `caching_sha2_password` なので、そのままだと
`Unsupported authentication method caching_sha2_password` で失敗します。

対策として、
- `containers/redmine-db-mysql/redmine.cnf` で `default_authentication_plugin = mysql_native_password` を指定
- `scripts/migrate-mysql-to-postgres.sh` が pgloader 実行前に、native password の
  一時ユーザー `redmine_pgloader`（SELECT 権限のみ）を作り、終了時に削除

の 2 段構えにしています。**移行元が MySQL 8.4 以降の場合**、`mysql_native_password` は
既定で無効なプラガブル認証になっているため、この手が使えません。その場合は
一時的にプラグインを有効化するか、pgloader を経由しない方式（`yaml_db` などの
Rails 経由ダンプ）を検討してください。

### 9.2 `tinyint(1)` → `boolean` は明示変換が必要

Rails は MySQL で boolean を `tinyint(1)` として保存します。CAST 規則を書かないと
pgloader は `smallint` として扱います。`verify` ステップで `issues.is_private` の型を
確認しているのはこの回帰検知のためです。

### 9.3 シーケンスを直さないと「移行直後の 1 件目」で落ちる

pgloader は `id` の値をそのまま COPY しますが、シーケンスは 1 のままです。
`scripts/pgloader/reset-sequences.sql` で `setval` し直さないと、移行後に最初の
レコードを作った瞬間に `duplicate key value violates unique constraint` になります。

### 9.4 移行元のプラグイン構成が違うとコンバートできない

移行先スキーマは「このイメージが持つ 10 プラグイン」で作られます。移行元にそれ以外の
プラグインが入っていると、そのテーブルの投入先が無く pgloader が失敗します。
`schema` ステップがテーブル集合を突き合わせて事前に検出します（2.2 参照）。

### 9.5 Gemfile と `config/database.yml` の関係（イメージを触るとき）

Redmine の `Gemfile` は `config/database.yml` に現れる `adapter:` 行を集め、その集合に
応じて DB gem（`mysql2` + `with_advisory_lock` / `pg`）を宣言します。
つまり **`database.yml` の中身が変わると bundle の内容が変わります。**

`Containerfile.v5-mysql` は、ビルド時に両アダプタを書いたダミー `database.yml` を置いて
`bundle install` し、実行時テンプレート（`database.mysql2.yml.tmpl` /
`database.postgresql.yml.tmpl`）にも常に両アダプタを含めています。これでビルド時と
実行時の gem 集合が一致し、実行時に bundler が解決をやり直して（= ネットワークを要求して）
失敗することがなくなります。テンプレート末尾の `gem_pin_*` スタンザはこのための
ダミーで、接続には使いません。**消さないでください。**

### 9.6 文字コード

移行元が `latin1` / 3 バイト `utf8` のままだと pgloader が不正バイト列で止まります。
コンバート前に utf8mb4 へ揃えてください（2.3 参照）。

### 9.7 添付ファイルの uid

添付ファイルのコピー後、`redmine` ユーザー所有へ `chown` しています。公式 Redmine
イメージの `redmine` uid は系列間で共通ですが、独自ビルドのイメージを混ぜる場合は
移行先イメージで `chown -R redmine:redmine /usr/src/redmine/files` を実行してください。

### 9.8 MySQL 8.0 は EOL 済み

`mysql:8.0` は 2026-04 に EOL を迎えています。移行元 (as-is) の再現用途に限定し、
常用の DB として運用しないでください。移行の目的地は PostgreSQL 18 + PostGIS 3.6 です。

---

## 10. 検証状況（重要）

このリポジトリに入っている移行元イメージ・コンバートスクリプト・本手順は、
**まだ実機で通しの動作確認をしていません。**作成環境からコンテナレジストリ
（Docker Hub の blob 配信ホスト）へ到達できず、ベースイメージを取得できなかったためです。

実施済み:

- `shellcheck` によるシェルスクリプトの静的検査
- `docker compose -f compose.legacy.yaml config` / `compose.dev.yaml config` の構文検証
- 上流ソースの確認（Redmine 5.1.6 / 6.1.3 / 7.0.0 の `Gemfile` の DB gem 解決ロジック、
  公式 redmine イメージの `Dockerfile.template` がダミー `database.yml` で全アダプタを
  事前インストールしている実装、`redmine:5.1.6` タグの存在、`mysql:8.0` の `*_FILE` 対応、
  Redmine 7.0.0 が `db/migrate/001_setup.rb` から全マイグレーションを保持していること）

未実施（実機で必ず行ってください）:

- イメージのビルド（`compose.legacy.yaml build`、Redmine 7 イメージ）
- 段階 1〜3 の通し実行 → **`bash scripts/test-upgrade.sh`**
- 実データ（本番相当のサイズ・文字コード）でのコンバート時間とエラーの確認

特に次の 3 点は環境差が出やすいため、最初の実行時にログを確認してください。

1. pgloader と MySQL 8.0 の認証（9.1）
2. `bundle install` 時の DB gem 解決（9.5。ビルド時に 3 つの gem を検証しています）
3. Redmine 5.1 → 7.0 のコアマイグレーション所要時間

## 11. 関連ドキュメント

- `docs/Setup.md` — 移行後の標準構成（開発 / 本番）の導入手順
- `docs/Design.md` — アーキテクチャ、`.env` の設計、Redmine シリーズの切り替え
- `docs/Manual.md` — 日常運用（バックアップ・リストア・更新手順）
- `CLAUDE.md` — リポジトリ全体の約束事（AI アシスタント向け）
