#!/bin/bash
# scripts/test-webflow.sh
#
# 稼働中の Redmine に対して、実際の Web UI (HTTP) を辿って
#   1. ログインできる
#   2. プロジェクトを作成でき、作成後のページに表示される
#   3. チケットを作成でき、作成後のページとチケット一覧に表示される
# ことを確認します。
#
# scripts/test-upgrade.sh の rails runner による検査がモデル層の確認なのに対し、
# こちらは「ブラウザで操作したときに実際に表示されるか」を確認するものです。
# アップグレードの前後で同じ検査を流し、データが引き継がれていることも見ます。
#
# 稼働中の Redmine であれば系列 (5 / 6 / 7) を問わず使えます。
# 単体でも使えますし、scripts/test-upgrade.sh から呼ばれます。
#
# 使い方:
#   # 作成して表示を確認する（--tag でこの実行分の識別子が決まります）
#   bash scripts/test-webflow.sh --url http://localhost:8081/redmine --tag before
#
#   # 過去の実行で作ったものが今も表示されるか確認する（アップグレード後の確認）
#   bash scripts/test-webflow.sh --url http://localhost:8080/redmine \
#       --tag after --expect-tag before
#
#   # 作成はせず、既存の表示確認だけ
#   bash scripts/test-webflow.sh --url http://localhost:8080/redmine \
#       --expect-tag before --skip-create
#
# ★ 初回ログイン時のパスワード強制変更に対応しています。
#   Redmine の admin は must_change_passwd が立っているため、初回ログイン後に
#   /my/password へ誘導されます。--password で入れず --new-password で入れた
#   場合はそのまま続行するので、アップグレード前後で同じ引数のまま使えます。
#
# 終了コード: 0 = 全項目 OK、1 = 失敗あり。

set -euo pipefail

BASE_URL=""
LABEL=""
LOGIN_USER="admin"
LOGIN_PASSWORD="admin"
NEW_PASSWORD="RedmineWebflow123!"
TAG=""
EXPECT_TAGS=()
SKIP_CREATE=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --url)          [ "$#" -ge 2 ] || { echo "--url requires an argument" >&2; exit 2; }; BASE_URL="$2"; shift ;;
        --url=*)        BASE_URL="${1#--url=}" ;;
        --label)        [ "$#" -ge 2 ] || { echo "--label requires an argument" >&2; exit 2; }; LABEL="$2"; shift ;;
        --label=*)      LABEL="${1#--label=}" ;;
        --user)         [ "$#" -ge 2 ] || { echo "--user requires an argument" >&2; exit 2; }; LOGIN_USER="$2"; shift ;;
        --user=*)       LOGIN_USER="${1#--user=}" ;;
        --password)     [ "$#" -ge 2 ] || { echo "--password requires an argument" >&2; exit 2; }; LOGIN_PASSWORD="$2"; shift ;;
        --password=*)   LOGIN_PASSWORD="${1#--password=}" ;;
        --new-password) [ "$#" -ge 2 ] || { echo "--new-password requires an argument" >&2; exit 2; }; NEW_PASSWORD="$2"; shift ;;
        --new-password=*) NEW_PASSWORD="${1#--new-password=}" ;;
        --tag)          [ "$#" -ge 2 ] || { echo "--tag requires an argument" >&2; exit 2; }; TAG="$2"; shift ;;
        --tag=*)        TAG="${1#--tag=}" ;;
        --expect-tag)   [ "$#" -ge 2 ] || { echo "--expect-tag requires an argument" >&2; exit 2; }; EXPECT_TAGS+=("$2"); shift ;;
        --expect-tag=*) EXPECT_TAGS+=("${1#--expect-tag=}") ;;
        --skip-create)  SKIP_CREATE=1 ;;
        -h|--help)      sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

[ -n "${BASE_URL}" ] || { echo "ERROR: --url is required (e.g. http://localhost:8081/redmine)" >&2; exit 2; }
BASE_URL="${BASE_URL%/}"
[ -n "${LABEL}" ] || LABEL="${BASE_URL}"
if [ "${SKIP_CREATE}" -eq 0 ] && [ -z "${TAG}" ]; then
    echo "ERROR: --tag is required unless --skip-create is given" >&2; exit 2
fi

log()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [webflow:${LABEL}] $*"; }
warn() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [webflow:${LABEL}] WARNING: $*" >&2; }

