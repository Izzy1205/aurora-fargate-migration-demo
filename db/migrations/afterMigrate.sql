-- Callback, not checksummed. Takes app_user's access to Flyway's history table back.
DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_user')
     AND to_regclass('public.flyway_schema_history') IS NOT NULL THEN
    REVOKE ALL ON public.flyway_schema_history FROM app_user;
  END IF;
END $$;

-- Append-only backstop for tables Flyway just created. db-logins.sql does the same.
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
