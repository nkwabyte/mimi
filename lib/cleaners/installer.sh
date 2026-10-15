#!/usr/bin/env bash
#
# lib/cleaners/installer.sh — Leftover installer packages scanner and cleaner (Phase 10).
#
# Inspired by Mole's installer module. Discovers leftover DMG, PKG, MPKG, ISO,
# XIP, and installer ZIP files across Downloads, Desktop, caches, etc., and provides
# preview, interactive selective removal, and automated batch cleaning.
#
# Sourced by lib/load.sh; never executed on its own.
# Compatible with macOS /bin/bash 3.2+.
#

INSTALLER_FILES=()
INSTALLER_SIZES_KB=()
INSTALLER_SOURCES=()
INSTALLER_SELECTED=()
INSTALLER_VIEW_INDICES=()

# Friendly source folder name from path
get_installer_source() {
  local file_path="$1"
  local dir_path="${file_path%/*}"

  case "$dir_path" in
    *"Mail Downloads"*|*"com.apple.mail"*) printf '%s' "Mail" ;;
    *"Downloads"*)                 printf '%s' "Downloads" ;;
    *"Desktop"*)                   printf '%s' "Desktop" ;;
    *"Documents"*)                 printf '%s' "Documents" ;;
    *"Homebrew"*)                  printf '%s' "Homebrew" ;;
    *"CloudDocs"*)                 printf '%s' "iCloud" ;;
    "/Users/Shared"*)              printf '%s' "Shared" ;;
    *)                             printf '%s' "${dir_path##*/}" ;;
  esac
}

# Inspect if a zip archive contains an installer (.app, .pkg, .dmg, .xip)
is_installer_zip() {
  local zip="$1"
  [ -r "$zip" ] || return 1
  [ -f "$zip" ] || return 1

  local cmd=""
  if command -v zipinfo >/dev/null 2>&1; then
    cmd="zipinfo -1"
  elif command -v unzip >/dev/null 2>&1; then
    cmd="unzip -Z -1"
  else
    return 1
  fi

  # Check the first 50 entries
  local listing
  listing="$($cmd "$zip" 2>/dev/null | head -50)" || return 1
  if printf '%s\n' "$listing" | grep -Ei '\.(app|pkg|dmg|xip)(/|$)' >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# Check if a file is an installer package
is_installer_candidate() {
  local file="$1"
  [ -L "$file" ] && return 1
  [ -f "$file" ] || return 1

  # Exclude active partial downloads
  [ -e "${file}.crdownload" ] && return 1
  [ -e "${file}.download" ] && return 1
  [ -e "${file}.part" ] && return 1

  case "$file" in
    *.crdownload|*.download|*.part) return 1 ;;
    *.dmg|*.DMG|*.pkg|*.PKG|*.mpkg|*.MPKG|*.iso|*.ISO|*.xip|*.XIP)
      return 0
      ;;
    *.zip|*.ZIP)
      is_installer_zip "$file" && return 0
      ;;
  esac
  return 1
}

# Scan installer packages in a directory up to maxdepth 2
scan_installers_in_directory() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  [ ! -L "$dir" ] || return 0

  local file
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    [ -f "$file" ] || continue
    [ ! -L "$file" ] || continue

    if is_installer_candidate "$file"; then
      # Security & whitelist gates
      if ! path_authorize "$file" >/dev/null 2>&1; then
        verbose "installer: refused unauthorized path: $file"
        continue
      fi
      if is_whitelisted "$file"; then
        verbose "installer: whitelisted, keeping: $file"
        continue
      fi

      local kb
      kb="$(file_size_kb "$file")"
      [ "$kb" -ge 0 ] 2>/dev/null || kb=0

      INSTALLER_FILES+=("$file")
      INSTALLER_SIZES_KB+=("$kb")
      INSTALLER_SOURCES+=("$(get_installer_source "$file")")
      INSTALLER_SELECTED+=(1)
    fi
  done < <(find -H "$dir" -maxdepth 2 -type f 2>/dev/null)
}

