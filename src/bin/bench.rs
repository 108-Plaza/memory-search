// Read queries (one per line) from stdin; print top-5 FILES (chunk-dedup, best
// score per file) as: query \t file:score,file:score,...
use memory_search::{Index, STORE};
use std::io::BufRead;
fn main() -> anyhow::Result<()> {
    let mut idx = Index::build(std::path::Path::new(STORE))?;
    for line in std::io::stdin().lock().lines() {
        let q = line?;
        if q.trim().is_empty() { continue; }
        let hits = idx.search(&q, 40)?;
        let mut files: Vec<(String, f32)> = Vec::new();
        for (s, c) in hits {
            if !files.iter().any(|(f, _)| *f == c.file) {
                files.push((c.file.clone(), s));
            }
            if files.len() == 5 { break; }
        }
        let row: Vec<String> = files.iter().map(|(f, s)| format!("{f}:{s:.3}")).collect();
        println!("{q}\t{}", row.join(","));
    }
    Ok(())
}
