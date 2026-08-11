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

/// Where `memq serve` listens. Both clients — the `UserPromptSubmit` hook and
/// the MCP server — reach the one resident index through this.
pub fn socket_path() -> PathBuf {
    cache_path()
        .parent()
        .expect("cache path has a parent")
        .join("memqd.sock")
}

/// Newest mtime among the store's `*.md` **and the directory itself**. Both the
/// daemon and the MCP server re-stat before serving and rebuild when this moves.
///
/// Both halves are load-bearing, and each covers the other's blind spot:
/// - the directory's mtime moves on add/remove/rename but NOT on an edit to a
///   file already inside it — and editing an existing memory is the common case
///   (this is also why launchd `WatchPaths` on the store would not work);
/// - the files' mtimes miss a **deletion** entirely, since removing one does not
///   touch the survivors. Measured 2026-08-11: a probe file stayed searchable
///   after `rm` until some unrelated memory happened to be edited.
pub fn store_stamp() -> std::time::SystemTime {
    let mut newest = std::fs::metadata(STORE)
        .and_then(|m| m.modified())
        .unwrap_or(std::time::SystemTime::UNIX_EPOCH);
    let Ok(entries) = std::fs::read_dir(STORE) else {
        return newest;
    };
    for e in entries.flatten() {
        if e.path().extension().is_none_or(|x| x != "md") {
            continue;
        }
        if let Ok(m) = e.metadata().and_then(|m| m.modified()) {
            newest = newest.max(m);
        }
    }
    newest
}

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

/// Model files live at an ABSOLUTE path. fastembed's default is
/// `.fastembed_cache` under the CURRENT DIRECTORY, which made the server
/// re-download 2.2 GB whenever launched from a different cwd — exactly what
/// an MCP client does. That bug cost the first wire-up attempt.
pub fn model_dir() -> PathBuf {
    let home = std::env::var("HOME").expect("HOME not set");
    PathBuf::from(home).join(".cache/memory-search/models")
}

/// Split one memory file into chunks: frontmatter description is prepended to
/// every chunk (it names the topic — retrieval quality depends on it),
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

/// The `[[wikilink]]` graph the store has been carrying all along.
///
/// There are ~1000 links across these files and nothing traversed them: search
/// ranked by embedding alone, so a hit never brought its own context with it.
/// The links are hand-written by whoever wrote the memory — they encode "you
/// will also need this", which is judgement no cosine score reproduces.
///
/// Only names + descriptions are surfaced, never neighbour bodies. A related
/// file costs one line; pulling its content would cost more context than the
/// hit itself and drown the thing actually asked about.
pub struct LinkGraph {
    /// file stem → frontmatter description (may be empty)
    pub descriptions: HashMap<String, String>,
    /// file stem → stems it links to
    pub out: HashMap<String, Vec<String>>,
    /// file stem → stems that link to it
    pub back: HashMap<String, Vec<String>>,
}

impl LinkGraph {
    pub fn build(store: &Path) -> Result<Self> {
        let mut descriptions = HashMap::new();
        let mut out: HashMap<String, Vec<String>> = HashMap::new();
        let mut back: HashMap<String, Vec<String>> = HashMap::new();

        for entry in std::fs::read_dir(store)? {
            let path = entry?.path();
            if path.extension().and_then(|e| e.to_str()) != Some("md") {
                continue;
            }
            let stem = match path.file_stem().and_then(|s| s.to_str()) {
                Some(s) if s != "MEMORY" => s.to_string(),
                _ => continue,
            };
            let raw = std::fs::read_to_string(&path)?;

            if let Some(d) = raw
                .lines()
                .find_map(|l| l.trim().strip_prefix("description:"))
            {
                descriptions.insert(stem.clone(), d.trim().trim_matches('"').to_string());
            }

            // `[[name]]` — a dangling link is normal here (it marks a memory
            // worth writing), so unresolved targets are simply skipped.
            let mut targets: Vec<String> = Vec::new();
            let mut rest = raw.as_str();
            while let Some(open) = rest.find("[[") {
                rest = &rest[open + 2..];
                let Some(close) = rest.find("]]") else { break };
                let target = rest[..close].trim().to_string();
                rest = &rest[close + 2..];
                if !target.is_empty() && target != stem && !targets.contains(&target) {
                    targets.push(target);
                }
            }
            for t in &targets {
                back.entry(t.clone()).or_default().push(stem.clone());
            }
            out.insert(stem, targets);
        }
        Ok(Self {
            descriptions,
            out,
            back,
        })
    }

