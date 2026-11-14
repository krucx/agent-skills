#!/usr/bin/env python3
"""Report what Claude Code transcripts cost: turns, tokens, peak context, duration, tool calls.

Usage (run with -I; standard library only):
  usage.py [--turns N] <transcript.jsonl>...
  usage.py --run <runId> [--repo-dir DIR] [--projects-dir DIR] [--plans-dir DIR]

A turn is one assistant transcript line that carries token usage (the convention of the Nov 2026
baseline in Documentation/review-pass-1/orchestrator-pass-plan.md). Peak context is the largest
input of any turn (input + cache-read + cache-write tokens). Tool calls are counted once per
tool_use id: plan.sh, cycle.sh, watch.sh, other Bash, other tools; "text" counts turns that
called no tool. "hand plan writes" counts Bash calls that pipe jq into `plan.sh write`, which
the orchestrator should never need.

--turns N counts only the first N turns of each transcript (to isolate the orchestrator portion
of a session that went on to other work).

--run finds the run's plan (<plans-dir>/<repo>.json when its runId matches, else
<plans-dir>/history/*-<runId>.json), the orchestrator transcript (the transcript in the repo's
own project folder with the most orchestrator script calls inside the run's time window) and
each worker transcript (project folders whose name ends with an item's branch, '/' and '.'
written as '-'). It prints one table and the orchestrator as a percentage of worker spend.
"""
import argparse
import glob
import json
import os
import re
import sys
from datetime import datetime

COLS = ("turns", "output", "cache_write", "cache_read", "peak", "secs",
        "plan", "cycle", "watch", "bash", "other", "text", "hand")
HEAD = ("turns", "output", "cache-write", "cache-read", "peak ctx", "duration",
        "plan.sh", "cycle.sh", "watch.sh", "bash", "other", "text", "hand writes")


def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def measure(path, max_turns=None):
    """Totals for one transcript, plus its first and last turn times."""
    t = dict.fromkeys(COLS, 0)
    t["first"] = t["last"] = None
    seen = set()
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            msg = d.get("message") or {}
            u = msg.get("usage")
            if d.get("type") != "assistant" or not u:
                continue
            if max_turns is not None and t["turns"] >= max_turns:
                break
            t["turns"] += 1
            t["output"] += u.get("output_tokens", 0)
            t["cache_write"] += u.get("cache_creation_input_tokens", 0)
            t["cache_read"] += u.get("cache_read_input_tokens", 0)
            t["peak"] = max(t["peak"], u.get("input_tokens", 0)
                            + u.get("cache_read_input_tokens", 0)
                            + u.get("cache_creation_input_tokens", 0))
            when = d.get("timestamp")
            if when:
                t["first"] = t["first"] or ts(when)
                t["last"] = ts(when)
            blocks = msg.get("content")
            calls = [b for b in blocks if b.get("type") == "tool_use"] if isinstance(blocks, list) else []
            if not calls:
                t["text"] += 1
            for b in calls:
                if b.get("id") in seen:
                    continue
                seen.add(b.get("id"))
                if b.get("name") != "Bash":
                    t["other"] += 1
                    continue
                cmd = (b.get("input") or {}).get("command", "")
                kinds = [k for k in ("plan", "cycle", "watch") if k + ".sh" in cmd]
                for k in kinds:
                    t[k] += 1
                if not kinds:
                    t["bash"] += 1
                if re.search(r"jq\b.*\|\s*\S*plan\.sh\s+write", cmd, re.S):
                    t["hand"] += 1
    if t["first"] is not None:
        t["secs"] = int(t["last"] - t["first"])
    return t


def total(rows):
    out = dict.fromkeys(COLS, 0)
    for r in rows:
        for c in COLS:
            out[c] = max(out[c], r[c]) if c == "peak" else out[c] + r[c]
    return out


