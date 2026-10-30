-- V11: reveal tickets for the SSN vault.
--
-- claimant.ssn_token (V6) stays what it was: the claimant's permanent SSN
-- reference. It never expires and it can no longer be used to reveal.
-- To see an SSN, staff first get a reveal ticket for one open claim. A
-- ticket:
--   - lives while its claim is open, and never more than 72 hours,
--   - works for one reveal only (used_at is set by the reveal),
--   - can be swapped for a new one by the refresh endpoint, which needs a
--     fresh sign-in. The old one is revoked and points at its replacement.
--
-- No foreign keys, the same as ssn_vault. vault_id and claim_id point at
-- ssn_vault.id and claim.id by value. A foreign key to claim would stop
-- the retention purge from deleting a claim until someone deleted its
-- tickets, and the token service login is not allowed to delete anything.
--
-- Access: the same pattern as ssn_vault. PUBLIC and app_user get nothing
-- here. It's revoked below, again in db-logins.sql after its broad grant,
-- and again in afterMigrate.sql as the backstop. The token service role
-- ssn_vault_rw can read and add tickets and set only the three columns that
-- burn or replace one. No DELETE, and no UPDATE on anything else.
--
-- The token service also needs to check that a claim is open and belongs
-- to the SSN it is asked about, so it gets SELECT on just those columns of
-- claim and claimant. Nothing else there.

CREATE TABLE ssn_ticket (
    id           bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    -- "rtk_" and 32 random URL-safe characters. A different prefix from
    -- the permanent "tok_" so the two can't be mixed up.
    ticket       text        NOT NULL UNIQUE
                             CHECK (ticket ~ '^rtk_[A-Za-z0-9_-]{32}$'),
    vault_id     bigint      NOT NULL,
    claim_id     bigint      NOT NULL,
    -- Who asked for it. Only this actor can refresh it.
    issued_by    text        NOT NULL CHECK (issued_by <> ''),
    issued_at    timestamptz NOT NULL DEFAULT now(),
    expires_at   timestamptz NOT NULL,
    used_at      timestamptz,
    revoked_at   timestamptz,
    -- The ticket that replaced this one on refresh.
    replaced_by  bigint,
    -- The hard cap. However the app is configured, the database won't
    -- store a ticket that lives longer than 72 hours.
    CONSTRAINT ssn_ticket_expiry_cap CHECK (
        expires_at > issued_at AND expires_at <= issued_at + interval '72 hours'
    ),
    -- A ticket is either used or revoked, never both.
    CONSTRAINT ssn_ticket_used_or_revoked CHECK (used_at IS NULL OR revoked_at IS NULL),
    -- Only a revoked ticket can have a replacement.
    CONSTRAINT ssn_ticket_replaced_is_revoked CHECK (replaced_by IS NULL OR revoked_at IS NOT NULL)
);

-- The UNIQUE on ticket indexes the reveal lookup. These two are for "every
-- ticket for this claim" and "every ticket for this SSN".
CREATE INDEX ssn_ticket_claim_id_idx ON ssn_ticket (claim_id);
CREATE INDEX ssn_ticket_vault_id_idx ON ssn_ticket (vault_id);

REVOKE ALL ON ssn_ticket FROM PUBLIC;

DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_user') THEN
    REVOKE ALL ON ssn_ticket FROM app_user;
    REVOKE ALL ON SEQUENCE ssn_ticket_id_seq FROM app_user;
  END IF;
  -- Not there on a plain local Postgres, or before db-logins has run.
  -- db-logins.sql and afterMigrate.sql repeat these grants.
  IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'ssn_vault_rw') THEN
    GRANT SELECT, INSERT ON ssn_ticket TO ssn_vault_rw;
    GRANT UPDATE (used_at, revoked_at, replaced_by) ON ssn_ticket TO ssn_vault_rw;
    GRANT SELECT (id, claimant_id, status) ON claim TO ssn_vault_rw;
    GRANT SELECT (id, ssn_token) ON claimant TO ssn_vault_rw;
  END IF;
END $$;
