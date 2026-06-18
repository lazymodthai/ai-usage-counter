import { useStore } from '../store'
import { PROVIDER_ICONS } from '../types'

export function Header() {
  const isLoading = useStore(s => s.isLoading)
  const menubarSource = useStore(s => s.menubarSource)
  const refreshAll = useStore(s => s.refreshAll)
  const setShowSettings = useStore(s => s.setShowSettings)
  const setCompact = useStore(s => s.setCompact)
  const hideWindow = useStore(s => s.hideWindow)

  return (
    <div className="header">
      <span className={`provider-icon tint-${menubarSource}`}>
        {PROVIDER_ICONS[menubarSource]}
      </span>
      <span className="header-title">AI Usage</span>
      <div className="spacer" />
      {isLoading && <span className="spinner" />}
      <button className="icon-btn" onClick={refreshAll} title="Refresh">↻</button>
      <button
        className="icon-btn"
        onClick={() => setCompact(true)}
        title="Compact mode (Ctrl+Shift+U)"
        style={{ fontSize: 11 }}
      >⊟</button>
      <button className="icon-btn" onClick={() => setShowSettings(true)} title="Settings">⚙</button>
      <button
        className="icon-btn"
        onClick={hideWindow}
        title="Hide (Ctrl+Shift+U to show again)"
        style={{ fontSize: 14, marginLeft: 2 }}
      >×</button>
    </div>
  )
}
