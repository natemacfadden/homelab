#!/usr/bin/env python3
#
# live utilization dashboard for the whole fleet, nvtop-style. Two views,
# toggled with v: line graphs of CPU and RAM, and of each GPU's utilization and
# memory, per box; or bars, one per CPU / RAM / disk / GPU. Both show load, disk
# usage, disk I/O, GPU temp and power alongside.
#
#   ./lab top                  live graphs, sampling every 2s
#   ./lab top --bars           start in the bar view
#   ./lab top -n 5             sample every 5s
#   ./lab top --once           print one text snapshot and exit
#
# keys: v graphs <-> bars, l solid lines <-> braille dots (2x the detail),
# + / - widen / narrow the graphs' time window (up to 6h of history, kept only
# while it runs and recorded in either view - for history from before you
# opened it, that's Prometheus on the head), s save the screen with its colors
# to ~/.cache/labtop/screen.ansi (cat it, or hand it to Claude), q quits.
#
# Each number in a box's header is colored like its line in the graph. Needs
# only python3 here and plain SSH to the boxes, and doesn't depend on the head
# being up. Hosts are head01 plus the WORKERS list in scripts/deploy.sh; this
# box is read locally. scripts/top_probe.sh is what runs on each box.
#
# GPUs: NVIDIA via nvidia-smi, AMD via sysfs (memory is VRAM + GTT, so the
# Strix Halo's unified memory counts; a sleeping GPU reads as 0%). Apple GPUs
# need sudo powermetrics, so the Mac graphs CPU and RAM only.
#
# env:
#   HOSTS      space-separated override of the host list
#   HEAD_HOST  the head's name (default head01)
#
import curses
import os
import re
import socket
import subprocess
import sys
import threading
import time
from collections import deque

HERE = os.path.dirname(os.path.abspath(__file__))
PROBE = os.path.join(HERE, "top_probe.sh")
KEEP_SECONDS = 6 * 3600
ZOOMS = (1, 2, 5, 10, 30, 60, 150)   # samples per graph column
LOCAL = socket.gethostname().split(".")[0]
# one persistent SSH connection per box, so a sample costs ~1s, not a handshake
SSH = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=3",
       "-o", "ControlMaster=auto", "-o", "ControlPersist=60",
       "-o", "ControlPath=" + os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"),
                                           "labtop-%r@%h:%p")]


def hosts():
    if os.environ.get("HOSTS"):
        return os.environ["HOSTS"].split()
    out = [os.environ.get("HEAD_HOST", "head01")]
    with open(os.path.join(HERE, "deploy.sh")) as f:
        block = re.search(r"^WORKERS=\((.*?)^\)", f.read(), re.S | re.M).group(1)
    for line in block.splitlines():
        m = re.match(r'\s*"\s*([^\s|]+)', line)   # host column; skips # rows
        if m:
            out.append(m.group(1))
    return out


def short(host):
    return host.split("@")[-1]


def num(s):
    try:
        return float(s)
    except ValueError:
        return None


def parse(text):
    d = {"gpus": [], "disks": [], "io": None}
    for line in text.splitlines():
        k, _, v = line.partition("=")
        if k == "cpu":
            d["cpu"] = num(v)
        elif k in ("load", "ncpu"):
            d[k] = v
        elif k == "mem":
            d["mem"] = tuple(int(x) for x in v.split())            # MiB
        elif k == "io":
            d["io"] = tuple(int(x) for x in v.split())             # KiB/s
        elif k == "disk":
            m, u, t = (x.strip() for x in v.split(","))
            d["disks"].append((m, int(u), int(t)))                 # KiB
        elif k == "gpu":
            name, util, used, total, temp, pw = (x.strip() for x in v.split(","))
            d["gpus"].append({"name": name, "util": num(util), "asleep": util == "sleep",
                              "used": num(used) or 0, "total": num(total) or 0,
                              "temp": num(temp), "pw": num(pw)})
    return d if d.get("cpu") is not None and "mem" in d else None


def probe(host):
    local = short(host) == LOCAL
    with open(PROBE) as f:
        try:
            r = subprocess.run(["bash", PROBE] if local else SSH + [host, "bash -s"],
                               stdin=subprocess.DEVNULL if local else f,
                               capture_output=True, text=True, timeout=15)
        except subprocess.TimeoutExpired:
            return None
    return parse(r.stdout)