FAILURES=()
ok()   { log "  OK   - $*"; }
fail() { warn "  FAIL - $*"; FAILURES+=("$*"); }

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
COOKIES="${WORK_DIR}/cookies.txt"

# ── HTML から値を取り出すヘルパー ─────────────────────────────────────────────
# Rails のフォームは属性順が一定ではないので、非貪欲マッチで拾います。
csrf_token() {
    perl -0777 -ne '
        if (/<meta[^>]*\bname="csrf-token"[^>]*\bcontent="([^"]*)"/) { print $1; exit }
        if (/<input[^>]*\bname="authenticity_token"[^>]*\bvalue="([^"]*)"/) { print $1; exit }
        if (/<input[^>]*\bvalue="([^"]*)"[^>]*\bname="authenticity_token"/) { print $1; exit }
    ' "$1"
}

# <select name="FIELD"> の中で selected の option、無ければ最初の option の値。
# FIELD は生のフィールド名を渡すこと（perl 側で quotemeta するので
# 'issue[tracker_id]' のように [] をエスケープせずに渡す）。
select_value() {
    local file="$1"
    FIELD="$2" perl -0777 -ne '
        my $f = quotemeta($ENV{FIELD});
        if (/<select[^>]*\bname="$f"[^>]*>(.*?)<\/select>/s) {
            my $body = $1;
            if ($body =~ /<option[^>]*\bvalue="(\d+)"[^>]*\bselected/s) { print $1; exit }
            if ($body =~ /<option[^>]*\bvalue="(\d+)"/s)                { print $1; exit }
        }
    ' "${file}"
}

# name="FIELD" のチェックボックス/隠しフィールドの値をすべて返す（改行区切り）。
checkbox_values() {
    local file="$1"
    FIELD="$2" perl -0777 -ne '
        my $f = quotemeta($ENV{FIELD});
        while (/<input[^>]*\bname="$f"[^>]*>/gs) {
            my $tag = $&;
            next if $tag =~ /\btype="hidden"/;
            if ($tag =~ /\bvalue="([^"]*)"/) { print "$1\n" }
        }
    ' "${file}"
}

# GET してファイルへ保存し、HTTP ステータスを返す。
http_get() {
    local url="$1" out="$2"
    curl -sS -L -b "${COOKIES}" -c "${COOKIES}" \
        -o "${out}" -w '%{http_code}' "${url}"
}

# ページに文字列が含まれるか（HTML エスケープされる可能性のある記号は避けて渡すこと）。
page_contains() { grep -qF "$2" "$1"; }

# POST してリダイレクトも追う。
#
# ★ -X POST を付けてはいけません。
#   curl の -X はリダイレクト先にも同じメソッドを強制するため、-L と併用すると
#   302 の追跡が GET ではなく POST になります。Redmine ではこれが CSRF 検証に
#   引っかかって 422 を返し、その時点で**セッションが作り直されて未ログインに
#   戻る**ため、ログイン自体は成功しているのに以後の操作が匿名になります。
#   --data-urlencode を渡せば curl は自動的に POST になり、302 では正しく
#   GET へ切り替えます。
http_post() {
    local url="$1"; shift
    local out="$1"; shift
    curl -sS -L -b "${COOKIES}" -c "${COOKIES}" "$@" -o "${out}" -w '%{http_code}' "${url}"
}

# ── 1. ログイン ────────────────────────────────────────────────────────────────
attempt_login() {
    # usage: attempt_login <password>  -> 0 = ログイン成功
    local password="$1"
    : > "${COOKIES}"

    local code
    code="$(http_get "${BASE_URL}/login" "${WORK_DIR}/login_form.html")"
    [ "${code}" = "200" ] || { warn "GET /login returned ${code}"; return 1; }

    local token
    token="$(csrf_token "${WORK_DIR}/login_form.html")"
    [ -n "${token}" ] || { warn "could not find the CSRF token on /login"; return 1; }

    http_post "${BASE_URL}/login" "${WORK_DIR}/login_result.html" \
        --data-urlencode "authenticity_token=${token}" \
        --data-urlencode "back_url=${BASE_URL}/my/page" \
        --data-urlencode "username=${LOGIN_USER}" \
        --data-urlencode "password=${password}" \
        --data-urlencode "login=Login" >/dev/null

    # 強制パスワード変更に誘導された場合はここで変更してしまう。
    if grep -qE 'name="new_password"' "${WORK_DIR}/login_result.html"; then
        log "  password change required — setting the new password"
        local ptoken
        ptoken="$(csrf_token "${WORK_DIR}/login_result.html")"
        http_post "${BASE_URL}/my/password" "${WORK_DIR}/pwchange.html" \
            --data-urlencode "authenticity_token=${ptoken}" \
            --data-urlencode "password=${password}" \
            --data-urlencode "new_password=${NEW_PASSWORD}" \
            --data-urlencode "new_password_confirmation=${NEW_PASSWORD}" >/dev/null
    fi

    # ログインできていれば /my/account が 200 で自分のログイン名を含む。
    code="$(http_get "${BASE_URL}/my/account" "${WORK_DIR}/my_account.html")"
    [ "${code}" = "200" ] || return 1
    page_contains "${WORK_DIR}/my_account.html" "${LOGIN_USER}" || return 1
    return 0
}

