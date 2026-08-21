//! `memq` — make memory retrieval automatic instead of optional.
//!
//! The MCP tool only fires when an agent *decides* to search, and the measured
//! failure mode is precisely that it does not feel the need to (see RULE 0 in
//! `~/IdeaProjects/108-Ting-Ecosystem/pos/CLAUDE.md`). This binary removes the decision: a `UserPromptSubmit`
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
use memory_search::{socket_path, store_stamp, Index, LinkGraph, Reindex, WarmCache, STORE};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::mpsc;
use std::time::Duration;

/// How long the idle daemon waits for a client before re-stat-ing the store.
/// Short enough that a memory written between two prompts is usually already
/// embedded by the time it is searched for, long enough to be one wake-up a
/// second on a machine doing nothing.
const IDLE_POLL: Duration = Duration::from_secs(1);

/// Deadlines on a served connection. A request is one line sent immediately
/// after connect and one response written back; both are sub-millisecond on a
/// socket with a live peer.
const CLIENT_READ_TIMEOUT: Duration = Duration::from_secs(5);
const CLIENT_WRITE_TIMEOUT: Duration = Duration::from_secs(5);

/// Deadline for `memq hook` / `memq <text>` waiting on the daemon.
const QUERY_TIMEOUT: Duration = Duration::from_secs(5);

