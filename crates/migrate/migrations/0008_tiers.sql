-- Two products instead of one, and the catalogue becomes something to buy.
--
-- M8 shipped a single yearly subscription whose only effect was the assistant's
-- allowance. It is now two monthly ones in a single App Store subscription
-- group: Plus opens the catalogue, Coach adds the language model. A person holds
-- at most one of them, because that is what a subscription group means, which is
-- why this stays two columns on `users` rather than a table of grants.

-- Ordered lowest to highest, and the order is the whole type: `>=` on this enum
-- is how every gate is written, so a tier added above COACH later needs no
-- comparison rewritten. Postgres orders enum labels by declaration.
CREATE TYPE subscription_tier AS ENUM ('PLUS', 'COACH');

ALTER TABLE users
  -- Renamed from `plus_until`: it is the end of whichever subscription the row
  -- holds, and a name that says Plus would be wrong for two thirds of them.
  RENAME COLUMN plus_until TO subscription_until;

ALTER TABLE users
  -- Which product the expiry above belongs to. Null exactly when
  -- `subscription_until` is null, and the pair is written and cleared together
  -- — a tier without an expiry would be a subscription that never ends.
  ADD COLUMN subscription_tier subscription_tier,

  -- The `signedDate` of the transaction these three columns came from.
  --
  -- This is what orders submissions, and it replaces the GREATEST-on-expiry rule
  -- M8 used. That rule was right while there was one product: a later expiry
  -- meant a later transaction. With two, it is wrong in the case that matters
  -- most — upgrading from Plus to Coach mid-month issues a Coach transaction
  -- whose expiry is *earlier* than the Plus period it replaced, and taking the
  -- greater expiry would leave the person paying for Coach and holding Plus.
  --
  -- Apple signs the truth at a moment; the most recently signed transaction for
  -- a subscription group is that group's current state. So the whole row moves
  -- together, and only forwards.
  ADD COLUMN subscription_signed_at timestamptz,

  -- Both halves of the pair, together or neither. Cheap to state and it makes
  -- the one bug this schema invites — writing a tier and forgetting the expiry,
  -- which reads as a free subscription — impossible rather than unlikely.
  ADD CONSTRAINT users_subscription_is_whole CHECK (
    (subscription_tier IS NULL) = (subscription_until IS NULL)
  );

-- Whether breathing this one needs a subscription.
--
-- Added with a default so the existing rows have a value, then stripped of it,
-- so `seed.rs` must state the answer for every technique it writes. A default
-- left in place is a way to add a technique and silently give it away, or
-- silently lock it, depending on which way the default happened to point.
ALTER TABLE techniques ADD COLUMN requires_subscription boolean NOT NULL DEFAULT true;
ALTER TABLE techniques ALTER COLUMN requires_subscription DROP DEFAULT;

-- No index on either. The subscription columns are read one person at a time by
-- primary key, and `techniques` is nine unpaginated rows read whole.
