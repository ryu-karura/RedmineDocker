# RedmineDocker (redmine スタック)

**RHEL 9.5 以上（本番）/ WSL AlmaLinux 9.5 以上・GitHub Codespaces（開発）で Docker Compose を使う Redmine 7.0 のコンテナ基盤**

このリポジトリでは、2 コンテナ構成の Redmine 基盤を構築・展開・運用します。開発も本番も同じ Docker Compose 定義 (`compose.dev.yaml`) を使い、本番はそこへ `compose.prod.yaml` を重ねて systemd ユニット (`systemd/redmine.service`) から起動します。設計は [redmine.jp の Docker ガイド](https://blog.redmine.jp/articles/6_1/redmine-6_1-docker/) を踏襲し、公式 Redmine イメージとファイルベースのシークレットを用いた 2 層構成へ拡張したものです。

---

## アーキテクチャ

```
  client ──443──► Host Apache ──/redmine──► redmine-web (Apache 2.4 + Redmine 7.0.1)
                  (TLS, HSTS)   127.0.0.1:80   │  REDMINE_WEB_SERVER で分岐
                                                  │
                               passenger (既定) ──┴── puma
                                        │                │
                                        ▼                ▼
                            mod_passenger が        Puma :3000
                            Redmine を直接起動      (ProxyPass /redmine)
                                        └────────┬───────┘
                                                  ▼
                                           redmine-db (PostgreSQL 18 + PostGIS 3.6)
                                           :5432   DB=redmine / owner=redmine
```

| コンテナ | ビルドコンテキスト | イメージ | 役割 | 公開先 |
|----------|-------------------|----------|------|--------|
| `redmine-db` | `containers/redmine-db/` | `postgis/postgis:18-3.6` | PostgreSQL 18 + PostGIS 3.6 | なし（内部 5432） |
| `redmine-web` | `containers/redmine-web/` | `docker.io/library/redmine:7.0.1` + plugin stack + Apache 2.4 | Redmine アプリ、Apache フロントエンド、Puma | `127.0.0.1:80` |

`redmine-web` だけがループバックに公開されます。ホスト側 Apache が 443 で TLS を終端し、`/redmine` をその先へ転送します。PostgreSQL (5432) と Puma (3000) はホストからは到達できません。

- **アプリサーバー:** `.env` の `REDMINE_WEB_SERVER` で `passenger`（既定: Apache + mod_passenger が直接起動、:3000 なし）と `puma`（Apache → ProxyPass → Puma :3000）を切り替えられます。既定が `passenger` なのは既定シリーズの 7 系（`Containerfile.v7`）で、5 系 / 6 系のイメージ既定は `puma` です。イメージには両方が同梱されているため、値の変更とコンテナ再起動のみで反映されます（再ビルド不要）。詳細は [docs/Design.md](docs/Design.md) を参照してください。
- **ネットワーク:** `redmine-net`（Compose が作る bridge ネットワーク）。コンテナは名前で相互に解決します。
- **公開 URL:** `http://localhost/redmine/`（サブ URI `/redmine`）。
- **シークレット:** `db_password` と `secret_key_base` はファイルベースのシークレットです（開発・本番とも compose の file secret として `/run/secrets/` にマウント）。プレーンな環境変数ではなく、`scripts/generate-secrets.sh` で生成します。

---

## コンポーネントのバージョン

| コンポーネント | 値 |
|---------------|----|
| OS | 本番: RHEL9.5+ / 開発 A: WSL上のAlmaLinux9.5+ / 開発 B: Codespaces |
| Redmine | 7.0.1 (`docker.io/library/redmine:7.0.1`)、5 系 / 6 系にも切り替え可 |
| PostgreSQL | 18 + PostGIS 3.6 (`postgis/postgis:18-3.6`) |
| Web 層 | Apache httpd 2.4 (redmine-web 内蔵) |
| Ruby / Puma | 公式 Redmine イメージに同梱 |
| Passenger | `REDMINE_WEB_SERVER=passenger`（7 系の既定）用。3 系列とも Debian trixie の `libapache2-mod-passenger` (6.0.26) |
| Node.js / Yarn | Debian `nodejs` + Yarn 1.22.22（5 系のみ。redmine_gtt 6.0.3 の webpack ビルド用） |

`redmine-web` に焼き込まれているプラグイン (6 系は 14 個): redmine_wiki_lists, redmine_banner,
redmine_issues_panel, redmica_ui_extension, redmine_ip_filter,
redmine_message_customize, redmine_issue_templates, view_customize, redmine_logs,
redmine_login_audit2, redmine_wiki_extensions, redmine_solid_queue, redmine_gtt,
redmine_xlsx_format_issue_exporter。
テーマ: farend_fancy。`redmine_gtt` には PostGIS と `postgis` アダプタが必要です（`containers/redmine-web/database.yml.tmpl` で設定）。

### Redmine のメジャーバージョン系列

`redmine-web` は系列ごとに Containerfile を分けています。プラグイン / テーマの対応
バージョンが系列ごとに違うためです。切り替えは `.env` の `REDMINE_VERSION` と
`REDMINE_WEB_CONTAINERFILE` をセットで変更し、再ビルドします
（起動できるのは一度に 1 系列だけ。詳細と対応調査の根拠は
[docs/Design.md](docs/Design.md)「Redmine シリーズの切り替え」）。

| 系列 | Containerfile | ベースイメージ | プラグイン | 備考 |
|------|---------------|----------------|-----------|------|
| Redmine 5 | `Containerfile.v5` | `redmine:5.1.12` | 12 個 | 公式イメージは 5.1.12 で打ち切り（Ruby 3.2 EOL）。login_audit2 / solid_queue は 5.1 で導入不可 |
| Redmine 6 | `Containerfile.v6` | `redmine:6.1.4` | 14 個 | `.env` で切り替え |
| Redmine 7 | `Containerfile.v7` | `redmine:7.0.1` | 14 個 | **既定**。banner は 7.0 対応が master にのみ入っているため master を pin |

> ⚠ **既定は Redmine 7 系です。** 6 系で運用中のスタックに対して `.env` を置かずに
> `docker compose -f compose.dev.yaml up --build -d` を実行すると、7 系イメージが
> ビルドされ起動時に 6.1 → 7.0 のマイグレーションが**片道で**走ります。6 系のまま
> 動かし続けるなら `.env` に `REDMINE_VERSION=6.1.4` と
> `REDMINE_WEB_CONTAINERFILE=Containerfile.v6` を明示してください（手順は
> [docs/Manual.md](docs/Manual.md)「Redmine のメジャーバージョン系列切り替え」）。

既存の Redmine 5.1.1 + MySQL からの移行（例外的な作業）は
**[アップグレード手順](docs/Upgrade.md)** を参照してください。

---

## リポジトリ構成

```
RedmineDocker/
├── README.md
├── docs/                         # 設計 / セットアップ / 運用手順
├── containers/
│   ├── redmine-db/                 # PostgreSQL 18 + PostGIS 3.6
│   ├── redmine-db-mysql/           # MySQL 8.0 CE（移行元の再現専用）
│   └── redmine-web/            # Redmine + plugin/theme スタック + Apache フロントエンド
│       ├── Containerfile.v5        #   Redmine 5.1.12 用
│       ├── Containerfile.v6        #   Redmine 6.1.4 用
│       ├── Containerfile.v7        #   Redmine 7.0.1 用（既定）
│       └── Containerfile.v5-mysql  #   Redmine 5.1.1 + MySQL（移行元の再現専用）
├── systemd/                      # 本番用 systemd ユニット
│   └── redmine.service             #   docker compose で 2 コンテナを起動/停止
├── host-apache/                  # ホスト Apache のリバースプロキシ (TLS)
├── scripts/                      # generate-secrets, backup, restore
│   ├── migrate-mysql-to-postgres.sh  # MySQL → PostgreSQL 18 コンバート
│   ├── test-upgrade.sh               # 5.1.1+MySQL → PG18 → 7.0.1 の通し検証
│   └── pgloader/                     # pgloader コマンドファイル + シーケンス再設定 SQL
├── logrotate/                    # ログローテーション
├── compose.dev.yaml              # Docker Compose 本体（開発・本番共通）
├── compose.prod.yaml             # 本番オーバーレイ（bind mount + 127.0.0.1:80）
├── compose.legacy.yaml           # 移行元 (Redmine 5.1.1 + MySQL 8.0) 再現用
├── .devcontainer/                # GitHub Codespaces / VS Code dev container
├── .env.example                  # SMTP / TZ などのオプション設定テンプレート
└── .gitignore
```

---

## クイックスタート (開発)

開発環境は 2 つあります。手順の細部（前提条件、systemd 設定など）は `docs/Setup.md` を参照してください。

**開発環境 A — WSL (AlmaLinux 9.5 以上)**、**開発環境 B — GitHub Codespaces** のどちらも同じコマンドで起動します。

```bash
# 0. 非シークレット設定 (.env) を作成（初回のみ）
cp .env.example .env
# 必要に応じて REDMINE_SUBURI / REDMINE_WEB_HOST_PORT / TZ / SMTP_* を編集

bash scripts/generate-secrets.sh                 # ./secrets/*.txt を生成
docker compose -f compose.dev.yaml up --build -d  # 初回ビルドは重めです（プラグインと webpack の構築）
# その後、転送ポートを開きます:
#   http://localhost:8080/redmine/   (初期ログイン: admin / admin)
```

`compose.dev.yaml` は名前付きボリュームを使うため、`docker compose down` してもデータは残ります。

WSL は Docker Engine を推奨（Podman 上で `docker` CLI をエミュレートする構成でも `compose.dev.yaml` は動きます）、Codespaces は devcontainer の docker-in-docker で動作します。コマンドは共通ですが、実行環境の違いは `docs/Setup.md` を参照してください。

`.env.example` には、コンテナ名・ネットワーク名・SUBURI・公開ポート・イメージタグ・ベースイメージタグの既定値が含まれます。通常は `cp .env.example .env` で開始し、必要項目だけ変更してください。

---

## クイックスタート (本番 / Docker Engine + systemd)

本番環境は RHEL 9.5 以上を想定しています。実機がまだ用意できない場合は、開発環境 A と同じ WSL (AlmaLinux 9.5 以上) 上で以下と同じ手順をリハーサルできます（`docs/Setup.md` の「本番相当の動作確認 (WSL)」を参照）。

1. Docker Engine と Compose プラグイン (v2.24 以上) を導入します（RHEL は Docker 公式リポジトリから）。
2. `/opt/redmine/containers` にこのリポジトリをクローンし、データルートを作成します。
```
sudo mkdir -p /opt/redmine/data/{postgres/18,redmine/files,redmine/log} /opt/redmine/backup/{db,files}
sudo chown -R 999:999 /opt/redmine/data/redmine   # コンテナ内 redmine (uid:gid 999)
```
3. `.env` を作成して必要な値を編集し、シークレットを生成します（登録コマンドは不要 — compose の file secret としてそのまま使われます）。
```
cp .env.example .env
bash scripts/generate-secrets.sh
```
4. イメージをビルドし、systemd ユニットを導入して起動します。詳細は `docs/Setup.md` を参照してください。
```
sudo docker compose -f compose.dev.yaml -f compose.prod.yaml build
sudo cp systemd/redmine.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now redmine
```

---

## ドキュメント

- **[設計書](docs/Design.md)** — アーキテクチャ、ネットワーク、データ配置、シークレット。
- **[セットアップ手順](docs/Setup.md)** — 本番 / 開発環境の導入手順。
- **[運用手順](docs/Manual.md)** — バックアップ、復旧、ログ管理。
- **[アップグレード手順](docs/Upgrade.md)** — Redmine 5.1.1 + MySQL 8.0 からの移行（DB コンバートと Redmine 7 へのアップグレード）。

## ライセンス

[LICENSE](LICENSE) を参照してください。
