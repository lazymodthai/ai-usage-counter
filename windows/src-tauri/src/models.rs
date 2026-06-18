use serde::{Deserialize, Serialize};

// JSONL entry from Claude Code ~/.claude/projects/**/*.jsonl
#[derive(Debug, Deserialize, Clone)]
pub struct JsonlEntry {
    #[serde(rename = "type")]
    pub entry_type: Option<String>,
    pub timestamp: Option<String>,
    pub model: Option<String>,
    pub usage: Option<TokenUsage>,
    // Some entries nest usage inside a message field
    pub message: Option<MessageWrapper>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct TokenUsage {
    pub input_tokens: Option<i64>,
    pub output_tokens: Option<i64>,
    pub cache_creation_input_tokens: Option<i64>,
    pub cache_read_input_tokens: Option<i64>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct MessageWrapper {
    pub usage: Option<TokenUsage>,
    pub model: Option<String>,
}

// Returned to the frontend
#[derive(Debug, Serialize, Clone, Default)]
pub struct ClaudeLocalUsage {
    pub session_tokens: i64,
    pub session_limit: i64,
    pub session_fraction: f64,
    pub session_reset_secs: f64,
    pub session_active: bool,
    pub weekly_tokens: i64,
    pub weekly_limit: i64,
    pub weekly_fraction: f64,
    pub weekly_reset_secs: f64,
    pub is_local: bool,
    pub fetched_at: String,
}

#[derive(Debug, Serialize, Clone, Default)]
pub struct AntigravityUsageRaw {
    pub plan_name: Option<String>,
    pub lanes: Vec<QuotaLaneRaw>,
    pub fetched_at: String,
}

// Returned to frontend for Codex / Gemini live usage
#[derive(Debug, Serialize, Clone, Default)]
pub struct ProviderUsageResult {
    pub session_pct: Option<f64>,
    pub session_reset_secs: Option<f64>,
    pub weekly_pct: Option<f64>,
    pub weekly_reset_secs: Option<f64>,
    pub quota_lanes: Vec<QuotaLaneRaw>,
    pub plan_name: Option<String>,
    pub is_auth_expired: bool,
    pub fetched_at: String,
}

#[derive(Debug, Serialize, Clone, Default)]
pub struct QuotaLaneRaw {
    pub id: String,
    pub label: String,
    pub group: Option<String>,
    pub pct: f64,
    pub reset_text: Option<String>,
}
