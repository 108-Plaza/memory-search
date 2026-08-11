#!/usr/bin/env python3
"""Retrieval regression bench — both paths, one query set.

    scripts/bench-both.py            # both paths, exit 1 on regression
    scripts/bench-both.py --verbose  # per-query ranks
    scripts/bench-both.py --hook     # skip the MCP path (no binary needed)

Two things reach this index and they must not drift apart:

  hook  memq serve's socket, GATED    — what a UserPromptSubmit injects
  mcp   the memory_search tool, RAW   — what an agent gets when it searches

Same index, so recall must match; the difference is that the hook rejects
off-topic prompts and the MCP path deliberately does not. Run this after
touching MIN_SCORE, MIN_MARGIN, the chunker, the model, or either output path.

⚠️ The queries are PARAPHRASES that share no words with their target filename —
that is the whole point, since keyword search already handles the easy case. If
you add one, do not name the file in the query.

⚠️ EXPECTED is a real filename in the store. A rename makes this bench quietly
measure nothing, so missing targets are reported as a setup error, not a miss.
"""
import argparse
import json
import os
import re
import socket
import statistics
import subprocess
import sys
import time

STORE = os.path.expanduser("~/.claude/shared-memory/pos108")
SOCK = os.path.expanduser("~/.cache/memory-search/memqd.sock")
BIN = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "target", "release", "memory-search")
FILES = re.compile(r"^### ([\w\-.]+\.md)", re.M)

# (query, expected memory | None for an off-topic control). `a|b` = either.
CASES = [
    ("ทำไมสาขาที่เปลี่ยนกุญแจใหม่ถึงล็อกอินเข้าระบบไม่ได้",
     "branch-key-registered-in-one-store-not-two"),
    ("printer prints garbled characters instead of readable text",
     "pos108-escpos-thai-encoding"),
    ("เวลาที่บันทึกลงฐานข้อมูลความละเอียดหายไป",
     "pg-timestamptz-truncates-chrono-nanos"),
    ("someone was mining crypto on one of our machines",
     "ibrowe-postgres-rce-cryptominer-20260729"),
    ("pod keeps restarting because it pulled the wrong build",
     "pos108-tenant-image-tag-skew-crashloop"),
    ("หยุดไม่ให้เครื่องแมคหลับตอนรันงานกลางคืน",
     "macbook-keep-awake-for-scheduled-jobs"),
    ("รับเงินลูกค้าด้วยการสแกนจ่ายแยกตามสาขา",
     "pos108-branch-promptpay"),
    ("ปิดร้านค้าออกจากระบบต้องทำอะไรบ้าง",
     "tenant-decommission-two-phase"),
    ("the build reported success but no job actually executed",
     "ai-review-green-when-it-did-not-run|github-actions-implicit-success-skipped-need"),
    ("คิดเงินค่าบริการรายเดือนตามจำนวนสาขา",
     "pos108-plan-branch-pricing-billing"),
    ("ห้ามใช้คำสั่งที่ลบข้อมูลโดยไม่ตรวจสอบก่อน",
     "destructive-commands-need-a-verified-gate"),
    ("我们的登录票据可以被伪造吗",
     "pos108-published-default-secret-vuln"),

    # Off-topic controls. The hook must stay silent on every one of these; the
    # MCP path is ungated and is expected to answer, so they only score there as
    # information. The prose paragraph is a KNOWN escape — it scores 0.558
    # against customer-platform-repo and peaks, which no threshold fixes.
    ("what is a good recipe for pad thai with tamarind", None),
    ("explain how quicksort partitioning works in python", None),
    ("who won the world cup in 1998", None),
    ("how do I center a div horizontally and vertically in CSS", None),
    ("พรุ่งนี้ฝนจะตกไหม ควรเอาร่มไปด้วยหรือเปล่า", None),
    ("ช่วยเขียนคำอวยพรวันเกิดให้เพื่อนสนิทหน่อย", None),
    ("Thanks, that looks good to me. Let's move on to the next thing.", None),
    ("The quarterly report shows a modest increase in customer satisfaction "
     "across all regions, with the strongest gains in the northern territory "
     "where the new onboarding process was piloted last spring.", None),
    ("yongyut@MacBook-Pro ~ % ls -la && git status\ntotal 48\ndrwxr-xr-x  "
     "12 yongyut staff 384 Aug 11 09:12 .\n-rw-r--r--   1 yongyut staff "
     "1204 Aug 11 09:12 README.md\nOn branch main\nnothing to commit", None),
]

# Measured 2026-08-11 at 278 files / 1372 chunks, MIN_SCORE 0.53. Recall is a
# floor, not a target: raise these when a change genuinely beats them, so the
# next change cannot quietly give it back.
EXPECT = {
    "hook@3": 7, "hook@5": 9,
    "mcp@3": 7, "mcp@5": 9,
    "hook_false_positives": 1,  # the prose paragraph, see above
}


def hook_query(text, k):
    s = socket.socket(socket.AF_UNIX)
    s.connect(SOCK)
    t0 = time.perf_counter()
    s.sendall((json.dumps({"q": text, "k": k}) + "\n").encode())
    s.shutdown(socket.SHUT_WR)
    buf = b""
    while True:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    s.close()
    return (time.perf_counter() - t0) * 1000, buf.decode()


