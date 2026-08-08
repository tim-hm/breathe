# Migrations

**Never change a migration that has landed on `main` — not its SQL, not its whitespace, not a comment.**

`sqlx::migrate!` checksums every file in this directory and stores that checksum on each database that runs it. Change the bytes and the checksums no longer agree, so the next `mise run migrate` fails against every database that has already applied the file — every other clone's dev database, and production, which has run the full set.

Nothing about that is visible while you make the change. A fresh database has no stored checksum to disagree with, so the edit passes `mise run check` and every e2e test, each of which builds a disposable `ond_test_<name>` from nothing. Without a guard the first place it surfaces is a deploy, after the image is already on the box.

`mise run check:migrations` is that guard. It compares this directory against `origin/main` — falling back to `main` — so the failure lands in the gate, on a fresh clone, with no database anywhere.

## Adding one

Name it `NNNN_lower_snake_case.sql`, numbered above every file already here. Do not renumber an existing migration, rename one, or slot a new one in below the highest number: sqlx applies migrations in version order, and a database that has already run the landed set cannot reproduce an order that changed underneath it.

## Where schema documentation goes

On the code that reads the column, or in `docs/`. Not in a comment here. A migration is a record of what was run, not a description of what the schema means — and a comment added to explain a constraint is an edit like any other, with the same consequences.
