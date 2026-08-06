-- The first user state in the schema: an anonymous identity, and the answers
-- onboarding collects against it.
--
-- The id is generated on the client and stored in its Keychain, so it survives a
-- reinstall and is the same value on a phone and, from M9, on a watch. Nothing
-- here is a credential — possession of the id is the whole of the claim — which
-- is exactly why Sign in with Apple gets a column below rather than a promise.

CREATE TYPE experience_level AS ENUM ('NEW', 'OCCASIONAL', 'REGULAR');

-- NEVER is first for readability only; what fixes it as the default is the
-- column default below and the zero value in the proto enum.
CREATE TYPE reminder_intensity AS ENUM ('NEVER', 'GENTLE', 'DAILY');

CREATE TABLE users (
  -- The client-generated UUID, taken as-is rather than reissued: a server-side
  -- id would need a handshake before the first RPC could be attributed, and the
  -- client already has to persist something to survive a reinstall.
  id uuid PRIMARY KEY,

  -- The Sign in with Apple seam, deferred past V1. Nullable because almost
  -- every row will have none, and UNIQUE so that when the flow does land, two
  -- anonymous identities cannot both claim one Apple account — the ambiguity
  -- would have to be resolved by hand, after the fact.
  apple_user_id text UNIQUE,

  -- What they are here for. An array rather than a child table because goals
  -- are a small set read and written whole, with no per-row attributes to hang
  -- on them; the ordered child tables in this schema exist for data that has
  -- both.
  goals technique_goal[] NOT NULL DEFAULT '{}',

  -- Null until they answer, which is a real state: the row is created by the
  -- identity layer on the first RPC, before anyone has been asked anything.
  experience_level experience_level,

  -- NOT NULL with a default of NEVER, so a row that exists without an answer
  -- still reads as "do not contact me". The privacy stance has to survive a
  -- partially written row, not just a well-behaved client.
  reminder_intensity reminder_intensity NOT NULL DEFAULT 'NEVER',

  -- Free text, in their words. Bounded because nothing reads it in bulk and an
  -- unbounded text column on a user-writable field is a row somebody eventually
  -- pastes a book into.
  intent_note text NOT NULL DEFAULT '' CHECK (char_length(intent_note) <= 500),

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
