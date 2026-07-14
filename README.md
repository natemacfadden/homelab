# homelab

Install scripts for a five-node Ray cluster (one head, four workers) with
Prometheus, Tailscale, and optional Grafana/Docker. You install the OS; the
scripts do the rest. All are idempotent — re-running is safe.

Architecture and machine roles: [docs/PLAN.md](docs/PLAN.md).

```
scripts/setup_head.sh        Ray head + Prometheus + cron
scripts/setup_worker.sh      Ray worker + node_exporter (+ optional Docker/Grafana)
scripts/setup_worker_mac.sh  macOS worker (uv + launchd; no systemd)
scripts/deploy.sh            push + run setup on every worker (fleet deploy)
scripts/common.sh            shared helpers
scripts/healthcheck.sh       verify a node's services are up
scripts/rename.sh            rename a machine and restart Ray
```

## Head node

Run on the always-on box (it also configures the box to stay on with the lid
closed):

```bash
bash scripts/setup_head.sh
```

It prints the address to use as HEAD_IP on the workers (Tailscale IP if up, else
LAN IP) and saves it to `~/ip.txt`.

### Deploy to a headless head

```bash
rsync -av --exclude .git ./ user@head-ip:~/homelab/
ssh user@head-ip 'cd ~/homelab && bash scripts/setup_head.sh'
```

## Worker nodes

Set `HEAD_IP` (head's IP/Tailscale name) and `RESOURCES` (the Ray tag this box
advertises, so matching tasks land here):

```bash
# ws1: CUDA GPU; also runs the trawler (Docker) and dashboards (Grafana)
HEAD_IP=192.168.1.50 RESOURCES='{"cuda": 1}' INSTALL_DOCKER=1 INSTALL_GRAFANA=1 bash scripts/setup_worker.sh

# big box: 128 GB unified memory
HEAD_IP=192.168.1.50 RESOURCES='{"big_memory": 1}' bash scripts/setup_worker.sh

# ws2: small / intermittent tasks
HEAD_IP=192.168.1.50 RESOURCES='{"small_task": 1}' bash scripts/setup_worker.sh
```

The MacBook has its own script (uv + launchd; opts into Ray's experimental macOS
clustering). Install the Tailscale app, sign in, then:

```bash
HEAD_IP=head01 RESOURCES='{"mac": 1}' bash scripts/setup_worker_mac.sh
```

### Optional flags

| Flag | Default | Use |
| --- | --- | --- |
| `INSTALL_DOCKER` | 0 (off) | on for workers that run containerized tasks |
| `INSTALL_GRAFANA` | 0 (off) | on for one box only (serves the dashboards) |
| `INSTALL_SSH` | 1 (on) | installs + hardens OpenSSH; 0 to skip (see below) |
| `SSH_TAILSCALE_ONLY` | 0 (off) | bind sshd to the Tailscale IP only |

## Deploy to all workers

`scripts/deploy.sh` rsyncs the repo to every worker and runs its setup script,
so you don't SSH into each box by hand:

```bash
HEAD_IP=head01 bash scripts/deploy.sh          # provision/update all workers
HEAD_IP=head01 bash scripts/deploy.sh --check  # healthcheck each instead
```

**The manifest** is the `WORKERS` array at the top of `deploy.sh` — you edit it
in place (same idea as `NODE_TARGETS`). One row per worker, `|`-separated:

```
# host | RESOURCES | extra flags | os
ws1     | {"cuda": 1}       | INSTALL_DOCKER=1 INSTALL_GRAFANA=1 | linux
bigbox  | {"big_memory": 1} |                                    | linux
macbook | {"mac": 1}        |                                    | mac
```

Set `SSH_USER` if your login differs from the current user.

**Passwordless SSH (one-time):** `deploy.sh` logs in with an SSH key, not a
password. From the box you deploy *from*:

```bash
ssh-keygen -t ed25519            # once, if you don't already have a key
ssh-copy-id user@ws1             # once per worker — prompts for the password
```

Chicken-and-egg: a worker needs `openssh-server` before you can copy a key to
it. So provision each box once by hand (it installs SSH via `INSTALL_SSH=1`),
`ssh-copy-id` to it, then `deploy.sh` drives the whole fleet from then on — and
the copied key also flips that box to key-only auth on the next run.

## SSH

On by default. Installs `openssh-server` and writes a drop-in at
`/etc/ssh/sshd_config.d/homelab.conf`. It goes key-only **only if**
`~/.ssh/authorized_keys` already has a key — otherwise passwords stay on so a
headless first run can't lock you out (add a key, re-run to harden). On the mac
it enables Remote Login (needs Full Disk Access, else enable it by hand).

## Config and restarts

- **Scrape targets:** the `NODE_TARGETS` array at the top of `setup_head.sh`.
  Edit and re-run.
- **Pinned versions** (Ray, Prometheus, node_exporter) live at the top of each
  script; keep Ray identical on every node.
- **Python:** every node needs the same version (Ray enforces it). uv installs a
  pinned standalone Python (`PYTHON_VERSION`, default 3.12 — Ray 2.48 rejects
  3.13), independent of the OS. Re-running rebuilds a venv on the wrong Python.
- Re-running a script applies changes and restarts the affected services.

```bash
sudo systemctl restart ray-head prometheus         # head
sudo systemctl restart ray-worker node_exporter    # worker
```

Then, once per box: `sudo tailscale up`.

## Renaming a machine

Run on the box you're renaming — sets the OS hostname, Tailscale/MagicDNS name,
and restarts Ray:

```bash
bash scripts/rename.sh head01
```

It renames only that box. Afterwards update old-name references elsewhere: any
worker's `HEAD_IP`, and `NODE_TARGETS` in `setup_head.sh` (then re-run it).

## Health check

Runs automatically at the end of each setup script; run it any time on a node:

```bash
bash scripts/healthcheck.sh
```

Auto-detects head vs worker, checks the services, dashboard/Prometheus ports, and
`ray status`, and exits non-zero if anything is down (usable from cron or CI).

## URLs

- Ray dashboard: `http://<head-ip>:8265`
- Prometheus: `http://<head-ip>:9090`
- Grafana (ws1): `http://<ws1-ip>:3000` — add Prometheus source `http://<head-ip>:9090`
