#!/usr/bin/env bash
#
# lib/cleaners/purge.sh — Project build artifacts scanner and purge engine (Phase 11).
#
# Inspired by Mole's purge module (mo purge). Discovers heavy build artifacts and
# dependencies (node_modules, target, .build, DerivedData, .venv, build, dist,
# .gradle, .next, etc.) within developer project trees and provides interactive
# multi-selection, dry-run previews, and safe verified direct removal.
#
# Sourced by lib/load.sh; never executed on its own.
# Compatible with macOS /bin/bash 3.2+.
#

PURGE_CONFIG_FILE="${CONFIG_DIR:-$HOME/.config/mimi}/purge_paths"

PURGE_PROJECT_NAMES=()
PURGE_PROJECT_PATHS=()
PURGE_ARTIFACT_PATHS=()
PURGE_ARTIFACT_TYPES=()
PURGE_SIZES_KB=()
PURGE_SELECTED=()
PURGE_VIEW_INDICES=()

# Known heavy project build artifact directory names
is_purge_target_name() {
  case "$1" in
    node_modules|target|build|dist|venv|.venv|.pytest_cache|.mypy_cache|.ruff_cache) return 0 ;;
    .gradle|.next|.nuxt|.output|.turbo|.parcel-cache|vendor|.dart_tool|.zig-cache|zig-out) return 0 ;;
    .angular|.svelte-kit|.astro|coverage|DerivedData|.build|Pods|.cxx|__pycache__) return 0 ;;
    *) return 1 ;;
  esac
}

# Project root indicators (manifests or VCS that establish a directory as a code project)
has_project_indicator() {
  local dir="$1"
  [ -d "$dir" ] || return 1

  [ -f "$dir/package.json" ] && return 0
  [ -f "$dir/Cargo.toml" ] && return 0
  [ -f "$dir/Package.swift" ] && return 0
  [ -f "$dir/pom.xml" ] && return 0
  [ -f "$dir/build.gradle" ] || [ -f "$dir/build.gradle.kts" ] || [ -f "$dir/settings.gradle" ] && return 0
  [ -f "$dir/pyproject.toml" ] || [ -f "$dir/requirements.txt" ] || [ -f "$dir/Pipfile" ] || [ -f "$dir/setup.py" ] && return 0
  [ -f "$dir/composer.json" ] && return 0
  [ -f "$dir/go.mod" ] && return 0
  [ -f "$dir/pubspec.yaml" ] && return 0
  [ -f "$dir/build.zig" ] && return 0
  [ -f "$dir/Podfile" ] && return 0
  [ -d "$dir/.git" ] && return 0
  return 1
}

# Find project root for a given build artifact
find_project_root_for_artifact() {
  local artifact_path="$1"
  local parent="${artifact_path%/*}"
  local p="$parent"
  local depth=0

  while [ "$depth" -lt 3 ]; do
    [ -z "$p" ] && break
    [ "$p" = "$HOME_DIR" ] && break
    [ "$p" = "/" ] && break

    if has_project_indicator "$p"; then
      printf '%s' "$p"
      return 0
    fi
    p="${p%/*}"
    depth=$((depth + 1))
  done

  # Fallback to direct parent if non-empty
  printf '%s' "$parent"
}

