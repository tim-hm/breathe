-- The technique catalogue: reference data describing what to breathe and for
-- how long. No user state lives here.

-- Native enums rather than text + CHECK. The proto contract already fixes these
-- value sets, and a native type makes the database reject a fifth goal at write
-- time instead of letting it reach the client as an unmapped variant.
CREATE TYPE technique_goal AS ENUM ('CALM', 'SLEEP', 'ENERGY', 'RESET');
CREATE TYPE phase_kind AS ENUM ('INHALE', 'HOLD_IN', 'EXHALE', 'HOLD_OUT');

CREATE TABLE techniques (
  id text PRIMARY KEY,

  -- The key the client pins its artwork and haptic patterns to. Unique and
  -- stable across reseeds, which `id` is not required to be.
  slug text NOT NULL UNIQUE,

  name text NOT NULL,
  summary text NOT NULL,
  goal technique_goal NOT NULL,

  -- Curated presentation order. Not derived from name or goal, because the
  -- intended reading order puts the most approachable technique first.
  sort_order integer NOT NULL,

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- No index on `sort_order`. The catalogue is curated and small — single digits
-- now, tens at most — so the planner would seq-scan and sort regardless, and the
-- index would only add write cost on every reseed.

-- Phases are a child table rather than a JSON column on `techniques`: they are
-- ordered, queried as a set, and their shape is fixed by the proto contract.
-- JSON would buy schema flexibility this data does not want and cost the
-- ordering guarantee the primary key gives for free.
CREATE TABLE technique_phases (
  technique_id text NOT NULL REFERENCES techniques (id) ON DELETE CASCADE,

  -- Position in the cycle, 0-based. Part of the primary key, so a technique
  -- cannot hold two phases in the same slot and the read path gets its ordering
  -- from an index it was going to use anyway.
  ordinal integer NOT NULL,

  kind phase_kind NOT NULL,

  -- Milliseconds. A zero-length phase would stall the client's animation loop
  -- on a segment it can never advance past.
  duration_ms integer NOT NULL CHECK (duration_ms > 0),

  PRIMARY KEY (technique_id, ordinal)
);
