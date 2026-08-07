-- What somebody has bought, on the row that already says who they are.
--
-- Columns on `users` rather than an `entitlements` table: there is exactly one
-- subscription, one row per person, and no history worth keeping — a renewal
-- replaces the expiry it extends. A child table would buy a join and an
-- ordering question in exchange for rows nothing reads.
--
-- The client is the authority on what the *UI* offers: StoreKit answers
-- `currentEntitlements` offline and every gate in the app reads it from there.
-- This is the authority on what the *server* spends, which is a different
-- question with a different threat model — a modified client can claim anything
-- it likes, and the language-model allowance costs real money.

ALTER TABLE users
  -- When the current subscription period ends, or NULL for the vast majority of
  -- rows that have never bought anything. Nullable rather than defaulted to a
  -- past timestamp so "never subscribed" and "lapsed" stay distinguishable in
  -- the data even though both read as FREE.
  --
  -- Never moved backwards: a client resubmits whatever StoreKit hands it, and
  -- an older transaction arriving after a newer one is ordinary — see
  -- `record_entitlement`.
  ADD COLUMN plus_until timestamptz,

  -- The App Store's `originalTransactionId`: stable across every renewal of one
  -- subscription, which is what makes resubmitting the same purchase a no-op
  -- rather than a second grant.
  --
  -- Deliberately not UNIQUE. It would stop one purchase entitling two anonymous
  -- identities, which is worth roughly $4.99 a year, at the cost of failing a
  -- legitimate person who reached this app with a new identity and the same
  -- Apple ID — the wrong side of that trade for a product with no account
  -- recovery.
  ADD COLUMN app_store_original_transaction_id text;

-- No index. Every read is one person by primary key; nothing sweeps by expiry
-- (there is no renewal job — the tier is derived on read) and nothing looks a
-- person up by transaction id.
