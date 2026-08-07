-- One App Store transaction, one identity at a time.
--
-- 0007 left `app_store_original_transaction_id` "deliberately not UNIQUE",
-- trading one purchase entitling two anonymous identities — worth roughly $4.99
-- a year at the time — against failing somebody who reinstalled and reached this
-- app with a new identity and the same Apple ID. Tiers repriced that trade.
-- Coach's whole content is the language model, its allowance is counted per user
-- per UTC day, and a `jwsRepresentation` is a plain string somebody can copy off
-- their own device and replay from any client under any self-minted UUID. The
-- leak stopped costing one subscription and started costing provider spend per
-- identity, without limit.
--
-- The reinstall case is served by letting the binding *move* rather than by
-- leaving it off — see `entitlement::service::claim`, which is where the rule
-- for when it may lives.

ALTER TABLE users
  -- When the current holder claimed the transaction id beside it, or NULL for
  -- the vast majority of rows holding none. NULL also for any row bound before
  -- this migration, which reads as "long ago" and so is freely transferable.
  --
  -- Exists to rate-limit the move. A transfer with no cooldown turns the fan-out
  -- this migration closes into the same fan-out taken in turns — one identity's
  -- daily allowance, then the next identity's. A reinstall is rare; a rotation
  -- is not.
  ADD COLUMN subscription_claimed_at timestamptz,

  -- The binding itself. Postgres treats NULLs as distinct, so the rows that have
  -- bought nothing are unaffected and no partial index is needed.
  --
  -- A backstop rather than the check: a constraint violation surfaces to the
  -- client as an opaque `internal`, so `entitlement::service` refuses a
  -- conflicting claim with a real status and this catches only the race between
  -- two submissions of the same transaction landing together.
  --
  -- Adding it fails the migration if two rows already hold one transaction id.
  -- That is the intended behaviour: such a pair is a replay that has already
  -- happened, and deciding which of the two identities keeps the subscription is
  -- not a decision a migration should make silently.
  ADD CONSTRAINT users_app_store_original_transaction_id_key
    UNIQUE (app_store_original_transaction_id);

-- No index on `subscription_claimed_at`. It is read only alongside the row the
-- unique constraint above already located, and nothing sweeps by it.
