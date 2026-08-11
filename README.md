# memory-search

Semantic search MCP server over a directory of markdown memories — built for the
pos108 shared memory store (`~/.claude/shared-memory/pos108`, ~280 files,
Thai+English), but any flat directory of `*.md` works. See
[Using it on your own store](#using-it-on-your-own-store).

- Model: **BGE-M3** via fastembed/ONNX, fully local. Chosen by measurement:
  6/6 on a Thai↔English retrieval spike where multilingual-e5-small scored 2/6
  (`src/bin/spike.rs` — rerun it before swapping models).
- No vector DB: ~1.4k chunks × 1024 dims brute-forced in ~28 ms/query.
- Embedding cache keyed by chunk content hash at
  `~/.cache/memory-search/index-v1.json` — first index ~8 min, unchanged boot ~1 s.
- **One model per machine, not per session.** `memq serve` is the only process
  that loads BGE-M3; the MCP server is a thin client of its socket and sits at
  **~9 MB**. It used to build its own index — 1.78 GB per open Claude session,
  ~7 GB across the eight that were live on 2026-08-11. Sharing costs less than
  it looks: the daemon is serial, but a query is ~30 ms against ~10 sessions at
  one query per prompt, so queuing needs two requests inside the same 30 ms. The
  reindex after a large write does stall everyone for seconds — that one is not
  about sharing.
- The markdown store stays the source of truth; this crate only reads it. The
  daemon re-stats the store before serving (`store_stamp`) and refreshes when a
  memory is written, deleted or renamed, so a memory written mid-session is
  searchable on the next query — and both clients inherit that. Refreshing
  reuses the loaded model (`Index::refresh`); a second `Index::build` would
  reload BGE-M3 each time, which is what made a reindex cost ~1 s and ~200 MB of
  churn until 2026-08-11.

## Using it on your own store

### Requirements

- **Rust** stable, edition 2021 (developed on 1.97).
- **macOS or Linux.** `memq serve` talks over a unix socket, so Windows is out
  without a port. The `launchctl` agent below is macOS-only; on Linux write a
  systemd user unit, or just run `memq serve` yourself — `memq hook` spawns a
  detached daemon when the socket is missing, so nothing hard-depends on the
  supervisor.
- **Network on first build only.** fastembed downloads BGE-M3 (~2 GB) into
  `~/.cache/memory-search/models`; after that everything is local and offline.
- **python3** for `scripts/*.py` (stdlib only, no pip install).
- **~2 GB of RAM** for the resident daemon — see the soak note under *Checks*.

### Point it at your store

`STORE` in [`src/lib.rs`](src/lib.rs) is a hardcoded absolute path — there is no
env var or CLI flag yet, so edit it and rebuild:

    pub const STORE: &str = "/Users/you/notes";

What the indexer expects of that directory:

- A **flat** directory of `*.md` (subdirectories are not walked).
- `MEMORY.md` is skipped by name — in this store it is the index of the others,
  so indexing it just returns a table of contents for every query. Harmless to
  leave in place if your store has no such file.
- **YAML frontmatter is optional.** If present, its `description:` line is
  prepended to every chunk of that file as context, which measurably helps
  retrieval; files without frontmatter are indexed as-is.
- Files are split on `## ` headings, then oversized sections on blank lines at
  2000 chars. The pre-heading block is its own chunk.
- `[[wiki-links]]` between files build a link graph — a hit pulls in the names
  of what it links to. Optional; a store with no links just never shows that
  section.
- Nothing is written back. The embedding cache lives in `~/.cache/memory-search/`
  so your store's git history never sees derived data.

### Build & wire up

    cargo build --release
    claude mcp add --scope user memory-search -- "$PWD/target/release/memory-search"

One tool: `memory_search(query, k)` — Thai and English both work.
Dev query loop: `cargo run --release --bin tryquery`.

**Budget ~8 minutes for the first index** (model download + embedding every
chunk). Every boot after that reuses the content-hash cache and takes ~1 s.
`cargo run --release --bin tryquery` is the cheapest way to trigger it and see
that retrieval works before wiring anything into Claude Code.

## Checks

    scripts/check-all.sh          # all three, ~80 s
    scripts/check-all.sh --quick  # skips the soak, ~10 s
    SOAK_N=10000 scripts/check-all.sh

Runs every check even if one fails, prints a summary, and exits with the number
that failed. The three below can also be run on their own.

    scripts/bench-both.py             # both paths, exit 1 on regression
    scripts/bench-both.py --verbose   # per-query ranks
    scripts/bench-both.py --hook      # hook path only, no binary needed

21 queries — 12 paraphrases that share no words with their target filename, plus
9 off-topic controls — against **both** paths, with recall floors that fail the
run if a change gives ground. It also fails if the two paths stop missing the
same things, since they read one index and a divergence means an output path is
dropping results; and if a renamed memory turns a case into a silent zero.

Run it after touching `MIN_SCORE`, `MIN_MARGIN`, the chunker, the model, or
either output path. Baseline at 278 files / 1372 chunks: recall 7/12 at k=3 and
9/12 at k=5 on both paths, ~28 ms median, one known false positive on the hook
(a paragraph of business prose that genuinely resembles the store).

`scripts/freshness-test.py` covers what the bench cannot: is a memory searchable
the moment it is **written, edited and deleted**? Three cases, because
`store_stamp` has two halves — an edit moves only the file's mtime, a delete
moves only the directory's. The delete case shipped broken on 2026-08-11 and is
the reason this exists; the bench passed the whole time. It writes one probe
into the real store and removes it in a `finally`.

`scripts/soak.py N` answers a different question — does memqd's RSS keep
growing? Measured over 10,000 queries: 1815 MB fresh, +144 MB in the first
quarter of the run, **+1 MB in the last**, flat at ~1983 MB. An ONNX arena
sizing itself to the largest input it has seen, not a leak; plan ~2 GB. Its
latency column is not the system's latency — it fires as fast as one client can
(13 q/s, p50 80 ms) and nothing real does that.

## memqd — automatic retrieval (the `UserPromptSubmit` hook)

`memq hook` injects the top hits into every prompt; `memq serve` is the resident
index it talks to over `~/.cache/memory-search/memqd.sock`.

This half is optional — the MCP tool works on its own. Register the hook in
`~/.claude/settings.json` with your own absolute path:

    { "hooks": { "UserPromptSubmit": [ { "hooks": [
        { "type": "command",
          "command": "/path/to/memory-search/target/release/memq hook",
          "timeout": 5 } ] } ] } }

Then install the agent so the daemon survives reboots — started by hand, it did
not, and the first prompt after every restart silently got no memory:

    cp scripts/com.108.memqd.plist ~/Library/LaunchAgents/
    launchctl bootout  gui/$UID/com.108.memqd 2>/dev/null
    launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.108.memqd.plist

⚠️ **Edit the plist's four absolute paths first** (binary, both log paths,
`WorkingDirectory`) — launchd expands neither `~` nor `$HOME`, so the shipped
copy points at the author's machine and will fail silently on yours. Check
`~/Library/Logs/memqd.log` after bootstrapping.

Log: `~/Library/Logs/memqd.log`. After `cargo build --release --bin memq`, restart
it (`launchctl kickstart -k gui/$UID/com.108.memqd`) — KeepAlive only replaces a
dead process, it does not notice a new binary. Same for the MCP server, which is
a per-session child: `pkill -f release/memory-search` and the harness respawns it
on the new binary within seconds, no app restart.

Two request modes on the socket, same index:

| | `{"q":…,"k":…}` | `{"q":…,"k":…,"raw":true}` |
|---|---|---|
| client | `memq hook` | the MCP server |
| output | markdown, gated | JSON, ungated |
| `MIN_SCORE` + margin | applied | not applied |
| `k` counts | files | files |

The split is only about gating: the hook spends a context budget nobody asked
for and must reject hard, while an agent that *chose* to search wants to see
what there is and judge for itself. Both dedup to one chunk per file — the raw
path did not at first, and measurement killed the idea: 11 of 12 bench queries
had one file take more than one of five slots, costing a real answer.

If the daemon is down when the MCP server needs it, the server starts one and
waits (~1 s cold) rather than loading a second copy of the model.
