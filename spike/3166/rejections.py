"""Spike #3166: why verify rejected, since 2026-11-03. Same DIR as harness_cost.py.

Each rejection's verdict text (the job's output, its first 700 characters) is
put in the first bucket whose pattern it matches, in this order.
"""
import collections, glob, json, re, sys

d = sys.argv[1]
J = {}
for f in glob.glob(f"{d}/jobs/*.json"):
    for j in json.load(open(f))["jobs"]:
        J[j["id"]] = j
cards = {c["id"]: c for c in json.load(open(f"{d}/cards.json"))["cards"]}
for f in glob.glob(f"{d}/sub/*.json"):
    for c in json.load(open(f))["cards"]:
        cards[c["id"]] = c

BUCKETS = [
    ("tests: surviving mutants / untested line (TEST-3)", r"mutant|TEST-3|no test|not covered|untested|held by no test|aren.t covered|never tested|doesn.t catch|don.t catch|tests? (that )?(is|are) supposed"),
    ("docs: a place not updated (SPEC-10)", r"SPEC-10|docs?\b.*(not|n.t) (updated|describe)|manual|api guide|describe the old|docs now|old wording"),
    ("paperwork: Handbook line / evidence / findings", r"Handbook:|Handbook line|evidence|Findings"),
    ("process: depends on unmerged work / wrong commit", r"hasn.t landed|not merged|isn.t on .main|still open|unmerged"),
    ("defect: behaviour wrong or bar unmet", r"regression|crash|does nothing|doesn.t work|off-by-one|bar \d+ (isn.t met|fails)|bar item \d+|isn.t met|not met|fails on bar|wrong"),
]
RX = [(n, re.compile(p, re.I)) for n, p in BUCKETS]
since = "2026-11-03"
rej = [j for j in J.values() if j["kind"] == "verify" and not j["audit"] and "reject" in (j["step"] or "") and j["queued_at"] >= since]
acc = [j for j in J.values() if j["kind"] == "verify" and not j["audit"] and "accept" in (j["step"] or "") and j["queued_at"] >= since]
out = collections.Counter()
by_prof = collections.defaultdict(collections.Counter)
for j in rej:
    t = re.sub(r"slipdock-runner:[^\n]*\n", "", j["output"] or "")[:700]
    b = next((n for n, rx in RX if rx.search(t)), "other")
    out[b] += 1
    by_prof[str((cards.get(j["card_id"]) or {}).get("profile"))][b] += 1
acc_prof = collections.Counter(str((cards.get(j["card_id"]) or {}).get("profile")) for j in acc)
rej_prof = collections.Counter(str((cards.get(j["card_id"]) or {}).get("profile")) for j in rej)
print(json.dumps({"rejections": len(rej), "accepts": len(acc), "why": out,
                  "by_profile": {p: {"accepted": acc_prof[p], "rejected": rej_prof[p], "why": by_prof[p]} for p in set(acc_prof) | set(rej_prof)}}, indent=1))
