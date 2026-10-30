-- V10: the SSN vault, behind the tokenization service.
--
-- claimant (V6) holds the ticket: ssn_token and ssn_hmac. This table holds
-- the coat: the SSN itself, encrypted with a dedicated KMS key. Only the
-- token service reads it, and every reveal writes an audit_event row in the
-- same transaction.
--
-- No plain SSN is ever stored. ssn_ciphertext is the KMS ciphertext blob,
-- encrypted with the encryption context {purpose: ssn, token: <ssn_token>},
-- so a blob copied onto another row won't decrypt.
--
-- Access: app_user gets nothing here. The default privileges from
-- db/logins hand app_user row access to every new table, so it's revoked
-- below, again in db-logins.sql after its broad grant (it runs before
-- Flyway on every deploy), and again in afterMigrate.sql as the backstop.
-- The token service role ssn_vault_rw is created by db-logins.sql, because
-- migrator has NOCREATEROLE.

CREATE TABLE ssn_vault (
    id              bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    -- Same rule as claimant.ssn_token, plus the exact shape the service
    -- issues: "tok_" and 32 random URL-safe characters.
    ssn_token       text        NOT NULL UNIQUE
                                CHECK (ssn_token !~ '^[0-9]{3}-?[0-9]{2}-?[0-9]{4}$')
                                CHECK (ssn_token ~ '^tok_[A-Za-z0-9_-]{32}$'),
    -- Same keyed hash as claimant.ssn_hmac and wage_quarter.ssn_hmac. Unique,
    -- so the same SSN always maps to the same token.
    ssn_hmac        bytea       NOT NULL UNIQUE CHECK (octet_length(ssn_hmac) = 32),
    ssn_ciphertext  bytea       NOT NULL CHECK (octet_length(ssn_ciphertext) > 0),
    -- KMS key ARN that encrypted this row. A key rotation re-encrypt job
    -- finds old rows by this.
    key_id          text        NOT NULL CHECK (key_id <> ''),
    created_at      timestamptz NOT NULL DEFAULT now()
);

-- The UNIQUE constraints above already index ssn_token and ssn_hmac, the
-- only two lookups. No foreign keys: claimant points here by value, the
-- same way wage_quarter matches on ssn_hmac.

REVOKE ALL ON ssn_vault FROM PUBLIC;

DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_user') THEN
    REVOKE ALL ON ssn_vault FROM app_user;
    REVOKE ALL ON SEQUENCE ssn_vault_id_seq FROM app_user;
  END IF;
  -- Not there on a plain local Postgres, or before db-logins has run with
  -- this change. db-logins.sql repeats these grants.
  IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'ssn_vault_rw') THEN
    GRANT SELECT, INSERT ON ssn_vault TO ssn_vault_rw;
    GRANT INSERT ON audit_event TO ssn_vault_rw;
  END IF;
END $$;
