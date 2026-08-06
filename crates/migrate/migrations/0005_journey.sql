-- What a person has done, as opposed to what they told us about themselves:
-- the sessions they breathed, the controlled pauses they measured, and the two
-- profile columns that decide whether anyone else can see either.
--
-- Everything here is append-only history. Streaks, totals, and every board are
-- derived on read from these rows — there is not a single counter column,
-- because a counter is a second source of truth that can only ever drift away
-- from the first.

CREATE TYPE birth_year_band AS ENUM (
  'BORN_BEFORE_1960',
  'BORN_1960S',
  'BORN_1970S',
  'BORN_1980S',
  'BORN_1990S',
  'BORN_2000S',
  'BORN_2010_OR_LATER'
);

ALTER TABLE users
  -- Null, not empty string, for "they have not chosen one": the uniqueness
  -- index below has to let every anonymous row coexist, and a null is the only
  -- value a unique index ignores.
  ADD COLUMN display_name text CHECK (char_length(display_name) BETWEEN 2 AND 24),

  ADD COLUMN birth_year_band birth_year_band;

-- Case-insensitive, so `tim` cannot stand next to `Tim` on a board and be read
-- as the same person. The server suffixes a colliding name rather than
-- rejecting it, and this index is what tells it a collision happened.
CREATE UNIQUE INDEX users_display_name_key ON users (lower(display_name));

-- No index on `birth_year_band`. The board queries reach `users` by primary key
-- through a join and filter the band with `$n IS NULL OR band = $n`, which the
-- planner cannot turn into an index scan against a parameter — so an index here
-- would cost a write on every profile save and serve no read.

CREATE TABLE sessions (
  user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,

  -- Minted by the client when the session ends, so a session recorded with no
  -- signal already has its identity. Half the primary key, which is what makes
  -- a re-sync an `ON CONFLICT DO NOTHING` rather than a duplicate.
  client_session_id uuid NOT NULL,

  -- Text, with deliberately no foreign key to `techniques`. The catalogue is
  -- reseeded reference data whose slugs may be renamed or retired, and a
  -- session someone actually breathed must never be rejected — or deleted —
  -- because the technique it names has since moved. A slug the catalogue no
  -- longer knows displays as itself rather than vanishing.
  technique_slug text NOT NULL CHECK (char_length(technique_slug) BETWEEN 1 AND 64),

  -- When the session began, not when it reached here. The two can be a week
  -- apart, and every streak is computed from this one.
  started_at timestamptz NOT NULL,

  duration_ms integer NOT NULL CHECK (duration_ms >= 0),
  cycles_completed integer NOT NULL CHECK (cycles_completed >= 0),
  breath_count integer NOT NULL CHECK (breath_count >= 0),

  -- Whether the timeline ran out, as opposed to the person ending it early.
  -- Both are recorded; nothing in the app treats an early end as a failure.
  completed boolean NOT NULL,

  recorded_at timestamptz NOT NULL DEFAULT now(),

  PRIMARY KEY (user_id, client_session_id)
);

-- Every read of this table is one person's history in time order — the history
-- strip, the totals, and the day list every streak is folded from.
CREATE INDEX sessions_user_started_at_idx ON sessions (user_id, started_at DESC);

CREATE TABLE bolt_scores (
  user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,

  -- Minted by the client, exactly as `sessions.client_session_id` is: both
  -- streams drain through one sync queue, so both need a resend to be free.
  -- A generated identity here instead would make the client's own ledger the
  -- only thing preventing duplicates, and a cleared ledger would quietly
  -- inflate somebody's pause history.
  client_score_id uuid NOT NULL,

  -- Seconds. Bounded well above any comfortable pause so the column rejects a
  -- client sending milliseconds by mistake, which would otherwise install an
  -- unbeatable personal best.
  seconds integer NOT NULL CHECK (seconds > 0 AND seconds <= 600),

  measured_at timestamptz NOT NULL DEFAULT now(),

  PRIMARY KEY (user_id, client_score_id)
);

-- Ordered by score, not by date: both readers ask for a maximum — one person's
-- personal best, and the best per person for the board — so leading with
-- `seconds` answers them from the index instead of aggregating the heap. Nothing
-- yet reads this history in date order; index that when something does.
CREATE INDEX bolt_scores_user_seconds_idx ON bolt_scores (user_id, seconds DESC);
