# homelab

Install scripts for a five-node Ray cluster (one head, four workers) with
Prometheus, Tailscale, and optional Grafana/Docker. You install the OS; the
scripts do the rest. Everything is idempotent — re-running is safe.

Architecture and machine roles: [docs/PLAN.md](docs/PLAN.md).

## `./lab`

One entry point. Run it with no arguments for the menu; `./lab <verb> --help`
for the detail on any verb.

```
PROVISION (run on the box itself; needs sudo; idempotent)
  ./lab setup --head          Ray head + Prometheus + cron
  ./lab setup --worker        Ray worker + node_exporter   [HEAD_IP=... RESOURCES=...]
  ./lab setup --worker-mac    macOS worker (uv + launchd)  [HEAD_IP=... RESOURCES=...]
  ./lab setup --llm           llama.cpp server (big box)
  ./lab setup --reviewer      reviewer toolchain on a worker

FLEET (run from the head or your laptop)
  ./lab deploy                push this repo + run setup on every worker
  ./lab deploy --check        healthcheck each worker instead

THIS BOX
  ./lab check                 verify services, and that it joined the cluster
  ./lab rename <name>         hostname + Tailscale name + restart Ray

USE THE CLUSTER
  ./lab claude [args]         Claude Code against the local model
  ./lab ds4                   ds4-server in the foreground (big box)
  ./lab repos                 git sync report over ~/github
  ./lab review ...            repo reviews (./lab review help)
```

`scripts/` holds the implementations — you don't call them directly. Two files
there are still worth editing by hand, and both say so at the top: the
`NODE_TARGETS` scrape list in `setup_head.sh`, and the `WORKERS` fleet list in
`deploy.sh`.

## Bringing up the cluster

**Head first** — run on the always-on box (it also configures the box to stay on
with the lid closed):

```bash
./lab setup --head
```

It prints the address to use as `HEAD_IP` on the workers (Tailscale IP if up,
else LAN IP) and saves it to `~/ip.txt`. For a headless head, push the repo over
first:

```bash
tar czf - --exclude=.git . | ssh user@head-ip 'mkdir -p ~/homelab && tar xzf - -C ~/homelab'
ssh user@head-ip 'cd ~/homelab && ./lab setup --head'
```

