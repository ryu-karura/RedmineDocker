# 設計書 — RedmineDocker (hwins スタック)

## 1. 概要

RedmineDocker は 2 つのコンテナが連携して Redmine 6.1.3 を動作させます。設計は [redmine.jp の Docker ガイド](https://blog.redmine.jp/articles/6_1/redmine-6_1-docker/) を踏襲しており、**公式** の `redmine` イメージを使い、認証情報は **ファイルベースのシークレット** で管理し、Compose / Quadlet の単一定義から運用するようにしています。Apache フロントエンドを `hwins-redmine` に統合し、この環境で求められる設定値に合わせています。

| 項目 | 値 |
|------|----|
| WSL ディストリビューション | `AlmaLinux9` |
| Linux 管理ユーザー | `hwins` |
| Linux ルートディレクトリ | `/opt/hwins` |
| Rootless Podman ネットワーク | `hwins-net` |
| Redmine イメージ | `docker.io/library/redmine:6.1.3` |
| PostgreSQL / PostGIS | `docker.io/postgis/postgis:18-3.6` |
| Apache フロントエンド | `httpd` 2.4（`hwins-redmine` に内蔵） |
| DB 名 / 所有者 | `redmine` / `redmine` |
| DB コンテナ | `hwins-db` |
| Redmine / Puma コンテナ | `hwins-redmine` |
| Web フロントコンテナ | `hwins-redmine` |
| Puma 内部ポート | `3000`（ホスト公開なし） |
| PostgreSQL 内部ポート | `5432`（ホスト公開なし） |
| Web ホストポート | `127.0.0.1:18080` |
| 公開 URL | `http://localhost/redmine/` |

## 2. トポロジー

```
  client ──443──► Host Apache ──/redmine──► hwins-redmine (Apache 2.4 + Puma :3000, :18080)
                                                    │ ProxyPass /redmine → 127.0.0.1:3000
                                                    ▼
                                             hwins-db (PostgreSQL 18 + PostGIS 3.6, :5432)
```

- `hwins-redmine` が `127.0.0.1:18080` にバインドされ、Apache フロントエンドが `/redmine` を Puma に転送します。ホスト側 Apache (`host-apache/redmine-proxy.conf`) が TLS を終端し、`/redmine` を転送します。
- PostgreSQL (5432) と Puma (3000) はホストには公開されません。
- コンテナは `hwins-net` ブリッジ上で通信し、`hwins-db` と `hwins-redmine` という名前で相互解決します。

## 3. コンテナの役割

### hwins-db (`containers/hwins-db/`)
- ベースイメージは `postgis/postgis:18-3.6` です。`POSTGRES_USER=redmine`、`POSTGRES_DB=redmine`、`POSTGRES_PASSWORD_FILE=/run/secrets/db_password` を設定します。
- 1 つの `redmine` ロールが `redmine` データベースを所有する（ブログの単一ユーザーモデル）構成です。`init-redmine.sh` は `postgis` / `postgis_topology` 拡張機能が存在することを確認します（冪等で、ベースイメージ側で初回初期化時に有効化済みです）。

### hwins-redmine (`containers/hwins-redmine/`)
- ベースイメージは `redmine:6.1.3`（公式、Ruby / Bundler / Puma / gem も含む）です。
- 日本語 CJK フォント（PDF / Gantt 用）、13 プラグイン + `farend_fancy` テーマ、`redmine_gtt` の webpack ビルド（yarn）を追加します。プラグイン gem は `bundle install` でイメージに焼き込みます。
- Apache フロントエンドを組み込み、`127.0.0.1:80` で受けた `/redmine` リクエストを Puma の `:3000` に転送します。Puma は `/redmine`（`RAILS_RELATIVE_URL_ROOT`）配下で `:3000` を Listen します。
- `entrypoint.sh` はシークレット解決（`*_FILE` 対応）、`config/database.yml` の描画（**`postgis`** アダプタ使用、redmine_gtt 必須）、`config/configuration.yml`（SMTP）の描画、DB 待機、コア / プラグインのマイグレーション実行、Apache の起動と `rails server`（Puma）起動を行います。


## 4. データと永続化

| ホスト上のパス（本番） | マウント先 | 内容 |
|------------------------|------------|------|
| `/opt/hwins/data/postgres/18` | hwins-db | PostgreSQL のデータディレクトリ |
| `/opt/hwins/data/redmine/files` | hwins-redmine | アップロードされた添付ファイル |
| `/opt/hwins/data/redmine/log` | hwins-redmine | Redmine の `production.log` |
| `/opt/hwins/backup/{db,files}` | host | バックアップ（Manual 参照） |

開発環境 (`compose.dev.yaml`) では、これらは名前付きボリューム (`pgdata`、`hwins_files`) になり、ホストの bind mount ではなくなります。プラグインとテーマはイメージに焼き込まれており、ボリュームマウントは行いません（ボリュームで上書きされるため）。

## 5. シークレット

ファイルとして保存される 2 つのシークレットで、プレーンな環境変数ではありません。

| シークレット | 利用先 | ソースファイル |
|--------------|--------|----------------|
| `db_password` | hwins-db, hwins-redmine | `secrets/db_password.txt` |
| `secret_key_base` | hwins-redmine | `secrets/secret_key_base.txt` |

`scripts/generate-secrets.sh` がファイルを作成します（mode 600、git ignore）。開発環境では Compose の `secrets:` で接続し、本番環境では `podman secret create` で登録して Quadlet の `Secret=` ディレクティブから参照し、`/run/secrets/<name>` にマウントします。

## 6. ユーザーと権限

- コンテナ内では公式イメージが持つユーザーをそのまま使用します: `redmine`（Redmine アプリ）と `postgres` / `redmine`（データベース）。独自の UID/GID リマップは行いません。これは、以前の rbenv ベースイメージよりも簡素化した設計です。
- ホスト側では `hwins` 管理ユーザーが `/opt/hwins` を所有します。rootless Podman ではコンテナユーザーが呼び出し元ユーザーのサブ UID 範囲にマップされ、ホストの bind mount 所有権は `:Z` SELinux relabel で管理します。

## 7. 補足 / 注意点

- Apache フロントエンドは `hwins-redmine` イメージに組み込まれ、個別の `hwins-static` イメージは不要になりました。
- 追加の Web プロキシコンテナを置かず、Redmine コンテナ内で Apache と Puma を運用しています。現状の設計では、堅牢性を優先して Redmine 側でアセット配信を行っています。
