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
- `entrypoint.sh` はシークレット解決（`*_FILE` 対応）、`config/database.yml` の描画（**`postgis`** アダプタ使用、redmine_gtt 必須）、`config/configuration.yml`（SMTP）の描画、DB 待機、コア / プラグインのマイグレーション実行、Apache の起動と `rails server`（Puma）起動を行います。


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

## 8. 設定項目 (Configuration)

コンテナ名・DB 名・ユーザー名・パス・SUB URI などの設定値は、以前は `compose.dev.yaml`・`quadlets/*.container`・`scripts/*.sh` に個別にハードコードされていました。現在は次の方針で集約しています。

| 設定項目 | `.env` 変数 | 既定値 | 開発 (`compose.dev.yaml`) | 本番 (`quadlets/`) | 本番運用スクリプト |
|---|---|---|---|---|---|
| DB コンテナの表示名 | `DB_CONTAINER_NAME` | `redmine-db` | ✅ `container_name` | ❌ 反映されない | ✅ `backup.sh`/`restore.sh` |
| Web コンテナの表示名 | `WEB_CONTAINER_NAME` | `redmine-web` | ✅ `container_name` | ❌ 反映されない | ✅ `restore.sh`（`systemctl` 対象名） |
| ネットワーク名 | `NETWORK_NAME` | `redmine-net` | ✅ | ❌ 反映されない | — |
| DB 名 | `DB_NAME` | `redmine` | ✅ `POSTGRES_DB` / `REDMINE_DB_NAME` | ❌ 反映されない | ✅ |
| DB ユーザー | `DB_USER` | `redmine` | ✅ | ❌ 反映されない | ✅ |
| SUB URI | `RAILS_RELATIVE_URL_ROOT` | `/redmine` | ✅（Apache 設定も entrypoint で再描画） | ❌ 反映されない | — |
| 開発ホストポート | `WEB_HOST_PORT` | `8080` | ✅ | 該当なし（本番は 80 固定、意図的） | — |
| データルート | `DATA_ROOT` | `/opt/redmine` | 該当なし（名前付きボリューム使用） | ❌ 反映されない | ✅ |
| タイムゾーン | `TZ` | `Asia/Tokyo` | ✅ | △ コンテナのプロセス環境のみ（`Timezone=` ディレクティブ自体は固定） | — |
| SMTP 設定 | `SMTP_HOST`/`PORT`/`USER`/`PASSWORD` | 例示値 | ✅ | ✅ `EnvironmentFile=` 経由で反映 | — |
| イメージ / バージョン | — | — | 集約対象外（下記参照） | 集約対象外 | — |

現在値のデフォルトは [`.env.example`](../.env.example) にまとめてあります。開発環境ではコピー不要（既定値がそのまま Compose に埋め込み済み）、本番では `/opt/redmine/containers/.env` としてコピーして使います（`docs/Setup.md` 参照）。

### なぜ Quadlet 側は `.env` を読めないのか

Podman Quadlet の `*.container` ユニットファイルは、systemd 起動時に `podman-system-generator` が一度だけ静的にパースするテキストです。`envsubst` や `.env` 読み込みの仕組みは持ちません。`Environment=`/`EnvironmentFile=` はコンテナ **内プロセス** の環境変数を注入するだけで、`Image=`・`ContainerName=`・`Volume=`・`PublishPort=`・`Network=`・`Timezone=`・`HealthCmd=` といったユニット自体のディレクティブには反映されません。したがって:

- コンテナ名・ネットワーク名・DB 名/ユーザー名・データパスは `quadlets/*.container` に直接ハードコードされたままです。
- 本番の systemd ユニット名 (`redmine-db.service`/`redmine-web.service`) は Quadlet ファイルの **ファイル名** に由来します。`ContainerName=` を変えても `systemctl --user`・`Requires=`/`After=`・`journalctl` が参照するユニット名は変わりません。
- `HealthCmd=` の `/redmine/login` や [`host-apache/redmine-proxy.conf`](../host-apache/redmine-proxy.conf) の `ProxyPass /redmine ...` も同様に静的です。本番で `RAILS_RELATIVE_URL_ROOT` を変える場合は、`quadlets/redmine-web.container` の `Environment=`・`HealthCmd=` と `host-apache/redmine-proxy.conf` を手動で揃えて編集してください。

`.env` を実際に読むのは次の 3 か所だけです。

- 開発: `compose.dev.yaml`（Docker Compose がプロジェクトディレクトリの `.env` を自動読込）。
- 本番アプリ: `quadlets/redmine-web.container` の `EnvironmentFile=-/opt/redmine/containers/.env`（`SMTP_*`、`TZ` のみコンテナへ反映）。
- 本番運用スクリプト: `scripts/backup.sh` / `scripts/restore.sh` が同じ `/opt/redmine/containers/.env` を直接 `source` します（`DATA_ROOT`、`DB_NAME`、`DB_USER`、`DB_CONTAINER_NAME`、`WEB_CONTAINER_NAME`）。

### なぜイメージ / バージョンは集約しないのか

Redmine・PostgreSQL・プラグインのバージョン変更は、`git ls-remote --tags` でタグの実在を確認したうえで Containerfile を編集してリビルドする、レビュー前提の作業です（`CLAUDE.md` 参照）。`.env` で無審査に切り替えられるようにすると、この確認手順を素通りしてしまうため、意図的に対象外としています。
