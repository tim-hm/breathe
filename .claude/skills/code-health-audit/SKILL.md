---
name: code-health-audit
description: "Run a comprehensive multi-agent code health audit across the codebase. Produces a structured, prioritised audit report covering architecture, documentation, type safety, code quality, hygiene, observability, performance, accessibility, and security. Use for: code audit, code health check, tech debt review, architecture review, documentation review, codebase audit, code quality review, sprint retrospective code review, or when the user wants to review code health after a period of development."
---

# Code Health Audit

A multi-agent pipeline that audits the full codebase and produces a structured report at `docs/audits/YYYY-MM-DD-audit.md`.

**Pipeline:** Conventions gathering → Scoping → 6 parallel review agents → Orchestrator synthesis

Coverage spans architecture, documentation accuracy (including `CLAUDE.md`), type safety, code quality, hygiene (dead code & repo artefacts), observability, performance, accessibility, and security — across both languages in the repo, Rust and Swift.

## Configuration defaults

Override any value by stating it in the invocation prompt (e.g., "run audit since 2026-07-01" or "audit with god file threshold 500").

| Parameter                  | Default                                                                                                                 | Description                                  |
| :------------------------- | :---------------------------------------------------------------------------------------------------------------------- | :------------------------------------------- |
| `since`                    | Date of most recent `docs/audits/*.md`, or 14 days ago                                                                  | Review window start                          |
| `god_file_threshold_rs`    | 400                                                                                                                     | Lines threshold for Rust god file detection  |
| `god_file_threshold_swift` | 300                                                                                                                     | Lines threshold for Swift god file detection |
| `output_dir`               | `docs/audits/`                                                                                                          | Output directory (created if missing)        |
| `exclude_paths`            | `target,.git,.sqlx,node_modules,.build,DerivedData,ios/Packages/OndCore/Sources/OndAPI/Generated,ios/Breathe.xcodeproj` | Glob patterns to exclude                     |
| `architecture_docs`        | `docs/`                                                                                                                 | Path to architecture documentation           |

The generated Swift under `OndAPI/Generated/` is committed but not authored — it is excluded from every review. Its _freshness_ is checked by `mise run check:generated`, not by this audit.

---

## Pipeline execution

Execute the following steps in order. Do not skip steps or reorder them.

### Step 1 — Gather Project Conventions

