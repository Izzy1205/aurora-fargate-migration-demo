-- V7: PFML schema, part 2. Claims, the leave they approve, the weeks that
-- leave is paid in, and the documents attached to a claim.
--
-- Postgres doesn't index foreign keys on its own, so every one here gets an
-- index. Without them, loading a claim's weeks or documents, or deleting a
-- parent row, scans the whole child table.

CREATE TABLE claim (
    id               bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    claimant_id      bigint      NOT NULL REFERENCES claimant (id),
    -- The employer asked to respond. Can be empty while staff work out who
    -- that is.
    employer_id      bigint      REFERENCES employer (id),
    claim_type       text        NOT NULL CHECK (claim_type IN ('bonding', 'medical')),
    status           text        NOT NULL DEFAULT 'submitted'
                                 CHECK (status IN ('submitted', 'in_review', 'approved', 'denied', 'withdrawn')),
    submitted_at     timestamptz NOT NULL DEFAULT now(),
    decided_at       timestamptz,
    decision_reason  text,
    -- Stops the retention purge from touching this claim, whatever its age.
    legal_hold       boolean     NOT NULL DEFAULT false,
    -- A decided claim has a decision time and a reason, and an undecided one
    -- has neither, so a half-recorded decision can't be saved.
    CONSTRAINT claim_decision_recorded CHECK (
        (status IN ('approved', 'denied')) = (decided_at IS NOT NULL AND decision_reason IS NOT NULL)
    ),
    CONSTRAINT claim_decided_after_submitted CHECK (decided_at IS NULL OR decided_at >= submitted_at)
);

CREATE INDEX claim_claimant_id_idx ON claim (claimant_id);
CREATE INDEX claim_employer_id_idx ON claim (employer_id);
-- Staff work queues: oldest claims in a given status first.
CREATE INDEX claim_status_submitted_at_idx ON claim (status, submitted_at);

-- Approved leave, with dates. A claim can have more than one period, for
-- example a medical leave followed by bonding.
CREATE TABLE leave_period (
    id          bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    claim_id    bigint      NOT NULL REFERENCES claim (id),
    leave_type  text        NOT NULL CHECK (leave_type IN ('bonding', 'medical')),
    start_date  date        NOT NULL,
    end_date    date        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    CHECK (end_date >= start_date),
    -- Lets benefit_week check that its claim_id matches its leave period's.
    UNIQUE (id, claim_id)
);

CREATE INDEX leave_period_claim_id_idx ON leave_period (claim_id);

-- One payable week of a leave period and what it pays. claim_id is copied
-- down from the leave period so a payment can be unique on claim plus week.
-- The composite foreign key makes sure the copy always matches.
CREATE TABLE benefit_week (
    id                   bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    leave_period_id      bigint      NOT NULL,
    claim_id             bigint      NOT NULL,
    week_start           date        NOT NULL,
    weekly_amount_cents  integer     NOT NULL CHECK (weekly_amount_cents > 0),
    created_at           timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (leave_period_id, claim_id) REFERENCES leave_period (id, claim_id),
    -- A claim can't have the same week twice, even across leave periods.
    UNIQUE (claim_id, week_start),
    -- Lets payment check that its claim_id matches its week's.
    UNIQUE (id, claim_id)
);

CREATE INDEX benefit_week_leave_period_id_idx ON benefit_week (leave_period_id);

-- Metadata only. The file itself sits in encrypted object storage under
-- storage_key, and nothing is served until the malware scan says clean.
CREATE TABLE document (
    id             bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    claim_id       bigint      NOT NULL REFERENCES claim (id),
    document_type  text        NOT NULL CHECK (document_type <> ''),
    storage_key    text        NOT NULL UNIQUE,
    scan_status    text        NOT NULL DEFAULT 'pending'
                               CHECK (scan_status IN ('pending', 'clean', 'infected')),
    uploaded_at    timestamptz NOT NULL DEFAULT now(),
    scanned_at     timestamptz,
    CONSTRAINT document_scan_time_recorded CHECK ((scan_status = 'pending') = (scanned_at IS NULL))
);

CREATE INDEX document_claim_id_idx ON document (claim_id);
