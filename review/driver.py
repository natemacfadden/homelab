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
import sys
import tempfile
import threading
import time
import ray

HOME = os.path.expanduser("~")
GITHUB = os.environ.get("REVIEW_GITHUB", f"{HOME}/github")
ARCHIVE = os.environ.get("REVIEW_ARCHIVE", f"{GITHUB}/repo-review-out")
SCHED = os.path.join(os.path.dirname(os.path.abspath(__file__)), "schedule.mjs")
MODEL = os.environ.get("REPO_REVIEW_MODEL", "ds4/deepseek-v4-flash")
WORKER_RESOURCE = os.environ.get("REVIEW_WORKER_RESOURCE", "mac")
MEM_CAP_MB = int(os.environ.get("REVIEW_MEM_CAP_MB", "0"))
LOGFILE = os.environ.get("REVIEW_LOG")  # trim mirror of output (no heartbeat)


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
    import glob
    import os
    import pathlib
    import shutil
    import signal
    import subprocess
    import tempfile
    import threading
    import time

    home = os.path.expanduser("~")
    tmproot = tempfile.gettempdir()
    # sweep stale leftovers a force-kill couldn't clean (this worker reviews one
    # repo at a time, so an rr-* dir older than an hour is a leftover).
    now = time.time()
    for old in glob.glob(os.path.join(tmproot, "rr-*")):
        try:
            if now - os.path.getmtime(old) > 3600:
                shutil.rmtree(old, ignore_errors=True)
        except OSError:
            pass

    work = tempfile.mkdtemp(prefix="rr-")
    try:
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

        # launchd/systemd give a minimal PATH; add opencode + common node
        # locations for macOS (Homebrew) and Linux so both resolve.
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
        return {"rc": rc, "killed_mem": killed["mem"], "cap_mb": cap,
                "files": files}
    finally:
        shutil.rmtree(work, ignore_errors=True)


# holds the in-flight task ref so a second Ctrl-C can cancel it
_current = {"ref": None}

def _fmt_elapsed(secs):
    m, s = divmod(int(secs), 60)
    h, m = divmod(m, 60)
    return f"{h}h{m:02d}m" if h else f"{m}m{s:02d}s"


class _Tee:
    """Mirror stdout to a logfile, but drop heartbeat frames (carriage-return
    writes with no newline) so the file stays trim - only real event lines land
    there. isatty() delegates to the terminal so the live heartbeat still runs.
    Opened 'w' so each run starts a fresh, bounded file."""
    def __init__(self, real, path):
        self._real = real
        self._log = open(path, "w", buffering=1)

    def write(self, s):
        self._real.write(s)
        if s and "\r" not in s and s.strip():
            self._log.write(s if s.endswith("\n") else s + "\n")

    def flush(self):
        self._real.flush()
        self._log.flush()

    def isatty(self):
        return self._real.isatty()

    def __getattr__(self, name):
        return getattr(self._real, name)


def _heartbeat(name, stopflag):
    """Simple in-place liveness line (interactive only): repo + elapsed. No
    remote-log polling - for the current lens, use watch.sh."""
    start = time.time()
    while not stopflag["done"]:
        line = (f"[{time.strftime('%H:%M:%S')}] {name} - reviewing - "
                f"{_fmt_elapsed(time.time() - start)}")
        # Keep it to ONE line: truncate to just under the pane width so it can
        # never wrap (a wrapped line makes \r rewind only the last row, which is
        # what turns the heartbeat into scrolling new lines). \r returns to col
        # 0, \x1b[K erases the old row, then we write the (short) line.
        try:
            width = os.get_terminal_size(sys.stdout.fileno()).columns
        except OSError:
            width = 80
        sys.stdout.write("\r\x1b[K" + line[:max(1, width - 1)])
        sys.stdout.flush()
        time.sleep(1.0)