def series(d):
    """A sample's graphed values, all in percent: (left graph, right graph)."""
    left = {"cpu": d["cpu"], "ram": 100 * d["mem"][0] / max(d["mem"][1], 1)}
    right = {}
    for i, g in enumerate(d["gpus"]):
        right[f"g{i}"] = 0 if g["asleep"] else g["util"]
        right[f"m{i}"] = 100 * g["used"] / g["total"] if g["total"] else None
    return left, right


class Fleet:
    """One poller thread per box; tick() appends everyone's latest to history."""

    def __init__(self, hosts, interval):
        self.hosts, self.interval = hosts, interval
        self.stale = max(3 * interval, 10)
        self.latest = {h: (0.0, None) for h in hosts}
        self.hist = {h: deque(maxlen=int(KEEP_SECONDS / interval)) for h in hosts}
        for h in hosts:
            threading.Thread(target=self.poll, args=(h,), daemon=True).start()

    def poll(self, host):
        while True:
            t0 = time.time()
            d = probe(host)
            if d:
                self.latest[host] = (time.time(), d)
            time.sleep(max(0.2, self.interval - (time.time() - t0)) if d else 5)

    def current(self, host):
        t, d = self.latest[host]
        return d if time.time() - t < self.stale else None

    def tick(self):
        for h in self.hosts:
            d = self.current(h)
            self.hist[h].append(series(d) if d else None)


# --- formatting -------------------------------------------------------------

def human(kib):
    v, units = float(kib), "KMGT"
    i = 0
    while v >= 1024 and i < 3:
        v /= 1024
        i += 1
    return f"{v:.1f}{units[i]}" if v < 10 else f"{v:.0f}{units[i]}"


def gib(mib):
    return f"{mib / 1024:.1f}"


def pct(v):
    return "-" if v is None else f"{v:.0f}%"


# color names; curses pairs are set up in run()
CYAN, MAGENTA, GREEN, YELLOW, BLUE, RED, WHITE = range(1, 8)
# color says which metric, the same on every box: each GPU has its own graph
SERIES_COLOR = {"cpu": CYAN, "ram": MAGENTA}
for _i in range(8):
    SERIES_COLOR[f"g{_i}"], SERIES_COLOR[f"m{_i}"] = GREEN, YELLOW


def info(host, d):
    """Header lines for a box, as lists of (text, color, bold) segments."""
    mu, mt = d["mem"]
    l1 = [(f"{short(host):<15}", 0, True), ("CPU ", 0, False),
          (f"{d['cpu']:3.0f}%", CYAN, True), (f"  load {d['load']}/{d['ncpu']}    RAM ", 0, False),
          (f"{gib(mu)}/{gib(mt)} GiB", MAGENTA, True)]
    if d["io"]:
        l1.append((f"    I/O read {human(d['io'][0])}/s  write {human(d['io'][1])}/s", 0, False))
    l2 = [(" " * 15 + "disk", 0, False)]
    for m, u, t in d["disks"]:
        p = 100 * u / max(t, 1)
        l2 += [(f"  {m} ", 0, False),
               (f"{p:.0f}%", RED if p >= 90 else YELLOW if p >= 80 else 0, p >= 80),
               (f" {human(u)}/{human(t)}", 0, False)]
    lines = [l1, l2]
    if d["gpus"]:
        l3 = [(" " * 15 + "gpu ", 0, False)]
        for i, g in enumerate(d["gpus"]):
            extra = "".join(f" {v:.0f}{u}" for v, u in ((g["temp"], "C"), (g["pw"], "W"))
                            if v is not None)
            l3 += [(f" {g['name']} ", 0, True),
                   ("sleep" if g["asleep"] else pct(g["util"]), SERIES_COLOR[f"g{i}"], True),
                   (" ", 0, False),
                   (f"{gib(g['used'])}/{gib(g['total'])} GiB", SERIES_COLOR[f"m{i}"], True),
                   (extra + "  ", 0, False)]
        lines.append(l3)
    return lines


def once():
    hs, res = hosts(), {}
    threads = [threading.Thread(target=lambda h=h: res.__setitem__(h, probe(h))) for h in hs]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    for h in hs:
        if not res.get(h):
            print(f"{short(h):<15}offline")
            continue
        for line in info(h, res[h]):
            print("".join(seg[0] for seg in line))
        print()


# --- drawing ----------------------------------------------------------------

# braille dot bit for (row 0-3, column 0-1) within a cell
DOTS = ((0x01, 0x08), (0x02, 0x10), (0x04, 0x20), (0x40, 0x80))


