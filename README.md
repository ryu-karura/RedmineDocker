# RedmineDocker (redmine スタック)

**RHEL 9.5 以上（本番）/ WSL AlmaLinux 9.5 以上・GitHub Codespaces（開発）上で rootless Podman を使う Redmine 6.1 のコンテナ基盤**

このリポジトリでは、運用時は systemd Quadlet で管理する 2 コンテナ構成の Redmine 基盤を構築・展開・運用し、開発時は Docker Compose で動かします。設計は [redmine.jp の Docker ガイド](https://blog.redmine.jp/articles/6_1/redmine-6_1-docker/) を踏襲し、公式 Redmine イメージと Docker/Podman シークレットを用いた 2 層構成へ拡張したものです。

---

## アーキテクチャ

```
  client ──443──► Host Apache ──/redmine──► redmine-web (Apache 2.4 + Redmine 6.1.3)
                  (TLS, HSTS)   127.0.0.1:80   │  REDMINE_WEB_SERVER で分岐
                                                  │
                                    puma (既定) ──┴── passenger
                                        │                │
                                        ▼                ▼
                            Puma :3000            mod_passenger が
                            (ProxyPass /redmine)   Redmine を直接起動
                                        └────────┬───────┘
                                                  ▼
                                           redmine-db (PostgreSQL 18 + PostGIS 3.6)
                                           :5432   DB=redmine / owner=redmine
```

| コンテナ | ビルドコンテキスト | イメージ | 役割 | 公開先 |
|----------|-------------------|----------|------|--------|
| `redmine-db` | `containers/redmine-db/` | `postgis/postgis:18-3.6` | PostgreSQL 18 + PostGIS 3.6 | なし（内部 5432） |
| `redmine-web` | `containers/redmine-web/` | `docker.io/library/redmine:6.1.3` + plugin stack + Apache 2.4 | Redmine アプリ、Apache フロントエンド、Puma | `127.0.0.1:80` |

`redmine-web` だけがループバックに公開されます。ホスト側 Apache が 443 で TLS を終端し、`/redmine` をその先へ転送します。PostgreSQL (5432) と Puma (3000) はホストからは到達できません。

- **アプリサーバー:** `.env` の `REDMINE_WEB_SERVER` で `puma`（既定: Apache → ProxyPass → Puma :3000）と `passenger`（Apache + mod_passenger が直接起動、:3000 なし）を切り替えられます。イメージには両方が同梱されているため、値の変更とコンテナ再起動のみで反映されます（再ビルド不要）。詳細は [docs/Design.md](docs/Design.md) を参照してください。
- **ネットワーク:** `redmine-net`（Podman Quadlet のネットワーク / Compose のブリッジ）。コンテナは名前で相互に解決します。
- **公開 URL:** `http://localhost/redmine/`（サブ URI `/redmine`）。
- **シークレット:** `db_password` と `secret_key_base` はファイルベースのシークレットです（開発では Docker シークレット、本番では Podman シークレット）。プレーンな環境変数ではなく、`scripts/generate-secrets.sh` で生成します。

---

## コンポーネントのバージョン

| コンポーネント | 値 |
|---------------|----|
| OS | 本番: RHEL9.5+ / 開発 A: WSL上のAlmaLinux9.5+ / 開発 B: Codespaces |
| Redmine | 6.1.3 (`docker.io/library/redmine:6.1.3`) |
| PostgreSQL | 18 + PostGIS 3.6 (`postgis/postgis:18-3.6`) |
| Web 層 | Apache httpd 2.4 (redmine-web 内蔵) |
| Ruby / Puma | 公式 Redmine イメージに同梱 |
| Passenger | Debian trixie の `libapache2-mod-passenger` (6.0.26)、`REDMINE_WEB_SERVER=passenger` 用 |
| Node.js / Yarn | Debian `nodejs` + Yarn 1.22.22（redmine_gtt の webpack ビルド用） |

`redmine-web` に焼き込まれているプラグイン (13 個): redmine_wiki_lists, redmine_banner,
redmine_issues_panel, redmica_ui_extension, redmine_ip_filter,
redmine_message_customize, redmine_issue_templates, view_customize, redmine_logs,
redmine_login_audit2, redmine_wiki_extensions, redmine_solid_queue, redmine_gtt。
テーマ: farend_fancy。`redmine_gtt` には PostGIS と `postgis` アダプタが必要です（`containers/redmine-web/database.yml.tmpl` で設定）。

---

## リポジトリ構成

```
RedmineDocker/
├── README.md
├── docs/                         # 設計 / セットアップ / 運用手順
├── containers/
│   ├── redmine-db/                 # PostgreSQL 18 + PostGIS 3.6
│   └── redmine-web/            # Redmine 6.1.3 + plugin/theme スタック + Apache フロントエンド
├── quadlets/                     # 本番用 Podman Quadlet ユニット
│   ├── redmine.network
│   ├── redmine-db.container
│   └── redmine-web.container
├── host-apache/                  # ホスト Apache のリバースプロキシ (TLS)
├── scripts/                      # generate-secrets, backup, restore
├── logrotate/                    # ログローテーション
├── compose.dev.yaml              # 開発用 Docker Compose
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

WSL は Podman 上で `docker` CLI をエミュレートして動作し、Codespaces は devcontainer の docker-in-docker（実 Docker Engine）で動作します。コマンドは共通ですが、実行環境の違いは `docs/Setup.md` を参照してください。

`.env.example` には、コンテナ名・ネットワーク名・SUBURI・公開ポート・イメージタグ・ベースイメージタグの既定値が含まれます。通常は `cp .env.example .env` で開始し、必要項目だけ変更してください。

---

## クイックスタート (本番 / Podman + Quadlets)

本番環境は RHEL 9.5 以上を想定しています。実機がまだ用意できない場合は、開発環境 A と同じ WSL (AlmaLinux 9.5 以上) 上で以下と同じ手順をリハーサルできます（`docs/Setup.md` の「本番相当の動作確認 (WSL)」を参照）。

1. RHEL 9.5 以上のホスト上の `/opt/redmine/containers` にこのリポジトリをクローンします。
2. `.env` を作成して必要な値を編集します（最低限、SMTP/TZ の確認を推奨）。
```
cp .env.example .env
```
3. `bash scripts/generate-secrets.sh` を実行し、シークレットを登録します。
```
podman secret create db_password secrets/db_password.txt
podman secret create secret_key_base secrets/secret_key_base.txt
```
登録確認
> podman secret ls
4. イメージをビルドし Quadlet ユニットを導入します。詳細は `docs/Setup.md` を参照してください。

---

## ドキュメント

- **[設計書](docs/Design.md)** — アーキテクチャ、ネットワーク、データ配置、シークレット。
- **[セットアップ手順](docs/Setup.md)** — 本番 / 開発環境の導入手順。
- **[運用手順](docs/Manual.md)** — バックアップ、復旧、ログ管理。

## ライセンス

[LICENSE](LICENSE) を参照してください。