# Resolve candidate search paths
purge_get_search_paths() {
  local explicit="${1:-}"
  if [ -n "$explicit" ]; then
    printf '%s\n' "$explicit"
    return 0
  fi

  # 1. Configured custom paths
  if [ -f "$PURGE_CONFIG_FILE" ]; then
    local line
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [ -z "$line" ] && continue
      [[ "$line" == \#* ]] && continue
      # Expand ~ if present
      line="${line/#\~/$HOME_DIR}"
      if [ -d "$line" ]; then
        printf '%s\n' "$line"
      fi
    done < "$PURGE_CONFIG_FILE"
    return 0
  fi

  # 2. Defaults if existing
  local default_roots=(
    "$HOME_DIR/Dev"
    "$HOME_DIR/Projects"
    "$HOME_DIR/Code"
    "$HOME_DIR/Developer"
    "$HOME_DIR/Workspace"
    "$HOME_DIR/src"
    "$HOME_DIR/GitHub"
    "$HOME_DIR/www"
  )
  local found=0 r
  for r in "${default_roots[@]}"; do
    if [ -d "$r" ]; then
      printf '%s\n' "$r"
      found=1
    fi
  done

  # Fallback to current working directory if none of the default dev roots exist
  if [ "$found" -eq 0 ]; then
    printf '%s\n' "$(pwd)"
  fi
}

# Show and manage purge paths
purge_manage_paths() {
  section "Configured project purge search paths"
  if [ -f "$PURGE_CONFIG_FILE" ]; then
    say "Configuration file: $PURGE_CONFIG_FILE"
    local line count=0
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [ -z "$line" ] && continue
      [[ "$line" == \#* ]] && continue
      count=$((count + 1))
      say "  $count) $line"
    done < "$PURGE_CONFIG_FILE"
    [ "$count" -eq 0 ] && say "  (No paths configured; using defaults)"
  else
    say "No custom search paths configured."
    say "Default scanned developer directories (if present):"
    say "  ~/Dev, ~/Projects, ~/Code, ~/Developer, ~/Workspace, ~/src, ~/GitHub, ~/www"
    say ""
    say "To set custom search paths, create '$PURGE_CONFIG_FILE' with one directory per line."
  fi
}

# Check if a path should be skipped during project search
is_purge_forbidden_dir() {
  local p="$1"
  local base="${p##*/}"

  case "$base" in
    .git|.hg|.svn|.Trash|Library|Applications|Movies|Music|Pictures|Public|System)
      return 0 ;;
  esac

  case "$p" in
    "/System"*|"/Library"*|"/Applications"*|"/usr"*|"/bin"*|"/sbin"*)
      return 0 ;;
    "$HOME_DIR/Library"*|"$HOME_DIR/.Trash"*)
      return 0 ;;
  esac
  return 1
}

# Reset scanner state
purge_reset_state() {
  PURGE_PROJECT_NAMES=()
  PURGE_PROJECT_PATHS=()
  PURGE_ARTIFACT_PATHS=()
  PURGE_ARTIFACT_TYPES=()
  PURGE_SIZES_KB=()
  PURGE_SELECTED=()
  PURGE_VIEW_INDICES=()
}

# Scan a single directory tree recursively (up to max depth 5)
_scan_purge_tree() {
  local dir="$1" max_depth="${2:-5}"
  [ -d "$dir" ] || return 0
  is_purge_forbidden_dir "$dir" && return 0

  # Use find with prune for performance, portability, and safety
  local found_paths=()
  while IFS= read -r match || [ -n "$match" ]; do
    [ -n "$match" ] || continue
    found_paths+=("$match")
  done < <(
    find "$dir" -maxdepth "$max_depth" \
      \( -name ".git" -o -name ".Trash" -o -name "Library" -o -name "Applications" \) -prune -o \
      -type d \( \
        -name "node_modules" -o \
        -name "target" -o \
        -name "build" -o \
        -name "dist" -o \
        -name "venv" -o \
        -name ".venv" -o \
        -name ".pytest_cache" -o \
        -name ".mypy_cache" -o \
        -name ".ruff_cache" -o \
        -name ".gradle" -o \
        -name ".next" -o \
        -name ".nuxt" -o \
        -name ".output" -o \
        -name ".turbo" -o \
        -name ".parcel-cache" -o \
        -name "vendor" -o \
        -name ".dart_tool" -o \
        -name ".zig-cache" -o \
        -name "zig-out" -o \
        -name ".angular" -o \
        -name ".svelte-kit" -o \
        -name ".astro" -o \
        -name "coverage" -o \
        -name "DerivedData" -o \
        -name ".build" -o \
        -name "Pods" -o \
        -name ".cxx" -o \
        -name "__pycache__" \
      \) -prune -print 2>/dev/null
  )

  local p
  for p in "${found_paths[@]}"; do
    [ -d "$p" ] || continue
    is_whitelisted "$p" && continue

    local bname="${p##*/}"
    local proj_root
    proj_root="$(find_project_root_for_artifact "$p")"

    # Strict check for ambiguous names: build, dist, vendor
    # They must have a recognized project indicator or .git in proj_root
    case "$bname" in
      build|dist|vendor)
        if ! has_project_indicator "$proj_root"; then
          continue
        fi
        ;;
    esac

    # Ensure artifact is not the project root itself or home
    [ "$p" = "$proj_root" ] && continue
    [ "$p" = "$HOME_DIR" ] && continue
    [ "$p" = "$dir" ] && continue

    local proj_name="${proj_root##*/}"
    update_spinner_message "Measuring: $proj_name / $bname"

    local sz_kb
    sz_kb="$(dir_size_kb "$p")"
    [ "$sz_kb" -gt 0 ] || continue

    PURGE_PROJECT_NAMES+=("$proj_name")
    PURGE_PROJECT_PATHS+=("$proj_root")
    PURGE_ARTIFACT_PATHS+=("$p")
    PURGE_ARTIFACT_TYPES+=("$bname")
    PURGE_SIZES_KB+=("$sz_kb")
    PURGE_SELECTED+=(1)
  done
}

