-- Techniques a person composed for themselves, stored server-side so they are
-- the same technique on every device they sign the same id in from.
--
-- Three tables mirroring the catalogue's three, and deliberately not the same
-- three. A user technique shares the catalogue's *shape* — a technique holds
-- ordered stages, a stage holds ordered phases — but none of its columns:
-- there is no curated sort order, no subscription flag, no safety note, and no
-- per-phase safe range. Folding them into `techniques` would mean every one of
-- those columns becoming nullable, every catalogue read growing a
-- `WHERE user_id IS NULL`, and the assistant's slug resolution quietly gaining
-- a way to name somebody's private exercise. A parallel table costs one more
-- read on one screen.

CREATE TABLE user_techniques (
  -- Server-minted. Unlike `users.id`, which the client generates because it has
  -- to survive a reinstall before any server has seen it, this id is only ever
  -- meaningful after the row exists.
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Deleting a person deletes what they wrote. There is nothing here anybody
  -- else can read, so there is nothing to keep.
  user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,

  -- Bounded in the schema as well as in the service, because this is the one
  -- free-text column in the feature and the bound is the difference between a
  -- name and a payload.
  name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 60),

  goal technique_goal NOT NULL,

  -- How many times a session repeats the whole stage list, matching
  -- `techniques.recommended_rounds`.
  rounds integer NOT NULL CHECK (rounds > 0),

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- The list query is "this person's techniques, oldest first" and nothing else,
-- so the index covers it whole. Worth having here where it was not worth having
-- on `techniques`: that table is bounded by what we curate, this one by how many
-- people install the app.
CREATE INDEX user_techniques_by_owner ON user_techniques (user_id, created_at);

CREATE TABLE user_technique_stages (
  technique_id uuid NOT NULL REFERENCES user_techniques (id) ON DELETE CASCADE,

  -- Position in the session, 0-based, part of the key for the same reason it is
  -- on `technique_stages`: two stages cannot claim one slot, and the read path
  -- gets its ordering from an index it would use anyway.
  ordinal integer NOT NULL,

  cycles integer NOT NULL CHECK (cycles > 0),

  PRIMARY KEY (technique_id, ordinal)
);

-- No `open_ended` column, unlike `technique_stages`. A retention the person ends
-- rather than the clock is the one part of the model with a real
-- contraindication behind it, and it belongs to the curated protocols that carry
-- the copy explaining it. Absent rather than present-and-always-false so that
-- authoring one is unrepresentable rather than merely unoffered.
CREATE TABLE user_technique_phases (
  technique_id uuid NOT NULL,
  stage_ordinal integer NOT NULL,
  ordinal integer NOT NULL,

  kind phase_kind NOT NULL,

  -- No `min_duration_ms`/`max_duration_ms` either. The bound on an authored
  -- phase is derived from the catalogue's seeded ranges at write time, so
  -- storing a copy per row would freeze a limit that is supposed to move when
  -- the seed does.
  duration_ms integer NOT NULL CHECK (duration_ms > 0),

  PRIMARY KEY (technique_id, stage_ordinal, ordinal),
  FOREIGN KEY (technique_id, stage_ordinal)
    REFERENCES user_technique_stages (technique_id, ordinal) ON DELETE CASCADE
);
