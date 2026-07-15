# セットアップガイド — RedmineDocker (hwins スタック)

このガイドでは、2 つの導入パスを説明します。

- **開発環境** — Docker Compose（GitHub Codespaces または任意の Docker ホスト）。
- **本番環境** — AlmaLinux9 / RHEL9 上の rootless Podman + systemd Quadlets。

どちらも `containers/` から同じ 3 つのイメージをビルドし、オーケストレーションとデータ配置の違いだけで構成されています。

---

## 開発環境 (Docker Compose)

前提条件: Docker Engine + Docker Compose v2。

```bash
# 1. シークレットファイルを生成 (db_password.txt, secret_key_base.txt)
bash scripts/generate-secrets.sh

# 2. 3 コンテナをビルドして起動
docker compose -f compose.dev.yaml up --build -d
#    初回ビルドは遅めです: プラグイン gem を構築し、
#    redmine_gtt の webpack ビルドを実行します。

# 3. 起動状況を確認 (hwins-redmine の entrypoint でマイグレーションが実行されます)
docker compose -f compose.dev.yaml logs -f hwins-redmine

# 4. アプリケーションを開く
#    http://localhost:18080/redmine/     (初期ログイン: admin / admin)
```

`docker compose -f compose.dev.yaml down` で停止できます（名前付きボリュームは保持されます）。`down -v` を指定するとデータも破棄されます。

オプション — ネットワーク接続のあるホストで httpd のベースイメージを digest 固定します：

```bash
bash scripts/pin-static-image.sh
```

---

## 本番環境 (rootless Podman + Quadlets)

このスタックは `hwins` という非特権ユーザーで **rootless** で動作します。Podman の状態、シークレット、Quadlet ユニットはすべてユーザー単位で管理し、TLS 終端用のホスト Apache のみシステムサービスです。以下の手順は `sudo` 付きでない限り `hwins` ユーザーで実行します。

前提条件: AlmaLinux9 / RHEL9、Podman 4.9+、`hwins` ユーザー、TLS 終端用のホスト Apache。

### 1. データルートを用意する (初回のみ、root 権限が必要)

```bash
# /opt/hwins を hwins 所有にして、rootless コンテナが書き込めるようにします。
# さらに logout / reboot 後もコンテナを継続して動かすために linger を有効にします。
sudo mkdir -p /opt/hwins
sudo chown hwins:hwins /opt/hwins
sudo loginctl enable-linger hwins
```

### 2. リポジトリを配置し、データディレクトリを作成する (hwins ユーザーとして)

```bash
git clone <this-repo> /opt/hwins/containers
mkdir -p /opt/hwins/data/postgres/18 \
         /opt/hwins/data/redmine/files \
         /opt/hwins/data/redmine/log \
         /opt/hwins/backup/db /opt/hwins/backup/files
```

### 3. シークレットを生成して登録する (hwins ユーザーとして)

```bash
cd /opt/hwins/containers
bash scripts/generate-secrets.sh
podman secret create db_password     secrets/db_password.txt
podman secret create secret_key_base secrets/secret_key_base.txt
```

必要に応じて `.env.example` から `/opt/hwins/containers/.env` を作成し、SMTP 設定を入れます。

### 4. イメージをビルドする (hwins ユーザーとして)

```bash
cd /opt/hwins/containers
# まず httpd の digest を pin します (推奨):
bash scripts/pin-static-image.sh
podman build -t localhost/hwins-db:18-3.6      containers/hwins-db
podman build -t localhost/hwins-redmine:6.1.3  containers/hwins-redmine
podman build -t localhost/hwins-static:2.4     containers/hwins-static
```

### 5. Quadlet ユニットを導入する (hwins ユーザーとして)

```bash
mkdir -p ~/.config/containers/systemd
cp quadlets/hwins.network           ~/.config/containers/systemd/
cp quadlets/hwins-db.container      ~/.config/containers/systemd/
cp quadlets/hwins-redmine.container ~/.config/containers/systemd/
cp quadlets/hwins-static.container  ~/.config/containers/systemd/
systemctl --user daemon-reload
systemctl --user start hwins-db hwins-redmine hwins-static
```

起動順序はユニットの `Requires=` / `After=` 依存関係で制御されます。
起動順: `hwins-db` → `hwins-redmine` → `hwins-static`、停止順は逆です。
`systemctl --user status hwins-redmine` と `podman healthcheck run hwins-redmine` で状態を確認できます。

### 6. ホスト Apache を設定する (TLS)

`host-apache/redmine-proxy.conf` を編集し（`YOUR_HOSTNAME` と証明書パスを設定）、次のコマンドを実行します。

```bash
sudo cp host-apache/redmine-proxy.conf /etc/httpd/conf.d/redmine-proxy.conf
sudo systemctl reload httpd
```

ホスト Apache は `https://<host>/redmine` を `127.0.0.1:18080` に転送します。

### 7. 導入後の作業

- 公開 URL から `admin` / `admin` でログインし、パスワードを変更します。
- 必要に応じて日本語の初期データを読み込みます。
  ```bash
  podman exec -e RAILS_ENV=production hwins-redmine \
      bundle exec rake redmine:load_default_data REDMINE_LANG=ja
  ```
- ログローテーションを有効化します: `sudo cp logrotate/redmine /etc/logrotate.d/hwins-redmine`。
- バックアップのスケジュールは `docs/Manual.md` を参照してください。

---

## トラブルシューティング

| 症状 | 確認点 |
|------|--------|
| hwins-redmine が再起動する / マイグレーションに失敗する | `podman logs hwins-redmine` を確認し、`db_password` シークレットが hwins-db と一致しているか確認する |
| `/redmine` から 503 が返る | hwins-redmine のヘルスチェックがまだ通っていない（初回起動時にビルド / マイグレーションを実行中）ため、しばらく待つ |
| redmine_gtt のマップエラーが出る | hwins-db に PostGIS が入っており、database.yml が `postgis` アダプタを使っていることを確認する |
| Static イメージが pin されていない | ネットワーク接続のあるホストで `scripts/pin-static-image.sh` を実行する |