/// How long a request will wait for an in-flight reindex before being answered
/// from the index as it stands.
///
/// This is the seam between two invariants that pull opposite ways. "A memory
/// written now is searchable now" is pinned by `scripts/freshness-test.py` and
/// was a real user-visible bug when it broke; on an unloaded machine a
/// person-sized write embeds in 0.2-1.0 s, so waiting buys it outright. What
/// this refuses to buy is the pathological case — 11 s per chunk on a machine
/// at load 157, where waiting for the whole reindex is what made a search hang
/// for 28 minutes. Past the grace the answer is stale rather than absent, which
/// is the trade this daemon already makes everywhere else.
const FRESHNESS_GRACE: Duration = Duration::from_secs(3);

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
    std::fs::create_dir_all(sock.parent().unwrap())?;

    // Ask before taking the path. `remove_file` below exists for the socket a
    // killed daemon leaves behind and cannot tell that case from a healthy one,
    // so an unconditional bind lets any stray `memq serve` UNLINK the running
    // daemon's socket: the good daemon keeps its index and its now-nameless
    // listener, and every client after that gets ECONNREFUSED. Measured live
    // 2026-08-14 — three daemons deep, socket mtime moving every few seconds,
    // 2.3 GB of resident model each.
    if UnixStream::connect(&sock).is_ok() {
        eprintln!("memqd: another daemon already answers on {sock:?} — exiting");
        return Ok(());
    }
    // Nothing answered: the file, if any, is a corpse.
    let _ = std::fs::remove_file(&sock);

    // Bind BEFORE building the index. A client that finds no socket starts a
    // daemon of its own (see `start_daemon` in the MCP server), and the index
    // build is a long window with no socket in it — so a restart under load
    // grew a SECOND resident BGE-M3, observed live on 2026-08-14: launchd's
    // daemon came up at 10:22:01, a rival at 10:23:04, 2.3 GB each and both
    // fighting for the same cores. Binding first closes the window: the client
    // connects and waits for the answer instead of forking the problem.
    let listener = UnixListener::bind(&sock).with_context(|| format!("binding {sock:?}"))?;
    eprintln!("memqd: listening on {sock:?}");

    // Accept on its own thread. The main thread stays the ONLY owner of the
    // model — the index is not shared, it is scheduled — but a client no longer
    // waits on the kernel backlog while embedding runs, and the loop below can
    // ask "is anyone waiting?" without blocking. It also means connections that
    // arrive during the build below are queued, not refused.
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            match stream {
                Ok(s) => {
                    if tx.send(s).is_err() {
                        return; // main loop is gone
                    }
                }
                Err(e) => eprintln!("memqd: accept failed: {e}"),
            }
        }
    });

    let t = std::time::Instant::now();
    let (mut index, missing) =
        Index::build_cached(std::path::Path::new(STORE)).context("building index")?;
    let mut graph = LinkGraph::build(std::path::Path::new(STORE)).context("building link graph")?;
    eprintln!(
        "memqd: {} chunks, {} linked files ready in {:?}{}",
        index.chunks.len(),
        graph.descriptions.len(),
        t.elapsed(),
        if missing > 0 {
            format!(" ({missing} not yet embedded — filling in the background)")
        } else {
            String::new()
        }
    );

    // Deliberately behind every possible store mtime, so the loop below starts
    // a background pass at once and picks up whatever the cache was missing.
    let mut stamp = std::time::SystemTime::UNIX_EPOCH;

    // Reindexing used to run inside the accept loop, so every client waited for
    // it. That is fine at the 1-5 s it normally costs and ruinous at what it
    // can cost on a loaded machine — 1685 s, measured 2026-08-14 (see
    // `embed_threads` for the CPU side of that number). The work is the same;
    // what changed is that it now happens in the GAPS between requests, a batch
    // at a time, and a waiting client always preempts it.
    let mut pending: Option<Pending> = None;
    // Outlives any single pass: embeddings from a pass that was abandoned and
    // whose replacement could not start yet.
    let mut carried: Option<Carried> = None;
    loop {
        // A waiting client wins, always.
        match rx.try_recv() {
            Ok(mut stream) => {
                serve_one(
                    &mut stream,
                    &mut index,
                    &mut graph,
                    &mut stamp,
                    &mut pending,
                    &mut carried,
                );
                continue;
            }
            Err(mpsc::TryRecvError::Empty) => {}
            Err(mpsc::TryRecvError::Disconnected) => break,
        }

        // Nobody waiting: pick up anything written since the last pass.
        begin_if_changed(&stamp, &mut pending, &mut carried);

        // Nobody waiting and there IS work: one batch, then round again.
        if pending.is_some() {
            drive_reindex(&mut index, &mut graph, &mut stamp, &mut pending, None);
            continue;
        }

        // Idle. Block for the next client, but wake often enough that a memory
        // written while the machine is quiet is embedded BEFORE anyone searches
        // for it — which is the point of moving this off the request path.
        match rx.recv_timeout(IDLE_POLL) {
            Ok(mut stream) => serve_one(
                &mut stream,
                &mut index,
                &mut graph,
                &mut stamp,
                &mut pending,
                &mut carried,
            ),
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }
    Ok(())
}

/// Start a reindex if there is one to start: the store has moved since `stamp`,
/// a pass in flight has been overtaken by a newer store, or an earlier attempt
/// failed and left its embeddings in `carried`.
///
/// An overtaken pass is abandoned rather than finished — completing it installs
/// a snapshot that is already out of date, which is how a memory deleted
/// mid-reindex kept answering. Its embeddings and its clock move to the
/// replacement, so the restart costs no model work and stays honest about how
/// long the whole chain has run.
///
/// Reads the store and the embedding cache; does no model work, so it is safe
/// on the request path.
fn begin_if_changed(
    stamp: &std::time::SystemTime,
    pending: &mut Option<Pending>,
    carried: &mut Option<Carried>,
) {
    let now = store_stamp();
    if let Some(p) = pending.as_ref() {
        if now <= p.stamp {
            return; // in flight and still current
        }
        let p = pending.take().expect("just matched Some");
        *carried = Some(Carried {
            cache: Some(p.work.into_warm()),
            started: p.started,
            restarts: p.restarts + 1,
        });
    } else if carried.is_none() && now <= *stamp {
        return; // nothing in flight, nothing owed, nothing new
    }

    let begun = match carried.as_mut() {
        Some(c) => Index::begin_reindex_with(std::path::Path::new(STORE), &mut c.cache),
        None => Index::begin_reindex(std::path::Path::new(STORE)),
    };
    match begun {
        Ok(work) => {
            eprintln!(
                "memqd: store changed — embedding {} chunks in the background",
                work.work()
            );
            // Adopt the abandoned pass's clock, or start one if this is the
            // head of the chain.
            let (started, restarts) = match carried.take() {
                Some(c) => (c.started, c.restarts),
                None => (std::time::Instant::now(), 0),
            };
            *pending = Some(Pending {
                stamp: now,
                started,
                restarts,
                work,
            });
        }
        // Serving the previous index is right: stale beats silent. `stamp` is
        // left alone so the next pass retries, and `carried` still holds the
        // embeddings — `begin_reindex_with` takes them only once the store has
        // actually been read, so a failed start costs nothing but the attempt.
        // It used to cost the whole pass: the cache was surrendered before the
        // outcome was known, and nothing had persisted it.
        Err(e) => eprintln!("memqd: reindex could not start ({e}); serving the previous index"),
    }
}