    /// One hop out from the files that matched, in both directions. Returns
    /// `(stem, description)` for neighbours that exist and are not themselves
    /// results, most-connected first — a file reached from several hits is more
    /// likely to be the shared context than one reached from a single hit.
    pub fn neighbours(&self, seeds: &[String], limit: usize) -> Vec<(String, String)> {
        let seed_stems: Vec<String> = seeds
            .iter()
            .map(|f| f.trim_end_matches(".md").to_string())
            .collect();

        let mut hits: HashMap<String, usize> = HashMap::new();
        for s in &seed_stems {
            let linked = self.out.get(s).into_iter().flatten();
            let linking = self.back.get(s).into_iter().flatten();
            for n in linked.chain(linking) {
                if seed_stems.contains(n) || !self.descriptions.contains_key(n) {
                    continue;
                }
                *hits.entry(n.clone()).or_default() += 1;
            }
        }

        let mut ranked: Vec<(String, usize)> = hits.into_iter().collect();
        // Count first, then name — ties must not reorder run to run.
        ranked.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
        ranked.truncate(limit);
        ranked
            .into_iter()
            .map(|(n, _)| {
                let d = self.descriptions.get(&n).cloned().unwrap_or_default();
                (n, d)
            })
            .collect()
    }
}

pub struct Index {
    pub chunks: Vec<Chunk>,
    pub embeddings: Vec<Vec<f32>>,
    model: TextEmbedding,
}

impl Index {
    /// Build the index from scratch, loading the model. Embeds only chunks
    /// missing from cache. Use [`Self::refresh`] to pick up later writes — a
    /// second `build` reloads BGE-M3 (~1 s, ~200 MB of churn) for nothing.
    pub fn build(store: &Path) -> Result<Self> {
        let mut model = TextEmbedding::try_new(
            InitOptions::new(EmbeddingModel::BGEM3)
                .with_cache_dir(model_dir())
                .with_show_download_progress(false),
        )?;
        let (chunks, embeddings) = Self::load(&mut model, store)?;
        Ok(Self {
            chunks,
            embeddings,
            model,
        })
    }

    /// Re-read the store into the ALREADY-LOADED model. Cheap when nothing
    /// changed (every chunk hits the cache) and the only cost when a memory was
    /// written is embedding that file's chunks.
    ///
    /// On failure the index is left untouched — a caller that keeps serving the
    /// previous one is right: stale beats silent.
    pub fn refresh(&mut self, store: &Path) -> Result<()> {
        let (chunks, embeddings) = Self::load(&mut self.model, store)?;
        self.chunks = chunks;
        self.embeddings = embeddings;
        Ok(())
    }

    fn load(model: &mut TextEmbedding, store: &Path) -> Result<(Vec<Chunk>, Vec<Vec<f32>>)> {
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
        Ok((chunks, embeddings))
    }

    /// Like [`Self::search`] but also returns the **median** score across the
    /// whole store.
    ///
    /// An absolute cutoff cannot separate "asked about something we know" from
    /// "text that is merely text". Measured 2026-08-09 on the first live hook
    /// firing: a pasted terminal transcript scored 0.617–0.629 against three
    /// unrelated files, inside the 0.599–0.661 band of genuine hits. The shape
    /// differs even though the height does not — a real question has a *peak*
    /// over the store, while generic text sits near everything at once. The
    /// margin `top - median` measures that peak and is scale-free, so it does
    /// not need re-tuning when the store grows.
    pub fn search_scored(&mut self, query: &str, k: usize) -> Result<(Vec<(f32, &Chunk)>, f32)> {
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
        let median = scored
            .get(scored.len() / 2)
            .map(|(s, _)| *s)
            .unwrap_or_default();
        scored.truncate(k);
        Ok((scored, median))
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
