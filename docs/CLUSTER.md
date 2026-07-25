# Cluster inventory and decisions

What each box is, what it's for, and why it's shaped this way — the parts no
command can tell you. How to provision any of it: [`./lab`](../README.md). How
the nightly repo reviews work: [`review/`](../review/README.md).

## Machines

Five nodes, two ISAs (x86-64 and ARM64), three accelerator stacks, 4 GB to
128 GB of memory. Ray tags are how work finds the right box. Hostnames are
current as of 2026-07-25 — a rename must also update `NODE_TARGETS` in
`scripts/setup_head.sh` and `WORKERS` in `scripts/deploy.sh`.

| Box | Hardware | Job | Ray tag |
|---|---|---|---|
| `head01` | Chromebook C302 (coreboot), Core m3, 4 GB, 64 GB eMMC. Headless Debian, SSH only. | Ray head (GCS + scheduler), Prometheus, cron. Always on — deliberately weak and isolated, so no task can take the scheduler down with it. No Grafana, Docker, or desktop. | — |
| `compute01` | Ryzen AI Max+ 395 (Strix Halo), 128 GB unified, Radeon 8060S | Local inference: `ds4-server` on `:8000` (primary) and llama.cpp/Vulkan on `:8081` (legacy fallback). GGUF quantization, CPU-side. **No training** — ROCm on gfx1151 is flaky and Vulkan can't train. Also holds the repo checkouts and drives `review/`. | `amd`, `big_memory` |
| `compute02` | Beefy CPU, 32 GB DDR5, RTX 5060 Ti 16 GB | Primary fine-tuning box (anything fitting in 16 GB VRAM); general semi-long tasks. Where Grafana goes if you want it (`INSTALL_GRAFANA=1`, one box only). | `cuda` |
| `compute03` | Older CPU, 16 GB, RX 6700 XT | Gaming PC, **intermittently offline** — only small/misc tasks land here, and Ray reroutes when it drops. Doubles as the interactive station (tiling WM, tmux, Taskwarrior). | `amd`, `small_task` |
| `computemac01` | MacBook Pro M1, Apple Metal | Always-on worker; runs the repo reviews. No systemd (launchd instead) and no `node_exporter`, so it's absent from Prometheus. Docker on macOS runs a RAM-hungry hidden VM, so it's run bare. | `mac` |

## Decisions

- **Tags, not hostnames.** A task asks for a capability
  (`@ray.remote(resources={"cuda": 1})`) and Ray places it; nothing addresses a
  box directly. That's what lets `compute03` drop off without breaking anything,
  and why a tag's number is a concurrency limit rather than a hardware fact.
- **Two memory layers on workers.** Ray's `memory_usage_threshold=0.80` kills
  greedy tasks gracefully and retryably; a systemd `MemoryMax=95%` cgroup is the
  kernel backstop for when that isn't fast enough. The head gets neither — no
  heavy work runs there.
- **The head's GCS grows with task history.** An env var prunes finished-task
  metadata, and a head restart between big batches is the fallback. Another
  reason the head stays otherwise idle.
- **Containers over sudo.** A task that needs to install things runs in rootless
  Docker (`INSTALL_DOCKER=1`) rather than getting root on a worker.
- **Cron plus Ray, not a scheduler.** Recurring work is a cron line that submits
  to Ray. systemd timers are the modern equivalent; Airflow is overkill at five
  nodes.
- **Local-first storage.** Each box keeps its own data; `scp` between them. No
  shared filesystem until something actually needs one.
- **Two scripts in git, re-run to converge**, rather than configuration
  management. Ansible is the scale-up path if this outgrows that.

## Deferred

Gigabit switch (WiFi is fine so far), NFS export from `compute01` if a shared
results folder becomes useful, Docker on the Mac, Ansible.
