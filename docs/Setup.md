# セットアップガイド — RedmineDocker (redmine スタック)

このガイドでは、次の 3 つの環境の導入手順を説明します。

- **開発環境 A — WSL (AlmaLinux 9.5 以上)** — Docker Compose（Docker Engine 推奨。rootless Podman で `docker` CLI をエミュレートする構成でも動きます）。
- **開発環境 B — GitHub Codespaces** — Docker Compose（devcontainer の Docker-in-Docker）。
- **本番環境 — RHEL 9.5 以上** — Docker Engine + Docker Compose を systemd ユニット (`systemd/redmine.service`) から起動。

いずれも `containers/` から同じ 2 つのイメージをビルドし、同じ `compose.dev.yaml` を使います。本番はそこへ `compose.prod.yaml` を重ねて、データ配置（名前付きボリューム → `/opt/redmine/data` の bind mount）と公開ポート（8080 → 80）だけを差し替えます。

RHEL の実機がまだ用意できない場合は、本番と同じ Docker + systemd 手順を開発環境 A と同じ WSL (AlmaLinux 9.5 以上) 上でリハーサルできます。手順は本ガイド末尾の「本番相当の動作確認 (WSL)」の章を参照してください。

コンテナ名・DB 名・ユーザー名・SUB URI・ポート・データ配置などの設定値は、開発・本番とも `.env` 1 ファイルに集約されています。一覧は `docs/Design.md` の「設定パラメータ (.env)」章を参照してください。

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
- コンテナランタイムが導入済みであること。**本番と同じ Docker Engine（`docker-ce` + `docker-compose-plugin`）を推奨**します。rootless Podman で `docker` / `docker compose` をエイリアスとしてエミュレートする構成（`docker compose` が内部で `podman-compose` を呼ぶ）でも `compose.dev.yaml` は動きます。ただし本番オーバーレイ `compose.prod.yaml` は Compose 仕様の `!override` / `!reset` タグを使うため **Docker Compose v2.24 以上が必須**で、podman-compose では読み込めません（本番相当のリハーサルをする場合は Docker Engine を入れてください）。

```bash
# 0. 非シークレット設定 (.env) を作成 (初回のみ)
cp .env.example .env
# 必要に応じて REDMINE_SUBURI / REDMINE_WEB_HOST_PORT / REDMINE_WEB_SERVER / TZ / SMTP_* を編集
# Redmine 5 系 / 6 系を使う場合は REDMINE_VERSION と REDMINE_WEB_CONTAINERFILE を
# セットで変更します (既定は 7 系。docs/Design.md「Redmine シリーズの切り替え」参照)

# 1. シークレットファイルを生成 (db_password.txt, secret_key_base.txt)
bash scripts/generate-secrets.sh

# 2. 2 コンテナをビルドして起動
docker compose -f compose.dev.yaml up --build -d
#    初回ビルドは遅めです: プラグイン gem を構築します
#    (5 系はさらに redmine_gtt の webpack ビルドが走ります)。

# 3. 起動状況を確認 (redmine-web の entrypoint でマイグレーションが実行されます)
docker compose -f compose.dev.yaml logs -f redmine-web

# 4. アプリケーションを開く
#    http://localhost:8080/redmine/     (初期ログイン: admin / admin)
```

任意: `.env.example` の値で展開される実際の compose 設定を確認する場合:

```bash
docker compose --env-file .env.example -f compose.dev.yaml config
```

WSL2 は `localhost` へのアクセスを自動的に Windows 側へフォワードするため、追加設定なしで Windows のブラウザから `http://localhost:8080/redmine/` を開けます。

rootless Podman / rootless Docker は特権ポート (<1024) への bind にホスト側の準備（`CAP_NET_BIND_SERVICE` の付与や `net.ipv4.ip_unprivileged_port_start` の変更）を要求するため、ホスト準備なしで動かせる開発環境ではホスト側ポートを 8080 にしています（本番は root の docker デーモンで動かすため、`compose.prod.yaml` が 127.0.0.1:80 を使います）。

