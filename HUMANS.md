# HUMANS.md — actlog

A guide for humans navigating and developing this codebase. Written
2026-11-18 per the org-wide rule that every agent-developed repo
carries one.

## What this is

A single-file Emacs package (`actlog.el`, ~590 lines) that rebuilds
the Emacs-side half of StayFree: it samples which buffer is front
every 15 seconds, credits elapsed wall time to an activity, and
writes ordinary Org clock lines into a per-day journal you own
(`actlog/YYYY-MM-DD.org`). Because the journal is plain Org clock
data, `org-clock-report`, the agenda and `org-clock-sum` all work on
it with this package not even loaded.

What it deliberately is NOT: device-wide per-app screen time. Android
sandboxes apps away from each other, so Emacs cannot read
UsageStatsManager; that half lives in `android-usage.el` (a sibling
repo) which imports a usage-app export instead.

## Mental model

Two timers drive everything:

- a **sampler** (`actlog--sampler-timer`, every `actlog-interval`
  seconds) that looks at the current buffer and hands the elapsed
  slice to `actlog--account`;
- a **flusher** (`actlog--flusher-timer`, every `actlog-flush-interval`
  seconds) that closes the live session and writes the Org file.

State is threefold: the in-memory live session (`actlog--current-key`,
`actlog--current-mode`, `actlog--since`), the day totals
(`actlog--totals`), and a small state file (`actlog--save-state`/
`actlog--load-state`) so a restart resumes the live session instead of
losing it.

## Code map (actlog.el)

| Symbol | Role |
|---|---|
| `actlog-interval` / `actlog-flush-interval` | sampling and flush cadence (seconds). |
| `actlog-idle-threshold` / `actlog-max-gap` | honesty rules: idle time is not credited; gaps longer than `actlog-max-gap` are dropped (suspend/hibernate). |
| `actlog--activity-key` | the classifier: project name (project.el) for project files, `Files:dir` for plain files, `Emacs:Bufname` for special buffers, subject to `actlog-ignore-buffer-regexps`. |
| `actlog--account` | the core bookkeeping: decides whether the slice continues the live session, closes it, or starts a new one; handles idle deduction. |
| `actlog--close-session` / `actlog--close-live` | turn a finished session into a CLOCK line + day total. |
| `actlog--rotate-day-if-needed` | midnight rollover: closes the live session into yesterday's file before anything is credited to today. |
| `actlog--append-clock` / `actlog--journal-clock` | write the journal: one Org entry per activity (heading from the key), one CLOCK line per session, `:MODE:` property recording the major mode. |
| `actlog--parse-day` / `actlog--read-day` | read a journal file back (for `actlog-report`). |
| `actlog-report` / `actlog-open-journal` / `actlog-toggle` | the three user commands. |
| `actlog--start` / `actlog--stop` / `actlog--shutdown` | mode wiring and clean shutdown (flush before exiting Emacs). |

## Core algorithms, in prose

**Sampling and accounting.** Every tick computes `now - last-sample`,
applies the idle rules (if Emacs was idle longer than
`actlog-idle-threshold`, only the pre-idle portion is kept), then asks
`actlog--activity-key` for the current activity. Same key as the live
session extends it; a different key closes the old session (CLOCK
line + total) and opens a new one. Sessions are clamped by
`actlog-max-gap` so a suspended device does not bank hours.

**Journal format.** One file per day; inside, one level-1 heading per
activity with a `:MODE:` property drawer and CLOCK lines appended in
session order. The writer finds the entry by heading text and inserts
the CLOCK line after the existing drawer, keeping the file valid Org
without rewriting it.

**Midnight.** `actlog--rotate-day-if-needed` compares the day of
`actlog--since` with today; on mismatch it closes the live session
into the old day before crediting anything to the new one.

## Invariants and gotchas

- The journal is the contract: plain Org clock data, readable by stock
  Org. Do not add package-private syntax to it.
- Idle and gap thresholds are honesty rules; relaxing them makes the
  data lie (banked suspend time). Change only with a README update.
- `actlog--shutdown` must stay wired to `kill-emacs-hook` or restarts
  silently lose the live session (state file mitigates, does not
  remove).
- Emacs-only scope: the Android per-app half is `android-usage.el`,
  not here.

## Developing

From AGENTS.md / Makefile (verify with `make check`):

```sh
emacs -Q --batch -L . -f batch-byte-compile actlog.el   # 0 warnings gate
emacs -Q --batch -L . -l test.el -f ert-run-tests-batch-and-exit
```

Branch law: land on `ai/main`. `actlog.elc` in the tree is a build
artifact; do not commit it.
