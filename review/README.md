# review-scheduler

Picks which repo to review next and runs
[repo-review](https://github.com/natemacfadden/repo-review) on it. Reads
`~/github/manifest.csv`, health-checks it against the repos on disk, and draws
one repo weighted by importance x staleness so older and never-reviewed repos
dominate. Reviews are archived at `repo-review-out/<repo>/<timestamp>/`.

## Use

```
node schedule.mjs            # pick one repo and run its review
node schedule.mjs --dry-run  # print the plan and command, don't run
node schedule.mjs --health   # health report only
node schedule.mjs --repo NAME [--seed N]
```

The model defaults to `ds4/deepseek-v4-flash` (antirez's local DwarfStar);
override with `REPO_REVIEW_MODEL=provider/model`. Paths override via
`REVIEW_GITHUB` / `REVIEW_MANIFEST` / `REVIEW_ARCHIVE` / `REVIEW_ADAPTER`.

Memory-aware (the `memory heavy` column): with less than `REVIEW_MIN_FREE_MB`
available (default 16000) it drops memory-heavy repos from the draw, and below
`REVIEW_MIN_RUN_MB` (default 3000) it skips the run. `REVIEW_SKIP_MEM_HEAVY=1`
never picks heavy repos. `--repo NAME` overrides the gate.

## Nightly cron

`cron.sh` wraps a run for cron: it puts node/opencode on PATH, skips if
antirez's ds4 server is down, and logs to `repo-review-out/_cron/`. One review
a night at 3am:

```
0 3 * * * /bin/bash -lc '/home/nate/github/review-scheduler/cron.sh'
```

## manifest.csv

Columns: `repo, mine?, 0-10 importance, profile, specialization, flavor, note,
last reviewed, memory heavy`. A repo is reviewable when it is a git repo on disk
with a numeric importance. `note` is free text for whoever runs the scheduler.

## Test

```
node --test test.mjs
```
