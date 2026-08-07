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
  Index is built at startup, not watched.

## Build & wire up

    cargo build --release
    claude mcp add --scope user memory-search -- \
      /Users/yongyutjantaboot/108-POS/memory-search/target/release/memory-search

One tool: `memory_search(query, k)` — Thai and English both work.
Dev query loop: `cargo run --release --bin tryquery`.
