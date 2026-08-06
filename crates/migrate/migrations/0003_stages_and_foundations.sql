-- The multi-stage technique model, the dial ranges that go with it, and the
-- breathing foundations.
--
-- A Wim Hof-style round is fast breaths, then a retention the person ends, then
-- a recovery hold — three stages, repeated as rounds. That is the general shape;
-- everything already seeded is the degenerate case of it, one stage repeated
-- once, which is exactly what the backfill below turns each of them into.

-- New value rather than a new type: `ALTER TYPE … ADD VALUE` is transactional in
-- Postgres 12 and later, on the one condition that nothing in the same
-- transaction *uses* the value. Nothing here does — the seed runs afterwards, in
-- its own transaction.
ALTER TYPE technique_goal ADD VALUE 'FOCUS';

ALTER TABLE techniques
  -- The caution a technique carries, empty where it carries none. Separate from
  -- `summary` because it has a second audience: the summary is read while
  -- choosing, this while breathing.
  ADD COLUMN safety_note text NOT NULL DEFAULT '';

CREATE TABLE technique_stages (
  technique_id text NOT NULL REFERENCES techniques (id) ON DELETE CASCADE,

  -- Position in the session, 0-based. Part of the primary key for the same
  -- reason `technique_phases.ordinal` is: two stages cannot claim one slot, and
  -- the read path gets its ordering from an index it would use anyway.
  ordinal integer NOT NULL,

  -- How many times this stage repeats its phases before the next stage begins.
  cycles integer NOT NULL CHECK (cycles > 0),

  -- Whether the person ends this stage rather than the clock. True only for a
  -- retention hold; its phases' durations then describe a typical hold rather
  -- than a scheduled one.
  open_ended boolean NOT NULL DEFAULT false,

  PRIMARY KEY (technique_id, ordinal)
);

-- Every technique that predates stages becomes one closed stage of its curated
-- cycle count. Runs before `recommended_cycles` is dropped below, which is the
-- only thing fixing the order of these statements.
INSERT INTO technique_stages (technique_id, ordinal, cycles, open_ended)
SELECT id, 0, recommended_cycles, false FROM techniques;

ALTER TABLE techniques
  DROP COLUMN recommended_cycles,
  -- Rounds, not cycles: `cycles` moved onto the stage, and what is left on the
  -- technique is how many times the whole stage list repeats. One for
  -- everything cyclic — the count only earns its name in a staged protocol.
  ADD COLUMN recommended_rounds integer NOT NULL DEFAULT 1 CHECK (recommended_rounds > 0);

ALTER TABLE technique_phases
  -- DEFAULT 0 is what makes this addable to a populated table, and it is also
  -- correct: the backfill above gave every existing technique exactly stage 0.
  -- Dropped immediately after, so no future insert can omit the column.
  ADD COLUMN stage_ordinal integer NOT NULL DEFAULT 0,

  -- The evidence-based range the phase may be dialled within. Nullable only for
  -- the length of this migration; backfilled from the curated default, which is
  -- the honest range for a phase nobody has widened yet.
  ADD COLUMN min_duration_ms integer,
  ADD COLUMN max_duration_ms integer;

UPDATE technique_phases
SET min_duration_ms = duration_ms,
    max_duration_ms = duration_ms;

ALTER TABLE technique_phases
  ALTER COLUMN stage_ordinal DROP DEFAULT,
  ALTER COLUMN min_duration_ms SET NOT NULL,
  ALTER COLUMN max_duration_ms SET NOT NULL,
  -- One constraint rather than three: what matters is that the range is usable
  -- and contains the default, and a client that renders a dial from a range not
  -- containing its own starting value has nowhere to put the handle.
  ADD CONSTRAINT technique_phases_duration_within_range
    CHECK (min_duration_ms > 0 AND min_duration_ms <= duration_ms AND duration_ms <= max_duration_ms);

-- The phase now belongs to a stage rather than straight to a technique. The key
-- stays composite instead of introducing a surrogate stage id: a stage has no
-- identity beyond its position in its technique, and a surrogate would need
-- keeping unique for a table nothing else references.
ALTER TABLE technique_phases
  DROP CONSTRAINT technique_phases_pkey,
  ADD PRIMARY KEY (technique_id, stage_ordinal, ordinal),
  DROP CONSTRAINT technique_phases_technique_id_fkey,
  ADD FOREIGN KEY (technique_id, stage_ordinal)
    REFERENCES technique_stages (technique_id, ordinal) ON DELETE CASCADE;

-- What a beginner asks before they ask which technique to do. Reference data on
-- the same footing as the catalogue: curated in `seed.rs`, served without auth,
-- and cited by M6's assistant rather than paraphrased by it.
CREATE TABLE foundation_topics (
  -- The slug is the primary key here, unlike `techniques`, because nothing
  -- references a topic by foreign key — so a surrogate id would buy only the
  -- ability to rename a slug, which is the one thing a stable key must not do.
  slug text PRIMARY KEY,

  question text NOT NULL,
  answer text NOT NULL,

  -- Curated reading order: the questions come in the order they occur to
  -- someone learning, which is neither alphabetical nor insertion order.
  sort_order integer NOT NULL
);
