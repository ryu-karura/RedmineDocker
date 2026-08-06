-- scripts/pgloader/verify-sequences.sql
--
-- public スキーマの全 serial/identity 列について、シーケンスの現在値が
-- その列の最大値以上であることを検証します
-- （scripts/migrate-mysql-to-postgres.sh の verify ステップから実行）。
--
-- 1 つでも遅れているシーケンスがあれば RAISE EXCEPTION で失敗します
-- （psql は -v ON_ERROR_STOP=1 で実行するため、そのまま非 0 終了になります）。
-- 遅れたまま運用を始めると、最初のレコード作成で
-- "duplicate key value violates unique constraint" になります。

DO $$
DECLARE
    r         record;
    seq_name  text;
    max_id    bigint;
    last_val  bigint;
    behind    text := '';
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
        EXECUTE format('SELECT last_value FROM %s', seq_name) INTO last_val;

        IF COALESCE(last_val, 0) < max_id THEN
            behind := behind || format(' %s.%s(sequence=%s, max=%s)',
                                       r.table_name, r.column_name, last_val, max_id);
        END IF;
    END LOOP;

    IF behind <> '' THEN
        RAISE EXCEPTION 'sequences are behind max(id):%', behind;
    END IF;

    RAISE NOTICE 'all sequences are at or ahead of max(id)';
END
$$;
