# セットアップガイド — RedmineDocker (redmine スタック)

このガイドでは、次の 3 つの環境の導入手順を説明します。

- **開発環境 A — WSL (AlmaLinux 9.5 以上)** — Docker Compose（rootless Podman 上で `docker` CLI をエミュレート）。
- **開発環境 B — GitHub Codespaces** — Docker Compose（devcontainer の Docker-in-Docker）。
- **本番環境 — RHEL 9.5 以上** — rootless Podman + systemd Quadlets。

いずれも `containers/` から同じ 2 つのイメージをビルドし、オーケストレーションとデータ配置の違いだけで構成されています。

RHEL の実機がまだ用意できない場合は、本番環境と同じ Podman + Quadlets 手順を開発環境 A と同じ WSL (AlmaLinux 9.5 以上) 上でリハーサルできます。手順は本ガイド末尾の「本番相当の動作確認 (WSL)」の章を参照してください。

コンテナ名・DB 名・ユーザー名・SUB URI・ポートなどの設定値の一覧、および `.env` に集約できるもの/できないもの（本番の Quadlet はなぜ `.env` を読めないか）は `docs/Design.md` の「設定項目 (Configuration)」章を参照してください。

---

## 開発環境 A — WSL (AlmaLinux 9.5 以上)

前提条件:
- WSL2 上に AlmaLinux 9.5 以上のディストリビューションを導入済みであること。
- `/etc/wsl.conf` で systemd を有効化していること（Podman および `systemctl --user` が必要とします）。
  ```ini
  [boot]
  systemd=true
  ```
  変更後は Windows 側で `wsl --shutdown` を実行し、ディストリビューションを再起動してください。
- rootless Podman が導入済みであること。`docker` / `docker compose` コマンドは Podman を呼び出すエイリアスで、`docker compose` は内部で `podman-compose` を経由します。

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

WSL2 は `localhost` へのアクセスを自動的に Windows 側へフォワードするため、追加設定なしで Windows のブラウザから `http://localhost:8080/redmine/` を開けます。

rootless Podman は特権ポート (<1024) への bind にホスト側の準備（`CAP_NET_BIND_SERVICE` の付与や `net.ipv4.ip_unprivileged_port_start` の変更）を要求するため、ホスト準備なしで動かせる開発環境ではホスト側ポートを 8080 にしています（本番の Quadlet ユニットはホスト側で 127.0.0.1:80 を使用します）。

`docker compose -f compose.dev.yaml down` で停止できます（名前付きボリュームは保持されます）。`down -v` を指定するとデータも破棄されます。

オプション — 追加の静的プロキシコンテナは不要です。`redmine-web` イメージに組み込まれた Apache フロントエンドをそのまま使います。

オプション — コンテナ名・DB 名・ユーザー名・SUB URI・ポートなどを既定値から変更したい場合は `cp .env.example .env` としてから編集してください（`docker compose` が自動で読み込みます）。何もしなければ `.env.example` に書かれた既定値がそのまま使われます。詳細は `docs/Design.md` の「設定項目」章を参照してください。この手順は開発環境 A・B のどちらでも共通です。

---

## 開発環境 B — GitHub Codespaces

前提条件: なし。`.devcontainer/devcontainer.json` が `docker-in-docker` フィーチャーを自動プロビジョニングするため、開発環境 A のような systemd 有効化や rootless Podman の準備は不要です。

```bash
# Codespace 起動時に .devcontainer/post-create.sh が自動実行され、
# shellcheck の導入と docker / docker compose の疎通確認を行います。

# 1. シークレットファイルを生成
bash scripts/generate-secrets.sh

# 2. 2 コンテナをビルドして起動
docker compose -f compose.dev.yaml up --build -d

# 3. ポート 8080 が自動フォワードされます (devcontainer.json の forwardPorts)。
#    表示される通知、または "Ports" タブから開きます。
#    http://localhost:8080/redmine/     (初期ログイン: admin / admin)
```

