# AI Usage Counter — Windows/macOS Overlay

Floating overlay แสดง usage ของ Claude / Antigravity ที่ลากย้ายตำแหน่งได้ทุกที่บนหน้าจอ  
สร้างด้วย [Tauri](https://tauri.app) (Rust + React) — รองรับทั้ง **Windows** และ **macOS**

---

## สถานะ Provider

| Provider | Windows | macOS (Tauri) | หมายเหตุ |
|---|---|---|---|
| **Claude** | ✅ | ✅ | login `claude.ai` → API `/api/organizations/{id}/usage` (usage จริง 5h + weekly) |
| **Antigravity** | ✅ | ✅ | ค้นหา language server process อัตโนมัติ ไม่ต้อง login |
| **Codex** | ✅ | ✅ | login ChatGPT → Bearer token → `/backend-api/wham/usage` |
| **Gemini** | ✅ | ✅ | login Google → DOM scrape Usage Limits page |

---

## ติดตั้ง

### วิธีที่ 1 — ดาวน์โหลดจาก GitHub Releases (แนะนำ)

> ไม่ต้องติดตั้ง Rust หรือ Node.js

1. ไปที่ **[Releases](../../releases/latest)** ของ repo นี้
2. ดาวน์โหลด **`ai-usage-counter_x.x.x_x64_en-US.msi`** (แนะนำ) หรือ **`ai-usage-counter_x.x.x_x64-setup.exe`**
3. ดับเบิลคลิกไฟล์ที่ดาวน์โหลดมา → คลิก "ติดตั้ง" → เสร็จ

> **ความต้องการของระบบ:** Windows 10 (1803+) พร้อม WebView2  
> (WebView2 มักมีอยู่แล้วหากใช้ Microsoft Edge — ถ้าไม่มี Windows จะแจ้งให้ติดตั้งอัตโนมัติ)

---

### วิธีที่ 2 — Build เอง (Windows)

รันคำเดียวได้ installer เลย:

```powershell
# clone repo ก่อน จากนั้น:
cd windows
powershell -ExecutionPolicy Bypass -File release.ps1
```

Script จะ:
- ตรวจและติดตั้ง Rust · Node.js · WebView2 · MSVC Build Tools อัตโนมัติ
- รัน `npm run tauri build`
- แสดงที่อยู่ไฟล์ `.msi` / `.exe` ที่ build ได้
- ถามว่าจะเปิด folder หรือไม่

> Build ครั้งแรกอาจใช้เวลา 10–20 นาที (Rust compile) — ครั้งถัดไปเร็วขึ้นมากเพราะมี cache

---

### Build เอง (macOS)

```bash
cd windows
chmod +x install.sh
./install.sh

npm run tauri build
# → ได้ไฟล์ที่ src-tauri/target/release/bundle/macos/
```

---

## ติดตั้ง dependencies ด้วยตนเอง (ถ้าไม่ใช้ script)

```bash
# npm packages (frontend + Tauri CLI)
npm install

# สร้าง icons จาก icon.png ที่ root ของ repo
npm run tauri icon ../icon.png
```

**Cargo.toml จัดการ Rust dependencies อัตโนมัติตอน build**

| Rust crate | ความหมาย |
|---|---|
| `tauri` | core framework |
| `tauri-plugin-shell` | รัน shell command |
| `tauri-plugin-fs` | อ่านไฟล์ |
| `tauri-plugin-http` | HTTP requests |
| `tauri-plugin-notification` | system notifications |
| `tauri-plugin-global-shortcut` | keyboard shortcuts |
| `chrono` | parse timestamp จาก JSONL |
| `dirs` | หา home directory |
| `regex` | parse process command line |
| `serde / serde_json` | JSON parsing |

---

## หน้าตา

```
┌─────────────────────────────────────┐
│ ⚡ AI Usage               [↻]  [⚙] │  ← ลากตรงไหนก็ได้เพื่อย้าย overlay
│─────────────────────────────────────│
│ ⚡ Claude              [Sign out]   │
│   🕐 Current Session               │
│   ████████░░  78.20%               │
│                        Resets 46m  │
│   📅 Weekly                        │
│   ████░░░░░░  41.00%               │
│                  Resets Tue 5:00AM │
│─────────────────────────────────────│
│ ⬡  Antigravity                     │
│   Pro Model       ████░░░░  42%    │
│   Fast Model      ██░░░░░░  28%    │
│─────────────────────────────────────│
│ ◉ Live · Claude · Updated 17:43:12 │
└─────────────────────────────────────┘
```

---

## วิธีใช้งาน

### ย้ายตำแหน่ง overlay
- **ลากที่แถบบนสุด** (ส่วนที่เขียนว่า "AI Usage") เพื่อย้าย overlay ไปวางไว้มุมไหนของจอก็ได้
- แอปจำตำแหน่งล่าสุดอัตโนมัติ ปิดแล้วเปิดใหม่ยังอยู่ที่เดิม

### ซ่อน / แสดง
- **Keyboard shortcut:** `Ctrl+Shift+U` (Windows/Linux) หรือ `Cmd+Shift+U` (macOS)
- คลิก **tray icon** ที่ system tray (มุมขวาล่าง Windows / menu bar macOS) เพื่อสลับซ่อน-แสดง
- คลิกขวา tray icon → **Hide** หรือ **Show**
- คลิกขวา tray icon → **Quit** เพื่อปิดแอป

### ปรับแต่ง (⚙ Settings)
คลิกปุ่ม ⚙ ที่มุมขวาบนของ overlay

| ตัวเลือก | ความหมาย |
|---|---|
| **Always on Top** | เปิด = ลอยเหนือทุก window ตลอด (default: เปิด) |
| **Opacity** | ปรับความโปร่งแสง 30%–100% (default: 95%) |
| **Refresh Interval** | ระยะเวลา auto-refresh (default: 60 วินาที) |

### Refresh ข้อมูล
- กด **↻** เพื่อ refresh ทันที
- แอป refresh อัตโนมัติตามที่ตั้งไว้ใน Settings

### Claude
กด **Sign in** → login `claude.ai` → ดึง usage จริงจาก API `/api/organizations/{id}/usage`
(session 5 ชั่วโมง + weekly 7 วัน) — ตัวเลขตรงกับที่ Anthropic แสดง ไม่ใช่การประมาณการ

### Antigravity
ค้นหา Antigravity language server process อัตโนมัติ (`wmic` บน Windows, `ps` บน macOS) แล้วดึง quota ผ่าน local HTTP ไม่ต้อง login

---

## ความต้องการของระบบ

| OS | เวอร์ชันต่ำสุด |
|---|---|
| **Windows** | Windows 10 (1803+) พร้อม WebView2 |
| **macOS** | macOS 11 (Big Sur) ขึ้นไป |

> WebView2 บน Windows 10/11 ส่วนใหญ่มีอยู่แล้ว (มาพร้อม Microsoft Edge) — install script จัดการให้ถ้ายังไม่มี

---

## Features

| Feature | รายละเอียด |
|---|---|
| **Overlay** | หน้าต่างลอยเหนือทุก app |
| **Draggable** | ลาก header เพื่อย้ายตำแหน่ง |
| **Position memory** | จำตำแหน่งล่าสุดอัตโนมัติ |
| **Opacity** | ปรับความโปร่งแสงได้ใน Settings |
| **Always on Top** | toggle ได้ใน Settings |
| **Keyboard shortcut** | `Ctrl+Shift+U` / `Cmd+Shift+U` สลับซ่อน-แสดง |
| **System tray** | คลิก tray icon เพื่อซ่อน/แสดง + compact mode |
| **Compact mode** | คลิก tray → Compact เพื่อย่อ overlay |
| **Claude / Codex / Gemini** | login → ดึง usage จริงจาก API/หน้าเว็บของแต่ละเจ้า |
| **Antigravity** | ค้นหา process อัตโนมัติ ดึง quota แบบ local (ไม่ต้อง login) |
| **Drag-anywhere** | ลากย้าย overlay จากตรงไหนก็ได้ |
| **Auto-dim** | จางเมื่อไม่ใช้ · ชัดเมื่อ hover |

---

## โครงสร้าง

```
windows/
├── src/                         React frontend
│   ├── components/
│   │   ├── Header.tsx           แถบบน + ปุ่ม refresh/settings
│   │   ├── ProviderSection.tsx  Claude, Codex, Gemini rows
│   │   ├── AntigravitySection.tsx Antigravity quota lanes
│   │   ├── UsageBar.tsx         progress bar component
│   │   ├── Footer.tsx           status bar ล่างสุด
│   │   ├── Settings.tsx         settings panel
│   │   └── CompactView.tsx      compact mode view
│   ├── store.ts                 Zustand state + Tauri invoke calls
│   ├── types.ts                 TypeScript types
│   └── utils.ts                 format helpers
└── src-tauri/                   Rust backend
    ├── src/
    │   ├── main.rs              entry point
    │   ├── lib.rs               Tauri setup + commands
    │   ├── provider_worker.rs   hidden WebView worker (login + fetch)
    │   ├── claude_provider.rs   claude.ai API usage
    │   ├── codex_provider.rs    ChatGPT wham/usage
    │   ├── gemini_provider.rs   Gemini Usage Limits scraper
    │   ├── antigravity_parser.rs ค้นหา process + ดึง quota
    │   ├── models.rs            data structs
    │   └── tray.rs              system tray + compact toggle
    └── tauri.conf.json          window config (frameless, transparent, alwaysOnTop)
```