# Scan all candidate installer directories
scan_all_installers() {
  local custom_target="${1:-}"
  INSTALLER_FILES=()
  INSTALLER_SIZES_KB=()
  INSTALLER_SOURCES=()
  INSTALLER_SELECTED=()

  if [ -n "$custom_target" ]; then
    if [ -d "$custom_target" ]; then
      scan_installers_in_directory "$custom_target"
    elif [ -f "$custom_target" ] && is_installer_candidate "$custom_target"; then
      local kb
      kb="$(file_size_kb "$custom_target")"
      INSTALLER_FILES+=("$custom_target")
      INSTALLER_SIZES_KB+=("${kb:-0}")
      INSTALLER_SOURCES+=("$(get_installer_source "$custom_target")")
      INSTALLER_SELECTED+=(1)
    else
      err "installer: target is not a directory or installer file: $custom_target"
      return "$EXIT_USAGE"
    fi
    return 0
  fi

  local scan_dirs=(
    "$HOME_DIR/Downloads"
    "$HOME_DIR/Desktop"
    "$HOME_DIR/Library/Caches/Homebrew/downloads"
    "$HOME_DIR/Library/Caches/Homebrew"
    "/Library/Caches/Homebrew/downloads"
    "$HOME_DIR/Library/Mobile Documents/com~apple~CloudDocs/Downloads"
    "$HOME_DIR/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
    "/Users/Shared/Downloads"
  )

  local d
  for d in "${scan_dirs[@]}"; do
    if [ -d "$d" ]; then
      scan_installers_in_directory "$d"
    fi
  done
  return 0
}

# Calculate total size of candidates
installer_total_size_kb() {
  local total=0 kb
  for kb in "${INSTALLER_SIZES_KB[@]}"; do
    total=$((total + kb))
  done
  printf '%s' "$total"
}

# Render terminal summary card of discovered installers
render_installer_card() {
  local count="${#INSTALLER_FILES[@]}"
  local total_kb
  total_kb="$(installer_total_size_kb)"

  render_card_header "Leftover Installer Packages"
  printf "  ${C_CYAN}%-20s${C_RESET} %d file(s)\n" "Packages Found:" "$count"
  printf "  ${C_CYAN}%-20s${C_RESET} %s\n" "Reclaimable Space:" "$(human_kb "$total_kb")"
  render_card_footer
  say ""

  if [ "$count" -eq 0 ]; then
    say "  ${C_GREEN}${ICON_SUCCESS} No leftover installer packages found. Clean!${C_RESET}"
    return 0
  fi

  printf "  ${C_FAINT}%-36s  %-12s  %10s${C_RESET}\n" "Package Name" "Source" "Size"
  local i mw=36
  for ((i = 0; i < count; i++)); do
    local f="${INSTALLER_FILES[$i]}"
    local name="${f##*/}"
    local src="${INSTALLER_SOURCES[$i]}"
    local sz
    sz="$(human_kb "${INSTALLER_SIZES_KB[$i]}")"
    [ "${#name}" -gt "$mw" ] && name="${name:0:33}..."
    printf "  %-36s  ${C_CYAN}%-12s${C_RESET}  %10s\n" "$name" "$src" "$sz"
  done
  say ""
}

