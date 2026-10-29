-- V6: PFML schema, part 1. The people and employers a claim is about, and
-- the wage records eligibility is checked against.
--
-- No plain SSN is stored anywhere. Each SSN is held two ways:
--   ssn_token  an opaque value the tokenization service can turn back into
--              the real number for someone allowed to see it. Every reveal
--              happens there and is logged there.
--   ssn_hmac   a keyed hash (HMAC-SHA256, 32 bytes) of the SSN. Same SSN,
--              same hash, so duplicate checks and the join to the state's
--              wage records are a plain equals. It has to be keyed: an SSN is
--              only nine digits, so an unkeyed hash can be reversed by
--              hashing every possible number.
-- The tokenization service and the HMAC key live outside this database and
-- aren't built yet. This migration is schema only.

CREATE TABLE claimant (
    id             bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    -- The token must never be the SSN itself. This catches the easy mistake
    -- of writing the raw number into the token column.
    ssn_token      text        NOT NULL UNIQUE
                               CHECK (ssn_token !~ '^[0-9]{3}-?[0-9]{2}-?[0-9]{4}$'),
    -- Unique, so the same person can't be signed up twice.
    ssn_hmac       bytea       NOT NULL UNIQUE CHECK (octet_length(ssn_hmac) = 32),
    first_name     text        NOT NULL,
    last_name      text        NOT NULL,
    email          text,
    phone          text,
    -- The sign-in provider's user ID. Empty for a claim staff key in on
    -- someone's behalf.
    sign_in_id     text        UNIQUE,
    created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE employer (
    id             bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    -- Federal employer ID, nine digits, stored without the dash.
    fein           text        NOT NULL UNIQUE CHECK (fein ~ '^[0-9]{9}$'),
    legal_name     text        NOT NULL,
    -- Where requests for the employer's response go.
    contact_email  text,
    contact_phone  text,
    created_at     timestamptz NOT NULL DEFAULT now()
);

-- Wages one employer paid one person in one quarter, loaded from the
-- state's wage records. Keyed by the SSN hash, not by claimant, because the
-- wage file arrives for everyone, long before most people ever file a claim.
-- The loader computes the same HMAC as sign-up, so matching is an equals.
CREATE TABLE wage_quarter (
    id             bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    employer_id    bigint      NOT NULL REFERENCES employer (id),
    ssn_hmac       bytea       NOT NULL CHECK (octet_length(ssn_hmac) = 32),
    wage_year      smallint    NOT NULL CHECK (wage_year BETWEEN 2000 AND 2100),
    wage_quarter   smallint    NOT NULL CHECK (wage_quarter BETWEEN 1 AND 4),
    wages_cents    bigint      NOT NULL CHECK (wages_cents >= 0),
    loaded_at      timestamptz NOT NULL DEFAULT now(),
    -- One row per employer, person and quarter. A reloaded file updates
    -- the row instead of adding a second one.
    UNIQUE (employer_id, ssn_hmac, wage_year, wage_quarter)
);

-- Eligibility looks up one person's last four quarters across every
-- employer. The unique key above starts with employer, so it can't serve
-- that lookup.
CREATE INDEX wage_quarter_ssn_hmac_idx ON wage_quarter (ssn_hmac, wage_year, wage_quarter);
