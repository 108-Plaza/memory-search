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
use memory_search::{socket_path, store_stamp, Index, LinkGraph, STORE};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};

/// Below this cosine score a hit is noise; injecting it costs context and
/// teaches the model to ignore the block. Calibrated against the store — see
/// `docs/HOOK.md`.
///
/// Lowered 0.55 → 0.52 → **0.53** on 2026-08-11. 0.55 sat *inside* the band of
/// true hits: real answers scored 0.543–0.677, so the cutoff cost recall. It
/// dropped `pos108-escpos-thai-encoding` — ranked **first** for a
/// garbled-printing question at 0.543 — and with it the whole block, since
/// nothing else cleared the bar.
///
/// ⚠️ The usable window is **~0.03 wide** and this number sits in the middle of
/// it, deliberately. Measured against 9 off-topic controls, the loudest
/// correctly-rejected one is a casual acknowledgement at **0.514**; the lowest
/// true hit is **0.543**. So 0.515–0.543 all behave identically on this
/// evidence, and 0.53 is the midpoint — ~0.016 of air on the noise side,
/// ~0.013 on the recall side. Anything outside that range trades one error for
/// the other. Re-run the controls before touching it; height alone cannot do
/// better than this — see `MIN_MARGIN` and the prose case recorded with it.
const MIN_SCORE: f32 = 0.53;

/// Prompts shorter than this are greetings, acknowledgements and `/commands`.
/// Embedding them returns whatever is nearest, which is worse than nothing.
const MIN_PROMPT_CHARS: usize = 12;

/// Required gap between the best score and the store's median score.
///
/// `MIN_SCORE` alone does not work, measured on the first live firing
/// (2026-08-09): a pasted terminal transcript scored **0.605** against an
/// unrelated file — above the cutoff, and inside the 0.574–0.726 band of real
/// questions. What separates them is not height but *shape*. A real question
/// peaks over the store (margin 0.144–0.303); text that is merely text sits
/// near everything at once (that paste: **0.121**; small talk: 0.080).
///
/// 0.13 splits a genuinely narrow gap — the tightest true positive measured is
/// 0.144 (a Thai receipt-encoding question) against that paste's 0.121. If real
/// questions start being dropped, this is the first number to look at.
///
/// ⚠️ **Known escape, and neither gate can close it.** A paragraph of ordinary
/// business prose ("modest increase in customer satisfaction across all
/// regions… the new onboarding process piloted last spring") scores **0.558**
/// against `customer-platform-repo` AND peaks, so it is injected. It predates
/// today's lowering — 0.558 cleared the old 0.55 cutoff too — and height
/// cannot separate it, since 0.558 sits mid-band among real answers. It is not
/// really a false *match* either: the store genuinely holds customer-platform
/// memories and the paragraph is genuinely about that. The cost is one
/// irrelevant block on a prompt that was pasted, not asked. Closing it needs a
/// different axis (is this a QUESTION?), not a different threshold.
const MIN_MARGIN: f32 = 0.13;

/// How many **files** to inject. Chunks are deduped to one per file, so this is
/// three distinct memories rather than three passages that may all come from
/// the same one — measured 2026-08-11, a single query spent every slot on three
/// chunks of `identity-platform-auth-history`, which is the whole hook budget
/// on one memory.
const DEFAULT_K: usize = 3;

/// Chunks scored before dedup. Deep enough that `DEFAULT_K` distinct files
/// survive even when the leaders are all sections of one hub file; the scoring
/// itself is over the whole store either way, so this only bounds the walk.
const POOL: usize = 40;

/// Neighbours are one line each, but they are also the cheapest thing to
/// over-produce — a well-linked hub can reach 20 files. Five is enough to name
/// the ones a human would have thought of.
const RELATED_LIMIT: usize = 5;

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

// Freshness lives in `memory_search::store_stamp` — the MCP server re-stats the
// same way. The daemon builds its index once, so before that existed a memory
// written after boot was invisible until someone remembered to restart it,
// which is the same failure the whole hook exists to remove. Two hub files
// written on 2026-08-09 were unsearchable for exactly that reason.
// Stat-ing the store is ~1 ms against a ~30 ms query — cheap per request.

