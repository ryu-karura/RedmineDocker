#!/bin/bash
# scripts/test-webflow.sh
#
# 稼働中の Redmine に対して、実際の Web UI (HTTP) を辿って
#   1. ログインできる
#   2. プロジェクトを作成でき、作成後のページに表示される
#   3. チケットを作成でき、作成後のページとチケット一覧に表示される
# ことを確認します。
#
# rails runner によるモデル層の確認とは違い、「ブラウザで操作したときに実際に
# 表示されるか」を確認するものです。
#
# 稼働中の Redmine であれば系列 (5 / 6 / 7) を問わず使えます。
#
# 使い方:
#   # 作成して表示を確認する（--tag でこの実行分の識別子が決まります）
#   bash scripts/test-webflow.sh --url http://localhost:8080/redmine --tag run1
#
# ★ 初回ログイン時のパスワード強制変更に対応しています。
#   Redmine の admin は must_change_passwd が立っているため、初回ログイン後に
#   /my/password へ誘導されます。--password で入れず --new-password で入れた
#   場合（前回の実行でパスワードを変更済みの場合）はそのまま続行します。
#
# 終了コード: 0 = 全項目 OK、1 = 失敗あり。

set -euo pipefail

BASE_URL=""
LABEL=""
LOGIN_USER="admin"
LOGIN_PASSWORD="admin"
NEW_PASSWORD="RedmineWebflow123!"
TAG=""

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
        -h|--help)      sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

[ -n "${BASE_URL}" ] || { echo "ERROR: --url is required (e.g. http://localhost:8081/redmine)" >&2; exit 2; }
BASE_URL="${BASE_URL%/}"
[ -n "${LABEL}" ] || LABEL="${BASE_URL}"
[ -n "${TAG}" ] || { echo "ERROR: --tag is required (it names the project/issue created by this run)" >&2; exit 2; }

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
# ブラウザ同様 Accept: text/html を送る。curl 既定の "*/*" だと、respond_to の
# 先頭にある形式が選ばれ、redmine_gtt 入りのイメージでは /projects/:id が
# GeoJSON（本文 "null"、content-disposition: attachment）で返ってしまう。
ACCEPT_HTML='Accept: text/html,application/xhtml+xml'

http_get() {
    local url="$1" out="$2"
    curl -sS -L -H "${ACCEPT_HTML}" -b "${COOKIES}" -c "${COOKIES}" \
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
    curl -sS -L -H "${ACCEPT_HTML}" -b "${COOKIES}" -c "${COOKIES}" "$@" -o "${out}" -w '%{http_code}' "${url}"
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
    # 未ログインでもログインページ（/my/account からのリダイレクト先）にログイン名が
    # 現れることがある（view_customize が埋め込む JS コンテキストの "admin":false など）。
    # ログアウトリンクの有無でもセッション確立を確かめる。
    grep -qE '/logout|signout' "${WORK_DIR}/my_account.html" || return 1
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

# ── 2. プロジェクト作成 → 表示確認 ────────────────────────────────────────────
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

# ── 3. チケット作成 → 表示確認 ────────────────────────────────────────────
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

# ── まとめ ─────────────────────────────────────────────────────────────────────
echo ""
if [ "${#FAILURES[@]}" -eq 0 ]; then
    log "All web-flow checks passed."
    exit 0
fi
warn "${#FAILURES[@]} check(s) failed:"
for f in "${FAILURES[@]}"; do warn "  - ${f}"; done
exit 1
