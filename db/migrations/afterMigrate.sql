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
