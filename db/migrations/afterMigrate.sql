-- Flyway callback, runs after every migrate. Not a versioned migration, so
-- it never shows up in the history table.
--
-- The default privileges set by db/logins give the app row access to every
-- new table, and on a fresh stack that includes Flyway's own history table.
-- Take it back. app_user matches the default app_username in
-- modules/database. Does nothing where that role doesn't exist, such as a
-- plain local Postgres.
DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_user')
     AND to_regclass('public.flyway_schema_history') IS NOT NULL THEN
    REVOKE ALL ON public.flyway_schema_history FROM app_user;
  END IF;
END $$;

-- Money and audit rows are add-only. The default privileges give app_user
-- UPDATE and DELETE on every new table, and db-logins re-grants them on
-- every deploy, so take them back here, after every migrate, on the tables
-- where nobody should ever edit or remove a row. Corrections are new rows.
DO $$
DECLARE
  t text;
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_user') THEN
    RETURN;
  END IF;
  FOREACH t IN ARRAY ARRAY['payment', 'payment_event', 'audit_event'] LOOP
    IF to_regclass('public.' || t) IS NOT NULL THEN
      EXECUTE format('REVOKE UPDATE, DELETE, TRUNCATE ON public.%I FROM app_user', t);
    END IF;
  END LOOP;
END $$;