# Scan all search paths for purgeable build artifacts
scan_all_purge_artifacts() {
  local target="${1:-}"
  purge_reset_state

  local search_paths=()
  while IFS= read -r p || [ -n "$p" ]; do
    [ -n "$p" ] && search_paths+=("$p")
  done < <(purge_get_search_paths "$target")

  if [ "${#search_paths[@]}" -eq 0 ]; then
    return 0
  fi

  start_spinner "Scanning projects for build artifacts..."
  local sp
  for sp in "${search_paths[@]}"; do
    update_spinner_message "Scanning: $sp"
    _scan_purge_tree "$sp" 5
  done
  stop_spinner
}

# Total reclaimed KB
purge_total_size_kb() {
  local total=0 kb
  for kb in "${PURGE_SIZES_KB[@]}"; do
    total=$((total + kb))
  done
  printf '%d' "$total"
}

# Render summary card
render_purge_card() {
  local count="${#PURGE_ARTIFACT_PATHS[@]}"
  local total_kb
  total_kb="$(purge_total_size_kb)"

  say ""
  say "${C_BOLD}Project Build Artifacts (Purge)${C_RESET}"
  say "Found: ${C_CYAN}$count${C_RESET} artifact folder(s) • Total reclaimable: ${C_GREEN}$(human_kb "$total_kb")${C_RESET}"
  say "─────────────────────────────────────────────────────────────────"

  if [ "$count" -eq 0 ]; then
    say "  ${C_DIM}No project build artifacts found in scanned paths.${C_RESET}"
    say ""
    return 0
  fi

  local max_display=12 i
  [ "$count" -lt "$max_display" ] && max_display="$count"

  for ((i = 0; i < max_display; i++)); do
    local proj="${PURGE_PROJECT_NAMES[$i]}"
    local atype="${PURGE_ARTIFACT_TYPES[$i]}"
    local path="${PURGE_ARTIFACT_PATHS[$i]}"
    local kb="${PURGE_SIZES_KB[$i]}"
    local rel_path="${path/#$HOME_DIR/~}"

    printf '  %-20s %-15s %10s  %s\n' \
      "$proj" "[$atype]" "$(human_kb "$kb")" "${C_DIM}$rel_path${C_RESET}"
  done

  if [ "$count" -gt "$max_display" ]; then
    say "  ${C_DIM}... and $((count - max_display)) more build artifact(s)${C_RESET}"
  fi
  say ""
}

