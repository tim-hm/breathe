# Roadmap to V1

Ten milestones, each independently shippable and testable, ordered so that every step delivers user value or unblocks the next. The product rationale for each feature is in [business-plan.md](business-plan.md); this doc records the build order and the technical decisions already made.

Current state: M1–M9 have shipped against a live backend (see [deployment.md](../deployment.md)), and M10 is the only one still ahead. Everything below is kept in the future tense it was written in — the technical decisions each milestone records are why the code looks the way it does, and a plan edited into a changelog loses them.

## M1 — Breathing session player

The product's reason to exist: tap a technique, get a full-screen guided session with animated visual, per-phase haptics, audio cues, pause/end, and a completion summary.

- **Phase engine**: a pure `SessionTimeline` value type in `BreatheKit` — phase boundaries precomputed from t=0, `phase(at:)` a pure lookup. Visuals read it through `TimelineView(.animation)`; haptic/audio events come from one `@MainActor` async loop sleeping on a `ContinuousClock` until each boundary. Absolute-time scheduling, not accumulating timers: no drift, and clean under Swift 6 strict concurrency.
- **Haptics**: `CHHapticEngine` behind a `HapticController`. Inhale = rising intensity curve over the phase; exhale = mirrored falling curve; hold-in = a firm entry transient; hold-out = a softer, duller one (the proto already insists the two holds feel different). `UIImpactFeedbackGenerator` fallback where `supportsHaptics` is false. Engine lifecycle (interruption, background) is the known pothole — test on a device early; the simulator has no haptics.
- **Audio**: short pre-rendered cue tones via `AVAudioPlayer`, session category `.playback` with `.mixWithOthers`. Three user modes: haptics+audio, haptics only, visual only.
- **Session length**: proto gains `recommended_cycles` on `Technique` (migration `0002` + `crates/migrate/src/seed.rs` + both codegens) — curated reference data like everything else on the message. User overrides live client-side until identity exists (M4).
- **Accessibility & housekeeping**: Reduce Motion swaps the scaling orb for a progress ring; VoiceOver announces phase changes; the idle timer is disabled mid-session. Sessions are recorded locally from day one — M5 syncs them.

Touches: `proto/breathe/v1/technique_service.proto`, `crates/api/src/features/technique/`, `crates/migrate/`, new `ios/Breathe/Features/Session/`, `BreatheKit`.

## M2 — Catalogue expansion + advanced dials

Seed the science-led set from the business plan (coherent breathing, extended exhale, Wim Hof-style rounds, box variant, alternate-nostril). Per-technique safety copy surfaces in the session UI, not just the list.

- **Multi-stage technique model.** The Wim Hof-style structure (fast breaths → retention → recovery, several rounds) becomes the general case that plain cyclic techniques degenerate to. Proto: `Technique` gains `repeated Stage stages` and `recommended_rounds`, where `Stage { repeated Phase phases; uint32 cycles; bool open_ended; }` — `open_ended` marks the retention hold the user ends themselves. A seeded box breathing is then one stage, `cycles = recommended_cycles`, closed-ended. This **replaces** `Technique.phases` from M1 — a breaking proto change, made deliberately while no released client exists: regenerate both languages and update the seed atomically in one commit, and accept the one-time `buf breaking` override that commit needs (`check:proto` exists to protect released clients; there are none yet). Schema: a new `technique_stages` table (`technique_id, ordinal, cycles, open_ended`); `technique_phases` moves its foreign key to the stage.
- **Advanced dials.** `Phase` gains `min_duration_ms` / `max_duration_ms` — the evidence-based safe range, seeded per phase, so every client renders dials from data instead of hardcoding limits. User overrides stay client-side (UserDefaults) until M4 profiles exist, then sync.
- **Breathing foundations.** The nose/belly/posture/eyes guidance from the business plan as seeded reference data: `foundation_topics` table (`slug, question, answer, sort_order`) served by a new `TechniqueService.ListFoundations` RPC (public reference data, same no-auth stance). The session UI shows suggestion-framed hints from it; M6's assistant cites the same rows.

Touches: `proto/breathe/v1/technique_service.proto`, migration `0003`, `crates/migrate/src/seed.rs`, `crates/api/src/features/technique/`, `BreatheKit` (`Technique.swift` grows stages; `SessionTimeline` flattens stages × cycles into its absolute-time boundary list — open-ended stages pause the clock until the user taps).

## M3 — Adaptive theme

Replace the four hardcoded `Color` literals in `ios/Packages/BreatheCore/Sources/BreatheUI/Theme.swift` with light/dark asset-catalog colors inside the BreatheUI target (`Bundle.module`), plus semantic surface/text tokens. Done now so onboarding and paywall screens are born themed.

## M4 — Onboarding + identity