Read the following files from the repo (skip any that don't exist):

- `CLAUDE.md` (project root)
- `docs/code-structure.md`
- `docs/architecture.md`
- `docs/transport.md`
- `docs/observability.md`
- `docs/testing.md`
- `docs/contributing.md`

Produce a `<project_conventions>` block (target: under 1,500 tokens) summarising:

- Code organisation pattern (feature-first, three-tier escalation, module size tiers, the Rust layering contract, the Swift target graph)
- Naming conventions (Rust snake_case modules with no feature-name prefix; Swift PascalCase named for the principal type, `-View`/`-Model`/`-Tests` suffixes; camel-case abbreviations in identifiers)
- Type safety requirements (no `any`-equivalents, no force-unwraps, explicit function signatures, generated types stopping at the repository boundary)
- Documentation rules (`CLAUDE.md` §1.2 — doc comments carry the explanation, the three kinds of inline comment that earn their line, banned section banners)
- Logging and observability standards (log at boundaries, level meanings, field names, the log-before-converting pattern)
- Testing expectations (placement, frameworks, what is deliberately _not_ tested)
- The mise-first and toolkit-first rules, and the minimal-environment-footprint rule (exactly three env vars)

This summary will be passed to every review agent so they can check against project-specific standards, not just universal best practices. Hold this block for use in Step 3.

### Step 2 — Scoping (Produce Change Context)

Read the reference file at `references/agents/scoping.md` (relative to this skill's directory) and follow its instructions to produce a `<change_context>` block. This runs inline (not as a subagent).

**Important:** The heat map is advisory. Every subsequent agent should review the whole repo for critical issues (a broken invariant in cold code still matters), but should go deepest on hot files/modules.

### Step 3 — Fan Out to Review Agents (Parallel)

For each of the 6 review agents below, read its reference file, then spawn an Agent subagent. **Launch all 6 in a single message** so they run in parallel.

| Agent                                   | Reference File                            | ID Prefix |
| :-------------------------------------- | :---------------------------------------- | :-------- |
| Architecture, Structure & Documentation | `references/agents/architecture.md`       | `ARCH`    |
| Type Safety & Robustness                | `references/agents/type-safety.md`        | `TYPE`    |
| Code Quality & Hygiene                  | `references/agents/code-quality.md`       | `QUAL`    |
| Observability & Logging                 | `references/agents/observability.md`      | `OBS`     |
| Performance & Accessibility             | `references/agents/perf-accessibility.md` | `PERF`    |
| Security & Hygiene                      | `references/agents/security-hygiene.md`   | `SEC`     |

#### Agent Prompt Template

For each agent, use the Agent tool with this prompt structure:

```text
You are a specialist code reviewer focused on {AGENT_FOCUS_AREA}.

## Project conventions

These are the project-specific standards. Use them as your review baseline — violations of project conventions are at least as important as universal best practice violations.

<project_conventions>
{paste the project_conventions block from Step 1}
</project_conventions>

## Review instructions

Follow these instructions to conduct your review. They define exactly what to look for and how to prioritise.

<review_instructions>
{paste the full contents of the agent's reference file}
</review_instructions>

## Change context

Focus your deepest analysis on files marked "hot" in the heat map. Also review other files in modules that contain hot files. Scan the full codebase for critical issues, but prioritise hot files and their surrounding modules.

<change_context>
{paste the change_context block from Step 2}
</change_context>

## Configuration

- God file threshold (Rust): {god_file_threshold_rs} lines
- God file threshold (Swift): {god_file_threshold_swift} lines
- Exclude paths: {exclude_paths} (skip these directories/patterns entirely)

## Tooling

Every repo operation goes through mise — `mise tasks` lists them. Never run raw `cargo`, `sqlx`, `buf`, `xcodebuild`, or `swiftlint`. You are reviewing, not fixing: read code, run read-only commands, and do not edit files or run tasks that mutate the database.

## Output format

Aim for 5-20 findings. Be selective — only report issues with real impact. Do not pad the report.

Produce your findings using this exact format. One block per finding:

### [{PREFIX}-{NNN}] {title}
- **Severity:** Critical | Warning | Suggestion
- **Location:** `{file_path}:{line_range}` (or `{file_path}` for whole-file issues)
- **Issue:** {concrete description of what is wrong}
- **Impact:** {why this matters — what breaks, degrades, or compounds}
- **Action:** {specific, actionable remediation steps — not vague advice}

Rules:
- Use prefix {PREFIX} for all finding IDs. Number from 001.
- Order findings by severity: Critical first, then Warning, then Suggestion.
- Be actionable. "This file is too long" is NOT actionable. "Split assistant/service.rs into service.rs and quota.rs, moving the spend-ceiling accounting and the breaker state out" IS actionable.
- Be concrete. Reference specific files, functions, lines, and types.
- If a review area has no issues, state that explicitly rather than inventing findings.
- Apply language-specific checks only when that language is present in the files you reviewed.

At the end of your output, include a brief summary line:
**Summary:** {N} critical, {N} warnings, {N} suggestions
```

### Step 4 — Orchestrate Final Document

Read the reference file at `references/agents/orchestrator.md` for detailed merge and synthesis instructions.

Then synthesise all 6 agent reports into the final audit document:

1. **Collect** all findings from the 6 agent reports.
2. **Deduplicate:** If multiple agents flagged the same file/location, merge into a single finding with combined context and the most severe rating.
3. **Cross-cutting analysis:** Look for:
   - **Patterns:** If 3+ agents flag the same module/file, elevate it as a systemic issue
   - **Contradictions:** Resolve conflicting recommendations with a specific approach
   - **Root causes:** Multiple symptoms sharing one root cause — identify and note it
   - **Dependency chains:** Finding X blocks finding Y — note the ordering
4. **Severity classification:** Validate each finding's severity against the criteria in the orchestrator reference.
5. **Previous audit delta:** If a previous audit exists in `docs/audits/`, read it and compare finding IDs to produce: resolved findings, recurring findings, new findings.
6. **Action plan:** Group recommended actions into Immediate (this sprint), Short-term (next 2-4 weeks), and Backlog. Note dependencies between actions.
7. **Assemble** the final document in the output format below.

### Step 5 — Write Output and Present Summary

1. Create the `docs/audits/` directory if it doesn't exist.
2. Write the final document to `docs/audits/YYYY-MM-DD-audit.md` (using today's date).
3. Retention: delete any audit files older than the previous audit, keeping exactly two — the new report and its delta parent. Git history retains the rest; the pipeline never reads further back than one audit.
4. Run `mise run fmt:text` so the new document matches the repo's markdown formatting, then `mise run check:md` to confirm it lints clean.
5. Present to the user:
   - The severity counts (critical/warning/suggestion)
   - The top 5 priority items (one line each)
   - The path to the full report

---

## Output document format

The final document must follow this structure exactly:

```markdown
# Code Health Audit — {YYYY-MM-DD}

## Summary

- **Review window:** {first_commit_date} → {last_commit_date} ({N} commits by {M} authors)
- **Files reviewed:** {total_files} ({hot_files} with significant recent changes)
- **Findings:** {critical_count} critical, {warning_count} warnings, {suggestion_count} suggestions

### Top Priority Items

1. {One-line summary of most critical finding with file reference}
2. ...
3. ...
4. ...
5. ...

---

## Cross-Cutting Concerns

{Orchestrator's analysis of patterns, root causes, systemic issues, and contradictions resolved}

---

## Delta from Previous Audit

{If a previous audit exists:}

- **Previous audit:** {date}
- **Resolved:** {N} findings no longer present
- **Recurring:** {N} findings still open
- **New:** {N} findings identified for the first time

{If no previous audit: "This is the baseline audit. Future audits will track delta from this report."}

---

## Findings by Area

### Architecture, Structure & Documentation

#### Critical

### [ARCH-001] {title}

- **Severity:** Critical
- **Location:** `{file_path}:{line_range}`
- **Issue:** {description}
- **Impact:** {why it matters}
- **Action:** {remediation steps}
- **Cross-referenced by:** {other agent prefixes, if merged}

#### Warnings

...

#### Suggestions

...

### Type Safety & Robustness

{same structure}

### Code Quality & Hygiene

{same structure}

### Observability & Logging

{same structure}

### Performance & Accessibility

{same structure}

### Security & Hygiene

{same structure}

---

## Action Plan

### Immediate (this sprint)

{Ordered actions with finding ID references and dependencies}

### Short-term (next 2-4 weeks)

{Ordered actions with finding ID references}

### Backlog (track but not urgent)

{Actions with finding ID references}

---

## Appendix: Change Heat Map

### Top 20 Hottest Files

| Rank | File | Commits | Churn | Hot |
| ---- | ---- | ------- | ----- | --- |
| 1    | ...  | ...     | ...   | Yes |

### Module-Level Summary

| Module | Files Changed | Total Churn | Hot Files |
| ------ | ------------- | ----------- | --------- |
| ...    | ...           | ...         | ...       |
```

## When NOT to use this skill

| You actually want                                   | Go to                                                       |
| :-------------------------------------------------- | :---------------------------------------------------------- |
| A review of only the current working diff           | `/code-review`                                              |
| A security review of pending changes on this branch | `/security-review`                                          |
| To land the stack once findings are fixed           | **land-in-origin-main**                                     |
| The conventions themselves rather than a review     | [CLAUDE.md](../../../CLAUDE.md) and [docs/](../../../docs/) |

## Provenance and maintenance

Ported from the `connect` repo's `cortex-code-health-audit` by Tim, 2026-08-07. The TypeScript/React review surface was replaced with Swift/SwiftUI throughout, and the auth checks were rewritten around this repo's documented "no auth" decision. Volatile facts and how to re-verify each:

| Volatile fact (as of 2026-08-07)                                 | Re-verify with                                                                                    |
| :--------------------------------------------------------------- | :------------------------------------------------------------------------------------------------ |
| Output dir `docs/audits/`, two-file retention                    | `ls docs/audits/`                                                                                 |
| Convention source files read in Step 1 still exist               | `ls CLAUDE.md docs/{code-structure,architecture,transport,observability,testing,contributing}.md` |
| The repo is Rust + Swift only — no TypeScript app to review      | `ls web/` (static page, no build), `cat package.json`                                             |
| Generated Swift lives under `OndAPI/Generated/` and is committed | [docs/transport.md](../../../docs/transport.md), "The contract is the source of truth"            |
| `fmt:text` / `check:md` are the markdown formatter and linter    | `mise tasks`                                                                                      |