# everything drawn this frame, (row, col) -> (char, attr), for the s key: curses
# can't read wide chars like braille back off the screen
SHADOW = {}
SNAP = os.path.expanduser("~/.cache/labtop/screen.ansi")
ANSI_FG = {CYAN: 36, MAGENTA: 35, GREEN: 32, YELLOW: 33, BLUE: 34, RED: 31, WHITE: 37}


def put(scr, y, x, text, attr=0):
    for i, ch in enumerate(text):
        SHADOW[(y, x + i)] = (ch, attr)
    try:
        scr.addstr(y, x, text, attr)
    except curses.error:   # writing the bottom-right cell, or off-screen
        pass


def save_screen(rows, cols):
    """Write the current frame as ANSI-colored text; returns the path."""
    out = []
    for r in range(rows):
        line, cur = "", None
        for c in range(cols):
            ch, attr = SHADOW.get((r, c), (" ", 0))
            if attr != cur:
                codes = ["0"] + (["1"] if attr & curses.A_BOLD else []) \
                    + (["2"] if attr & curses.A_DIM else [])
                fg = ANSI_FG.get(curses.pair_number(attr))
                line += f"\033[{';'.join(codes + ([str(fg)] if fg else []))}m"
                cur = attr
            line += ch
        out.append(line.rstrip() + "\033[0m")
    while out and out[-1] == "\033[0m":
        out.pop()
    os.makedirs(os.path.dirname(SNAP), exist_ok=True)
    with open(SNAP, "w") as f:
        f.write("\n".join(out) + "\n")
    return SNAP


def put_line(scr, y, segments, width):
    """segments are (text, color, style); style is True for bold, "dim", or falsy"""
    x = 0
    for text, color, style in segments:
        if x >= width:
            break
        attr = curses.A_DIM if style == "dim" else curses.A_BOLD if style else 0
        put(scr, y, x, text[:width - x], curses.color_pair(color) | attr)
        x += len(text)


def span_label(seconds):
    if seconds < 120:
        return f"{seconds:.0f}s"
    if seconds < 7200:
        return f"{seconds / 60:.0f}m"
    return f"{seconds / 3600:.1f}h"


# line pieces by how the line turns in a column: (going up, going down) gives
# (char where it leaves the old row, char where it reaches the new one)
TURN = {"up": ("╯", "╭"), "down": ("╮", "╰")}