- **Onboarding**: a friendly stepper — goals, experience level, and the reminder-intensity dial whose zero state is _never_.
- **Identity**: the seam `architecture.md` deliberately deferred gets its design here. Anonymous UUID generated client-side, stored in the Keychain (survives reinstall), sent as a header via a Connect-Swift interceptor in `BreatheAPI/Clients.swift`. A server layer lazily upserts a `users` row and injects the id into request extensions. `TechniqueService` stays public. Sign in with Apple is deferred; the `users` table leaves an `apple_user_id` seam.
- **Proto**: new `ProfileService` (get/update goals, reminder intensity, intent note) with `crates/api/src/features/profile/` cloned from the `technique` layout; register in `grpc.rs`.
- **Infra**: first real deployment (managed Postgres + HTTPS host) lands here — M6 TestFlight testers need a reachable backend.

## M5 — Journey tracking & gamification (free)

All free by product decision; requires M4's identity header on every RPC.

- **Proto** — new `proto/breathe/v1/journey_service.proto`, one service, four RPCs:
  - `RecordSessions(repeated SessionRecord) returns (RecordSessionsResponse)` — batch, because M1 records sessions locally and the client syncs opportunistically. `SessionRecord { client_session_id (uuid, idempotency key), technique_slug, started_at, duration_ms, cycles_completed, breath_count, completed }`. Server upserts on `(user_id, client_session_id)` so retries and double-syncs are harmless.
  - `GetJourney` → totals (sessions, breaths, minutes), current and best streak, last N sessions. Streaks are computed on read in SQL from calendar days in the user's UTC offset (sent per request, not stored) — no denormalised counters to drift.
  - `RecordBoltScore(seconds)` — the BOLT-style controlled-breath test, measured client-side in its own small guided flow; server keeps history and best.
  - `GetLeaderboard(board, scope)` — `board ∈ {STREAK, MINUTES_30D, BOLT}`, `scope ∈ {GLOBAL, AGE_BAND}` — returns top entries plus the caller's own rank. Only controlled-test and consistency boards exist — no maximal-hold contests (rationale in the business plan).