# Build view indices for interactive purge menu
purge_build_indices() {
  local query="${1:-}" sort_mode="${2:-size}" reverse="${3:-0}"
  local count="${#PURGE_ARTIFACT_PATHS[@]}" i query_lower
  PURGE_VIEW_INDICES=()
  [ "$count" -gt 0 ] || return 0

  query_lower="$(_paginated_to_lower "$query")"
  for ((i = 0; i < count; i++)); do
    local proj="${PURGE_PROJECT_NAMES[$i]}"
    local atype="${PURGE_ARTIFACT_TYPES[$i]}"
    local path="${PURGE_ARTIFACT_PATHS[$i]}"

    if [ -n "$query_lower" ]; then
      local proj_l atype_l path_l
      proj_l="$(_paginated_to_lower "$proj")"
      atype_l="$(_paginated_to_lower "$atype")"
      path_l="$(_paginated_to_lower "$path")"

      case "$proj_l" in *"$query_lower"*) ;; *)
        case "$atype_l" in *"$query_lower"*) ;; *)
          case "$path_l" in *"$query_lower"*) ;; *) continue ;; esac
        ;; esac
      ;; esac
    fi
    PURGE_VIEW_INDICES+=("$i")
  done

  # Sorting: size, name, or type
  local vcount="${#PURGE_VIEW_INDICES[@]}" j temp
  if [ "$vcount" -gt 1 ]; then
    for ((i = 0; i < vcount - 1; i++)); do
      for ((j = i + 1; j < vcount; j++)); do
        local idx1="${PURGE_VIEW_INDICES[$i]}"
        local idx2="${PURGE_VIEW_INDICES[$j]}"
        local swap=0
        if [ "$sort_mode" = "size" ]; then
          local s1="${PURGE_SIZES_KB[$idx1]:-0}"
          local s2="${PURGE_SIZES_KB[$idx2]:-0}"
          if [ "$reverse" = 1 ]; then
            [ "$s1" -gt "$s2" ] && swap=1
          else
            [ "$s1" -lt "$s2" ] && swap=1
          fi
        elif [ "$sort_mode" = "type" ]; then
          local t1="${PURGE_ARTIFACT_TYPES[$idx1]}"
          local t2="${PURGE_ARTIFACT_TYPES[$idx2]}"
          if [ "$reverse" = 1 ]; then
            [ "$t1" \< "$t2" ] && swap=1
          else
            [ "$t1" \> "$t2" ] && swap=1
          fi
        else
          local n1="${PURGE_PROJECT_NAMES[$idx1]}"
          local n2="${PURGE_PROJECT_NAMES[$idx2]}"
          if [ "$reverse" = 1 ]; then
            [ "$n1" \< "$n2" ] && swap=1
          else
            [ "$n1" \> "$n2" ] && swap=1
          fi
        fi
        if [ "$swap" = 1 ]; then
          temp="${PURGE_VIEW_INDICES[$i]}"
          PURGE_VIEW_INDICES[$i]="${PURGE_VIEW_INDICES[$j]}"
          PURGE_VIEW_INDICES[$j]="$temp"
        fi
      done
    done
  fi
}

