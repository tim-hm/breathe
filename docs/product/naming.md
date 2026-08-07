# Naming

The name is **önd**. The App Store listing name is **ond breath**, and the domain is `ondbreathe.app`.

## How it is written

- **Display: lowercase, with the diacritic.** `önd` — in the app's wordmark, the subscription tiers (`önd Plus`, `önd Coach`), the marketing page, and prose. Not capitalised and never uppercased: `ÖND` is a different word wearing a hat, and the app's whole typographic register is lowercase already.
- **Identifiers: ASCII, always.** `Ond`, `ond`, `OND_` — Swift modules, bundle ids, the proto package, environment variables, directories, filenames, AWS resources. A non-ASCII filename normalises differently across git, macOS and Linux, and the bug that produces is invisible until it is somebody's afternoon.
- **The App Store listing carries the ASCII form** because that is what people type into search. The home-screen display name is set separately and keeps the diacritic.

## Still open

The name is decided and shipping; two checks from the list below have not been run against it, and both should happen before submission rather than after:

1. **Trademark search** — USPTO and EUIPO, Nice classes 9 (software), 42 (SaaS), 44 (health/wellness). This is the check that killed the previous candidate.
2. **App Store Connect name reservation** — the only authoritative claim on `ond breath`. A reservation costs nothing and holds the name; nothing is reserved yet.

## How we got here

**Breathe** was the internal working name and is unusable as a listing name: at least six live apps use it or a close variant, and Apple's own Watch app owned the word for years (renamed _Mindfulness_ in watchOS 8, partly because the space is so crowded). Nothing answers to it now: the OpenTofu state bucket and the `breathe-tofu` IAM user were the last two holdouts, operator-only and carried for a while as legacy, and both were renamed to `ond-*` once it was clear the inconsistency cost more attention than the migration did. The word survives in the codebase only as a verb, which is the one place it was never a brand.

**Cadence** was carried as far as validation as the market-facing name and taken no further. What validation found, in August 2026, via the iTunes Search API (US storefront) and DNS:

- **App Store**: 51 US apps matched "cadence"; roughly half branded `Cadence: <something>`, none holding the bare name and none a breathing or meditation app.
- **Discoverability**: mixed. "Cadence" surfaces run and bike trackers — running cadence is a core fitness term — so brand searches would have shown competitors above us early on.
- **Trademarks**: Cadence Design Systems is large but in a different field (class 9); _Cadence Health_ (cadence.care, remote patient monitoring) sits uncomfortably close to the health and wellness classes. This was flagged at the time as the check most likely to kill the name.
- **Domains**: `cadence.app` parked for sale at a premium; `getcadence.app` taken by the bike-tracker developer.

## Constraints learned from research

Kept because they apply to any future rename, and to the subtitle:

- **App Store listing names are globally unique.** The name is claimed the moment another developer registers it, and Apple also rejects names confusingly similar to existing apps. The home-screen display name is set separately and need not be unique.
- The winning pattern in the category is a distinctive brand word plus a keyword-carrying subtitle — `Coherence – Breathwork`, `iBreathe – Relax and Breathe`. The subtitle does the search work, which is what frees the brand word to be distinctive, and what `ond breath` leans on.

## Validation checklist

For any future candidate, in this order — each step is cheaper than the one after it:

1. **App Store search** for the exact word and near-collisions in Health & Fitness and Lifestyle.
2. **Domain availability** — `.app` (requires HTTPS, which we ship anyway) and one fallback.
3. **Trademark search** — USPTO and EUIPO, classes 9, 42, 44.
4. **App Store Connect name reservation** — the only authoritative check.
5. **Say-it-aloud test** — tell three people about the app; if they cannot spell it or find it afterwards, it fails.