`docker compose -f compose.dev.yaml down` で停止できます（名前付きボリュームは保持されます）。`down -v` を指定するとデータも破棄されます。

オプション — 追加の静的プロキシコンテナは不要です。`redmine-web` イメージに組み込まれた Apache フロントエンドをそのまま使います。

オプション — コンテナ名・DB 名・ユーザー名・SUB URI・ポートなどを既定値から変更したい場合は `cp .env.example .env` としてから編集してください（`docker compose` が自動で読み込みます）。何もしなければ `.env.example` に書かれた既定値がそのまま使われます。詳細は `docs/Design.md` の「設定パラメータ」章を参照してください。この手順は開発環境 A・B のどちらでも共通です。

---

## 開発環境 B — GitHub Codespaces

前提条件: なし。`.devcontainer/devcontainer.json` が `docker-in-docker` フィーチャーを自動プロビジョニングするため、開発環境 A のような systemd 有効化や rootless Podman の準備は不要です。

```bash
# Codespace 起動時に .devcontainer/post-create.sh が自動実行され、
# shellcheck の導入と docker / docker compose の疎通確認を行います。

# 0. 非シークレット設定 (.env) を作成 (初回のみ)
cp .env.example .env
# 必要に応じて CODESPACES_WEB_HOST_PORT / REDMINE_SUBURI / TZ / SMTP_* を編集

# 1. シークレットファイルを生成
bash scripts/generate-secrets.sh

# 2. 2 コンテナをビルドして起動 (Codespaces 用 80 公開オーバーライドを併用)
docker compose -f compose.dev.yaml -f compose.codespaces.yaml up --build -d

# 3. ポート 80 が自動フォワードされます (devcontainer.json の forwardPorts)。
#    "Ports" タブで Port 80 の Visibility を Public にすると外部公開できます。
#    http://localhost/redmine/     (初期ログイン: admin / admin)
```

開発環境 A (WSL) との違い: Codespaces は実 Docker Engine（docker-in-docker）で動作します。WSL 版も Docker Engine を入れれば同じですが、Podman 上で `docker` CLI をエミュレートする構成でも動きます。`compose.dev.yaml` はどちらでも同じファイルを使いますが、ビルド時間やヘルスチェックのタイミングがわずかに異なることがあります。

---

## 本番環境 (RHEL 9.5 以上 / Docker Engine + systemd)

本番は **Docker Engine + Docker Compose** でコンテナを動かし、起動・停止は **systemd ユニット
`redmine.service`** が担当します（`systemd/redmine.service`）。TLS 終端のホスト Apache も
システムサービスです。以下の手順は root 権限（`sudo`）で実行します。

前提条件:

- RHEL 9.5 以上（同等の互換ディストリビューションでも同一手順）。
- **Docker Engine + Compose プラグイン v2.24 以上**。`compose.prod.yaml` が Compose 仕様の
  `!override` / `!reset` タグを使うため、この版が下限です（`docker compose version` で確認）。
- TLS 終端用のホスト Apache（`httpd`）。

### 1. Docker Engine を導入する (初回のみ)

RHEL には Docker Engine が同梱されていないため、Docker 公式リポジトリから導入します。

```bash
sudo dnf -y install dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
sudo dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
docker compose version    # v2.24 以上であることを確認
```

`podman-docker`（`docker` コマンドを podman に橋渡しするパッケージ）が入っていると
`/usr/bin/docker` が衝突します。導入済みなら `sudo dnf remove podman-docker` で外してください
（`podman` 本体は残して構いません）。

### 2. データルートを用意する (初回のみ)

```bash
sudo mkdir -p /opt/redmine/containers \
              /opt/redmine/data/postgres/18 \
              /opt/redmine/data/redmine/files \
              /opt/redmine/data/redmine/log \
              /opt/redmine/backup/db /opt/redmine/backup/files

# 添付ファイルとログは、コンテナ内の redmine ユーザー (uid:gid = 999:999) が書き込みます。
# docker の bind mount は UID を変換しないため、ホスト側の所有者を合わせます。
sudo chown -R 999:999 /opt/redmine/data/redmine
```