# Build view indices for interactive installer menu
installer_build_indices() {
  local query="${1:-}" sort_mode="${2:-size}" reverse="${3:-0}"
  local count="${#INSTALLER_FILES[@]}" i name path sz query_lower
  INSTALLER_VIEW_INDICES=()
  [ "$count" -gt 0 ] || return 0

  query_lower="$(_paginated_to_lower "$query")"
  for ((i = 0; i < count; i++)); do
    path="${INSTALLER_FILES[$i]}"
    name="${path##*/}"
    if [ -n "$query_lower" ]; then
      local name_lower src_lower
      name_lower="$(_paginated_to_lower "$name")"
      src_lower="$(_paginated_to_lower "${INSTALLER_SOURCES[$i]}")"
      case "$name_lower" in *"$query_lower"*) ;; *)
        case "$src_lower" in *"$query_lower"*) ;; *) continue ;; esac
      ;; esac
    fi
    INSTALLER_VIEW_INDICES+=("$i")
  done

  # Simple sorting: size or name
  local vcount="${#INSTALLER_VIEW_INDICES[@]}" j temp
  if [ "$vcount" -gt 1 ]; then
    for ((i = 0; i < vcount - 1; i++)); do
      for ((j = i + 1; j < vcount; j++)); do
        local idx1="${INSTALLER_VIEW_INDICES[$i]}"
        local idx2="${INSTALLER_VIEW_INDICES[$j]}"
        local swap=0
        if [ "$sort_mode" = "size" ]; then
          local s1="${INSTALLER_SIZES_KB[$idx1]:-0}"
          local s2="${INSTALLER_SIZES_KB[$idx2]:-0}"
          if [ "$reverse" = 1 ]; then
            [ "$s1" -gt "$s2" ] && swap=1
          else
            [ "$s1" -lt "$s2" ] && swap=1
          fi
        else
          local n1="${INSTALLER_FILES[$idx1]##*/}"
          local n2="${INSTALLER_FILES[$idx2]##*/}"
          if [ "$reverse" = 1 ]; then
            [ "$n1" \< "$n2" ] && swap=1
          else
            [ "$n1" \> "$n2" ] && swap=1
          fi
        fi
        if [ "$swap" = 1 ]; then
          temp="${INSTALLER_VIEW_INDICES[$i]}"
          INSTALLER_VIEW_INDICES[$i]="${INSTALLER_VIEW_INDICES[$j]}"
          INSTALLER_VIEW_INDICES[$j]="$temp"
        fi
      done
    done
  fi
}

