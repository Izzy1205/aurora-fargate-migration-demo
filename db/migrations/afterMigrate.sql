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

-- Payments and audit events are append-only by design. The app inserts
-- them and never edits or removes one; a correction or reversal is a new
-- payment row. The default privileges give app_user UPDATE and DELETE on
-- every table Flyway creates, so take them back here. db-logins.sql does
-- the same revoke right after its broad grant, because it runs before
-- Flyway on every deploy and used to leave a window where the app had
-- them. This copy is the backstop, and it covers the first deploy, when
-- these tables don't exist until Flyway makes them.
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

-- The SSN vault is for the token service only (V10). Same reason as above:
-- default privileges give app_user row access to it.
DO $$
BEGIN
  IF to_regclass('public.ssn_vault') IS NULL THEN
    RETURN;
  END IF;
  REVOKE ALL ON public.ssn_vault FROM PUBLIC;
  IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_user') THEN
    REVOKE ALL ON public.ssn_vault FROM app_user;
    REVOKE ALL ON SEQUENCE public.ssn_vault_id_seq FROM app_user;
  END IF;
  IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'ssn_vault_rw') THEN
    GRANT SELECT, INSERT ON public.ssn_vault TO ssn_vault_rw;
    GRANT INSERT ON public.audit_event TO ssn_vault_rw;
  END IF;
END $$;
