//! `memq` — make memory retrieval automatic instead of optional.
//!
//! The MCP tool only fires when an agent *decides* to search, and the measured
//! failure mode is precisely that it does not feel the need to (see RULE 0 in
//! `~/108-POS/CLAUDE.md`). This binary removes the decision: a `UserPromptSubmit`
//! hook runs `memq hook` on every prompt and the top hits are injected as
//! context before the model ever sees the turn.
//!
//! Two modes:
//!   `memq serve`  — daemon holding the index in RAM, one query per connection
//!                   over a unix socket.
//!   `memq hook`   — reads the hook JSON on stdin, queries the daemon, prints
//!                   `additionalContext` JSON on stdout.
//!   `memq <text>` — same query path, human-readable, for testing.
//!
//! Why a daemon at all: `Index::build` costs ~2.6 s even with a warm cache
//! (model load dominates). Paying that per prompt is unusable; holding it in a
//! resident process makes a query the cost of embedding one string (~100 ms).
//!
//! The daemon is disposable. `memq hook` never blocks a prompt on it: if the
//! socket is missing or stale it spawns a detached `memq serve`, emits nothing,
//! and the *next* prompt gets results. Failing silent is deliberate — a memory
//! lookup must never be able to break the user's turn.

use anyhow::{Context, Result};
use memory_search::{Index, LinkGraph, STORE};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;

/// Below this cosine score a hit is noise; injecting it costs context and
/// teaches the model to ignore the block. Calibrated against the store — see
/// `docs/HOOK.md`.
const MIN_SCORE: f32 = 0.55;

/// Prompts shorter than this are greetings, acknowledgements and `/commands`.
/// Embedding them returns whatever is nearest, which is worse than nothing.
const MIN_PROMPT_CHARS: usize = 12;

const DEFAULT_K: usize = 3;

/// Neighbours are one line each, but they are also the cheapest thing to
/// over-produce — a well-linked hub can reach 20 files. Five is enough to name
/// the ones a human would have thought of.
const RELATED_LIMIT: usize = 5;

fn socket_path() -> PathBuf {
    memory_search::cache_path()
        .parent()
        .expect("cache path has a parent")
        .join("memqd.sock")
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("serve") => serve(),
        Some("hook") => hook(),
        Some(_) => {
            let q = args.join(" ");
            match query(&q, DEFAULT_K) {
                Ok(hits) => {
                    print!("{hits}");
                    Ok(())
                }
                Err(e) => {
                    eprintln!("memq: {e}");
                    eprintln!("memq: is the daemon up?  memq serve &");
                    std::process::exit(1);
                }
            }
        }
        None => {
            eprintln!("usage: memq serve | memq hook | memq <query text>");
            std::process::exit(2);
        }
    }
}

// ---------------------------------------------------------------- daemon

fn serve() -> Result<()> {
    let sock = socket_path();
    // A socket file left by a killed daemon would make every client hang on
    // connect, so the bind owns the path unconditionally.
    let _ = std::fs::remove_file(&sock);
    std::fs::create_dir_all(sock.parent().unwrap())?;

    let t = std::time::Instant::now();
    let mut index = Index::build(std::path::Path::new(STORE)).context("building index")?;
    let graph = LinkGraph::build(std::path::Path::new(STORE)).context("building link graph")?;
    eprintln!(
        "memqd: {} chunks, {} linked files ready in {:?}",
        index.chunks.len(),
        graph.descriptions.len(),
        t.elapsed()
    );

    let listener = UnixListener::bind(&sock).with_context(|| format!("binding {sock:?}"))?;
    eprintln!("memqd: listening on {sock:?}");

    // Serial by design: a query is ~100 ms and the only client is a hook that
    // fires once per prompt. Concurrency here would buy nothing and would need
    // the model behind a lock anyway.
    for stream in listener.incoming() {
        let mut stream = match stream {
            Ok(s) => s,
            Err(e) => {
                eprintln!("memqd: accept failed: {e}");
                continue;
            }
        };
        if let Err(e) = handle(&mut stream, &mut index, &graph) {
            eprintln!("memqd: request failed: {e}");
        }
    }
    Ok(())
}

