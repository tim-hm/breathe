# Launch todos

Concrete blockers and follow-ups found while building the privacy and support pages, in the order they would bite. Milestone-level planning lives in [product/roadmap.md](product/roadmap.md) — this is the short list of things already known to be wrong or missing.

## Blocks the first submission

- [ ] **Fill the two placeholders in `web/privacy.html`.** The data-controller section ships `[full legal name]` and `[postal address]`, styled loudly so they cannot be missed on the page. App Store Connect and the UK GDPR both require a named controller. Nothing between the working tree and production strips them — `mise run deploy` rsyncs `web/` wholesale.
- [ ] **Deploy the Caddyfile.** `LegalLinks.privacyPolicy` is the literal `https://ondbreathe.app/privacy`, and only the `try_files` directive resolves the extensionless form. Until the box has the new Caddyfile, the paywall's privacy link 404s — which App Review rejects.
- [ ] **Link both documents from Settings.** `LegalLinks.swift`'s own doc comment says App Review expects the privacy policy and terms reachable from Settings as well as the paywall. `SettingsView` currently links neither.

## Makes the privacy policy true

- [ ] **Build `DeleteAccount`, or honour erasure by hand.** The policy promises full erasure on request, and [product/business-plan.md](product/business-plan.md) commits to "deletion is deletion". The contract has only `DeleteSessions` — nothing deletes a profile, BOLT scores, or the user row. Until the RPC exists, every erasure request is a manual `DELETE` someone has to remember to run.
- [ ] **Surface the anonymous identifier in Settings.** Erasure-by-email needs the requester to supply the ID that identifies their record, and nothing in the app shows it. The policy currently says we will tell people how to retrieve it, which is a promise resting on a support reply.
- [ ] **Set OpenRouter's data policy to deny training and retention.** Nothing in `crates/api/src/features/assistant/` sends a data-collection preference, so conversations are handled under whatever the account default is. The policy is written honestly around that today — it says what happens at the provider is not ours to promise. Configure it and the wording can be strengthened.
- [ ] **Confirm the App Store age rating against `birth_year_band`.** The enum includes `BORN_2010_OR_LATER`, which now means 16 or younger, while the policy states the app is not directed at children under 13. Those need to agree.

## Worth doing before launch

- [ ] **Add `encode zstd gzip` to the Caddyfile's static `handle` block.** Caddy does not compress by default. Measured against the real `web/`: a first visit transfers ~36 KB uncompressed versus ~11 KB compressed. Put it inside the static `handle`, not at site level — at site level it would also wrap the gRPC-Web responses from `reverse_proxy api:18100`, which carry their own framing.
- [ ] **Add a `check:web` task that fails on unfilled placeholders.** `grep`ping `web/*.html` for `class="placeholder"` and exiting non-zero, wired into `mise run check`, turns "a policy that ships with a placeholder is worse than no policy" from a comment into a gate.
- [ ] **Swap the App Store badge for Apple's official artwork.** `index.html` carries a hand-drawn stand-in, marked as such, so the layout is real.
- [ ] **Give Privacy a real `href` everywhere it appears.** Done for the site footer and the paywall; check nothing else still points at `#`.

## Found in passing, not mine to fix

Both are in the technique-figure generator, which was being rewritten concurrently — flagged here so they are not lost.

- [ ] **`--accent-soft` fails contrast in light mode.** `#8bb3ab` on white is ~2.30:1, under WCAG 1.4.11's 3:1 for non-text. It strokes the exhale, which is the one thing the figures exist to distinguish. The dark value is fine at 3.38:1.
- [ ] **Generated `aria-label`s are wrong on two figures.** One reads "Breathe in for 1 seconds", and the announced cycle counts disagree with what is drawn (coherent breathing announces 27, draws 2). The fix belongs in the generator, not in `index.html`.
