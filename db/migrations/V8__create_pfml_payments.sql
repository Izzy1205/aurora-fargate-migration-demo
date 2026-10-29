-- V8: PFML schema, part 3. Where money goes and what was paid.
--
-- Money rows are add-only. Nobody edits a payment: a correction is a new
-- row with the difference, a reversal is a new row with the opposite
-- amount, and status changes are rows in payment_event. The balance is the
-- sum of the rows, so the history always explains the number.
-- afterMigrate.sql takes UPDATE and DELETE on these tables away from the
-- app login, so this holds even if the code gets it wrong.

-- Bank details, versioned. A change is a new row with a higher version and
-- a date it becomes payable, a few days out, so the real person has time to
-- stop a hijacked change. Each payment points at the exact version it used.
-- The cooling-off length and who gets notified are app rules.
CREATE TABLE payee_account (
    id                  bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    claimant_id         bigint      NOT NULL REFERENCES claimant (id),
    version             integer     NOT NULL CHECK (version > 0),
    -- The account and routing numbers live in the tokenization service. A
    -- bare string of digits here means someone stored the real number.
    bank_account_token  text        NOT NULL UNIQUE CHECK (bank_account_token !~ '^[0-9]+$'),
    payable_from        timestamptz NOT NULL,
    created_at          timestamptz NOT NULL DEFAULT now(),
    UNIQUE (claimant_id, version),
    CHECK (payable_from >= created_at)
);

-- payment_kind:
--   original    the one payment for a benefit week
--   correction  a later adjustment, positive or negative, pointing back
--   reversal    undoes the original, with the opposite amount
CREATE TABLE payment (
    id                   bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    benefit_week_id      bigint      NOT NULL,
    claim_id             bigint      NOT NULL,
    payment_kind         text        NOT NULL CHECK (payment_kind IN ('original', 'correction', 'reversal')),
    original_payment_id  bigint,
    amount_cents         integer     NOT NULL CHECK (amount_cents <> 0),
    method               text        NOT NULL CHECK (method IN ('ach', 'check')),
    -- Empty only for a paper check mailed to the address on file.
    payee_account_id     bigint      REFERENCES payee_account (id),
    -- Set by the caller and unique, so a retried request finds the row it
    -- already wrote instead of paying again.
    idempotency_key      text        NOT NULL UNIQUE CHECK (idempotency_key <> ''),
    -- The weekly pay run that produced this row, e.g. its execution name.
    pay_run_id           text        NOT NULL,
    -- Corrections and reversals need a reason and an approver.
    reason               text,
    approved_by          text,
    created_at           timestamptz NOT NULL DEFAULT now(),

    -- The week has to belong to the claim the payment says it's for.
    FOREIGN KEY (benefit_week_id, claim_id) REFERENCES benefit_week (id, claim_id),
    -- A correction or reversal points at an original for the same week.
    FOREIGN KEY (original_payment_id, benefit_week_id) REFERENCES payment (id, benefit_week_id),
    UNIQUE (id, benefit_week_id),

    CONSTRAINT payment_links_to_original CHECK (
        (payment_kind = 'original') = (original_payment_id IS NULL)
    ),
    CONSTRAINT payment_amount_sign CHECK (
        payment_kind = 'correction'
        OR (payment_kind = 'original' AND amount_cents > 0)
        OR (payment_kind = 'reversal' AND amount_cents < 0)
    ),
    CONSTRAINT payment_adjustment_approved CHECK (
        payment_kind = 'original' OR (reason IS NOT NULL AND approved_by IS NOT NULL)
    ),
    CONSTRAINT payment_ach_needs_account CHECK (
        method <> 'ach' OR payee_account_id IS NOT NULL
    )
);

-- One week, paid once. The database refuses a second original payment for
-- the same claim and week, whatever the code does. Corrections and
-- reversals are left out, so they can still be added. Postgres can't put a
-- WHERE on a table constraint, so this is a unique index; it rejects a
-- duplicate the same way.
CREATE UNIQUE INDEX payment_one_original_per_claim_week
    ON payment (claim_id, benefit_week_id)
    WHERE payment_kind = 'original';

CREATE INDEX payment_benefit_week_id_idx ON payment (benefit_week_id);
CREATE INDEX payment_original_payment_id_idx ON payment (original_payment_id);
CREATE INDEX payment_payee_account_id_idx ON payment (payee_account_id);
CREATE INDEX payment_pay_run_id_idx ON payment (pay_run_id);

-- What happened to a payment after it left: sent, settled at the bank, or
-- returned. A new row each time, never an edit.
CREATE TABLE payment_event (
    id           bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    payment_id   bigint      NOT NULL REFERENCES payment (id),
    status       text        NOT NULL CHECK (status IN ('sent', 'settled', 'returned')),
    occurred_at  timestamptz NOT NULL DEFAULT now(),
    -- The bank's return code or trace number, when there is one.
    detail       text
);

CREATE INDEX payment_event_payment_id_idx ON payment_event (payment_id, occurred_at);
