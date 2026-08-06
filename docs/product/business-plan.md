# Business plan

The product definition: what we are building, for whom, why it wins, and how it pays for itself. The build order lives in [roadmap.md](roadmap.md); the market-facing name is an open decision tracked in [naming.md](naming.md) — "Breathe" is the internal working name throughout.

## Vision

A breathing app that treats a guided breath the way Apple's Watch Mindfulness app does — one beautiful, haptic-led minute — and then goes where that app refuses to: a science-backed catalogue of techniques for real goals (calm, sleep, energy, focus, reset), personalised by an assistant that learns what you need, on a phone rather than only a watch. Radically simple on the surface, deep on demand, and honest to its core: no ads, no tracking, no dark patterns, no $70 subscription.

## Positioning

The market has a barbell shape and nothing in the middle:

- **Apple Mindfulness (Watch)** — free, gorgeous, haptic-led, and too simple: one technique, no goals, no guidance, no phone experience.
- **Calm / Headspace** — content megaliths at ~$70/year: celebrity narrations, sleep stories, kids' content, and a breathing feature buried under an upsell funnel.
- **Utilitarian pacers** (iBreathe, Awesome Breathing, Breathwork: Paced Breathing) — configurable timers with little craft and no guidance.
- **Exhala** — the nearest competitor: haptic breath guidance on iPhone. No personalisation, no catalogue depth, no social layer.

We sit in the gap: **Watch-grade craft, phone-first, science-led catalogue, AI personalisation, community motivation — at an impulse price.**

**Target users:** stressed professionals who want two calm minutes between meetings; poor sleepers who found 4-7-8 on YouTube and want it guided; Watch Mindfulness users who wished it did more; breathwork-curious people put off by woo or by Calm's price.

## Differentiators

1. **Haptic craft.** Distinct vibration patterns for inhale, hold, and exhale — the phone breathes with you, eyes closed, sound off, and the same sessions live on your wrist in a full Apple Watch app. This is the hero experience and it is free, forever.
2. **Science, stated honestly.** Every technique carries its evidence and its safety notes (the seeded catalogue already writes in this voice — see `crates/migrate/src/seed.rs`). No mysticism, no medical claims.
3. **Guided personalisation.** Onboarding learns your goals; an LLM tailors recommendations and explains the why. Not a chatbot — a guide with fixed, useful entry points.
4. **User-owned attention.** Reminder intensity is a dial the user sets, and "never" is the default, not an opt-out. Nothing nudges, upsells, or guilts.
5. **Radical privacy.** No ads, no third-party trackers, no data resale. Anonymous identity by default. Privacy is a stated feature, not a settings page.
6. **Honest price.** ~$4.99/year against Calm's ~$70. Cheap enough to be an impulse subscription, sustainable because the costly feature (LLM) is what the price gates.

## Technique catalogue

Curated, goal-organised, and science-led. Each technique ships with safe defaults and carries its rationale in its summary; an **Advanced** disclosure exposes dials (per-phase durations within evidence-based safe ranges, session length, rounds, haptic/audio intensity). Simple by default, deep on demand.

| Goal   | Technique                   | Pattern                                   | Evidence anchor                                          |
| :----- | :-------------------------- | :---------------------------------------- | :------------------------------------------------------- |
| Calm   | Box breathing (seeded)      | 4-4-4-4                                   | Slow paced breathing lowers acute stress arousal         |
| Calm   | Coherent breathing          | ~5.5 breaths/min                          | HRV-resonance literature                                 |
| Sleep  | 4-7-8 (seeded)              | 4 in, 7 hold, 8 out                       | Extended exhale shifts autonomic balance parasympathetic |
| Sleep  | Extended exhale             | 4 in, 6–8 out                             | Same mechanism, gentler entry point                      |
| Reset  | Physiological sigh (seeded) | double inhale, long exhale                | Stanford 2023 cyclic-sighing study                       |
| Energy | Bellows breath (seeded)     | 1 in, 1 out, rapid                        | Traditional practice; short bouts raise alertness        |
| Energy | Wim Hof-style rounds        | 30–40 fast breaths → retention → recovery | Popular protocol; strongest safety framing in the app    |
| Focus  | Box variant                 | longer holds                              | Attentional anchor; used in high-stress professions      |
| Focus  | Alternate-nostril           | visual-cue-led                            | Traditional practice with modest trial support           |