**Then each worker**, with `HEAD_IP` (the head's IP/Tailscale name) and
`RESOURCES` (the Ray tag this box advertises, so matching tasks land here):

```bash
# ws1: CUDA GPU; also runs the trawler (Docker) and dashboards (Grafana)
HEAD_IP=192.168.1.50 RESOURCES='{"cuda": 1}' INSTALL_DOCKER=1 INSTALL_GRAFANA=1 ./lab setup --worker

# big box: 128 GB unified memory
HEAD_IP=192.168.1.50 RESOURCES='{"big_memory": 1}' ./lab setup --worker

# ws2: small / intermittent tasks
HEAD_IP=192.168.1.50 RESOURCES='{"small_task": 1}' ./lab setup --worker
```

The MacBook takes `--worker-mac` (uv + launchd; opts into Ray's experimental
macOS clustering). Install the Tailscale app, sign in, then:

```bash
HEAD_IP=head01 RESOURCES='{"mac": 1}' ./lab setup --worker-mac
```

### RESOURCES tags

Arbitrary labels you invent so tasks can target a box; a task runs there only if
it requests the tag (`@ray.remote(resources={"cuda": 1})`). The number is a
concurrency limit (units available), not hardware — `{"cuda": 1}` = one such task
at a time. A box can advertise several: `{"amd": 1, "big_memory": 1}`. The value
is baked into the box's service, so it survives reboots; change it by re-running
setup (or `./lab deploy`) with a new value. CPUs/GPUs are auto-detected
separately.

### Worker options

Set as environment variables; full list per role via `./lab setup --worker --help`.

| Flag | Default | Use |
| --- | --- | --- |
| `INSTALL_DOCKER` | 0 (off) | on for workers that run containerized tasks |
| `INSTALL_GRAFANA` | 0 (off) | on for one box only (serves the dashboards) |
| `INSTALL_SSH` | 1 (on) | installs OpenSSH; 0 to skip (see [SSH](#ssh)) |
| `SSH_KEY_ONLY` | 0 (off) | disable password auth (key-only); off = passwords left alone |
| `SSH_TAILSCALE_ONLY` | 0 (off) | bind sshd to the Tailscale IP only |

## Deploy to all workers

`./lab deploy` copies the repo (tar over ssh) to every worker and runs its setup
there, so you don't SSH into each box by hand:

```bash
HEAD_IP=head01 ./lab deploy          # provision/update all workers
./lab deploy --check                 # healthcheck each instead
```

**The fleet list** is the `WORKERS` array at the top of `scripts/deploy.sh` — you
edit it in place (same idea as `NODE_TARGETS`). One row per worker,
`|`-separated:

```
# host                       | RESOURCES                   | extra flags | os
compute01                    | {"amd": 1, "big_memory": 1} |             | linux
compute02                    | {"cuda": 1}                 |             | linux
compute03                    | {"amd": 1, "small_task": 1} |             | linux
natemacfadden@computemac01   | {"mac": 1}                  |             | mac
```

A bare host logs in as `SSH_USER` (defaults to your current user); write
`user@host` for a box whose login differs (e.g. the mac's `natemacfadden`).

`--check` runs whatever is already on each box rather than pushing first, so a
worker needs at least one full deploy before it works.

**Passwordless SSH (one-time):** deploy logs in with an SSH key. Run from the box
you deploy *from* (e.g. the head):

```bash
ls ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519   # once, if you have no key
ssh-copy-id nate@compute01                          # once per box, uses its login
ssh-copy-id natemacfadden@computemac01
ssh nate@compute01 true && echo OK                  # verify: no password prompt
```

A box needs an SSH server before you can copy a key to it: a fresh linux worker
gets one from its first setup run (`INSTALL_SSH=1`); the mac needs Remote Login
on (see [SSH](#ssh)).

**Sudo during deploy:** setup needs root, so deploy runs it with `ssh -t` and you
type each box's sudo password once per deploy. To make deploys fully hands-off,
give your user passwordless sudo on each worker (one time, at the console or over
an interactive ssh):

```bash
echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/homelab   # on each worker
```

Scope it to the commands setup runs (apt-get, systemctl, tee, tar, …) instead of
`ALL` if you want a tighter grant.

## Health check

Runs automatically at the end of each setup; run it any time on a node:

```bash
./lab check
```

Auto-detects head, linux worker, or macOS worker (launchd), checks the services,
dashboard/Prometheus ports, and `ray status`, and exits non-zero if anything is
down (usable from cron or CI).

**It also verifies the node actually joined the cluster**, not just that the
service is running. `ray-worker` can be `active` (systemd only knows the local
process forked) while the head never registered the node — wrong `HEAD_IP`, an
unreachable GCS, or a Ray/Python version mismatch. So on a worker it also checks:

- `head GCS <addr> reachable` — TCP to the head's `:6379` (from the `--address`
  baked into the worker service).
- `joined Ray cluster` — queries the head's node list and confirms *this* node is
  there and **alive**. It reports one of `present`, `REGISTERED BUT DEAD` (the
  head knew this node but it dropped — restart `ray-worker`), or `MISSING`
  (never joined). This is the check that catches an "All checks passed" worker
  that isn't in `ray status` on the head.

On the head it adds a `cluster nodes` line (count of active nodes), so a head
serving an empty cluster is obvious at a glance.

## Using the cluster

**LLM server (big box).** OpenAI-compatible API on `:8081`. Serves the newest
`.gguf` under `~/models`; re-run with `MODEL=/path/to.gguf` to swap. API key:
`~/llm/api.key` (big box only).

```bash
./lab setup --llm
curl http://compute01:8081/v1/models -H "Authorization: Bearer $(cat ~/llm/api.key)"
```

**Claude Code against the local model** — starts the model server for the
session, stops it on exit:

```bash
./lab claude                       # or: ./lab claude -p "explain this repo"
```

**Repo reviews.** `./lab review` reviews one of your repos a night on a tagged
worker, weighted by importance x staleness. See
[review/README.md](review/README.md).

## Config and restarts

- **Scrape targets:** the `NODE_TARGETS` array at the top of
  `scripts/setup_head.sh`. Edit, then `./lab setup --head`.
- **Pinned versions** (Ray, Prometheus, node_exporter) live at the top of each
  script; keep Ray identical on every node.
- **Python:** every node needs the same version (Ray enforces it). uv installs a
  pinned standalone Python (`PYTHON_VERSION`, default 3.12 — Ray 2.48 rejects
  3.13), independent of the OS. Re-running rebuilds a venv on the wrong Python.
- Re-running a setup role applies changes and restarts the affected services.

```bash
sudo systemctl restart ray-head prometheus         # head
sudo systemctl restart ray-worker node_exporter    # worker
```

Then, once per box: `sudo tailscale up`.

## Renaming a machine

Run on the box you're renaming — sets the OS hostname, Tailscale/MagicDNS name,
and restarts Ray:

```bash
./lab rename head01
```

It renames only that box. Afterwards update old-name references elsewhere: any
worker's `HEAD_IP`, and `NODE_TARGETS` in `scripts/setup_head.sh` (then re-run
`./lab setup --head`).

## SSH

On by default. Installs `openssh-server` and writes a drop-in at
`/etc/ssh/sshd_config.d/homelab.conf`. It leaves password auth **alone** — it
never disables it on its own, so a run can't lock you out. Set `SSH_KEY_ONLY=1`
to explicitly go key-only (`PasswordAuthentication no`). On the mac it enables
Remote Login (needs Full Disk Access, else enable it by hand).

## Troubleshooting

- **`Could not get lock ... unattended-upgr`** — Ubuntu's auto-updater holds the
  apt lock. Setup waits up to `APT_LOCK_TIMEOUT` seconds (default 300) for it to
  free, so this should be rare; if it still times out, wait for the updater to
  finish and re-run, or raise `APT_LOCK_TIMEOUT`. Don't kill it (can corrupt dpkg).
- **Workers offline after re-running `./lab setup --head`** — restarting the head
  resets Ray, so workers drop and reconnect on their own over a minute or two.
  Normal. Nudge a straggler with `sudo systemctl restart ray-worker`.
- **`No homelab services found`** — setup hasn't finished on that box, or you ran
  the check mid-reinstall before the service came up. Re-check once setup is done.
- **`./lab deploy --check` vs plain `./lab deploy`** — `--check` only runs the
  healthcheck already on each box (no code push); plain deploy copies the current
  repo and re-runs setup. Push code changes with plain deploy, not `--check`.
- **SSH `Permission denied (publickey)`** — the box is key-only and your key
  isn't on it. Add it with `ssh-copy-id` from a box that can still log in (or at
  the console). Setup never disables passwords unless you set `SSH_KEY_ONLY=1`.
- **SSH `Connection closed` (mac)** — Remote Login is off, or the login/key is
  wrong. Turn on Remote Login and connect as the mac's actual account.

## URLs

- Ray dashboard: `http://<head-ip>:8265`
- Prometheus: `http://<head-ip>:9090`
- Grafana (ws1): `http://<ws1-ip>:3000` — add Prometheus source `http://<head-ip>:9090`
