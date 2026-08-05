#!/bin/bash
# containers/redmine-db-mysql/init-redmine.sh
#
# upstream mysql イメージの /docker-entrypoint-initdb.d/ フックから、
# 初回初期化時に 1 回だけ実行されます（空データディレクトリで、認証情報を
# 設定済みの一時 MySQL サーバーが起動している状態）。
#
# ★ 実行ビットを立てないでください。
#   mysql の docker-entrypoint.sh は「実行ビットのない .sh は source する」
#   仕様で、source された場合だけ entrypoint 内の docker_process_sql /
#   mysql_note が使えます。これらを使うとパスワードを argv に置かずに済みます。
#   Containerfile 側で 0644 を設定しています。
#
# `redmine` ユーザーと `redmine` データベースは MYSQL_USER / MYSQL_DATABASE から
# 作成済みです。ここでは Redmine 5.1.6 が要求する文字コード (utf8mb4) を DB に
# 明示的に固定します。redmine.cnf で character-set-server を utf8mb4 にしている
# ため通常は同じ結果になりますが、ベースイメージや起動オプションが変わっても
# DB 側が utf8mb4 であることを保証する冪等なセーフティネットです。
# 照合順序を general_ci にしている理由は redmine.cnf のコメント参照。

mysql_note "Ensuring database '${MYSQL_DATABASE}' is utf8mb4 (collation utf8mb4_general_ci) ..."

docker_process_sql --database=mysql <<-EOSQL
	ALTER DATABASE \`${MYSQL_DATABASE}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
EOSQL

mysql_note "Redmine database initialised."
