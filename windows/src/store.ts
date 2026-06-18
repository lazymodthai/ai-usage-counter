import { create } from 'zustand'
import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import { getCurrentWindow, PhysicalPosition, LogicalSize, currentMonitor } from '@tauri-apps/api/window'
import type { ProviderID, ProviderState, AppState, ClaudeLocalUsage, AntigravityUsage, ProviderUsageResult } from './types'
import { ALL_PROVIDERS } from './types'
import { formatTokens, formatCountdown, formatResetLabel } from './utils'

const FULL_HEIGHT = 500
const COMPACT_HEIGHT = 44

interface Store extends AppState {
  showSettings: boolean
  visibleProviders: ProviderID[]
  sessionTokenLimit: number
  weeklyTokenLimit: number
  refreshInterval: number
  autoDim: boolean

  refreshAll: () => Promise<void>
  loadProviderAuthStates: () => Promise<void>
  openLoginWindow: (provider: ProviderID) => Promise<void>
  signOutProvider: (provider: ProviderID) => Promise<void>
  setMenubarSource: (id: ProviderID) => void
  setOpacity: (v: number) => void
  setAutoDim: (v: boolean) => void
  setAlwaysOnTop: (v: boolean) => void
  setShowSettings: (v: boolean) => void
  setCompact: (v: boolean) => Promise<void>
  hideWindow: () => Promise<void>
  initWindow: () => Promise<void>

  setVisibleProviders: (ids: ProviderID[]) => void
  toggleProviderVisible: (id: ProviderID) => void
  setSessionTokenLimit: (v: number) => void
  setWeeklyTokenLimit: (v: number) => void
  setRefreshInterval: (v: number) => void
}

const defaultProvider = (): ProviderState => ({
  authState: 'signed_out',
  sessionBar: null,
  weeklyBar: null,
  quotaLanes: [],
  fetchedAt: null,
  usingLocal: false,
})

function mapClaudeUsage(u: ClaudeLocalUsage): ProviderState {
  return {
    authState: 'signed_in',
    usingLocal: u.is_local,
    fetchedAt: new Date(u.fetched_at),
    quotaLanes: [],
    sessionBar: {
      fraction: u.session_fraction,
      usedText: formatTokens(u.session_tokens),
      limitText: formatTokens(u.session_limit),
      resetLabel: u.session_active && u.session_reset_secs > 0
        ? formatCountdown(u.session_reset_secs)
        : '',
      isActive: u.session_active,
    },
    weeklyBar: {
      fraction: u.weekly_fraction,
      usedText: formatTokens(u.weekly_tokens),
      limitText: formatTokens(u.weekly_limit),
      resetLabel: formatResetLabel(u.weekly_reset_secs),
      isActive: true,
    },
  }
}

function mapProviderUsage(u: ProviderUsageResult): ProviderState {
  const pctToFraction = (pct: number | null) => pct != null ? pct / 100 : 0
  return {
    authState: u.is_auth_expired ? 'expired' : 'signed_in',
    usingLocal: false,
    fetchedAt: new Date(u.fetched_at),
    quotaLanes: u.quota_lanes.map(l => ({
      id: l.id,
      label: l.label,
      group: l.group,
      pct: l.pct,
      resetText: l.reset_text,
    })),
    sessionBar: u.session_pct != null ? {
      fraction: pctToFraction(u.session_pct),
      usedText: `${u.session_pct.toFixed(1)}%`,
      limitText: '100%',
      resetLabel: u.session_reset_secs != null ? formatCountdown(u.session_reset_secs) : '',
      isActive: true,
    } : null,
    weeklyBar: u.weekly_pct != null ? {
      fraction: pctToFraction(u.weekly_pct),
      usedText: `${u.weekly_pct.toFixed(1)}%`,
      limitText: '100%',
      resetLabel: u.weekly_reset_secs != null ? formatResetLabel(u.weekly_reset_secs) : '',
      isActive: true,
    } : null,
  }
}

