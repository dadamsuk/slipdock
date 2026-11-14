"""Spike #3166: what each part of the runner harness has cost since 2026-11-03.

Never merged. Reads the data a pass fetched with the CLI into a directory:

    slipdock cards slipdock --all --json > DIR/cards.json
    slipdock cards <sub-board> --all --json > DIR/sub/<sub-board>.json   (each epic's)
    slipdock jobs --card <id> --json > DIR/jobs/<id>.json               (each card touched since)

then: python3 -I spike/3166/harness_cost.py DIR

A card goes to every part whose pattern its title matches (a card can be two
parts). Job-hours are finished_at - started_at, per job kind.
"""

import collections
import glob
import json
import re
import sys
from datetime import datetime

SINCE = "2026-11-03"

# Title patterns, case-insensitive. Order is only for the report.
PARTS = [
    ("daemon", r"daemon|slipdock-runner|\bmachine|runner (unit|script|scenario|setup)|setup.token|skills? drift|cli drift|enrol"),
    ("lanes", r"\blanes?\b|lane_mode|overlap|worktree|\bpaths\b"),
    ("merge queue", r"\bmerg|rebase|conflict"),
    ("releases", r"release|deploy|batched|hotfix|shipped|ship by|ledger"),
    ("verify", r"verif|reject|evidence|bar gate|mutant|mutation|accept|spot-check"),
    ("audit", r"\baudit"),
    ("health", r"health|stuck|detector|overseer|monitor|\blease|timeout|timed out|gave up|requeue|orphan"),
    ("generators", r"nightly|recurring|triage|finding|gardener|sweep|reconcile|daily|scheduled"),
    ("jobs & pools", r"\bjobs?\b|\bpool|claim|\bqueue|parked|handoff|runner|\bloop\b|epic's job"),
]
RX = [(n, re.compile(p, re.I)) for n, p in PARTS]


def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None


def hours(j):
    a, b = ts(j.get("started_at") or j.get("claimed_at")), ts(j.get("finished_at"))
    return (b - a).total_seconds() / 3600 if a and b and b > a else 0.0


def load(d):
    cards = json.load(open(f"{d}/cards.json"))["cards"]
    for f in glob.glob(f"{d}/sub/*.json"):
        for c in json.load(open(f))["cards"]:
            c["_epic"] = int(f.rsplit("/", 1)[1][:-5])
            cards.append(c)
    jobs = {}
    for f in glob.glob(f"{d}/jobs/*.json"):
        try:
            for j in json.load(open(f))["jobs"]:
                jobs[j["id"]] = j
        except (ValueError, KeyError):
            pass
    return cards, list(jobs.values())


def parts_of(c):
    t = c["title"]
    return [n for n, rx in RX if rx.search(t)]


def main(d):
    cards, jobs = load(d)
    new = [c for c in cards if c["inserted_at"] >= SINCE]
    by_card = collections.defaultdict(list)
    for j in jobs:
        if (j.get("queued_at") or "") >= SINCE:
            by_card[j["card_id"]].append(j)
    out = {"since": SINCE, "cards_new": len(new), "jobs": len(sum(by_card.values(), []))}

    # Job-hours by kind, whole board.
    kind_h = collections.Counter()
    kind_n = collections.Counter()
    for js in by_card.values():
        for j in js:
            k = "audit" if j.get("audit") else j["kind"]
            kind_h[k] += hours(j)
            kind_n[k] += 1
    out["job_hours_by_kind"] = {k: [kind_n[k], round(kind_h[k], 1)] for k in kind_n}

    # Per part: cards, the job-hours spent building those cards.
    harness = set()
    rows = {}
    for name, _ in RX:
        cs = [c for c in new if name in parts_of(c)]
        harness |= {c["id"] for c in cs}
        h = collections.Counter()
        for c in cs:
            for j in by_card.get(c["id"], []):
                h["audit" if j.get("audit") else j["kind"]] += hours(j)
        rows[name] = {
            "cards": len(cs),
            "job_hours": {k: round(v, 1) for k, v in h.items()},
            "total_h": round(sum(h.values()), 1),
            "examples": [f"#{c['id']} {c['title'][:70]}" for c in cs[:6]],
        }
    out["parts"] = rows
    hc = [c for c in new if c["id"] in harness]
    out["harness_cards"] = len(hc)
    out["harness_job_hours"] = round(sum(hours(j) for c in hc for j in by_card.get(c["id"], [])), 1)
    out["all_job_hours"] = round(sum(kind_h.values()), 1)

    # Origins: cards the harness filed by itself.
    out["origin"] = collections.Counter(str(c.get("origin")) for c in new)

    # Verify: how often it rejects, and on docs cards.
    def verdicts(cs):
        n = rej = 0
        h = 0.0
        for c in cs:
            vs = [j for j in by_card.get(c["id"], []) if j["kind"] == "verify" and not j.get("audit")]
            n += len(vs)
            h += sum(hours(j) for j in vs)
            rej += max(0, len([j for j in by_card.get(c["id"], []) if j["kind"] == "claude"]) - 1) if vs else 0
        return {"cards": len(cs), "verify_jobs": n, "verify_h": round(h, 1), "rebuilds_after_first": rej}

    prof = lambda c: c.get("profile")
    out["verify_by_profile"] = {
        p: verdicts([c for c in new if prof(c) == p]) for p in sorted({str(prof(c)) for c in new}, key=str)
        for p in [None if p == "None" else p]
    }
    audits = [j for js in by_card.values() for j in js if j.get("audit")]
    out["audit"] = {"jobs": len(audits), "hours": round(sum(hours(j) for j in audits), 1),
                    "statuses": collections.Counter(j["status"] for j in audits)}
    merges = [j for js in by_card.values() for j in js if j["kind"] == "merge"]
    out["merge"] = {"jobs": len(merges), "hours": round(sum(hours(j) for j in merges), 1),
                    "statuses": collections.Counter(j["status"] for j in merges),
                    "cards": len({j["card_id"] for j in merges})}
    allj = [j for js in by_card.values() for j in js]
    out["job_status"] = collections.Counter(j["status"] for j in allj)
    out["recovery"] = collections.Counter(str(j.get("recovery")) for j in allj)
    json.dump(out, sys.stdout, indent=1, default=str)


if __name__ == "__main__":
    main(sys.argv[1])
