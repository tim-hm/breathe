# Naming brief

The market-facing name is undecided; **Breathe** remains the internal working name (bundle id `xyz.holmie.breathe`, repo name, code identifiers) until a candidate survives the validation checklist below. Nothing in the codebase blocks on this decision — the display name and App Store listing name are metadata, set at submission time.

## Constraints learned from research

- **App Store listing names are globally unique.** The name is claimed the moment another developer registers it, and Apple also rejects names confusingly similar to existing apps. The home-screen display name is set separately and need not be unique.
- **"Breathe" is unusable** as a listing name: at least six live apps use it or a close variant, and Apple's own Watch app owned the word for years (they renamed it _Mindfulness_ in watchOS 8, partly because the space is so crowded).
- **"Exhale" is conflicted**: _Exhale App_ is an established wellbeing app, and _Exhala_ is a direct competitor that already ships haptic breath guidance.
- The winning pattern in the category is a distinctive brand word plus a keyword-carrying subtitle — `Coherence – Breathwork`, `iBreathe – Relax and Breathe`. The subtitle does the search work, so the brand word is free to be distinctive.

## Shortlist

Ordered by current preference. None validated yet — see the checklist.

| Candidate | Rationale | Watch-outs |
| :-- | :-- | :-- |
| **Pneuma** | Greek for breath/spirit/life-force; premium, short, ownable; no breathing-app conflict found in searches | Check pronunciation friction ("NOO-ma"); several non-app wellness businesses use it |
| **Caesura** | The held pause — in poetry and music, the deliberate break; precisely what a breath hold is | Spelling is hard to type from memory; check literary-app conflicts |
| **Lento** | Musical tempo marking for "slow"; breath pacing is tempo; two syllables, easy to say | Common word in Romance languages; check trademark breadth |
| **Cadence** | The rhythm of a breath cycle; warm and familiar; "cadence breathing" is a real synonym for coherent breathing | See the validation results below — viable with a subtitle, but crowded |
| **Sough** | The soft sound of wind or slow breathing; genuinely rare word | Pronunciation is ambiguous ("sow"/"suff") — likely fails the say-it-aloud test |
| **In Hold Out** | Tim's original candidate; literal (the breath cycle itself), memorable, no conflicts found | Awkward to say aloud and to search; keep as fallback |

Recommended listing pattern once chosen: `<Name>: Breathe & Calm` or `<Name> – Guided Breathing`, so the subtitle carries the category keywords.

## Cadence — validation results (August 2026)

Checked via the iTunes Search API (US storefront) and DNS:

- **App Store**: 51 US apps match "cadence"; roughly half are branded `Cadence: <something>` — but none holds the bare name `Cadence`, and none is a breathing or meditation app. `Cadence: Guided Breathing` looks reservable; only an App Store Connect reservation proves it.
- **Discoverability**: mixed. A search for "cadence" surfaces run/bike trackers (running cadence is a core fitness term), so brand searches will show competitors above us early on. Nobody searching "breathing app" collides with those, though — the subtitle carries that traffic.
- **Trademarks (needs a real search before committing)**: Cadence Design Systems is a large software company (class 9, different field); _Cadence Health_ (cadence.care, remote patient monitoring) is uncomfortably close to the health/wellness classes. This is the check most likely to kill the name.
- **Domains**: `cadence.app` is parked for sale at Afternic (expect a premium price); `getcadence.app` is taken by the bike-tracker developer; `cadencebreathing.com` is registered; `breathecadence.com` shows no DNS delegation and is likely available.

## Validation checklist

Run per candidate, in this order — each step is cheaper than the one after it:

1. **App Store search** for the exact word and near-collisions in the Health & Fitness and Lifestyle categories.
2. **Domain availability** — `.app` (requires HTTPS, which we ship anyway) and one fallback (`.com` or a `get<name>.app` pattern).
3. **Trademark search** — USPTO and EUIPO, Nice classes 9 (software), 42 (SaaS), 44 (health/wellness services).
4. **App Store Connect name reservation** — the only authoritative check; create the app record with the candidate name to claim it. Reserve the winner immediately; a reservation costs nothing and holds the name.
5. **Say-it-aloud test** — tell three people about the app; if they can't spell it or find it afterwards, it fails.
