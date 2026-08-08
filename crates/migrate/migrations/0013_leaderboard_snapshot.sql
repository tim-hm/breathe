-- The boards, folded once instead of once per caller.
--
-- `0005_journey.sql` says there is not a single counter column, because a
-- counter is a second source of truth that can only ever drift away from the
-- first. That still holds. Nothing here is a counter: no row is ever
-- incremented, and every key is deleted and re-derived wholly from `sessions`
-- and `bolt_scores` by one statement. What this is, is a cache with a stated
-- staleness bound — it can be dropped entirely and the next read rebuilds it
-- byte for byte, which is exactly what a counter could not do.
--
-- Why it earns the second table at all: ranking needs every candidate row, so
-- the fold cannot be narrowed to the twenty entries that get shown. The streak
-- board reads each recently active person's whole history, and the minutes
-- board sums thirty days across everybody — per request, for every caller who
-- opens the tab, on the fastest-growing table in the schema.

CREATE TYPE leaderboard_board AS ENUM ('STREAK', 'MINUTES_30D', 'BOLT');

-- One person's score on one board, as of the last refresh of that board.
--
-- Scores rather than finished boards. A board's ranking depends on the scope
-- the caller asked for — everyone, or their own birth-year band — so
-- materialising the ranking would mean one copy of every row per band, eight
-- times the storage and eight times the refresh, to save a window function over
-- a table that holds one narrow row per person. The expensive half is the fold;
-- the ranking is not.
--
-- `utc_offset_minutes` is part of the key because a streak is a run of *local*
-- calendar days: the same history yields a different streak depending on where
-- the person asking is standing, and `journey_service.proto` is explicit that
-- the offset is sent per request and never stored. So the streak board is
-- materialised once per day boundary anybody actually asks for, and the answer
-- stays exactly the one the live fold gave rather than an approximation of it.
-- The key space is finite because `validated_offset` refuses an offset that is
-- not a whole number of quarter-hours between -12:00 and +14:00.
--
-- The other two boards have no local-day question — a rolling thirty days and a
-- personal best are the same number at every offset — so they are folded once,
-- under the key 0. That is a real offset rather than a sentinel standing in for
-- one, and for those boards it is not a lie: their answer at offset 0 is their
-- answer everywhere.
CREATE TABLE leaderboard_snapshot (
  board leaderboard_board NOT NULL,

  -- The day boundary this row was folded at, east-positive, as
  -- `GetLeaderboardRequest` carries it. `integer` rather than `smallint`
  -- because that is the width the value has everywhere else it exists, and two
  -- bytes a row is not worth a narrowing conversion that can fail.
  utc_offset_minutes integer NOT NULL,

  user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,

  -- Days, minutes, or seconds, depending on the board. Non-negative for the
  -- same reason every aggregate this feature serves is: the read path narrows
  -- it onto an unsigned wire field and fails rather than clamping.
  value integer NOT NULL CHECK (value >= 0),

  PRIMARY KEY (board, utc_offset_minutes, user_id)
);

-- No index beyond the primary key. Every read takes one key and ranks the rows
-- under it, which is a prefix scan of the primary key; an index on `value`
-- would order rows the read still has to join to `users` row by row to filter
-- the band and fetch the display name, so it would sort nothing the join did
-- not resort. Index this when a plan says to.

-- When each key was last folded, and the lock that decides who folds it.
--
-- Separate from the snapshot rather than a `refreshed_at` column on it, because
-- a board can legitimately have no rows — nobody holds a current streak — and
-- `max(refreshed_at)` over zero rows cannot tell that apart from a board that
-- has never been folded. The first would then re-fold on every request forever,
-- which is the cost this whole migration exists to remove.
--
-- A refresh takes `FOR UPDATE` on this row, so two requests that find the same
-- key stale do not both fold it. That is correctness, not just economy: the
-- refresh deletes a key's rows and reinserts them, and two such transactions
-- interleaved under READ COMMITTED both delete the rows they can see and then
-- collide on the primary key.
CREATE TABLE leaderboard_refresh (
  board leaderboard_board NOT NULL,
  utc_offset_minutes integer NOT NULL,

  -- `-infinity` is what a row is created with when a request finds a key it has
  -- to lock before folding, and means "never folded". A real timestamp means
  -- the rows under this key are the fold as of that moment.
  refreshed_at timestamptz NOT NULL,

  PRIMARY KEY (board, utc_offset_minutes)
);