fn serve() -> Result<()> {
    let sock = socket_path();
    // A socket file left by a killed daemon would make every client hang on
    // connect, so the bind owns the path unconditionally.
    let _ = std::fs::remove_file(&sock);
    std::fs::create_dir_all(sock.parent().unwrap())?;

    let t = std::time::Instant::now();
    let mut stamp = store_stamp();
    let mut index = Index::build(std::path::Path::new(STORE)).context("building index")?;
    let mut graph = LinkGraph::build(std::path::Path::new(STORE)).context("building link graph")?;
    eprintln!(
        "memqd: {} chunks, {} linked files ready in {:?}",
        index.chunks.len(),
        graph.descriptions.len(),
        t.elapsed()
    );

    let listener = UnixListener::bind(&sock).with_context(|| format!("binding {sock:?}"))?;
    eprintln!("memqd: listening on {sock:?}");

    // Serial by design: a query is ~30 ms and the model would need a lock
    // anyway, so concurrency buys almost nothing. Since 2026-08-11 the clients
    // are the hook AND every session's MCP server, so requests do queue — at
    // 30 ms that is invisible, but a reindex after a large write blocks the lot
    // for seconds. That is the price of one resident model instead of one per
    // session (~1.78 GB each).
    for stream in listener.incoming() {
        let mut stream = match stream {
            Ok(s) => s,
            Err(e) => {
                eprintln!("memqd: accept failed: {e}");
                continue;
            }
        };
        // Pick up memories written since boot. `refresh` re-embeds only what
        // changed INTO the loaded model — a second `Index::build` here would
        // reload BGE-M3 every time (~1 s and ~200 MB of churn) for nothing.
        // A failed rebuild keeps serving the old index: stale beats silent.
        let now = store_stamp();
        if now > stamp {
            let t = std::time::Instant::now();
            match (
                index.refresh(std::path::Path::new(STORE)),
                LinkGraph::build(std::path::Path::new(STORE)),
            ) {
                (Ok(()), Ok(g)) => {
                    graph = g;
                    stamp = now;
                    eprintln!(
                        "memqd: store changed — reindexed {} chunks in {:?}",
                        index.chunks.len(),
                        t.elapsed()
                    );
                }
                _ => eprintln!("memqd: reindex failed, serving the previous index"),
            }
        }

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

    // `"raw": true` — the MCP server's mode. It shares the resident model but
    // NOT the hook's editorial policy: an agent that chose to search wants every
    // hit with its score and formats them itself, where the hook is spending a
    // context budget nobody asked for and must gate hard. Same index, different
    // contract, so the gates and the file-dedup below stay on the hook's path.
    if req["raw"].as_bool().unwrap_or(false) {
        return handle_raw(stream, index, graph, q, k);
    }

    // Scored over the whole store regardless of the pool — the median, and so
    // the margin gate, is unaffected by how deep we walk.
    let (hits, median) = index.search_scored(q, POOL.max(k))?;
    let mut out = String::new();
    let mut matched: Vec<String> = Vec::new();

    // Flat distribution ⇒ the prompt is not *about* anything in the store.
    // Judged on the best hit, so one strong match still carries weaker ones.
    let peaked = hits.first().is_some_and(|(s, _)| *s - median >= MIN_MARGIN);

    if peaked {
        for (score, c) in hits {
            // Sorted descending, so the first sub-threshold hit ends it.
            if score < MIN_SCORE || matched.len() == k {
                break;
            }
            // One chunk per file: the best-scoring section speaks for it.
            if matched.contains(&c.file) {
                continue;
            }
            let heading = if c.heading.is_empty() {
                "(top)"
            } else {
                &c.heading
            };
            // Drop the synthetic context header the chunker prepends.
            let body = c.text.splitn(2, '\n').nth(1).unwrap_or(&c.text);
            out.push_str(&format!(
                "### {} — {heading} (score {score:.3})\n{body}\n\n",
                c.file
            ));
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

/// Ungated results as one JSON line: `{hits:[{file,heading,score,body}],
/// related:[{name,desc}]}`. No `MIN_SCORE` and no margin test — an agent that
/// chose to search wants to see what there is and judge for itself.
///
/// It IS deduped to one chunk per file, same as the hook. That was left off at
/// first, on the theory that two sections of the right memory are useful rather
/// than wasteful. Measured 2026-08-11 and the theory lost: **11 of 12 bench
/// queries had a file take more than one of five slots**, and it cost a real
/// answer — `tenant-decommission-two-phase` (file-rank 4) fell off the list
/// because `enrol-must-show-url-shop-package` occupied two. `k` means files on
/// both paths now, and an agent that wants more sections can raise it.
///
/// `related` follows the store's own `[[wikilinks]]` one hop out from the files
/// that matched, which is context no cosine score ranks.
fn handle_raw(
    stream: &mut UnixStream,
    index: &mut Index,
    graph: &LinkGraph,
    q: &str,
    k: usize,
) -> Result<()> {
    let (scored, _median) = index.search_scored(q, POOL.max(k))?;
    let mut matched: Vec<String> = Vec::new();
    let mut hits: Vec<serde_json::Value> = Vec::new();
    for (score, c) in scored {
        if matched.len() == k {
            break;
        }
        if matched.contains(&c.file) {
            continue;
        }
        matched.push(c.file.clone());
        hits.push(serde_json::json!({
            "file": c.file,
            "heading": c.heading,
            "score": score,
            // Drop the synthetic context header the chunker prepends.
            "body": c.text.splitn(2, '\n').nth(1).unwrap_or(&c.text),
        }));
    }

    let related: Vec<serde_json::Value> = graph
        .neighbours(&matched, RELATED_LIMIT)
        .into_iter()
        .map(|(name, desc)| serde_json::json!({ "name": name, "desc": desc }))
        .collect();

    let body = serde_json::json!({ "hits": hits, "related": related });
    writeln!(stream, "{body}")?;
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
    // Pasted shell transcripts are the one input shape observed to beat the
    // score cutoff (2026-08-09). The margin test catches them, but barely, so
    // this names them outright: a `user@host … %` or `… $ ` line is a paste,
    // and a real question essentially never contains one.
    if trimmed
        .lines()
        .any(|l| l.contains('@') && (l.contains("% ") || l.contains("$ ")))
    {
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
