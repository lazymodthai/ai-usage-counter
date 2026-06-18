use crate::models::{ProviderUsageResult, QuotaLaneRaw};
use chrono::Utc;

pub const START_URL: &str = "https://gemini.google.com/app";

// Tried in order — matches the macOS GeminiProvider fallback list.
// The first entry equals START_URL (already loaded), the rest are navigated to.
pub const USAGE_URLS: &[&str] = &[
    "https://gemini.google.com/app",
    "https://gemini.google.com/app/settings",
    "https://gemini.google.com/app/settings/usage",
    "https://gemini.google.com/app/usage",
];

// JS that scrapes gemini.google.com's Usage Limits view.
// No public JSON API exists; Gemini uses obfuscated batchexecute RPCs.
// Ported from GeminiProvider.swift.
pub const FETCH_JS: &str = r#"
(async () => {
    const nav = (params) => {
        window.location = 'https://tauri-result.internal/?' +
            new URLSearchParams({ id: '__REQ_ID__', ...params }).toString();
    };
    try {
        if (location.host.includes('accounts.google.com')) { nav({ error: 'auth' }); return; }
        if (!location.host.includes('gemini.google.com')) { nav({ error: 'auth' }); return; }

        function pageText() { return (document.body.innerText || '').replace(/ /g, ' '); }
        function normalizePct(value, text) {
            const pct = parseFloat(value);
            return /left|remain/i.test(text) ? Math.max(0, 100 - pct) : pct;
        }
        function near(text, re) {
            const idx = text.search(re);
            if (idx < 0) return null;
            const seg = text.slice(idx, idx + 300);
            const m = seg.match(/(\d+(?:\.\d+)?)\s*%/);
            if (!m) return null;
            const around = seg.slice(Math.max(0, m.index - 40), m.index + 40);
            const out = { pct: parseFloat(m[1]), remaining: /left|remain/i.test(around) };
            const rm = seg.match(/resets?[^\n.;]{0,80}/i);
            if (rm) out.reset = rm[0];
            return out;
        }
        function titleCase(s) {
            return s.replace(/\s+/g, ' ').replace(/^(gemini\s*)+/i, 'Gemini ').trim();
        }
        function quotaLanes(text) {
            const lines = text.split('\n').map(s => s.trim()).filter(Boolean);
            const lanes = [];
            let group = null;
            for (let i = 0; i < lines.length; i++) {
                const line = lines[i];
                if (/^(Gemini Flash|Gemini Pro|Claude|OpenAI|GPT)$/i.test(line)
                    && !(/(\d+(?:\.\d+)?)\s*%/.test(line))
                    && line.length < 80) {
                    group = titleCase(line); continue;
                }
                const window = lines.slice(i, i + 4).join(' ');
                const pct = window.match(/(\d+(?:\.\d+)?)\s*%/);
                if (!pct) continue;
                const model = line.match(/((?:Gemini|Claude|GPT|OpenAI)[A-Za-z0-9 ._-]*(?:\([^)]*\))?)/i)
                           || window.match(/((?:Gemini|Claude|GPT|OpenAI)[A-Za-z0-9 ._-]*(?:\([^)]*\))?)/i);
                if (!model) continue;
                const label = titleCase(model[1]);
                if (lanes.some(l => l.label.toLowerCase() === label.toLowerCase())) continue;
                const reset = window.match(/(?:->|resets?\s*(?:in|at)?|reset\s*(?:in|at)?)\s*([^|\n]{1,80})/i);
                lanes.push({
                    id: label.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, ''),
                    label, group,
                    pct: normalizePct(pct[1], window),
                    reset: reset ? reset[1].trim() : null
                });
            }
            return lanes;
        }
        function grab() {
            const text = pageText();
            const session = near(text, /5[\s-]?hour|five[\s-]?hour|current\s+limit|current\s+usage|usage\s+limit/i);
            const weekly = near(text, /week|weekly/i);
            const lanes = quotaLanes(text);
            if (!session && !weekly && lanes.length === 0) return null;
            return { session, weekly, lanes };
        }
        function clickMatch(re) {
            const els = Array.from(document.querySelectorAll(
                'button, [role="button"], [role="menuitem"], [role="tab"], a'));
            const el = els.find(e => {
                const label = e.getAttribute('aria-label') || '';
                const txt = (e.textContent || '').trim();
                return re.test(label) || (txt.length > 0 && txt.length < 40 && re.test(txt));
            });
            if (el) { el.click(); return true; }
            return false;
        }

        let r = grab();
        if (!r) {
            if (clickMatch(/settings|setting|usage|quota|limit/i)) {
                await new Promise(res => setTimeout(res, 1200));
                if (clickMatch(/usage|quota|limit/i)) {
                    for (let i = 0; i < 5 && !r; i++) {
                        await new Promise(res => setTimeout(res, 1000));
                        r = grab();
                    }
                }
                document.dispatchEvent(new KeyboardEvent('keydown',
                    { key: 'Escape', keyCode: 27, bubbles: true }));
            }
        }

        if (r) {
            nav({ data: JSON.stringify(r) });
        } else {
            nav({ error: 'notfound' });
        }
    } catch (e) {
        nav({ error: String(e) });
    }
})();
"#;

// ── Response parsing ─────────────────────────────────────────────────────────

pub fn parse_usage(raw: &str) -> Option<ProviderUsageResult> {
    let payload: serde_json::Value = serde_json::from_str(raw).ok()?;

    fn parse_bar(v: Option<&serde_json::Value>) -> Option<(f64, Option<String>)> {
        let d = v?.as_object()?;
        let pct = d.get("pct")?.as_f64()?;
        let remaining = d.get("remaining").and_then(|r| r.as_bool()).unwrap_or(false);
        let used = if remaining { (100.0 - pct).max(0.0) } else { pct };
        let reset = d.get("reset").and_then(|r| r.as_str()).map(|s| s.to_string());
        Some((used, reset))
    }

    let session = parse_bar(payload.get("session"));
    let weekly = parse_bar(payload.get("weekly"));

    let lanes: Vec<QuotaLaneRaw> = payload
        .get("lanes")
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|row| {
                    Some(QuotaLaneRaw {
                        id: row.get("id")?.as_str()?.to_string(),
                        label: row.get("label")?.as_str()?.to_string(),
                        group: row.get("group").and_then(|v| v.as_str()).map(|s| s.to_string()),
                        pct: row.get("pct")?.as_f64()?.max(0.0).min(100.0),
                        reset_text: row.get("reset").and_then(|v| v.as_str()).map(|s| s.to_string()),
                    })
                })
                .collect()
        })
        .unwrap_or_default();

    if session.is_none() && weekly.is_none() && lanes.is_empty() {
        return None;
    }

    Some(ProviderUsageResult {
        session_pct: session.as_ref().map(|(p, _)| *p),
        session_reset_secs: None,
        weekly_pct: weekly.as_ref().map(|(p, _)| *p),
        weekly_reset_secs: None,
        quota_lanes: lanes,
        plan_name: None,
        is_auth_expired: false,
        fetched_at: Utc::now().to_rfc3339(),
    })
}
