#!/usr/bin/env python3
"""Is a memory searchable the moment it is written, changed and deleted?

    scripts/freshness-test.py                # daemon + the real MCP server
    scripts/freshness-test.py --daemon-only  # socket only, no binary needed

`scripts/bench-both.py` measures ranking quality and would pass happily while
this invariant is broken, which is exactly what happened on 2026-08-11: the MCP
server built its index in `main()` and never again, so a memory written
mid-session came back "not recorded" from a file that existed.

Three cases, because `store_stamp` has two halves that cover each other's blind
spot and only one of them is exercised by writing a new file:

  create   file mtime AND directory mtime move
  edit     only the FILE's mtime moves     — a directory watch misses this
  delete   only the DIRECTORY's mtime moves — file mtimes miss this entirely,
                                              and this was the case that shipped
                                              broken and failed this test first

It writes ONE file into the real store and removes it in a `finally`, including
on Ctrl-C. If it ever leaves one behind the name says so: delete it on sight.
"""
import argparse
import json
import os
import socket
import subprocess
import sys
import time

STORE = os.path.expanduser("~/.claude/shared-memory/pos108")
SOCK = os.path.expanduser("~/.cache/memory-search/memqd.sock")
BIN = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "target", "release", "memory-search")
PROBE = os.path.join(STORE, "zzz-tmp-freshness-probe-delete-me.md")

BEFORE = "turquoise pangolin calibration ritual"
AFTER = "vermillion armadillo inspection protocol"


def write_probe(marker):
    with open(PROBE, "w") as f:
        f.write("---\nname: zzz-tmp-freshness-probe-delete-me\n"
                "description: temporary probe written by scripts/freshness-test.py\n"
                "---\n"
                f"The {marker} requires exactly seventeen brass thimbles.\n")


def daemon_search(text, k=3):
    """Raw mode — ungated, so a nonsense probe is not filtered out by MIN_SCORE."""
    s = socket.socket(socket.AF_UNIX)
    s.connect(SOCK)
    s.sendall((json.dumps({"q": text, "k": k, "raw": True}) + "\n").encode())
    s.shutdown(socket.SHUT_WR)
    buf = b""
    while True:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    s.close()
    return buf.decode()


class Mcp:
    """The real MCP server over stdio — the whole chain, not just the index."""

    def __init__(self):
        self.p = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self.n = 0
        self.rpc("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                                "clientInfo": {"name": "freshness", "version": "0"}})
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

    def search(self, text, k=3):
        r = self.rpc("tools/call", {"name": "memory_search",
                                    "arguments": {"query": text, "k": k}})
        return "".join(c.get("text", "") for c in r["result"]["content"])

    def close(self):
        self.p.stdin.close()
        self.p.wait(timeout=10)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--daemon-only", action="store_true",
                    help="skip the MCP server (no built binary required)")
    args = ap.parse_args()

    if not os.path.isdir(STORE):
        sys.exit(f"SETUP ERROR: no store at {STORE}")
    if not os.path.exists(SOCK):
        sys.exit(f"SETUP ERROR: {SOCK} missing — is memqd up?\n"
                 "  launchctl kickstart -k gui/$UID/com.108.memqd")
    if os.path.exists(PROBE):
        sys.exit(f"SETUP ERROR: {PROBE} already exists.\n"
                 "A previous run died before cleaning up. Delete it and re-run.")

    # One long-lived MCP server for the whole test: a fresh one per step would
    # index at boot and pass no matter what, which is the bug this test exists
    # for. Started BEFORE the probe is written, for the same reason.
    mcp = None if args.daemon_only else Mcp()
    paths = [("daemon", daemon_search)] + ([] if mcp is None else [("mcp", mcp.search)])
    fails = []

    def check(step, marker, want):
        for name, search in paths:
            t0 = time.perf_counter()
            found = marker in search(marker)
            dt = (time.perf_counter() - t0) * 1000
            ok = found == want
            print(f"  {'ok  ' if ok else 'FAIL'}  {step:<22} {name:<7} "
                  f"{'sees it' if found else 'does not see it':<16} {dt:5.0f} ms")
            if not ok:
                fails.append(f"{step} via {name}: expected "
                             f"{'a hit' if want else 'no hit'}, got the opposite")

    try:
        print(f"probe: {os.path.basename(PROBE)}")
        write_probe(BEFORE)
        check("after create", BEFORE, True)

        # Only the file's mtime moves here — a directory watch would miss it,
        # and editing an existing memory is the common case.
        write_probe(AFTER)
        check("after edit (new text)", AFTER, True)
        check("after edit (old text)", BEFORE, False)

        # Only the directory's mtime moves here. This is the case that shipped
        # broken: a removed memory stayed searchable until something unrelated
        # was edited.
        os.remove(PROBE)
        check("after delete", AFTER, False)
    finally:
        if os.path.exists(PROBE):
            os.remove(PROBE)
        if mcp is not None:
            mcp.close()

    print()
    if fails:
        for f in fails:
            print(f"FAIL: {f}")
        print("\nThe index is not tracking the store. Look at store_stamp() and "
              "the refresh call in whichever path failed.")
        sys.exit(1)
    print("PASS — writes, edits and deletes are all visible immediately"
          + ("" if mcp else " (daemon only)"))


if __name__ == "__main__":
    main()