/// Answer one client, first giving any in-flight reindex up to
/// [`FRESHNESS_GRACE`] to land so the answer includes what was just written.
fn serve_one(
    stream: &mut UnixStream,
    index: &mut Index,
    graph: &mut LinkGraph,
    stamp: &mut std::time::SystemTime,
    pending: &mut Option<Pending>,
    carried: &mut Option<Carried>,
) {
    // Re-stat before answering. Checking only when the loop finds itself idle
    // is not enough and `freshness-test.py` says so: a client that is already
    // queued when a memory lands gets served from the index as it was, and the
    // change is not even noticed until the NEXT pass. Measured — the daemon
    // path failed create, edit and delete while the MCP path, arriving a beat
    // later, passed all three. ~1 ms against a ~30 ms query.
    begin_if_changed(stamp, pending, carried);
    if pending.is_some() {
        drive_reindex(
            index,
            graph,
            stamp,
            pending,
            Some(std::time::Instant::now() + FRESHNESS_GRACE),
        );
    }
    if let Err(e) = handle(stream, index, graph) {
        eprintln!("memqd: request failed: {e:#}");
    }
}

/// Push an in-flight reindex forward: to `deadline` if given, otherwise exactly
/// one batch. Committing the result is the same either way — the swap happens
/// only on success, so a failure leaves the previous index serving.
fn drive_reindex(
    index: &mut Index,
    graph: &mut LinkGraph,
    stamp: &mut std::time::SystemTime,
    pending: &mut Option<Pending>,
    deadline: Option<std::time::Instant>,
) {
    loop {
        let Some(p) = pending.as_mut() else { return };
        match index.step_reindex(&mut p.work) {
            Ok(true) => {
                let p = pending.take().expect("just matched Some");
                let elapsed = p.started.elapsed();
                let restarts = p.restarts;
                let stamp_at_start = p.stamp;
                match (
                    index.apply(p.work),
                    LinkGraph::build(std::path::Path::new(STORE)),
                ) {
                    (Ok(()), Ok(g)) => {
                        *graph = g;
                        *stamp = stamp_at_start;
                        eprintln!(
                            "memqd: reindexed {} chunks in {:?}{}",
                            index.chunks.len(),
                            elapsed,
                            match restarts {
                                0 => String::new(),
                                n => format!(" (restarted {n}x)"),
                            }
                        );
                    }
                    _ => eprintln!("memqd: reindex failed, serving the previous index"),
                }
                return;
            }
            Ok(false) => match deadline {
                Some(d) if std::time::Instant::now() < d => continue,
                _ => return,
            },
            Err(e) => {
                eprintln!("memqd: reindex failed, serving the previous index: {e:#}");
                *pending = None;
                return;
            }
        }
    }
}

