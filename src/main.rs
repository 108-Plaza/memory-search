//! MCP stdio server exposing `memory_search` over the pos108 memory store.
//!
//! Wire-up (project .mcp.json):
//!   { "mcpServers": { "memory-search": {
//!       "command": "/Users/yongyutjantaboot/108-POS/memory-search/target/release/memory-search" } } }
//!
//! **This process holds no index and no model.** It is a thin client of
//! `memq serve` over `~/.cache/memory-search/memqd.sock`, which already holds
//! BGE-M3 resident for the `UserPromptSubmit` hook.
//!
//! It used to build its own. That is one **1.78 GB** copy of the model per
//! Claude session, and sessions accumulate: eight were live on 2026-08-11
//! holding ~7 GB between them, on top of the daemon's own 1.86 GB. Nothing
//! noticed because macOS pages the idle ones out to near zero. Sharing the
//! daemon makes it one copy per machine no matter how many sessions are open.
//!
//! What that trades away: the daemon answers serially, so a query can queue
//! behind another session's — invisible at ~30 ms, seconds while it reindexes
//! after a large memory is written. Worth it, and the previous design paid the
//! same reindex cost per session anyway.
//!
//! Freshness comes free with it. The daemon re-stats the store per request, so
//! a memory written mid-session is searchable at once — this server used to
//! freeze its index at boot and answer "nothing recorded" about a file that had
//! just been written (measured 2026-08-11, with a probe the daemon found and
//! this one could not see at all).

use anyhow::{bail, Context, Result};
use memory_search::socket_path;
use rmcp::{
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    model::*,
    schemars, tool, tool_handler, tool_router,
    transport::stdio,
    ErrorData as McpError, ServerHandler, ServiceExt,
};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;

#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
struct SearchArgs {
    /// What to look for — Thai or English both work (BGE-M3 multilingual).
    query: String,
    /// How many results (default 5, max 20).
    k: Option<usize>,
}

/// A cold daemon loads the model before it can answer. Measured at ~2.6 s; this
/// is slack for a loaded machine, and it is only ever paid once.
const DAEMON_START_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

/// One query against `memq serve`, in the ungated `raw` mode: every hit with
/// its score, formatted here rather than by the daemon's hook policy.
fn query_daemon(query: &str, k: usize) -> Result<String> {
    let req = serde_json::json!({ "q": query, "k": k, "raw": true });

    let mut stream = match UnixStream::connect(socket_path()) {
        Ok(s) => s,
        // Under launchd the daemon is always up, so this is the cold-boot case:
        // start it and wait, rather than fall back to loading a second model —
        // the whole point of this process is that it does not own one.
        Err(_) => {
            start_daemon()?;
            UnixStream::connect(socket_path()).context("daemon started but is not accepting")?
        }
    };

    writeln!(stream, "{req}")?;
    stream.shutdown(std::net::Shutdown::Write)?;
    let mut raw = String::new();
    stream.read_to_string(&mut raw)?;
    let resp: serde_json::Value =
        serde_json::from_str(raw.trim()).context("daemon sent something that is not JSON")?;

    let empty = vec![];
    let hits = resp["hits"].as_array().unwrap_or(&empty);
    let mut out = hits
        .iter()
        .map(|h| {
            let heading = h["heading"].as_str().unwrap_or_default();
            format!(
                "### {} — {} (score {:.3})\n{}",
                h["file"].as_str().unwrap_or("?"),
                if heading.is_empty() { "(top)" } else { heading },
                h["score"].as_f64().unwrap_or_default(),
                h["body"].as_str().unwrap_or_default()
            )
        })
        .collect::<Vec<_>>()
        .join("\n\n");

    // The store's own `[[wikilinks]]`, one hop out. Names only: whoever wrote
    // the memory decided these belong together, which is context a cosine score
    // cannot rank into the top k.
    if let Some(related) = resp["related"].as_array().filter(|r| !r.is_empty()) {
        out.push_str("\n\n### Linked from the above (names only — read if relevant)\n");
        for r in related {
            out.push_str(&format!(
                "- `{}` — {}\n",
                r["name"].as_str().unwrap_or("?"),
                r["desc"].as_str().unwrap_or_default()
            ));
        }
    }
    Ok(out)
}

/// Spawn `memq serve` (the sibling binary) detached and wait for its socket.
fn start_daemon() -> Result<()> {
    let memq = std::env::current_exe()?
        .parent()
        .context("binary has no parent directory")?
        .join("memq");
    if !memq.exists() {
        bail!("memqd is not running and {memq:?} does not exist to start it");
    }
    tracing::info!("memqd not reachable — starting {memq:?}");
    std::process::Command::new(&memq)
        .arg("serve")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .with_context(|| format!("spawning {memq:?}"))?;

    let deadline = std::time::Instant::now() + DAEMON_START_TIMEOUT;
    while std::time::Instant::now() < deadline {
        std::thread::sleep(std::time::Duration::from_millis(200));
        if UnixStream::connect(socket_path()).is_ok() {
            return Ok(());
        }
    }
    bail!("memqd did not come up within {DAEMON_START_TIMEOUT:?} — check ~/Library/Logs/memqd.log")
}

#[derive(Clone)]
struct MemorySearch {
    tool_router: ToolRouter<Self>,
}

#[tool_router]
impl MemorySearch {
    fn new() -> Self {
        Self {
            tool_router: Self::tool_router(),
        }
    }

    #[tool(
        description = "Semantic search over the pos108 shared memory store (Thai+English), including \
                       memories written earlier in this session. Returns the most relevant memory \
                       chunks with their file names. Use this BEFORE assuming something is unrecorded, \
                       and to find which memory file covers a topic. Results ending in -history.md are \
                       archived logs; prefer the hub file of the same name."
    )]
    async fn memory_search(
        &self,
        Parameters(args): Parameters<SearchArgs>,
    ) -> Result<CallToolResult, McpError> {
        let k = args.k.unwrap_or(5).min(20);
        let query = args.query.clone();
        // The socket call is blocking, and a cold daemon can hold it for
        // seconds; keep it off the async runtime.
        let hits = tokio::task::spawn_blocking(move || query_daemon(&query, k))
            .await
            .map_err(|e| McpError::internal_error(e.to_string(), None))?
            .map_err(|e| McpError::internal_error(format!("{e:#}"), None))?;

        Ok(CallToolResult::success(vec![ContentBlock::text(hits)]))
    }
}

#[tool_handler]
impl ServerHandler for MemorySearch {
    fn get_info(&self) -> ServerInfo {
        InitializeResult::new(ServerCapabilities::builder().enable_tools().build())
            .with_instructions(
                "Semantic search over the pos108 memory store. One tool: memory_search(query, k). \
                 Thai and English queries both work.",
            )
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::from_default_env()
                .add_directive(tracing::Level::INFO.into()),
        )
        .with_writer(std::io::stderr)
        .with_ansi(false)
        .init();

    // Start serving immediately — there is nothing to load. If the daemon is
    // cold, the first search pays for it and every later session gets it warm.
    // Failing here instead would take the tool out over a daemon that launchd
    // brings back on its own.
    if let Err(e) = tokio::task::spawn_blocking(|| UnixStream::connect(socket_path())).await? {
        tracing::warn!("memqd not reachable at startup ({e}); the first search will start it");
    }

    let service = MemorySearch::new().serve(stdio()).await?;
    service.waiting().await?;
    Ok(())
}
