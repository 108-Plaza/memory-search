//! Index + search over the pos108 shared memory store.
//!
//! Design constraints (decided, not defaulted):
//! - Model is BGE-M3: the only one that scored 6/6 on the Thai↔English spike
//!   (multilingual-e5-small scored 2/6 — a Thai passage acted as an attractor
//!   for every Thai query). No query/passage prefixes: BGE-M3 needs none.
//! - No vector DB. ~1k chunks × 1024 dims ≈ 4 MB of f32 in RAM; brute-force
//!   cosine is microseconds. Anything more is machinery without a payoff.
//! - The markdown store stays the source of truth. This crate only reads it.
//!   The embedding cache lives OUTSIDE the store (~/.cache/memory-search/) so
//!   the store's git history never sees derived data.
//! - Chunks are keyed by content hash, so an unchanged chunk is never
//!   re-embedded — a boot with no store changes does zero model work.

use anyhow::{Context, Result};
use fastembed::{EmbeddingModel, InitOptions, TextEmbedding};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

pub const STORE: &str = "/Users/yongyutjantaboot/.claude/shared-memory/pos108";

/// Max chunk size in bytes. Sections larger than this are split on paragraph
/// boundaries. BGE-M3 truncates internally past its token limit; keeping
/// chunks this size keeps every byte inside the window with margin.
const MAX_CHUNK: usize = 2000;

#[derive(Serialize, Deserialize, Clone)]
pub struct Chunk {
    pub file: String,    // e.g. "108-bridge.md"
    pub heading: String, // "" for the pre-heading block
    pub text: String,
    pub hash: String, // blake3 of text — cache key
}

#[derive(Serialize, Deserialize, Default)]
pub struct Cache {
    /// chunk hash → embedding
    pub embeddings: HashMap<String, Vec<f32>>,
}

pub fn cache_path() -> PathBuf {
    let home = std::env::var("HOME").expect("HOME not set");
    PathBuf::from(home).join(".cache/memory-search/index-v1.json")
}

/// Split one memory file into chunks: frontmatter description is prepended to
/// the first chunk (it names the topic — retrieval quality depends on it),
/// then split on `## ` headings, then oversized sections on blank lines.
pub fn chunk_file(name: &str, raw: &str) -> Vec<Chunk> {
    // Strip frontmatter, keep its description line as context.
    let mut body = raw;
    let mut description = String::new();
    if let Some(rest) = raw.strip_prefix("---\n") {
        if let Some(end) = rest.find("\n---\n") {
            for line in rest[..end].lines() {
                if let Some(d) = line.strip_prefix("description: ") {
                    description = d.trim_matches('"').to_string();
                }
            }
            body = &rest[end + 5..];
        }
    }

    let mut sections: Vec<(String, String)> = Vec::new(); // (heading, text)
    let mut cur_head = String::new();
    let mut cur = String::new();
    for line in body.lines() {
        if let Some(h) = line.strip_prefix("## ") {
            if !cur.trim().is_empty() {
                sections.push((cur_head.clone(), std::mem::take(&mut cur)));
            }
            cur_head = h.to_string();
        }
        cur.push_str(line);
        cur.push('\n');
    }
    if !cur.trim().is_empty() {
        sections.push((cur_head, cur));
    }

    let mut chunks = Vec::new();
    for (heading, text) in sections {
        // Oversized section → split on blank lines, greedily packing.
        let pieces: Vec<String> = if text.len() <= MAX_CHUNK {
            vec![text]
        } else {
            let mut out: Vec<String> = Vec::new();
            let mut buf = String::new();
            for para in text.split("\n\n") {
                if !buf.is_empty() && buf.len() + para.len() + 2 > MAX_CHUNK {
                    out.push(std::mem::take(&mut buf));
                }
                if !buf.is_empty() {
                    buf.push_str("\n\n");
                }
                buf.push_str(para);
            }
            if !buf.trim().is_empty() {
                out.push(buf);
            }
            out
        };
        for piece in pieces {
            // Context header: the model sees which file/topic this came from.
            let ctx = if description.is_empty() {
                format!("[{name}] {heading}\n")
            } else {
                format!("[{name}] {description} — {heading}\n")
            };
            let text = format!("{ctx}{piece}");
            let hash = blake3::hash(text.as_bytes()).to_hex().to_string();
            chunks.push(Chunk {
                file: name.to_string(),
                heading: heading.clone(),
                text,
                hash,
            });
        }
    }
    chunks
}

