mod antigravity_parser;
mod claude_provider;
mod codex_provider;
mod gemini_provider;
mod models;
mod provider_worker;
mod tray;

use models::{AntigravityUsageRaw, ProviderUsageResult};
use provider_worker::{clear_provider_data, load_auth_state, save_auth_state, ProviderWorker};
use std::sync::Arc;
use tauri::{AppHandle, Emitter, Manager, State};

pub struct AppState {
    pub claude: Arc<ProviderWorker>,
    pub codex: Arc<ProviderWorker>,
    pub gemini: Arc<ProviderWorker>,
}

// ── Existing commands ─────────────────────────────────────────────────────────

#[tauri::command]
fn get_antigravity_usage() -> Option<AntigravityUsageRaw> {
    antigravity_parser::compute()
}

#[tauri::command]
fn update_tray_title(app: AppHandle, title: String) {
    if let Some(tray) = app.tray_by_id("main") {
        let _ = tray.set_tooltip(Some(&title));
    }
}

#[tauri::command]
fn save_window_position(app: AppHandle, x: i32, y: i32) {
    if let Ok(data_dir) = app.path().app_data_dir() {
        let _ = std::fs::create_dir_all(&data_dir);
        let _ = std::fs::write(
            data_dir.join("window_position.json"),
            format!(r#"{{"x":{},"y":{}}}"#, x, y),
        );
    }
}

#[tauri::command]
fn get_saved_position(app: AppHandle) -> Option<serde_json::Value> {
    let data_dir = app.path().app_data_dir().ok()?;
    let content = std::fs::read_to_string(data_dir.join("window_position.json")).ok()?;
    serde_json::from_str(&content).ok()
}

// ── Auth state ────────────────────────────────────────────────────────────────

#[tauri::command]
fn get_provider_auth_state(app: AppHandle, provider: String) -> String {
    load_auth_state(&app, &provider)
}

// ── Login window ──────────────────────────────────────────────────────────────

#[tauri::command]
async fn open_login_window(app: AppHandle, provider: String) -> Result<(), String> {
    use std::sync::atomic::{AtomicBool, Ordering};
    use tauri::{WebviewUrl, WebviewWindowBuilder};

    let label = format!("{}-login", provider);
    if let Some(w) = app.get_webview_window(&label) {
        let _ = w.set_focus();
        return Ok(());
    }

    let start_url = match provider.as_str() {
        "claude" => "https://claude.ai/login",
        "codex" => "https://chatgpt.com/auth/login",
        "gemini" => "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fgemini.google.com%2Fapp",
        _ => return Err(format!("Unknown provider: {provider}")),
    };

    let data_dir = app
        .path()
        .app_data_dir()
        .map_err(|e| e.to_string())?
        .join("providers")
        .join(&provider);

    let app_clone = app.clone();
    let provider_for_nav = provider.clone();
    let label_clone = label.clone();
    let logged_in = Arc::new(AtomicBool::new(false));
    let logged_in_clone = logged_in.clone();

    let parsed_url: url::Url = start_url.parse().map_err(|e: url::ParseError| e.to_string())?;

    WebviewWindowBuilder::new(&app, &label, WebviewUrl::External(parsed_url))
        .title(match provider.as_str() {
            "claude" => "Sign in to Claude",
            "codex"  => "Sign in to ChatGPT",
            "gemini" => "Sign in to Gemini",
            _        => "Sign in",
        })
        .inner_size(600.0, 760.0)
        .resizable(true)
        .data_directory(data_dir)
        .on_navigation(move |url| {
            let is_done = match provider_for_nav.as_str() {
                "claude" => {
                    let host = url.host_str().unwrap_or("");
                    let path = url.path();
                    host.contains("claude.ai")
                        && !path.contains("/login")
                        && !path.contains("/auth")
                }
                "codex" => {
                    let host = url.host_str().unwrap_or("");
                    let path = url.path();
                    host.contains("chatgpt.com")
                        && !path.contains("/auth")
                        && !path.contains("/login")
                }
                "gemini" => url
                    .host_str()
                    .map(|h| h.contains("gemini.google.com"))
                    .unwrap_or(false),
                _ => false,
            };
            if is_done && !logged_in_clone.swap(true, Ordering::SeqCst) {
                let app = app_clone.clone();
                let provider = provider_for_nav.clone();
                let label = label_clone.clone();
                std::thread::spawn(move || {
                    std::thread::sleep(std::time::Duration::from_secs(2));
                    save_auth_state(&app, &provider, "signed_in");
                    app.emit("auth-state-changed", &provider).ok();
                    if let Some(w) = app.get_webview_window(&label) {
                        let _ = w.close();
                    }
                });
            }
            true
        })
        .build()
        .map_err(|e| e.to_string())?;

    // Fallback: if the user closes the login window manually (URL detection may
    // miss SPA redirects), treat the close as "maybe signed in" and re-check.
    // The usage fetch shares the same cookie store, so it confirms or downgrades.
    let app_for_close = app.clone();
    let provider_for_close = provider.clone();
    let logged_in_for_close = logged_in.clone();
    let login_window = app
        .get_webview_window(&label)
        .ok_or_else(|| "login window missing".to_string())?;
    login_window.on_window_event(move |event| {
        if let tauri::WindowEvent::Destroyed = event {
            if !logged_in_for_close.load(Ordering::SeqCst) {
                // Don't trust the close alone — let the usage fetch confirm login
                // (it persists signed_in on success, expired on failure).
                app_for_close
                    .emit("auth-state-changed", &provider_for_close)
                    .ok();
            }
        }
    });

    Ok(())
}

// ── Sign out ──────────────────────────────────────────────────────────────────

#[tauri::command]
async fn sign_out_provider(
    app: AppHandle,
    state: State<'_, AppState>,
    provider: String,
) -> Result<(), String> {
    // Close worker window if open
    if let Some(w) = app.get_webview_window(&format!("{}-worker", provider)) {
        let _ = w.close();
    }
    // Reset worker ready state
    match provider.as_str() {
        "claude" => state.claude.is_ready.store(false, std::sync::atomic::Ordering::Relaxed),
        "codex" => state.codex.is_ready.store(false, std::sync::atomic::Ordering::Relaxed),
        "gemini" => state.gemini.is_ready.store(false, std::sync::atomic::Ordering::Relaxed),
        _ => {}
    }
    // Clear cookies + auth state
    clear_provider_data(&app, &provider);
    Ok(())
}

// ── Claude usage (official claude.ai API, requires login) ──────────────────────

#[tauri::command]
async fn get_claude_usage(
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<Option<ProviderUsageResult>, String> {
    let data_dir = app
        .path()
        .app_data_dir()
        .map_err(|e| e.to_string())?
        .join("providers")
        .join("claude");

    let (window, is_new) = state
        .claude
        .ensure_window(&app, "claude-worker", claude_provider::START_URL, data_dir)
        .map_err(|e| e.to_string())?;

    let raw = state
        .claude
        .eval_and_wait(&window, claude_provider::FETCH_JS, 20, is_new)
        .await;

    if let Some(raw) = raw {
        if raw == "__auth_expired__" {
            save_auth_state(&app, "claude", "expired");
            return Ok(Some(ProviderUsageResult {
                is_auth_expired: true,
                fetched_at: chrono::Utc::now().to_rfc3339(),
                ..Default::default()
            }));
        }
        if let Some(result) = claude_provider::parse_usage(&raw) {
            save_auth_state(&app, "claude", "signed_in");
            return Ok(Some(result));
        }
    }

    Ok(None)
}

// ── Codex usage ───────────────────────────────────────────────────────────────

#[tauri::command]
async fn get_codex_usage(
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<Option<ProviderUsageResult>, String> {
    let data_dir = app
        .path()
        .app_data_dir()
        .map_err(|e| e.to_string())?
        .join("providers")
        .join("codex");

    let (window, is_new) = state
        .codex
        .ensure_window(&app, "codex-worker", codex_provider::START_URL, data_dir)
        .map_err(|e| e.to_string())?;

    // Try primary API first
    let raw = state
        .codex
        .eval_and_wait(&window, codex_provider::FETCH_JS, 20, is_new)
        .await;

    if let Some(raw) = raw {
        if raw == "__auth_expired__" {
            save_auth_state(&app, "codex", "expired");
            return Ok(Some(ProviderUsageResult {
                is_auth_expired: true,
                fetched_at: chrono::Utc::now().to_rfc3339(),
                ..Default::default()
            }));
        }
        if let Some(result) = codex_provider::parse_wham(&raw) {
            save_auth_state(&app, "codex", "signed_in");
            return Ok(Some(result));
        }
    }

    // Fallback: navigate to usage page and scrape
    let _ = window.eval(&format!(
        "window.location = 'https://chatgpt.com/codex/settings/usage';"
    ));
    tokio::time::sleep(tokio::time::Duration::from_secs(4)).await;

    let raw = state
        .codex
        .eval_and_wait(&window, codex_provider::SCRAPE_JS, 20, false)
        .await;

    if let Some(raw) = raw {
        if raw == "__auth_expired__" {
            save_auth_state(&app, "codex", "expired");
            return Ok(Some(ProviderUsageResult {
                is_auth_expired: true,
                fetched_at: chrono::Utc::now().to_rfc3339(),
                ..Default::default()
            }));
        }
        if let Some(result) = codex_provider::parse_scrape(&raw) {
            save_auth_state(&app, "codex", "signed_in");
            return Ok(Some(result));
        }
    }

    Ok(None)
}

// ── Gemini usage ──────────────────────────────────────────────────────────────

#[tauri::command]
async fn get_gemini_usage(
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<Option<ProviderUsageResult>, String> {
    let data_dir = app
        .path()
        .app_data_dir()
        .map_err(|e| e.to_string())?
        .join("providers")
        .join("gemini");

    let (window, is_new) = state
        .gemini
        .ensure_window(&app, "gemini-worker", gemini_provider::START_URL, data_dir)
        .map_err(|e| e.to_string())?;

    // Gemini SPA is slow to hydrate — extra settle time on first load
    let settle = if is_new { 6u64 } else { 0u64 };
    if settle > 0 {
        tokio::time::sleep(tokio::time::Duration::from_secs(settle)).await;
    }

    // Match macOS: try the in-app view first, then fall back to dedicated
    // usage URLs. The SPA may surface the meters on any of these.
    for (i, url) in gemini_provider::USAGE_URLS.iter().enumerate() {
        if i > 0 {
            let _ = window.eval(&format!("window.location = '{url}';"));
            tokio::time::sleep(tokio::time::Duration::from_secs(4)).await;
        }

        let raw = state
            .gemini
            .eval_and_wait(&window, gemini_provider::FETCH_JS, 25, false)
            .await;

        if let Some(raw) = raw {
            if raw == "__auth_expired__" {
                save_auth_state(&app, "gemini", "expired");
                return Ok(Some(ProviderUsageResult {
                    is_auth_expired: true,
                    fetched_at: chrono::Utc::now().to_rfc3339(),
                    ..Default::default()
                }));
            }
            if let Some(result) = gemini_provider::parse_usage(&raw) {
                save_auth_state(&app, "gemini", "signed_in");
                return Ok(Some(result));
            }
        }
    }

    Ok(None)
}

// ── First-launch tip ──────────────────────────────────────────────────────────

#[tauri::command]
fn show_first_launch_tip(app: AppHandle) {
    use tauri_plugin_notification::NotificationExt;
    let _ = app
        .notification()
        .builder()
        .title("AI Usage Counter")
        .body("กำลังทำงานอยู่ใน System Tray  คลิกไอคอน ⚡ เพื่อแสดง/ซ่อน overlay\nหรือกด Ctrl+Shift+U")
        .show();
}

// ── App setup ─────────────────────────────────────────────────────────────────

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Modifiers, Shortcut, ShortcutState};

    #[cfg(target_os = "macos")]
    let toggle_mod = Modifiers::SUPER | Modifiers::SHIFT;
    #[cfg(not(target_os = "macos"))]
    let toggle_mod = Modifiers::CONTROL | Modifiers::SHIFT;

    let toggle_shortcut = Shortcut::new(Some(toggle_mod), Code::KeyU);

    tauri::Builder::default()
        .manage(AppState {
            claude: ProviderWorker::new(),
            codex: ProviderWorker::new(),
            gemini: ProviderWorker::new(),
        })
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_http::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(move |app, shortcut, event| {
                    if event.state() != ShortcutState::Pressed {
                        return;
                    }
                    let _ = shortcut;
                    if let Some(win) = app.get_webview_window("main") {
                        let visible = win.is_visible().unwrap_or(false);
                        if visible {
                            let _ = win.hide();
                        } else {
                            let _ = win.show();
                            let _ = win.set_focus();
                        }
                    }
                })
                .build(),
        )
        .setup(move |app| {
            tray::setup(app)?;

            if let Some(win) = app.get_webview_window("main") {
                if let Ok(data_dir) = app.path().app_data_dir() {
                    if let Ok(content) =
                        std::fs::read_to_string(data_dir.join("window_position.json"))
                    {
                        if let Ok(pos) = serde_json::from_str::<serde_json::Value>(&content) {
                            let x = pos["x"].as_i64().unwrap_or(100) as i32;
                            let y = pos["y"].as_i64().unwrap_or(100) as i32;
                            let _ = win.set_position(tauri::PhysicalPosition::new(x, y));
                        }
                    }
                }
            }

            app.handle()
                .global_shortcut()
                .register(toggle_shortcut)
                .ok();

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_antigravity_usage,
            update_tray_title,
            save_window_position,
            get_saved_position,
            get_provider_auth_state,
            open_login_window,
            sign_out_provider,
            get_claude_usage,
            get_codex_usage,
            get_gemini_usage,
            show_first_launch_tip,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