Safety is part of the product voice: the Wim Hof-style experience is seated-only with prominent warnings (never in water, never driving), and no feature ever rewards pushing a hold to the limit — see the leaderboard design below.

**Breathing foundations.** Alongside the catalogue, the app teaches the questions most apps never answer: belly vs chest (diaphragmatic breathing and why), in through the nose (filtration, nitric oxide, natural slowing — while acknowledging nasal breathing is hard for some people at first and improves with practice), out through nose or pursed lips, posture (seated vs lying down), eyes open or closed. Everything is framed as a suggestion, never a rule: "the breathing still works while you're learning; here's how to level up." Foundations appear as a short teachable moment in onboarding, as per-session hints, and as a reference the assistant can draw on.

## Journey tracking & gamification — free

Personal stats are the retention spine: sessions completed, total breaths, cumulative minutes, streaks. The framing rule is **celebrate consistency, never pressure** — "your streak paused", never "you failed".

Competition is opt-in, under a chosen display name, comparable globally or within a voluntarily provided demographic band. Two leaderboard families:

- **Controlled-breath test** — a BOLT-style timed comfortable hold after a normal exhale: an established CO₂-tolerance metric that genuinely improves with practice, and safe to gamify.
- **Consistency boards** — streaks, minutes, sessions.

Deliberately absent: maximal breath-hold contests. Competitive max holds — especially after fast-breathing rounds — are the one place breathwork apps create real physiological risk (blackout), so the app never measures or ranks one.

All of this is free: the growth loop should have zero friction.

## Monetisation

One auto-renewable subscription via StoreKit 2. No Stripe, no web checkout, no other SKUs at launch. Small Business Program commission (15%) nets ~$4.24 of a
$4.99 year.

| Tier                | Contents                                                                                                                                                   |
| :------------------ | :--------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Free**            | Full catalogue, session player with haptics + audio, the Apple Watch app, all stats and leaderboards, one-time AI onboarding recommendation                |
| **Plus — $4.99/yr** | Ongoing AI personalisation (re-tuning, "why this technique" explanations), smart LLM-written reminders, audio soundscapes, unlimited session customisation |

The logic: the hero experience and the growth loop stay free; the marginal-cost feature (every LLM call costs real money) is exactly what the subscription gates, so cost scales with revenue. The price is low enough that the paywall funds the product rather than gating wellbeing.

## Privacy & trust commitments

Written as testable product rules, not aspirations:

1. No third-party analytics, ad, or tracking SDK ships in the binary — ever.
2. LLM calls go through our backend; the API key never ships to the client, and conversations are not stored for training.
3. Notification intensity is a user-owned dial whose zero state is **never** — the app requests notification permission only after the user moves the dial.
4. Identity is an anonymous device-generated ID; no email, no password, no account required for anything in V1.
5. Leaderboards and demographic comparison are opt-in; display names are chosen, never derived.
6. Any user can delete their data on demand, and deletion is deletion.

## Risks

| Risk                                                | Mitigation                                                                                                                                     |
| :-------------------------------------------------- | :--------------------------------------------------------------------------------------------------------------------------------------------- |
| App Review scrutiny of AI + health-adjacent content | Wellness framing, no medical claims, per-technique safety notes (already the seed-data voice); contraindications surfaced in-session           |
| LLM cost per free user                              | Personalisation is the paid tier; free tier gets one onboarding call; per-user quotas and a rule-based fallback                                |
| Crowded category, weak discoverability              | Distinctive coined name + keyword-carrying subtitle ([naming.md](naming.md)); haptic craft as the reviewable "wow"                             |
| Competition mechanics undermine the calm brand      | Opt-in only, consistency-framed copy, no maximal-hold contests                                                                                 |
| Solo-maintainer scope creep                         | Roadmap milestones are each independently shippable; the parking lot is a real fence ([roadmap.md](roadmap.md))                                |
| Full Watch app widens V1 scope                      | The watch reuses BreatheKit's platform-neutral session engine; only the haptic mapping and UI are watch-specific ([roadmap.md](roadmap.md) M9) |