# Interactive Paginated Selector for Project Purge
interactive_purge_selector() {
  local count="${#PURGE_ARTIFACT_PATHS[@]}"
  [ "$count" -gt 0 ] || return 0

  local cur=0 top=0 vh rows cols drawn key frame
  local sort_mode="size" sort_rev=0 search_query="" search_mode=0
  purge_build_indices "$search_query" "$sort_mode" "$sort_rev"

  enter_alt_screen
  tui_begin
  drawn=0

  while true; do
    local vcount="${#PURGE_VIEW_INDICES[@]}"
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
      printf '%s\n' "${C_CYAN}${C_BOLD}MIMI PROJECT PURGE${C_RESET} — Select build artifacts to purge"
      local sel_count=0 sel_kb=0 idx
      for ((idx = 0; idx < count; idx++)); do
        if [ "${PURGE_SELECTED[$idx]}" = 1 ]; then
          sel_count=$((sel_count + 1))
          sel_kb=$((sel_kb + PURGE_SIZES_KB[idx]))
        fi
      done
      printf '%s\n' "${C_DIM}Found: $count artifacts • Selected: $sel_count ($(human_kb "$sel_kb"))${C_RESET}"
      if [ "$search_mode" = 1 ]; then
        printf '%s\n' "${C_CYAN}Search:${C_RESET} ${search_query}_"
      else
        printf '%s\n' "${C_DIM}↑/↓:Move  Space:Toggle  a:All  x:None  /:Search  s:Sort  Enter:Purge  q:Quit${C_RESET}"
      fi
      printf '%s\n' "─────────────────────────────────────────────────────────────────"

      if [ "$vcount" -eq 0 ]; then
        printf '%s\n' "  ${C_DIM}(No build artifacts match filter '${search_query}')${C_RESET}"
      else
        local end=$((top + vh)) i
        [ "$end" -gt "$vcount" ] && end="$vcount"
        for ((i = top; i < end; i++)); do
          local a_idx="${PURGE_VIEW_INDICES[$i]}"
          local proj="${PURGE_PROJECT_NAMES[$a_idx]}"
          local atype="${PURGE_ARTIFACT_TYPES[$a_idx]}"
          local kb="${PURGE_SIZES_KB[$a_idx]}"
          local is_sel="${PURGE_SELECTED[$a_idx]}"

          local mark="[ ]"
          [ "$is_sel" = 1 ] && mark="[${C_GREEN}●${C_RESET}]"

          local prefix="  "
          [ "$i" -eq "$cur" ] && prefix="${C_CYAN}❯${C_RESET} "

          local line
          line="$(printf '%s%s %-18s %-14s %10s' \
            "$prefix" "$mark" "$proj" "[$atype]" "$(human_kb "$kb")")"

          if [ "$i" -eq "$cur" ]; then
            printf '%s\n' "${C_BOLD}${line}${C_RESET}"
          else
            printf '%s\n' "$line"
          fi
        done
      fi
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
        enter|esc)
          search_mode=0
          ;;
        backspace)
          if [ -n "$search_query" ]; then
            search_query="${search_query%?}"
            purge_build_indices "$search_query" "$sort_mode" "$sort_rev"
            cur=0; top=0
          else
            search_mode=0
          fi
          ;;
        [a-zA-Z0-9._-])
          search_query="${search_query}${key}"
          purge_build_indices "$search_query" "$sort_mode" "$sort_rev"
          cur=0; top=0
          ;;
      esac
      continue
    fi

    case "$key" in
      up|k)   cur=$((cur - 1)); [ "$cur" -lt 0 ] && cur=$((vcount - 1)) ;;
      down|j) cur=$((cur + 1)); [ "$cur" -ge "$vcount" ] && cur=0 ;;
      home|g) cur=0 ;;
      end|G)  cur=$((vcount - 1)) ;;
      space)
        if [ "$vcount" -gt 0 ] && [ "$cur" -lt "$vcount" ]; then
          local real_idx="${PURGE_VIEW_INDICES[$cur]}"
          if [ "${PURGE_SELECTED[$real_idx]}" = 1 ]; then
            PURGE_SELECTED[$real_idx]=0
          else
            PURGE_SELECTED[$real_idx]=1
          fi
        fi
        ;;
      a|A)
        for ((idx = 0; idx < count; idx++)); do PURGE_SELECTED[$idx]=1; done
        ;;
      x|X|n|N)
        for ((idx = 0; idx < count; idx++)); do PURGE_SELECTED[$idx]=0; done
        ;;
      s|S)
        if [ "$sort_mode" = "size" ]; then
          sort_mode="name"
        elif [ "$sort_mode" = "name" ]; then
          sort_mode="type"
        else
          sort_mode="size"
        fi
        purge_build_indices "$search_query" "$sort_mode" "$sort_rev"
        cur=0; top=0
        ;;
      /)
        search_mode=1
        ;;
      enter)
        tui_clear_frame "$drawn"
        tui_end
        leave_alt_screen
        return 0
        ;;
      q|Q|esc|quit)
        tui_clear_frame "$drawn"
        tui_end
        leave_alt_screen
        # Deselect all on quit
        for ((idx = 0; idx < count; idx++)); do PURGE_SELECTED[$idx]=0; done
        return 0
        ;;
      *) ;;
    esac
  done
}