class Mcp:
    """The real MCP server over stdio — not a stand-in for it."""

    def __init__(self):
        self.p = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self.n = 0
        self.rpc("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                                "clientInfo": {"name": "bench", "version": "0"}})
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def _send(self, msg):
        self.p.stdin.write(json.dumps(msg) + "\n")
        self.p.stdin.flush()

    def rpc(self, method, params):
        self.n += 1
        self._send({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params})
        while True:
            line = self.p.stdout.readline()
            if not line:
                sys.exit("MCP server closed the pipe — is the binary built?")
            msg = json.loads(line)
            if msg.get("id") == self.n:
                return msg

    def query(self, text, k):
        t0 = time.perf_counter()
        r = self.rpc("tools/call", {"name": "memory_search",
                                    "arguments": {"query": text, "k": k}})
        dt = (time.perf_counter() - t0) * 1000
        return dt, "".join(c.get("text", "") for c in r["result"]["content"])

    def close(self):
        self.p.stdin.close()
        self.p.wait(timeout=10)


def run(label, fn, k, verbose):
    lat, hits, real, fp, ctrl, dupes, misses = [], 0, 0, 0, 0, 0, []
    for text, expected in CASES:
        dt, out = fn(text, k)
        lat.append(dt)
        got = [f[:-3] for f in FILES.findall(out)]
        if len(got) != len(set(got)):
            dupes += 1
        if expected is None:
            ctrl += 1
            if got:
                fp += 1
            if verbose:
                print(f"    {'ANSWERED' if got else 'silent':>8}  {text[:38]:<40} {got[:1]}")
            continue
        real += 1
        rank = next((i + 1 for i, g in enumerate(got) if g in expected.split("|")), None)
        if rank:
            hits += 1
        else:
            misses.append(expected.split("|")[0])
        if verbose:
            print(f"    {rank if rank else 'MISS':>8}  {text[:38]:<40} {got[:1]}")
    return {"label": f"{label}@{k}", "recall": hits, "of": real, "fp": fp, "ctrl": ctrl,
            "dupes": dupes, "median": statistics.median(lat), "misses": sorted(misses)}


def report(r):
    print(f"  {r['label']:<8} recall {r['recall']}/{r['of']}   "
          f"controls answered {r['fp']}/{r['ctrl']}   "
          f"dupes {r['dupes']}/{len(CASES)}   median {r['median']:3.0f} ms")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--verbose", action="store_true", help="per-query ranks")
    ap.add_argument("--hook", action="store_true", help="hook path only")
    args = ap.parse_args()

    # A renamed target would turn a real miss into a silent zero.
    stale = [e.split("|")[0] for _, e in CASES if e
             and not any(os.path.exists(os.path.join(STORE, f"{n}.md"))
                         for n in e.split("|"))]
    if stale:
        sys.exit(f"SETUP ERROR: expected memories no longer in the store: {stale}\n"
                 "Rename them here, or replace the case if the memory is gone.")
    if not os.path.exists(SOCK):
        sys.exit(f"SETUP ERROR: {SOCK} missing — is memqd up?\n"
                 "  launchctl kickstart -k gui/$UID/com.108.memqd")

    results = []
    print("hook path — memqd socket, GATED (MIN_SCORE + margin)")
    for k in (3, 5):
        results.append(run("hook", hook_query, k, args.verbose))
        report(results[-1])

    if not args.hook:
        print("\nMCP path — memory_search over stdio, UNGATED "
              "(controls SHOULD answer here)")
        mcp = Mcp()
        for k in (3, 5):
            results.append(run("mcp", mcp.query, k, args.verbose))
            report(results[-1])
        mcp.close()

    by = {r["label"]: r for r in results}
    fails = []
    for label, floor in EXPECT.items():
        if label == "hook_false_positives":
            continue
        if label in by and by[label]["recall"] < floor:
            fails.append(f"{label} recall {by[label]['recall']}/{by[label]['of']} "
                         f"below the {floor} floor")
    for r in results:
        if r["dupes"]:
            fails.append(f"{r['label']} returned the same file twice in "
                         f"{r['dupes']} queries — dedup regressed")
    for label in ("hook@3", "hook@5"):
        if label in by and by[label]["fp"] > EXPECT["hook_false_positives"]:
            fails.append(f"{label} answered {by[label]['fp']} off-topic controls, "
                         f"expected at most {EXPECT['hook_false_positives']}")

    # Same index behind both, so a divergence here means an output path is
    # dropping results the other keeps.
    if "mcp@5" in by and by["hook@5"]["misses"] != by["mcp@5"]["misses"]:
        fails.append(f"paths disagree at k=5: hook missed {by['hook@5']['misses']}, "
                     f"mcp missed {by['mcp@5']['misses']}")

    print()
    if fails:
        for f in fails:
            print(f"FAIL: {f}")
        sys.exit(1)
    print(f"PASS — both paths at their floors, misses identical: "
          f"{by['hook@5']['misses']}")


if __name__ == "__main__":
    main()
