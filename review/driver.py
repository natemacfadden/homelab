#!/usr/bin/env python3
"""Distributed review driver (semi-automated).

Picks a repo with the Node scheduler HERE, ships it to a Ray worker (tagged
REVIEW_WORKER_RESOURCE, default "mac"), runs the review there against the ds4
model, and files the returned docs + metrics into the local archive. Selection
and results stay here; only execution is remote. OS-agnostic (Linux + macOS).

  python driver.py                one review, weighted pick
  python driver.py <repo>         review a specific repo once (mode 1)
  python driver.py --loop [N]     cycle continuously, stalest-first (mode 2)

Env: RAY_ADDRESS (default "auto"), REVIEW_GITHUB, REVIEW_ARCHIVE,
     REPO_REVIEW_MODEL (default ds4/deepseek-v4-flash),
     REVIEW_WORKER_RESOURCE (default "mac"; set "reviewer" to make it a role),
     REVIEW_MEM_CAP_MB (0 = auto: ~90% of the worker's RAM),
     REVIEW_REPO (force a specific repo in the weighted pick).
"""
import argparse
import json
import os
import pathlib
import signal
import subprocess
import tempfile
import time
import ray

HOME = os.path.expanduser("~")
GITHUB = os.environ.get("REVIEW_GITHUB", f"{HOME}/github")
ARCHIVE = os.environ.get("REVIEW_ARCHIVE", f"{GITHUB}/repo-review-out")
SCHED = os.path.join(os.path.dirname(os.path.abspath(__file__)), "schedule.mjs")
MODEL = os.environ.get("REPO_REVIEW_MODEL", "ds4/deepseek-v4-flash")
WORKER_RESOURCE = os.environ.get("REVIEW_WORKER_RESOURCE", "mac")
MEM_CAP_MB = int(os.environ.get("REVIEW_MEM_CAP_MB", "0"))


def pick(repo=None):
    """Choose a repo via the Node scheduler's --emit mode (no local memory
    gate). A given repo (or REVIEW_REPO) forces one; else the weighted draw."""
    choice = tempfile.mktemp(suffix=".json")
    cmd = ["node", SCHED, "--emit", choice]
    forced = repo or os.environ.get("REVIEW_REPO")
    if forced:
        cmd += ["--repo", forced]
    subprocess.run(cmd, check=True)
    return json.loads(pathlib.Path(choice).read_text())


def bundle_bytes(name):
    """git bundle the chosen repo (full history) into one blob of bytes."""
    dest = tempfile.mktemp(suffix=".bundle")
    subprocess.run(
        ["git", "-C", f"{GITHUB}/{name}", "bundle", "create", dest, "--all"],
        check=True,
    )
    data = pathlib.Path(dest).read_bytes()
    os.remove(dest)
    return data


@ray.remote
def review(choice, bundle, model, mem_cap_mb):
    """Runs on the worker: clone the bundle, run the adapter under a memory
    watchdog, return the output files. A blown cap kills the review (not the
    box) and is reported, never silently skipped. OS-agnostic (Linux/macOS)."""
    import os
    import pathlib
    import signal
    import subprocess
    import tempfile
    import threading
    import time

    home = os.path.expanduser("~")
    work = tempfile.mkdtemp(prefix="rr-")
    bpath = os.path.join(work, "repo.bundle")
    pathlib.Path(bpath).write_bytes(bundle)
    repo = os.path.join(work, choice["name"])
    subprocess.run(["git", "clone", "-q", bpath, repo], check=True)

    out = os.path.join(work, "out")
    target = f"{repo}:{choice['flavor']}" if choice.get("flavor") else repo
    args = [target]
    if choice.get("profile"):
        args += ["--profile", choice["profile"]]
    if choice.get("specialization"):
        args += ["--for", choice["specialization"]]
    args += ["--out", out, "--stamp", choice["stamp"]]

    # launchd/systemd give a minimal PATH; add opencode + common node locations
    # for macOS (Homebrew) and Linux so node/opencode resolve either way.
    env = dict(os.environ)
    env["PATH"] = ":".join([
        f"{home}/.opencode/bin", "/opt/homebrew/bin", "/usr/local/bin",
        "/usr/bin", "/bin", env.get("PATH", ""),
    ])
    env["REPO_REVIEW_MODEL"] = model
    adapter = f"{home}/github/repo-review/adapters/opencode/run.mjs"

    # auto cap = ~90% of total RAM: Linux /proc/meminfo, else macOS sysctl.
    cap = mem_cap_mb
    if not cap:
        total_mb = 0
        try:
            for line in open("/proc/meminfo"):
                if line.startswith("MemTotal:"):
                    total_mb = int(line.split()[1]) // 1024
                    break
        except Exception:
            pass
        if not total_mb:
            try:
                total_mb = int(
                    subprocess.check_output(["sysctl", "-n", "hw.memsize"])
                ) // 1048576
            except Exception:
                total_mb = 0
        cap = int(total_mb * 0.9) if total_mb else 0

    def tree_rss_mb(root):
        try:
            rows = subprocess.check_output(
                ["ps", "-Ao", "pid,ppid,rss"], text=True
            ).splitlines()[1:]
        except Exception:
            return 0
        kids, rss = {}, {}
        for ln in rows:
            f = ln.split()
            if len(f) < 3:
                continue
            pid, ppid, r = int(f[0]), int(f[1]), int(f[2])
            kids.setdefault(ppid, []).append(pid)
            rss[pid] = r
        total, stack = 0, [root]
        while stack:
            p = stack.pop()
            total += rss.get(p, 0)
            stack += kids.get(p, [])
        return total // 1024

    proc = subprocess.Popen(
        ["node", adapter] + args, env=env, start_new_session=True
    )
    killed = {"mem": False}

    def watch():
        if not cap:
            return
        while proc.poll() is None:
            if tree_rss_mb(proc.pid) > cap:
                killed["mem"] = True
                try:
                    os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                except Exception:
                    pass
                break
            time.sleep(5)

    threading.Thread(target=watch, daemon=True).start()
    rc = proc.wait()

    files = {}
    od = pathlib.Path(out)
    if od.exists():
        for p in od.rglob("*"):
            if p.is_file():
                files[str(p.relative_to(out))] = p.read_bytes()
    return {"rc": rc, "killed_mem": killed["mem"], "cap_mb": cap, "files": files}


