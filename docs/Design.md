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
| Puma 内部ポート | `3000`（ホスト公開なし） |
| PostgreSQL 内部ポート | `5432`（ホスト公開なし） |
| Web ホストポート | `127.0.0.1:80` |
| 公開 URL | `http://localhost/redmine/` |

## 2. トポロジー

```
  client ──443──► Host Apache ──/redmine──► redmine-web (Apache 2.4 + Puma :3000, :80)
                                                    │ ProxyPass /redmine → 127.0.0.1:3000
                                                    ▼
                                             redmine-db (PostgreSQL 18 + PostGIS 3.6, :5432)
```

- `redmine-web` が `127.0.0.1:80` にバインドされ、Apache フロントエンドが `/redmine` を Puma に転送します。ホスト側 Apache (`host-apache/redmine-proxy.conf`) が TLS を終端し、`/redmine` を転送します。
- PostgreSQL (5432) と Puma (3000) はホストには公開されません。
- コンテナは `redmine-net` ブリッジ上で通信し、`redmine-db` と `redmine-web` という名前で相互解決します。

## 3. コンテナの役割

### redmine-db (`containers/redmine-db/`)
- ベースイメージは `postgis/postgis:18-3.6` です。`POSTGRES_USER=redmine`、`POSTGRES_DB=redmine`、`POSTGRES_PASSWORD_FILE=/run/secrets/db_password` を設定します。
- 1 つの `redmine` ロールが `redmine` データベースを所有する（ブログの単一ユーザーモデル）構成です。`init-redmine.sh` は `postgis` / `postgis_topology` 拡張機能が存在することを確認します（冪等で、ベースイメージ側で初回初期化時に有効化済みです）。

### redmine-web (`containers/redmine-web/`)
- ベースイメージは `redmine:6.1.3`（公式、Ruby / Bundler / Puma / gem も含む）です。
- 日本語 CJK フォント（PDF / Gantt 用）、13 プラグイン + `farend_fancy` テーマ、`redmine_gtt` の webpack ビルド（yarn）を追加します。プラグイン gem は `bundle install` でイメージに焼き込みます。
- Apache フロントエンドを組み込み、`127.0.0.1:80` で受けた `/redmine` リクエストを Puma の `:3000` に転送します。Puma は `/redmine`（`RAILS_RELATIVE_URL_ROOT`）配下で `:3000` を Listen します。
- `entrypoint.sh` はシークレット解決（`*_FILE` 対応）、`config/database.yml` の描画（**`postgis`** アダプタ使用、redmine_gtt 必須）、`config/configuration.yml`（SMTP）の描画、DB 待機、コア / プラグインのマイグレーション実行、Apache の起動と `rails server`（Puma）起動を行います。マイグレーションの実行可否は公式イメージと同じ環境変数で制御します（`REDMINE_NO_DB_MIGRATE` に値を設定するとコアの `db:migrate` をスキップ、`REDMINE_PLUGINS_MIGRATE` が非空なら `redmine:plugins:migrate` を実行。本スタックは 13 プラグインを内蔵するため既定で `REDMINE_PLUGINS_MIGRATE=1`）。


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
- 追加の Web プロキシコンテナを置かず、Redmine コンテナ内で Apache と Puma を運用しています。現状の設計では、堅牢性を優先して Redmine 側でアセット配信を行っています。

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
| SUBURI | `REDMINE_SUBURI` | `/redmine` |
| 開発公開ポート | `REDMINE_WEB_HOST_PORT` | `8080` |

補足:
- `compose.dev.yaml` の build args で `REDMINE_WEB_BASE_IMAGE` / `REDMINE_DB_BASE_IMAGE` を `Containerfile` の `FROM` に渡します。
- 同じバージョン変数から、ビルド済みローカルイメージタグ（`REDMINE_WEB_IMAGE` / `REDMINE_DB_IMAGE`）も構成されます。
- 本番の `quadlets/redmine-web.container` は `EnvironmentFile=-/opt/redmine/containers/.env` を読むため、SMTP/TZ などは同一ファイルで管理できます。
