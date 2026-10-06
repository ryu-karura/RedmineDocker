# E2E テスト (Playwright)

`redmine-web` イメージをブラウザ経由で一通り触って確認する Playwright スクリプトです。
ビルドが通ることとコンテナが起動することは `scripts/test-stack.sh`（podman 前提）で確認できますが、
こちらは実際の画面操作（ログイン、プロジェクト作成、チケット登録、プラグイン画面、ユーザ管理など）を
ヘッドレスブラウザで再現し、スクリーンショットとして記録します。

実行すると `out/` に各ステップのスクリーンショット (`NN.png`) と結果一覧 (`results.json`) が
生成されます（`.gitignore` 対象、コミットしません）。結果は各 PR の説明に記載する運用とします。

## 前提

- このスクリプトは **データが空の新規スタック** に対して実行することを想定しています。
  プロジェクト識別子・ユーザー名が固定のため、既存データがあると重複エラーになります。
  本番や既存の開発スタックに対しては実行しないでください。
- ホスト側に Chromium の依存ライブラリ (`libatk-1.0.so.0` 等) が無い場合、Playwright の
  Chromium は起動できません。この環境では公式コンテナ `mcr.microsoft.com/playwright` を
  使って実行しています（下記手順参照）。

## 実行手順

1. テスト専用の分離スタックを起動する（`compose.dev.yaml` を使い、プロジェクト名・ボリューム名・
   ポートを本来の開発スタックと分ける）。例:

   ```bash
   cat > /tmp/e2e.env <<'EOF'
   COMPOSE_PROJECT_NAME=redmine702
   REDMINE_NETWORK=redmine702-net
   REDMINE_DB_CONTAINER=redmine702-db
   REDMINE_WEB_CONTAINER=redmine702-web
   REDMINE_DB_VOLUME=redmine702_pgdata
   REDMINE_FILES_VOLUME=redmine702_files
   REDMINE_WEB_HOST_PORT=18080
   REDMINE_WEB_CONTAINERFILE=Containerfile.v7
   REDMINE_WEB_BASE_IMAGE=docker.io/library/redmine:7.0.2
   REDMINE_WEB_IMAGE=localhost/redmine-web:7.0.2
   EOF

   docker compose --env-file /tmp/e2e.env -f compose.dev.yaml build redmine-web
   REDMINE_WEB_SERVER=passenger \
     docker compose --env-file /tmp/e2e.env -f compose.dev.yaml up -d --no-build

   # ヘルスチェックが healthy になるまで待つ
   curl -sf http://127.0.0.1:18080/redmine/login
   ```

2. Playwright（ホストに Chromium 依存ライブラリが無い場合はコンテナ経由）でテストを実行する。

   ```bash
   cd tests/e2e
   docker run --rm --network host --ipc host \
     -u "$(id -u)":"$(id -g)" -e HOME=/tmp \
     -v "$PWD":/work -w /work \
     mcr.microsoft.com/playwright:v1.62.1-noble node run.js
   ```

   結果は標準出力に `[PASS]`/`[FAIL]` で1行ずつ出力され、`out/` に各ステップのスクリーンショット
   (`NN.png`) と集計 (`results.json`) が保存されます（`out/` は git 管理外）。

3. 終わったら分離スタックを撤去する。

   ```bash
   docker compose --env-file /tmp/e2e.env -f compose.dev.yaml down -v
   ```

## 環境変数

- `BASE`: テスト対象の URL（既定 `http://127.0.0.1:18080/redmine`）。

## シナリオ構成

`run.js` 内で A〜I のシナリオに分けています。

- A. ログイン（初期 admin のパスワード変更強制、ログイン確認）
- B. 管理画面・設定（sudo モード、プラグイン一覧、REST API 有効化、テーマ変更）
- C. プロジェクト（複数プロジェクトの新規作成、全モジュール有効化）
- D. チケット（作成、ステータス変更、添付ファイル、PDF 出力、ガントチャート、かんばん）
- E. Wiki（mermaid マクロ、全文検索）
- F. ユーザ管理（ユーザ追加、プロジェクトメンバー追加）
- G. 一般ユーザ（誤パスワード、ログイン、権限確認、403、ログアウト）
- H. プラグイン画面（login_audit2, view_customize, issue_templates, logs, gtt, ip_filter, message_customize）
- I. REST API（Basic 認証での issues.json / projects.json 取得）

新しい確認項目を足す場合は `step()` 呼び出しを追加するだけで、スクリーンショットと
結果一覧 (`results.json`) に自動的に反映されます。
