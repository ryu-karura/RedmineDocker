# セットアップガイド — RedmineDocker (redmine スタック)

このガイドでは、2 つの導入パスを説明します。

- **開発環境** — Docker Compose（GitHub Codespaces または任意の Docker ホスト）。
- **本番環境** — AlmaLinux9 / RHEL9 上の rootless Podman + systemd Quadlets。

どちらも `containers/` から同じ 2 つのイメージをビルドし、オーケストレーションとデータ配置の違いだけで構成されています。

---

## 開発環境 (Docker Compose)

前提条件: Docker Engine + Docker Compose v2。

```bash
# 1. シークレットファイルを生成 (db_password.txt, secret_key_base.txt)
bash scripts/generate-secrets.sh

# 2. 2 コンテナをビルドして起動
docker compose -f compose.dev.yaml up --build -d
#    初回ビルドは遅めです: プラグイン gem を構築し、
#    redmine_gtt の webpack ビルドを実行します。

# 3. 起動状況を確認 (redmine-web の entrypoint でマイグレーションが実行されます)
docker compose -f compose.dev.yaml logs -f redmine-web

# 4. アプリケーションを開く
#    http://localhost:8080/redmine/     (初期ログイン: admin / admin)
```

rootless Podman/Docker は特権ポート (<1024) への bind にホスト側の準備
（`CAP_NET_BIND_SERVICE` の付与や `net.ipv4.ip_unprivileged_port_start` の変更）を
要求するため、ホスト準備なしで動かせる開発環境ではホスト側ポートを 8080 にしています
（本番の Quadlet ユニットはホスト側で 127.0.0.1:80 を使用します）。

`docker compose -f compose.dev.yaml down` で停止できます（名前付きボリュームは保持されます）。`down -v` を指定するとデータも破棄されます。

オプション — 追加の静的プロキシコンテナは不要です。`redmine-web` イメージに組み込まれた Apache フロントエンドをそのまま使います。
---

## 本番環境 (rootless Podman + Quadlets)

このスタックは `redmine` という非特権ユーザーで **rootless** で動作します。Podman の状態、シークレット、Quadlet ユニットはすべてユーザー単位で管理し、TLS 終端用のホスト Apache のみシステムサービスです。以下の手順は `sudo` 付きでない限り `redmine` ユーザーで実行します。

前提条件: AlmaLinux9 / RHEL9、Podman 4.9+、`redmine` ユーザー、TLS 終端用のホスト Apache。

### 1. データルートを用意する (初回のみ、root 権限が必要)

```bash
# /opt/redmine を redmine 所有にして、rootless コンテナが書き込めるようにします。
# さらに logout / reboot 後もコンテナを継続して動かすために linger を有効にします。
sudo mkdir -p /opt/redmine
sudo chown redmine:redmine /opt/redmine
sudo loginctl enable-linger redmine
```

### 2. リポジトリを配置し、データディレクトリを作成する (redmine ユーザーとして)

```bash
git clone <this-repo> /opt/redmine/containers
mkdir -p /opt/redmine/data/postgres/18 \
         /opt/redmine/data/redmine/files \
         /opt/redmine/data/redmine/log \
         /opt/redmine/backup/db /opt/redmine/backup/files
```

### 3. シークレットを生成して登録する (redmine ユーザーとして)

```bash
cd /opt/redmine/containers
bash scripts/generate-secrets.sh
podman secret create db_password     secrets/db_password.txt
podman secret create secret_key_base secrets/secret_key_base.txt
```

必要に応じて `.env.example` から `/opt/redmine/containers/.env` を作成し、SMTP 設定を入れます。

### 4. イメージをビルドする (redmine ユーザーとして)

```bash
cd /opt/redmine/containers
podman build -t localhost/redmine-db:18-3.6      containers/redmine-db
podman build -t localhost/redmine-web:6.1.3  containers/redmine-web
```

### 5. Quadlet ユニットを導入する (redmine ユーザーとして)

```bash
mkdir -p ~/.config/containers/systemd
cp quadlets/redmine.network           ~/.config/containers/systemd/
cp quadlets/redmine-db.container      ~/.config/containers/systemd/
cp quadlets/redmine-web.container ~/.config/containers/systemd/
systemctl --user daemon-reload
systemctl --user start redmine-db redmine-web
```

起動順序はユニットの `Requires=` / `After=` 依存関係で制御されます。
起動順: `redmine-db` → `redmine-web`、停止順は逆です。
`systemctl --user status redmine-web` と `podman healthcheck run redmine-web` で状態を確認できます。

### 6. ホスト Apache を設定する (TLS)

`host-apache/redmine-proxy.conf` を編集し（`YOUR_HOSTNAME` と証明書パスを設定）、次のコマンドを実行します。

```bash
sudo cp host-apache/redmine-proxy.conf /etc/httpd/conf.d/redmine-proxy.conf
sudo systemctl reload httpd
```

ホスト Apache は `https://<host>/redmine` を `127.0.0.1:80` に転送します。

### 7. 導入後の作業

- 公開 URL から `admin` / `admin` でログインし、パスワードを変更します。
- 必要に応じて日本語の初期データを読み込みます。
  ```bash
  podman exec -e RAILS_ENV=production redmine-web \
      bundle exec rake redmine:load_default_data REDMINE_LANG=ja
  ```
- ログローテーションを有効化します: `sudo cp logrotate/redmine /etc/logrotate.d/redmine-web`。
- バックアップのスケジュールは `docs/Manual.md` を参照してください。

---

## トラブルシューティング

| 症状 | 確認点 |
|------|--------|
| redmine-web が再起動する / マイグレーションに失敗する | `podman logs redmine-web` を確認し、`db_password` シークレットが redmine-db と一致しているか確認する |
| `/redmine` から 503 が返る | redmine-web のヘルスチェックがまだ通っていない（初回起動時にビルド / マイグレーションを実行中）ため、しばらく待つ |
| redmine_gtt のマップエラーが出る | redmine-db に PostGIS が入っており、database.yml が `postgis` アダプタを使っていることを確認する |
| Apache フロントエンドが起動しない | `redmine-web` コンテナのログと `apache2ctl -k start` の結果を確認する |
| ビルドが `git clone ... <plugin>` で失敗する（`Remote branch ... not found`） | 固定したタグが upstream に存在するか `git ls-remote --tags <url>` で確認する（`v` 接頭辞はリポジトリごとに異なる）。フォールバックなしの `--branch` は、存在しないタグを指定するとビルドが即失敗する |
| `bundle install` が `pg` のビルドで失敗する / `pg_config` が見つからない | redmine-web イメージに `libpq-dev`（`/usr/bin/pg_config` を提供）が入っているか確認する。`postgresql-client` だけでは `pg_config` は入らず、`postgis` アダプタが使う `pg` gem のネイティブ拡張をビルドできない |
