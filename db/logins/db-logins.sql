-- Run by db-logins.sh as the Aurora master user. Re-running it is safe.
--
-- migrator owns the schema and every table, so Flyway can run DDL without
-- the master user. app_user can only read and write rows. The master user
-- is left for break-glass and for this script.

\set QUIET on
\getenv app_user APP_DB_USER
\getenv app_pw APP_DB_PASSWORD
\getenv migrator_user MIGRATOR_DB_USER
\getenv migrator_pw MIGRATOR_DB_PASSWORD

-- Create the roles only if they are missing.
SELECT format('CREATE ROLE %I', :'migrator_user')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'migrator_user') \gexec
SELECT format('CREATE ROLE %I', :'app_user')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'app_user') \gexec

-- Set the passwords from the secrets every run, so bumping the secret
-- version in Terraform and deploying is all a rotation takes.
ALTER ROLE :"migrator_user" WITH LOGIN NOCREATEDB NOCREATEROLE PASSWORD :'migrator_pw';
ALTER ROLE :"app_user" WITH LOGIN NOCREATEDB NOCREATEROLE PASSWORD :'app_pw';
\unset app_pw
\unset migrator_pw

-- On Aurora the master user is not a real superuser, so it has to be a
-- member of migrator to hand tables to it and to set its default
-- privileges below.
SELECT format('GRANT %I TO %I WITH INHERIT TRUE, SET TRUE', :'migrator_user', current_user)
WHERE NOT (pg_has_role(current_user, :'migrator_user', 'USAGE')
           AND pg_has_role(current_user, :'migrator_user', 'SET')) \gexec

SELECT format('GRANT CONNECT ON DATABASE %I TO %I, %I', current_database(), :'migrator_user', :'app_user') \gexec

REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE, CREATE ON SCHEMA public TO :"migrator_user";
GRANT USAGE ON SCHEMA public TO :"app_user";

-- A stack built before this change has its tables, including Flyway's
-- history table, owned by the master user. Hand those to migrator. Only
-- objects the master user owns are touched. Sequences that belong to a
-- table move with it.
SELECT format('ALTER TABLE %I.%I OWNER TO %I', n.nspname, c.relname, :'migrator_user')
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
  AND c.relowner = (SELECT oid FROM pg_roles WHERE rolname = current_user)
ORDER BY c.relname \gexec

SELECT format('ALTER SEQUENCE %I.%I OWNER TO %I', n.nspname, c.relname, :'migrator_user')
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relkind = 'S'
  AND c.relowner = (SELECT oid FROM pg_roles WHERE rolname = current_user)
  AND NOT EXISTS (
    SELECT FROM pg_depend d
    WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype IN ('a', 'i')
  )
ORDER BY c.relname \gexec

-- Row access on what exists today, and on whatever Flyway creates later.
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO :"app_user";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO :"app_user";
ALTER DEFAULT PRIVILEGES FOR ROLE :"migrator_user" IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"app_user";
ALTER DEFAULT PRIVILEGES FOR ROLE :"migrator_user" IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO :"app_user";

-- The app has no business with Flyway's history table.
SELECT format('REVOKE ALL ON public.flyway_schema_history FROM %I', :'app_user')
WHERE to_regclass('public.flyway_schema_history') IS NOT NULL \gexec