# holds the in-flight task ref so a second Ctrl-C can cancel it
_current = {"ref": None}


def run_once(repo=None):
    """One review: pick (or forced repo) -> bundle -> run on a worker -> file."""
    choice = pick(repo)
    print(f"chosen: {choice['name']} (flavor {choice.get('flavor') or 'auto'}, "
          f"profile {choice.get('profile') or 'general'})")
    data = bundle_bytes(choice["name"])
    _current["ref"] = review.options(
        resources={WORKER_RESOURCE: 1}
    ).remote(choice, data, MODEL, MEM_CAP_MB)
    try:
        res = ray.get(_current["ref"])
    finally:
        _current["ref"] = None

    dest = pathlib.Path(ARCHIVE)
    for rel, content in res["files"].items():
        fp = dest / rel
        fp.parent.mkdir(parents=True, exist_ok=True)
        fp.write_bytes(content)

    status = "MEM-KILLED" if res["killed_mem"] else f"rc={res['rc']}"
    print(f"{choice['name']}: {status}, cap {res['cap_mb']}MB, "
          f"{len(res['files'])} files -> {ARCHIVE}/{choice['name']}/{choice['stamp']}/")
    if res["killed_mem"]:
        print("LOUD: review exceeded the memory cap and was terminated - "
              "treat as a resource finding for this repo, not a clean result.")
    return choice, res


def main():
    ap = argparse.ArgumentParser(description="Distributed repo-review driver.")
    ap.add_argument("repo", nargs="?",
                    help="mode 1: review this specific repo once")
    ap.add_argument("--loop", nargs="?", const=-1, type=int, metavar="N",
                    help="mode 2: cycle continuously (stalest-first); "
                         "optional N caps the number of cycles")
    ap.add_argument("--interval", type=int, default=0,
                    help="seconds to wait between cycles in --loop")
    args = ap.parse_args()

    ray.init(address=os.environ.get("RAY_ADDRESS", "auto"))

    if args.loop is None:
        run_once(args.repo)
        return

    stop = {"n": 0}

    def handle(signum, frame):
        stop["n"] += 1
        if stop["n"] == 1:
            print("\n>> stop requested - finishing the current review, then "
                  "exiting. (Ctrl-C again to cancel it now.)", flush=True)
        else:
            print("\n>> hard stop - cancelling the running review.", flush=True)
            if _current["ref"] is not None:
                ray.cancel(_current["ref"], force=True)
            raise KeyboardInterrupt

    signal.signal(signal.SIGINT, handle)
    signal.signal(signal.SIGTERM, handle)

    pid = os.getpid()
    bar = "=" * 64
    print(bar)
    print("LOOP MODE - reviewing repos continuously, stalest-first.")
    print("  each cycle reviews the most-due repo; freshly reviewed ones sink.")
    print(f"  PID {pid}    stop: Ctrl-C   (or from elsewhere: kill {pid})")
    if args.loop and args.loop > 0:
        print(f"  capped at {args.loop} cycle(s)")
    print(bar, flush=True)

    n = 0
    while stop["n"] == 0:
        n += 1
        print(f"\n{bar}\n[cycle {n}] starting\n{bar}", flush=True)
        try:
            choice, _ = run_once()
            print(f"[cycle {n}] done: {choice['name']}", flush=True)
        except KeyboardInterrupt:
            print(f"[cycle {n}] cancelled.", flush=True)
            break
        except Exception as e:  # keep the loop alive across one bad review
            print(f"[cycle {n}] ERROR: {e}", flush=True)
        if args.loop and args.loop > 0 and n >= args.loop:
            print(f"reached cycle cap ({args.loop}).")
            break
        if stop["n"]:
            break
        if args.interval and stop["n"] == 0:
            print(f"[cycle {n}] sleeping {args.interval}s (Ctrl-C to stop)",
                  flush=True)
            time.sleep(args.interval)

    print(f"\nloop stopped after {n} cycle(s).", flush=True)


if __name__ == "__main__":
    main()
