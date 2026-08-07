# Orchestrator — Reference

Synthesise all 6 review agent reports into a single coherent audit document. This is NOT a simple concatenation — add value through cross-cutting analysis, deduplication, conflict resolution, and prioritisation.

## Process

### 1. Collect and Parse

Gather all 6 agent reports. Each report uses the standard finding format (defined in the agent prompt template). Parse each finding into a structured record with: id, severity, location, issue, impact, action. Infer the source agent from the ID prefix (ARCH, TYPE, QUAL, OBS, PERF, SEC).

### 2. Deduplicate

Identify findings that reference the same file/location from multiple agents. Common overlaps:

- Architecture agent flags a god file → Code quality agent flags SRP violations in the same file
- Type safety agent flags a missing error variant → Observability agent flags a silent swallow in the same code
- Security agent flags missing input validation → Type safety agent flags a raw primitive on the same RPC
- Architecture agent flags a generated type escaping the repository boundary → Type safety agent flags the same value as unvalidated

**Merge rule:** When 2+ findings cover the same location and the same underlying issue, merge into a single finding:

- Use the ID from the most specific agent (e.g., a type safety finding stays TYPE-xxx even if the architecture agent also noted it)
- Keep the highest severity
- Combine the issue descriptions into one comprehensive description
- Merge the action items, removing duplicates
- Note all contributing agents in a `Cross-referenced by:` line

**Do NOT merge** findings that happen to be in the same file but address different issues. A god-file finding (ARCH) and an unwrap-in-production finding (TYPE) in the same file are separate findings.

### 3. Cross-Cutting Analysis

This is your highest-value contribution. Look for:

#### Patterns

If 3+ agents flag the same module or file, it is a systemic issue. Elevate it in the Cross-Cutting Concerns section. Name the module, list all finding IDs that touch it, and explain why it is a hot spot. Don't just list — synthesise.

#### Cross-language drift

This repo has one contract and two implementations of it. A finding on one side of the boundary often has a silent twin on the other: an enum conversion tightened in Rust but not in `OndKit`, a field made optional in `proto/` that only one end treats as optional, a validation rule enforced in `service.rs` that the app's model does not know about. When you see a finding on one side, check whether the other side has the matching gap, and say so — a one-sided fix on a two-sided boundary is how the next bug gets written.

#### Contradictions

Agents may recommend conflicting actions. Common examples:

- One agent recommends extracting shared code; another notes the three-tier escalation rule says it stays feature-local until a second concrete consumer exists
- One agent wants a trait seam for testability; another notes the project deliberately has no repository trait because `sqlx::query_as!` checks queries against the real schema

**Resolve every contradiction.** Don't present both sides and leave it to the reader. Where the project has made an explicit decision (documented in `docs/` or `CLAUDE.md`), the decision wins and the contradicting finding is downgraded or dropped — say which. If you genuinely can't decide, present both options with clear tradeoffs and a recommendation.

#### Root Causes

Multiple symptoms may share a root cause:

- Many layering violations might stem from one service that took `Arc<AppState>` and now reaches everything
- Several type safety issues might trace back to a generated type that escaped the repository boundary
- Multiple test gaps might reflect a missing fixture in `tests/e2e/harness.rs`

Identify root causes and note them. Fixing the root cause may resolve multiple findings at once.

#### Dependency Chains

Some findings block others:

- You can't fix the SRP violation until the god file is split
- You can't tighten the Swift decode until the proto field stops being optional
- You can't add the correlation-ID helper until there is a fallible HTTP route to need it

Note these dependencies in the Action Plan so the work isn't attempted out of order.

### 4. Severity Validation

Validate each finding's severity against these criteria:

**Critical** — Must fix before next sprint:

- Active bugs (code does the wrong thing)
- Security vulnerabilities (injection, credential exposure, an identity check that isn't there on per-person data)
- Data integrity risks (silent data loss, corruption, race conditions, a migration that can lose rows)
- Production reliability risks (panics, unhandled errors in critical paths)

**Warning** — Should fix soon (within 2-4 weeks):

- Architectural drift that will compound (layering violations, circular dependencies, a generated type past the repository boundary)
- Growing tech debt (god files, duplicate code, missing abstractions)
- Missing observability that hampers debugging (an error converted to `tonic::Status` without a log)
- Type safety gaps that increase bug risk (raw primitives where a newtype exists, force-unwraps, catch-all match arms on contract enums)
- Test coverage gaps on a decision that is invisible in the code

**Suggestion** — Fix when touching the relevant code:

- Code style improvements
- Minor refactoring opportunities
- Performance optimisations with low impact
- Accessibility improvements in non-critical paths
- Documentation gaps

If an agent marked something as Critical but it doesn't meet the Critical criteria above, downgrade it. If an agent marked something as Suggestion but it is actually a security issue, upgrade it. Note any reclassifications.

**One project-specific caution.** `docs/testing.md` names things this repo deliberately does not test — trivial CRUD, ruleless conversions, thin wrappers, framework behaviour. A "missing test" finding against one of those is not a finding. Drop it and say you dropped it.

### 5. Previous Audit Delta

If a previous audit file exists in `docs/audits/`:

1. Read the most recent audit file
2. Extract all finding IDs from it (match `[PREFIX-NNN]` patterns)
3. Compare against the current findings:
   - **Resolved:** Finding IDs from the previous audit that have no corresponding finding in the current audit (the issue was fixed)
   - **Recurring:** Findings that match a previous finding by location AND issue description (finding numbers will differ between audits — match by file path and issue content, not by ID number). Note if severity changed.
   - **New:** Findings in the current audit with no location/issue match in the previous audit

If no previous audit exists, write: "This is the baseline audit. Future audits will track delta from this report."

### 6. Build the Action Plan

Group all findings into three buckets:

**Immediate (this sprint):**

- All Critical findings
- Warnings that are actively causing pain or blocking other work

**Short-term (next 2-4 weeks):**

- Remaining Warnings
- Root cause fixes that would resolve multiple findings

**Backlog (track but not urgent):**

- Suggestions
- Nice-to-have improvements

Within each bucket:

- Order by dependency (if X blocks Y, list X first)
- Order by blast radius (fixes that resolve multiple findings first)
- Reference the finding IDs each action addresses
- Note dependencies between actions: "Requires [ARCH-002] to be completed first"
- Where an action changes `proto/`, say so — it drags `mise run generate`, a committed Swift regeneration, and a `buf breaking` check along with it

### 7. Assemble the Final Document

Follow the output format specified in SKILL.md exactly. Ensure:

- The summary stats are accurate (count findings after dedup, not before)
- The top 5 priority items are genuinely the most important, not just the first ones listed
- The cross-cutting concerns section adds insight, not just repetition
- Each "Findings by Area" section preserves the original finding format but incorporates any merges or severity changes
- The action plan is actionable — someone should be able to create tickets directly from it
- The heat map appendix is included from the scoping data
- Prose follows the repo's writing conventions: active voice, British spelling, camel-case abbreviations in identifiers (`TechniqueId`, not `TechniqueID`)

## Tone and Judgment

Be opinionated. An audit that lists 200 suggestions with no prioritisation is worse than useless. Your job is to:

- **Separate signal from noise.** Not every imperfection is worth reporting.
- **Make judgment calls.** If a shortcut is pragmatic and the codebase is better for it, don't flag it.
- **Respect stated decisions.** "No auth", "no `shared` crate", "no repository trait", "no metrics yet" are documented choices with reasons attached. Flag them only if the reason has expired — and then argue why.
- **Focus on what matters.** A silent data loss trumps a naming convention. A systemic architectural issue trumps isolated style nits.
- **Be honest about severity.** If the codebase is in good shape, say so. Don't invent problems to fill the report.
