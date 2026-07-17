# review

Picks which repo to review next and runs
[repo-review](https://github.com/natemacfadden/repo-review) on it, **distributed
over a Ray cluster**: selection and results stay on this box, while the review
itself executes on a tagged worker. It reads `~/github/manifest.csv`,
health-checks it against the repos on disk, and draws one repo weighted by
importance x staleness so older and never-reviewed repos dominate. Results are
archived at `repo-review-out/<repo>/<stamp>/` (one doc per lens, plus `MEMO.md`
and `metrics.json`).

Run it on the box that has the repos, the manifest, the `raylab` venv (Ray), and
node — and that can reach the model server. At least one Ray worker must be
tagged as a reviewer (see [Distributed setup](#distributed-setup)).

## Run

`run.sh` is the entry point; it sets up the env and dispatches to `driver.py`.

```
./run.sh                one review, weighted pick
./run.sh <repo>         review a specific repo once
./run.sh --loop [N]     review continuously, stalest-first (N caps the cycles)
./run.sh --nightly      install a cron job: one review nightly at 3am
./run.sh --stop         stop a running loop/review AND remove the nightly cron
```

Before each run it checks the model server is reachable (`REVIEW_MODEL_URL`) and
skips if not. Interactively it prints a live heartbeat and mirrors output to a
trim `repo-review-out/_cron/live.log`; under cron it logs to
`repo-review-out/_cron/<stamp>.log`.

## Watch and triage

- **Live**: the heartbeat shows the current repo + elapsed; `live.log` is a trim
  copy you can read any time.
- **`watch.sh [-f]`** — the running review's lens phases (which lens, verdict).
  Needs the Ray venv: `source ~/raylab/venv/bin/activate`.
- **`reviews.sh`** — inbox over the archive; tracks read/handled state in a
  `.status` file per review dir (never touches the running loop):

```
./reviews.sh                 every review + status + scores, newest first
./reviews.sh new             only reviews still marked new
./reviews.sh mark <repo/stamp> <read|handled> ["note"]
./reviews.sh show <repo/stamp>
```

## How selection works

`driver.py` picks by calling `schedule.mjs` (which can also run standalone):

```
node schedule.mjs [--dry-run] [--health] [--repo NAME] [--seed N]
```

It weights each reviewable repo by importance x staleness and applies a memory
gate (see the `memory heavy` column below): under `REVIEW_MIN_FREE_MB` (default
16000) it drops memory-heavy repos from the draw, and under `REVIEW_MIN_RUN_MB`
(default 3000) it skips the run entirely. `--repo NAME` overrides the gate.

## Distributed setup

`driver.py` ships the chosen repo (as a git bundle) to a Ray worker tagged with
`REVIEW_WORKER_RESOURCE` (default `mac`), runs the review there against the
model, and files the returned docs back here. Provision a worker with
`../scripts/setup_reviewer.sh` (OS-agnostic: node, opencode, coreutils, a clone
of repo-review). The model defaults to `ds4/deepseek-v4-flash` (a local
DwarfStar server) and stays on the inference box, reachable cluster-wide.

## Environment

- **Model**: `REPO_REVIEW_MODEL` (default `ds4/deepseek-v4-flash`),
  `REVIEW_MODEL_URL` (health-check URL, default
  `http://127.0.0.1:8000/v1/models`).
- **Paths**: `REVIEW_GITHUB`, `REVIEW_MANIFEST`, `REVIEW_ARCHIVE`,
  `REVIEW_ADAPTER`.
- **Cluster**: `RAY_ADDRESS` (default `auto`), `REVIEW_WORKER_RESOURCE` (default
  `mac`; set to `reviewer` to make it a role), `RAYLAB_VENV`.
- **Memory**: `REVIEW_MIN_FREE_MB`, `REVIEW_MIN_RUN_MB`, `REVIEW_SKIP_MEM_HEAVY=1`
  (never pick heavy repos), `REVIEW_MEM_CAP_MB` (0 = auto, ~90% of worker RAM).
- **Cleanup**: on a worker **dedicated** to reviews, `REVIEW_KILL_ORPHANS=1`
  (e.g. `REVIEW_KILL_ORPHANS=1 ./run.sh --loop`) sweeps any reviewer process a
  prior crash orphaned, at each run's start. Leave it unset on a shared machine
  — it could kill another user's `opencode`.

## manifest.csv

Columns: `repo, mine?, 0-10 importance, profile, specialization, flavor, note,
last reviewed, memory heavy`. A repo is reviewable when it is a git repo on disk
with a numeric importance. `note` is free text for whoever runs the scheduler.
The file lives outside this repo and is never committed.

## Other

- `repos_status.sh [--no-fetch] [root]` — quick git sync report for every repo
  under a root (default `~/github`): dirty trees, ahead/behind vs upstream.

## Test

```
node --test test.mjs
```
