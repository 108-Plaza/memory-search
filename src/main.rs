//! MCP stdio server exposing `memory_search` over the pos108 memory store.
//!
//! Wire-up (project .mcp.json):
//!   { "mcpServers": { "memory-search": {
//!       "command": "/Users/yongyutjantaboot/108-POS/memory-search/target/release/memory-search" } } }
//!
//! The index is built once at startup (cache makes an unchanged store free)
//! and NOT watched afterwards — a session that writes new memories sees them
//! on the next session's boot, which matches how MEMORY.md itself behaves.

use anyhow::Result;
use memory_search::{Index, STORE};
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

#[derive(Clone)]
struct MemorySearch {
    index: Arc<Mutex<Index>>,
    tool_router: ToolRouter<Self>,
}

#[tool_router]
impl MemorySearch {
    fn new(index: Index) -> Self {
        Self {
            index: Arc::new(Mutex::new(index)),
            tool_router: Self::tool_router(),
        }
    }

    #[tool(
        description = "Semantic search over the pos108 shared memory store (229 files, Thai+English). \
                       Returns the most relevant memory chunks with their file names. Use this BEFORE \
                       assuming something is unrecorded, and to find which memory file covers a topic. \
                       Results ending in -history.md are archived logs; prefer the hub file of the same name."
    )]
    async fn memory_search(
        &self,
        Parameters(args): Parameters<SearchArgs>,
    ) -> Result<CallToolResult, McpError> {
        let k = args.k.unwrap_or(5).min(20);
        let index = self.index.clone();
        let query = args.query.clone();
        // fastembed is sync; keep the async runtime responsive.
        let hits = tokio::task::spawn_blocking(move || {
            let mut idx = index.blocking_lock();
            idx.search(&query, k).map(|hits| {
                hits.into_iter()
                    .map(|(score, c)| {
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
                    .join("\n\n")
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
    // must never pay the model-load cost.
    let t = std::time::Instant::now();
    let index = tokio::task::spawn_blocking(|| Index::build(std::path::Path::new(STORE))).await??;
    tracing::info!(
        "index ready: {} chunks in {:?}",
        index.chunks.len(),
        t.elapsed()
    );

    let service = MemorySearch::new(index).serve(stdio()).await?;
    service.waiting().await?;
    Ok(())
}
