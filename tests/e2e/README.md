# E2E テスト (Playwright)

`redmine-web` イメージをブラウザ経由で一通り触って確認する Playwright スクリプトです。
ビルドと起動の確認は `scripts/test-stack.sh`（curl ベース）で行えますが、こちらは実際の画面操作
（ログイン、プロジェクト作成、チケット登録、プラグイン画面、ユーザ管理など）をヘッドレスブラウザで
再現し、各ステップのスクリーンショットと結果を残します。

CI（`.github/workflows/e2e.yml`）では puma / passenger の両モードで同じスクリプトを実行します。

## 前提

- **データが空の新規スタック** に対して実行することを想定しています。プロジェクト識別子・ユーザー名が
  固定のため、既存データがあると重複エラーになります。本番や既存の開発スタックに対しては実行しないでください。
- 既定値（`.env.example` 相当）は Redmine 7.0.2 / `REDMINE_WEB_SERVER=passenger` / 15 プラグインです。
  テストは 15 プラグインが管理画面の一覧に出ることも確認します。

## 実行手順

1. 分離スタックを起動する（`compose.dev.yaml` を使い、プロジェクト名・ボリューム名・ポートを
   手元の開発スタックと分ける）。`.env` は読まれないようにプロジェクト名などを `--env-file` で指定します。

   ```bash
   cat > /tmp/e2e.env <<'EOF'
   COMPOSE_PROJECT_NAME=redmine-e2e
   REDMINE_NETWORK=redmine-e2e-net
   REDMINE_DB_CONTAINER=redmine-e2e-db
   REDMINE_WEB_CONTAINER=redmine-e2e-web
   REDMINE_DB_VOLUME=redmine_e2e_pgdata
   REDMINE_FILES_VOLUME=redmine_e2e_files
   REDMINE_WEB_HOST_PORT=18080
   EOF

   bash scripts/generate-secrets.sh          # 既存の secrets/ は上書きされません
   docker compose --env-file /tmp/e2e.env -f compose.dev.yaml build redmine-web
   REDMINE_WEB_SERVER=passenger \
     docker compose --env-file /tmp/e2e.env -f compose.dev.yaml up -d --no-build

   # healthy になるまで待つ
   docker inspect --format '{{.State.Health.Status}}' redmine-e2e-web
   ```

   puma で確認する場合は `REDMINE_WEB_SERVER=puma` にします。**モードを変えるたびに**
   `docker compose ... down -v` で DB を作り直してください（同じ DB に 2 回流すると重複エラーになります）。

2. テストを実行する。ホストに Chromium の依存ライブラリが無い場合でも、公式コンテナで動きます。
   `npm install` は実行のたびにコンテナ内で行うため、`node_modules` はコミットされません。

   ```bash
   cd tests/e2e
   docker run --rm --network host --ipc host \
     -u "$(id -u)":"$(id -g)" -e HOME=/tmp \
     -v "$PWD":/work -w /work \
     mcr.microsoft.com/playwright:v1.62.1-noble \
     sh -c "npm install --no-audit --no-fund --silent && node run.js"
   ```

   標準出力に `[PASS]` / `[FAIL]` が 1 行ずつ出ます。最後の行は `DONE pass=N fail=M` です。
   `out/` に各ステップのスクリーンショット（`NN.png`）と `results.json` が保存されます（git 管理外）。

3. 終わったら分離スタックを撤去する。

   ```bash
   docker compose --env-file /tmp/e2e.env -f compose.dev.yaml down -v
   ```

## 環境変数

- `BASE`: テスト対象の URL（既定 `http://127.0.0.1:18080/redmine`）。ホストポートを変えた場合に指定します。

## シナリオ構成

`run.js` 内で A〜I のシナリオに分けています（現在 48 ステップ）。

- A. ログイン（初期 admin のパスワード変更強制、ログイン確認）
- B. 管理画面・設定（sudo モード、プラグイン一覧 14 件、REST API 有効化、テーマ変更）
- C. プロジェクト（複数プロジェクトの新規作成、全モジュール有効化）
- D. チケット（作成、ステータス変更、添付ファイル、PDF 出力、ガントチャート、かんばん）
- E. Wiki（mermaid マクロ、全文検索）
- F. ユーザ管理（ユーザ追加、プロジェクトメンバー追加）
- G. 一般ユーザ（誤パスワード、ログイン、権限確認、403、ログアウト）
- H. プラグイン（login_audit2, view_customize, issue_templates, logs, xlsx 出力, banner, gtt, ip_filter, message_customize, cascading_custom_fields）
- I. REST API（Basic 認証での issues.json / projects.json 取得）

新しい確認項目を足す場合は `step()` 呼び出しを追加します。スクリーンショットと `results.json` に自動で反映されます。

## 既知の注意点

- Redmine 7 系は管理画面の操作前にパスワード再確認（sudo モード）を要求します。ログイン直後は猶予期間で
  要求されないことがあるため、シナリオ 05 は「要求された場合は突破、されなければ記録のみ」にしています。
- 設定画面の REST API タブは Redmine 7 で `integrations` に改名されています（`settings?tab=integrations`）。
- メンバー追加の検索結果は、Ajax 絞り込み中の古い一覧を拾わないよう「候補が 1 件に収束するまで待つ」実装です。