# Perform removal of selected build artifacts
execute_purge_removal() {
  local is_dry=0
  [ "${DRY_RUN:-0}" = 1 ] && is_dry=1
  local count="${#PURGE_ARTIFACT_PATHS[@]}"

  local to_remove_count=0 to_remove_kb=0 idx
  for ((idx = 0; idx < count; idx++)); do
    if [ "${PURGE_SELECTED[$idx]}" = 1 ]; then
      to_remove_count=$((to_remove_count + 1))
      to_remove_kb=$((to_remove_kb + PURGE_SIZES_KB[idx]))
    fi
  done

  if [ "$to_remove_count" -eq 0 ]; then
    say "No project build artifacts selected for purging."
    return 0
  fi

  if [ "$is_dry" = 1 ]; then
    say "${C_GREEN}${ICON_SUCCESS} [DRY RUN] Would purge $to_remove_count project build artifact(s) ($(human_kb "$to_remove_kb"))${C_RESET}"
    return 0
  fi

  if [ "${ASSUME_YES:-0}" != 1 ]; then
    confirm "Permanently remove $to_remove_count project build artifact(s) ($(human_kb "$to_remove_kb"))?" || {
      say "Project purge cancelled."
      return 0
    }
  fi

  local removed_count=0 freed_kb=0 failed_count=0
  for ((idx = 0; idx < count; idx++)); do
    [ "${PURGE_SELECTED[$idx]}" = 1 ] || continue
    local p="${PURGE_ARTIFACT_PATHS[$idx]}"
    local kb="${PURGE_SIZES_KB[$idx]}"

    if [ -d "$p" ]; then
      if clear_dir_contents "$p" && fs_remove "$p"; then
        removed_count=$((removed_count + 1))
        freed_kb=$((freed_kb + kb))
        verbose "purged build artifact: $p"
      else
        failed_count=$((failed_count + 1))
        err "purge: failed to remove: $p"
      fi
    fi
  done

  say "${C_GREEN}${ICON_SUCCESS} Purged $removed_count project build artifact(s), freed $(human_kb "$freed_kb").${C_RESET}"
  [ "$failed_count" -gt 0 ] && warn "$failed_count artifact(s) could not be removed."

  history_record "purge" "$([ "$failed_count" -eq 0 ] && echo ok || echo partial)" \
    "freed_kb=$freed_kb" "removed=$removed_count" "failed=$failed_count"
  return 0
}

# Top-level subcommand runner
run_purge() {
  local target_path="${1:-}"

  if [ "${PURGE_SHOW_PATHS:-0}" = 1 ]; then
    purge_manage_paths
    return 0
  fi

  scan_all_purge_artifacts "$target_path" || return $?
  local count="${#PURGE_ARTIFACT_PATHS[@]}"

  # JSON mode output
  if [ "${JSONL_ENABLED:-0}" = 1 ]; then
    local total_kb
    total_kb="$(purge_total_size_kb)"
    printf '{"type":"purge_scan","candidates_count":%d,"total_reclaimable_kb":%d,"items":[' \
      "$count" "$total_kb"
    local i first=1
    for ((i = 0; i < count; i++)); do
      [ "$first" = 1 ] || printf ','
      first=0
      printf '{"path":"%s","project":"%s","type":"%s","size_kb":%d}' \
        "$(json_escape "${PURGE_ARTIFACT_PATHS[$i]}")" \
        "$(json_escape "${PURGE_PROJECT_NAMES[$i]}")" \
        "$(json_escape "${PURGE_ARTIFACT_TYPES[$i]}")" \
        "${PURGE_SIZES_KB[$i]}"
    done
    printf ']}\n'

    # If --yes and not dry-run, remove all candidates
    if [ "${ASSUME_YES:-0}" = 1 ] && [ "${DRY_RUN:-0}" != 1 ]; then
      local rem=0 freed=0 fail=0
      for ((i = 0; i < count; i++)); do
        local p="${PURGE_ARTIFACT_PATHS[$i]}"
        local kb="${PURGE_SIZES_KB[$i]}"
        if clear_dir_contents "$p" && fs_remove "$p"; then
          rem=$((rem + 1))
          freed=$((freed + kb))
        else
          fail=$((fail + 1))
        fi
      done
      printf '{"type":"purge_cleanup","removed":%d,"freed_kb":%d,"failed":%d}\n' \
        "$rem" "$freed" "$fail"
    fi
    return 0
  fi

  render_purge_card
  [ "$count" -eq 0 ] && return 0

  if [ "${DRY_RUN:-0}" = 1 ]; then
    say "${C_DIM}Run without --dry-run to select and purge build artifacts.${C_RESET}"
    return 0
  fi

  if [ "${ASSUME_YES:-0}" = 1 ]; then
    execute_purge_removal
    return 0
  fi

  if tui_available; then
    interactive_purge_selector
    execute_purge_removal
  else
    execute_purge_removal
  fi
}
