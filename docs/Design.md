# 設計書 — RedmineDocker (redmine スタック)

## 1. 概要

RedmineDocker は 2 つのコンテナが連携して Redmine 7.0.1 を動作させます。設計は [redmine.jp の Docker ガイド](https://blog.redmine.jp/articles/6_1/redmine-6_1-docker/) を踏襲しており、**公式** の `redmine` イメージを使い、認証情報は **ファイルベースのシークレット** で管理し、開発・本番とも **同じ Docker Compose 定義**（`compose.dev.yaml`、本番はこれに `compose.prod.yaml` を重ねる）から運用します。本番の起動・停止は systemd ユニット `redmine.service` が担当します。Apache フロントエンドを `redmine-web` に統合し、この環境で求められる設定値に合わせています。

| 項目 | 値 |
|------|----|
| 本番 OS | RHEL 9.5 以上 |
| 開発 A / 本番相当確認 OS | WSL ディストリビューション `AlmaLinux 9.5 以上` |
| 開発 B OS | GitHub Codespaces（Ubuntu, devcontainer） |
| コンテナランタイム | Docker Engine（Compose プラグイン v2.24 以上） |
| 本番の起動方式 | systemd ユニット `redmine.service`（`docker compose ... up -d --wait`） |
| Linux ルートディレクトリ | `/opt/redmine` |
| コンテナネットワーク | `redmine-net`（bridge） |
| Redmine イメージ | `docker.io/library/redmine:7.0.1` |
| PostgreSQL / PostGIS | `docker.io/postgis/postgis:18-3.6` |
| Apache フロントエンド | `httpd` 2.4（`redmine-web` に内蔵） |
| DB 名 / 所有者 | `redmine` / `redmine` |
| DB コンテナ | `redmine-db` |
| Redmine アプリ / Web フロントコンテナ | `redmine-web` |
| アプリサーバー | `passenger`（既定）または `puma`（`REDMINE_WEB_SERVER`） |
| Puma 内部ポート | `3000`（ホスト公開なし。`passenger` では未使用） |
| PostgreSQL 内部ポート | `5432`（ホスト公開なし） |
| Web ホストポート | `127.0.0.1:80` |
| 公開 URL | `http://localhost/redmine/` |

## 2. トポロジー

`REDMINE_WEB_SERVER=passenger`（既定）:

```
  client ──443──► Host Apache ──/redmine──► redmine-web (Apache 2.4 + mod_passenger, :80)
                                                    │ Passenger が Redmine を直接起動（:3000 なし）
                                                    ▼
                                             redmine-db (PostgreSQL 18 + PostGIS 3.6, :5432)
```

`REDMINE_WEB_SERVER=puma`:

```
  client ──443──► Host Apache ──/redmine──► redmine-web (Apache 2.4 + Puma :3000, :80)
                                                    │ ProxyPass /redmine → 127.0.0.1:3000
                                                    ▼
                                             redmine-db (PostgreSQL 18 + PostGIS 3.6, :5432)
```

- `redmine-web` が `127.0.0.1:80` にバインドされます。ホスト側 Apache (`host-apache/redmine-proxy.conf`) が TLS を終端し、`/redmine` を転送します。ホスト側の設定はどちらのモードでも同じです。
- コンテナ内 Apache から先は `REDMINE_WEB_SERVER` で切り替わります。`passenger`（7 系の既定）は `mod_passenger` が Redmine を Apache の子プロセスとして直接起動し、静的資産は Apache が `public/` から配信します。`puma` は `/redmine` を Puma (`:3000`) に `ProxyPass` し、静的資産も Rails (`RAILS_SERVE_STATIC_FILES`) が配信します。
- PostgreSQL (5432) と Puma (3000) はホストには公開されません。
- コンテナは `redmine-net` ブリッジ上で通信し、`redmine-db` と `redmine-web` という名前で相互解決します。

## 3. コンテナの役割

### redmine-db (`containers/redmine-db/`)
- ベースイメージは `postgis/postgis:18-3.6` です。`POSTGRES_USER=redmine`、`POSTGRES_DB=redmine`、`POSTGRES_PASSWORD_FILE=/run/secrets/db_password` を設定します。
- 1 つの `redmine` ロールが `redmine` データベースを所有する（ブログの単一ユーザーモデル）構成です。`init-redmine.sh` は `postgis` / `postgis_topology` 拡張機能が存在することを確認します（冪等で、ベースイメージ側で初回初期化時に有効化済みです）。

### redmine-web (`containers/redmine-web/`)
- ベースイメージは `redmine:7.0.1`（公式、Ruby / Bundler / Puma / gem も含む）です。Redmine のメジャーバージョン系列ごとに Containerfile を分けており、既定は 7 系（`Containerfile.v7`）です。5 系 / 6 系については「9. Redmine シリーズの切り替え」を参照してください。
- 日本語 CJK フォント（PDF / Gantt 用）、14 プラグイン + `farend_fancy` テーマを追加します。プラグイン gem は `bundle install` でイメージに焼き込みます。`redmine_gtt` は 7.x でフロントエンドが webpack+yarn から Vite+pnpm へ移行したため、ビルド済み資産を同梱する公式リリース tarball を展開しています（6 系 / 7 系。Node ツールチェーンは不要）。5 系だけは webpack 時代の 6.0.3 を使うため yarn + webpack のビルドが残ります。
- Apache フロントエンドを組み込み、`127.0.0.1:80` で `/redmine` リクエストを受けます。その先の処理は `REDMINE_WEB_SERVER` で切り替わります（下記「アプリサーバーの切り替え」）。
- `entrypoint.sh` はシークレット解決（`*_FILE` 対応）、`config/database.yml` の描画（**`postgis`** アダプタ使用、redmine_gtt 必須）、`config/configuration.yml`（SMTP）の描画、Apache 設定の描画、DB 待機、コア / プラグインのマイグレーション実行、アプリサーバーの起動を行います。マイグレーションの実行可否は公式イメージと同じ環境変数で制御します（`REDMINE_NO_DB_MIGRATE` に値を設定するとコアの `db:migrate` をスキップ、`REDMINE_PLUGINS_MIGRATE` が非空なら `redmine:plugins:migrate` を実行。本スタックは 14 プラグインを内蔵するため既定で `REDMINE_PLUGINS_MIGRATE=1`）。

#### アプリサーバーの切り替え（`REDMINE_WEB_SERVER`）

イメージには Puma（公式イメージ同梱）と `mod_passenger` の **両方** が入っています。切り替えは環境変数の変更とコンテナ再起動のみで、イメージの再ビルドは不要です。

既定値は系列ごとに各 Containerfile の `ENV REDMINE_WEB_SERVER` が決めます。**7 系（既定シリーズ）は `passenger`**、5 系 / 6 系は `puma` です。`compose.dev.yaml` も既定を `passenger` に合わせてあります（`.env` の `REDMINE_WEB_SERVER` で上書き。本番も同じ compose 定義なので設定箇所は 1 か所です）。`compose.dev.yaml` は値を常にコンテナへ渡すため、5 系 / 6 系へ切り替えて `puma` で動かすときは `.env` 側も明示してください。

`mod_passenger` は 3 系列とも Debian trixie の `libapache2-mod-passenger`（Passenger 6.0.26）です。7 系のベースは Ruby 4.0 ですが、この版のままで Redmine 7 を配信できることを実機で確認しています（検証根拠は下記「9. Redmine シリーズの切り替え」参照）。

| | `passenger`（既定 / 7 系） | `puma`（5 系 / 6 系の既定） |
|---|---|---|
| リクエスト処理 | Apache + `mod_passenger` が直接起動 | Apache → `ProxyPass` → Puma `:3000` |
| Apache 設定 | `httpd-redmine-passenger.conf.tmpl` → `redmine-passenger.conf` | `httpd-redmine.conf.tmpl` → `redmine-proxy.conf` |
| 静的資産 | Apache が `Alias` で `public/` を配信 | Rails（`RAILS_SERVE_STATIC_FILES=1`） |
| コンテナの PID 1 | `apache2 -DFOREGROUND` | `entrypoint.sh`（Apache 起動後 Puma を監視） |
| 実行ユーザー | `PassengerUser redmine` | `runuser -u redmine` で Puma |
| `:3000` | なし | あり |

`entrypoint.sh` が起動時にテンプレートを描画し、`a2enmod passenger` / `a2dismod -f passenger` と `a2enconf` / `a2disconf` で該当する設定だけを有効化します（どちらも `*:80` の VirtualHost を定義するため、同時に有効化はできません）。

`passenger` モードでは `entrypoint.sh` が `/etc/apache2/envvars` を `source` してから `apache2 -DFOREGROUND` を `exec` します。この `source` には実測に基づく 2 つの回避策が入っています。消さないでください。

1. **`set -u` を一時的に外す。** `envvars` の先頭は `APACHE_CONFDIR`（本来 `apache2ctl` が設定する変数）を未設定のまま参照するため、`set -euo pipefail` のまま `source` すると `APACHE_CONFDIR: unbound variable` で entrypoint ごと終了します（コンテナが起動直後に exit 1）。
2. **`LANG` を元に戻す。** `envvars` は mod_dav 向けに `LANG=C` を `export` します。この値は Apache → `mod_passenger` → Redmine と継承され、Ruby の `Encoding.default_external` が US-ASCII になります。すると bundler が `Gemfile` を評価する際、日本語コメントを含む `config/database.yml` を読んだ時点で `invalid byte sequence in US-ASCII` となり、アプリが起動しません。公式イメージが設定している `LANG=C.UTF-8` を `source` 後に復元します。

どちらも `puma` モードでは起きません（`apache2ctl -k start` が別プロセスで `envvars` を読むため）。`passenger` を既定にしたことで両方とも通常経路に乗るようになりました。

実装上の注意点:

- `config.ru` は Passenger 配下では `map` を **行いません**。`mod_passenger` は `PassengerBaseURI` によって `SCRIPT_NAME` を `/redmine` に設定し、`PATH_INFO` からはプレフィックスを除去して渡すため、`Rack::URLMap`（`map`）を挟むと `/login` が `/redmine` にマッチせず全リクエストが 404 になります。`defined?(PhusionPassenger)` で判定して分岐しています。
- `PassengerRuby` は公式イメージの `/usr/local/bin/ruby` を指します（Debian パッケージの既定である `/usr/bin/ruby` には Redmine の gem が入っていません）。
- Passenger の native support 拡張はビルド時に用意していません。初回起動時に自動コンパイルが試みられ、失敗しても pure-Ruby 実装へフォールバックします（error log に警告が出るのみ）。


## 4. データと永続化

| ホスト上のパス（本番） | マウント先 | 内容 |
|------------------------|------------|------|
| `/opt/redmine/data/postgres/18` | redmine-db | PostgreSQL のデータディレクトリ |
| `/opt/redmine/data/redmine/files` | redmine-web | アップロードされた添付ファイル |
| `/opt/redmine/data/redmine/log` | redmine-web | Redmine の `log/` ディレクトリ（公式イメージの既定 `RAILS_LOG_TO_STDOUT=true` では Rails ログは標準出力に出るため通常は空。ファイル出力へ切り替えたときの `production.log` 置き場。`docs/Manual.md`「ログ」参照） |
| `/opt/redmine/backup/{db,files}` | host | バックアップ（Manual 参照） |

bind mount への差し替えは `compose.prod.yaml`（本番オーバーレイ）だけが行います。開発環境 (`compose.dev.yaml` 単体) では名前付きボリューム (`pgdata`、`redmine_files`) のままで、ホスト準備なしに動きます。プラグインとテーマはイメージに焼き込まれており、ボリュームマウントは行いません（ボリュームで上書きされるため）。

docker の bind mount は UID を変換しません（rootless Podman のようなサブ UID へのリマップが無い）。そのため `files` / `log` はホスト側を **999:999**（公式 redmine イメージの `redmine` ユーザー）にしておく必要があります。マウント直下の所有者だけは `entrypoint.sh` が起動時に合わせますが、リストアなどで中身を入れ替えたときは再帰的に `chown` してください（`scripts/restore.sh` は root 実行時に自動で行います）。PostgreSQL のデータディレクトリは、`postgres` イメージの entrypoint が root で起動して所有者を調整するため、ホスト側は root 所有のままで構いません。

## 5. シークレット

ファイルとして保存される 2 つのシークレットで、プレーンな環境変数ではありません。

| シークレット | 利用先 | ソースファイル |
|--------------|--------|----------------|
| `db_password` | redmine-db, redmine-web | `secrets/db_password.txt` |
| `secret_key_base` | redmine-web | `secrets/secret_key_base.txt` |

`scripts/generate-secrets.sh` がファイルを作成します（mode 600、git ignore）。開発・本番とも `compose.dev.yaml` の `secrets:`（file secret）でコンテナの `/run/secrets/<name>` にマウントされるため、**本番でも登録コマンドは不要**です。コンテナ側は `REDMINE_DB_PASSWORD_FILE` などの `*_FILE` 経由で読み込みます。

## 6. ユーザーと権限

- コンテナ内では公式イメージが持つユーザーをそのまま使用します: `redmine`（Redmine アプリ）と `postgres` / `redmine`（データベース）。独自の UID/GID リマップは行いません。
- 本番の docker デーモンは root で動き、`redmine.service` も root の system ユニットです。コンテナ内の UID はホストの UID にそのまま対応するため、bind mount するデータディレクトリは `999:999`（コンテナ内 `redmine`）で所有させます（「4. データと永続化」参照）。SELinux 環境向けに `compose.prod.yaml` の bind mount には `:Z` を付けています。
- `docker` グループへの追加は root 相当の権限付与に等しいため、運用コマンド（`scripts/backup.sh` など）は root（`sudo`）実行を既定にしています。

## 7. 補足 / 注意点

- 追加の Web プロキシコンテナを置かず、Redmine コンテナ内で Apache とアプリサーバーを運用しています。既定の `passenger` モードでは Apache が `public/` を直接配信し、`puma` モードでは Redmine（Rails）側がアセットを配信します。

## 8. 設定パラメータ (.env)

非シークレット設定は `.env`（テンプレート: `.env.example`）で管理します。Compose は自動で `.env` を読み込み、運用スクリプト（`scripts/backup.sh` / `scripts/restore.sh`）も同じ値を参照します。この節で扱うのは通常スタック（`compose.dev.yaml`）用の `.env` です。移行元スタック（`compose.legacy.yaml`）用の変数は別ファイル `.env.legacy`（テンプレート: `.env.legacy.example`）にあり、混在させません — 詳細は「10. 移行元 (MySQL) の再現と DB コンバート」参照。

主なパラメータ:

| 用途 | 変数 | 既定値 |
|------|------|--------|
| Redmine バージョン | `REDMINE_VERSION` | `7.0.1` |
| Web の Containerfile | `REDMINE_WEB_CONTAINERFILE` | `Containerfile.v7` |
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
| データルート（本番の bind mount 元） | `REDMINE_DATA_ROOT` | `/opt/redmine/data` |
| Redmine データディレクトリ | `REDMINE_DATA_DIR` | `${REDMINE_DATA_ROOT}/redmine` |
| SUBURI | `REDMINE_SUBURI` | `/redmine` |
| 開発公開ポート | `REDMINE_WEB_HOST_PORT` | `8080` |
| 本番公開ポート | `REDMINE_PROD_HOST_PORT` | `80`（`compose.prod.yaml` のみが参照） |
| アプリサーバー | `REDMINE_WEB_SERVER` | `passenger`（`puma` も可） |
| Puma 内部ポート | `REDMINE_PUMA_PORT` | `3000`（`passenger` では未使用） |
| YJIT 有効化 | `RUBY_YJIT_ENABLE` | `1` |
| DB アダプタ | `REDMINE_DB_ADAPTER` | `postgis`（`.env` 側は常にこれで固定。`postgresql` / `mysql2` は `.env.legacy` 側でのみ使用。「10. 移行元 (MySQL) の再現と DB コンバート」参照） |
| マイグレーション専用起動 | `REDMINE_MIGRATE_ONLY` | 未設定（設定するとマイグレーション後に Web サーバーを起動せず終了） |

補足:
- `compose.dev.yaml` の build args で `REDMINE_WEB_BASE_IMAGE` / `REDMINE_DB_BASE_IMAGE` を Containerfile の `FROM` に渡します。`redmine-web` の Containerfile は `REDMINE_WEB_CONTAINERFILE` で選びます（系列切り替えのため。「9. Redmine シリーズの切り替え」参照）。`REDMINE_VERSION` と `REDMINE_WEB_CONTAINERFILE` は必ずセットで変更してください。
- 同じバージョン変数から、ビルド済みローカルイメージタグ（`REDMINE_WEB_IMAGE` / `REDMINE_DB_IMAGE`）も構成されます。
- 本番も `systemd/redmine.service` が `WorkingDirectory=/opt/redmine/containers` で compose を実行するため、同じ `.env` がそのまま読み込まれます（SMTP/TZ を含む全項目）。
- `RUBY_YJIT_ENABLE` は Ruby 本体が直接読む環境変数で、Puma (`bundle exec rails server`) に
  そのまま渡って有効化されます。Redmine のコードや Containerfile には手を入れないため、
  イメージ再ビルド不要でコンテナ再起動のみで反映されます。`passenger` モードでも、Apache の
  プロセス環境から Passenger が起動するアプリへそのまま継承されます。
- `REDMINE_WEB_SERVER` はイメージに両方式が同梱されているため、値の変更とコンテナ再起動のみで
  反映されます（イメージ再ビルド不要）。本番では `.env` を書き換えて
  `sudo systemctl reload redmine` を実行します。
- **同一チェックアウトから 2 つ目の開発スタックを並行起動する場合**は、`COMPOSE_PROJECT_NAME` /
  `REDMINE_NETWORK` / `REDMINE_DB_CONTAINER` / `REDMINE_WEB_CONTAINER` / `REDMINE_DB_VOLUME` /
  `REDMINE_FILES_VOLUME` / `REDMINE_WEB_HOST_PORT` をすべて別値にした 2 つ目の `.env` を用意し、
  `docker compose --env-file .env.stack2 -f compose.dev.yaml up --build -d` のように
  `--env-file` で明示してください（Compose は既定でカレントディレクトリの `.env` しか自動読込
  しないため）。`secrets/db_password.txt` / `secrets/secret_key_base.txt` は両スタックで共有
  されますが、開発用途では問題ありません（DB コンテナ・データが分離されていれば同じパスワード
  を使っても支障はない）。

### 本番でも `.env` がそのまま効きます

本番の起動は `systemd/redmine.service` の
`ExecStart=/usr/bin/docker compose -f compose.dev.yaml -f compose.prod.yaml up -d --wait`
です。`WorkingDirectory=/opt/redmine/containers` で実行するため、Compose が同じディレクトリの
`.env` を自動読込します。つまりコンテナ名・ネットワーク名・DB 名/ユーザー名・サブ URI・
データルート (`REDMINE_DATA_ROOT`) まで、**開発と同じ 1 ファイル**で設定できます。

残る注意点は 2 つです。

- 公開ポートだけは開発と本番で変数を分けています（`REDMINE_WEB_HOST_PORT` = 開発の 8080 /
  `REDMINE_PROD_HOST_PORT` = 本番の 80）。`.env.example` をそのままコピーした `.env` の
  開発値が本番に効いてしまうと、ホスト Apache の転送先 (`127.0.0.1:80`) と食い違うためです。
- [`host-apache/redmine-proxy.conf`](../host-apache/redmine-proxy.conf) の
  `ProxyPass /redmine ...` は静的です。`REDMINE_SUBURI` を変える場合は、このファイルも
  合わせて編集してください。

ヘルスチェックの判定ロジックはイメージ内の `/usr/local/bin/redmine-healthcheck.sh`
（`containers/redmine-web/healthcheck.sh`）に置いています。サブ URI と
`REDMINE_WEB_SERVER` で検証内容が変わるため、コンテナの環境変数から解決できる場所に
まとめてあります。

### なぜイメージ / バージョンは `.env` の値を変えただけでは反映しないのか

Redmine・PostgreSQL・プラグインのバージョン変更は、`git ls-remote --tags` でタグの実在を確認したうえで Containerfile も合わせて編集し、リビルドする、レビュー前提の作業です（`CLAUDE.md` 参照）。`.env` の値を変えただけでは既存イメージは切り替わらないため、必ずビルドとレビューを経てください。

## 9. Redmine シリーズの切り替え

`redmine-web` は Redmine のメジャーバージョン系列ごとに Containerfile を分けています。
プラグイン / テーマの対応バージョンが系列ごとに違い、単一 Containerfile の条件分岐では
どのタグがどの系列向けか読み取れなくなるためです。

| 系列 | Containerfile | ベースイメージ | Ruby / Rails | プラグイン数 |
|------|---------------|----------------|--------------|--------------|
| Redmine 5 | `Containerfile.v5` | `redmine:5.1.12` | Ruby 3.2 / Rails 6.1.7.10 | 12 |
| Redmine 6 | `Containerfile.v6` | `redmine:6.1.4` | Ruby 3.4 / Rails 7.2.3.2 | 14 |
| Redmine 7（既定） | `Containerfile.v7` | `redmine:7.0.1` | Ruby 4.0 / Rails 8.1.3.1 | 14 |

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
# 6 系
REDMINE_VERSION=6.1.4
REDMINE_WEB_CONTAINERFILE=Containerfile.v6
# 7 系（既定。.env で指定しなければこれになります）
REDMINE_VERSION=7.0.1
REDMINE_WEB_CONTAINERFILE=Containerfile.v7
```

変更後は `docker compose -f compose.dev.yaml up --build -d` で再ビルド・再作成します。

**本番 (Docker + systemd)** — 本番も同じ `compose.dev.yaml` を使うため、開発とまったく同じく
`.env` の 2 行（`REDMINE_VERSION` / `REDMINE_WEB_CONTAINERFILE`）を変えるだけです。

```bash
cd /opt/redmine/containers
# .env の REDMINE_VERSION / REDMINE_WEB_CONTAINERFILE を変更してから
sudo docker compose -f compose.dev.yaml -f compose.prod.yaml build
sudo systemctl restart redmine
```

**テスト** — `bash scripts/test-stack.sh --series 6`（`5` / `6` / `7`、既定 `7`）。
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
| redmine_banner | 0.3.5（宣言 4.0+） | 0.3.5 | master（0.3.5 より後の 7.0 対応コミット。対応を含むタグは未リリース） |
| redmine_wiki_lists | 0.0.11（宣言 3.4+、2021 年で更新停止） | 0.0.11 | 0.0.11（同左） |
| redmine_login_audit2 | **非同梱**（全版が 6.0.0 以上を要求） | v1.0.0 | 1.0.2（"Redmine 7.0 support" コミット） |
| redmine_solid_queue | **非同梱**（solid_queue gem が Rails 7 以上を要求。最古の 0.1.1 でも rails >= 7.0.3.1 のため古い版へ落としても不可） | v1.0.0 | v1.0.0（宣言なし・CI なし） |
| redmine_xlsx_format_issue_exporter | 0.2.1（宣言 4.2+、CI なし） | 0.2.1（同左） | 0.2.1（同左） |
| テーマ farend_fancy | tag `redmine5.1`（`public/themes/` 配下） | master | master（Redmine trunk 追従コミットあり） |

宣言だけで CI 実績がないもの（上表の「宣言 …+」と書いたもの）は本番投入前に動作確認してください。

5 系で **非同梱** とした 2 つは 2026-09 に再確認済みで、いずれも技術的に導入できない
ままです（`redmine:5.1.12` に載せて実際に確認）。`redmine_login_audit2` 1.0.2 は起動時に
`Redmine::PluginRequirementError: ... requires Redmine 6.0.0 or higher` で停止し、
`redmine_solid_queue` は bundler が `solid_queue < 0.3.0 requires rails >= 7.0.3.1` で
解決に失敗します。

`redmine_banner` の 7 系だけタグではなく master を pin しているのは、Redmine 7 対応が
最新タグ 0.3.5 より後のコミットにしかないためです（PR #15 `test_fix_for_redmine_7_0`、
2026-08-25 マージ）。修正は 2 点あり、いずれも 7.0 固有です。

- `config/routes.rb`: `resources :banner, only: %i[preview off]` のように RESTful でない
  アクションを `only:` に渡していた箇所を `only: []` へ修正。Rails 8.1 はルーティング
  定義時に例外を投げるため、**このプラグインを置くだけで Redmine 全体が起動不能**でした
  （実際に 0.3.5 を Redmine 7.0.1 に載せると
  `Route 'resources :banner' - :only and :except must include only [...]` で終了します）。
- `assets/stylesheets/banner.css`: Redmine 7.0 でコアの `.icon` から `background-repeat`
  等が `legacy-icons-compat.css` へ分離されたことによる、管理画面メニューのアイコンの
  敷き詰め表示を修正。

upstream の `init.rb` は `version '0.3.4'` のままなので、管理画面のプラグイン一覧では
0.3.4 と表示されます（実体は master）。7.0 対応を含むタグが出たらそのタグへ
差し替えてください。

### 系列固有の注意点

- **テーマの置き場が 5 系だけ違います。** Redmine 6.0 でテーマが `public/themes/` から
  `themes/` へ移動しました（5.1.13 のツリーには `public/themes`、6.1.4 / 7.0.1 には `themes`）。
  `Containerfile.v5` だけ `public/themes/farend_fancy` へ clone し、`chown` 対象も
  `public/` 配下で完結させています。
- **5 系の geo gem スタックは固定が必要です。** `redmine_gtt` 6.0.3 の Gemfile は既定で
  `activerecord-postgis-adapter 10.x`（= activerecord ~> 7.2）を要求し、Rails 6.1 では解決
  できません。`Containerfile.v5` は gtt 自身の CI が 5.1-stable 用に使っている値
  （`GEM_RGEO_ACTIVERECORD_VERSION=7.0.1` / `GEM_ACTIVERECORD_POSTGIS_ADAPTER_VERSION=7.1.1`）を
  `ENV` で設定します。ARG ではなく ENV なのは、Redmine の Gemfile が `plugins/*/Gemfile` を
  bundler 実行のたびに評価するため、実行時にも同じ値が必要だからです。
- **ベースイメージは Redmine のパッチリリースに追従します。** 現在の pin は 7.0.1 と 6.1.4
  （どちらも公式イメージは 2026-08-30 公開）で、Redmine 本体の修正に加えて Rails を
  8.1.3 → 8.1.3.1 / 7.2.3.1 → 7.2.3.2 へ上げるパッチリリースです。追従するときは
  `.env`（`REDMINE_VERSION`）、各 `Containerfile.v*` の `ARG WEB_BASE_IMAGE`、
  `compose.dev.yaml` の既定値、`scripts/test-stack.sh` の系列表を**同時に**変更してください（1 か所でも取り残すと、
  ビルドしたイメージと起動するイメージのタグがずれます）。
- **5 系の公式イメージはメンテナンスが終了しています。** docker-library/redmine は 2026-04-20 の
  commit `ac72cc3` "Remove 5.1 (Ruby 3.2 EOL)" で 5.1 を削除しました。Docker Hub に残る
  `redmine:5.1.12`（2026-04-14 push）が最後で、Redmine 本体のソースにある 5.1.13 に対応する
  公式イメージはありません。ベース OS と Ruby 3.2 の更新は止まっています。
- **`mod_passenger` は 3 系列とも Debian trixie の 6.0.26 です（7 系も同じ）。** 以前は
  7 系だけ forky (Debian 14 / testing) の 6.1.x を APT pin で導入していました。根拠は
  Passenger の CHANGELOG 6.1.1 にある "[Ruby] Improve support for Ruby 4 and Frozen String
  Literals" で、「Ruby 4 対応は 6.1.1 以降」と読んだためです。2026-09 に実機で検証した
  結果、この pin は不要と判断して撤去しました。根拠は次の 3 点です。
  1. **6.1.1 の該当コミットは frozen string literal 対応でした。** 該当は
     `Deal with frozen string literals (#2620)` で、`buffer = ''` → `String.new`、
     `result << ...` → `result += ...` といった置き換えです（`thread_handler.rb`、
     `loader_shared_helpers.rb` ほか）。Ruby 4 固有の C API 変更への追従ではありません。
  2. **Ruby 4.0.6 は文字列リテラルを凍結しません。** 公式イメージ `redmine:7.0.1` の
     Ruby で `"".frozen?` は `false`、`s = ""; s << "x"` も通ります。つまり 6.0.26 が
     壊れる前提（リテラル凍結）が現時点では成立しません。
  3. **実際に配信できることを確認しました。** Debian trixie と同一 upstream 版の
     Passenger 6.0.26（Ubuntu 25.10 の `libapache2-mod-passenger 6.0.26+ds-1.1`）に、
     公式イメージから持ち込んだ Ruby 4.0.6 + Redmine 7.0.1 を載せ、本リポジトリの
     `config.ru` と `httpd-redmine-passenger.conf.tmpl` をそのまま使って起動し、
     `scripts/test-webflow.sh`（ログイン → プロジェクト作成 → チケット作成・表示）が
     全項目通過しました。`public/` の静的配信、アプリが `redmine` ユーザーで動くこと、
     Passenger 側の警告が出ないことも確認しています。

  この結果、7 系は 5 / 6 系と同じ `apt-get install libapache2-mod-passenger` だけになり、
  APT pin・preferences・バージョン assert（約 40 行）が不要になりました。
  `scripts/test-stack.sh --web-server passenger`（7 系では `--web-server` 省略時の既定）は
  3 系列共通で、稼働中コンテナの `libapache2-mod-passenger` が 6.0.25 以上
  （Ruby 3.4 対応が入った版）であることを検査します。

  将来 Ruby がリテラル凍結を既定にした場合は 6.1.1 以上が必要になります。その時点で
  Debian の安定版が 6.1 を持っていれば素の apt で足り、無ければ次のいずれかです。
  1. Phusion の APT リポジトリ（Passenger 6.1.0 で Debian 13 trixie パッケージが追加済み）から
     6.1.x を導入する。外部 APT リポジトリ依存が増えます。
  2. 7 系は `puma` 専用と割り切り、`Containerfile.v7` から `libapache2-mod-passenger` を外す。

  なお「7 系を Ruby 3.4 ベースで自前ビルドして trixie の Passenger に合わせる」案も検討
  しましたが、採りませんでした。Redmine 7 の公式イメージは全バリアント（trixie /
  bookworm / alpine）が Ruby 4.0 のみで、Ruby 3.4 にするには公式イメージをやめて Redmine 
  本体のビルド（tarball の SHA256 追跡、gosu、`cargo`/`rustc` の **trixie-backports** pin、
  gem の全ビルド）を自前で抱えることになります。Redmine 7.0.1 自体は Ruby 3.4 でも動きます
  （Gemfile は `ruby '>= 3.2.0', '< 4.1.0'`、Rails 8.1.3.1 は ruby >= 3.2 要求、
  Ruby 4 以上を要求する gem もありません）が、pin を 1 つ消すために別の pin と
  ビルド一式を抱える取引になるため、上記の実測により不要と結論しました。
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
| `.env.legacy.example` | `compose.legacy.yaml` 専用の環境変数テンプレート。通常スタックの `.env.example` とは別ファイル（8 章参照） |
| `containers/redmine-db-mysql/` | MySQL 8.0 CE。移行元 DB の再現専用（本番構成には無い） |
| `containers/redmine-web/Containerfile.v5-mysql` | Redmine 5.1.1 + プラグイン 16 個。mysql2 / postgresql の両アダプタで起動できる |
| `compose.legacy.yaml` | 移行元スタック。コンテナ名・ネットワーク・ボリューム・ポートを通常構成と分けており、`compose.dev.yaml` と同時起動できる |
| `compose.legacy-on-postgres.yaml` | `compose.legacy.yaml` への override。移行元のバージョン・プラグイン構成のまま DB だけ PostgreSQL へ恒久的に切り替える場合に重ねる（下記参照） |
| `scripts/migrate-mysql-to-postgres.sh` | コンバート本体（preflight / schema / data / sequences / files / verify）。`.env` と `.env.legacy` の両方を読む |
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

この単発起動の代わりに `compose.legacy.yaml` の `redmine-legacy-web` を
恒久稼働させることもできます — 移行元のバージョン・プラグイン構成を変えず、
DB だけ MySQL から PostgreSQL（`redmine-db`）へ切り替えたまま運用を続ける構成
です。`redmine-legacy-web` は既定では `redmine-legacy-net`（MySQL 側）にしか
繋がっていないため、`compose.legacy-on-postgres.yaml` という override を
重ねて `redmine-net`（`compose.dev.yaml` が作る、`external: true` で参照）
にも接続し、`REDMINE_DB_ADAPTER=postgresql` で `redmine-db` を向くよう
環境変数を上書きします。通常スタック（`.env` / `compose.dev.yaml`）側は
一切変更しません — `Containerfile.v5-mysql` を通常スタックの
`REDMINE_WEB_CONTAINERFILE` に指定することはなく、常に `compose.legacy.yaml`
の管轄に留めます（`.env` と `.env.legacy` を混在させない、という設計方針の
帰結です。8 章参照）。`redmine-db` の実体は PostGIS 拡張入りの PostgreSQL 18
ですが、gtt を積まないこの構成では PostGIS 固有機能を使わないため、
`postgresql` アダプタで機能的に過不足ありません（`postgis` は指定できません
— このイメージに `database.postgis.yml.tmpl` は無いため）。手順は
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
