# memory-search

Semantic search MCP server over the pos108 shared memory store
(`~/.claude/shared-memory/pos108`, ~280 files, Thai+English).

- Model: **BGE-M3** via fastembed/ONNX, fully local. Chosen by measurement:
  6/6 on a Thai↔English retrieval spike where multilingual-e5-small scored 2/6
  (`src/bin/spike.rs` — rerun it before swapping models).
- No vector DB: ~1.4k chunks × 1024 dims brute-forced in ~28 ms/query.
- Embedding cache keyed by chunk content hash at
  `~/.cache/memory-search/index-v1.json` — first index ~8 min, unchanged boot ~1 s.
- **One model per machine, not per session.** `memq serve` is the only process
  that loads BGE-M3; the MCP server is a thin client of its socket and sits at
  **~9 MB**. It used to build its own index — 1.78 GB per open Claude session,
  ~7 GB across the eight that were live on 2026-08-11. The cost of sharing is
  that the daemon answers serially, so queries queue: nothing at ~30 ms, seconds
  while it reindexes after a large write.
- The markdown store stays the source of truth; this crate only reads it. The
  daemon re-stats the store before serving (`store_stamp`) and refreshes when a
  memory is written, deleted or renamed, so a memory written mid-session is
  searchable on the next query — and both clients inherit that. Refreshing
  reuses the loaded model (`Index::refresh`); a second `Index::build` would
  reload BGE-M3 each time, which is what made a reindex cost ~1 s and ~200 MB of
  churn until 2026-08-11.

## Build & wire up

    cargo build --release
    claude mcp add --scope user memory-search -- \
      /Users/yongyutjantaboot/108-POS/memory-search/target/release/memory-search

One tool: `memory_search(query, k)` — Thai and English both work.
Dev query loop: `cargo run --release --bin tryquery`.

## memqd — automatic retrieval (the `UserPromptSubmit` hook)

`memq hook` injects the top hits into every prompt; `memq serve` is the resident
index it talks to over `~/.cache/memory-search/memqd.sock`. Install the agent
so it survives reboots — started by hand, it did not, and the first prompt after
every restart silently got no memory:

    cp scripts/com.108.memqd.plist ~/Library/LaunchAgents/
    launchctl bootout  gui/$UID/com.108.memqd 2>/dev/null
    launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.108.memqd.plist

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
| one chunk per file | yes | no |

The split is deliberate: the hook spends a context budget nobody asked for and
must gate hard, while an agent that *chose* to search wants every hit and its
score. If the daemon is down when the MCP server needs it, the server starts one
and waits (~1 s cold) rather than loading a second copy of the model.
