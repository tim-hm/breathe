-- How many cycles a session plays by default, per technique.

ALTER TABLE techniques
  -- DEFAULT 1 is what makes this addable to a populated table, and it is also
  -- the honest answer for an uncurated row: play the cycle once. Every seeded
  -- technique overwrites it with a curated value.
  ADD COLUMN recommended_cycles integer NOT NULL DEFAULT 1
  -- A zero-cycle session has nothing to play, and the client would open a
  -- full-screen player onto an already-finished timeline.
  CHECK (recommended_cycles > 0);
