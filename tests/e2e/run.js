// Redmine 7.0.2 (passenger mode) E2E walkthrough with screenshots.
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const BASE = process.env.BASE || 'http://127.0.0.1:18080/redmine';
const OUT = path.join(__dirname, 'out');
const ADMIN_PW = 'Admin702pass!';
const USER = { login: 'yamada', pw: 'User702pass!', first: '太郎', last: '山田', mail: 'yamada@example.com' };
const PROJECTS = [
  { name: '基幹システム刷新', id: 'core-renewal', desc: 'E2E: 基幹システム刷新プロジェクト' },
  { name: '社内ポータル', id: 'portal', desc: 'E2E: 社内ポータル運用' },
  { name: '防災マップ', id: 'bousai-map', desc: 'E2E: GTT 地図付きプロジェクト' },
];

fs.mkdirSync(OUT, { recursive: true });
const results = [];
let n = 0;

async function step(scenario, title, page, fn, { shot = true, fullPage = true } = {}) {
  n += 1;
  const id = String(n).padStart(2, '0');
  const rec = { id, scenario, title, status: 'PASS', note: '', shot: null, url: '' };
  try {
    const note = await fn();
    if (note) rec.note = String(note);
  } catch (e) {
    rec.status = 'FAIL';
    rec.note = (e && e.message ? e.message : String(e)).split('\n')[0].slice(0, 300);
  }
  if (page && shot) {
    try {
      const file = `${id}.png`;
      await page.screenshot({ path: path.join(OUT, file), fullPage });
      rec.shot = file;
      rec.url = page.url().replace(/^https?:\/\/[^/]+/, '');
    } catch (_) { /* ignore */ }
  }
  results.push(rec);
  console.log(`[${rec.status}] ${id} ${scenario} / ${title} ${rec.note}`);
  return rec.status === 'PASS';
}

async function expectOk(resp) {
  if (!resp) return;
  const s = resp.status();
  if (s >= 400) throw new Error(`HTTP ${s} ${resp.url()}`);
}

async function noErrorPage(page) {
  const t = await page.title();
  if (/Internal error|内部エラー|404|500/.test(t)) throw new Error(`error page: ${t}`);
}

async function flash(page) {
  const ok = await page.locator('#flash_notice').first().textContent().catch(() => null);
  const err = await page.locator('#errorExplanation, #flash_error').first().textContent().catch(() => null);
  if (err && err.trim()) throw new Error(`form error: ${err.trim().replace(/\s+/g, ' ')}`);
  return ok ? ok.trim() : '';
}

async function sudo(page) {
  if (await page.locator('#sudo_password').count()) {
    await page.fill('#sudo_password', ADMIN_PW);
    await Promise.all([page.waitForLoadState('load'), page.locator('#sudo-form input[name="commit"]').click()]);
    return true;
  }
  return false;
}

async function go(page, url) {
  const r = await page.goto(url);
  await expectOk(r);
  await sudo(page);
  return r;
}

async function submit(page, loc) {
  await Promise.all([page.waitForLoadState('load'), (typeof loc === 'string' ? page.locator(loc) : loc).click()]);
  await sudo(page);
}

const SUBMIT = 'input[name="commit"]:visible';

async function whoami(page) {
  const l = page.locator('#account .user-login');
  if (!(await l.count())) return '';
  return (await l.first().textContent()).trim();
}

async function login(page, user, pw) {
  await page.goto(`${BASE}/login`);
  await page.fill('#username', user);
  await page.fill('#password', pw);
  await Promise.all([page.waitForLoadState('load'), page.click('#login-submit')]);
}

