# ca-certificates/ — 社内プロキシ (TLS 傍受型) の CA を入れる場所

TLS を再終端する（MITM する）プロキシの配下では、ビルド中の `git clone` や
`bundle install` が証明書エラーで失敗します。その場合は、**プロキシの CA 証明書を
PEM 形式で拡張子 `.crt` にして、このディレクトリへ置いてください**。

```
containers/redmine-web/ca-certificates/corp-proxy.crt
```

`Containerfile.v5` / `.v6` / `.v7` / `.v5-mysql` はこのディレクトリをイメージの
`/usr/local/share/ca-certificates/` へコピーし、`update-ca-certificates` を実行します。
ファイルを置かなければ何も起きません（このディレクトリは既定で空です）。

注意点:

- ファイル名は必ず `.crt` で終わらせてください。`update-ca-certificates` は
  `/usr/local/share/ca-certificates/` 直下の `*.crt` だけを取り込みます。
- 中身は PEM（`-----BEGIN CERTIFICATE-----`）です。DER 形式の場合は
  `openssl x509 -inform der -in corp.cer -out corp-proxy.crt` で変換します。
- 証明書チェーンが複数ある場合は、1 ファイル 1 証明書に分けて置いてください。
- **`.crt` は `.gitignore` 済みです**（社内証明書をリポジトリへコミットしないため）。
  必要なら各ホストで配置してください。
- プロキシ設定そのもの（`HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY`）は `.env` で設定します。
  詳細は `docs/Setup.md`「プロキシ環境で使う場合」を参照してください。
