import { useStore } from '../store'
import { PROVIDER_ICONS } from '../types'
import { startWindowDrag } from '../utils'

const TINT: Record<string, string> = {
  claude: '#ff9f0a',
  codex: '#30d158',
  gemini: '#0a84ff',
}

export function CompactView() {
  const menubarSource = useStore(s => s.menubarSource)
  const providers = useStore(s => s.providers)
  const isLoading = useStore(s => s.isLoading)
  const opacity = useStore(s => s.opacity)
  const autoDim = useStore(s => s.autoDim)
  const setCompact = useStore(s => s.setCompact)
  const hideWindow = useStore(s => s.hideWindow)

  const p = providers[menubarSource]
  const sessionPct = p.sessionBar ? (p.sessionBar.fraction * 100).toFixed(0) : '—'
  const weeklyPct = p.weeklyBar ? (p.weeklyBar.fraction * 100).toFixed(0) : '—'
  const tint = TINT[menubarSource]
  const sessionColor = p.sessionBar
    ? p.sessionBar.fraction >= 1 ? '#ff3b30'
      : p.sessionBar.fraction >= 0.9 ? '#ff9f0a'
      : tint
    : tint

  return (
    <div
      className="compact-view"
      style={{ '--idle-opacity': autoDim ? opacity : 1 } as React.CSSProperties}
      onMouseDown={startWindowDrag}
    >
      <span style={{ color: tint, fontSize: 11, flexShrink: 0 }}>
        {PROVIDER_ICONS[menubarSource]}
      </span>
      <span className="compact-nums">
        <span style={{ color: sessionColor, fontWeight: 700 }}>{sessionPct}%</span>
        <span style={{ color: 'rgba(255,255,255,0.2)' }}> | </span>
        <span style={{ color: 'rgba(255,255,255,0.55)' }}>{weeklyPct}%</span>
      </span>
      <div className="spacer" />
      {isLoading && <span className="spinner" style={{ width: 8, height: 8 }} />}
      <button className="icon-btn" onClick={() => setCompact(false)} title="Expand (Ctrl+Shift+U)">⊡</button>
      <button className="icon-btn" onClick={hideWindow} title="Hide">×</button>
    </div>
  )
}
