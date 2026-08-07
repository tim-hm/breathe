---
name: land-in-origin-main
description: "Open PRs for the current GitButler stack, merge them into origin/main in dependency order, and rebase the local workspace once they land. Use when the user says: land in origin main, land my branches, merge my PRs, get my branches into main, ship my stack, ship my branches, get my work merged, sync after merge. Wraps the gitbutler skill — does not replace it."
---

# Land in Origin Main

Orchestrates a stack of GitButler branches through the gate, PR creation, merge into `origin/main`, and post-merge sync. For any individual `but` command, defer to the `gitbutler` skill at `~/.claude/skills/gitbutler/SKILL.md`.

## Non-negotiable rules

1. Use the `gitbutler` skill for every `but` invocation; never call raw `git` write commands.
2. Always start with `but status -fv` to read the live stack — never assume branch names or order from earlier in the conversation.
3. Get explicit user confirmation at the two checkpoints below. Do not silently open PRs or merge.
4. Merge in dependency order: base branch first, children only after the base has landed.
5. `mise run check` passes locally before any PR opens. CI runs the same gate; finding out from GitHub costs a round trip.

## The flow

### Step 1 — Read the stack

Run `but status -fv`. From the output, identify:

- The set of branches the user wants to land. If ambiguous, ask: "I see branches X, Y, Z — land all of them, or a subset?"
- For stacked branches, the dependency order (base → children).
- Independent branches (separate stacks) have no order between them.

### Step 2 — Run the gate

Before proposing a plan, run the three commands from `CLAUDE.md` §3, in order, and report the result:

```bash
mise run generate   # protobuf types + SQLx cache
mise run fmt
mise run check
```

`mise run check` excludes `check:swift` and `test:swift` because they need a full Xcode toolchain. CI covers `check:swift` on a macOS runner but never runs `test:swift` at all — so if any branch in the stack touches `ios/`, run both explicitly here.

Two failure modes here are stack-specific rather than code-specific, and both surface as a `check` failure:

- **`check:generated`** fails when a `proto/` edit landed without its regenerated Swift. `mise run generate` fixes it, but the regenerated files must then be committed onto the branch that changed the proto — not swept into whichever lane is on top.
- **`check:proto`** runs `buf breaking` against `main`. A break is a contract decision, not a lint failure: stop and surface it to the user rather than working around it.

If the gate fails, stop. Report what failed and fix it before continuing — a red PR is worse than an unopened one.

### Step 3 — Check for migration collisions

`crates/migrate/migrations/` is sequentially numbered (`0007_entitlements.sql`). Two branches developed in parallel can both add `0008_`, and nothing catches it until they are in `main` together.

```bash
but status -fv   # note migration files per branch
ls crates/migrate/migrations/
git ls-tree --name-only origin/main crates/migrate/migrations/
```

If two branches in the stack add the same number, or a branch's number is already taken on `origin/main`, renumber the later one before opening PRs — rename the file and amend it into its own commit. Renumbering after a merge means rewriting a landed migration, which is the one thing sqlx's checksum will not forgive.

### Step 4 — Confirm the plan (checkpoint 1)

Summarise the proposed plan back to the user before touching anything:

```text
Gate: mise run check — pass (check:swift, test:swift — pass)
Migrations: no collisions

I'll open PRs for these branches (in this order):

  Stack 1:  feature/api  →  feature/ui
  Stack 2:  feature/docs  (independent)

Then merge each into origin/main, base first.
Proceed?
```

Wait for explicit confirmation. If the user wants changes (different subset, different order, skip a branch), update the plan and reconfirm.

### Step 5 — Open PRs in dependency order

For each branch in dependency order, run `but pr new <branch>`.

- `but pr new <child>` automatically cascades the stack — opening the child PR after the parent does the right thing.
- Capture each PR URL from the command output.
- Do NOT mix `but push` + `gh pr create` — `but pr new` is the one-shot wrapper to use.

### Step 6 — Confirm before merging (checkpoint 2)

Once all PRs are open, summarise back to the user with URLs and CI status:

```text
Created PRs:

  1. feature/api    — https://github.com/.../pull/123  (CI: pending)
  2. feature/ui     — https://github.com/.../pull/124  (CI: pending)
  3. feature/docs   — https://github.com/.../pull/125  (CI: pending)

Ready to start merging from the base. Confirm to proceed.
```

Pull CI status per PR with `gh pr checks <pr-url>`. `.github/workflows/checks.yml` is deliberately only the fast, dependency-free slice — `check:rs`, `check:proto`, `check:text`, `check:md`, `check:doc-links`, and `check:swift` on a macOS runner. The tests, `check:sqlx`, `check:generated`, and `check:deps` never run there, which is precisely why Step 2 is not optional: a green PR is not evidence that the gate passed.

Wait for explicit confirmation before any merge.

### Step 7 — Merge base, then cascade

For each PR in dependency order, merge with `gh pr merge --merge <pr-url>` (or whatever style the repo allows — check `gh repo view --json mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed` if unsure; add `--admin` if the user asked to bypass CI/branch protection).

GitHub auto-retargets a stacked child PR's base to `main` once its parent merges, so you can merge straight through the queue without a `but pull` between each one. If a child merge fails because its base still points at an unmerged parent, run `but pull` to rebase it, then retry.

If the user wants to gate each individual merge (not just checkpoint 2), they'll say so — default is to proceed through the queue once checkpoint 2 is approved.

### Step 8 — Sync and verify

After all PRs are merged, run `but pull --status-after` once to integrate the merged commits into the local workspace — it fetches `main`, rebases any remaining branches, and drops the landed ones out of the stack in a single pass.

If any landed branch touched `crates/migrate/migrations/`, run `mise run migrate` afterwards so the local database matches the schema `main` now describes.

Confirm from the status output that every landed branch is gone. Report: "Landed: A, B, C. Workspace now clean."

## Failure modes

- **PR conflicts after merging the base.** `but pull` will surface conflicts in child branches. Defer to the gitbutler skill's "Resolve conflicts after reorder/move" recipe. Do NOT use raw git resolution commands.
- **CI failing on a PR.** Stop the flow. Report which PR is blocked. Do not proceed to merge a child while a parent is failing.
- **PR already exists.** `but pr new` errors if the branch already has an open PR. Look up the existing URL with `gh pr list --head <branch>`, include it in the checkpoint-2 summary, and continue.
- **Empty workspace.** If `but status -fv` shows no branches with commits to land, report "no branches to land" and exit without calling `but pr new`.
- **Another agent is mid-flight.** `but pull` and bare `but push` are workspace-global and rewrite IDs under everyone. If `but status` shows lanes you did not create, confirm with the user before Step 8.

## Reference

For `but` command syntax, flags, and recovery recipes, see the `gitbutler` skill at `~/.claude/skills/gitbutler/SKILL.md`.

## When NOT to use this skill

| You actually want                                          | Go to                                            |
| :--------------------------------------------------------- | :----------------------------------------------- |
| Syntax or recovery recipes for an individual `but` command | user-level `gitbutler` skill                     |
| The gate's task definitions and what each one covers       | `.mise.toml`, [CLAUDE.md](../../../CLAUDE.md) §3 |
| A health review of the code before landing it              | **code-health-audit**                            |

## Provenance and maintenance

Ported from the `connect` repo's `cortex-land-in-origin-main` by Tim, 2026-08-07. Volatile facts and how to re-verify each:

| Volatile fact (as of 2026-08-07)                                     | Re-verify with                                                      |
| :------------------------------------------------------------------- | :------------------------------------------------------------------ |
| `but pr new` cascades stacked PRs; one-shot push+PR wrapper          | `but pr new --help`                                                 |
| GitHub auto-retargets a stacked child PR's base after parent merge   | `gh pr view <child-url> --json baseRefName` after a merge           |
| `but pull --status-after` integrates merged commits in one pass      | `but pull --help`                                                   |
| The gate is `generate` → `fmt` → `check`; Swift tasks sit outside it | `mise tasks`, and the `check` task's `depends` list in `.mise.toml` |
| Migrations are sequentially numbered and collide across branches     | `ls crates/migrate/migrations/`                                     |
