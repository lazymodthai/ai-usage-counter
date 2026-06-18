use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindowBuilder};

// Shared result store — keyed by request ID string.
// Values: raw data string (from JS), "__error__<msg>", or "__auth_expired__"
pub type ResultStore = Arc<Mutex<HashMap<String, String>>>;

pub struct ProviderWorker {
    pub results: ResultStore,
    pub req_id: AtomicU64,
    pub is_ready: AtomicBool, // true after first successful page load delay
}

impl ProviderWorker {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            results: Arc::new(Mutex::new(HashMap::new())),
            req_id: AtomicU64::new(0),
            is_ready: AtomicBool::new(false),
        })
    }

    /// Returns (window, is_new). Creates the window if it doesn't exist.
    pub fn ensure_window(
        self: &Arc<Self>,
        app: &AppHandle,
        label: &str,
        start_url: &str,
        data_dir: PathBuf,
    ) -> tauri::Result<(tauri::WebviewWindow, bool)> {
        if let Some(w) = app.get_webview_window(label) {
            return Ok((w, false));
        }

        let results = self.results.clone();

        let parsed: url::Url = start_url
            .parse()
            .map_err(|e: url::ParseError| tauri::Error::Anyhow(anyhow::anyhow!("{e}")))?;

        let window = WebviewWindowBuilder::new(
            app,
            label,
            WebviewUrl::External(parsed),
        )
        .visible(false)
        .data_directory(data_dir)
        .on_navigation(move |url| {
            if url.host_str() == Some("tauri-result.internal") {
                let params: HashMap<String, String> = url
                    .query_pairs()
                    .map(|(k, v)| (k.into_owned(), v.into_owned()))
                    .collect();
                if let Some(id) = params.get("id") {
                    let mut map = results.lock().unwrap();
                    if let Some(data) = params.get("data") {
                        map.insert(id.clone(), data.clone());
                    } else if params.get("error").map(|e| e == "auth").unwrap_or(false) {
                        map.insert(id.clone(), "__auth_expired__".into());
                    } else {
                        let err = params.get("error").cloned().unwrap_or_else(|| "unknown".into());
                        map.insert(id.clone(), format!("__error__{err}"));
                    }
                }
                return false; // block navigation — keep current page loaded
            }
            true
        })
        .build()?;

        Ok((window, true))
    }

    /// Eval `js` (with `__REQ_ID__` replaced) in `window`, then poll for result.
    /// Returns `None` on timeout. Returns `Some("__auth_expired__")` on auth failure.
    pub async fn eval_and_wait(
        &self,
        window: &tauri::WebviewWindow,
        js: &str,
        timeout_secs: u64,
        is_new_window: bool,
    ) -> Option<String> {
        // Give the page time to load on first use
        if is_new_window && !self.is_ready.load(Ordering::Relaxed) {
            tokio::time::sleep(tokio::time::Duration::from_secs(5)).await;
        }

        let req_id = self.req_id.fetch_add(1, Ordering::SeqCst).to_string();
        let js = js.replace("__REQ_ID__", &req_id);

        self.results.lock().ok()?.remove(&req_id);
        window.eval(&js).ok()?;

        let deadline =
            tokio::time::Instant::now() + tokio::time::Duration::from_secs(timeout_secs);
        loop {
            tokio::time::sleep(tokio::time::Duration::from_millis(300)).await;
            if let Ok(map) = self.results.try_lock() {
                if let Some(result) = map.get(&req_id) {
                    self.is_ready.store(true, Ordering::Relaxed);
                    return Some(result.clone());
                }
            }
            if tokio::time::Instant::now() >= deadline {
                return None;
            }
        }
    }
}

// ── Auth state persistence ────────────────────────────────────────────────────

pub fn save_auth_state(app: &AppHandle, provider: &str, state: &str) {
    if let Ok(data_dir) = app.path().app_data_dir() {
        let dir = data_dir.join("providers").join(provider);
        let _ = std::fs::create_dir_all(&dir);
        let _ = std::fs::write(dir.join("auth.json"), state);
    }
}

pub fn load_auth_state(app: &AppHandle, provider: &str) -> String {
    let Ok(data_dir) = app.path().app_data_dir() else {
        return "signed_out".into();
    };
    std::fs::read_to_string(data_dir.join("providers").join(provider).join("auth.json"))
        .unwrap_or_else(|_| "signed_out".into())
}

pub fn clear_provider_data(app: &AppHandle, provider: &str) {
    if let Ok(data_dir) = app.path().app_data_dir() {
        let _ = std::fs::remove_dir_all(data_dir.join("providers").join(provider));
    }
}
