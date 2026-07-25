# homelab

Install scripts for a five-node Ray cluster (one head, four workers) with
Prometheus, Tailscale, and optional Grafana/Docker. You install the OS; the
scripts do the rest. Everything is idempotent — re-running is safe, and is how
you apply a config change.

What each box is and why it's shaped that way:
[docs/CLUSTER.md](docs/CLUSTER.md).

## `./lab`

Everything runs through one command. It explains itself: `./lab` for the menu,
`./lab <verb> --help` for a verb's flags, env, and examples, and a verb run
without what it needs tells you what's missing.

```
setup --head | --worker | --worker-mac | --llm | --reviewer   provision this box
deploy [--check]                                              push to every worker
check                                                         verify this box
rename <name>                                                 rename this box
claude | ds4 | repos | review                                 use the cluster
```

## Bring-up order

The one thing no single command can tell you, because it spans boxes:

1. **Head first** — `./lab setup --head`. It prints the address to use as
   `HEAD_IP` everywhere else, and saves it to `~/ip.txt`.
2. **Each worker**, pointed at that address and tagged with what it's for:
   `HEAD_IP=head01 RESOURCES='{"cuda": 1}' ./lab setup --worker` (the MacBook
   takes `--worker-mac`). `./lab setup --worker --help` explains tags.
3. **Thereafter, from the head**: `./lab deploy` pushes this repo to the whole
   fleet and re-runs setup on each box, so you stop SSHing around.

**Bootstrapping a headless head**, which can't run `./lab` before it has the
repo:

```bash
tar czf - --exclude=.git . | ssh user@head-ip 'mkdir -p ~/homelab && tar xzf - -C ~/homelab'
ssh user@head-ip 'cd ~/homelab && ./lab setup --head'
```

## Two invariants

- **Ray and Python must be identical on every node** — Ray enforces it and
  refuses to join otherwise. Both are pinned at the top of `scripts/common.sh`;
  change them there and redeploy the fleet, never one box at a time. `./lab
  check` reports the mismatch as a worker that won't join.
- **Two config lists are edited by hand, in place**: `NODE_TARGETS` in
  `scripts/setup_head.sh` (Prometheus scrape targets) and `WORKERS` in
  `scripts/deploy.sh` (who's in the fleet). Both are at the top of their file and
  say so. Everything else is a flag or an env var.

## Layout

`scripts/` holds the implementations behind `./lab`; you don't call them
directly, and their leading comments are the `--help` text you get through it.
[`review/`](review/README.md) is the one subsystem with its own docs — it reviews
one of your repos a night on a tagged worker.