開発環境 A (WSL) との違い: Codespaces は実 Docker Engine（docker-in-docker）で動作しますが、WSL 版は Podman 上で `docker` CLI をエミュレートして動作します。`compose.dev.yaml` はどちらでも同じファイルを使いますが、ビルド時間やヘルスチェックのタイミングがわずかに異なることがあります。

---

## 本番環境 (RHEL 9.5 以上 / rootless Podman + Quadlets)

このスタックは `redmine` という非特権ユーザーで **rootless** で動作します。Podman の状態、シークレット、Quadlet ユニットはすべてユーザー単位で管理し、TLS 終端用のホスト Apache のみシステムサービスです。以下の手順は `sudo` 付きでない限り `redmine` ユーザーで実行します。

前提条件: RHEL 9.5 以上（同等の互換ディストリビューションでも同一手順で動作します）、Podman 4.9+、`redmine` ユーザー、TLS 終端用のホスト Apache。

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

必要に応じて `.env.example` から `/opt/redmine/containers/.env` を作成し、SMTP 設定を入れます。この `.env` は `scripts/backup.sh`/`scripts/restore.sh` の DB 名・ユーザー名・データルートの既定値も上書きできますが、`quadlets/*.container` 自体のコンテナ名・DB 名・SUB URI 等はここでは変更できません（`docs/Design.md` の「設定項目」章に理由と一覧があります）。

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

## 本番相当の動作確認 (WSL: AlmaLinux 9.5 以上 で本番手順を検証する)

RHEL の実機がまだ用意できない場合、開発環境 A で使っているのと同じ WSL (AlmaLinux 9.5 以上) 上で、上の「本番環境」章の手順 1〜7 を **そのまま** 実行することで rootless Podman + systemd Quadlets 構成をリハーサルできます。イメージ・環境変数・シークレット・ヘルスチェックは開発/本番で共通なので、手順自体に変更はありません。ここでは WSL 特有の前提条件と、開発環境 A との切り替え手順のみを補足します。

### WSL 特有の前提条件

- 開発環境 A と同じく `/etc/wsl.conf` に `[boot] systemd=true` が必要です（`systemctl --user`、`loginctl enable-linger` が動作するため）。未設定の場合は本番環境の章の手順がすべて失敗します。
- ホスト Apache (TLS 終端) の証明書は、実ドメインがなければ自己署名証明書で代用してください。動作確認が目的であれば `curl -k` で疎通確認できます。
- WSL2 は `localhost` へのアクセスを自動的に Windows 側へフォワードするため、`redmine-web` がホスト側 `127.0.0.1:80` に公開されていれば、Windows から `https://localhost/redmine/`（ホスト Apache 経由）で到達できます。

### 開発環境 A ⇄ 本番相当環境の切り替え

同じ WSL ディストリビューション上で両方を試す場合、コンテナ名 (`redmine-db` / `redmine-web`) とネットワーク名 (`redmine-net`) が Compose と Quadlet の間で共通のため、**同時には起動できません**。切り替え前に必ず片方を停止してください。

開発 (Compose) → 本番相当 (Quadlets):
```bash
docker compose -f compose.dev.yaml down   # 名前付きボリュームは保持されます
# 続けて上の「本番環境」章の手順 1〜7 を実行します
```

本番相当 (Quadlets) → 開発 (Compose):
```bash
systemctl --user stop redmine-web redmine-db
docker compose -f compose.dev.yaml up --build -d
```

データは共有されません。開発環境 A は名前付きボリューム (`pgdata`, `redmine_files`) を使い、本番相当環境は `/opt/redmine/data` 配下の bind mount を使うため、切り替えてもデータは引き継がれません。

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
| `systemctl --user` が `Failed to connect to bus` 等で失敗する（WSL） | `/etc/wsl.conf` の `[boot] systemd=true` が設定されているか、設定後に `wsl --shutdown` で再起動したか確認する |
| `docker compose up` や `systemctl --user start` が "name is already in use" 等で失敗する | 開発環境と本番相当環境を同じ WSL 上で併用しようとしていないか確認する（コンテナ名/ネットワーク名が衝突するため、片方を停止してから切り替える。上の「開発環境 A ⇄ 本番相当環境の切り替え」を参照） |