/// Walk the store and produce every chunk. MEMORY.md is skipped (it is the
/// index the session already loads; retrieval should surface topic files).
pub fn chunk_store(store: &Path) -> Result<Vec<Chunk>> {
    let mut chunks = Vec::new();
    let mut entries: Vec<_> = std::fs::read_dir(store)
        .with_context(|| format!("read_dir {}", store.display()))?
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| {
            p.extension().is_some_and(|x| x == "md")
                && p.file_name().is_some_and(|n| n != "MEMORY.md")
        })
        .collect();
    entries.sort();
    for path in entries {
        let name = path.file_name().unwrap().to_string_lossy().to_string();
        let raw = std::fs::read_to_string(&path)?;
        chunks.extend(chunk_file(&name, &raw));
    }
    Ok(chunks)
}

pub struct Index {
    pub chunks: Vec<Chunk>,
    pub embeddings: Vec<Vec<f32>>,
    model: TextEmbedding,
}

impl Index {
    /// Build (or refresh) the index. Embeds only chunks missing from cache.
    pub fn build(store: &Path) -> Result<Self> {
        let mut model = TextEmbedding::try_new(
            InitOptions::new(EmbeddingModel::BGEM3).with_show_download_progress(false),
        )?;

        let chunks = chunk_store(store)?;
        let mut cache: Cache = std::fs::read(cache_path())
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();

        let missing: Vec<&Chunk> = chunks
            .iter()
            .filter(|c| !cache.embeddings.contains_key(&c.hash))
            .collect();
        if !missing.is_empty() {
            tracing::info!("embedding {} new/changed chunks", missing.len());
            // Batch to bound peak memory; 64 texts/batch is comfortable.
            for batch in missing.chunks(64) {
                let texts: Vec<&str> = batch.iter().map(|c| c.text.as_str()).collect();
                let embs = model.embed(texts, None)?;
                for (c, e) in batch.iter().zip(embs) {
                    cache.embeddings.insert(c.hash.clone(), e);
                }
            }
            // Prune entries whose chunk no longer exists, then persist.
            let live: std::collections::HashSet<&str> =
                chunks.iter().map(|c| c.hash.as_str()).collect();
            cache.embeddings.retain(|k, _| live.contains(k.as_str()));
            let path = cache_path();
            std::fs::create_dir_all(path.parent().unwrap())?;
            std::fs::write(&path, serde_json::to_vec(&cache)?)?;
        }

        let embeddings = chunks
            .iter()
            .map(|c| cache.embeddings[&c.hash].clone())
            .collect();
        Ok(Self {
            chunks,
            embeddings,
            model,
        })
    }

    pub fn search(&mut self, query: &str, k: usize) -> Result<Vec<(f32, &Chunk)>> {
        let q = &self.model.embed(vec![query], None)?[0];
        let qn: f32 = q.iter().map(|x| x * x).sum::<f32>().sqrt();
        let mut scored: Vec<(f32, &Chunk)> = self
            .embeddings
            .iter()
            .zip(&self.chunks)
            .map(|(e, c)| {
                let dot: f32 = q.iter().zip(e).map(|(a, b)| a * b).sum();
                let en: f32 = e.iter().map(|x| x * x).sum::<f32>().sqrt();
                (dot / (qn * en), c)
            })
            .collect();
        scored.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap());
        scored.truncate(k);
        Ok(scored)
    }
}
