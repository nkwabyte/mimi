# Mimi — Feature Guide & Architectural Overview

`mimi` is an ultra-fast, transactional macOS system cleanup tool, application uninstaller, and developer workspace optimizer. Built with 100% pure Bash 3.2+ compatibility, `mimi` requires zero runtime dependencies while offering modern terminal aesthetics, non-destructive safety planning, and deep system intelligence.

---

## Table of Contents

1. [Core Architecture & Safety Principles](#1-core-architecture--safety-principles)
2. [Interactive Terminal Experience (TUI)](#2-interactive-terminal-experience-tui)
3. [System Health Diagnostics (`mimi status`)](#3-system-health-diagnostics-mimi-status)
4. [System Performance Optimization (`mimi optimize`)](#4-system-performance-optimization-mimi-optimize)
5. [Interactive Storage Analyzer (`mimi analyze`)](#5-interactive-storage-analyzer-mimi-analyze)
6. [Project Build Artifacts Purge (`mimi purge`)](#6-project-build-artifacts-purge-mimi-purge)
7. [Leftover Installer Discovery (`mimi installer`)](#7-leftover-installer-discovery-mimi-installer)
8. [Touch ID for sudo (`mimi touchid`)](#8-touch-id-for-sudo-mimi-touchid)
9. [Application Lifecycle & Deep Uninstaller (`mimi apps` / `mimi uninstall`)](#9-application-lifecycle--deep-uninstaller)
10. [Multi-Category System & Developer Cleaner (`mimi clean` / `mimi scan`)](#10-multi-category-system--developer-cleaner)
11. [Shell Completions & Self-Update Engine (`mimi completion` / `mimi update`)](#11-shell-completions--self-update-engine)
12. [Scripting & Machine Integration (JSON Lines Protocol)](#12-scripting--machine-integration-json-lines-protocol)

---

## 1. Core Architecture & Safety Principles

### Pure Bash 3.2+ Portability
- Runs out of the box on macOS default `/bin/bash` (3.2.57) without requiring Homebrew, Node.js, Python, or external package managers.
- Strictly avoids bash 4+ features (no associative arrays, no fractional `read -t`, full POSIX utility conformance).

### Action Authorization & Confirmation Classes
All operations are classified into strict safety tiers:
- **`read-only`**: Reports reclaimable space with 0 mutation (`scan`, `analyze`, `status`, `history`). Never prompts.
- **`recoverable`**: Automatically regenerable caches and safe temporary items. Answerable via `--yes`.
- **`risky`**: Potential loss of rebuildable or secondary state (Docker untagged images, stale simulator devices, mail download cache). Requires explicit terminal confirmation `y/N` or named `--force-risky <name>`.
- **`irreversible`**: Permanent, unrecoverable data deletion (Trash, MobileSync iOS backups, orphan configuration review files). Requires typing the exact action name on a real terminal or explicitly naming it via `--force-risky <name>`. `--yes` is deliberately refused.

### Whitelist & Protected Paths
- Path protection engine verifies that system paths (`/System`, `/usr`, `/bin`, `/sbin`, `/Library/Apple`) and Apple Silicon boot infrastructure are completely immutable.
- Built-in presets (`--whitelist-preset xcode-simulator`, `xcode-derived`, `node`, `browsers`, `ml`).
- Custom user whitelist configured via `--whitelist <path>` or saved to `~/.config/mimi/whitelist.conf`.

### Transactional Planning & Execution
- `mimi plan`: Generates an immutable, cryptographic execution plan file (schema v3) detailing every single path to be removed without altering disk state.
- `mimi apply <plan>`: Verifies plan freshness, integrity, and current system identity before executing removal.

### Root Privilege Separation
- `mimi` never runs as `root` (fails fast if invoked via `sudo mimi`).
- System-scope LaunchDaemons/LaunchAgents uninstall requests use an unprivileged request token passed to `libexec/mimi-root-apply` via standard `sudo`.

---

## 2. Interactive Terminal Experience (TUI)

### High-Fidelity UI
- Centered 4-frame braille spinner (`⠖` -> `⠲` -> `⠴` -> `⠦`) with an asynchronous IPC background loop. Messages update in-place without screen tearing or cursor flicker.
- Interactive keyboard-driven navigation (`↑`/`↓`, `j`/`k`, `PgUp`/`PgDn`, `Home`/`End`, `Enter`, `Space`, `q`).
- Instant single-key shortcuts from the Main Menu:
  - `1`: Quick scan
  - `2`: Quick clean
  - `3`: Optimize system caches
  - `4`: Live system status card
  - `5`: Uninstall applications
  - `6`: Choose individual categories
  - `7`: Storage space analyzer
  - `8`: Touch ID for sudo toggle
  - `9`: Manage path whitelist
  - `0`: System diagnostics & SIP
  - `i`: Leftover installer discovery
  - `p`: Project build artifacts purge
  - `u`: Check for updates
  - `e`: Shell completion setup
  - `c`: Save current selection as default
  - `s`: Settings & thresholds
  - `l`: View recent cleanup log
  - `q`: Quit

### Zero stdout Pollution
- All interactive menus, spinners, status bars, and diagnostic cards output strictly to `stderr` (`>&2`) or `/dev/tty`.
- Commands piped to files or other utilities (e.g., `mimi scan > report.txt` or `mimi status --json | jq`) receive pure, clean, machine-parseable data.

---

## 3. System Health Diagnostics (`mimi status`)

Provides an instant, unified terminal dashboard showing hardware health and system security posture:
- **CPU & Load**: Model name, core count, user/system utilization %, and 1m/5m/15m load averages.
- **Memory Breakdown**: Physical RAM, active, wired, compressed, and free memory with visual capacity gauges.
- **Swap Usage**: Used vs total swap space.
- **Disk Utilization**: Mount point, used/available gigabytes, and graphical fill bar.
- **Battery & Power**: Charge percentage, AC vs battery state, and charging indicator.
- **Security & Integrity**: SIP (System Integrity Protection) status and Full Disk Access (TCC) presence.
- **JSON Telemetry**: `mimi status --json` emits structured telemetry for monitoring integrations.

---

## 4. System Performance Optimization (`mimi optimize`)

Runs safe, routine maintenance tasks to refresh macOS system services:
- **DNS Cache Flush**: Flushes local directory service caches via `dscacheutil -flushcache` and restarts `mDNSResponder`.
- **QuickLook Thumbnail Reset**: Resets corrupted thumbnail databases with `qlmanage -r` and `qlmanage -r cache`.
- **Preferences Integrity Lint**: Scans user application preference plists (`~/Library/Preferences/*.plist`) with `plutil -lint` to identify corrupted property lists.
- **Finder .DS_Store Suppression**: Prevents automatic `.DS_Store` generation on SMB network shares and external USB storage volumes.
- **Dry Run Safety**: Supports `--dry-run` to inspect proposed maintenance operations without mutating system state.

---

## 5. Interactive Storage Analyzer (`mimi analyze`)

A pure-bash disk usage explorer and drill-down tool:
- **1-Depth Directory Inspection**: Shows immediate subdirectories sorted by size with visual proportion bars.
- **Top Offending Files**: Scans for the largest individual files exceeding threshold (`--large-file-mb`, default 500 MB).
- **Interactive Drill-Down**:
  - Type directory number to descend into a child folder.
  - Type `..` to move back up to the parent directory.
  - Type `o` to reveal the current directory in macOS Finder.
- **Automation Support**: `mimi analyze [path] --json` emits structured file and folder trees.

---

## 6. Project Build Artifacts Purge (`mimi purge`)

Deep cleaning for developer workspaces to reclaim tens of gigabytes of ephemeral build dependencies:
- **Artifact Patterns**: Automatically scans for:
  - Node.js: `node_modules`, `.next`, `.nuxt`, `.output`
  - Rust: `target`
  - Swift: `.build`, `DerivedData`
  - Python: `.venv`, `venv`, `__pycache__`
  - Java / Kotlin: `.gradle`, `build`
  - Mobile & Other: `Pods`, `vendor`, `dist`, `.cxx`
- **Project Root Verification**: Ensures folders are within genuine project roots (checks for `package.json`, `Cargo.toml`, `Package.swift`, `pyproject.toml`, etc.) to prevent deleting generic user folders.
- **Search Path Resolution**: Defaults to standard workspace roots (`~/Dev`, `~/Projects`, `~/Code`, `~/Developer`, `~/Workspace`, `~/src`, `~/GitHub`, `~/www`), configurable via `~/.config/mimi/purge_paths` or CLI `--paths`.
- **Interactive Selector**: Multi-select interface (`menu_paginated.sh`) with live search filter `/`, multi-sorting (by size, name, age), select all (`a`), deselect all (`x`).
- **CLI Flags**: `mimi purge [--dry-run] [--paths] [--json] [--yes] [<path>]`.

---

## 7. Leftover Installer Discovery (`mimi installer`)

Scans standard download locations (`~/Downloads`, `~/Desktop`, Homebrew caches, Mail downloads, etc.) for forgotten installation media:
- **Package Extensions**: `.dmg`, `.pkg`, `.mpkg`, `.iso`, `.xip`, and installer `.zip` archives.
- **False-Positive Prevention**: Excludes symlinks, active incomplete downloads (`.crdownload`, `.download`), and whitelisted files.
- **Interactive Review**: Full-screen paginated selector with live filter `/` and file size sorting.
- **Non-Interactive Mode**: `mimi installer [--dry-run] [--json] [--yes]`.

---

## 8. Touch ID for sudo (`mimi touchid`)

Enables biometric authentication for command-line administrative privileges:
- **Apple Sonoma & Sequoia Conformance**: Configures `/etc/pam.d/sudo_local` (Apple's official, upgrade-resilient PAM configuration mechanism that survives macOS software updates).
- **Hardware Awareness**: Validates biometric hardware availability before touching system configuration.
- **Actions**:
  - `mimi touchid status`: Checks current PAM enablement.
  - `mimi touchid enable`: Enables Touch ID PAM module atomically.
  - `mimi touchid disable`: Safely removes PAM module configuration.
  - `mimi touchid toggle`: Flips current configuration state.
- **Dry-Run Preview**: `--dry-run` shows exact PAM diff without requiring root access.

---

## 9. Application Lifecycle & Deep Uninstaller

Complete replacement for GUI uninstallation tools:
- **Application Inventory (`mimi apps`)**: Lists all installed applications with origin classification (`app`, `cask`, `mas`, `pkg`, `system`). Filter via `--source`.
- **Deep Inspection (`mimi app inspect <target>`)**: Discovers total application footprint, code signing team ID, bundle architecture, and attributable data across:
  - `~/Library/Application Support/<bundle-id>`
  - `~/Library/Caches/<bundle-id>`
  - `~/Library/Containers/<bundle-id>`
  - `~/Library/Preferences/<bundle-id>.plist`
  - `~/Library/Saved Application State/<bundle-id>.savedState`
  - `~/Library/HTTPStorages/<bundle-id>`
  - `~/Library/WebKit/<bundle-id>`
  - `~/Library/LaunchAgents/*`
- **Interactive App Picker (`mimi uninstall`)**:
  - Arrow key navigation, space selection (`○` / `●`), search `/`, and size sort `s`.
  - Safety check: Requires typing `uninstall` once before removal begins.
- **Attributable Data Modes**:
  - Default: Deletes bundle and attributable application support/cache files.
  - `--keep-data`: Deletes only the app bundle and LaunchAgents, leaving user data intact.
- **Homebrew Cask Delegation**: Pass `--cask` to delegate to `brew uninstall --cask`, and `--zap` for full brew cleanup.
- **Verified Vendor Uninstallers**: `--vendor-uninstaller` checks and executes official developer uninstaller binaries after verifying code signatures.

---

## 10. Multi-Category System & Developer Cleaner

Supports 30+ fine-grained cleanup categories:
- **Browsers**: Safari, Google Chrome, Mozilla Firefox, Brave, Microsoft Edge, Arc.
- **Electron Apps**: Slack, Discord, VS Code, Spotify, Claude, GitHub Desktop.
- **Developer Caches**: Xcode DerivedData, Xcode Archives, iOS DeviceSupport symbols, iOS Simulator caches.
- **Package Managers**: Homebrew cache, Homebrew old versions (`brew autoremove`), npm, yarn, pnpm, pip, CocoaPods, Gradle, toolchains.
- **AI & ML Frameworks**: Hugging Face hub cache, PyTorch model caches.
- **System Maintenance**: User application logs (`~/Library/Logs`), user caches (`~/Library/Caches`), quicklook thumbnails, `.DS_Store` files, stale temporary files (`$TMPDIR`).
- **Opt-In Categories**: Local Time Machine snapshot thinning, Docker build cache prune (`--include-docker-cache`), system trash (`--include-trash`), stale simulators (`--include-sim-stale`), stale Android emulators (`--include-android`).
- **Orphan Leftovers**: Scans for leftover configs and folders from uninstalled applications (`--include-orphans`).

---

## 11. Shell Completions & Self-Update Engine

### Shell Completions (`mimi completion`)
- Generates raw completion scripts on demand:
  - `mimi completion zsh`: Outputs Zsh completion script (`#compdef mimi`).
  - `mimi completion bash`: Outputs Bash completion script.
- Automated installation (`mimi completion install`):
  - Automatically detects user shell (`SHELL`).
  - Copies completions to `~/.config/mimi/completions/`.
  - Idempotently adds hook to `~/.zshrc` or `~/.bashrc` without duplicate lines.
  - Supports `--dry-run` to preview profile edits.

### Self-Update Engine (`mimi update`)
- **Channel Detection**: Intelligently identifies installation channel:
  - Homebrew tap (`brew upgrade nkwabyte/mimi/mimi`)
  - Git checkout (`git pull origin main`)
  - Standalone script installation
- **Remote Version Check**: Queries GitHub Releases API for the latest published tag.
- **Semver Engine**: Accurately compares semver numbers (major, minor, patch).
- **Check-Only Mode**: `mimi update --check` checks and reports availability without modifying installation.
- **JSON Telemetry**: Emits `{ "type": "update_check", "current_version": "...", "latest_version": "...", "update_available": true }`.

---

## 12. Scripting & Machine Integration (JSON Lines Protocol)

Designed for headless environments, CI pipelines, and wrapper integration:
- **Flag**: `--json` or `--jsonl`.
- **Protocol Schema**: Emits newline-delimited JSON events for lifecycle tracking:
  - `hello`: Engine version and platform diagnostics.
  - `phase_started` / `phase_finished`: Operation status.
  - `action`: Individual item inspection or cleanup details with byte counts.
  - `run_finished`: Reclaimed space summary and return code.
- **Correlation**: Pass `--request-id <uuid>` to correlate events across external orchestrators.
- **Exit Codes**: Standardized Unix exit codes (0 = success, 1 = usage error, 3 = partial failure, 4 = interrupted, 5 = confirmation denied, 6 = plan rejected, 7 = lock busy, 8 = runtime error).