- **Opt-in social** — leaderboards return only users who set a display name via `UpdateProfile` (M4's `ProfileService` gains `display_name` and optional `birth_year_band`). Display names are user-chosen, screened against a denylist at V1, unique-suffixed on collision. No display name → invisible to others, boards still show your own rank against anonymous aggregate.
- **Schema** — migration adds `sessions` (append-only, indexed on `(user_id, started_at)`), `bolt_scores`, and profile columns. Leaderboards are plain indexed queries at V1 scale; materialise later if they get hot.
- **Feature crate** — `crates/api/src/features/journey/` cloned from the `technique` layout; register in `grpc.rs`.
- **iOS** — journey tab (stats, streak, BOLT flow) in `ios/Breathe/Features/Journey/`; sync queue in `BreatheKit` draining the local session store from M1. Copy follows the framing rule: celebrate consistency, never pressure ("your streak paused", never "you failed").

## M6 — AI guided personalisation

`crates/api/src/features/assistant/` mirroring the `technique` crate. The model is reached over **OpenRouter** — one OpenAI-shaped HTTP API in front of every provider, so changing model is a constant rather than a client — calling `~anthropic/claude-haiku-latest`, a floating alias that tracks the newest Haiku (the leading `~` is part of the id). Haiku because both RPCs are short, structured, and latency-sensitive, and because per-call cost is what makes a generous free-tier quota possible at all.

`OPENROUTER_API_KEY` joins `config.rs` as its third and only optional variable — a secret, which is the one thing CLAUDE.md §1.4 admits. The base URL and the model id are **constants** beside it, not variables: a model id that could differ between a laptop and a deployment would make "the assistant sounds different in production" invisible. The key never ships to the client; the model is called server-side precisely so no build of the app ever carries one.

- **Two RPCs** in a new `assistant_service.proto`: unary `GetRecommendation` returning structured output (ranked technique slugs + one-line reasons, server-validated against the catalogue so the model cannot recommend a technique that doesn't exist), and server-streaming `ExplainTechnique` for the science explanation, where perceived latency matters.
- **Cost and safety controls**, all server-side: a prompt-cached prefix (system prompt + serialized catalogue, marked with `cache_control` that OpenRouter forwards to Anthropic models), small `max_tokens`, a per-user daily quota persisted in Postgres so it survives a restart, a circuit breaker that trips on consecutive failures, and a rule-based fallback ranked on the profile's own `TechniqueGoal` ordering. Every RPC answers: the response carries `AssistantSource`, so the client says "chosen for you" only when a model wrote it.
- **The seam**: a `ModelClient` trait with three implementations — the provider, a disabled one installed when no key is configured, and a scripted double the integration tests drive. Everything that matters sits above it, so validation, quota, breaker, and fallback are all tested with no key and no network.
- **Risk**: this is the first server-streaming RPC through Connect-Swift — spike the transport before building on it (`docs/transport.md` is the reference); the fallback is a unary explanation.

## M7 — Reminders (opt-in)

Local notifications only — no push infrastructure in V1. `UNUserNotificationCenter` scheduling driven by the dial from M4: never (default), gentle, daily. Notification permission is requested only when the user moves the dial off _never_. Plus subscribers get batch-fetched LLM-written reminder copy; the free tier uses static copy.

## M8 — Monetisation

Two StoreKit 2 auto-renewable monthly subscriptions in one App Store subscription group — **Plus** at $0.99 for the full catalogue and **Coach** at $4.99 for the catalogue plus the AI breathing coach. One group, so switching between them is an upgrade Apple prorates rather than a second purchase this app has to reconcile. The free tier keeps the whole app and two techniques: box breathing and the physiological sigh.

The enforcement is split along cost, and only along cost. **The client gates the catalogue**, because a session runs entirely on the device — a server check in front of it would guard nothing, so the catalogue is served whole with a `requires_subscription` flag per technique and locked ones are listed, described, and shown their rhythm rather than hidden. **The server gates the model**, because that is the only thing in the app with a marginal cost: the backend verifies a submitted transaction JWS once (ES256, x5c chain to a compiled-in Apple Root CA - G3, bundle and product id checked in the decoded payload), stores the tier and expiry on the user row, and `AssistantService` reads its daily allowance from that row and never from anything a request carries. Below Coach there is no allowance at all and the assistant answers from its rules, which is what every caller gets offline anyway.

Submissions are ordered by the payload's `signedDate` rather than by expiry, and the whole row moves together. That is what makes an upgrade safe: moving Plus → Coach mid-period issues a transaction whose expiry is _earlier_ than the one it replaces, so any rule that kept the later expiry would leave somebody paying for Coach and holding Plus.

App Store Server Notifications stay deferred — resubmission on every launch plus an expiry read on every call covers a monthly subscription, and the client submits revocations it sees so a refund still lands. `Transaction.currentEntitlements` drives all UI gating, cached across launches so nothing re-locks while StoreKit answers. The paywall carries the App Review checklist: both prices read from the App Store, restore purchases, EULA and privacy links.

## M9 — Apple Watch app

Full parity on the wrist: catalogue, guided sessions with haptics, and the journey stats view. In V1 by product decision — the wrist is where breath haptics feel most natural, and it completes the "Watch-grade craft" story.

- **Target** — new watchOS SwiftUI target (`ios/BreatheWatch/`, declared in `ios/project.yml`) sharing `BreatheCore`: `SessionTimeline`, the domain models, and the sync queue are platform-neutral by construction, so the watch reuses the phone's session engine rather than reimplementing it.
- **Haptics** — watchOS has no CoreHaptics; the vocabulary is `WKInterfaceDevice.play(WKHapticType)`. Mapping: inhale `.directionUp`, exhale `.directionDown`, both holds `.click`, session end `.success` — discrete taps at phase boundaries instead of the phone's intensity curves, driven by the same timeline loop. Run sessions inside a `WKExtendedRuntimeSession` of the mindfulness type so haptics keep firing with the wrist down and the screen dim.
- **Identity & data** — the phone sends the anonymous ID once over WatchConnectivity (`applicationContext`); the watch stores it in its own Keychain and then talks to the backend directly with the same header. Catalogue cached on-watch; sessions recorded locally and drained through M5's batch `RecordSessions`, so offline wrist sessions sync later.
- **Entitlement** — purchases stay on the phone; the entitlement state mirrors over WatchConnectivity. The free tier is fully functional on the watch, consistent with the product's free/paid split.
- **Risks** — the coarser haptic vocabulary must still make inhale and exhale feel unmistakably different (prototype early; the simulator plays no haptics); sub-second physiological-sigh phases stress discrete taps the same way they stress CHHaptic scheduling on the phone.

Dependencies: M2 (catalogue model), M4 (identity), M5 (session sync). Can build in parallel with M6–M8 once those land.

## M10 — Launch readiness

- `DEVELOPMENT_TEAM` + release signing in `ios/project.yml`; TestFlight internal → external, both app targets.
- `PrivacyInfo.xcprivacy`, no-tracking privacy labels, wellness (not medical) copy, contraindications surfaced in-session.
- Backend hardening: rate limiting on assistant routes, `/health`-based monitoring, a load test of the streaming path.
- App Store assets for iPhone **and** Watch (screenshots per device class).
- Support and privacy-policy pages on the site — `web/` is already published, but the one-pager is the only page there and App Store Connect blocks on both URLs.

## Post-V1 parking lot

Deliberately fenced out of V1: HealthKit mindful minutes, widgets and Live Activities, Watch complications and Smart Stack presence beyond the app itself, Sign in with Apple + cross-device sync, push notifications, free-form chat, and any web/Stripe channel.

## Sequencing notes

M1–M3 are client-heavy; M4's backend and infra work can proceed in parallel with M3. M6 carries the schedule risk (new transport pattern + LLM integration); M9 is the second-largest block of new surface (a whole second app target) and should start as soon as M5 lands rather than waiting for M6–M8. M7 and M8 are comparatively mechanical.
