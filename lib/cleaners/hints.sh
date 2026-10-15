#!/usr/bin/env bash
#
# lib/cleaners/hints.sh — Non-destructive project artifact hints and recovery guidance.
#
# Sourced by lib/load.sh; never executed on its own.
# Compatible with macOS /bin/bash 3.2+.
#
# Scans shallow project directories (e.g. ~/Dev, ~/Projects, ~/Code) for bulky
# build artifacts (node_modules, target, .build, .gradle) without touching or
# deleting them, and suggests recovery tips.

HINT_PROJECT_COUNT=0
HINT_PROJECT_EXAMPLES=()
HINT_PROJECT_ESTIMATED_KB=0

probe_project_artifact_hints() {
  HINT_PROJECT_COUNT=0
  HINT_PROJECT_EXAMPLES=()
  HINT_PROJECT_ESTIMATED_KB=0

  local search_roots=()
  local r
  for r in "$HOME/Dev" "$HOME/Developer" "$HOME/Projects" "$HOME/Code" "$HOME/Workspace" "$HOME/src"; do
    [ -d "$r" ] && search_roots+=("$r")
  done

  [ "${#search_roots[@]}" -gt 0 ] || return 0

  local root project artifact
  for root in "${search_roots[@]}"; do
    # Shallow search: maxdepth 2 to stay fast and avoid indexing deep trees
    for project in "$root"/*; do
      [ -d "$project" ] || continue
      for artifact in "node_modules" "target" ".build" ".gradle" "Pods"; do
        if [ -d "$project/$artifact" ]; then
          HINT_PROJECT_COUNT=$((HINT_PROJECT_COUNT + 1))
          if [ "${#HINT_PROJECT_EXAMPLES[@]}" -lt 2 ]; then
            HINT_PROJECT_EXAMPLES+=("${project/#$HOME/~}/$artifact")
          fi
          # Sample sizes up to 3 items
          if [ "${#HINT_PROJECT_EXAMPLES[@]}" -le 3 ]; then
            local skb
            skb="$(du -skP "$project/$artifact" 2>/dev/null | awk '{print $1}')"
            if [ -n "$skb" ] && [ "$skb" -gt 0 ] 2>/dev/null; then
              HINT_PROJECT_ESTIMATED_KB=$((HINT_PROJECT_ESTIMATED_KB + skb))
            fi
          fi
          break
        fi
      done
      # Cap check at 25 projects to guarantee sub-second execution
      [ "$HINT_PROJECT_COUNT" -ge 25 ] && break 2
    done
  done
}

show_cleanup_hints() {
  local mode="$1"
  [ "${JSONL_ENABLED:-0}" = 1 ] && return 0

  # 1. Project artifact hint if found
  if [ "$HINT_PROJECT_COUNT" -gt 0 ]; then
    say ""
    say "  ${C_PURPLE}💡 Developer Hint:${C_RESET} Found ${C_BOLD}${HINT_PROJECT_COUNT}${C_RESET} project build artifact(s) in your workspace"
    if [ "${#HINT_PROJECT_EXAMPLES[@]}" -gt 0 ]; then
      local ex
      for ex in "${HINT_PROJECT_EXAMPLES[@]}"; do
        say "     ${C_GRAY}${ICON_SUBLIST} ${ex}${C_RESET}"
      done
    fi
    say "     ${C_DIM}Build artifacts can be purged directly in their project folders when needed.${C_RESET}"
  fi

  # 2. Touch ID configuration hint if on macOS and not yet configured
  if [ "$mode" = "clean" ] && [ "$(uname -s)" = "Darwin" ]; then
    if [ ! -f /etc/pam.d/sudo_local ] && ! grep -q "pam_tid.so" /etc/pam.d/sudo 2>/dev/null; then
      say ""
      say "  ${C_CYAN}💡 Tip:${C_RESET} You can enable ${C_BOLD}Touch ID for sudo${C_RESET} on your Mac by adding pam_tid.so to /etc/pam.d/sudo_local"
    fi
  fi
}

export_clean_preview_ledger() {
  local mode="$1"
  local clean_list_file="$CONFIG_DIR/clean-list.txt"
  [ -d "$CONFIG_DIR" ] || mkdir -p "$CONFIG_DIR" 2>/dev/null || return 0

  {
    printf 'Mimi %s Run Ledger - %s\n' "$mode" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'Mode: %s\n' "$mode"
    if [ "$mode" = "scan" ]; then
      printf 'Estimated Reclaimable: %s\n' "$(human_kb "$TOTAL_BEFORE_KB")"
    else
      printf 'Reclaimed: %s\n' "$(human_kb "$TOTAL_RECLAIMED_KB")"
    fi
    printf 'Categories Scanned: %s\n' "$ONLY_LIST"
    printf 'Log: %s\n' "$LOG_FILE"
  } > "$clean_list_file" 2>/dev/null || true
}

