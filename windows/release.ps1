# ─────────────────────────────────────────────────────────────────────────────
# AI Usage Counter — Windows release build
# สร้าง .msi และ .exe installer พร้อมใช้งาน
#
# วิธีรัน (PowerShell):
#   powershell -ExecutionPolicy Bypass -File release.ps1
# ─────────────────────────────────────────────────────────────────────────────

function Ok($msg)   { Write-Host "  ✔  $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  ⚠  $msg" -ForegroundColor Yellow }
function Fail($msg) { Write-Host "  ✘  $msg" -ForegroundColor Red; exit 1 }
function Step($msg) { Write-Host "`n▸ $msg" -ForegroundColor Cyan }
function Info($msg) { Write-Host "     $msg" -ForegroundColor DarkGray }

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "  AI Usage Counter — Windows Release Builder" -ForegroundColor White
Write-Host "  ─────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

Set-Location $PSScriptRoot

# ── 1. ตรวจสอบ dependencies ──────────────────────────────────────────────────
Step "ตรวจสอบ dependencies"

$cargoPath = "$env:USERPROFILE\.cargo\bin"
$env:PATH  = "$cargoPath;$env:PATH"

$needsSetup = $false

if (-not (Get-Command rustc -ErrorAction SilentlyContinue)) {
    Warn "ไม่พบ Rust — จะรัน install.ps1 เพื่อติดตั้ง"
    $needsSetup = $true
}

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Warn "ไม่พบ Node.js — จะรัน install.ps1 เพื่อติดตั้ง"
    $needsSetup = $true
}

if ($needsSetup) {
    Write-Host ""
    Warn "กำลังรัน install.ps1 เพื่อติดตั้ง dependencies..."
    powershell -ExecutionPolicy Bypass -File "$PSScriptRoot\install.ps1"

    # Reload PATH
    $env:PATH = "$cargoPath;$env:PATH"

    if (-not (Get-Command rustc -ErrorAction SilentlyContinue)) {
        Fail "ติดตั้ง Rust ไม่สำเร็จ กรุณา restart PowerShell แล้วรันใหม่"
    }
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        Fail "ติดตั้ง Node.js ไม่สำเร็จ กรุณา restart PowerShell แล้วรันใหม่"
    }
}

Ok "Rust   $(rustc --version)"
Ok "Node   $(node --version) / npm $(npm --version)"

# ── 2. npm install ───────────────────────────────────────────────────────────
Step "ติดตั้ง npm packages"
npm ci --silent
Ok "npm packages พร้อมแล้ว"

# ── 3. สร้าง app icons ──────────────────────────────────────────────────────
Step "สร้าง app icons"
$iconPath = "..\icon.png"
if (Test-Path $iconPath) {
    npm run tauri icon $iconPath -- --quiet 2>$null
    Ok "Icons สร้างสำเร็จ"
} else {
    Warn "ไม่พบ icon.png ที่ root ของ repo — ข้ามขั้นตอนนี้"
    Info "รันเองได้ด้วย: npm run tauri icon <path>"
}

# ── 4. Build ─────────────────────────────────────────────────────────────────
Step "กำลัง build (อาจใช้เวลา 5–15 นาที ขึ้นกับ cache)"
Write-Host ""

$buildStart = Get-Date
npm run tauri build
$buildEnd = Get-Date
$elapsed = [int]($buildEnd - $buildStart).TotalSeconds

# ── 5. แสดงผลลัพธ์ ────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ─────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  ✅  Build สำเร็จ (ใช้เวลา ${elapsed}s)" -ForegroundColor Green
Write-Host "  ─────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

$bundleDir = "src-tauri\target\release\bundle"
$msiDir    = "$bundleDir\msi"
$nsisDir   = "$bundleDir\nsis"

$outputFiles = @()

if (Test-Path $msiDir) {
    $msiFiles = Get-ChildItem "$msiDir\*.msi" -ErrorAction SilentlyContinue
    foreach ($f in $msiFiles) {
        $size = [math]::Round($f.Length / 1MB, 1)
        Write-Host "  📦  MSI installer  (แนะนำ)" -ForegroundColor White
        Write-Host "      $($f.FullName)" -ForegroundColor Yellow
        Write-Host "      ขนาด: ${size} MB" -ForegroundColor DarkGray
        Write-Host ""
        $outputFiles += $f.FullName
    }
}

if (Test-Path $nsisDir) {
    $exeFiles = Get-ChildItem "$nsisDir\*-setup.exe" -ErrorAction SilentlyContinue
    foreach ($f in $exeFiles) {
        $size = [math]::Round($f.Length / 1MB, 1)
        Write-Host "  📦  NSIS installer (.exe)" -ForegroundColor White
        Write-Host "      $($f.FullName)" -ForegroundColor Yellow
        Write-Host "      ขนาด: ${size} MB" -ForegroundColor DarkGray
        Write-Host ""
        $outputFiles += $f.FullName
    }
}

if ($outputFiles.Count -eq 0) {
    Warn "ไม่พบไฟล์ installer ใน $bundleDir"
    Info "ลองตรวจสอบ: src-tauri\target\release\bundle\"
    exit 1
}

# ── 6. เปิด folder? ─────────────────────────────────────────────────────────
Write-Host "  เปิด folder ที่เก็บ installer หรือไม่? " -NoNewline -ForegroundColor White
Write-Host "[Y/n] " -NoNewline -ForegroundColor DarkGray
$answer = Read-Host

if ($answer -eq "" -or $answer -match "^[Yy]") {
    if (Test-Path $msiDir) {
        Invoke-Item $msiDir
    } elseif (Test-Path $nsisDir) {
        Invoke-Item $nsisDir
    }
}

Write-Host ""
Write-Host "  ติดตั้ง: ดับเบิลคลิกที่ไฟล์ .msi หรือ .exe" -ForegroundColor DarkGray
Write-Host ""
