import { getCurrentWindow } from '@tauri-apps/api/window'
import type { MouseEvent } from 'react'

// Interactive elements that should click, not drag the window.
const NO_DRAG_SELECTOR = 'button, input, a, label, select, textarea, .slider, [data-no-drag]'

// Start an OS-level window drag from anywhere on the surface, except when the
// press lands on an interactive control. Wire to onMouseDown of a root container.
export function startWindowDrag(e: MouseEvent): void {
  if (e.button !== 0) return // left button only
  const target = e.target as HTMLElement
  if (target.closest(NO_DRAG_SELECTOR)) return
  getCurrentWindow().startDragging().catch(() => {})
}

export function formatTokens(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
  if (n >= 1_000) return `${Math.round(n / 1_000)}K`
  return `${n}`
}

export function formatCountdown(secs: number): string {
  const h = Math.floor(secs / 3600)
  const m = Math.floor((secs % 3600) / 60)
  const s = Math.floor(secs % 60)
  if (h > 0) return `${h}h ${m}m`
  if (m > 0) return `${m}m`
  return `${s}s`
}

export function formatResetLabel(secs: number): string {
  if (secs <= 0) return ''
  const d = new Date(Date.now() + secs * 1000)
  const days = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']
  const day = days[d.getDay()]
  const h = d.getHours()
  const ampm = h >= 12 ? 'PM' : 'AM'
  const h12 = h % 12 || 12
  const m = d.getMinutes().toString().padStart(2, '0')
  return `Resets ${day} ${h12}:${m}${ampm}`
}

export function formatTime(date: Date): string {
  return date.toLocaleTimeString('en-US', {
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hour12: false,
  })
}
