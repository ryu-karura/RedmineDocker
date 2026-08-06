-- scripts/pgloader/reset-sequences.sql
--
-- pgloader の data-only ロード後に、public スキーマの全 serial/identity 列の
-- シーケンスを現在の最大値へ合わせ直します
-- （scripts/migrate-mysql-to-postgres.sh の sequences ステップから実行）。
--
-- ★ なぜ必要か
--   pgloader は id 列の値をそのまま COPY します。シーケンス自体は
--   `rake db:migrate` 直後の 1 のままなので、これを直さないと移行後に
--   最初のレコードを作った瞬間 "duplicate key value violates unique constraint
--   \"xxx_pkey\"" で失敗します。
--
-- 冪等です（何度実行しても結果は同じ）。

DO $$
DECLARE
    r        record;
    max_id   bigint;
    seq_name text;
BEGIN
    FOR r IN
        SELECT c.relname AS table_name,
               a.attname AS column_name
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attribute a ON a.attrelid = c.oid
        WHERE c.relkind = 'r'
          AND n.nspname = 'public'
          AND a.attnum > 0
          AND NOT a.attisdropped
        ORDER BY c.relname, a.attnum
    LOOP
        seq_name := pg_get_serial_sequence(quote_ident(r.table_name), r.column_name);
        CONTINUE WHEN seq_name IS NULL;

        EXECUTE format('SELECT COALESCE(max(%I), 0) FROM %I', r.column_name, r.table_name)
            INTO max_id;

        IF max_id > 0 THEN
            -- is_called = true なので、次に採番されるのは max_id + 1。
            PERFORM setval(seq_name, max_id, true);
        ELSE
            -- 空テーブル。is_called = false なので、次に採番されるのは 1。
            PERFORM setval(seq_name, 1, false);
        END IF;

        RAISE NOTICE 'sequence % set to % (table %.%)',
            seq_name, max_id, r.table_name, r.column_name;
    END LOOP;
END
$$;