def fmt_dur(secs):
    return "%dh%02dm" % (secs // 3600, secs % 3600 // 60) if secs >= 3600 else "%dm%02ds" % (secs // 60, secs % 60)


def fmt_tok(n):
    return "%.1fM" % (n / 1e6) if n >= 1e6 else "%dK" % round(n / 1e3) if n >= 1e3 else str(n)


def cells(t):
    return [str(t["turns"]), fmt_tok(t["output"]), fmt_tok(t["cache_write"]), fmt_tok(t["cache_read"]),
            fmt_tok(t["peak"]), fmt_dur(t["secs"])] + [str(t[c]) for c in COLS[6:]]


def table(rows):
    """rows: [(label, totals)] printed as an aligned table."""
    grid = [["transcript"] + list(HEAD)] + [[label] + cells(t) for label, t in rows]
    widths = [max(len(r[i]) for r in grid) for i in range(len(grid[0]))]
    for n, r in enumerate(grid):
        print("  ".join(c.ljust(widths[0]) if i == 0 else c.rjust(widths[i]) for i, c in enumerate(r)))
        if n == 0:
            print("  ".join("-" * w for w in widths))


def folder_name(path):
    return re.sub(r"[/.]", "-", os.path.abspath(path))


def find_plan(plans_dir, run_id):
    cands = glob.glob(os.path.join(plans_dir, "*.json")) + glob.glob(os.path.join(plans_dir, "history", "*.json"))
    for p in sorted(cands):
        try:
            with open(p, encoding="utf-8") as fh:
                if json.load(fh).get("runId") == run_id:
                    return p
        except (ValueError, OSError):
            continue
    sys.exit("usage.py: no plan with runId %s under %s" % (run_id, plans_dir))


def run_mode(args):
    plan_path = find_plan(args.plans_dir, args.run)
    with open(plan_path, encoding="utf-8") as fh:
        plan = json.load(fh)
    branches = [i["branch"] for i in plan.get("items", []) if i.get("branch")]
    workers = []
    for b in branches:
        suffix = "-" + re.sub(r"[/.]", "-", b)
        for folder in sorted(glob.glob(os.path.join(args.projects_dir, "*"))):
            if folder.endswith(suffix):
                for f in sorted(glob.glob(os.path.join(folder, "*.jsonl"))):
                    workers.append((b, f))
    worker_rows = [(b, measure(f)) for b, f in workers]
    worker_rows = [(b, t) for b, t in worker_rows if t["turns"]]
    lo = min([t["first"] for _, t in worker_rows] or [0]) - 3600
    hi = max([t["last"] for _, t in worker_rows] or [1e18]) + 3600
    own = os.path.join(args.projects_dir, folder_name(args.repo_dir))
    best = None
    for f in glob.glob(os.path.join(own, "*.jsonl")):
        t = measure(f)
        if not t["turns"] or t["last"] < lo or t["first"] > hi:
            continue
        score = t["plan"] + t["cycle"] + t["watch"]
        if best is None or score > best[0]:
            best = (score, f, t)
    if best is None or best[0] == 0:
        sys.exit("usage.py: no orchestrator transcript in %s overlapping run %s" % (own, args.run))
    orch = measure(best[1], args.turns)
    print("run %s (%s), plan %s\n" % (args.run, plan.get("repo"), plan_path))
    wtot = total([t for _, t in worker_rows])
    table([("orchestrator " + os.path.basename(best[1])[:8], orch)]
          + [("worker " + b, t) for b, t in worker_rows]
          + [("workers total (%d)" % len(worker_rows), wtot)])
    print()
    for label, c in (("output", "output"), ("cache-read", "cache_read")):
        pct = 100.0 * orch[c] / wtot[c] if wtot[c] else float("nan")
        print("orchestrator %s: %s of %s worker %s = %.1f%%" % (label, fmt_tok(orch[c]), fmt_tok(wtot[c]), label, pct))
    print("model-written plan writes (jq ... | plan.sh write): %d" % orch["hand"])


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("transcripts", nargs="*")
    ap.add_argument("--run")
    ap.add_argument("--turns", type=int, help="count only the first N turns of each transcript")
    ap.add_argument("--repo-dir", default=os.getcwd(), help="the repo the orchestrator ran in")
    ap.add_argument("--projects-dir", default=os.path.expanduser("~/.claude/projects"))
    ap.add_argument("--plans-dir", default=os.path.expanduser("~/.agents/orchestrator"))
    args = ap.parse_args()
    if args.run:
        run_mode(args)
    elif args.transcripts:
        rows = [(os.path.basename(p)[:36], measure(p, args.turns)) for p in args.transcripts]
        table(rows)
    else:
        ap.error("give transcript files or --run <runId>")


if __name__ == "__main__":
    main()