log "Target: ${BASE_URL}"

if attempt_login "${LOGIN_PASSWORD}"; then
    ok "logged in as '${LOGIN_USER}'"
elif attempt_login "${NEW_PASSWORD}"; then
    # 前回の実行でパスワードを変更済みの場合はこちらで入れる。
    ok "logged in as '${LOGIN_USER}' (with the previously changed password)"
else
    fail "login as '${LOGIN_USER}'"
    warn "cannot continue without a session — aborting."
    warn "1 check(s) failed."
    exit 1
fi

# ログイン後のトップに「ログアウト」リンクがある = セッションが確立している。
code="$(http_get "${BASE_URL}/my/page" "${WORK_DIR}/my_page.html")"
if [ "${code}" = "200" ] && grep -qE '/logout|signout' "${WORK_DIR}/my_page.html"; then
    ok "authenticated session is established (/my/page shows a logout link)"
else
    fail "authenticated session on /my/page (HTTP ${code})"
fi

# ── 2. 既存データの表示確認（アップグレード後の引き継ぎ確認） ─────────────────
verify_tag() {
    local tag="$1"
    local identifier="webflow-${tag}"
    local project_name="Webflow 検証 ${tag}"
    local issue_subject="Webflow 検証チケット ${tag}"
    local code

    code="$(http_get "${BASE_URL}/projects/${identifier}" "${WORK_DIR}/verify_project_${tag}.html")"
    if [ "${code}" = "200" ] && page_contains "${WORK_DIR}/verify_project_${tag}.html" "${project_name}"; then
        ok "existing project '${identifier}' still displays (name shown)"
    else
        fail "existing project '${identifier}' displays (HTTP ${code})"
        return
    fi

    code="$(http_get "${BASE_URL}/projects/${identifier}/issues" "${WORK_DIR}/verify_issues_${tag}.html")"
    if [ "${code}" = "200" ] && page_contains "${WORK_DIR}/verify_issues_${tag}.html" "${issue_subject}"; then
        ok "existing issue of '${identifier}' still displays in the issue list"
    else
        fail "existing issue of '${identifier}' displays in the issue list (HTTP ${code})"
    fi
}

for t in ${EXPECT_TAGS[@]+"${EXPECT_TAGS[@]}"}; do
    log "Verifying data created by an earlier run (tag: ${t}) ..."
    verify_tag "${t}"
done

# ── 3. プロジェクト作成 → 表示確認 ────────────────────────────────────────────
if [ "${SKIP_CREATE}" -eq 1 ]; then
    log "--skip-create given — not creating a project/issue."