def run_once(repo=None):
    """One review: pick (or forced repo) -> bundle -> run on a worker -> file."""
    choice = pick(repo)
    interactive = sys.stdout.isatty()
    if interactive:
        hdr = (f"{choice['name']}  ({choice.get('flavor') or 'auto'} - "
               f"{choice.get('profile') or 'general'})")
        print(f"\n-- reviewing {hdr} " + "-" * max(0, 58 - len(hdr)))
    else:
        print(f"chosen: {choice['name']} (flavor {choice.get('flavor') or 'auto'}, "
              f"profile {choice.get('profile') or 'general'})")

    data = bundle_bytes(choice["name"])
    _current["ref"] = review.options(
        resources={WORKER_RESOURCE: 1}
    ).remote(choice, data, MODEL, MEM_CAP_MB)

    stopflag = {"done": False}
    hb = None
    if interactive:
        hb = threading.Thread(target=_heartbeat, args=(choice["name"], stopflag),
                              daemon=True)
        hb.start()
    try:
        res = ray.get(_current["ref"])
    finally:
        _current["ref"] = None
        stopflag["done"] = True
        if hb:
            hb.join(timeout=2)
            sys.stdout.write("\n")
            sys.stdout.flush()

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
    # mirror our output to a trim logfile (heartbeat frames excluded) so the
    # run can be watched from elsewhere without bloating the file.
    if LOGFILE:
        try:
            sys.stdout = _Tee(sys.stdout, LOGFILE)
        except OSError:
            pass

    ap = argparse.ArgumentParser(description="Distributed repo-review driver.")
    ap.add_argument("repo", nargs="?",
                    help="mode 1: review this specific repo once")
    ap.add_argument("--loop", nargs="?", const=-1, type=int, metavar="N",
                    help="mode 2: cycle continuously (stalest-first); "
                         "optional N caps the number of cycles")
    ap.add_argument("--interval", type=int, default=0,
                    help="seconds to wait between cycles in --loop")
    args = ap.parse_args()

    # PID file so `run.sh --stop` can signal us (any mode).
    pidfile = os.environ.get("REVIEW_PIDFILE")
    if pidfile:
        try:
            pathlib.Path(pidfile).parent.mkdir(parents=True, exist_ok=True)
            pathlib.Path(pidfile).write_text(str(os.getpid()))
            import atexit
            atexit.register(lambda: pathlib.Path(pidfile).unlink(missing_ok=True))
        except Exception:
            pass

    # log_to_driver=False: keep worker stdout ON the worker (reachable via
    # watch.sh / ray logs) instead of streaming it into our terminal, where it
    # would interleave with and scroll away the in-place heartbeat line.
    ray.init(address=os.environ.get("RAY_ADDRESS", "auto"), log_to_driver=False)

    is_loop = args.loop is not None
    stop = {"n": 0}

    # In --loop the first signal finishes the current review then stops; a
    # second signal (or any signal in single-run mode) cancels it now.
    def handle(signum, frame):
        if is_loop and stop["n"] == 0:
            stop["n"] = 1
            print("\n>> stop requested - finishing current review, then "
                  "exiting. (signal again to cancel now.)", flush=True)
            return
        print("\n>> cancelling the running review.", flush=True)
        if _current["ref"] is not None:
            ray.cancel(_current["ref"], force=True)
        raise KeyboardInterrupt

    signal.signal(signal.SIGINT, handle)
    signal.signal(signal.SIGTERM, handle)

    if not is_loop:
        try:
            run_once(args.repo)
        except KeyboardInterrupt:
            print("review cancelled.")
        return

    pid = os.getpid()
    bar = "=" * 64
    print(bar)
    print("LOOP MODE - reviewing repos continuously, stalest-first.")
    print("  each cycle reviews the most-due repo; freshly reviewed ones sink.")
    print(f"  PID {pid}    stop: run.sh --stop  (or Ctrl-C / kill {pid})")
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
            print(f"[cycle {n}] sleeping {args.interval}s (run.sh --stop to stop)",
                  flush=True)
            time.sleep(args.interval)

    print(f"\nloop stopped after {n} cycle(s).", flush=True)


if __name__ == "__main__":
    main()
