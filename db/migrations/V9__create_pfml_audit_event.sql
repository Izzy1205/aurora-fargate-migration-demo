-- V9: PFML schema, part 4. The audit trail.
--
-- The app connects with one login, so the database can't tell which staff
-- member did something. The app writes that here: who, what, which record,
-- when, before and after for changes, and a reason for sensitive views.
-- Rows are add-only (afterMigrate.sql takes UPDATE and DELETE away from the
-- app login) and get copied to a locked log store staff can't edit. That
-- copy is the real record; this table is for searching.

CREATE TABLE audit_event (
    id           bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    occurred_at  timestamptz NOT NULL DEFAULT now(),
    -- Staff user, claimant sign-in ID, or a system job name.
    actor        text        NOT NULL CHECK (actor <> ''),
    action       text        NOT NULL CHECK (action <> ''),
    -- Points at any record, so there's no foreign key: the table name and
    -- the row's id.
    record_type  text        NOT NULL,
    record_id    bigint      NOT NULL,
    before_data  jsonb,
    after_data   jsonb,
    reason       text
);

-- "Everything that happened to this claim" and "everything this person did".
CREATE INDEX audit_event_record_idx ON audit_event (record_type, record_id, occurred_at);
CREATE INDEX audit_event_actor_idx ON audit_event (actor, occurred_at);
