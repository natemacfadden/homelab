# Home Lab Plan

Heterogeneous ML/AI cluster. Setup scripts: setup_head.sh and setup_worker.sh.

## 1. Overview

Five-node cluster for training, local inference, and agent-directed CPU tasks.
Ray distributes work with resource-aware scheduling and automatic retry of
failed tasks. Prometheus and Grafana monitor it. Tailscale reaches it from
anywhere. Cron runs recurring jobs. Storage stays local per machine, and each
box has a dedicated role.

The cluster spans two ISAs (x86-64 and ARM64), three accelerator stacks (NVIDIA
CUDA, AMD ROCm, Apple Metal), and 4 GB to 128 GB of memory. This is handled with
Ray custom resource tags, an isolated always-on head node, layered memory
protection, and containerized tasks.

## 2. Machines and roles

| Machine | Hardware | Role / Ray tag |
|---|---|---|
| Head node: Chromebook C302 (coreboot) | Core m3, 4 GB RAM, 64 GB eMMC. Headless Debian, SSH only. | Ray head (GCS + scheduler), Prometheus, cron. Always on. No Grafana, Docker, or desktop. |
| Big box | Ryzen AI Max+ 395 (Strix Halo), 128 GB unified, Radeon 8060S. | llama.cpp server, Vulkan backend, OpenAI-compatible API. GGUF quantization (CPU-side). Fine-tuning experimental only (ROCm on gfx1151 is flaky; Vulkan cannot train). Tag: big_memory. |
| Workstation 1 (ws1) | Beefy CPU, 32 GB DDR5, RTX 5060 Ti 16 GB (CUDA). | Repo trawler and general semi-long tasks; primary fine-tuning box (<=16 GB VRAM). Also hosts Grafana. Tag: cuda. |
| Workstation 2 (ws2) | Older CPU, 16 GB, RX 6700 XT. Gaming PC, intermittently offline. | Small misc tasks (Ray reroutes when it drops). Interactive station: tiling WM, tmux (resurrect/continuum), Taskwarrior. Tag: small_task. |
| MacBook Pro (M1, ARM64) | Apple Metal. No systemd, no Docker initially (macOS Docker runs a RAM-hungry hidden VM; quit Docker Desktop to free it). | Always-on worker for misc and moderately heavy tasks, run bare. Tag: mac. |

## 3. Head node vs worker nodes

| | Head (setup_head.sh) | Workers (setup_worker.sh) |
|---|---|---|
| Ray | `ray start --head --port=6379 --dashboard-host=0.0.0.0` via systemd. A GCS hygiene env var prunes finished-task metadata; GCS memory grows with task history, so a restart between batches is the fallback. | `ray start --address=HEAD_IP:6379 --resources='{"cuda": 1}'` via systemd. Runs as your normal user, no sudo or SSH access; the worker opens a persistent outbound connection and the head pushes tasks down it. |
| Monitoring | Prometheus server, scrapes Ray's service-discovery file and every node_exporter. MemoryMax=1G cap. | node_exporter only. Grafana on ws1 (INSTALL_GRAFANA=1), pointed at the head's Prometheus on :9090. The server can live anywhere; browsers do the rendering. |
| Memory limits | None; no heavy tasks run here. | Layer 1: RAY_memory_usage_threshold=0.80, graceful retryable task kills. Layer 2: systemd MemoryMax=95%, kernel cgroup hard wall. |
| Docker | Not installed. | Rootless Docker (INSTALL_DOCKER=1) on Linux workers. Tasks that install software run containerized instead of getting sudo. |
| Cron | Nightly trawler job: score repos, pick one, `ray job submit`. | None by default. |
| Both | Python venv with the same pinned Ray version; Tailscale (authenticate once with `sudo tailscale up`); tmux; same username everywhere for SSH. | |

## 4. Ray internals

Each machine runs a raylet: it schedules tasks onto pre-started worker processes
and manages the local object store (Plasma, shared memory). A remote call
returns an ObjectRef (a future) immediately. The finished task's return value,
any picklable Python object, parks in the worker's local object store and only
crosses the network when something calls `ray.get()`. The head's GCS keeps the
global directory of objects and live nodes. Results flow back to the submitting
driver, so submit long-running jobs from the head inside tmux.

## 5. Key workflows

- Repo trawler (ws1): a Ray task runs `docker run -v ~/results:/results
  python:3.12 ...` to clone a repo, install dependencies inside the container,
  run Claude Code headless, write the review to the mounted folder, and return
  the review text to the driver. Overhead is near-native on Linux (~1 s startup).
- Inference from anywhere: point an agent's API base URL at the big box's
  llama.cpp server port. Set AMD_VULKAN_ICD=RADV.
- Recurring jobs: cron on the head runs a scoring script, then `ray job submit`.
  systemd timers are the modern alternative; Airflow is overkill.
- Provisioning: OS install is manual; the rest is the two scripts, kept in a git
  repo with pinned versions. Re-run periodically to catch drift. Ansible is the
  scale-up path.
- Networking and storage: WiFi for now; a gigabit switch later if transfers get
  slow. Local-first storage per role; scp between boxes; NFS export from the big
  box only if a shared results folder becomes useful.

## 6. Setup order

1. Install Debian on the Chromebook, set the hostname, enable SSH.
2. Run setup_head.sh; open the dashboard on :8265 from another browser.
3. Run setup_worker.sh per box with the correct HEAD_IP and tag; run a trivial
   test task on each.
4. Set up llama.cpp (Vulkan) on the big box; hit the API from ws1.
5. Wire up the headless trawler script and containerized trawler tasks.
6. Add Grafana on ws1 and point it at the Prometheus data source.
7. Run `tailscale up` on every box.
8. Set up tmux plugins, Taskwarrior, and a tiling WM on ws2.

Later: gigabit switch, NFS, Docker on the Mac, Ansible.
