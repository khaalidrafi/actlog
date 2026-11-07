# AGENTS.md — khaalidrafi/actlog

Local law for agents working in this repo. Global owner rules apply on
top (Guix-first machine, simple code, tests before implementation,
commit early/often, never procrastinate).

## Identity & commits (HARD LAW)

- Author every commit as your model identity: `MODEL <model@provider>`
  (e.g. `GLM-5.3-Flash <glm-5.3-flash@z.ai>`).
- End every commit message with BOTH trailers:

        Co-authored-by: <agent/harness> <agent@harness>
        Co-authored-by: Khalid Rafi <khaalidrafi@gmail.com>

  Canonical owner email is `khaalidrafi@gmail.com` — no variants.
- One model per commit. Never mix agents' work in one commit.
- Never commit directly to `main`. Branch `ai/main` is the working
  default; feature work on `ai/<topic>`.
- Descriptive subjects; put what comments can't hold in the body.

## This package

- actlog — StayFree-style activity tracking with an Org journal
  (single-file `actlog.el` + `test.el`).
- Gate before any push: `make compile` and `make test` (ERT, all
  green). CI: `.github/workflows/ci.yml` runs the same gate.
- Tests live in `test.el`; add tests BEFORE the fix/feature they cover.
- Keep code simple and short; comment the WHY, not the what.
- Record anything the owner should personally review in AI-REVIEW.org.