/// A background reindex in flight, with what it takes to log and commit it.
struct Pending {
    /// The store stamp this pass read the store at, committed only on success.
    /// A write that lands past it does not wait for the next pass: this one is
    /// abandoned and restarted from the newer store, carrying its embeddings
    /// along — see [`begin_if_changed`].
    stamp: std::time::SystemTime,
    /// When the FIRST pass in this chain started, not this one. Restarts are
    /// driven by store writes, so restarting the clock with them under-reports
    /// the wait exactly when it is longest — and this log is the only
    /// instrument for the 1685 s case described above.
    started: std::time::Instant,
    /// How many times this chain has been abandoned and restarted. Kept apart
    /// from `started` so the log can say both.
    restarts: usize,
    work: Reindex,
}

/// An abandoned pass's embeddings and clock, waiting to be adopted by its
/// replacement. Lives in [`serve`] rather than inside [`begin_if_changed`] so
/// that a start which fails leaves it here for the next attempt instead of
/// dropping it — `Index::apply` is the only thing that persists, and a pass
/// that never starts never reaches it.
struct Carried {
    /// `None` only for the instant between a successful `begin_reindex_with`
    /// taking it and the caller taking the rest of this struct.
    cache: Option<WarmCache>,
    started: std::time::Instant,
    restarts: usize,
}

fn handle(stream: &mut UnixStream, index: &mut Index, graph: &LinkGraph) -> Result<()> {
    // One serial loop serves every client, so a peer that connects and then
    // sends nothing would hold ALL of them — forever, on a blocking read with
    // no deadline. Requests are one short line written immediately after
    // connect; anything slower than this is not a client.
    // macOS fails setsockopt with EINVAL once the peer is gone, which makes this
    // a free liveness check: a client that already timed out, or a `memq hook`
    // that exited, is a corpse and not a request. Skip it silently rather than
    // logging a failure and spending a search on nobody.
    if stream.set_read_timeout(Some(CLIENT_READ_TIMEOUT)).is_err()
        || stream
            .set_write_timeout(Some(CLIENT_WRITE_TIMEOUT))
            .is_err()
    {
        return Ok(());
    }
    let mut line = String::new();
    BufReader::new(stream.try_clone().context("try_clone")?)
        .read_line(&mut line)
        .context("read_line")?;
    let req: serde_json::Value = serde_json::from_str(line.trim()).context("parse request")?;
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

    stream
        .write_all(out.as_bytes())
        .context("write hook body")?;
    stream.flush().context("flush hook")?;
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
    let (scored, _median) = index
        .search_scored(q, POOL.max(k))
        .context("search_scored")?;
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
    writeln!(stream, "{body}").context("write raw body")?;
    stream.flush().context("flush raw")?;
    Ok(())
}

// ---------------------------------------------------------------- client

fn query(q: &str, k: usize) -> Result<String> {
    let mut stream = UnixStream::connect(socket_path())?;
    // `memq hook` runs on the user's prompt with a 5 s harness timeout, so an
    // unbounded read here spends that budget doing nothing. Fail fast and let
    // the hook emit no context — which is its documented behaviour when the
    // daemon is not answering.
    stream.set_read_timeout(Some(QUERY_TIMEOUT))?;
    stream.set_write_timeout(Some(QUERY_TIMEOUT))?;
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
            // Two very different failures arrive here and only one wants a new
            // daemon. "Nothing is listening" is the first prompt after a reboot
            // — start one and stay quiet, never fail a turn over a memory
            // lookup. "Listening, but did not answer inside QUERY_TIMEOUT" is a
            // daemon that is merely busy, and spawning a rival for THAT makes it
            // worse: the rival takes the socket path and orphans a perfectly
            // good index. Adding the timeout without this check is what turned
            // one slow daemon into three on 2026-08-14.
            if UnixStream::connect(socket_path()).is_err() {
                spawn_daemon();
            }
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