fn handle(stream: &mut UnixStream, index: &mut Index, graph: &LinkGraph) -> Result<()> {
    let mut line = String::new();
    BufReader::new(stream.try_clone()?).read_line(&mut line)?;
    let req: serde_json::Value = serde_json::from_str(line.trim())?;
    let q = req["q"].as_str().unwrap_or_default();
    let k = req["k"].as_u64().unwrap_or(DEFAULT_K as u64) as usize;

    let hits = index.search(q, k)?;
    let mut out = String::new();
    let mut matched: Vec<String> = Vec::new();
    for (score, c) in hits {
        if score < MIN_SCORE {
            continue;
        }
        let heading = if c.heading.is_empty() {
            "(top)"
        } else {
            &c.heading
        };
        // Drop the synthetic context header the chunker prepends.
        let body = c.text.splitn(2, '\n').nth(1).unwrap_or(&c.text);
        out.push_str(&format!("### {} — {heading} (score {score:.3})\n{body}\n\n", c.file));
        if !matched.contains(&c.file) {
            matched.push(c.file.clone());
        }
    }

    // One hop along the store's own links. Skipped when nothing scored — an
    // off-topic prompt must stay silent, and neighbours of nothing are noise.
    if !matched.is_empty() {
        let related = graph.neighbours(&matched, RELATED_LIMIT);
        if !related.is_empty() {
            out.push_str("### Linked from the above (names only — read if relevant)\n");
            for (name, desc) in related {
                out.push_str(&format!("- `{name}` — {desc}\n"));
            }
            out.push('\n');
        }
    }

    stream.write_all(out.as_bytes())?;
    stream.flush()?;
    Ok(())
}

// ---------------------------------------------------------------- client

fn query(q: &str, k: usize) -> Result<String> {
    let mut stream = UnixStream::connect(socket_path())?;
    let req = serde_json::json!({ "q": q, "k": k });
    writeln!(stream, "{req}")?;
    stream.shutdown(std::net::Shutdown::Write)?;
    let mut out = String::new();
    stream.read_to_string(&mut out)?;
    Ok(out)
}

/// Start a detached daemon and return immediately. The current prompt gets
/// nothing; the next one gets a warm index.
fn spawn_daemon() {
    let exe = match std::env::current_exe() {
        Ok(p) => p,
        Err(_) => return,
    };
    let _ = std::process::Command::new(exe)
        .arg("serve")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn();
}

// ---------------------------------------------------------------- hook

fn hook() -> Result<()> {
    let mut raw = String::new();
    std::io::stdin().read_to_string(&mut raw)?;
    let prompt = serde_json::from_str::<serde_json::Value>(&raw)
        .ok()
        .and_then(|v| v["prompt"].as_str().map(str::to_owned))
        .unwrap_or_default();

    let trimmed = prompt.trim();
    if trimmed.chars().count() < MIN_PROMPT_CHARS || trimmed.starts_with('/') {
        return Ok(());
    }

    let hits = match query(trimmed, DEFAULT_K) {
        Ok(h) => h,
        Err(_) => {
            // No daemon (first prompt after a reboot, or it died). Start one and
            // stay quiet — never fail a turn over a memory lookup.
            spawn_daemon();
            return Ok(());
        }
    };
    if hits.trim().is_empty() {
        return Ok(());
    }

    let context = format!(
        "Relevant entries from the pos108 memory store (retrieved automatically \
         for this prompt — they may be stale, verify before relying on them):\n\n{hits}"
    );
    let out = serde_json::json!({
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": context,
        }
    });
    println!("{out}");
    Ok(())
}
