# Scoping — Reference

Analyse the git history and produce a structured change context that focuses the entire audit. This runs inline (not as a subagent) before all review agents.

## Inputs

- The git repository in the current working directory
- A `since` date (provided by the orchestrating Claude, or defaulting to 14 days ago)
- The file tree of the repo

## Process

### 1. Determine the Review Window

Check for previous audits:

```bash
ls -t docs/audits/*.md 2>/dev/null | head -1
```

If a previous audit exists, extract its date from the filename (`docs/audits/YYYY-MM-DD-audit.md`). Use this as the default `since` date unless the user specified a different one. If no previous audit exists, use 14 days before today.

### 2. Gather Git Data

Run these commands (adjust `--since` to the determined date):

**Commit list:**

```bash
git log --oneline --since="{since}" --no-merges
```

**Per-file churn (lines added + removed):**

```bash
git log --numstat --since="{since}" --no-merges --format=""
```

**Authors:**

```bash
git log --format="%aN" --since="{since}" --no-merges | sort -u
```

**Changed files:**

```bash
git diff --name-status $(git log --since="{since}" --no-merges --format="%H" | tail -1)^..HEAD
```

(If this fails due to no parent, use `git log --diff-filter=A --name-only --since="{since}"` for new files and `git log --diff-filter=D --name-only --since="{since}"` for deleted files.)

**Dependency and toolchain changes:**

```bash
git log --oneline --since="{since}" --no-merges -- \
  "Cargo.toml" "crates/*/Cargo.toml" "Cargo.lock" \
  "ios/Packages/OndCore/Package.swift" "**/Package.resolved" \
  ".mise.toml"
```

**GitButler note.** This repo is worked through a GitButler workspace, so the history contains synthetic `GitButler Workspace Commit` entries. Exclude them from commit counts and churn — they are workspace bookkeeping, not authored change:

```bash
git log --oneline --since="{since}" --no-merges --invert-grep --grep="GitButler Workspace Commit"
```

### 3. Compute File Heat Map

For each file that appears in the numstat output:

1. Count the number of commits that touched it (`commit_count`)
2. Sum lines added + lines removed (`churn`)
3. Compute a heat score: `commit_count * churn`
4. Rank files by heat score descending
5. Flag the top 20% as **hot**

Exclude files matching the configured `exclude_paths` patterns. In particular, exclude the committed generated Swift under `ios/Packages/OndCore/Sources/OndAPI/Generated/` — it is machine output whose churn tracks `proto/` edits, and leaving it in swamps the top of the heat map with files nobody wrote. Note the corresponding `proto/` change instead.

### 4. Compute Module Heat Map

Roll up file-level data to module/package level:

- `crates/api/src/features/*/` — each feature is a sub-module of `api`
- `crates/api/src/` (outside `features/`) — app-local infrastructure: `lib.rs`, `state.rs`, `grpc.rs`, `http/`, `config.rs`, `obs.rs`
- `crates/migrate/` — schema and seed
- `ios/Packages/OndCore/Sources/*/` — each Swift target (`OndKit`, `OndUI`) is a module
- `ios/Ond/Features/*/` — each app feature is a module
- `proto/` — treat as a single module
- `docs/`, `infra/`, `.github/` — treat each as a single module

Sum the churn and commit counts for all files within each module. Flag modules with the highest aggregate churn.

A feature that moved in both languages at once (`crates/api/src/features/journey/` and `ios/Packages/OndCore/Sources/OndKit/Journey*.swift`) is worth calling out explicitly — cross-language churn on one feature usually means a contract change, and contract changes are where the two ends drift.

### 5. Identify Large Diffs

Find individual commits with unusually high churn:

```bash
git log --format="%H %s" --since="{since}" --no-merges
```

For each commit, check its numstat. Flag commits where total churn exceeds 500 lines (configurable, but 500 is a good default). These are potential review targets — they may represent rushed changes, large refactors, or regenerated output committed alongside source.

### 6. Identify Dependency Changes

From the dependency file changes gathered earlier, note:

- New dependencies added (new entries in a `Cargo.toml` or `Package.swift`)
- Dependencies removed
- Version bumps
- Lock file changes (`Cargo.lock`, `Package.resolved`)
- Tool version changes in `.mise.toml` — the `[tools]` section pins the toolchain both languages build against, so a bump there has a wider blast radius than a library bump

## Output Format

Produce the change context using this exact structure. Every header must be present even if the section is empty (write "None" for empty sections).

```markdown
## Commit Summary

- **Window:** {YYYY-MM-DD} → {YYYY-MM-DD}
- **Total commits:** {N} (excluding merges and GitButler workspace commits)
- **Authors:** {comma-separated list}
- **Previous audit:** {date or "None — this is the first audit"}

## File Heat Map (Top 20)

| Rank | File   | Commits | Churn | Hot |
| ---- | ------ | ------- | ----- | --- |
| 1    | {path} | {N}     | {N}   | Yes |
| 2    | {path} | {N}     | {N}   | Yes |
| ...  | ...    | ...     | ...   | ... |

## Module Heat Map

| Module   | Files Changed | Total Churn | Hottest File |
| -------- | ------------- | ----------- | ------------ |
| {module} | {N}           | {N}         | {path}       |
| ...      | ...           | ...         | ...          |

## Cross-Language Feature Churn

- **{feature}:** {Rust paths} + {Swift paths} — {combined churn}
- ... (or "None")

## New Files

- {path}
- ... (or "None")

## Deleted Files

- {path}
- ... (or "None")

## Large Diffs (>500 lines churn)

- `{commit_hash}` {commit_message} — {churn} lines
- ... (or "None")

## Dependency Changes

- **{file}:** {description of change}
- ... (or "None")
```

## Important Notes

- Exclude generated files, lock files, and build artefacts from the heat map.
- New migrations under `crates/migrate/migrations/` are always worth listing in "New Files" even when their churn is small — a schema change is the one edit that cannot be reverted by editing the file.
- If the repo has fewer than 5 commits in the window, note this — the audit may have limited scope.
- Binary files should be excluded from churn calculations.