export const useStore = create<Store>((set, get) => ({
  providers: {
    claude: defaultProvider(),
    codex: defaultProvider(),
    gemini: defaultProvider(),
    antigravity: defaultProvider(),
  },
  menubarSource: 'claude',
  isLoading: false,
  opacity: (() => {
    const v = Number(localStorage.getItem('idleOpacity'))
    return v > 0 ? v : 0.4
  })(),
  autoDim: localStorage.getItem('autoDim') !== 'false',
  alwaysOnTop: true,
  compact: false,
  showSettings: false,
  visibleProviders: (() => {
    try {
      const stored = localStorage.getItem('visibleProviders')
      return stored ? JSON.parse(stored) : ALL_PROVIDERS
    } catch {
      return ALL_PROVIDERS
    }
  })(),
  sessionTokenLimit: Number(localStorage.getItem('sessionTokenLimit')) || 0,
  weeklyTokenLimit: Number(localStorage.getItem('weeklyTokenLimit')) || 0,
  refreshInterval: Number(localStorage.getItem('refreshInterval')) || 60,

  loadProviderAuthStates: async () => {
    for (const provider of ['codex', 'gemini'] as ProviderID[]) {
      try {
        const authState = await invoke<string>('get_provider_auth_state', { provider })
        set(state => ({
          providers: {
            ...state.providers,
            [provider]: {
              ...state.providers[provider],
              authState: authState as 'signed_in' | 'signed_out' | 'expired',
            },
          },
        }))
      } catch (e) {
        // ignore — stays signed_out
      }
    }
  },

  openLoginWindow: async (provider: ProviderID) => {
    await invoke('open_login_window', { provider })
  },

  signOutProvider: async (provider: ProviderID) => {
    await invoke('sign_out_provider', { provider })
    set(state => ({
      providers: {
        ...state.providers,
        [provider]: { ...state.providers[provider], authState: 'signed_out', sessionBar: null, weeklyBar: null, quotaLanes: [] },
      },
    }))
  },

  refreshAll: async () => {
    set({ isLoading: true })
    try {
      const usage = await invoke<ClaudeLocalUsage>('get_claude_local_usage')
      set(state => ({
        providers: { ...state.providers, claude: mapClaudeUsage(usage) },
      }))
    } catch (e) {
      console.error('Claude local usage error:', e)
    }

    // Fetch Codex usage if signed in
    const codexAuth = get().providers.codex.authState
    if (codexAuth === 'signed_in' || codexAuth === 'expired') {
      try {
        const result = await invoke<ProviderUsageResult | null>('get_codex_usage')
        if (result) {
          const mapped = mapProviderUsage(result)
          set(state => ({ providers: { ...state.providers, codex: mapped } }))
        }
      } catch (e) {
        console.error('Codex usage error:', e)
      }
    }

    // Fetch Gemini usage if signed in
    const geminiAuth = get().providers.gemini.authState
    if (geminiAuth === 'signed_in' || geminiAuth === 'expired') {
      try {
        const result = await invoke<ProviderUsageResult | null>('get_gemini_usage')
        if (result) {
          const mapped = mapProviderUsage(result)
          set(state => ({ providers: { ...state.providers, gemini: mapped } }))
        }
      } catch (e) {
        console.error('Gemini usage error:', e)
      }
    }

    try {
      const antiUsage = await invoke<AntigravityUsage | null>('get_antigravity_usage')
      if (antiUsage) {
        set(state => ({
          providers: {
            ...state.providers,
            antigravity: {
              authState: 'signed_in',
              sessionBar: null,
              weeklyBar: null,
              quotaLanes: antiUsage.lanes.map(l => ({
                id: l.id,
                label: l.label,
                group: l.group,
                pct: l.pct,
                resetText: l.reset_text,
              })),
              fetchedAt: new Date(antiUsage.fetched_at),
              usingLocal: true,
            }
          }
        }))
      } else {
        set(state => ({
          providers: {
            ...state.providers,
            antigravity: {
              ...state.providers.antigravity,
              authState: 'signed_out',
            }
          }
        }))
      }
    } catch (e) {
      console.error('Antigravity usage error:', e)
    } finally {
      set({ isLoading: false })

      // Update tray title
      const state = get()
      const provider = state.providers[state.menubarSource]
      const fraction = provider.sessionBar?.fraction ?? 0
      const pct = Math.round(fraction * 100)
      try {
        await invoke('update_tray_title', { title: `AI Usage — ${pct}%` })
      } catch (e) {
        // ignore
      }
    }
  },

  setVisibleProviders: (ids) => {
    if (ids.length === 0) return
    set({ visibleProviders: ids })
    localStorage.setItem('visibleProviders', JSON.stringify(ids))
  },
  toggleProviderVisible: (id) => {
    const current = get().visibleProviders
    if (current.includes(id)) {
      if (current.length > 1) {
        const next = current.filter(x => x !== id)
        set({ visibleProviders: next })
        localStorage.setItem('visibleProviders', JSON.stringify(next))
      }
    } else {
      const next = [...current, id]
      set({ visibleProviders: next })
      localStorage.setItem('visibleProviders', JSON.stringify(next))
    }
  },
  setSessionTokenLimit: (v) => {
    set({ sessionTokenLimit: v })
    localStorage.setItem('sessionTokenLimit', String(v))
  },
  setWeeklyTokenLimit: (v) => {
    set({ weeklyTokenLimit: v })
    localStorage.setItem('weeklyTokenLimit', String(v))
  },
  setRefreshInterval: (v) => {
    const valid = Math.max(30, v)
    set({ refreshInterval: valid })
    localStorage.setItem('refreshInterval', String(valid))
  },

  setMenubarSource: id => set({ menubarSource: id }),

  setOpacity: v => {
    set({ opacity: v })
    localStorage.setItem('idleOpacity', String(v))
  },

  setAutoDim: v => {
    set({ autoDim: v })
    localStorage.setItem('autoDim', String(v))
  },

  setAlwaysOnTop: async v => {
    set({ alwaysOnTop: v })
    try { await getCurrentWindow().setAlwaysOnTop(v) } catch {}
  },

  setShowSettings: v => set({ showSettings: v }),

  setCompact: async v => {
    set({ compact: v })
    try {
      const height = v ? COMPACT_HEIGHT : FULL_HEIGHT
      await getCurrentWindow().setSize(new LogicalSize(320, height))
    } catch {}
  },

  hideWindow: async () => {
    try { await getCurrentWindow().hide() } catch {}
  },

  initWindow: async () => {
    // Load Codex/Gemini auth states from disk before showing UI
    await useStore.getState().loadProviderAuthStates()

    try {
      const win = getCurrentWindow()

      // Restore saved position, or place bottom-right on first launch
      const saved = localStorage.getItem('windowPos')
      if (saved) {
        const { x, y } = JSON.parse(saved) as { x: number; y: number }
        await win.setPosition(new PhysicalPosition(x, y))
      } else {
        // First launch: place overlay at bottom-right near system tray
        try {
          const monitor = await currentMonitor()
          if (monitor) {
            const { width, height } = monitor.size
            const scaleFactor = monitor.scaleFactor
            // overlay is 320×500 logical px, convert to physical
            const overlayW = Math.round(320 * scaleFactor)
            const overlayH = Math.round(500 * scaleFactor)
            const margin = Math.round(16 * scaleFactor)
            const taskbarH = Math.round(48 * scaleFactor)
            await win.setPosition(new PhysicalPosition(
              width - overlayW - margin,
              height - overlayH - taskbarH - margin,
            ))
          }
        } catch {}
        // Show first-launch notification pointing to tray icon
        await invoke('show_first_launch_tip').catch(() => {})
      }

      // Apply always-on-top
      await win.setAlwaysOnTop(get().alwaysOnTop)

      // Restore compact mode
      const savedCompact = localStorage.getItem('compact') === 'true'
      if (savedCompact) {
        set({ compact: true })
        await win.setSize(new LogicalSize(320, COMPACT_HEIGHT))
      }

      // Save position whenever window moves
      await win.listen('tauri://move', async () => {
        const pos = await win.outerPosition()
        localStorage.setItem('windowPos', JSON.stringify({ x: pos.x, y: pos.y }))
      })

      // Listen for tray toggle-compact event
      await win.listen('toggle-compact', () => {
        const next = !useStore.getState().compact
        useStore.getState().setCompact(next)
        localStorage.setItem('compact', String(next))
      })

      // Listen for tray show event (restores from hide)
      await win.listen('tauri://focus', () => {
        // nothing needed — Tauri shows window automatically
      })

      // Refresh auth state when a provider login window closes
      await listen<string>('auth-state-changed', (event) => {
        const provider = event.payload as ProviderID
        set(state => ({
          providers: {
            ...state.providers,
            [provider]: { ...state.providers[provider], authState: 'signed_in' },
          },
        }))
        // Immediately fetch usage for the newly logged-in provider
        useStore.getState().refreshAll()
      })
    } catch {}
  },
}))