PostgreSQL のデータディレクトリ (`/opt/redmine/data/postgres/18`) は root 所有のままで構いません。
`postgres` イメージの entrypoint が root で起動して所有者を調整します。

### 3. リポジトリを配置し、.env とシークレットを用意する

```bash
sudo git clone <this-repo> /opt/redmine/containers
cd /opt/redmine/containers
sudo cp .env.example .env
# 必要に応じて TZ / SMTP_* / REDMINE_SUBURI / REDMINE_VERSION などを編集

sudo bash scripts/generate-secrets.sh    # secrets/*.txt (mode 600) を生成
```

`.env` は**開発・本番で同じ 1 ファイル**です。`systemd/redmine.service` は
`WorkingDirectory=/opt/redmine/containers` で `docker compose` を実行するため、コンテナ名・
DB 名・SUB URI・データ配置 (`REDMINE_DATA_ROOT`) まで含めてここで設定できます
（`docs/Design.md`「設定パラメータ (.env)」）。

シークレットは compose の file secret としてそのままマウントされるため、登録コマンドは不要です
（`secrets/db_password.txt` → コンテナ内 `/run/secrets/db_password`）。**`secrets/` は
git-ignore 済みで、リポジトリには含めません。**

公開ポートは `compose.prod.yaml` の既定で `127.0.0.1:80` です（ホスト Apache の転送先）。
`.env` の `REDMINE_WEB_HOST_PORT`（開発用の 8080）は本番には影響しません。変更したい場合は
`.env` の `REDMINE_PROD_HOST_PORT` を設定し、`host-apache/redmine-proxy.conf` の転送先も
合わせてください。

### 4. イメージをビルドする

```bash
cd /opt/redmine/containers
set -a; source .env; set +a
sudo docker build -t "${REDMINE_DB_IMAGE}" \
    --build-arg DB_BASE_IMAGE="${REDMINE_DB_BASE_IMAGE}" containers/redmine-db
sudo docker build -t "${REDMINE_WEB_IMAGE}" \
    -f "containers/redmine-web/${REDMINE_WEB_CONTAINERFILE}" \
    --build-arg WEB_BASE_IMAGE="${REDMINE_WEB_BASE_IMAGE}" containers/redmine-web
```

`docker compose -f compose.dev.yaml -f compose.prod.yaml build` でも同じイメージができます
（`compose.dev.yaml` の `build:` 定義を使うため、タグ名も `.env` の値になります）。

`redmine-web` は Redmine のメジャーバージョン系列ごとに Containerfile が分かれています
（`Containerfile.v5` / `Containerfile.v6` / `Containerfile.v7`（既定））。`.env` の
`REDMINE_VERSION` と `REDMINE_WEB_CONTAINERFILE` は必ずセットで設定してください
（対応するプラグイン構成の違いは `docs/Design.md`「Redmine シリーズの切り替え」参照）。

### 5. systemd ユニットを導入して起動する

```bash
sudo cp /opt/redmine/containers/systemd/redmine.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now redmine
systemctl status redmine
```

`ExecStart` は `docker compose -f compose.dev.yaml -f compose.prod.yaml up -d --wait` です。
`--wait` は全コンテナが `healthy` になるまで戻らないため、**`systemctl start` の完了 =
スタック稼働開始**になります。初回起動はマイグレーションとアセット生成で数分かかります
（`TimeoutStartSec=900`）。

起動順序は compose の `depends_on: {redmine-db: {condition: service_healthy}}` が保証します
（`redmine-db` → `redmine-web`、停止は逆順）。そのため systemd ユニットは 1 つだけです。
コンテナ単位の状態・ログは compose で確認します。

```bash
cd /opt/redmine/containers
sudo docker compose -f compose.dev.yaml -f compose.prod.yaml ps
sudo docker compose -f compose.dev.yaml -f compose.prod.yaml logs -f redmine-web
```

