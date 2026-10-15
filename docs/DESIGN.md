# Mimi — Design System & Interface Specification (`DESIGN.md`)

This document serves as the comprehensive visual, architectural, and interaction design specification for **Mimi**. It is designed specifically for UI/UX engineers, design agents, and frontend contributors working on revamping both the **terminal CLI / TUI interface** and translating its patterns to the **macOS native desktop app (SwiftUI / iMimi)**.

---

## Table of Contents

1. [Design Philosophy & Product Identity](#1-design-philosophy--product-identity)
2. [Color Palette & Design Tokens](#2-color-palette--design-tokens)
3. [Typography & Text Hierarchies](#3-typography--text-hierarchies)
4. [Iconography & Symbolic Language](#4-iconography--symbolic-language)
5. [TUI Component Architecture](#5-tui-component-architecture)
   - [Brand Banner & Quick Status Line](#brand-banner--quick-status-line)
   - [Card Containers & Framing](#card-containers--framing)
   - [Metric Gauges & Visual Bars](#metric-gauges--visual-bars)
   - [Asynchronous Braille Spinner](#asynchronous-braille-spinner)
   - [Menu & Interactive Selectors](#menu--interactive-selectors)
   - [Paginated Table & Live Search](#paginated-table--live-search)
6. [Screen Blueprints & Wireframes](#6-screen-blueprints--wireframes)
   - [Screen 1: Main Menu Dashboard](#screen-1-main-menu-dashboard)
   - [Screen 2: Live System Health (`mimi status`)](#screen-2-live-system-health-mimi-status)
   - [Screen 3: Storage Space Analyzer (`mimi analyze`)](#screen-3-storage-space-analyzer-mimi-analyze)
   - [Screen 4: Project Build Artifacts Purge (`mimi purge`)](#screen-4-project-build-artifacts-purge-mimi-purge)
   - [Screen 5: Deep Application Uninstaller (`mimi uninstall`)](#screen-5-deep-application-uninstaller-mimi-uninstall)
   - [Screen 6: Touch ID & System Diagnostics (`mimi touchid`)](#screen-6-touch-id--system-diagnostics-mimi-touchid)
7. [Stream Separation & UX Invariants](#7-stream-separation--ux-invariants)
8. [Desktop GUI Adaptation (SwiftUI / iMimi Bridge)](#8-desktop-gui-adaptation-swiftui--imimi-bridge)

---

## 1. Design Philosophy & Product Identity

### The Mimi Aesthetic: "Precision Unix Minimalism"
Mimi bridges the raw speed and transparency of Unix utilities with the visual clarity of modern developer interfaces (inspired by `tw93/Mole`, `gh`, `lazygit`, and `btop`).

1. **Substance Over Noise**: Information density is high, but visual clutter is low. No decorative ASCII borders unless they organize data.
2. **Dark Mode First**: Tailored for dark macOS terminal environments (Ghostty, iTerm2, Kitty, Terminal.app) with high-contrast text and vibrant accents.
3. **Color as Meaning, Not Decoration**: Color always communicates state—green means healthy/reclaimable, amber means caution/opt-in, red means danger/heavy load, cyan highlights focus/active commands.
4. **Motion Without Tearing**: Spinners and loading states run on isolated background loops with in-place text replacement to guarantee 0 cursor flicker.
5. **Zero stdout Pollution**: Visuals, cards, and spinners render exclusively on `stderr` or `/dev/tty`. Piped stdout remains 100% clean, predictable, and scriptable.

---

## 2. Color Palette & Design Tokens

Mimi implements an adaptive color token system adhering strictly to the [NO_COLOR](https://no-color.org) standard and terminal capabilities (`TERM=dumb` degrades to pure ASCII).

### Core Token Palette

| Token Name | ANSI Code | Hex Equivalent | Usage & Role |
| :--- | :--- | :--- | :--- |
| `C_CYAN` | `\033[36m` | `#00E5FF` | **Primary Brand Accent**: Active cursors, key highlight, category titles, card headers |
| `C_GREEN` | `\033[32m` | `#10B981` | **Success / Reclaimable**: Safe items, granted permissions, healthy capacity (<70%) |
| `C_YELLOW` | `\033[33m` | `#F59E0B` | **Warning / Moderate**: Cautionary categories, opt-in flags, elevated load (70–84%) |
| `C_RED` | `\033[31m` | `#EF4444` | **Danger / Critical**: Irreversible operations, corrupted plists, high load (≥85%) |
| `C_PURPLE` | `\033[35m` | `#A855F7` | **Developer State**: Build artifacts (`node_modules`, `target`, DerivedData) |
| `C_GRAY` | `\033[38;5;244m`| `#9CA3AF` | **Subdued Metadata**: Version pills, minor file paths, secondary tags |
| `C_DIM` | `\033[2m` | `#6B7280` | **Structural Borders**: Dividers, empty gauge bars, navigation hints |
| `C_BOLD` | `\033[1m` | — | **Emphasis**: Values, selected rows, major headings |
| `C_RESET` | `\033[0m` | — | Reset formatting to terminal default |

### Semantic Health & Capacity Thresholds

```
[██████████░░░░░░]  58%  -> C_GREEN  (Normal / Healthy: < 70%)
[█████████████░░░]  78%  -> C_YELLOW (Warning / Approaching limit: 70–84%)
[████████████████]  94%  -> C_RED    (Critical / High resource strain: ≥ 85%)
```

---

## 3. Typography & Text Hierarchies

Mimi assumes a monospace developer font (such as SF Mono, JetBrains Mono, Fira Code, or Menlo). Visual distinction relies on weight (`BOLD`), luminosity (`DIM`), and padding.

### Typographic Scales

- **Hero Logo**: Multi-line block ASCII banner (`show_brand_banner`) for full-screen terminal launches.
- **Section Heading**: `C_BOLD + C_CYAN` with leading line art (`─── Main menu ───────────────────`).
- **Data Key-Value**:
  - Key: `C_DIM` or `C_CYAN` with fixed column width (e.g. `%-16s`).
  - Value: `C_BOLD + C_WHITE` or colored semantic pill (`Enabled`, `Granted`).
- **Footer Hints**: `C_DIM` centered or padded legend (`↑/↓ move   enter select   / search   q quit`).

---

## 4. Iconography & Symbolic Language

All icons are standardized UTF-8 symbols with automatic ASCII fallbacks for basic environments:

| Glyph | Token | Meaning | Context |
| :---: | :--- | :--- | :--- |
| `❯` | `ICON_ARROW` | Focus / Current Cursor | Active item in interactive menus & lists |
| `✔` / `✓` | `ICON_SUCCESS` | Verified / Completed | Cleaned successfully, permission granted, SIP active |
| `✖` / `☻` | `ICON_ERROR` | Failed / Denied | Operation failed, permission denied, corrupted plist |
| `◎` | `ICON_WARNING` | Action Required | Confirmation gate, opt-in category notice |
| `●` | `ICON_SOLID` | Selected State | Checked checkbox in multi-select lists |
| `○` | `ICON_EMPTY` | Unselected State | Unchecked checkbox in multi-select lists |
| `•` | `ICON_BULLET` | List Item / Metadata | Diagnostics properties, secondary points |
| `↳` | `ICON_SUBLIST` | Attributable Remnant | Sub-paths belonging to an application bundle |
| `💾` | `ICON_DISK` | Storage Accounting | Disk free before/after summaries |
| `🔒` | `ICON_LOCK` | Security / Root | Root helper boundary, SIP, Touch ID |
| `⚙` | `ICON_ADMIN` | Configuration | Preferences linting, PAM rules, config file |
| `🧹` | `ICON_CLEAN` | Purge / Wipe | Cleaning operations, garbage reclamation |

---

## 5. TUI Component Architecture

### Brand Banner & Quick Status Line
Rendered at the top of the interactive menu when terminal height is at least 24 rows:

```
 __  __ _           _
|  \/  (_)_ __ ___ (_)
| |\/| | | '_ ` _ \| |  v0.5.0
| |  | | | | | | | | |  macOS System Cleaner & Optimizer
|_|  |_|_|_| |_| |_|_|  Apple Silicon & Developer Aware

macOS 15.0 (arm64) • 84GB free (62% used) • config: config.conf • Touch ID: on
```

### Card Containers & Framing
Mimi groups related information into cards framed with smooth box drawing characters (`U+2500` `─`):

```bash
# Code implementation: lib/ui/theme.sh
render_card_header "System Status"
# Content rendered here with consistent 2-space left indent
render_card_footer
```

Visual output:
```
─── System Status ───────────────────────────────────────────────
  Hardware:      Apple M3 Max (16 cores)
  Memory:        36.00 GB (Active: 14.20 GB, Wired: 4.80 GB)
─────────────────────────────────────────────────────────────────
```

### Metric Gauges & Visual Bars
Horizontal proportional capacity meters are rendered using unicode blocks (`█` `U+2588` and `░` `U+2591`):

```bash
# Code implementation: render_health_bar <percentage> <width>
render_health_bar 64 16
# Output: [██████████░░░░░░]
```

### Asynchronous Braille Spinner
During background scans and operations, an asynchronous non-blocking spinner loops at 80ms:

```
Frames:  ⠖  ->  ⠲  ->  ⠴  ->  ⠦
Format:  ${FRAME} ${C_BOLD}${MESSAGE}${C_RESET}
```
- Operates via a dedicated background subshell that polls a control directory.
- `update_spinner_message "New text"` renames the IPC message file atomically, updating the message in place with `\r\033[2K` without cursor repositioning artifacts.
- Trap safety: `EXIT`, `INT`, and `TERM` signals automatically clear the line and kill the spinner PID.

### Menu & Interactive Selectors
Full-screen interactive screens switch to the alternate terminal buffer (`\033[?1049h`), hide the cursor (`\033[?25l`), and render frames with a single atomic redraw per keypress:

```
❯ 1  Quick scan            — code-default safe categories (read-only)
  2  Quick clean           — clean safe caches and temporary files
  3  Optimize system       — refresh caches, flush DNS & repair configs
  4  System status         — live memory, swap, disk & battery health
```

### Paginated Table & Live Search
`lib/ui/menu_paginated.sh` provides a reusable interactive table with real-time substring filtering:

```
  Filter: [ node_mod                   ]  (Press / to edit, Esc to clear)
  Showing 1-8 of 14 matching items (Page 1/2) • Sort: Size (desc)

  [●] 1. web-client/node_modules        [node_modules]     1.42 GB  (~45d old)
  [●] 2. api-server/node_modules        [node_modules]   892.40 MB  (~12d old)
  [○] 3. docs-site/node_modules         [node_modules]   412.10 MB  (~8d old)
  ─────────────────────────────────────────────────────────────────────────────
  ↑/↓ move   space toggle   a all   x clear   s sort   / search   enter purge   q back
```

---

## 6. Screen Blueprints & Wireframes

### Screen 1: Main Menu Dashboard

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  __  __ _           _                                                       │
│ |  \/  (_)_ __ ___ (_)                                                      │
│ | |\/| | | '_ ` _ \| |  v0.5.0                                              │
│ | |  | | | | | | | | |  macOS System Cleaner & Optimizer                    │
│ |_|  |_|_|_| |_| |_|_|  Apple Silicon & Developer Aware                     │
│                                                                             │
│ macOS 15.0 (arm64) • 82GB free (65% used) • config: default • Touch ID: on   │
│                                                                             │
│ Main menu                                                                   │
│   ↑/↓ move   1-9/0 jump   enter select   v info   q quit                    │
│                                                                             │
│ ❯ 1  Quick scan            — code-default safe categories (read-only)       │
│   2  Quick clean           — clean safe caches and temporary files          │
│   3  Optimize system       — refresh caches, flush DNS & repair configs     │
│   4  System status         — live memory, swap, disk & battery health       │
│   5  Uninstall apps        — deep app removal with orphan cleanup           │
│   6  Choose categories     — pick individual categories to scan or clean    │
│   7  Storage analyzer      — explore disk usage & interactive drill-down    │
│   8  Touch ID for sudo     — configure biometric auth for admin commands    │
│   9  Manage whitelist      — protect custom directories, apps, or paths     │
│   0  System diagnostics    — view macOS info, SIP & Full Disk Access        │
│   i  Installer packages    — scan and remove leftover DMG, PKG and archives │
│   p  Purge project artifacts — scan & remove heavy build artifacts          │
│   u  Check for updates     — query GitHub for newer releases & upgrade      │
│   e  Shell completions     — configure tab completions for zsh / bash       │
│   c  Save configuration    — persist selection + settings as default        │
│   s  Settings              — configure safety thresholds and preferences    │
│   l  View most recent log  — inspect output from latest cleanup session     │
│   q  Quit                                                                   │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### Screen 2: Live System Health (`mimi status`)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ ─── System Status ───────────────────────────────────────────────────────── │
│   macOS:         15.0.1 (24A348)                                            │
│   Hardware:      Apple M3 Max (16 cores, arm64)                             │
│   Uptime:        4 days, 12 hours, 28 mins                                  │
│                                                                             │
│   CPU Usage:     [████░░░░░░░░░░░░]  24%  (User: 18%, Sys: 6%)              │
│   Load Averages: 2.14, 1.88, 1.65                                           │
│                                                                             │
│   Memory:        [██████████░░░░░░]  62%  (22.32 GB / 36.00 GB)             │
│                  • Active:     14.20 GB                                     │
│                  • Wired:       5.12 GB                                     │
│                  • Compressed:  3.00 GB                                     │
│                  • Free:       13.68 GB                                     │
│                                                                             │
│   Swap:          [█░░░░░░░░░░░░░░░]   8%  (256.0 MB / 3.00 GB)              │
│                                                                             │
│   Disk (/):      [████████████░░░░]  74%  (742.0 GB / 994.0 GB)             │
│                  • Available: 252.0 GB                                      │
│                                                                             │
│   Power:         Battery at 92% (Discharging, ~6h remaining)                │
│   SIP Status:    ✔ Enabled                                                  │
│   Full Disk:     ✔ Granted                                                  │
│ ─────────────────────────────────────────────────────────────────────────── │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### Screen 3: Storage Space Analyzer (`mimi analyze`)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ ─── Storage Analyzer: /Users/musahibrahimali ────────────────────────────── │
│   Total Size: 412.80 GB in 8 top-level directories                          │
│                                                                             │
│   1. Library/          [████████████░░░░]  164.20 GB  (40%)                 │
│   2. Dev/              [████████░░░░░░░░]  112.50 GB  (27%)                 │
│   3. Downloads/        [████░░░░░░░░░░░░]   58.40 GB  (14%)                 │
│   4. Documents/        [██░░░░░░░░░░░░░░]   32.10 GB   (8%)                 │
│   5. Pictures/         [█░░░░░░░░░░░░░░░]   22.40 GB   (5%)                 │
│   6. Desktop/          [█░░░░░░░░░░░░░░░]   14.20 GB   (3%)                 │
│   7. .Trash/           [░░░░░░░░░░░░░░░░]    7.80 GB   (2%)                 │
│   8. Music/            [░░░░░░░░░░░░░░░░]    1.20 GB  (<1%)                 │
│                                                                             │
│   Top Large Files (>500 MB):                                                │
│   • Downloads/Xcode_16_Release.xip                          14.28 GB        │
│   • Dev/Models/llama-3-70b-instruct.Q4_K_M.gguf             38.45 GB        │
│   • Library/Developer/CoreSimulator/Devices/.../data.img      8.12 GB       │
│                                                                             │
│   [1-8] drill down   .. go up   o open in Finder   q exit                   │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### Screen 4: Project Build Artifacts Purge (`mimi purge`)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ ─── Project Build Artifacts (Purge) ─────────────────────────────────────── │
│   Search roots: ~/Dev, ~/Projects, ~/Code                                   │
│   Found 14 artifact folder(s) occupying 12.84 GB                            │
│                                                                             │
│   [●] 1. ~/Dev/Bash/mimi/build            [build]         124.5 MB  (~2d)   │
│   [●] 2. ~/Dev/Web/dashboard/node_modules [node_modules]    1.84 GB  (~14d) │
│   [●] 3. ~/Dev/Rust/compiler/target       [target]          5.12 GB  (~30d) │
│   [○] 4. ~/Dev/Python/ai-agent/.venv      [.venv]           3.20 GB  (~5d)  │
│   [●] 5. ~/Dev/iOS/MyApp/.build           [.build]        840.2 MB  (~42d) │
│   [●] 6. ~/Dev/Mobile/client/Pods         [Pods]            1.72 GB  (~60d) │
│                                                                             │
│   Selected: 5 folder(s) • 9.64 GB to reclaim                                │
│   ───────────────────────────────────────────────────────────────────────── │
│   ↑/↓ move   space toggle   a all   x clear   s sort   enter purge   q back │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### Screen 5: Deep Application Uninstaller (`mimi uninstall`)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ ─── Installed Applications ──────────────────────────────────────────────── │
│   Filter: [ slack                     ]                                     │
│                                                                             │
│ ❯ [●] Slack.app                     412.50 MB  (Cask)        [com.tinyspeck]│
│       ↳ ~/Library/Application Support/Slack                  1.84 GB        │
│       ↳ ~/Library/Caches/com.tinyspeck.slack                 842.10 MB      │
│       ↳ ~/Library/Saved Application State/com.tinyspeck...    24.50 MB      │
│       ↳ ~/Library/Preferences/com.tinyspeck.slack.plist       12.00 KB      │
│       Total Footprint: 3.12 GB (5 attributable items)                       │
│                                                                             │
│   [○] Discord.app                   284.10 MB  (App Store)   [com.discord]  │
│   [○] Google Chrome.app             612.40 MB  (System App)  [com.chrome]   │
│                                                                             │
│   Selected for removal: Slack.app (3.12 GB total footprint)                 │
│   Type 'uninstall' to permanently remove: [ uninstall                 ]     │
│   ───────────────────────────────────────────────────────────────────────── │
│   ↑/↓ move   space toggle   enter confirm   / filter   q back               │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 7. Stream Separation & UX Invariants

To guarantee that Mimi works seamlessly across interactive terminals, shell pipelines, and machine automation:

1. **Terminal UI Stream (`stderr` / `/dev/tty`)**:
   - Menus, frames, headers, footers, spinners, and interactive dialogs write exclusively to `stderr` (`>&2`) or directly to `/dev/tty`.
   - Never write progress bars or visual ANSI codes to stdout.

2. **Machine Telemetry Stream (`stdout`)**:
   - `mimi --json` and `mimi --jsonl` emit strictly structured JSON Lines protocol records to `stdout`.
   - Any diagnostic error or warning goes to `stderr`.
   - Redirecting stdout to a file (`mimi scan --json > report.jsonl`) produces 100% valid JSON with zero ANSI codes.

3. **Interruption & Signal Integrity**:
   - `SIGINT` (Ctrl+C) and `SIGTERM` trap cleanly: they immediately stop background spinners, restore normal screen buffers (`\033[?1049l`), unhide the cursor (`\033[?25h`), and release the run lock (`~/.config/mimi/run.lock`).

---

## 8. Desktop GUI Adaptation (SwiftUI / iMimi Bridge)

For the standalone macOS application (`iMimi`) in `~/Dev/xcode/Mimi`, the TUI design language maps directly to Apple's native Human Interface Guidelines (HIG):

| Mimi CLI Token / Pattern | SwiftUI Component | Visual Equivalent |
| :--- | :--- | :--- |
| **Main Menu Options** | `NavigationSplitView` Sidebar | Sidebar list with SF Symbols (`speedometer`, `trash`, `sparkles`, `terminal`) |
| **Health Status Card** | `GroupBox` with Grid layout | Native macOS vibrancy card with rounded corners (`12pt`) |
| **Progress / Health Bar** | `ProgressView(value:total:)` | Native macOS capsule gauge with tinted accents (Green/Amber/Red) |
| **Braille Spinner** | `ProgressView().progressViewStyle(.circular)` | Native indeterminate progress spinner |
| **Paginated Artifact Table** | `Table` with selection & sorting | Native NSTableView with column header sorting and checkbox rows |
| **Live Search Filter (`/`)** | `.searchable(text: $query)` | Standard macOS spotlight search field in toolbar |
| **Touch ID Toggle** | `Toggle` + LocalAuthentication | Biometric prompt via `LAContext.evaluatePolicy` |
| **Stream Engine** | Subprocess invocation of `mimi --json` | Real-time JSON line parser driving SwiftUI `@Published` model state |

---

*This document is the single source of truth for the Mimi design system. Modifications to UI themes, layout algorithms, or interactive controls must be reflected here.*