else
    IDENTIFIER="webflow-${TAG}"
    PROJECT_NAME="Webflow 検証 ${TAG}"
    ISSUE_SUBJECT="Webflow 検証チケット ${TAG}"
    ISSUE_DESCRIPTION="Web UI 経由で作成したチケットです（日本語の本文を含みます）。"

    log "Creating project '${IDENTIFIER}' ..."
    code="$(http_get "${BASE_URL}/projects/new" "${WORK_DIR}/project_new.html")"
    if [ "${code}" != "200" ]; then
        fail "GET /projects/new (HTTP ${code})"
    else
        ok "the new-project form is served"
        token="$(csrf_token "${WORK_DIR}/project_new.html")"

        # 有効化するモジュールとトラッカーはフォームから拾う（系列差を吸収するため）。
        TRACKER_ARGS=()
        while IFS= read -r tid; do
            [ -n "${tid}" ] || continue
            TRACKER_ARGS+=(--data-urlencode "project[tracker_ids][]=${tid}")
        done < <(checkbox_values "${WORK_DIR}/project_new.html" 'project[tracker_ids][]')

        http_post "${BASE_URL}/projects" "${WORK_DIR}/project_create.html" \
            --data-urlencode "authenticity_token=${token}" \
            --data-urlencode "project[name]=${PROJECT_NAME}" \
            --data-urlencode "project[identifier]=${IDENTIFIER}" \
            --data-urlencode "project[description]=Web UI 経由の検証用プロジェクト" \
            --data-urlencode "project[is_public]=1" \
            --data-urlencode "project[enabled_module_names][]=issue_tracking" \
            --data-urlencode "project[enabled_module_names][]=wiki" \
            "${TRACKER_ARGS[@]+"${TRACKER_ARGS[@]}"}" >/dev/null

        code="$(http_get "${BASE_URL}/projects/${IDENTIFIER}" "${WORK_DIR}/project_show.html")"
        if [ "${code}" = "200" ] && page_contains "${WORK_DIR}/project_show.html" "${PROJECT_NAME}"; then
            ok "project '${IDENTIFIER}' was created and its overview page displays the name"
        else
            fail "project '${IDENTIFIER}' is created and displayed (HTTP ${code})"
        fi
    fi

    # ── 4. チケット作成 → 表示確認 ────────────────────────────────────────────
    log "Creating an issue in '${IDENTIFIER}' ..."
    code="$(http_get "${BASE_URL}/projects/${IDENTIFIER}/issues/new" "${WORK_DIR}/issue_new.html")"
    if [ "${code}" != "200" ]; then
        fail "GET /projects/${IDENTIFIER}/issues/new (HTTP ${code})"
    else
        ok "the new-issue form is served"
        token="$(csrf_token "${WORK_DIR}/issue_new.html")"
        TRACKER_ID="$(select_value "${WORK_DIR}/issue_new.html" 'issue[tracker_id]')"
        STATUS_ID="$(select_value  "${WORK_DIR}/issue_new.html" 'issue[status_id]')"
        PRIORITY_ID="$(select_value "${WORK_DIR}/issue_new.html" 'issue[priority_id]')"

        ISSUE_ARGS=()
        [ -n "${TRACKER_ID}" ]  && ISSUE_ARGS+=(--data-urlencode "issue[tracker_id]=${TRACKER_ID}")
        [ -n "${STATUS_ID}" ]   && ISSUE_ARGS+=(--data-urlencode "issue[status_id]=${STATUS_ID}")
        [ -n "${PRIORITY_ID}" ] && ISSUE_ARGS+=(--data-urlencode "issue[priority_id]=${PRIORITY_ID}")

        http_post "${BASE_URL}/projects/${IDENTIFIER}/issues" "${WORK_DIR}/issue_create.html" \
            --data-urlencode "authenticity_token=${token}" \
            --data-urlencode "issue[subject]=${ISSUE_SUBJECT}" \
            --data-urlencode "issue[description]=${ISSUE_DESCRIPTION}" \
            "${ISSUE_ARGS[@]+"${ISSUE_ARGS[@]}"}" >/dev/null

        # 作成直後のページ（リダイレクト先）に件名が出ていること。
        if page_contains "${WORK_DIR}/issue_create.html" "${ISSUE_SUBJECT}"; then
            ok "the created issue is displayed on the page returned after submitting"
        else
            fail "the created issue is displayed right after submitting"
        fi

        # チケット一覧にも出ていること。
        code="$(http_get "${BASE_URL}/projects/${IDENTIFIER}/issues" "${WORK_DIR}/issue_list.html")"
        if [ "${code}" = "200" ] && page_contains "${WORK_DIR}/issue_list.html" "${ISSUE_SUBJECT}"; then
            ok "the created issue appears in the project's issue list"
        else
            fail "the created issue appears in the issue list (HTTP ${code})"
        fi
    fi
fi

# ── まとめ ─────────────────────────────────────────────────────────────────────
echo ""
if [ "${#FAILURES[@]}" -eq 0 ]; then
    log "All web-flow checks passed."
    exit 0
fi
warn "${#FAILURES[@]} check(s) failed:"
for f in "${FAILURES[@]}"; do warn "  - ${f}"; done
exit 1
