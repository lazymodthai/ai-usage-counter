use crate::models::ProviderUsageResult;
use chrono::Utc;

pub const START_URL: &str = "https://chatgpt.com/";

// JS that fetches /backend-api/wham/usage via a Bearer token from /api/auth/session.
// Signals result by navigating to tauri-result.internal.
pub const FETCH_JS: &str = r#"
(async () => {
    const nav = (params) => {
        const base = 'https://tauri-result.internal/';
        window.location = base + '?' + new URLSearchParams({ id: '__REQ_ID__', ...params }).toString();
    };
    try {
        const sr = await fetch('/api/auth/session', { credentials: 'include' });
        if (!sr.ok) { nav({ error: 'auth' }); return; }
        const sj = await sr.json();
        const token = sj && sj.accessToken;
        if (!token) { nav({ error: 'auth' }); return; }
        const r = await fetch('https://chatgpt.com/backend-api/wham/usage', {
            credentials: 'include',
            headers: { 'Authorization': 'Bearer ' + token, 'Accept': 'application/json' }
        });
        if (r.status === 401 || r.status === 403) { nav({ error: 'auth' }); return; }
        if (!r.ok) { nav({ error: 'http_' + r.status }); return; }
        const data = await r.json();
        nav({ data: JSON.stringify(data) });
    } catch (e) {
        nav({ error: String(e) });
    }
})();
"#;

// Fallback: scrape the usage settings page.
pub const SCRAPE_JS: &str = r#"
(async () => {
    const nav = (params) => {
        const base = 'https://tauri-result.internal/';
        window.location = base + '?' + new URLSearchParams({ id: '__REQ_ID__', ...params }).toString();
    };
    try {
        if (!location.host.includes('chatgpt.com') || location.pathname.includes('/auth')) {
            nav({ error: 'auth' }); return;
        }
        function near(re) {
            const idx = document.body.innerText.replace(/ /g, ' ').search(re);
            if (idx < 0) return null;
            const seg = document.body.innerText.slice(idx, idx + 260);
            const m = seg.match(/(\d+(?:\.\d+)?)\s*%/);
            if (!m) return null;
            const around = seg.slice(Math.max(0, m.index - 40), m.index + 40);
            return { pct: parseFloat(m[1]), remaining: /left|remain/i.test(around) };
        }
        for (let i = 0; i < 8; i++) {
            const session = near(/5[\s-]?hour/i);
            const weekly = near(/week/i);
            if (session || weekly) {
                nav({ data: JSON.stringify({ session, weekly }) });
                return;
            }
            await new Promise(r => setTimeout(r, 1000));
        }
        nav({ error: 'notfound' });
    } catch (e) {
        nav({ error: String(e) });
    }
})();
"#;

// ── Response parsing ─────────────────────────────────────────────────────────

pub fn parse_wham(raw: &str) -> Option<ProviderUsageResult> {
    let root: serde_json::Value = serde_json::from_str(raw).ok()?;

    let rl = root.get("rate_limit")
        .or_else(|| root.get("rate_limits"))
        .unwrap_or(&root);

    fn find_window<'a>(rl: &'a serde_json::Value, keys: &[&str]) -> Option<&'a serde_json::Value> {
        keys.iter().find_map(|k| rl.get(*k))
    }

    let primary = find_window(rl, &["primary_window", "primary"]);
    let secondary = find_window(rl, &["secondary_window", "secondary"]);

    fn parse_window(d: &serde_json::Value) -> (Option<f64>, Option<f64>, Option<f64>) {
        let pct = ["used_percent", "usage_percent", "used_percentage"]
            .iter()
            .find_map(|k| d.get(*k).and_then(|v| v.as_f64()));

        let reset_secs = d.get("resets_in_seconds")
            .or_else(|| d.get("reset_after_seconds"))
            .or_else(|| d.get("resets_after_seconds"))
            .and_then(|v| v.as_f64())
            .or_else(|| {
                d.get("resets_at")
                    .or_else(|| d.get("reset_at"))
                    .and_then(|v| v.as_str())
                    .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                    .map(|dt| (dt.timestamp() - Utc::now().timestamp()).max(0) as f64)
            });

        let dur = d.get("limit_window_seconds")
            .or_else(|| d.get("window_seconds"))
            .and_then(|v| v.as_f64())
            .or_else(|| d.get("window_minutes").and_then(|v| v.as_f64()).map(|m| m * 60.0));

        (pct, reset_secs, dur)
    }

    let (p_pct, p_reset, p_dur) = primary.map(parse_window).unwrap_or_default();
    let (s_pct, s_reset, s_dur) = secondary.map(parse_window).unwrap_or_default();

    // primary = 5h window, secondary = weekly. Swap if durations say otherwise.
    let (session_pct, session_reset, weekly_pct, weekly_reset) =
        match (p_dur, s_dur) {
            (Some(pd), Some(sd)) if pd > sd => (s_pct, s_reset, p_pct, p_reset),
            _ => (p_pct, p_reset, s_pct, s_reset),
        };

    if session_pct.is_none() && weekly_pct.is_none() {
        return None;
    }

    let plan_name = root.get("plan_type").and_then(|v| v.as_str()).map(capitalize);

    Some(ProviderUsageResult {
        session_pct,
        session_reset_secs: session_reset,
        weekly_pct,
        weekly_reset_secs: weekly_reset,
        quota_lanes: vec![],
        plan_name,
        is_auth_expired: false,
        fetched_at: Utc::now().to_rfc3339(),
    })
}

pub fn parse_scrape(raw: &str) -> Option<ProviderUsageResult> {
    let payload: serde_json::Value = serde_json::from_str(raw).ok()?;

    fn used_pct(v: Option<&serde_json::Value>) -> Option<f64> {
        let d = v?.as_object()?;
        let pct = d.get("pct").and_then(|p| p.as_f64())?;
        let remaining = d.get("remaining").and_then(|r| r.as_bool()).unwrap_or(false);
        Some(if remaining { (100.0 - pct).max(0.0) } else { pct })
    }

    let session_pct = used_pct(payload.get("session"));
    let weekly_pct = used_pct(payload.get("weekly"));

    if session_pct.is_none() && weekly_pct.is_none() {
        return None;
    }

    Some(ProviderUsageResult {
        session_pct,
        weekly_pct,
        fetched_at: Utc::now().to_rfc3339(),
        ..Default::default()
    })
}

fn capitalize(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        None => String::new(),
        Some(f) => f.to_uppercase().to_string() + c.as_str(),
    }
}
