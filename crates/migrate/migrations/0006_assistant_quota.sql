-- The daily allowance of language-model calls, per person.
--
-- In Postgres rather than in the process because it has to survive a restart: a
-- counter held in memory resets on every deploy, and a deploy is exactly when a
-- cost control must not quietly reopen. It is also the only assistant state
-- worth keeping — prompts, replies, and explanations are never stored, so the
-- one row per person per day is the whole audit trail.

CREATE TABLE assistant_usage (
  user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,

  -- The UTC day the calls were made on. UTC, not the caller's local day, and
  -- deliberately unlike `journey`'s streaks: a streak is something a person is
  -- shown and must therefore match the calendar they live in, whereas this is a
  -- spend limit nobody sees. A client-supplied offset here would be a lever for
  -- claiming two allowances by flying east.
  usage_date date NOT NULL,

  -- Calls charged against the allowance, incremented as each is claimed.
  -- Claimed before the call rather than recorded after it: a model call that
  -- times out has still cost money, and a counter that only counted successes
  -- would let a failing model be retried without limit.
  calls integer NOT NULL DEFAULT 0 CHECK (calls >= 0),

  PRIMARY KEY (user_id, usage_date)
);

-- No index beyond the primary key. Every read is one person on one day, which
-- the primary key already answers; nothing sweeps the table by date, and a
-- retention job that eventually does will scan it once a night regardless.