# Interactive Paginated Selector for Installers
interactive_installer_selector() {
  local count="${#INSTALLER_FILES[@]}"
  [ "$count" -gt 0 ] || return 0

  local cur=0 top=0 vh rows cols drawn key frame
  local sort_mode="size" sort_rev=0 search_query="" search_mode=0
  installer_build_indices "$search_query" "$sort_mode" "$sort_rev"

  enter_alt_screen
  tui_begin
  drawn=0

  while true; do
    local vcount="${#INSTALLER_VIEW_INDICES[@]}"
    rows="$(paginated_term_rows)"
    cols="$(paginated_term_cols)"
    vh=$((rows - 8))
    [ "$vh" -lt 3 ] && vh=3
    [ "$vh" -gt "$vcount" ] && vh="$vcount"
    [ "$cur" -lt "$top" ] && top="$cur"
    [ "$cur" -ge $((top + vh)) ] && top=$((cur - vh + 1))
    [ "$top" -lt 0 ] && top=0

    # Draw frame
    frame="$(
      printf '%s\n' "${C_CYAN}${C_BOLD}MIMI INSTALLER CLEANER${C_RESET} — Select packages to remove"
      local sel_count=0 sel_kb=0 idx
      for ((idx = 0; idx < count; idx++)); do
        if [ "${INSTALLER_SELECTED[$idx]}" = 1 ]; then
          sel_count=$((sel_count + 1))
          sel_kb=$((sel_kb + INSTALLER_SIZES_KB[idx]))
        fi
      done
      printf '%s\n' "${C_DIM}Found: $count packages • Selected: $sel_count ($(human_kb "$sel_kb"))${C_RESET}"
      if [ "$search_mode" = 1 ]; then
        printf '%s\n' "${C_CYAN}Search:${C_RESET} ${search_query}_"
      else
        printf '%s\n' "${C_DIM}↑/↓:Move  Space:Toggle  a:All  x:None  /:Search  s:Sort  Enter:Clean  q:Quit${C_RESET}"
      fi
      printf '%s\n' "─────────────────────────────────────────────────────────────────"

      local end=$((top + vh))
      [ "$end" -gt "$vcount" ] && end="$vcount"
      local r
      for ((r = top; r < end; r++)); do
        local orig_idx="${INSTALLER_VIEW_INDICES[$r]}"
        local file="${INSTALLER_FILES[$orig_idx]}"
        local name="${file##*/}"
        local src="${INSTALLER_SOURCES[$orig_idx]}"
        local sz
        sz="$(human_kb "${INSTALLER_SIZES_KB[$orig_idx]}")"
        local mark="○"
        [ "${INSTALLER_SELECTED[$orig_idx]}" = 1 ] && mark="${C_CYAN}●${C_RESET}"

        local line_content
        line_content="$(printf '%b  %-30s  %-10s  %8s' "$mark" "${name:0:28}" "$src" "$sz")"
        if [ "$r" = "$cur" ]; then
          printf '%s\n' "${C_BOLD}${C_CYAN}❯ ${line_content}${C_RESET}"
        else
          printf '%s\n' "  ${line_content}"
        fi
      done
    )"

    tui_paint "$drawn" "$frame"
    if [ -z "$frame" ]; then
      drawn=0
    else
      local tmp="${frame//$'\n'/}"
      drawn=$(( ${#frame} - ${#tmp} + 1 ))
    fi

    key="$(read_key)"
    if [ "$search_mode" = 1 ]; then
      case "$key" in
        enter|esc) search_mode=0 ;;
        backspace)
          if [ -n "$search_query" ]; then
            search_query="${search_query%?}"
            installer_build_indices "$search_query" "$sort_mode" "$sort_rev"
            cur=0; top=0
          else
            search_mode=0
          fi
          ;;
        quit|q|Q) search_mode=0 ;;
        [a-zA-Z0-9._\ -])
          search_query="${search_query}${key}"
          installer_build_indices "$search_query" "$sort_mode" "$sort_rev"
          cur=0; top=0
          ;;
        *) ;;
      esac
      continue
    fi

    case "$key" in
      up|k)   cur=$((cur - 1)); [ "$cur" -lt 0 ] && cur=$((vcount - 1)) ;;
      down|j) cur=$((cur + 1)); [ "$cur" -ge "$vcount" ] && cur=0 ;;
      pgup)   cur=$((cur - vh)); [ "$cur" -lt 0 ] && cur=0 ;;
      pgdn)   cur=$((cur + vh)); [ "$cur" -ge "$vcount" ] && cur=$((vcount - 1)) ;;
      home|g) cur=0 ;;
      end|G)  cur=$((vcount - 1)) ;;
      space)
        if [ "$vcount" -gt 0 ]; then
          local target_idx="${INSTALLER_VIEW_INDICES[$cur]}"
          if [ "${INSTALLER_SELECTED[$target_idx]}" = 1 ]; then
            INSTALLER_SELECTED[$target_idx]=0
          else
            INSTALLER_SELECTED[$target_idx]=1
          fi
        fi ;;
      a|A)
        for ((idx = 0; idx < count; idx++)); do INSTALLER_SELECTED[idx]=1; done ;;
      x|X|n|N)
        for ((idx = 0; idx < count; idx++)); do INSTALLER_SELECTED[idx]=0; done ;;
      /)
        search_mode=1 ;;
      s|S)
        if [ "$sort_mode" = "size" ] && [ "$sort_rev" = 0 ]; then
          sort_rev=1
        elif [ "$sort_mode" = "size" ]; then
          sort_mode="name"; sort_rev=0
        else
          sort_mode="size"; sort_rev=0
        fi
        installer_build_indices "$search_query" "$sort_mode" "$sort_rev"
        cur=0; top=0 ;;
      enter)
        tui_clear_frame "$drawn"
        tui_end
        leave_alt_screen
        return 0 ;;
      q|Q|esc|quit)
        tui_clear_frame "$drawn"
        tui_end
        leave_alt_screen
        # Clear selections so nothing is removed
        for ((idx = 0; idx < count; idx++)); do INSTALLER_SELECTED[idx]=0; done
        return 0 ;;
      *) ;;
    esac
  done
}

