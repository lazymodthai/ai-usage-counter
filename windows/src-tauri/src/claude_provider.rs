use crate::models::ProviderUsageResult;
use chrono::Utc;

pub const START_URL: &str = "https://claude.ai/";

// Fetches official usage from claude.ai's internal API, run inside a logged-in
// WebView so it inherits WebKit/WebView2 TLS + cookies (gets past Cloudflare):
//   GET /api/organizations            -> pick the org with the "chat" capability
//   GET /api/organizations/{id}/usage -> { five_hour: {utilization, resets_at},
//                                          seven_day: {utilization, resets_at} }
// Signals the result by navigating to tauri-result.internal.
pub const FETCH_JS: &str = r#"
(async () => {
    const nav = (params) => {
        window.location = 'https://tauri-result.internal/?' +
            new URLSearchParams({ id: '__REQ_ID__', ...params }).toString();
    };
    try {
        const headers = { 'Accept': 'application/json' };
        const orgRes = await fetch('/api/organizations', { credentials: 'include', headers });
        if (orgRes.status === 401 || orgRes.status === 403) { nav({ error: 'auth' }); return; }
        if (!orgRes.ok) { nav({ error: 'http_' + orgRes.status }); return; }
        const orgs = await orgRes.json();
        const org = Array.isArray(orgs) && orgs.length
            ? ((orgs.find(o => (o.capabilities || []).includes('chat')) || orgs[0]).uuid)
            : null;
        if (!org) { nav({ error: 'noorg' }); return; }
        const r = await fetch('/api/organizations/' + org + '/usage', { credentials: 'include', headers });
        if (r.status === 401 || r.status === 403) { nav({ error: 'auth' }); return; }
        if (!r.ok) { nav({ error: 'http_' + r.status }); return; }
        const data = await r.json();
        nav({ data: JSON.stringify(data) });
    } catch (e) {
        nav({ error: String(e) });
    }
})();
"#;

// ── Response parsing ─────────────────────────────────────────────────────────

pub fn parse_usage(raw: &str) -> Option<ProviderUsageResult> {
    let root: serde_json::Value = serde_json::from_str(raw).ok()?;

    let (session_pct, session_reset) = root
        .get("five_hour")
        .map(parse_window)
        .unwrap_or((None, None));
    let (weekly_pct, weekly_reset) = root
        .get("seven_day")
        .map(parse_window)
        .unwrap_or((None, None));

    if session_pct.is_none() && weekly_pct.is_none() {
        return None;
    }

    Some(ProviderUsageResult {
        session_pct,
        session_reset_secs: session_reset,
        weekly_pct,
        weekly_reset_secs: weekly_reset,
        quota_lanes: vec![],
        plan_name: None,
        is_auth_expired: false,
        fetched_at: Utc::now().to_rfc3339(),
    })
}

fn parse_window(d: &serde_json::Value) -> (Option<f64>, Option<f64>) {
    (provider_pct(d.get("utilization")), reset_secs(d.get("resets_at")))
}

// Mirrors the macOS providerPct: a fractional value <= 1 is a 0..1 ratio.
fn provider_pct(v: Option<&serde_json::Value>) -> Option<f64> {
    let n = provider_num(v)?;
    if n <= 1.0 && n.fract() != 0.0 {
        Some(n * 100.0)
    } else {
        Some(n)
    }
}

fn provider_num(v: Option<&serde_json::Value>) -> Option<f64> {
    let v = v?;
    v.as_f64().or_else(|| v.as_str().and_then(|s| s.parse::<f64>().ok()))
}

fn reset_secs(v: Option<&serde_json::Value>) -> Option<f64> {
    let s = v?.as_str()?;
    let dt = chrono::DateTime::parse_from_rfc3339(s).ok()?;
    Some((dt.timestamp() - Utc::now().timestamp()).max(0) as f64)
}