アプリサーバーは 7 系（既定）では **Passenger（Apache + mod_passenger）が既定** です。
Puma（Apache → ProxyPass → Puma :3000）に戻す場合は `.env` に `REDMINE_WEB_SERVER=puma` と
書いて `sudo systemctl reload redmine` を実行します（イメージには両方式が入っているため
再ビルドは不要です）。5 系 / 6 系のイメージ既定は `puma` です。切り替え後の確認方法と
トラブルシューティングは `docs/Manual.md`「ケース E」を参照してください。

**`mod_passenger` は 3 系列とも Debian trixie の 6.0.26** です。7 系のベースは
Ruby 4.0 ですが、この版のままで動作することを実機で確認しています（根拠は
`docs/Design.md`「9. Redmine シリーズの切り替え」）。外部 APT リポジトリも
追加スイートも使いません。本番へ出す前に、開発環境で
`bash scripts/test-stack.sh --series 7`（`--web-server` 省略時は 7 系の既定 =
passenger で検証します）を実行して動作を確認してください。

### 6. ホスト Apache を設定する (TLS)

`host-apache/redmine-proxy.conf` を編集し（`YOUR_HOSTNAME` と証明書パスを設定）、次のコマンドを実行します。

```bash
sudo cp host-apache/redmine-proxy.conf /etc/httpd/conf.d/redmine-proxy.conf
sudo systemctl reload httpd
```

ホスト Apache は `https://<host>/redmine` を `127.0.0.1:80` に転送します。

### 7. 導入後の作業

- 公開 URL から `admin` / `admin` でログインし、パスワードを変更します。
- 日本語の初期データ（トラッカー/ロール/ワークフロー等）は `redmine-web` の
  `entrypoint.sh` が初回起動時（trackers テーブルが空のとき）に自動投入します
  （`REDMINE_LOAD_DEFAULT_DATA=1` / `REDMINE_DEFAULT_DATA_LANG=ja` が既定）。
  2 回目以降の起動では既存データがあるためスキップされ、無効化したい場合は
  `.env` に `REDMINE_LOAD_DEFAULT_DATA=0` と書きます。
- ログローテーションを有効化します: `sudo cp logrotate/redmine /etc/logrotate.d/redmine-web`。
- バックアップは root の cron に登録します（`scripts/backup.sh` は docker を操作します）:
  `sudo crontab -e` で
  `0 2 * * * /opt/redmine/containers/scripts/backup.sh >> /opt/redmine/backup/backup.log 2>&1`。
  詳細は `docs/Manual.md` を参照してください。
- 再起動時の自動復帰は `systemctl enable redmine`（ユニット）と compose の
  `restart: always`（コンテナ）の二段で担保されます。

---

## 本番相当の動作確認 (WSL: AlmaLinux 9.5 以上 で本番手順を検証する)

RHEL の実機がまだ用意できない場合、開発環境 A で使っているのと同じ WSL (AlmaLinux 9.5 以上) 上で、上の「本番環境」章の手順 1〜7 を **そのまま** 実行することで Docker Engine + systemd 構成をリハーサルできます。イメージ・環境変数・シークレット・ヘルスチェックは開発/本番で共通なので、手順自体に変更はありません。ここでは WSL 特有の前提条件と、開発環境 A との切り替え手順のみを補足します。

### WSL 特有の前提条件

- `/etc/wsl.conf` に `[boot] systemd=true` が必要です（`systemctl` でユニットを動かすため）。未設定の場合は本番環境の章の手順 5 以降がすべて失敗します。
- **Docker Engine が必要です**（手順 1 と同じ手順で導入できます）。`docker` が rootless Podman のエイリアスになっている環境では、`compose.prod.yaml` の `!override` / `!reset` を podman-compose が解釈できないため本番相当の検証はできません。
- ホスト Apache (TLS 終端) の証明書は、実ドメインがなければ自己署名証明書で代用してください。動作確認が目的であれば `curl -k` で疎通確認できます。
- WSL2 は `localhost` へのアクセスを自動的に Windows 側へフォワードするため、`redmine-web` がホスト側 `127.0.0.1:80` に公開されていれば、Windows から `https://localhost/redmine/`（ホスト Apache 経由）で到達できます。

### 開発環境 A ⇄ 本番相当環境の切り替え

