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
-- Group role for the SSN token service. NOLOGIN: a login is granted
-- membership.
SELECT 'CREATE ROLE ssn_vault_rw NOLOGIN'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ssn_vault_rw') \gexec
-- The token service's login. It has no password: it signs in with an IAM
-- auth token (rds_iam), which the app mints with its task role. That keeps
-- a password secret out of this task's definition, since adding one there
-- would replace the Terraform-owned task definition. The name is fixed and
-- matches vault_db_username in modules/ssn_vault.
SELECT 'CREATE ROLE ssn_vault_login'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ssn_vault_login') \gexec

-- Set the passwords from the secrets every run, so bumping the secret
-- version in Terraform and deploying is all a rotation takes.
ALTER ROLE :"migrator_user" WITH LOGIN NOCREATEDB NOCREATEROLE PASSWORD :'migrator_pw';
ALTER ROLE :"app_user" WITH LOGIN NOCREATEDB NOCREATEROLE PASSWORD :'app_pw';
\unset app_pw
\unset migrator_pw
-- PASSWORD NULL: password sign-in is impossible for the vault login.
ALTER ROLE ssn_vault_login WITH LOGIN NOCREATEDB NOCREATEROLE PASSWORD NULL;
GRANT ssn_vault_rw TO ssn_vault_login;
-- rds_iam only exists on RDS and Aurora. Skipped on plain Postgres.
SELECT 'GRANT rds_iam TO ssn_vault_login'
WHERE EXISTS (SELECT FROM pg_roles WHERE rolname = 'rds_iam') \gexec

-- On Aurora the master user is not a real superuser, so it has to be a
-- member of migrator to hand tables to it and to set its default
-- privileges below.
SELECT format('GRANT %I TO %I WITH INHERIT TRUE, SET TRUE', :'migrator_user', current_user)
WHERE NOT (pg_has_role(current_user, :'migrator_user', 'USAGE')
           AND pg_has_role(current_user, :'migrator_user', 'SET')) \gexec

SELECT format('GRANT CONNECT ON DATABASE %I TO %I, %I, ssn_vault_login', current_database(), :'migrator_user', :'app_user') \gexec

REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE, CREATE ON SCHEMA public TO :"migrator_user";
GRANT USAGE ON SCHEMA public TO :"app_user", ssn_vault_rw;

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

-- Payments and audit events are append-only by design. The app inserts
-- them and never edits or removes one; a correction or reversal is a new
-- payment row. The broad grant above would hand UPDATE and DELETE back on
-- every deploy, and since this runs before Flyway, the app had them until
-- Flyway's afterMigrate took them away again. Take them back here, in the
-- same run, so there's no window. Tables that don't exist yet (a fresh
-- database, or one still at V2) are skipped; when Flyway creates them,
-- afterMigrate.sql does the same revoke as the backstop.
SELECT format('REVOKE UPDATE, DELETE, TRUNCATE ON %I.%I FROM %I', 'public', t, :'app_user')
FROM unnest(ARRAY['payment', 'payment_event', 'audit_event']) AS t
WHERE to_regclass(format('%I.%I', 'public', t)) IS NOT NULL
ORDER BY t \gexec

-- The app has no business with Flyway's history table.
SELECT format('REVOKE ALL ON public.flyway_schema_history FROM %I', :'app_user')
WHERE to_regclass('public.flyway_schema_history') IS NOT NULL \gexec

-- The SSN vault is for the token service only. The broad grant above would
-- give app_user the encrypted SSNs on every deploy, so take it back in the
-- same run. afterMigrate.sql repeats this as the backstop.
SELECT format('REVOKE ALL ON public.ssn_vault FROM %I', :'app_user')
WHERE to_regclass('public.ssn_vault') IS NOT NULL \gexec
SELECT format('REVOKE ALL ON SEQUENCE public.ssn_vault_id_seq FROM %I', :'app_user')
WHERE to_regclass('public.ssn_vault_id_seq') IS NOT NULL \gexec
SELECT 'GRANT SELECT, INSERT ON public.ssn_vault TO ssn_vault_rw'
WHERE to_regclass('public.ssn_vault') IS NOT NULL \gexec
SELECT 'GRANT INSERT ON public.audit_event TO ssn_vault_rw'
WHERE to_regclass('public.audit_event') IS NOT NULL \gexec

-- Reveal tickets (V11) get the same treatment as the vault: app_user's
-- broad grant is taken back in the same run, and the token service gets
-- only what it needs. afterMigrate.sql repeats this as the backstop.
SELECT format('REVOKE ALL ON public.ssn_ticket FROM %I', :'app_user')
WHERE to_regclass('public.ssn_ticket') IS NOT NULL \gexec
SELECT format('REVOKE ALL ON SEQUENCE public.ssn_ticket_id_seq FROM %I', :'app_user')
WHERE to_regclass('public.ssn_ticket_id_seq') IS NOT NULL \gexec
SELECT 'REVOKE ALL ON public.ssn_ticket FROM PUBLIC'
WHERE to_regclass('public.ssn_ticket') IS NOT NULL \gexec
SELECT 'GRANT SELECT, INSERT ON public.ssn_ticket TO ssn_vault_rw'
WHERE to_regclass('public.ssn_ticket') IS NOT NULL \gexec
SELECT 'GRANT UPDATE (used_at, revoked_at, replaced_by) ON public.ssn_ticket TO ssn_vault_rw'
WHERE to_regclass('public.ssn_ticket') IS NOT NULL \gexec
SELECT 'GRANT SELECT (id, claimant_id, status) ON public.claim TO ssn_vault_rw'
WHERE to_regclass('public.claim') IS NOT NULL \gexec
SELECT 'GRANT SELECT (id, ssn_token) ON public.claimant TO ssn_vault_rw'
WHERE to_regclass('public.claimant') IS NOT NULL \gexec