def graph(scr, y, x, h, w, legend, hist, side, ui, interval):
    """Box at (y, x) of size h x w with a line for every series on one side:
    box-drawing characters like nvtop (ui.style "lines", one value per cell),
    or braille ("dots", 2x4 per cell - finer, but it reads as dots).
    legend is [(label, key)], drawn in the top border in each line's color; a
    None key is a plain title. The legend's keys are the series drawn."""
    if h < 3 or w < 8:
        return
    dim = curses.color_pair(0) | curses.A_DIM
    put(scr, y, x, "┌" + "─" * (w - 2) + "┐", dim)
    for r in range(1, h - 1):
        put(scr, y + r, x, "│", dim)
        put(scr, y + r, x + w - 1, "│", dim)
    put(scr, y + h - 1, x, "└" + "─" * (w - 2) + "┘", dim)
    lx = x + 2
    for label, key in legend:
        parts = (((f" {label} ", curses.color_pair(0) | curses.A_BOLD),) if key is None else
                 ((" ━━ ", curses.color_pair(SERIES_COLOR[key]) | curses.A_BOLD),
                  (label + " ", curses.color_pair(0))))
        for text, attr in parts:
            put(scr, y, lx, text[:max(0, x + w - 8 - lx)], attr)
            lx += len(text)
    cw, ch = w - 2, h - 2
    zoom = ui.zoom
    dots = ui.style == "dots"
    nx, ny = (cw * 2, ch * 4) if dots else (cw, ch)
    put(scr, y + h - 1, x + 2, f" -{span_label(nx * zoom * interval)} ", dim)
    put(scr, y + h - 1, x + w - 6, " now ", dim)
    put(scr, y, x + w - 7, " 100% ", dim)   # in the border, so no line covers it

    samples = list(hist)[-nx * zoom:]
    # right-align: the last column is the newest bucket of `zoom` samples
    cols = []
    for b in range(nx):
        end = len(samples) - (nx - 1 - b) * zoom
        cols.append(samples[max(0, end - zoom):max(0, end)])
    keys = [k for _, k in legend if k]

    if not dots:
        cells = {}   # (row, col) -> (char, color); a later series draws over
        for key in keys:
            color, prev = SERIES_COLOR[key], None
            for xi, chunk in enumerate(cols):
                vals = [s[side][key] for s in chunk if s and s[side].get(key) is not None]
                if not vals:
                    prev = None
                    continue
                v = min(100, max(0, sum(vals) / len(vals)))
                r = round((100 - v) / 100 * (ny - 1))
                if prev is None or prev == r:
                    cells[(r, xi)] = ("─", color)
                else:
                    leave, reach = TURN["up" if r < prev else "down"]
                    cells[(prev, xi)] = (leave, color)
                    cells[(r, xi)] = (reach, color)
                    for rr in range(min(prev, r) + 1, max(prev, r)):
                        cells[(rr, xi)] = ("│", color)
                prev = r
        for (r, c), (char, color) in cells.items():
            put(scr, y + 1 + r, x + 1 + c, char, curses.color_pair(color) | curses.A_BOLD)
        return

    # (row, col) -> {key: bits}. A cell has one color, so where series share a
    # cell only the topmost (last drawn) one's dots show, as with lines - mixing
    # them would paint the other's dots in the wrong color
    cells = {}
    for key in keys:
        prev = None
        for xi, chunk in enumerate(cols):
            vals = [s[side][key] for s in chunk if s and s[side].get(key) is not None]
            if not vals:
                prev = None   # a gap: box offline, or no data yet
                continue
            v = min(100, max(0, sum(vals) / len(vals)))
            yi = round((100 - v) / 100 * (ny - 1))
            lo, hi = (yi, yi) if prev is None else (min(prev, yi), max(prev, yi))
            for yy in range(lo, hi + 1):
                c = cells.setdefault((yy // 4, xi // 2), {})
                c[key] = c.get(key, 0) | DOTS[yy % 4][xi % 2]
            prev = yi
    for (r, c), by_key in cells.items():
        key = list(by_key)[-1]   # dicts keep insertion order; keys draw in order
        put(scr, y + 1 + r, x + 1 + c, chr(0x2800 | by_key[key]),
            curses.color_pair(SERIES_COLOR[key]))


BAR = 20


def bar(p):
    """A [████····] gauge as segments, green / yellow / red by level."""
    if p is None:
        return [("[" + " " * BAR + "]", 0, False)]
    n = round(min(100, max(0, p)) * BAR / 100)
    color = RED if p >= 80 else YELLOW if p >= 50 else GREEN
    return [("[", 0, False), ("█" * n, color, False), ("·" * (BAR - n), 0, "dim"),
            ("]", 0, False)]


def bar_lines(host, d):
    """The bar view of one box, as put_line segment lists."""
    pad = " " * 15
    mu, mt = d["mem"]
    out = [[(f"{short(host):<15}", 0, True), ("CPU ", 0, False)] + bar(d["cpu"])
           + [(f" {d['cpu']:4.0f}%  load {d['load']}/{d['ncpu']}", 0, False)],
           [(pad + "RAM ", 0, False)] + bar(100 * mu / max(mt, 1))
           + [(f" {100 * mu / max(mt, 1):4.0f}%  {gib(mu)}/{gib(mt)} GiB", 0, False)]]
    for m, u, t in d["disks"]:
        p = 100 * u / max(t, 1)
        out.append([(pad + "DSK ", 0, False)] + bar(p)
                   + [(f" {p:4.0f}%  {human(u)}/{human(t)}  ", 0, False), (m, 0, "dim")])
    if d["io"]:
        out.append([(pad + f"I/O read {human(d['io'][0])}/s  write {human(d['io'][1])}/s",
                     0, False)])
    for g in d["gpus"]:
        mp = 100 * g["used"] / g["total"] if g["total"] else None
        extra = "".join(f"  {v:.0f}{u}" for v, u in ((g["temp"], "C"), (g["pw"], "W"))
                        if v is not None)
        out.append([(f"  {g['name'][:12]:<13}", CYAN, True), ("GPU ", 0, False)]
                   + bar(0 if g["asleep"] else g["util"])
                   + [(" sleep" if g["asleep"] else f" {pct(g['util']):>5}", 0, False),
                      ("   VRAM ", 0, False)] + bar(mp)
                   + [(f" {gib(g['used'])}/{gib(g['total'])} GiB{extra}", 0, False)])
    return out


def draw_bars(scr, fleet, on, rows, cols):
    y = 1
    for h in on:
        for line in bar_lines(h, fleet.current(h)):
            put_line(scr, y, line, cols)
            y += 1
        y += 1


CPU_LEGEND = [("cpu", "cpu"), ("ram", "ram")]


class UI:
    view = "graphs"   # or "bars"
    style = "lines"   # or "dots"
    zoom_i = 0
    flash, flash_until = "", 0.0

    @property
    def zoom(self):
        return ZOOMS[self.zoom_i]


def draw(scr, fleet, ui):
    view = ui.view
    scr.erase()
    SHADOW.clear()
    rows, cols = scr.getmaxyx()
    on = [h for h in fleet.hosts if fleet.current(h)]
    off = [short(h) for h in fleet.hosts if not fleet.current(h)]
    keys = f"{view} view, v to switch" + (f"   l {ui.style}   +/- time window"
                                         if view == "graphs" else "")
    put_line(scr, 0, [("lab top", 0, True),
                      (f"   sample {fleet.interval:g}s   {keys}   s save   q quit", 0, False)]
             + ([("   offline: ", 0, False), (" ".join(off), RED, True)] if off else [])
             + ([("   " + ui.flash, GREEN, True)] if time.time() < ui.flash_until else []),
             cols)
    if not on:
        put(scr, 2, 0, "waiting for the first samples..." if not any(fleet.hist.values())
            else "no box is answering")
        scr.refresh()
        return
    if view == "bars":
        draw_bars(scr, fleet, on, rows, cols)
        scr.refresh()
        return
    per = (rows - 1) // len(on)
    y = 1
    for h in on:
        d = fleet.current(h)
        lines = info(h, d)
        for i, line in enumerate(lines):
            put_line(scr, y + i, line, cols)
        gh = per - len(lines)
        if d["gpus"]:
            lw = cols // 2
            graph(scr, y + len(lines), 0, gh, lw, CPU_LEGEND, fleet.hist[h], 0, ui, fleet.interval)
            # one graph per GPU, stacked; the last takes any leftover rows
            n = len(d["gpus"])
            gy = y + len(lines)
            for i, g in enumerate(d["gpus"]):
                hh = gh // n if i < n - 1 else gh - (gh // n) * (n - 1)
                graph(scr, gy, lw, hh, cols - lw,
                      [(g["name"], None), ("util", f"g{i}"), ("mem", f"m{i}")],
                      fleet.hist[h], 1, ui, fleet.interval)
                gy += hh
        else:
            graph(scr, y + len(lines), 0, gh, cols, CPU_LEGEND, fleet.hist[h], 0, ui,
                  fleet.interval)
        y += per
    scr.refresh()


def run(scr, interval, view):
    curses.curs_set(0)
    curses.use_default_colors()
    for pair, color in ((CYAN, curses.COLOR_CYAN), (MAGENTA, curses.COLOR_MAGENTA),
                        (GREEN, curses.COLOR_GREEN), (YELLOW, curses.COLOR_YELLOW),
                        (BLUE, curses.COLOR_BLUE), (RED, curses.COLOR_RED),
                        (WHITE, curses.COLOR_WHITE)):
        curses.init_pair(pair, color, -1)
    scr.timeout(200)
    fleet = Fleet(hosts(), interval)
    ui = UI()
    ui.view = view
    next_tick = time.time() + min(interval, 2)   # let the first probes land
    draw(scr, fleet, ui)
    while True:
        if time.time() >= next_tick:
            fleet.tick()
            next_tick += interval
            draw(scr, fleet, ui)
        k = scr.getch()
        if k in (ord("q"), ord("Q"), 27):
            return
        if k in (ord("v"), ord("V"), ord("\t")):
            ui.view = "bars" if ui.view == "graphs" else "graphs"
        elif k in (ord("l"), ord("L")):
            ui.style = "dots" if ui.style == "lines" else "lines"
        elif k in (ord("+"), ord("=")) and ui.zoom_i < len(ZOOMS) - 1:
            ui.zoom_i += 1
        elif k in (ord("-"), ord("_")) and ui.zoom_i > 0:
            ui.zoom_i -= 1
        elif k in (ord("s"), ord("S")):
            ui.flash = "saved " + save_screen(*scr.getmaxyx()).replace(os.path.expanduser("~"), "~")
            ui.flash_until = time.time() + 4
        elif k != curses.KEY_RESIZE:
            continue
        draw(scr, fleet, ui)


def main(argv):
    interval, view, args = 2.0, "graphs", list(argv)
    while args:
        a = args.pop(0)
        if a == "--once":
            return once()
        if a == "--bars":
            view = "bars"
        elif a == "-n" and args:
            interval = max(1.0, float(args.pop(0)))
        else:
            sys.exit(f"unknown option '{a}' (see ./lab top --help)")
    if not sys.stdout.isatty():
        return once()
    try:
        curses.wrapper(run, interval, view)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main(sys.argv[1:])
