use std::fs;
use std::io::{BufRead, BufReader};
use std::path::PathBuf;

use chrono::{DateTime, Datelike, Duration, Local, TimeZone, Utc};

use crate::models::{ClaudeLocalUsage, JsonlEntry, TokenUsage};

const DEFAULT_SESSION_LIMIT: i64 = 8_800_000;
const DEFAULT_WEEKLY_LIMIT: i64 = 88_000_000;
const BLOCK_SECS: i64 = 5 * 3600;

pub fn compute() -> ClaudeLocalUsage {
    let now = Utc::now();
    let mut entries = collect_entries();

    if entries.is_empty() {
        return ClaudeLocalUsage {
            session_limit: DEFAULT_SESSION_LIMIT,
            weekly_limit: DEFAULT_WEEKLY_LIMIT,
            is_local: true,
            fetched_at: now.to_rfc3339(),
            ..Default::default()
        };
    }

    entries.sort_by_key(|(ts, _)| *ts);

    // Build 5-hour billing blocks: (block_start, last_activity, total_tokens)
    let block_dur = Duration::seconds(BLOCK_SECS);
    let mut blocks: Vec<(DateTime<Utc>, DateTime<Utc>, i64)> = Vec::new();

    for (ts, tokens) in &entries {
        let mut placed = false;
        for b in &mut blocks {
            if *ts >= b.0 && *ts < b.0 + block_dur {
                if *ts > b.1 {
                    b.1 = *ts;
                }
                b.2 += tokens;
                placed = true;
                break;
            }
        }
        if !placed {
            blocks.push((*ts, *ts, *tokens));
        }
    }

    // Active block: reset time still in future AND last activity within 5h
    let active = blocks
        .iter()
        .filter(|b| {
            let reset = b.0 + block_dur;
            reset > now && now.signed_duration_since(b.1).num_seconds() < BLOCK_SECS
        })
        .max_by_key(|b| b.0);

    let (session_tokens, session_reset_secs, session_active) = match active {
        Some(b) => {
            let reset_ms = ((b.0 + block_dur) - now).num_milliseconds();
            (b.2, (reset_ms as f64 / 1000.0).max(0.0), true)
        }
        None => (0, 0.0, false),
    };

    // Weekly: tokens since Monday midnight (local)
    let week_start = monday_midnight_utc(now);
    let weekly_tokens: i64 = entries
        .iter()
        .filter(|(ts, _)| *ts >= week_start)
        .map(|(_, t)| t)
        .sum();

    let next_monday = week_start + Duration::days(7);
    let weekly_reset_secs =
        ((next_monday - now).num_milliseconds() as f64 / 1000.0).max(0.0);

    ClaudeLocalUsage {
        session_tokens,
        session_limit: DEFAULT_SESSION_LIMIT,
        session_fraction: clamp01(session_tokens as f64 / DEFAULT_SESSION_LIMIT as f64),
        session_reset_secs,
        session_active,
        weekly_tokens,
        weekly_limit: DEFAULT_WEEKLY_LIMIT,
        weekly_fraction: clamp01(weekly_tokens as f64 / DEFAULT_WEEKLY_LIMIT as f64),
        weekly_reset_secs,
        is_local: true,
        fetched_at: now.to_rfc3339(),
    }
}

fn clamp01(v: f64) -> f64 {
    v.clamp(0.0, 1.0)
}

fn monday_midnight_utc(now: DateTime<Utc>) -> DateTime<Utc> {
    let local = now.with_timezone(&Local);
    let days_since_monday = local.weekday().num_days_from_monday() as i64;
    let monday = local.date_naive() - Duration::days(days_since_monday);
    Local
        .from_local_datetime(&monday.and_hms_opt(0, 0, 0).unwrap())
        .unwrap()
        .with_timezone(&Utc)
}

// ── File collection ─────────────────────────────────────────────────────────

fn collect_entries() -> Vec<(DateTime<Utc>, i64)> {
    let base = match dirs::home_dir() {
        Some(h) => h.join(".claude").join("projects"),
        None => return Vec::new(),
    };
    if !base.exists() {
        return Vec::new();
    }
    let mut out = Vec::new();
    visit_dir(&base, &mut out);
    out
}

fn visit_dir(dir: &PathBuf, out: &mut Vec<(DateTime<Utc>, i64)>) {
    let rd = match fs::read_dir(dir) {
        Ok(r) => r,
        Err(_) => return,
    };
    for entry in rd.flatten() {
        let path = entry.path();
        if path.is_dir() {
            visit_dir(&path, out);
        } else if path.extension().and_then(|s| s.to_str()) == Some("jsonl") {
            parse_file(&path, out);
        }
    }
}

fn parse_file(path: &PathBuf, out: &mut Vec<(DateTime<Utc>, i64)>) {
    let file = match fs::File::open(path) {
        Ok(f) => f,
        Err(_) => return,
    };
    for line in BufReader::new(file).lines().flatten() {
        if line.trim().is_empty() {
            continue;
        }
        if let Ok(entry) = serde_json::from_str::<JsonlEntry>(&line) {
            if entry.entry_type.as_deref() != Some("assistant") {
                continue;
            }
            let ts = entry
                .timestamp
                .as_deref()
                .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
                .map(|dt| dt.with_timezone(&Utc));
            let tokens = extract_tokens(&entry);
            if let (Some(ts), t) = (ts, tokens) {
                if t > 0 {
                    out.push((ts, t));
                }
            }
        }
    }
}

fn extract_tokens(entry: &JsonlEntry) -> i64 {
    sum_usage(entry.usage.as_ref())
        .or_else(|| entry.message.as_ref().and_then(|m| sum_usage(m.usage.as_ref())))
        .unwrap_or(0)
}

fn sum_usage(u: Option<&TokenUsage>) -> Option<i64> {
    let u = u?;
    let total = u.input_tokens.unwrap_or(0)
        + u.output_tokens.unwrap_or(0)
        + u.cache_creation_input_tokens.unwrap_or(0)
        + u.cache_read_input_tokens.unwrap_or(0);
    if total > 0 { Some(total) } else { None }
}