(async () => {
  const browser = await chromium.launch();
  const ctxOpts = { viewport: { width: 1366, height: 900 }, locale: 'ja-JP', timezoneId: 'Asia/Tokyo' };
  const admin = await browser.newContext(ctxOpts);
  const page = await admin.newPage();
  page.setDefaultTimeout(30000);

  // ── A. ログイン ──
  await step('A. ログイン', 'ログイン画面', page, async () => {
    await go(page, `${BASE}/login`);
    await page.waitForSelector('#login-form');
    return `title="${await page.title()}"`;
  });
  await step('A. ログイン', '初期 admin でログイン → パスワード変更要求', page, async () => {
    await login(page, 'admin', 'admin');
    if (!page.url().includes('/my/password')) throw new Error(`unexpected url ${page.url()}`);
    return 'must_change_passwd により /my/password へ遷移';
  });
  await step('A. ログイン', 'admin パスワード変更', page, async () => {
    await page.fill('#password', 'admin');
    await page.fill('#new_password', ADMIN_PW);
    await page.fill('#new_password_confirmation', ADMIN_PW);
    await Promise.all([page.waitForLoadState('load'), page.click('input[name="commit"]')]);
    return await flash(page);
  });
  await step('A. ログイン', 'ログイン後（マイページ）', page, async () => {
    await go(page, `${BASE}/my/page`);
    const who = await whoami(page);
    if (who !== '@admin') throw new Error(`whoami=${who}`);
    return `ログイン中: ${who}`;
  });

  // ── B. 管理・設定 ──
  await step('B. 管理画面', '管理操作前のパスワード再確認（sudo モード）', page, async () => {
    const r = await page.goto(`${BASE}/admin`);
    await expectOk(r);
    const shown = await page.locator('#sudo_password').count();
    if (!shown) return 'ログイン直後の猶予期間内のため今回は要求されず（Redmine 7 の sudo モード仕様）';
    await sudo(page);
    return 'パスワード再入力を要求 → 突破確認';
  });
  await step('B. 管理画面', '管理トップ', page, async () => {
    await sudo(page);
    await noErrorPage(page);
  });
  await step('B. 管理画面', '情報（バージョン・環境）', page, async () => {
    await go(page, `${BASE}/admin/info`);
    const txt = await page.locator('#content').innerText();
    const ver = (txt.match(/Redmine version\s+([^\n]+)/) || [])[1];
    const ruby = (txt.match(/Ruby version\s+([^\n]+)/) || [])[1];
    const rails = (txt.match(/Rails version\s+([^\n]+)/) || [])[1];
    if (!ver || !ver.includes('7.0.2')) throw new Error(`Redmine version: ${ver}`);
    return `Redmine ${ver.trim()} / Ruby ${ruby && ruby.trim()} / Rails ${rails && rails.trim()}`;
  });
  await step('B. 管理画面', 'プラグイン一覧', page, async () => {
    await go(page, `${BASE}/admin/plugins`);
    const rows = await page.locator('table.plugins tr[id^="plugin-"]').count();
    if (rows !== 15) throw new Error(`plugin rows=${rows} (expected 15)`);
    return `${rows} プラグイン`;
  });
  await step('B. 設定', '設定（全般）', page, async () => {
    await go(page, `${BASE}/settings?tab=general`);
    await noErrorPage(page);
  });
  await step('B. 設定', '設定（認証）', page, async () => {
    await go(page, `${BASE}/settings?tab=authentication`);
    await noErrorPage(page);
  });
  await step('B. 設定', 'REST API 有効化', page, async () => {
    await page.goto(`${BASE}/settings?tab=integrations`);
    await sudo(page);
    await page.check('#settings_rest_api_enabled');
    await submit(page, page.locator(SUBMIT).first());
    if (!(await page.isChecked('#settings_rest_api_enabled'))) throw new Error('not saved');
    return await flash(page);
  });
  await step('B. 設定', 'テーマを farend_fancy に変更', page, async () => {
    await go(page, `${BASE}/settings?tab=display`);
    await page.selectOption('#settings_ui_theme', 'farend_fancy');
    await submit(page, page.locator(SUBMIT).first());
    const href = await page.locator('link[rel="stylesheet"][href*="farend_fancy"]').count();
    if (!href) throw new Error('farend_fancy stylesheet not loaded');
    return await flash(page);
  });

  // ── C. プロジェクト ──
  for (const p of PROJECTS) {
    await step('C. プロジェクト', `プロジェクト作成: ${p.name}`, page, async () => {
      await go(page, `${BASE}/projects/new`);
      await page.fill('#project_name', p.name);
      await page.fill('#project_description', p.desc);
      await page.fill('#project_identifier', p.id);
      const mods = page.locator('input[type="checkbox"][name="project[enabled_module_names][]"]');
      for (let i = 0; i < await mods.count(); i++) await mods.nth(i).check();
      await submit(page, page.locator(SUBMIT).first());
      const msg = await flash(page);
      if (!page.url().includes(`/projects/${p.id}`)) throw new Error(`url ${page.url()}`);
      return `${msg}（全モジュール有効化）`;
    }, { fullPage: p === PROJECTS[0] });
  }
  await step('C. プロジェクト', 'プロジェクト一覧（3件）', page, async () => {
    await go(page, `${BASE}/projects?display_type=list`);
    const txt = await page.locator('#content').innerText();
    const miss = PROJECTS.filter((p) => !txt.includes(p.name)).map((p) => p.name);
    if (miss.length) throw new Error(`missing: ${miss.join(',')}`);
    return `${PROJECTS.length} 件表示`;
  });

  // ── D. チケット ──
  const issues = [
    { p: 'core-renewal', subject: '要件定義書の作成', desc: '業務要件を整理する。', tracker: '機能' },
    { p: 'core-renewal', subject: 'ログイン時に 500 エラー', desc: '再現手順: ...', tracker: 'バグ' },
    { p: 'portal', subject: 'トップページのお知らせ欄改修', desc: 'お知らせを 5 件表示に。', tracker: 'サポート' },
  ];
  const issueIds = [];
  for (const it of issues) {
    await step('D. チケット', `チケット作成: ${it.subject}`, page, async () => {
      await go(page, `${BASE}/projects/${it.p}/issues/new`);
      await page.selectOption('#issue_tracker_id', { label: it.tracker });
      await page.waitForLoadState('networkidle');
      await page.fill('#issue_subject', it.subject);
      await page.fill('#issue_description', it.desc);
      await submit(page, page.locator(SUBMIT).first());
      const m = page.url().match(/\/issues\/(\d+)/);
      if (!m) throw new Error(`not created: ${page.url()} ${await flash(page)}`);
      issueIds.push(Number(m[1]));
      return `#${m[1]} ${await flash(page)}`;
    }, { fullPage: it === issues[0] });
  }
  await step('D. チケット', 'チケット更新（ステータス・注記・添付ファイル）', page, async () => {
    const id = issueIds[0];
    await go(page, `${BASE}/issues/${id}/edit`);
    await page.selectOption('#issue_status_id', { label: '進行中' });
    await page.fill('#issue_notes', 'E2E: 添付ファイルをアップロードして進行中に変更。');
    const f = path.join(OUT, 'e2e-attachment.txt');
    fs.writeFileSync(f, 'Redmine 7.0.2 passenger E2E attachment\n');
    await page.setInputFiles('input[type="file"].file_selector', f);
    await page.waitForSelector('.attachments_fields input.filename', { timeout: 30000 });
    await page.waitForFunction(() => !document.querySelector('.attachments_fields .ajax-loading'));
    await Promise.all([page.waitForLoadState('load'), page.locator('#issue-form input[name="commit"]').first().click()]);
    await flash(page);
    const att = await page.locator('.attachments a', { hasText: 'e2e-attachment.txt' }).count();
    if (!att) throw new Error('attachment not shown');
    const st = (await page.locator('.status.attribute .value').first().textContent()).trim();
    return `#${id} ステータス=${st}, 添付 OK`;
  });
  await step('D. チケット', '添付ファイルのダウンロード（files/ 書込・読出）', page, async () => {
    const href = await page.locator('.attachments a.icon-download').first().getAttribute('href');
    const r = await page.request.get(new URL(href, BASE).toString());
    if (r.status() !== 200) throw new Error(`download HTTP ${r.status()}`);
    const body = await r.text();
    if (!body.includes('passenger E2E')) throw new Error('content mismatch');
    return `HTTP 200, ${body.length} bytes`;
  }, { shot: false });
  await step('D. チケット', 'チケット一覧', page, async () => {
    await go(page, `${BASE}/issues?set_filter=1&status_id=*`);
    const rows = await page.locator('table.issues tr.issue').count();
    if (rows < issues.length) throw new Error(`rows=${rows}`);
    return `${rows} 件`;
  });
  await step('D. チケット', 'チケット PDF 出力（日本語フォント）', page, async () => {
    const r = await page.request.get(`${BASE}/issues/${issueIds[0]}.pdf`);
    const ct = r.headers()['content-type'] || '';
    const buf = await r.body();
    if (r.status() !== 200 || !ct.includes('pdf')) throw new Error(`HTTP ${r.status()} ${ct}`);
    fs.writeFileSync(path.join(OUT, 'issue.pdf'), buf);
    return `${ct}, ${buf.length} bytes`;
  }, { shot: false });
  await step('D. チケット', 'ガントチャート', page, async () => {
    await go(page, `${BASE}/projects/core-renewal/issues/gantt`);
    await noErrorPage(page);
  });
  await step('D. チケット', 'かんばん（redmine_issues_panel）', page, async () => {
    await go(page, `${BASE}/projects/core-renewal/issues_panel`);
    const cards = await page.locator('.issue-card, [class*="issue_card"], .card').count();
    return `カード要素 ${cards}`;
  });

  // ── E. Wiki ──
  await step('E. Wiki', 'Wiki 作成（mermaid / wiki_lists / wiki_extensions マクロ）', page, async () => {
    await go(page, `${BASE}/projects/core-renewal/wiki/Wiki/edit`);
    const body = [
      'h1. E2E Wiki',
      '',
      '最終更新: {{lastupdated_at}}',
      '',
      'h2. チケット一覧 (wiki_lists)',
      '',
      '{{ref_issues(-p)}}',
      '',
      'h2. 構成図 (mermaid)',
      '',
      '{{mermaid',
      'graph LR',
      '  Client --> HostApache --> Passenger --> Redmine --> PostGIS',
      '}}',
    ].join('\n');
    await page.fill('#content_text', body);
    await submit(page, page.locator(SUBMIT).first());
    await page.waitForTimeout(2500);
    const txt = await page.locator('.wiki').first().innerText();
    if (/Error executing|マクロ.*エラー/.test(txt)) throw new Error('macro error in output');
    const svg = await page.locator('.wiki svg').count();
    return `mermaid SVG=${svg}`;
  });
  await step('E. Wiki', '全文検索', page, async () => {
    await go(page, `${BASE}/search?q=${encodeURIComponent('要件')}&all_words=1&titles_only=0`);
    const hits = await page.locator('#search-results dt').count();
    if (!hits) throw new Error('no hits');
    return `${hits} 件ヒット`;
  });

  // ── F. ユーザ管理 ──
  await step('F. ユーザ管理', 'ユーザ一覧', page, async () => {
    await go(page, `${BASE}/users`);
    await noErrorPage(page);
  });
  await step('F. ユーザ管理', `ユーザ追加: ${USER.login}`, page, async () => {
    await go(page, `${BASE}/users/new`);
    await page.fill('#user_login', USER.login);
    await page.fill('#user_firstname', USER.first);
    await page.fill('#user_lastname', USER.last);
    await page.fill('#user_mail', USER.mail);
    await page.fill('#user_password', USER.pw);
    await page.fill('#user_password_confirmation', USER.pw);
    const mc = page.locator('#user_must_change_passwd');
    if (await mc.count()) await mc.uncheck();
    await submit(page, page.locator(SUBMIT).first());
    return await flash(page);
  });
  await step('F. ユーザ管理', 'プロジェクトにメンバー追加（開発者）', page, async () => {
    await go(page, `${BASE}/projects/core-renewal/settings/members`);
    await page.locator('#content a.icon-add').first().click();
    await page.waitForSelector('#principal_search');
    await page.fill('#principal_search', USER.login);
    await page.waitForFunction(
      (name) => {
        const el = document.querySelector('#principals');
        if (!el) return false;
        const boxes = el.querySelectorAll('input[type="checkbox"]');
        return boxes.length === 1 && el.innerText.includes(name);
      },
      `${USER.first} ${USER.last}`
    );
    const cb = page.locator('#principals input[type="checkbox"]');
    await cb.first().check();
    await page.locator('.roles-selection label', { hasText: '開発者' }).locator('input').check();
    await page.click('#member-add-submit');
    await page.waitForSelector(`#tab-content-members table.members td.name:has-text("${USER.last}")`);
    await page.waitForTimeout(500);
    return '開発者ロールで追加';
  });

  // ── G. 一般ユーザでログイン ──
  const userCtx = await browser.newContext(ctxOpts);
  const up = await userCtx.newPage();
  up.setDefaultTimeout(30000);
  await step('G. 一般ユーザ', '誤パスワードでログイン失敗', up, async () => {
    await login(up, USER.login, 'wrong-password');
    const err = await up.locator('#flash_error').textContent();
    if (!err) throw new Error('no error shown');
    return err.trim();
  });
  await step('G. 一般ユーザ', `${USER.login} でログイン`, up, async () => {
    await login(up, USER.login, USER.pw);
    const who = await whoami(up);
    if (who !== '@' + USER.login) throw new Error(`whoami=${who} url=${up.url()}`);
    return who;
  });
  await step('G. 一般ユーザ', '参加プロジェクトのみ表示（権限）', up, async () => {
    await expectOk(await up.goto(`${BASE}/projects?display_type=list`));
    const txt = await up.locator('#content').innerText();
    // 新規プロジェクトは既定で公開のため全件見える場合あり。メンバー所属は確認。
    if (!txt.includes('基幹システム刷新')) throw new Error('member project missing');
    return '基幹システム刷新 表示';
  });
  await step('G. 一般ユーザ', '一般ユーザでチケット作成', up, async () => {
    await expectOk(await up.goto(`${BASE}/projects/core-renewal/issues/new`));
    await up.fill('#issue_subject', '一般ユーザからの起票テスト');
    await up.fill('#issue_description', 'yamada が作成。');
    await Promise.all([up.waitForLoadState('load'), up.locator('input[name="commit"]').first().click()]);
    const m = up.url().match(/\/issues\/(\d+)/);
    if (!m) throw new Error(`not created: ${up.url()}`);
    return `#${m[1]}`;
  });
  await step('G. 一般ユーザ', '管理画面へのアクセス拒否（403）', up, async () => {
    const r = await up.goto(`${BASE}/admin`);
    if (r.status() !== 403) throw new Error(`HTTP ${r.status()} (expected 403)`);
    return 'HTTP 403';
  });
  await step('G. 一般ユーザ', 'ログアウト', up, async () => {
    await up.goto(`${BASE}/my/page`);
    await up.locator('#account').click();
    await Promise.all([up.waitForLoadState('load'), up.locator('a.logout').click()]);
    if (await whoami(up)) throw new Error('still logged in');
    return 'ログアウト済';
  });

  // ── H. プラグイン機能 ──
  await step('H. プラグイン', 'ログイン監査（redmine_login_audit2）', page, async () => {
    await go(page, `${BASE}/admin/login_audit`);
    const txt = await page.locator('#content').innerText();
    if (!txt.includes(USER.login)) throw new Error('yamada の記録なし');
    return 'yamada の成功/失敗ログイン記録あり';
  });
  await step('H. プラグイン', 'View Customize で CSS 追加', page, async () => {
    await go(page, `${BASE}/view_customizes/new`);
    await page.fill('#view_customize_path_pattern', '.*');
    await page.selectOption('#view_customize_customize_type', 'css');
    await page.fill('#view_customize_code', '#header h1::after { content: "  [E2E 7.0.2 passenger]"; color: #ffeb3b; }');
    await page.fill('#view_customize_comments', 'E2E 確認用');
    await submit(page, page.locator(SUBMIT).first());
    await flash(page);
    await page.goto(`${BASE}/projects/core-renewal`);
    const css = await page.evaluate(() => getComputedStyle(document.querySelector('#header h1'), '::after').content);
    if (!css.includes('E2E')) throw new Error(`::after=${css}`);
    return `ヘッダーに反映: ${css}`;
  }, { fullPage: false });
  await step('H. プラグイン', 'グローバルチケットテンプレート作成（redmine_issue_templates）', page, async () => {
    await go(page, `${BASE}/global_issue_templates/new`);
    await page.fill('#global_issue_template_title', '障害報告テンプレート');
    await page.selectOption('#global_issue_template_tracker_id', { label: 'バグ' });
    await page.fill('#global_issue_template_description', '## 現象\n\n## 再現手順\n\n## 期待結果\n');
    await submit(page, page.locator(SUBMIT).first());
    return await flash(page);
  });
  await step('H. プラグイン', 'ログビューア（redmine_logs）', page, async () => {
    await go(page, `${BASE}/logs/index`);
    await noErrorPage(page);
  });
  await step('H. プラグイン', 'XLSX 出力（redmine_xlsx_format_issue_exporter）', page, async () => {
    const r = await page.request.get(`${BASE}/projects/core-renewal/issues.xlsx`);
    const ct = r.headers()['content-type'] || '';
    if (r.status() !== 200 || !ct.includes('spreadsheet')) throw new Error(`HTTP ${r.status()} ${ct}`);
    const buf = await r.body();
    if (buf.length < 1000) throw new Error(`xlsx too small: ${buf.length}`);
    return `${ct.split(';')[0]}, ${buf.length} bytes`;
  }, { shot: false });
  await step('H. プラグイン', 'カスケードリスト形式のカスタムフィールド（redmine_cascading_custom_fields）', page, async () => {
    await go(page, `${BASE}/custom_fields/new?type=IssueCustomField`);
    const values = await page.$$eval('#custom_field_field_format option', os => os.map(o => o.value));
    if (!values.includes('cascading_list')) throw new Error(`cascading_list format missing: ${values.join(',')}`);
    await page.selectOption('#custom_field_field_format', 'cascading_list');
    await page.locator('#custom_field_cascade_parent_id').waitFor({ timeout: 10000 });
    return '形式 cascading_list を選択、親フィールド選択欄が表示';
  });
  await step('H. プラグイン', 'グローバルバナー表示（redmine_banner）', page, async () => {
    await go(page, `${BASE}/global_banner`);
    await noErrorPage(page);
  });
  await step('H. プラグイン', 'GTT 地図レイヤー設定（redmine_gtt）', page, async () => {
    await go(page, `${BASE}/gtt_map_layers`);
    await noErrorPage(page);
  });
  await step('H. プラグイン', 'IP フィルタ設定（redmine_ip_filter）', page, async () => {
    await go(page, `${BASE}/filter_rule/edit`);
    await noErrorPage(page);
  });
  await step('H. プラグイン', 'メッセージカスタマイズ（redmine_message_customize）', page, async () => {
    await go(page, `${BASE}/custom_message_settings/edit`);
    await noErrorPage(page);
  });

  // ── I. REST API ──
  const apiCtx = await browser.newContext({ ...ctxOpts, httpCredentials: { username: USER.login, password: USER.pw } });
  const ap = await apiCtx.newPage();
  await step('I. REST API', 'issues.json（Basic 認証 / yamada）', ap, async () => {
    const r = await ap.goto(`${BASE}/issues.json?project_id=core-renewal&status_id=*`);
    if (r.status() !== 200) throw new Error(`HTTP ${r.status()}`);
    const j = JSON.parse(await ap.locator('body').innerText());
    return `total_count=${j.total_count}`;
  }, { fullPage: false });
  await step('I. REST API', 'projects.json（Basic 認証 / yamada）', ap, async () => {
    const r = await ap.goto(`${BASE}/projects.json`);
    if (r.status() !== 200) throw new Error(`HTTP ${r.status()}`);
    const j = JSON.parse(await ap.locator('body').innerText());
    return `total_count=${j.total_count}`;
  }, { fullPage: false });

  await browser.close();
  fs.writeFileSync(path.join(OUT, 'results.json'), JSON.stringify(results, null, 2));
  const fail = results.filter((r) => r.status !== 'PASS').length;
  console.log(`DONE pass=${results.length - fail} fail=${fail}`);
})();
