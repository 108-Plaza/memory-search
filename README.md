# memory-search

Semantic search MCP server over the pos108 shared memory store
(`~/.claude/shared-memory/pos108`, 229 files, Thai+English).

- Model: **BGE-M3** via fastembed/ONNX, fully local. Chosen by measurement:
  6/6 on a Thai↔English retrieval spike where multilingual-e5-small scored 2/6
  (`src/bin/spike.rs` — rerun it before swapping models).
- No vector DB: ~1.1k chunks × 1024 dims brute-forced in ~25 ms/query.
- Embedding cache keyed by chunk content hash at
  `~/.cache/memory-search/index-v1.json` — first index ~8 min, unchanged boot ~1 s.
- The markdown store stays the source of truth; this crate only reads it.
  The MCP server indexes once at startup. The `memq` daemon re-stats the store
  per request and reindexes when a memory changes (see below).

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
dead process, it does not notice a new binary.
