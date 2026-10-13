# チケット詳細に帳票印刷ボタンを追加する (View Customize)

指定したトラッカーのチケット詳細画面だけに「帳票プレビュー」ボタンを追加し、A4 帳票風レイアウトでプレビュー・印刷する設定手順。
Redmine 本体やコンテナイメージの変更は不要で、同梱プラグイン `view_customize` の JavaScript 1 本で実現する。

## 概要

- 対象: 指定トラッカーのチケット詳細 (`/issues/<ID>`) のみ
- ボタン: チケット詳細右上の操作リンク群 (`.contextual`) に「帳票プレビュー」を追加
- 1 ページ目: タイトル、基本情報表、説明、承認欄・押印欄
- 2 ページ目: 添付画像のプレビュー (画像が多い場合は 3 ページ目以降へ続く)
- 印刷: ブラウザの印刷機能 (`window.print()`)。A4、改ページ指定済み

## 設定手順

管理 → ViewCustomize → 新規 で次のとおり登録する。

| 項目 | 設定値 |
|------|--------|
| パスパターン | `/issues/\d+$` |
| プロジェクトパターン | 空欄 (全プロジェクト)。絞る場合のみ指定 |
| 挿入位置 | 全てのページの末尾 |
| タイプ | JavaScript |
| コード | 下記「コード全文」 |

## トラッカーの絞り込み方

View Customize 自体にはトラッカー条件がない (絞れるのはパスとプロジェクトのみ)。
チケット詳細の DOM は `<div class="issue tracker-<ID> status-.. priority-..">` の形でトラッカー ID がクラスに付くので、JavaScript 側で判定する。

- トラッカー ID は 管理 → トラッカー の編集 URL (`/trackers/2/edit`) で確認する
- コード先頭の `TRACKER_CLASS` を対象 ID に合わせる (環境ごとに ID が違うため、本番で必ず確認する)
- 新規作成・編集画面は別パスなので `/issues/\d+$` により対象外になる

## コード全文

```javascript
$(function () {
  var TRACKER_CLASS = 'tracker-2';            // 対象トラッカーID
  var $issue = $('div.issue.' + TRACKER_CLASS);
  if ($issue.length === 0) return;

  var issueId = (location.pathname.match(/\/issues\/(\d+)/) || [])[1] || '';
  var IMG_EXT = /\.(png|jpe?g|gif|bmp|webp)$/i;

  // 承認欄の役職。配列を書き換えて調整する
  var SIGN_ROLES = ['担当', '確認', '承認'];

  $('<style>').text(
    // 画面プレビュー: グレー背景にA4用紙
    '#print-preview{position:fixed;inset:0;z-index:9999;background:#888;overflow:auto;padding:16px}' +
    '#print-preview .pp-bar{position:sticky;top:0;text-align:center;margin-bottom:12px}' +
    '#print-preview .pp-sheet{box-sizing:border-box;width:210mm;min-height:297mm;margin:0 auto 16px;' +
      'padding:14mm;background:#fff;color:#000;font-size:10.5pt;box-shadow:0 0 8px rgba(0,0,0,.5)}' +
    '#print-preview h1{font-size:18pt;text-align:center;border-bottom:3px double #000;margin:0 0 6mm;padding-bottom:3mm}' +
    '#print-preview h2{font-size:11pt;background:#eee;border-left:4px solid #000;padding:2px 6px;margin:6mm 0 2mm}' +
    '#print-preview table{border-collapse:collapse;width:100%}' +
    '#print-preview th,#print-preview td{border:1px solid #000;padding:4px 6px;text-align:left;vertical-align:top}' +
    '#print-preview th{background:#f0f0f0;width:18%;white-space:nowrap}' +
    '#print-preview .pp-desc{border:1px solid #000;padding:6px;min-height:80mm}' +
    '#print-preview .pp-desc img{max-width:100%}' +
    '#print-preview .pp-meta{display:flex;justify-content:space-between;font-size:9pt;margin-bottom:3mm}' +
    '#print-preview .pp-foot{margin-top:6mm;font-size:8pt;text-align:right;color:#444}' +
    '#print-preview .pp-sign{margin:6mm 0 0 auto;width:auto;table-layout:fixed}' +
    '#print-preview .pp-sign th{width:30mm;text-align:center;white-space:nowrap}' +
    '#print-preview .pp-sign td{width:30mm;height:22mm;text-align:center;vertical-align:middle;color:#aaa;font-size:8pt}' +
    '#print-preview .pp-sign-wrap{page-break-inside:avoid;break-inside:avoid}' +
    '#print-preview .pp-img{text-align:center;margin-bottom:6mm;page-break-inside:avoid;break-inside:avoid}' +
    '#print-preview .pp-img img{max-width:100%;max-height:110mm;border:1px solid #999}' +
    '#print-preview .pp-img div{font-size:9pt;margin-top:1mm}' +
    // 印刷: オーバーレイのみ、A4、2ページ目で改ページ
    '@page{size:A4;margin:0}' +
    '@media print{' +
      'body>*:not(#print-preview){display:none!important}' +
      '#print-preview{position:static;background:none;padding:0;overflow:visible}' +
      '#print-preview .pp-bar{display:none}' +
      '#print-preview .pp-sheet{margin:0;box-shadow:none;width:auto;min-height:0}' +
      '#print-preview .pp-sheet+.pp-sheet{page-break-before:always;break-before:page}' +
    '}'
  ).appendTo('head');

  function esc(s) { return $('<div>').text($.trim(s)).html(); }

  // 承認欄・押印欄 (下段が押印スペース)
  function signTable() {
    var head = '', cell = '';
    $.each(SIGN_ROLES, function (_, r) {
      head += '<th>' + esc(r) + '</th>';
      cell += '<td>印</td>';
    });
    return '<div class="pp-sign-wrap">' +
      '<table class="pp-sign"><tr>' + head + '</tr><tr>' + cell + '</tr></table>' +
      '</div>';
  }

  function imageAttachments() {
    var list = [];
    $issue.find('div.attachments a[href*="/attachments/download/"]').each(function () {
      var name = $.trim($(this).text());
      if (IMG_EXT.test(name)) list.push({ url: this.href, name: name });
    });
    return list;
  }

  function build() {
    var rows = '';
    $issue.find('.attributes .attribute').each(function () {
      rows += '<tr><th>' + esc($(this).find('.label').text()) + '</th>' +
              '<td>' + esc($(this).find('.value').text()) + '</td></tr>';
    });
    var desc = $issue.find('.description .wiki').html() || '(説明なし)';
    var now = new Date().toLocaleString('ja-JP');
    var project = $.trim($('#header h1').first().text());

    var p1 =
      '<section class="pp-sheet">' +
        '<h1>' + esc($issue.find('.subject h3').text()) + '</h1>' +
        '<div class="pp-meta"><span>チケット #' + esc(issueId) + '</span><span>' + esc(project) + '</span></div>' +
        '<h2>基本情報</h2><table>' + rows + '</table>' +
        '<h2>説明</h2><div class="pp-desc">' + desc + '</div>' +
        signTable() +
        '<div class="pp-foot">出力日時: ' + esc(now) + ' (1/2)</div>' +
      '</section>';

    var imgs = imageAttachments();
    var body = imgs.length ? '' : '<p>添付画像なし</p>';
    $.each(imgs, function (_, a) {
      body += '<div class="pp-img"><img src="' + esc(a.url) + '" alt=""><div>' + esc(a.name) + '</div></div>';
    });
    var p2 =
      '<section class="pp-sheet">' +
        '<h1>添付画像</h1>' +
        '<div class="pp-meta"><span>チケット #' + esc(issueId) + '</span><span>' + esc(project) + '</span></div>' +
        body +
        '<div class="pp-foot">出力日時: ' + esc(now) + ' (2/2)</div>' +
      '</section>';

    return $('<div id="print-preview">').append(
      '<div class="pp-bar"><button id="pp-print">印刷</button> <button id="pp-close">閉じる</button></div>' + p1 + p2
    );
  }

  var $btn = $('<a href="#" class="icon icon-print">帳票プレビュー</a>').on('click', function (e) {
    e.preventDefault();
    var $box = build().appendTo('body');
    $box.find('#pp-close').on('click', function () { $box.remove(); });
    $box.find('#pp-print').on('click', function () {
      // 画像読込完了を待ってから印刷
      var waits = $box.find('img').map(function () {
        var img = this;
        return new Promise(function (r) {
          if (img.complete) r(); else { img.onload = r; img.onerror = r; }
        });
      }).get();
      Promise.all(waits).then(function () { window.print(); });
    });
  });

  $('div.issue .contextual').first().prepend($btn);
});
```

