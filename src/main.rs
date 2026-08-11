//! MCP stdio server exposing `memory_search` over the pos108 memory store.
//!
//! Wire-up (project .mcp.json):
//!   { "mcpServers": { "memory-search": {
//!       "command": "/Users/yongyutjantaboot/108-POS/memory-search/target/release/memory-search" } } }
//!
//! The index is built at startup and re-stat'd before every search, so a
//! memory written mid-session is searchable immediately. It did NOT use to be:
//! the index was frozen at boot, which made `memory_search` answer "nothing
//! recorded" about a file that had just been written — measured 2026-08-11 with
//! a probe file the daemon found and this server could not see at all.

use anyhow::Result;
use memory_search::{store_stamp, Index, LinkGraph, STORE};
use rmcp::{
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    model::*,
    schemars, tool, tool_handler, tool_router,
    transport::stdio,
    ErrorData as McpError, ServerHandler, ServiceExt,
};
use std::sync::Arc;
use tokio::sync::Mutex;

#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
struct SearchArgs {
    /// What to look for — Thai or English both work (BGE-M3 multilingual).
    query: String,
    /// How many results (default 5, max 20).
    k: Option<usize>,
}

struct State {
    index: Index,
    graph: LinkGraph,
    /// Newest store mtime the above was built from.
    stamp: std::time::SystemTime,
}

impl State {
    /// Pick up memories written since the last search. Nothing to do in the
    /// common case; when a file did change, only its chunks are re-embedded.
    /// A failed rebuild keeps the previous index rather than failing the query.
    fn refresh_if_stale(&mut self) {
        let now = store_stamp();
        if now <= self.stamp {
            return;
        }
        let t = std::time::Instant::now();
        let store = std::path::Path::new(STORE);
        match (self.index.refresh(store), LinkGraph::build(store)) {
            (Ok(()), Ok(g)) => {
                self.graph = g;
                self.stamp = now;
                tracing::info!(
                    "store changed — reindexed {} chunks in {:?}",
                    self.index.chunks.len(),
                    t.elapsed()
                );
            }
            (r_idx, r_graph) => {
                // Leave `stamp` behind so the next call retries.
                for e in [r_idx.err(), r_graph.err().map(|e| e.context("link graph"))]
                    .into_iter()
                    .flatten()
                {
                    tracing::warn!("reindex failed, serving the previous index: {e:#}");
                }
            }
        }
    }
}

#[derive(Clone)]
struct MemorySearch {
    state: Arc<Mutex<State>>,
    tool_router: ToolRouter<Self>,
}

#[tool_router]
impl MemorySearch {
    fn new(index: Index, graph: LinkGraph, stamp: std::time::SystemTime) -> Self {
        Self {
            state: Arc::new(Mutex::new(State {
                index,
                graph,
                stamp,
            })),
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
        let state = self.state.clone();
        let query = args.query.clone();
        // fastembed is sync; keep the async runtime responsive.
        let hits = tokio::task::spawn_blocking(move || {
            let mut guard = state.blocking_lock();
            let st = &mut *guard;
            st.refresh_if_stale();
            let graph = &st.graph;
            st.index.search(&query, k).map(|hits| {
                let mut matched: Vec<String> = Vec::new();
                let mut body = hits
                    .into_iter()
                    .map(|(score, c)| {
                        if !matched.contains(&c.file) {
                            matched.push(c.file.clone());
                        }
                        format!(
                            "### {} — {} (score {:.3})\n{}",
                            c.file,
                            if c.heading.is_empty() {
                                "(top)"
                            } else {
                                &c.heading
                            },
                            score,
                            // Skip the synthetic context header line we prepended.
                            c.text.splitn(2, '\n').nth(1).unwrap_or(&c.text)
                        )
                    })
                    .collect::<Vec<_>>()
                    .join("\n\n");

                // The store's own `[[wikilinks]]`, one hop out. Names only:
                // whoever wrote the memory decided these belong together, which
                // is context a cosine score cannot rank into the top k.
                let related = graph.neighbours(&matched, 5);
                if !related.is_empty() {
                    body.push_str("\n\n### Linked from the above (names only — read if relevant)\n");
                    for (name, desc) in related {
                        body.push_str(&format!("- `{name}` — {desc}\n"));
                    }
                }
                body
            })
        })
        .await
        .map_err(|e| McpError::internal_error(e.to_string(), None))?
        .map_err(|e| McpError::internal_error(e.to_string(), None))?;

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

    // Build the index BEFORE accepting the transport: the first tool call
    // must never pay the model-load cost. Stamp first, so a write racing the
    // build is re-picked-up rather than assumed included.
    let t = std::time::Instant::now();
    let stamp = store_stamp();
    let index = tokio::task::spawn_blocking(|| Index::build(std::path::Path::new(STORE))).await??;
    let graph = LinkGraph::build(std::path::Path::new(STORE))?;
    tracing::info!(
        "index ready: {} chunks, {} linked files in {:?}",
        index.chunks.len(),
        graph.descriptions.len(),
        t.elapsed()
    );

    let service = MemorySearch::new(index, graph, stamp).serve(stdio()).await?;
    service.waiting().await?;
    Ok(())
}