# Perform removal of selected installers
execute_installer_removal() {
  local is_dry=0
  [ "${DRY_RUN:-0}" = 1 ] && is_dry=1
  local count="${#INSTALLER_FILES[@]}"

  local to_remove_count=0 to_remove_kb=0 idx
  for ((idx = 0; idx < count; idx++)); do
    if [ "${INSTALLER_SELECTED[$idx]}" = 1 ]; then
      to_remove_count=$((to_remove_count + 1))
      to_remove_kb=$((to_remove_kb + INSTALLER_SIZES_KB[idx]))
    fi
  done

  if [ "$to_remove_count" -eq 0 ]; then
    say "No installer packages selected for removal."
    return 0
  fi

  if [ "$is_dry" = 1 ]; then
    say "${C_GREEN}${ICON_SUCCESS} [DRY RUN] Would remove $to_remove_count installer packages ($(human_kb "$to_remove_kb"))${C_RESET}"
    return 0
  fi

  if [ "${ASSUME_YES:-0}" != 1 ]; then
    confirm "Permanently remove $to_remove_count installer package(s) ($(human_kb "$to_remove_kb"))?" || {
      say "Installer cleanup cancelled."
      return 0
    }
  fi

  local removed_count=0 freed_kb=0 failed_count=0
  for ((idx = 0; idx < count; idx++)); do
    [ "${INSTALLER_SELECTED[$idx]}" = 1 ] || continue
    local file="${INSTALLER_FILES[$idx]}"
    local kb="${INSTALLER_SIZES_KB[$idx]}"

    if [ -f "$file" ]; then
      if fs_remove "$file"; then
        removed_count=$((removed_count + 1))
        freed_kb=$((freed_kb + kb))
        verbose "installer removed: $file"
      else
        failed_count=$((failed_count + 1))
        err "installer: failed to remove: $file"
      fi
    fi
  done

  say "${C_GREEN}${ICON_SUCCESS} Removed $removed_count installer package(s), freed $(human_kb "$freed_kb").${C_RESET}"
  [ "$failed_count" -gt 0 ] && warn "$failed_count installer(s) could not be removed."

  history_record "installer" "$([ "$failed_count" -eq 0 ] && echo ok || echo partial)" \
    "freed_kb=$freed_kb" "removed=$removed_count" "failed=$failed_count"
  return 0
}

# Top-level subcommand runner
run_installer() {
  local target_path="${1:-}"
  scan_all_installers "$target_path" || return $?

  local count="${#INSTALLER_FILES[@]}"

  # JSON mode output
  if [ "${JSONL_ENABLED:-0}" = 1 ]; then
    local total_kb
    total_kb="$(installer_total_size_kb)"
    printf '{"type":"installer_scan","candidates_count":%d,"total_reclaimable_kb":%d,"items":[' \
      "$count" "$total_kb"
    local i first=1
    for ((i = 0; i < count; i++)); do
      [ "$first" = 1 ] || printf ','
      first=0
      printf '{"path":"%s","name":"%s","source":"%s","size_kb":%d}' \
        "$(json_escape "${INSTALLER_FILES[$i]}")" \
        "$(json_escape "${INSTALLER_FILES[$i]##*/}")" \
        "$(json_escape "${INSTALLER_SOURCES[$i]}")" \
        "${INSTALLER_SIZES_KB[$i]}"
    done
    printf ']}\n'

    # If --yes or mode=clean and not dry-run, remove all candidates
    if [ "${ASSUME_YES:-0}" = 1 ] && [ "${DRY_RUN:-0}" != 1 ]; then
      local rem=0 freed=0 fail=0
      for ((i = 0; i < count; i++)); do
        local f="${INSTALLER_FILES[$i]}"
        local kb="${INSTALLER_SIZES_KB[$i]}"
        if fs_remove "$f"; then
          rem=$((rem + 1))
          freed=$((freed + kb))
        else
          fail=$((fail + 1))
        fi
      done
      printf '{"type":"installer_cleanup","removed":%d,"freed_kb":%d,"failed":%d}\n' \
        "$rem" "$freed" "$fail"
    fi
    return 0
  fi

  render_installer_card
  [ "$count" -eq 0 ] && return 0

  if [ "${DRY_RUN:-0}" = 1 ]; then
    say "${C_DIM}Run without --dry-run to select and delete packages.${C_RESET}"
    return 0
  fi

  if [ "${ASSUME_YES:-0}" = 1 ]; then
    execute_installer_removal
    return 0
  fi

  if tui_available; then
    interactive_installer_selector
    execute_installer_removal
  else
    execute_installer_removal
  fi
}
