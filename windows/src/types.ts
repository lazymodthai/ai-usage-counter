export type ProviderID = 'claude' | 'codex' | 'gemini' | 'antigravity'
export type AuthState = 'signed_in' | 'signed_out' | 'expired'

export interface QuotaLane {
  id: string
  label: string
  group: string | null
  pct: number
  resetText: string | null
}

export interface UsageBarVM {
  fraction: number
  usedText: string
  limitText: string
  resetLabel: string
  isActive: boolean
}

export interface ProviderState {
  authState: AuthState
  sessionBar: UsageBarVM | null
  weeklyBar: UsageBarVM | null
  quotaLanes: QuotaLane[]
  fetchedAt: Date | null
  usingLocal: boolean
}

export interface AppState {
  providers: Record<ProviderID, ProviderState>
  menubarSource: ProviderID
  isLoading: boolean
  opacity: number
  alwaysOnTop: boolean
  compact: boolean
}

export const ALL_PROVIDERS: ProviderID[] = ['claude', 'codex', 'gemini', 'antigravity']

export const PROVIDER_LABELS: Record<ProviderID, string> = {
  claude: 'Claude',
  codex: 'Codex',
  gemini: 'Gemini',
  antigravity: 'Antigravity',
}

export const PROVIDER_ICONS: Record<ProviderID, string> = {
  claude: '⚡',
  codex: '</>',
  gemini: '✦',
  antigravity: '⬡',
}

// Rust response shape from get_claude_local_usage
export interface ClaudeLocalUsage {
  session_tokens: number
  session_limit: number
  session_fraction: number
  session_reset_secs: number
  session_active: boolean
  weekly_tokens: number
  weekly_limit: number
  weekly_fraction: number
  weekly_reset_secs: number
  is_local: boolean
  fetched_at: string
}

// Rust response shape from get_codex_usage / get_gemini_usage
export interface ProviderUsageResult {
  session_pct: number | null
  session_reset_secs: number | null
  weekly_pct: number | null
  weekly_reset_secs: number | null
  quota_lanes: AntigravityLane[]
  plan_name: string | null
  is_auth_expired: boolean
  fetched_at: string
}

export interface AntigravityUsage {
  plan_name: string | null
  lanes: AntigravityLane[]
  fetched_at: string
}

export interface AntigravityLane {
  id: string
  label: string
  group: string | null
  pct: number
  reset_text: string | null
}
