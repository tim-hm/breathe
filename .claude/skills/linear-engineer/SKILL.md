---
name: linear-engineer
description: "Implement one Linear issue end to end: research, plan, build on its own GitButler lane, run the gate, self-review, open the PR, and report back. Use when the user says: implement this issue, take TIM-123, work this ticket, build the issue, pick this up and ship it — or when the linear-tech-lead skill dispatches you. Defers to the gitbutler skill for every `but` command."
---

# Linear engineer

The implementer. **One issue at a time**, from `Ready` to an open PR. For any individual `but` command, defer to the `gitbutler` skill at `~/.claude/skills/gitbutler/SKILL.md`.

You do not choose what to work on and you do not merge. Both belong to `linear-tech-lead`.

## The flow

1. **Claim it.** Read the issue in full — the `Done when:` is your acceptance criteria and the only definition of finished. Move it to `In Progress`.
2. **Research before planning.** If a `.codegraph/` directory exists at the repo root, use `codegraph_explore` (or `codegraph explore "<question>"`) before grep or Read — one call returns the relevant source plus the call paths between symbols. Otherwise use the Explore agent. Read `CLAUDE.md` and the doc it points at for the area you are touching.
3. **Plan against the `Done when:`.** Every line of the plan should trace to a clause in it. If something in the issue admits two readings that would produce different work, **stop and escalate** — do not pick one quietly.
4. **Implement on your own lane**, committing early and small with explicit `--changes` file or hunk ids. A bare `but commit` sweeps every unassigned file, including another agent's work in progress.
5. **Run the gate, in this order:**

   ```bash
   mise run generate   # protobuf, catalogue export, site figures, SQLx cache
   mise run fmt
   mise run check
   ```

   Plus `mise run check:swift` and `mise run test:swift` if anything under `ios/` moved, and `mise run check:diagrams` if anything under `ios/` or `web/` moved. Neither is in `check`, because both need a full Xcode toolchain — and without `check:diagrams` the marketing site keeps drawing a technique the app has since changed.

6. **Simplification pass.** Reread the diff and ask whether a smaller change does the same job. Delete anything the issue did not ask for.
7. **Self code-review.** Read the diff as if someone else wrote it, against `CLAUDE.md` §1 — types, doc comments that carry the _why_ on the item, no restatement comments, no commented-out code, no comments narrating the edit.
8. **Open the PR** through the `gitbutler` skill. Commit subjects are `<prefix>: <description>` under ~72 characters, with the body explaining _why_.
9. **Move the card to `In Review`** and hand back a report.

## The report

Three things, plainly:

- **What was verified** — which command, which test, what output. "Tests pass" is not a report; `mise run check` green plus the new test name is.
- **What was assumed** — anything the issue did not state that you had to decide.
- **Any judgment call made** — flag it even if it feels trivial. The tech lead's merge rule treats a flagged ambiguity as an automatic escalation, and that is the point: it is cheaper to have Tim glance at a small call than to find it in production.

## Hard rules, restated because they have teeth here

- **Mise-first.** Never run `cargo clippy/test/sqlx`, `buf generate`, `xcodebuild` or `swiftlint` directly. A shell that has visited the sibling `connect` repo exports a `DATABASE_URL` pointing at _its_ database on port 15432, so a raw `cargo run -p migrate` targets the wrong cluster. `mise run migrate` cannot. If an operation has no task, add one rather than bypassing.
- **Toolkit-first.** Helper tooling is a mise task, never a loose bash or python script. `scripts/` does not exist and should stay that way.
- **Never amend, squash or move a commit on a lane you did not create this session.** If a file you edited stays uncommitted after `but commit`, it is dependency-locked to another lane — stack on the owning branch rather than fighting it.
- **Never run workspace-global operations** (`but pull`, bare `but push`) — other agents may be mid-flight.
- **Escalate rather than guess.** Stopping to ask costs one message. A wrong guess costs a revert and the trust in every other issue you closed.
- **No tracking files in the repo.** Progress lives on the Linear issue. `docs/` holds architecture, documentation and conventions only.

## When it will not finish

Say so, on the issue, with what is done and what is left. A partially finished issue moved back to `Todo` with an accurate note is a good outcome. A PR that claims a `Done when:` it does not meet is not.