## 仕様と注意点

### レイアウト
- 画面上はグレー背景に A4 用紙 (210mm 幅) を表示する。印刷時はオーバーレイ以外を `display:none` にして、`@page { size: A4; margin: 0 }` と各シートの `padding: 14mm` で余白を確保する
- 2 枚目以降は `.pp-sheet + .pp-sheet { break-before: page }` で改ページする
- 印刷ダイアログでは用紙サイズ A4、余白「なし/既定」を選ぶ。見出しの灰色背景を出すには「背景のグラフィック」を ON にする
- 説明欄 (`min-height: 80mm`) と承認欄で 1 ページに収まらない場合、承認欄が 2 ページ目に押し出される。その場合は `.pp-desc` の `min-height` を 60mm 程度まで下げる
- フッターの「1/2」「2/2」は固定文字。添付画像が多くて 3 ページ以上になっても自動では変わらない。厳密なページ番号が必要なら別途計算が必要

### 承認欄・押印欄
- 右寄せの表。上段が役職、下段が押印スペース (30mm × 22mm)
- 役職の変更は `SIGN_ROLES` を編集する (例: `['起票','課長','部長','役員']`)
- 下段の「印」は目印の薄灰文字で、印刷にも出る。不要なら `signTable()` 内の `<td>印</td>` を `<td></td>` にする
- 2 ページ目にも付ける場合は、`p2` の `body` の後ろに `signTable()` を追加する

### 添付画像
- 添付ファイルのうち拡張子が png / jpg / jpeg / gif / bmp / webp のものだけを対象にする
- 画像は `/attachments/download/<ID>/<ファイル名>` を `<img>` に直接指定する。Redmine は画像を inline 配信するので表示できる
- 印刷ボタンは画像の読込完了を待ってから `window.print()` を呼ぶ

### セキュリティ
- 説明欄は Redmine が描画した `.wiki` の HTML をそのまま埋め込む。サニタイズは Redmine 側で済んでいる
- 属性値・タイトル・ファイル名は `esc()` でエスケープして埋め込む

### 限界
- ロゴ、複数ページにまたがる複雑な帳票、サーバ側での PDF 生成が必要な場合、JavaScript だけでは限界がある。その場合は独自の Redmine プラグインか専用 view を検討する
- `redmine_gtt` を含む構成でも、本カスタマイズは DOM を読むだけなので影響しない

## 関連

- プラグイン一覧と `view_customize` の概要: [Plugins.md](Plugins.md)
