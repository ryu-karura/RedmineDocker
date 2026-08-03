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
- ベースイメージは `redmine:6.1.3`（公式、Ruby / Bundler / Puma / gem も含む）です。
- 日本語 CJK フォント（PDF / Gantt 用）、13 プラグイン + `farend_fancy` テーマ、`redmine_gtt` の webpack ビルド（yarn）を追加します。プラグイン gem は `bundle install` でイメージに焼き込みます。
- Apache フロントエンドを組み込み、`127.0.0.1:80` で `/redmine` リクエストを受けます。その先の処理は `REDMINE_WEB_SERVER` で切り替わります（下記「アプリサーバーの切り替え」）。
- `entrypoint.sh` はシークレット解決（`*_FILE` 対応）、`config/database.yml` の描画（**`postgis`** アダプタ使用、redmine_gtt 必須）、`config/configuration.yml`（SMTP）の描画、Apache 設定の描画、DB 待機、コア / プラグインのマイグレーション実行、アプリサーバーの起動を行います。マイグレーションの実行可否は公式イメージと同じ環境変数で制御します（`REDMINE_NO_DB_MIGRATE` に値を設定するとコアの `db:migrate` をスキップ、`REDMINE_PLUGINS_MIGRATE` が非空なら `redmine:plugins:migrate` を実行。本スタックは 13 プラグインを内蔵するため既定で `REDMINE_PLUGINS_MIGRATE=1`）。

#### アプリサーバーの切り替え（`REDMINE_WEB_SERVER`）

イメージには Puma（公式イメージ同梱）と `mod_passenger`（Debian trixie の `libapache2-mod-passenger` = Passenger 6.0.26）の **両方** が入っています。切り替えは環境変数の変更とコンテナ再起動のみで、イメージの再ビルドは不要です。

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

補足:
- `compose.dev.yaml` の build args で `REDMINE_WEB_BASE_IMAGE` / `REDMINE_DB_BASE_IMAGE` を `Containerfile` の `FROM` に渡します。
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
