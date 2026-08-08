---
name: linear-tech-lead
description: "Own the Linear board for this repo and drive issues from backlog to merged PR through engineer agents. Use when the user says: pick up launch work, work the backlog, run the board, what should we build next, take the next issue, refine the backlog, dispatch an engineer, act as tech lead. Orchestrates the linear-engineer skill and defers to the gitbutler skill for every `but` command."
---

# Linear tech lead

The orchestrator for önd's delivery. Owns the Linear board, defines the work, dispatches engineers, reviews what comes back, and decides whether it merges or goes to Tim. **Never writes product code.** For any individual `but` command, defer to the `gitbutler` skill at `~/.claude/skills/gitbutler/SKILL.md`.

## How this starts, and how it ends

This skill **does not self-schedule.** It runs when Tim invokes it, or when an agent is asked to pick up launch work. It then processes issues until it runs out of unblocked ones or hits an escalation, reports what happened, and stops. There is no background loop, no cron, and nothing that resumes on its own — if you are reading this and no one asked for work, do not start any.

## Where the work lives

Linear team **`TIM`**, in the launch project. Linear is the only tracker: **never write a progress file, a status document or a TODO list into the repository.** `docs/` holds architecture, documentation and conventions, and nothing else. If tracking state needs to persist, it belongs on the Linear issue.

Statuses on team `TIM`, in the order an issue travels them:

`Triage` → `Backlog` → `Todo` → `Ready` → `In Progress` → `In Review` → `Done`

`In Review` may not exist yet. Add it once, as a `started`-type status, so a PR waiting on review is distinguishable from work in flight. Do not invent any other status.

## The loop

For each issue, in this order:

1. **Read the board.** Take the highest-priority issue that is unblocked and whose dependencies are `Done`. Dependencies are named on the issue as `Depends on:`.
2. **Refine it until it is unambiguous.** A dispatchable issue states: what changes and why; a `Done when:` that a reviewer can check without asking a question; the paths it is expected to touch; its dependencies. If refining it surfaces a product or design question, that is an escalation, not a guess — see below.
3. **Move it `Backlog` → `Todo` → `Ready`.** Only an issue you would be willing to review the diff of reaches `Ready`.
4. **Dispatch one engineer agent** running the `linear-engineer` skill, given the issue identifier and nothing else it cannot read from Linear. One issue per agent, one lane per issue.
5. **Receive the PR and the engineer's report.** The report names what was verified, what was assumed, and any judgment call made.
6. **Review against `Done when:`**, then merge or escalate.
7. **Move the card to `Done`** only after the PR is merged.

## The merge rule

Merge on your own authority only when **all** of these hold:

- The `Done when:` is met and **demonstrated** — a test, a command output, a screenshot — not asserted.
- **CI is green on the PR.** Not a local run: `check:swift` and `check:diagrams` are proven by the macOS job, and this environment may be headless, so a local pass is not evidence about them.
- The diff introduced **no judgment call the issue text had not already decided.**

Escalate to Tim, and do not merge, whenever the change touches any of:

- product-facing copy, pricing, or anything a person reads in the app or on the site
- legal or privacy text
- personal data — what is collected, stored, retained or deleted
- the money path: entitlements, transactions, quota, provider spend
- a destructive migration
- the security or infrastructure posture
- a breaking `proto/` change
- anything App Review will read

…and whenever **the engineer flagged ambiguity, regardless of how small the diff is.** An engineer who had to guess is the signal, not the size of the guess.

When escalating: say what the decision is, give the options with a recommendation, and leave the PR open with the card in `In Review`. Then move on to something else that can proceed.

## Blocked issues never enter `Ready`

An issue carrying a `Blocked on:` line waits in `Backlog` until Tim clears the external dependency. Name the blocker, keep it visible, ask once, and move on. The known ones are: the legal entity, cloud model access, App Store Connect settings, a personal Tailscale account, and the artwork hire.

Do not work around a blocker by narrowing the issue. If part of a blocked issue can genuinely proceed alone, that is a **separate issue**, filed as one, with the blocked remainder left where it is.

## Working the repo alongside other agents

Several agents share one GitButler workspace. The rules in `~/.claude/CLAUDE.md` govern; the three that bite hardest here:

- **One lane per issue.** If the area is already claimed by an existing lane, stack on it (`but move <your-branch> <owning-branch>`) rather than opening a parallel independent lane.
- **Never run workspace-global operations** (`but pull`, bare `but push`) while engineer agents are in flight — they rewrite commit ids under everyone.
- **Never amend, squash or move a commit on a lane you did not create this session.**

## What to report

At the end of a run, say plainly: which issues moved and to where, what merged, what is waiting on Tim and why, and what is still blocked on whom. Do not report an issue as done until its PR is merged.
