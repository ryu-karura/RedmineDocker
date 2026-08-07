# 設計書 — RedmineDocker (redmine スタック)

## 1. 概要

RedmineDocker は 2 つのコンテナが連携して Redmine 6.1.3 を動作させます。設計は [redmine.jp の Docker ガイド](https://blog.redmine.jp/articles/6_1/redmine-6_1-docker/) を踏襲しており、**公式** の `redmine` イメージを使い、認証情報は **ファイルベースのシークレット** で管理し、Compose / Quadlet の単一定義から運用するようにしています。Apache フロントエンドを `redmine-web` に統合し、この環境で求められる設定値に合わせています。

| 項目 | 値 |
|------|----|
| 本番 OS | RHEL 9.5 以上 |
| 開発 A / 本番相当確認 OS | WSL ディストリビューション `AlmaLinux 9.5 以上` |
| 開発 B OS | GitHub Codespaces（Ubuntu, devcontainer） |
| Linux 管理ユーザー | `redmine` |
| Linux ルートディレクトリ | `/opt/redmine` |
| Rootless Podman ネットワーク | `redmine-net` |
| Redmine イメージ | `docker.io/library/redmine:6.1.3` |
| PostgreSQL / PostGIS | `docker.io/postgis/postgis:18-3.6` |
| Apache フロントエンド | `httpd` 2.4（`redmine-web` に内蔵） |
| DB 名 / 所有者 | `redmine` / `redmine` |
| DB コンテナ | `redmine-db` |
| Redmine / Puma コンテナ | `redmine-web` |
| Web フロントコンテナ | `redmine-web` |
| アプリサーバー | `puma`（既定）または `passenger`（`REDMINE_WEB_SERVER`） |
| Puma 内部ポート | `3000`（ホスト公開なし。`passenger` では未使用） |
| PostgreSQL 内部ポート | `5432`（ホスト公開なし） |
| Web ホストポート | `127.0.0.1:80` |
| 公開 URL | `http://localhost/redmine/` |

## 2. トポロジー

`REDMINE_WEB_SERVER=puma`（既定）:

```
  client ──443──► Host Apache ──/redmine──► redmine-web (Apache 2.4 + Puma :3000, :80)
                                                    │ ProxyPass /redmine → 127.0.0.1:3000
                                                    ▼
                                             redmine-db (PostgreSQL 18 + PostGIS 3.6, :5432)
```

`REDMINE_WEB_SERVER=passenger`:

```
  client ──443──► Host Apache ──/redmine──► redmine-web (Apache 2.4 + mod_passenger, :80)
                                                    │ Passenger が Redmine を直接起動（:3000 なし）
                                                    ▼
                                             redmine-db (PostgreSQL 18 + PostGIS 3.6, :5432)
```

- `redmine-web` が `127.0.0.1:80` にバインドされます。ホスト側 Apache (`host-apache/redmine-proxy.conf`) が TLS を終端し、`/redmine` を転送します。ホスト側の設定はどちらのモードでも同じです。
- コンテナ内 Apache から先は `REDMINE_WEB_SERVER` で切り替わります。`puma` は `/redmine` を Puma (`:3000`) に `ProxyPass` し、静的資産も Rails (`RAILS_SERVE_STATIC_FILES`) が配信します。`passenger` は `mod_passenger` が Redmine を Apache の子プロセスとして直接起動し、静的資産は Apache が `public/` から配信します。
- PostgreSQL (5432) と Puma (3000) はホストには公開されません。
- コンテナは `redmine-net` ブリッジ上で通信し、`redmine-db` と `redmine-web` という名前で相互解決します。

## 3. コンテナの役割

### redmine-db (`containers/redmine-db/`)
- ベースイメージは `postgis/postgis:18-3.6` です。`POSTGRES_USER=redmine`、`POSTGRES_DB=redmine`、`POSTGRES_PASSWORD_FILE=/run/secrets/db_password` を設定します。
- 1 つの `redmine` ロールが `redmine` データベースを所有する（ブログの単一ユーザーモデル）構成です。`init-redmine.sh` は `postgis` / `postgis_topology` 拡張機能が存在することを確認します（冪等で、ベースイメージ側で初回初期化時に有効化済みです）。

### redmine-web (`containers/redmine-web/`)
- ベースイメージは `redmine:6.1.3`（公式、Ruby / Bundler / Puma / gem も含む）です。Redmine のメジャーバージョン系列ごとに Containerfile を分けており、既定は 6 系（`Containerfile.v6`）です。5 系 / 7 系については「9. Redmine シリーズの切り替え」を参照してください。
- 日本語 CJK フォント（PDF / Gantt 用）、13 プラグイン + `farend_fancy` テーマを追加します。プラグイン gem は `bundle install` でイメージに焼き込みます。`redmine_gtt` は 7.x でフロントエンドが webpack+yarn から Vite+pnpm へ移行したため、ビルド済み資産を同梱する公式リリース tarball を展開しています（6 系 / 7 系。Node ツールチェーンは不要）。5 系だけは webpack 時代の 6.0.3 を使うため yarn + webpack のビルドが残ります。
- Apache フロントエンドを組み込み、`127.0.0.1:80` で `/redmine` リクエストを受けます。その先の処理は `REDMINE_WEB_SERVER` で切り替わります（下記「アプリサーバーの切り替え」）。
- `entrypoint.sh` はシークレット解決（`*_FILE` 対応）、`config/database.yml` の描画（**`postgis`** アダプタ使用、redmine_gtt 必須）、`config/configuration.yml`（SMTP）の描画、Apache 設定の描画、DB 待機、コア / プラグインのマイグレーション実行、アプリサーバーの起動を行います。マイグレーションの実行可否は公式イメージと同じ環境変数で制御します（`REDMINE_NO_DB_MIGRATE` に値を設定するとコアの `db:migrate` をスキップ、`REDMINE_PLUGINS_MIGRATE` が非空なら `redmine:plugins:migrate` を実行。本スタックは 13 プラグインを内蔵するため既定で `REDMINE_PLUGINS_MIGRATE=1`）。

#### アプリサーバーの切り替え（`REDMINE_WEB_SERVER`）

イメージには Puma（公式イメージ同梱）と `mod_passenger` の **両方** が入っています。切り替えは環境変数の変更とコンテナ再起動のみで、イメージの再ビルドは不要です。

`mod_passenger` の入手元は系列で異なります。5 系 / 6 系（Ruby 3.x）は Debian trixie の `libapache2-mod-passenger`（Passenger 6.0.26）を使い、7 系（Ruby 4.0）だけは Passenger の Ruby 4 対応が 6.1.1 以降であるため forky (Debian 14 / testing) の 6.1.x を APT pin で導入します（下記「9. Redmine シリーズの切り替え」参照）。

| | `puma`（既定） | `passenger` |
|---|---|---|
| リクエスト処理 | Apache → `ProxyPass` → Puma `:3000` | Apache + `mod_passenger` が直接起動 |
| Apache 設定 | `httpd-redmine.conf.tmpl` → `redmine-proxy.conf` | `httpd-redmine-passenger.conf.tmpl` → `redmine-passenger.conf` |
| 静的資産 | Rails（`RAILS_SERVE_STATIC_FILES=1`） | Apache が `Alias` で `public/` を配信 |
| コンテナの PID 1 | `entrypoint.sh`（Apache 起動後 Puma を監視） | `apache2 -DFOREGROUND` |
| 実行ユーザー | `runuser -u redmine` で Puma | `PassengerUser redmine` |
| `:3000` | あり | なし |

`entrypoint.sh` が起動時にテンプレートを描画し、`a2enmod passenger` / `a2dismod -f passenger` と `a2enconf` / `a2disconf` で該当する設定だけを有効化します（どちらも `*:80` の VirtualHost を定義するため、同時に有効化はできません）。

実装上の注意点:

- `config.ru` は Passenger 配下では `map` を **行いません**。`mod_passenger` は `PassengerBaseURI` によって `SCRIPT_NAME` を `/redmine` に設定し、`PATH_INFO` からはプレフィックスを除去して渡すため、`Rack::URLMap`（`map`）を挟むと `/login` が `/redmine` にマッチせず全リクエストが 404 になります。`defined?(PhusionPassenger)` で判定して分岐しています。
- `PassengerRuby` は公式イメージの `/usr/local/bin/ruby` を指します（Debian パッケージの既定である `/usr/bin/ruby` には Redmine の gem が入っていません）。
- Passenger の native support 拡張はビルド時に用意していません。初回起動時に自動コンパイルが試みられ、失敗しても pure-Ruby 実装へフォールバックします（error log に警告が出るのみ）。


## 4. データと永続化

| ホスト上のパス（本番） | マウント先 | 内容 |
|------------------------|------------|------|
| `/opt/redmine/data/postgres/18` | redmine-db | PostgreSQL のデータディレクトリ |
| `/opt/redmine/data/redmine/files` | redmine-web | アップロードされた添付ファイル |
| `/opt/redmine/data/redmine/log` | redmine-web | Redmine の `production.log` |
| `/opt/redmine/backup/{db,files}` | host | バックアップ（Manual 参照） |

開発環境 (`compose.dev.yaml`) では、これらは名前付きボリューム (`pgdata`、`redmine_files`) になり、ホストの bind mount ではなくなります。プラグインとテーマはイメージに焼き込まれており、ボリュームマウントは行いません（ボリュームで上書きされるため）。

## 5. シークレット

ファイルとして保存される 2 つのシークレットで、プレーンな環境変数ではありません。

| シークレット | 利用先 | ソースファイル |
|--------------|--------|----------------|
| `db_password` | redmine-db, redmine-web | `secrets/db_password.txt` |
| `secret_key_base` | redmine-web | `secrets/secret_key_base.txt` |

`scripts/generate-secrets.sh` がファイルを作成します（mode 600、git ignore）。開発環境では Compose の `secrets:` で接続し、本番環境では `podman secret create` で登録して Quadlet の `Secret=` ディレクティブから参照し、`/run/secrets/<name>` にマウントします。

## 6. ユーザーと権限

- コンテナ内では公式イメージが持つユーザーをそのまま使用します: `redmine`（Redmine アプリ）と `postgres` / `redmine`（データベース）。独自の UID/GID リマップは行いません。これは、以前の rbenv ベースイメージよりも簡素化した設計です。
- ホスト側では `redmine` 管理ユーザーが `/opt/redmine` を所有します。rootless Podman ではコンテナユーザーが呼び出し元ユーザーのサブ UID 範囲にマップされ、ホストの bind mount 所有権は `:Z` SELinux relabel で管理します。

## 7. 補足 / 注意点

- Apache フロントエンドは `redmine-web` イメージに組み込まれ、個別の `redmine-static` イメージは不要になりました。
- 追加の Web プロキシコンテナを置かず、Redmine コンテナ内で Apache とアプリサーバーを運用しています。既定の `puma` モードでは、堅牢性を優先して Redmine 側でアセット配信を行っています（`passenger` モードでは Apache が `public/` を直接配信します）。

## 8. 設定パラメータ (.env)

非シークレット設定は `.env`（テンプレート: `.env.example`）で管理します。Compose は自動で `.env` を読み込み、運用スクリプト（`scripts/backup.sh` / `scripts/restore.sh`）も同じ値を参照します。

主なパラメータ:

| 用途 | 変数 | 既定値 |
|------|------|--------|
| Redmine バージョン | `REDMINE_VERSION` | `6.1.3` |
| Web の Containerfile | `REDMINE_WEB_CONTAINERFILE` | `Containerfile.v6` |
| PostgreSQL メジャー | `REDMINE_DB_PG_MAJOR` | `18` |
| PostGIS バージョン | `REDMINE_DB_POSTGIS_VERSION` | `3.6` |
| Web イメージタグ | `REDMINE_WEB_IMAGE` | `localhost/redmine-web:${REDMINE_VERSION}` |
| DB イメージタグ | `REDMINE_DB_IMAGE` | `localhost/redmine-db:${REDMINE_DB_PG_MAJOR}-${REDMINE_DB_POSTGIS_VERSION}` |
| Web ベースイメージ | `REDMINE_WEB_BASE_IMAGE` | `docker.io/library/redmine:${REDMINE_VERSION}` |
| DB ベースイメージ | `REDMINE_DB_BASE_IMAGE` | `docker.io/postgis/postgis:${REDMINE_DB_PG_MAJOR}-${REDMINE_DB_POSTGIS_VERSION}` |
| Compose プロジェクト名 | `COMPOSE_PROJECT_NAME` | `redmine` |
| DB コンテナ表示名 | `REDMINE_DB_CONTAINER` | `redmine-db` |
| Web コンテナ表示名 | `REDMINE_WEB_CONTAINER` | `redmine-web` |
| ネットワーク名 | `REDMINE_NETWORK` | `redmine-net` |
| DB ボリューム名 | `REDMINE_DB_VOLUME` | `redmine_pgdata` |
| 添付ファイルボリューム名 | `REDMINE_FILES_VOLUME` | `redmine_web_files` |
| DB 名 / ユーザー | `REDMINE_DB_NAME` / `REDMINE_DB_USER` | `redmine` / `redmine` |
| データルート | `REDMINE_DATA_DIR` | `/opt/redmine/data/redmine` |
| SUBURI | `REDMINE_SUBURI` | `/redmine` |
| 開発公開ポート | `REDMINE_WEB_HOST_PORT` | `8080` |
| アプリサーバー | `REDMINE_WEB_SERVER` | `puma`（`passenger` も可） |
| Puma 内部ポート | `REDMINE_PUMA_PORT` | `3000`（`passenger` では未使用） |
| YJIT 有効化 | `RUBY_YJIT_ENABLE` | `1` |
| DB アダプタ | `REDMINE_DB_ADAPTER` | `postgis`（移行手順でのみ `postgresql` / `mysql2`。「10. 移行元 (MySQL) の再現と DB コンバート」参照） |
| マイグレーション専用起動 | `REDMINE_MIGRATE_ONLY` | 未設定（設定するとマイグレーション後に Web サーバーを起動せず終了） |

補足:
- `compose.dev.yaml` の build args で `REDMINE_WEB_BASE_IMAGE` / `REDMINE_DB_BASE_IMAGE` を Containerfile の `FROM` に渡します。`redmine-web` の Containerfile は `REDMINE_WEB_CONTAINERFILE` で選びます（系列切り替えのため。「9. Redmine シリーズの切り替え」参照）。`REDMINE_VERSION` と `REDMINE_WEB_CONTAINERFILE` は必ずセットで変更してください。
- 同じバージョン変数から、ビルド済みローカルイメージタグ（`REDMINE_WEB_IMAGE` / `REDMINE_DB_IMAGE`）も構成されます。
- 本番の `quadlets/redmine-web.container` は `EnvironmentFile=-/opt/redmine/containers/.env` を読むため、SMTP/TZ などは同一ファイルで管理できます。
- `RUBY_YJIT_ENABLE` は Ruby 本体が直接読む環境変数で、Puma (`bundle exec rails server`) に
  そのまま渡って有効化されます。Redmine のコードや Containerfile には手を入れないため、
  イメージ再ビルド不要でコンテナ再起動のみで反映されます。`passenger` モードでも、Apache の
  プロセス環境から Passenger が起動するアプリへそのまま継承されます。
- `REDMINE_WEB_SERVER` はイメージに両方式が同梱されているため、値の変更とコンテナ再起動のみで
  反映されます（イメージ再ビルド不要）。本番 (Quadlet) では `Environment=REDMINE_WEB_SERVER=`
  を書き換えるか、`EnvironmentFile` の `.env` に記述してください。
- **同一チェックアウトから 2 つ目の開発スタックを並行起動する場合**は、`COMPOSE_PROJECT_NAME` /
  `REDMINE_NETWORK` / `REDMINE_DB_CONTAINER` / `REDMINE_WEB_CONTAINER` / `REDMINE_DB_VOLUME` /
  `REDMINE_FILES_VOLUME` / `REDMINE_WEB_HOST_PORT` をすべて別値にした 2 つ目の `.env` を用意し、
  `docker compose --env-file .env.stack2 -f compose.dev.yaml up --build -d` のように
  `--env-file` で明示してください（Compose は既定でカレントディレクトリの `.env` しか自動読込
  しないため）。`secrets/db_password.txt` / `secrets/secret_key_base.txt` は両スタックで共有
  されますが、開発用途では問題ありません（DB コンテナ・データが分離されていれば同じパスワード
  を使っても支障はない）。

### なぜ Quadlet 側は一部の変数しか `.env` から読めないのか

Podman Quadlet の `*.container` ユニットファイルは、systemd 起動時に `podman-system-generator` が一度だけ静的にパースするテキストです。`envsubst` や `.env` 読み込みの仕組みは持ちません。`Environment=`/`EnvironmentFile=` はコンテナ **内プロセス** の環境変数を注入するだけで、`Image=`・`ContainerName=`・`Volume=`・`PublishPort=`・`Network=`・`Timezone=`・`HealthCmd=` といったユニット自体のディレクティブには反映されません。したがって:

- コンテナ名・ネットワーク名・DB 名/ユーザー名・データパスは `quadlets/*.container` に直接ハードコードされたままです。
- 本番の systemd ユニット名 (`redmine-db.service`/`redmine-web.service`) は Quadlet ファイルの **ファイル名** に由来します。`ContainerName=` を変えても `systemctl --user`・`Requires=`/`After=`・`journalctl` が参照するユニット名は変わりません。
- `HealthCmd=` は変数展開されないため、ヘルスチェックの判定ロジックはイメージ内の `/usr/local/bin/redmine-healthcheck.sh`（`containers/redmine-web/healthcheck.sh`）に置いています。ユニット側もこのスクリプトを呼ぶだけなので、サブ URI や `REDMINE_WEB_SERVER` はスクリプトがコンテナの環境変数から解決します（`compose.dev.yaml` と同一コマンド）。
- [`host-apache/redmine-proxy.conf`](../host-apache/redmine-proxy.conf) の `ProxyPass /redmine ...` は静的です。本番で `REDMINE_SUBURI`（`RAILS_RELATIVE_URL_ROOT`）を変える場合は、`quadlets/redmine-web.container` の `Environment=` と `host-apache/redmine-proxy.conf` を手動で揃えて編集してください。

### なぜイメージ / バージョンは `.env` の値を変えただけでは反映しないのか

Redmine・PostgreSQL・プラグインのバージョン変更は、`git ls-remote --tags` でタグの実在を確認したうえで Containerfile も合わせて編集し、リビルドする、レビュー前提の作業です（`CLAUDE.md` 参照）。`.env` の値を変えただけでは既存イメージは切り替わらないため、必ずビルドとレビューを経てください。

## 9. Redmine シリーズの切り替え

`redmine-web` は Redmine のメジャーバージョン系列ごとに Containerfile を分けています。
プラグイン / テーマの対応バージョンが系列ごとに違い、単一 Containerfile の条件分岐では
どのタグがどの系列向けか読み取れなくなるためです。

| 系列 | Containerfile | ベースイメージ | Ruby / Rails | プラグイン数 |
|------|---------------|----------------|--------------|--------------|
| Redmine 5 | `Containerfile.v5` | `redmine:5.1.12` | Ruby 3.2 / Rails 6.1.7.10 | 11 |
| Redmine 6（既定） | `Containerfile.v6` | `redmine:6.1.3` | Ruby 3.4 / Rails 7.2.3.1 | 13 |
| Redmine 7 | `Containerfile.v7` | `redmine:7.0.0` | Ruby 4.0 / Rails 8.1.3 | 12 |

`entrypoint.sh` / `healthcheck.sh` / `config.ru` / 各 `*.tmpl` / `redmine-db` は 3 系列で共通です。
系列間の差分は「ベースイメージ」「プラグインのピン」「テーマの配置先」だけに閉じています。

このほかに、移行元 (as-is) を再現するための `Containerfile.v5-mysql`（Redmine 5.1.1 +
MySQL 8.0 CE、プラグイン 16 個）があります。通常構成では使わない検証専用のイメージで、
`compose.legacy.yaml` からのみ参照します（「10. 移行元 (MySQL) の再現と DB コンバート」）。

### 切り替え方法

**開発 (Compose)** — `.env` の 2 つを必ずセットで変更します
（`REDMINE_WEB_BASE_IMAGE` / `REDMINE_WEB_IMAGE` は `REDMINE_VERSION` から生成されます）。

```bash
# 5 系
REDMINE_VERSION=5.1.12
REDMINE_WEB_CONTAINERFILE=Containerfile.v5
# 6 系（既定）
REDMINE_VERSION=6.1.3
REDMINE_WEB_CONTAINERFILE=Containerfile.v6
# 7 系
REDMINE_VERSION=7.0.0
REDMINE_WEB_CONTAINERFILE=Containerfile.v7
```

変更後は `docker compose -f compose.dev.yaml up --build -d` で再ビルド・再作成します。

**本番 (Quadlet)** — Quadlet は `Image=` を変数展開できないため、系列ごとにユニットを用意しています。
`quadlets/*.container` をコピーしたあと、5 系 / 7 系では `redmine-web.container` だけを上書きします。

```bash
cp quadlets/*.container quadlets/*.network ~/.config/containers/systemd/
cp quadlets/v7/redmine-web.container ~/.config/containers/systemd/   # 7 系の場合
systemctl --user daemon-reload
```

**テスト** — `bash scripts/test-stack.sh --series 7`（`5` / `6` / `7`、既定 `6`）。
系列でイメージタグが違うため、`--skip-build` は同じ系列のイメージにしか使えません。

### 同時起動はできません

コンテナ名 (`redmine-db` / `redmine-web`)、公開ポート、ボリューム、データディレクトリを
系列間で共用しているため、起動できるのは一度に 1 系列だけです。また **データベースの内容は
系列間で互換ではありません**。同じ DB に対して別系列のイメージを起動すると、起動時の
`db:migrate` が片道で走ります（5 → 6 → 7 の順にしか進めません）。系列を跨いで試す場合は
必ず事前に `scripts/backup.sh` を実行してください。

### プラグイン / テーマの対応状況（調査根拠つき）

各プラグインの `init.rb` の `requires_redmine` 宣言と、リポジトリの CI マトリクス / コミットを
実際に確認した結果です。CI の対象が RedMica の場合は、RedMica 3.0 = Redmine 5.1.2/5.1.3 相当、
3.1 = 6.0 相当、4.0/4.1 = 6.1 相当、`redmine/redmine` の `master` = 7.0-devel と読み替えています。

| プラグイン | 5 系 | 6 系 | 7 系 |
|---|---|---|---|
| redmine_gtt | v6.0.3（CI に 5.1-stable。要 `GEM_*` ピン） | v7.1.0 | v7.1.0（CI に 7.0-stable × ruby 3.4/4.0） |
| redmine_wiki_extensions | 0.9.5（CI に 5.1-stable） | 1.2.0 | 1.3.0（CI に 7.0-stable, ruby 4.0） |
| view_customize | v3.6.0（CI に redmine-5.1） | master | v3.6.0（7.0 deprecation 対応コミット） |
| redmine_issues_panel | v1.0.4（CI に RedMica 3.0） | v1.2.1 | v1.2.1（CI が redmine master） |
| redmine_ip_filter | v1.1.0（CI に RedMica 3.0） | v1.1.1 | v1.2.0（CI が redmine master） |
| redmica_ui_extension | v0.3.10（CI に RedMica 3.0.1） | v0.6.0 | v0.6.0（CI が redmine master） |
| redmine_message_customize | v1.0.1（CI に RedMica 3.0） | v1.1.0 | v1.1.0（宣言 6.0+。CI 実績は 2024-11 時点で 7.0 の検証なし） |
| redmine_issue_templates | master（宣言 4.0+） | master | master（7.0 向けアイコン互換コミットあり） |
| redmine_logs | 0.3.0（宣言 3.0+、CI は 5.0 まで） | 0.4.0 | 0.4.0（CI は 6.1 まで） |
| redmine_banner | 0.3.5（宣言 4.0+） | 0.3.5 | **非同梱**（master 未対応、修正は未マージ枝のみ） |
| redmine_wiki_lists | 0.0.11（宣言 3.4+、2021 年で更新停止） | 0.0.11 | 0.0.11（同左） |
| redmine_login_audit2 | **非同梱**（全版が 6.0.0 以上を要求） | v1.0.0 | 1.0.2（"Redmine 7.0 support" コミット） |
| redmine_solid_queue | **非同梱**（solid_queue gem が activerecord >= 7.1 要求、5.1 は Rails 6.1） | v1.0.0 | v1.0.0（宣言なし・CI なし） |
| テーマ farend_fancy | tag `redmine5.1`（`public/themes/` 配下） | master | master（Redmine trunk 追従コミットあり） |

宣言だけで CI 実績がないもの（上表の「宣言 …+」と書いたもの）は本番投入前に動作確認してください。

### 系列固有の注意点

- **テーマの置き場が 5 系だけ違います。** Redmine 6.0 でテーマが `public/themes/` から
  `themes/` へ移動しました（5.1.13 のツリーには `public/themes`、6.1.3 / 7.0.0 には `themes`）。
  `Containerfile.v5` だけ `public/themes/farend_fancy` へ clone し、`chown` 対象も
  `public/` 配下で完結させています。
- **5 系の geo gem スタックは固定が必要です。** `redmine_gtt` 6.0.3 の Gemfile は既定で
  `activerecord-postgis-adapter 10.x`（= activerecord ~> 7.2）を要求し、Rails 6.1 では解決
  できません。`Containerfile.v5` は gtt 自身の CI が 5.1-stable 用に使っている値
  （`GEM_RGEO_ACTIVERECORD_VERSION=7.0.1` / `GEM_ACTIVERECORD_POSTGIS_ADAPTER_VERSION=7.1.1`）を
  `ENV` で設定します。ARG ではなく ENV なのは、Redmine の Gemfile が `plugins/*/Gemfile` を
  bundler 実行のたびに評価するため、実行時にも同じ値が必要だからです。
- **5 系の公式イメージはメンテナンスが終了しています。** docker-library/redmine は 2026-04-20 の
  commit `ac72cc3` "Remove 5.1 (Ruby 3.2 EOL)" で 5.1 を削除しました。Docker Hub に残る
  `redmine:5.1.12`（2026-04-14 push）が最後で、Redmine 本体のソースにある 5.1.13 に対応する
  公式イメージはありません。ベース OS と Ruby 3.2 の更新は止まっています。
- **7 系の `mod_passenger` だけ forky (Debian 14 / testing) から導入します。** Debian trixie の
  `libapache2-mod-passenger` は 6.0.26 で、Passenger が Ruby 4 に対応したのは 6.1.1（CHANGELOG:
  "[Ruby] Improve support for Ruby 4 and Frozen String Literals"）以降です。7 系のベースは
  Ruby 4.0 なので、trixie のパッケージでは Ruby 4 対応が入りません。forky には 6.1.x があり、
  依存ライブラリは trixie と同一バージョンで満たせるため、`Containerfile.v7` は forky を
  APT pin して `libapache2-mod-passenger` だけを取得します。実装は次のとおりです
  （`ARG PASSENGER_APT_SUITE` / `ARG PASSENGER_MIN_VERSION` で変更可）。
  - `/etc/apt/sources.list.d/passenger-suite.list` に forky を一時的に追加する。
  - `/etc/apt/preferences.d/passenger-suite.pref` で、forky 由来を既定 `Pin-Priority: -10`
    （= 導入禁止）、`passenger` 関連パッケージのみ `990`（trixie の 500 より優先）にする。
    こうすると forky から来るのは passenger 関連だけで、`libc6` 等が引きずられる部分
    アップグレードは起こりません。依存が trixie 側で満たせない場合は、黙って混ざる代わりに
    ビルドがその場で失敗します。
  - `dpkg --compare-versions ... ge 6.1` で導入結果を検証し、6.1 未満ならビルドを失敗させる。
  - 追加した sources.list / preferences は同じ `RUN` 内で削除し、実行時の apt に forky を
    残さない。
  検証は `bash scripts/test-stack.sh --series 7 --web-server passenger` で、稼働中コンテナの
  `libapache2-mod-passenger` が 6.1 以上であることも含めて確認できます。
  forky 側の版が 6.1 未満に戻る、あるいは依存が trixie で満たせなくなった場合の代替案:
  1. Phusion の APT リポジトリ（Passenger 6.1.0 で Debian 13 trixie パッケージが追加済み）から
     6.1.x を導入する。外部 APT リポジトリ依存が増えます。
  2. 7 系は `puma` 専用と割り切り、`Containerfile.v7` から `libapache2-mod-passenger` を外す。
- **7 系の `redmine_gtt` は導入手順が変わりました。** gtt 7.0 でフロントエンドが
  webpack + yarn から Vite + pnpm（`corepack enable pnpm` → `pnpm install` → `pnpm build`、
  Node >= 22）へ移行しました。Debian trixie の `nodejs` は 20.19 で要件を満たさないため、
  ビルド済み `assets/` を同梱する公式リリース tarball
  (`redmine_gtt-v7.1.0.tar.gz`) を展開する方式にしています。gtt の要件である
  PostgreSQL >= 15 / PostGIS >= 3.4 は、本スタックの 18-3.6 で満たしています。
  なお 6 系→7 系で gtt を上げた場合、MDI グリフを直接指定していたトラッカーアイコンは
  既定マーカーへフォールバックするため、管理画面で選び直しが必要です。

---

## 10. 移行元 (MySQL) の再現と DB コンバート

既存の **Redmine 5.1.1 + MySQL 8.0 CE** から本構成へ移行するための設計です。
実際の作業手順は [docs/Upgrade.md](Upgrade.md) にまとめています。ここでは
「なぜその作り方なのか」だけを記録します。

### 構成要素

| 要素 | 位置づけ |
|------|---------|
| `containers/redmine-db-mysql/` | MySQL 8.0 CE。移行元 DB の再現専用（本番 Quadlet には無い） |
| `containers/redmine-web/Containerfile.v5-mysql` | Redmine 5.1.1 + プラグイン 16 個。mysql2 / postgresql の両アダプタで起動できる |
| `compose.legacy.yaml` | 移行元スタック。コンテナ名・ネットワーク・ボリューム・ポートを通常構成と分けており、`compose.dev.yaml` と同時起動できる |
| `scripts/migrate-mysql-to-postgres.sh` | コンバート本体（preflight / schema / data / sequences / files / verify） |
| `scripts/pgloader/` | pgloader コマンドファイルのテンプレートとシーケンス再設定 SQL |
| `scripts/test-upgrade.sh` | 段階 1〜3 の通し検証 |

### なぜ「スキーマは Rails、データは pgloader」なのか

pgloader にスキーマ生成まで任せると、MySQL の型からの機械変換になります
（`id` 列が `serial` にならない、`tinyint(1)` が `boolean` にならない等）。
Rails から見ると壊れているスキーマになり、その後の Redmine 7 へのマイグレーションで
破綻します。

そこで移行先には、**移行元とまったく同じ Redmine 5.1.1・同じプラグイン構成**で
`rake db:migrate` を実行させてスキーマを作り、pgloader には `data only` で中身だけを
運ばせます。両者は同じマイグレーション列で作られるため、テーブル・列・列順が一致し、
列名ベースの投入が安全に行えます。`schema_migrations` / `ar_internal_metadata` は
移行先が作ったものをそのまま使うため転送対象外です。

### `REDMINE_DB_ADAPTER` とテンプレートの選択規則

`entrypoint.sh` は `config/database.${REDMINE_DB_ADAPTER}.yml.tmpl` があればそれを、
無ければ既定の `config/database.yml.tmpl`（postgis 用）を描画します。
どのテンプレートをイメージに含めるかは Containerfile 側の責務で、entrypoint に系列別の
分岐は置きません。

| イメージ | 同梱テンプレート | 既定アダプタ |
|----------|-----------------|--------------|
| `Containerfile.v5` / `.v6` / `.v7` | `database.yml.tmpl` | `postgis` |
| `Containerfile.v5-mysql` | `database.mysql2.yml.tmpl` / `database.postgresql.yml.tmpl` | `mysql2` |

コンバートの 1 ステップ目では、同じ 5.1.1 イメージを `REDMINE_DB_ADAPTER=postgresql` +
`REDMINE_MIGRATE_ONLY=1` で単発起動します。gtt を同梱していないため
`activerecord-postgis-adapter` は無く、素の `postgresql` アダプタで接続します
（テーブル定義は同一で、後から 6/7 系が `postgis` アダプタで接続し直すだけです）。

`compose.dev.yaml` の `redmine-web` は `REDMINE_DB_ADAPTER`（既定 `postgis`）を
そのまま渡すので、この単発起動の代わりに `REDMINE_WEB_CONTAINERFILE=
Containerfile.v5-mysql` + `REDMINE_DB_ADAPTER=postgresql` で恒久稼働させることもできます
— 移行元のバージョン・プラグイン構成を変えず、DB だけ MySQL から PostgreSQL
（`redmine-db`）へ切り替えたまま運用を続ける構成です。`redmine-db` の実体は
PostGIS 拡張入りの PostgreSQL 18 ですが、gtt を積まないこの構成では PostGIS 固有
機能を使わないため、`postgresql` アダプタで機能的に過不足ありません（`postgis`
は指定できません — このイメージに `database.postgis.yml.tmpl` は無いため）。手順は
[docs/Upgrade.md](Upgrade.md) §4.1 参照。

### `config/database.yml` が bundle の内容を決めてしまう

Redmine の `Gemfile` は `config/database.yml` に現れる `adapter:` 行を集め、その集合に
応じて DB gem（`mysql2` + `with_advisory_lock` / `pg`）を宣言します
（公式 Docker イメージも、全アダプタを事前インストールするためにダミーの
`database.yml` を置いてから `bundle install` しています）。

このため `Containerfile.v5-mysql` は、

1. ビルド時に **両アダプタを書いたダミー `config/database.yml`** を置いてから `bundle install`
2. `mysql2` / `with_advisory_lock` / `pg` が bundle に入ったことをビルド時に検証
3. 実行時テンプレート側にも常に両アダプタ（末尾の `gem_pin_*` スタンザ）を含める

という作りにしています。ビルド時と実行時で adapter 集合が変わると、bundler が実行時に
Gemfile.lock を解決し直し、ネットワーク不通の環境では起動に失敗するためです。

なお通常構成（postgis）では、ビルド時に `database.yml` が無く、実行時の `adapter: postgis`
は Redmine の Gemfile のどの分岐にも当たらないため、どちらも「DB gem の宣言なし」で一致
しています。`pg` は `redmine_gtt` の Gemfile が持ち込んでいます。

### 移行元プラグイン構成の一致が前提

移行先スキーマは「`Containerfile.v5-mysql` が持つ 16 プラグイン」で作られます。移行元に
それ以外のプラグインが入っていると、そのテーブルの投入先が存在せず pgloader が失敗します。
`schema` ステップが移行元と移行先のテーブル集合を突き合わせ、事前に検出して止めます。
