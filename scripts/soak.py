#!/usr/bin/env python3
"""Does memqd's RSS keep growing? Fire N queries and watch where it stops.

    launchctl kickstart -k gui/$UID/com.108.memqd   # measure from a fresh boot
    scripts/soak.py 10000                            # ~12 min, run it detached

Answered 2026-08-11 at 278 files / 1372 chunks: 1815 MB fresh, +144 MB over the
first quarter of the run, +1 MB over the last, flat at ~1983 MB. That is an ONNX
arena sizing itself to the largest input it has seen, not a leak. Plan ~2 GB.

⚠️ Do not read the LATENCY here as the system's latency. This fires as fast as
one client can, which no real usage does — 13 q/s sustained, p50 80 ms, against
28 ms from scripts/bench-both.py. What the p99 column IS good for is catching a
reindex: writing a memory mid-run showed up as p99 2.1 s in one sample.

⚠️ Anything else touching the store during a run (another session writing a
memory) lands in the series as a step. Check ~/Library/Logs/memqd.log for
"reindexed" lines before blaming the allocator for a jump.
"""
import json, socket, os, subprocess, sys, time, statistics

SOCK = os.path.expanduser("~/.cache/memory-search/memqd.sock")
N = int(sys.argv[1]) if len(sys.argv) > 1 else 10000
SAMPLE = 250

# Varied so we are not replaying one embedding path; mixed scripts and lengths.
STEMS = [
    "ทำไม tenant ถึง CrashLoop หลัง deploy", "why did the branch key stop working",
    "promptpay per branch reconcile", "หยุด mac ไม่ให้หลับตอนรันงาน",
    "kubectl set image vs helm values drift", "ใครมีสิทธิ์อ่าน audit log",
    "printer thai encoding tis-620", "登录票据可以被伪造吗",
    "outbox pending stuck retry", "การคิดเงินรายเดือนต่อสาขา",
    "github actions skipped job counts as success", "rustsec advisory crossbeam",
]

def pid_of_daemon():
    out = subprocess.run(["pgrep", "-f", "release/memq serve"],
                         capture_output=True, text=True).stdout.split()
    return int(out[0]) if out else None

def rss_mb(pid):
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)],
                         capture_output=True, text=True).stdout.strip()
    return int(out) / 1024 if out else 0.0

def query(text, k=5):
    s = socket.socket(socket.AF_UNIX)
    s.connect(SOCK)
    t0 = time.perf_counter()
    s.sendall((json.dumps({"q": text, "k": k}) + "\n").encode())
    s.shutdown(socket.SHUT_WR)
    while s.recv(65536):
        pass
    s.close()
    return (time.perf_counter() - t0) * 1000

pid = pid_of_daemon()
if not pid:
    sys.exit("no daemon running")

print(f"daemon pid {pid}, {N} queries, sampling RSS every {SAMPLE}")
print(f"{'queries':>8} {'RSS MB':>9} {'Δ MB':>7} {'p50 ms':>7} {'p99 ms':>7}")
start = time.time()
base = rss_mb(pid)
prev = base
print(f"{0:8d} {base:9.1f} {0.0:7.1f} {'-':>7} {'-':>7}")

rows = [(0, base)]
window = []
for i in range(1, N + 1):
    window.append(query(f"{STEMS[i % len(STEMS)]} {i}"))
    if i % SAMPLE == 0:
        r = rss_mb(pid)
        w = sorted(window)
        print(f"{i:8d} {r:9.1f} {r-prev:+7.1f} {w[len(w)//2]:7.1f} "
              f"{w[int(len(w)*0.99)]:7.1f}", flush=True)
        rows.append((i, r))
        prev = r
        window = []

el = time.time() - start
final = rss_mb(pid)
print(f"\n{N} queries in {el:.0f}s ({N/el:.0f} q/s single-threaded)")
print(f"RSS {base:.0f} -> {final:.0f} MB  (+{final-base:.0f} MB, "
      f"{(final-base)/N*1024:.1f} KB per query)")
# Growth over the last quarter tells you whether it plateaued or is still climbing.
q = len(rows) // 4
first_q = rows[q][1] - rows[0][1]
last_q = rows[-1][1] - rows[-1 - q][1]
print(f"growth in first quarter: {first_q:+.0f} MB   in last quarter: {last_q:+.0f} MB")
print("VERDICT:", "plateaued" if abs(last_q) < max(20, first_q * 0.15)
      else "still climbing")
