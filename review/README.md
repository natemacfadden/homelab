# review

Reviews your repos on a schedule, one at a time, **distributed over the Ray
cluster**: this box picks the repo and keeps the results, a tagged worker runs
[repo-review](https://github.com/natemacfadden/repo-review) against a local
model. It reads `~/github/manifest.csv` and draws one repo weighted by
importance x staleness, so stale and never-reviewed repos dominate. Output lands
in `repo-review-out/<repo>/<stamp>/` — one doc per lens, plus `MEMO.md` and
`metrics.json`.

## Run

`./review` is the only entry point. Run it on the box with the repos, the
manifest, the `raylab` venv, and node (that box also needs to reach the model
server, and at least one worker must be tagged as a reviewer — see
[Setup](#setup)).

```
./review                       one review now, weighted pick
./review run <repo>            review a specific repo instead
./review run --loop [N]        review continuously, stalest-first (N caps cycles)
./review nightly               install cron: one review nightly at 3am
./review stop                  stop the running review AND drop the nightly cron
```

A run prints a live heartbeat (repo + elapsed) and mirrors its output to
`repo-review-out/_cron/live.log`; under cron it logs to
`repo-review-out/_cron/<stamp>.log`. If the model server is unreachable the run
says so and exits instead of failing halfway.

## Watch and triage

```
./review watch                 follow the running review's lens phases
./review plan                  what would be picked, and manifest health
./review inbox [new]           archived reviews + scores, newest first
./review show <repo/stamp>     print that review's MEMO
./review mark <repo/stamp> <read|handled> ["note"]
```

`inbox` tracks read/handled state in a `.status` file inside each review dir
(absent = new), so triage only ever writes to finished reviews — it can't
disturb a running loop. `plan` is also the health check: it lists every repo
with its weight and flags manifest problems (missing from disk, not a git repo,
on disk but unlisted), exiting non-zero if any warning fires.

## Setup

The worker does the work, so it needs the reviewer toolchain: node, opencode,
coreutils, and a clone of repo-review. Provision one with
[`../scripts/setup_reviewer.sh`](../scripts/setup_reviewer.sh) (macOS or
Debian/Ubuntu, idempotent), then tag it in the cluster with the resource
`./review` targets — `{"mac": 1}` by default:

```bash
REVIEW_MODEL_URL=http://compute01:8000/v1 bash scripts/setup_reviewer.sh
```

`driver.py` bundles the chosen repo (`git bundle`, full history), ships it to
that worker, runs the review under a memory watchdog, and files the returned
docs back here. The model stays on the inference box and is reached over the
network, so nothing but selection and archiving happens locally.

## manifest.csv

Lives at `~/github/manifest.csv` — outside this repo, never committed. Columns
are matched by header name, so order doesn't matter:

| Column | Meaning |
| --- | --- |
| `repo` | directory name under `~/github` |
| `to review` | `0` opts the repo out entirely |
| `0-10 importance` | weight; blank/`n/a`/`0` means never picked |
| `profile` | who's judging (`job`, `oss-audit`, …) |
| `specialization` | free text passed as repo-review's `--for` |
| `flavor` | what the repo is for (`performance`, `research`, …); blank auto-detects |
| `note` | free text, printed when that repo is drawn |
| `memory heavy` | `1` flags it in the plan; the worker's cap is what actually protects it |

A repo is reviewable when it's opted in, on disk, a git repo, and has a numeric
importance. "Last reviewed" isn't a column you maintain — it's read from the
archive's stamped directories.

## Environment

Defaults are right for this cluster; override only what moves.

| Variable | Default | Use |
| --- | --- | --- |
| `REPO_REVIEW_MODEL` | `ds4/deepseek-v4-flash` | model the worker reviews with |
| `REVIEW_MODEL_URL` | `http://127.0.0.1:8000/v1` | model base URL, health-checked before each run |
| `REVIEW_WORKER_RESOURCE` | `mac` | Ray resource tag the review runs on |
| `REVIEW_MEM_CAP_MB` | `0` (auto: ~90% of worker RAM) | kills a review that blows the cap, and reports it |
| `REVIEW_KILL_ORPHANS` | unset | see below |
| `RAY_ADDRESS`, `RAYLAB_VENV` | `auto`, `~/raylab/venv` | cluster and Ray venv |
| `REVIEW_GITHUB`, `REVIEW_MANIFEST`, `REVIEW_ARCHIVE` | under `~/github` | paths |

`REVIEW_KILL_ORPHANS=1` sweeps reviewer processes a prior crash orphaned, at
each run's start. Only set it on a worker **dedicated** to reviews — on a shared
box it could kill someone else's `opencode`.

## Internals

- `schedule.mjs` — selection only: parse the manifest, health-check it, print
  the plan, and with `--emit` write the drawn repo as JSON. Never runs a review.
- `driver.py` — Ray driver: bundle, dispatch, memory watchdog, archive.
- `manifest.mjs` — pure helpers (CSV, health check, weighting). Tests:
  `node --test test.mjs`.