同じ WSL ディストリビューション上で両方を試す場合、コンテナ名 (`redmine-db` / `redmine-web`) とネットワーク名 (`redmine-net`) が開発用 compose と本番用 compose で共通のため、**同時には起動できません**。切り替え前に必ず片方を停止してください。

開発 (compose.dev.yaml のみ) → 本番相当 (compose.dev.yaml + compose.prod.yaml):
```bash
docker compose -f compose.dev.yaml down   # 名前付きボリュームは保持されます
# 続けて上の「本番環境」章の手順 1〜7 を実行します
```

本番相当 → 開発:
```bash
sudo systemctl stop redmine
docker compose -f compose.dev.yaml up --build -d
```

データは共有されません。開発環境 A は名前付きボリューム (`pgdata`, `redmine_files`) を使い、本番相当環境は `/opt/redmine/data` 配下の bind mount を使うため、切り替えてもデータは引き継がれません。

---

## トラブルシューティング

| 症状 | 確認点 |
|------|--------|
| redmine-web が再起動する / マイグレーションに失敗する | `docker compose -f compose.dev.yaml -f compose.prod.yaml logs redmine-web` を確認し、`secrets/db_password.txt` が redmine-db 初期化時のものと一致しているか確認する |
| `/redmine` から 503 が返る | redmine-web のヘルスチェックがまだ通っていない（初回起動時にビルド / マイグレーションを実行中）ため、しばらく待つ |
| redmine_gtt のマップエラーが出る | redmine-db に PostGIS が入っており、database.yml が `postgis` アダプタを使っていることを確認する |
| Apache フロントエンドが起動しない | `redmine-web` コンテナのログと `apache2ctl -k start` の結果を確認する |
| ビルドが `git clone ... <plugin>` で失敗する（`Remote branch ... not found`） | 固定したタグが upstream に存在するか `git ls-remote --tags <url>` で確認する（`v` 接頭辞はリポジトリごとに異なる）。フォールバックなしの `--branch` は、存在しないタグを指定するとビルドが即失敗する |
| `bundle install` が `pg` のビルドで失敗する / `pg_config` が見つからない | redmine-web イメージに `libpq-dev`（`/usr/bin/pg_config` を提供）が入っているか確認する。`postgresql-client` だけでは `pg_config` は入らず、`postgis` アダプタが使う `pg` gem のネイティブ拡張をビルドできない |
| `systemctl` が `Failed to connect to bus` 等で失敗する（WSL） | `/etc/wsl.conf` の `[boot] systemd=true` が設定されているか、設定後に `wsl --shutdown` で再起動したか確認する |
| `docker compose up` や `systemctl start redmine` が "name is already in use" 等で失敗する | 開発環境と本番相当環境を同じホスト上で併用しようとしていないか確認する（コンテナ名/ネットワーク名が衝突するため、片方を停止してから切り替える。上の「開発環境 A ⇄ 本番相当環境の切り替え」を参照） |
| 添付ファイルのアップロードや `production.log` の出力が `Permission denied` になる | bind mount 先の所有者がコンテナ内 redmine (999:999) になっているか確認する（`sudo chown -R 999:999 /opt/redmine/data/redmine`）。docker の bind mount は UID を変換しません。マウント直下だけは `entrypoint.sh` が起動時に合わせますが、リストア等で中身が root 所有になった場合は再帰的に直す必要があります |
| `compose.prod.yaml` の読み込みで `!override` / `!reset` 付近の YAML エラーになる | Docker Compose v2.24 以上か確認する（`docker compose version`）。podman-compose はこのタグに対応していないため、本番オーバーレイは Docker Compose 専用です |
| `systemctl start redmine` が `docker: command not found` で失敗する | Docker Engine が入っているか、`podman-docker` が `/usr/bin/docker` を握っていないか確認する（手順 1 参照） |
| `systemctl start redmine` がタイムアウトする | `--wait` は全コンテナが healthy になるまで待ちます。初回起動はマイグレーションとアセット生成で数分かかるため、`docker compose ... logs -f redmine-web` で進行中か確認する。進んでいない場合はログのエラーを確認 |
