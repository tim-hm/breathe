# What still blocks launch

Every item below is one Linear issue: a title, what and why with the current state named at `file:line`, a `Done when:` that becomes the acceptance criteria, and a `Depends on:` or `Blocked on:` where the ordering or an external action is load-bearing.

**This file is staging, not a tracker.** It exists so the reconciliation is reviewable as a diff. Once Linear holds every issue it is deleted, and Linear is the only place the work lives after that. Nothing ephemeral stays in `docs/`.

The numbering is flat and stable so "#15" means the same thing here and in the upload. **Items 1–41 are launch blockers.** **Items 42–51 are engineering debt** carried over from the 2026-08-07 audit — real, verified still-open, and labelled `debt` in Linear so they never sit in the blocker queue. The audit file itself goes away with this change; its other seventy findings were verified fixed against the tree at `6f3f145`, including all five criticals.

The critical path is long and mostly serial: coach privacy (#9 → #10 → #11), accounts (#12 → #13, which co-blocks #5), session presence (#14 → #15/#16 → #41, and #17 → #27), authoring (#21 → #22 → #26 → #27/#28), and release (#33 → #38, #11 → #39, everything → #40). The order below is chosen so the App Review batch (#1–#6) ships independently of all of them, and so the four externally-blocked items never sit on the path of something that could otherwise move.

## The list

1. **App Review — link the privacy policy and terms from Settings.** `ios/Ond/LegalLinks.swift:6` says in its own doc comment that App Review expects both reachable from Settings as well as the paywall. The only consumer is `ios/Ond/Features/Subscription/PaywallView.swift:202-203`; `ios/Ond/Features/Settings/SettingsView.swift` references neither.

   _Done when:_ Settings carries both links, each opens the live URL on a device, and the paywall keeps its own pair.

2. **App Review — deploy the Caddyfile, and add `encode zstd gzip` in the same change.** The `try_files` directive is present at `infra/box/Caddyfile:41`, so `https://ondbreathe.app/privacy` — the literal `LegalLinks.privacyPolicy` traps on — resolves once the box takes the file. It has not taken it. There is also no `encode` directive anywhere in the file, which is roughly 36 KB versus 11 KB on a first visit. Put `encode` inside the static `handle`, never at site level: at site level it would also wrap the gRPC-Web responses from `reverse_proxy api:18100`, which carry their own framing.

   _Done when:_ `/privacy` and `/support` resolve on the deployed box, a first visit is served compressed, and a gRPC-Web round trip is unaffected.

3. **App Review — reconcile the age rating with `birth_year_band`.** `proto/ond/v1/profile_service.proto:146` declares `BIRTH_YEAR_BAND_BORN_2010_OR_LATER` (the Postgres label is at `crates/migrate/migrations/0005_journey.sql:17`), which now means sixteen or younger, while `web/privacy.html` states the app is not directed at children under thirteen. Those two have to agree before the rating questionnaire is answered, because the answer decides the rating.

   _Done when:_ the App Store Connect age rating, the youngest band the app offers, and the policy's children's-data paragraph all say the same thing, and the decision is written down where the enum is defined.

4. **App Review — swap in Apple's official App Store badge.** `web/index.html:32-33` carries a comment marking the badge below it as a hand-drawn stand-in "so the layout is real". This is a download from Apple's marketing resources, not a commission, so it is independent of #33.

   _Done when:_ the badge is Apple's own artwork at the required clear space and minimum size, and the stand-in comment is gone.

5. **A `DeleteAccount` RPC and an in-app "delete everything".** `web/privacy.html:160` promises "It is a deletion, not a flag." The contract has only `DeleteSessions` (`proto/ond/v1/journey_service.proto:38`) and no `DeleteAccount` anywhere in `proto/`. The server side is one scoped statement: the profile is columns on `users` (`crates/migrate/migrations/0004_users_and_profiles.sql:15`), and every child table cascades from it — `sessions` and `bolt_scores` at `0005_journey.sql:39,75`, the assistant quota at `0006_assistant_quota.sql:10`. This is a hard App Review gate rather than only a privacy promise: guideline 5.1.1(v) requires in-app account deletion the moment account creation is offered, so it lands with #12/#13, not after them.

   _Done when:_ a `DeleteAccount` RPC erases the user row and everything hanging off it, Settings offers it behind a confirmation, the local stores and Keychain identity are cleared on the device, and an e2e test proves nothing survives.

   _Depends on / co-blocks:_ #12, #13.

6. **Surface the anonymous identifier in Settings.** Erasure-by-email needs the requester to supply the id that identifies their record, and nothing renders it — `ios/Ond/Features/Settings/SettingsView.swift` has no reference to it. The policy currently rests that promise on a support reply. Superseded in part by #12/#13, but needed until those land.

   _Done when:_ Settings shows the identifier with a copy affordance, and the policy's erasure section points at it by name.

7. **Send OpenRouter a deny-training/retention data policy (interim).** `crates/api/src/features/assistant/model/openrouter.rs:138-143` builds `ChatRequest { model, max_tokens, stream, messages }` with no `provider` block, so every call runs under whatever the account default is while #9 is weeks out.

   _Done when:_ the request carries a provider data policy denying training and retention, an e2e test pins the serialised body, and the account-level setting agrees with it.

8. **Interim policy truth pass.** Make `web/privacy.html` accurate to the world #7 creates — OpenRouter, training and retention denied, transcripts on the device only. This is what ships if the App Review batch goes out before #9/#10, and without it there is a window where the submitted policy describes infrastructure that does not exist.

   _Done when:_ every sentence in the policy about the model provider is true of the deployed stack on the day of submission.

   _Depends on:_ #7.

9. **Migrate the model client to Bedrock or Vertex, with no training and no prompt logging.** The seam already exists: `trait ModelClient` at `crates/api/src/features/assistant/model/mod.rs:119`, with the disabled implementation in `model/disabled.rs` and the scripted double at `crates/api/tests/e2e/harness.rs:170`. Keep both intact — they are what let quota, breaker, validation and fallback stay tested with no key and no network.

   _Done when:_ the default implementation calls the chosen provider, the no-training and no-prompt-logging settings are confirmed in writing, `mise run test:e2e` passes unchanged, and the rule-based fallback still answers with no key configured.

   _Blocked on:_ choosing the provider and obtaining account-level model access with the data settings confirmed in writing.

10. **Persist coach conversations server-side.** `Chat` is deliberately stateless today: the RPC is declared at `proto/ond/v1/assistant_service.proto:45` and its request doc at `:124-130` says the server holds no transcript, while `crates/api/src/features/assistant/repository.rs` is forty-three lines holding only the daily quota. Moving the transcript server-side is what lets someone continue a conversation on a second device, and it is new personal data, so its erasure path is part of the work rather than a follow-up.

    _Done when:_ conversations persist against the user row, the client reads history from the server rather than the device, the transcript is included in #5's deletion, and the retention period is decided and written into the policy.

11. **End-state policy rewrite.** `web/privacy.html:105` currently says "We store none of it. Prompts, replies, and explanations are never written to our database" and disclaims what happens at the provider. Both sentences stop being true the moment #9 and #10 land.

    _Done when:_ the policy describes the real provider, the real retention, and the real erasure path, and #39's nutrition labels are answered from it.

    _Depends on:_ #9, #10.

12. **Server-side Sign in with Apple.** Verify the Apple identity token and bind it to `users.apple_user_id` — the column exists and is `UNIQUE` at `crates/migrate/migrations/0004_users_and_profiles.sql:25`, and nothing reads or writes it; the only mentions in `crates/` are the doc comments at `identity.rs:7` and `profile/repository.rs:182`. The interesting decision is the merge rule when a device signing in already carries an anonymous id and that Apple account already has a row.

    _Done when:_ the token is verified against Apple's keys, the binding is written, the merge rule is decided and documented on the column, and e2e tests cover a fresh sign-in, a returning sign-in, and the collision.

13. **Client Sign in with Apple, local-only mode, and restore on a new device.** No `AuthenticationServices` import exists anywhere under `ios/`. Today the identity lives only in the Keychain, so a person on a different Apple ID has no path back to their history. A local account is a first-class choice with no sync and no coach — everything on the device, which is what the free tier already is.

    _Done when:_ a person can sign in, sign out, choose local-only, and restore their journey on a second device; the watch follows the phone's identity as it does now.

    _Depends on:_ #12. _Co-blocks:_ #5.

14. **Keep a phone session running backgrounded with the screen off.** The watch already does this through `WKExtendedRuntimeSession` (`ios/project.yml` declares `WKBackgroundModes: [mindfulness]` for `OndWatch`). The phone declares no `UIBackgroundModes` at all and explicitly pauses on scene `.background` at `ios/Ond/Features/Session/SessionView.swift:60-66`. Eyes closed with the screen off is the premise of the whole app, and it is the one place the phone is worse than the wrist.

    _Done when:_ a session started on the phone keeps cueing with the screen off and the app backgrounded, haptics and audio keep their timing, the battery cost is measured, and the existing hand-pause behaviour is unchanged.

15. **Live Activity and Dynamic Island for a running session.** No `ActivityKit`, no `WidgetKit`, and no widget extension target in `ios/project.yml`. This is the host surface for #41, so the design has to carry a phase cue readable in under a second at a glance, not only elapsed progress.

    _Done when:_ a running session shows a live phase cue in the Dynamic Island and on the Live Activity, it ends cleanly when the session does, and it reads correctly under Reduce Motion.

    _Depends on:_ #14.

16. **Lock-screen presence and controls for a running session.** Nothing uses `MPNowPlayingInfoCenter` or `MPRemoteCommandCenter`. Same constraint as #15: legible as a breathing cue at a glance, and silent by default.

    _Done when:_ the lock screen shows the session with working pause/resume/end, and the controls agree with the in-app state in both directions.

    _Depends on:_ #14.

17. **APNs push, end to end.** Local scheduling exists — `ios/Ond/Features/Schedules/NotificationScheduler.swift:53` uses a `UNCalendarNotificationTrigger` — but there is no push entitlement client-side and no APNs plumbing server-side. This is the prerequisite for anything the server initiates.

    _Done when:_ the entitlement and capability are configured, device tokens register and are stored against the user, the server can send a notification end to end, and the reminder dial's `NEVER` state still means never.

18. **Profile management in Settings.** Goals, experience level and reminder cadence are collected once and never editable again — the only setters live under `ios/Ond/Features/Onboarding/`. Display name and birth-year band are reachable only from `ios/Ond/Features/Journey/LeaderboardNameView.swift:24,45`. Subscription management is already there (`ios/Ond/Features/Settings/SettingsView.swift:108-128`, the manage button at `:121-126`), so what remains for that half is a discoverability check rather than a build.

    _Done when:_ every profile field is editable from Settings, changes sync, and someone who wants to cancel finds the route without being told.

19. **Rebuild onboarding around how people actually describe themselves.** Today it offers tidy abstractions — calm, sleep, energy, focus, reset. Nobody arrives that tidy. Let someone say "I have ADHD and I struggle to settle" or "I'm perimenopausal and waking at 3am" in their own words, and route that to the right technique and the right framing. The raw material exists: `intent_note` is already a bounded free-text column on `users` (`0004_users_and_profiles.sql:39`) and already reaches the coach. This makes it the spine of onboarding rather than an afterthought.

    _Done when:_ onboarding accepts a free-text self-description, routes it to a technique and a framing, and the routing is pinned by tests over a set of real phrasings.

    _Depends on:_ #34.

20. **Let someone onboard with no goal at all.** "I'm just exploring" has to be a first-class answer, not a skipped step — the same principle as the reminder dial whose zero state is _never_. Nothing else in the product pressures, and the entry point should not be the exception.

    _Done when:_ a person can finish onboarding having chosen nothing, the app is fully usable afterwards, and the coach and suggestions behave sensibly with an empty goal set.

21. **Author your own breath exercise.** Rounds, per-phase durations, nose or mouth, left or right nostril, holds. Today the only customisation is per-phase dials on a catalogue technique: the value type is `ios/Packages/OndCore/Sources/OndKit/TechniqueOverrides.swift:15-41` and its storage is `UserDefaults` at `OndKit/SessionSettings.swift:205-248` — device-local, never synced, and unable to express a technique that is not already in the catalogue.

    _Done when:_ a person can create, edit, run and delete their own technique; it syncs across their devices; it plays through the same `SessionTimeline` the catalogue uses; and the safe per-phase ranges the catalogue already seeds still bound it.

22. **Chain exercises into a sequence.** One style of breathing, then another, then a third — the user-built equivalent of the Wim Hof-style protocol. The contract already has the level for it: `Stage` exists precisely because a technique can be several differently-shaped blocks in order.

    _Done when:_ a person can order several stages into one session, the timeline plays them without a seam, and an open-ended hold inside a sequence still stops the clock.

    _Depends on:_ #21.

23. **Surface gamification in the app.** Streaks and boards live only on the Journey tab, and a "levels" concept does not exist anywhere — `JourneyStats` has no notion of one. The framing rule holds: celebrate consistency, never pressure.

    _Done when:_ progression is visible outside the Journey tab, a level concept exists in the domain and is earned from real activity, and no copy anywhere reads as a failure.

24. **Add breathing measurements and baselines beyond BOLT.** The controlled-pause test is the only measurement the app takes. More of them feed the coach better context and give the boards something other than volume to rank.

    _Done when:_ at least one further measurement is defined, measured in-app, stored with history, cited by the coach, and eligible for a board.

25. **Watch UX refinement pass.** Deliberately a companion rather than a driver: the issue names the intended subset instead of chasing parity. #41 raises the stakes on one part of it — the wrist is the least conspicuous cue channel there is, so discreet pacing has to feel right there first.

    _Done when:_ the intended feature subset is written down and true of the app, the haptic vocabulary is consistent across every surface, and a session started on the wrist needs no phone.

26. **Define the coach's capability and tool surface.** What the model may call, with authoring a custom exercise for the user as the first tool worth having. Today the assistant reads context and answers; it takes no actions.

    _Done when:_ the tool surface is specified and implemented, every tool is validated server-side against the same rules a person's own edit would face, the guardrails are written up for #39, and the quota still bounds spend per user.

    _Depends on:_ #21.

27. **Periodic coach jobs.** Decide server scheduler versus on-device trigger, then build it. The API has no scheduler, no cron and no worker — the only `tokio::spawn` in `crates/api/src` is the SSE relay at `assistant/model/openrouter.rs:236`. The behaviour wanted is a nudge: "you have not practised in four days", or "I have looked at your last two weeks — want to talk about it?".

    _Depends on:_ #17, #26.

    _Done when:_ the scheduling decision is recorded with its reasoning, jobs run on a cadence, they respect the reminder dial including `NEVER`, and a failing job cannot spend unbounded model calls.

28. **Raise the coach and the app's copy to the niche framing.** Once #19 lets someone describe a real situation, the rest of the product has to answer at that level — the coach's prompting and guardrails, the technique copy, the in-session hints. Without this, onboarding asks a real question and the app answers a generic one.

    _Done when:_ the coach's system prompt, the catalogue copy and the session hints all speak to the situations #34 identifies, and the wellness-not-medical line is held explicitly in the guardrails.

    _Depends on:_ #19, #24, #26.

29. **Confirm Family Sharing.** `crates/api/src/features/entitlement/verifier/appstore.rs:150-171` deliberately does not parse `inAppOwnershipType` — the doc at `:152-154` argues that reading it would be a field to keep in step with a schema Apple owns, in exchange for nothing that decides an entitlement. That reasoning holds only while a family-shared transaction should be honoured identically to a purchased one, and nothing currently verifies or caps it.

    _Done when:_ Family Sharing is enabled on both subscriptions, the intended behaviour is decided and stated on the verifier, and a real shared purchase is tested on a second Apple ID.

    _Blocked on:_ enabling Family Sharing on both subscriptions in App Store Connect, which is also what makes the behaviour testable.

30. **Grafana on the box.** There is no metrics endpoint and no log shipping: `infra/box/compose.yaml:6-16` configures the json-file driver at 10 MiB × 5 and the comment above it says outright that nothing ships these logs anywhere. Scrape the API, Caddy and Postgres; the panels that matter first are users and revenue.

    _Done when:_ Grafana runs on the box, the three sources are scraped, users and revenue panels exist, and the dashboard is reachable over the tailnet rather than the public listener.

    _Depends on:_ #31 for how it is reached.

31. **Bring the box into the tailnet and close SSH.** There is no Tailscale anywhere in `infra/`. `admin_cidr` is a required variable with no default (`infra/variables.tf:18-21`) and is narrowed in a gitignored `terraform.tfvars`, with SSM break-glass attached at `infra/main.tf:163-166`. Once the box is on the tailnet, 22/tcp closes entirely and #30's dashboard is reachable without ever being publicly exposed.

    _Done when:_ the box joins the tailnet from cloud-init, the security group no longer opens 22/tcp to any CIDR, SSM remains as break-glass, and `mise run deploy` still works over the tailnet.

    _Blocked on:_ a personal Tailscale account — this machine is joined to the work tailnet and has to be logged out and re-enrolled before any of this can be built or tested.

32. **Rate-limit the edge and finish the leaderboard fix.** `crates/api/src/identity.rs:117-126` inserts a `users` row for any well-formed UUID in the header, on the public catalogue path that needs no identity, and there is no rate limiting in `infra/box/Caddyfile` or in the tower stack. The leaderboard queries amplify it: the covering index at `crates/migrate/migrations/0010_sessions_started_at.sql:19` and the bounded streak fold at `journey/leaderboard/repository.rs:54-58` made them cheaper, but they still run live per request with nothing in front.

    _Done when:_ a request-rate limit exists at the edge or in `build_app`, the unbounded-identity insert is capped, and a load test shows the leaderboard path bounded under a hostile caller.

33. **Commission the icon, site artwork and in-app imagery.** There is currently _zero_ artwork: `ios/Ond/Assets.xcassets/AppIcon.appiconset/Contents.json` declares one universal 1024×1024 entry with no `filename`, `ios/OndWatch` has no asset catalog at all, and no image asset of any kind exists anywhere under `ios/`. **Style:** simple, clean, minimalist — unDraw-adjacent flat vector illustration, a restrained palette drawn from the app's own accent tokens, no gradients for their own sake, no stock-photo realism. It has to sit beside a product whose whole visual argument is calm. **Formats:** 1024×1024 PNG, no alpha, sRGB for the iOS icon; a separate watchOS icon set; SVG for site figures; `@1x/@2x/@3x` PNG or PDF-vector for in-app imagery.

    _Done when:_ the icon renders on both targets at every size, the site figures are replaced, and the in-app imagery is in the catalogues with no placeholder left.

    _Blocked on:_ hiring the illustrator and sending the brief.

34. **Research breathing for ADHD, perimenopause and athletes.** The output is evidence, technique mappings and copy proposals — the raw material #19 routes to and #28 speaks in, not code on its own.

    _Done when:_ each of the three has a written evidence summary, a mapping onto techniques already in the catalogue, and proposed copy, all reviewable before anything ships.

35. **`--accent-soft` fails contrast in light mode.** `web/style.css:14` defines `--accent-soft: #6bb3ab`, which is 2.30:1 on white against WCAG 1.4.11's 3:1 for non-text, and `web/style.css:509` uses it to stroke the exhale — the one thing the figures exist to distinguish. The dark value `#457066` on `#101413` is fine at 3.33:1.

    _Done when:_ the light value clears 3:1 against the page ground, the exhale still reads as softer than the inhale, and the app's runtime 45% mix of the same accent is checked against the new value.

36. **Announced cycle counts disagree with what is drawn.** `web/index.html:248` announces 27 cycles while the paths draw 2, and `:212` announces 20 while the paths draw 11. This is structural rather than a typo: the label reports `stage.cycles` (`ios/Packages/OndCore/Sources/OndKit/TechniqueFigureDrawing.swift:278-279`) while the drawing fits a 22-second window capped at twelve (`OndKit/BreathRhythm.swift:76,80,96-102`). The "1 seconds" half of this finding is already fixed and tested.

    _Done when:_ every generated `aria-label` describes what is actually drawn, and `mise run check:diagrams` fails if the two ever diverge again.

37. **Release signing, archive, and TestFlight distribution for both targets.** `ios/project.yml:31` declares `DEVELOPMENT_TEAM: ${OND_DEV_TEAM}`, so no team is committed and none resolves without the environment variable; there is no release signing or provisioning configuration at all, and `mise run ios:build` (`.mise.toml:528-533`) builds `generic/platform=iOS Simulator` only.

    _Done when:_ both targets archive and sign for release, a `mise run ios:archive` task exists, and an internal TestFlight build installs on a real iPhone and a paired Watch.

38. **App Store Connect listing: metadata, keywords, and screenshots.** Per device class, for iPhone and Watch. The subtitle carries the discoverability argument recorded in [product/naming.md](product/naming.md).

    _Done when:_ every required field is filled, screenshots exist for every device class both targets need, and the listing passes App Store Connect's own validation.

    _Depends on:_ #33, #37.

39. **The App Store Connect privacy questionnaire and `PrivacyInfo.xcprivacy`.** No privacy manifest exists anywhere in the tree. The nutrition labels have to agree with what the app actually collects and with the shipped policy, which is why this follows the policy rather than leading it.

    _Done when:_ `PrivacyInfo.xcprivacy` is in the app target and accurate, the questionnaire is answered, and every answer is traceable to a sentence in the shipped policy.

    _Depends on:_ #11, or #8 if submitting on the interim policy.

40. **Run a beta window.** External TestFlight, a feedback triage loop, and an explicit go/no-go before submission. This is the item that converts everything above into a decision.

    _Done when:_ external testers have run real sessions across a defined window, feedback is triaged into fix-now versus after-launch, and the go/no-go is recorded with its reasoning.

    _Depends on:_ #37.

41. **Discreet mode — pacing that runs through a stressful meeting without anyone noticing.** A thirty-minute call is the situation the app currently cannot help with: opening a full-screen session is exactly what you cannot do with people watching. Discreet mode runs long and quiet, nudging through the Dynamic Island, the lock screen and the wrist — haptic-first, silent by default, glanceable in a second, and never a takeover. **It adds no technique to the catalogue**: coherent breathing and extended exhale are already the right patterns, so this is a delivery mode over what exists. The open question it has to answer is pacing — continuous guidance for thirty minutes is wrong, so the issue decides the nudge cadence and how it decays.

    _Done when:_ a discreet session runs for half an hour with the app backgrounded, cues arrive on the wrist and the Dynamic Island without sound, the cadence decays as decided, and ending it takes one gesture.

    _Depends on:_ #14, #15, #16, and the watch haptic vocabulary. _Feeds:_ #19 — "I get anxious in meetings" is precisely the real-world self-description onboarding should route somewhere, and this is where it routes.

42. **Debt — `BirthYearBand` reaches into the leaderboard's SQL layer.** `crates/api/src/features/journey/leaderboard/repository.rs:12` imports `profile::types::BirthYearBand`. The rest of the audit's backdoor imports are closed — `assistant/service.rs:24-30` now goes through the four provider services — so this is the last one, and it is a type with two genuine owners rather than a service bypass.

    _Done when:_ the leaderboard repository no longer imports another feature's types, either by promoting `BirthYearBand` to tier 2 or by routing it through `profile::service`.

43. **Debt — the e2e test table documents 31 of 72 tests.** `docs/testing.md`'s table has thirty-one rows against seventy-two `#[tokio::test]` functions in `crates/api/tests/e2e/`. The profile suite the audit called out is now represented; most of `journey` and half of `entitlement` still are not. The table's framing — "each was verified by breaking the code it covers" — asserts something about thirty-one tests while implying it about all of them.

    _Done when:_ the table is either current or explicitly narrowed to "the tests worth reading first", so an absent row stops reading as drift.

44. **Debt — `identity.rs` holds raw SQL outside any `repository.rs`.** `crates/api/src/identity.rs:117-126` runs `sqlx::query!` from a tier-2 module at `src/` root — the only query in the crate outside a `features/*/repository.rs` or `crates/migrate`. `docs/code-structure.md:39` states "All SQL" belongs in a repository with no exception noted.

    _Done when:_ either the query moves into a repository, or `identity` escalates to `src/identity/{mod.rs,repository.rs}` — and `docs/code-structure.md` records the decision either way.

45. **Debt — a handful of public items still carry no `///`.** The audit's list is nearly closed: every RPC entry point and all five feature error enums are documented now. What remains is `TechniqueServiceImpl`, `JourneyServiceImpl`, `ProfileServiceImpl` and `EntitlementServiceImpl` at their respective `handlers/grpc.rs`, plus `Config` and `config::load` (`crates/api/src/config.rs:30,157`) and `BuildInfo` and `http::router` (`crates/api/src/http/mod.rs:29,34`).

    _Done when:_ each carries a `///` block stating the constraint rather than the signature.

46. **Debt — five `handlers/mod.rs` files carry no `//!`.** `crates/api/src/features/{assistant,entitlement,journey,profile,technique}/handlers/mod.rs` are each a single `pub mod grpc;` and are the only `.rs` files in `crates/` without a module doc — the only exceptions to a rule stated twice, in the directory where the layering contract is enforced.

    _Done when:_ each has a line naming what the directory holds and what it may not do, or each collapses to `handlers.rs` on the Tier 1 argument.

47. **Debt — the `recommend` e2e helper is implemented twice.** `crates/api/tests/e2e/assistant.rs:898-903` and `crates/api/tests/e2e/entitlement.rs:157-169` differ only in how the router is built. `harness.rs` already owns the shared half, so both the precedent and the destination exist.

    _Done when:_ one `recommend` lives in `harness.rs` and both suites call it.

48. **Debt — the session backdrop pushes text below WCAG AA.** `ios/Ond/Features/Session/SessionView.swift:101-112` washes `goal.accent` from 0.35 down to 0.05 over the ground. Against the top of that gradient, `Theme.Ink.secondary` — the "Round 2 of 3 · cycle 12 of 30" line at `:147` — measures 3.26–3.57:1 across the five accents in both appearances, and the nostril hint drawn in `goal.accent` itself at `:192` falls as low as 2.93:1 in light mode. All are `.subheadline`, so all need 4.5:1. The hint is the one thing alternate-nostril breathing cannot be done without, and it is the least readable text on the screen. Every other contrast failure the audit found is fixed and pinned by `ThemeColorTests`.

    _Done when:_ the position line and the nostril hint clear 4.5:1 against every accent in both appearances, with the assertion added to `ThemeColorTests` so it cannot regress.

49. **Debt — the leaderboards are still computed live on every request.** The index and the bounded streak fold landed (see #32), but nothing is materialised: there is no `leaderboard_snapshot` table and no materialised view, so the same fold repeats for every caller who opens the tab. A board a few minutes stale is indistinguishable from a live one.

    _Done when:_ the boards are served from a snapshot refreshed on a schedule, and the read path no longer folds the whole window per request.

50. **Debt — nothing watches the dependency manifests.** `check:audit` runs `cargo audit` (`.mise.toml:360-371`) on a daily CI cron, which closes the advisory half. There is still no `.github/dependabot.yml`, so nothing proposes the upgrade an advisory calls for, and nothing watches `Package.resolved` at all.

    _Done when:_ `.github/dependabot.yml` covers `cargo` and `github-actions`, and the Swift lockfile has some watcher.

51. **Debt — three fixed-size numerals ignore Dynamic Type.** `ios/Ond/Features/Journey/BoltTestView.swift:109` and `:125` are `.font(.system(size: 72, …))` on the controlled-pause timer and its result, and `ios/Ond/Features/Session/CountdownView.swift:27` is `.font(.system(size: 96, …))` on the pre-session countdown. Every other fixed size the audit found has been moved onto a text style; these three are display numerals where the metric genuinely matters, so the answer is probably a bounded scale rather than a plain text style.

    _Done when:_ each scales at least partway with Dynamic Type — `.custom(_:size:relativeTo:)` or a capped `.dynamicTypeSize` — without breaking its layout at the largest accessibility sizes.
