#!/usr/bin/env bash
#
# lib/ui/analyze.sh — Interactive Storage Analyzer & Disk Explorer.
#
# Sourced by lib/load.sh; never executed on its own.
# Analyzes directory storage breakdown, top subdirectories, and largest files
# with visual size bars, interactive drill-down, and JSON output.

analyze_format_kb() {
  local kb="${1:-0}"
  human_kb "$kb"
}

analyze_format_pct() {
  local part="${1:-0}" total="${2:-1}"
  awk -v p="$part" -v t="$total" 'BEGIN { if (t > 0) printf "%d", (p / t) * 100; else print 0 }' 2>/dev/null || echo "0"
}

run_analyze() {
  local target="${1:-}"
  if [ -z "$target" ]; then
    target="$HOME_DIR"
  fi

  # Resolve tilde and relative path
  case "$target" in
    \~|\~/*) target="$HOME_DIR${target#\~}" ;;
    /*) ;;
    *) target="$PWD/$target" ;;
  esac

  if [ ! -d "$target" ]; then
    err "analyze: target is not a directory: $target"
    return 1
  fi

  # Canonicalize path
  local canon_target
  canon_target="$(cd -P "$target" 2>/dev/null && pwd -P || echo "$target")"

  start_spinner "Analyzing storage in $(basename "$canon_target")..."

  local du_out line size_kb entry_path
  du_out="$(du -d 1 -k "$canon_target" 2>/dev/null || true)"

  if [ -z "$du_out" ]; then
    stop_spinner
    err "analyze: unable to read directory: $canon_target"
    return 1
  fi

  local total_kb=0
  local child_paths=()
  local child_kbs=()
  local child_names=()
  local child_count=0

  # First parse the target total and collect direct children
  while IFS=$'\t' read -r size_kb entry_path; do
    [ -n "$size_kb" ] && [ -n "$entry_path" ] || continue
    case "$size_kb" in ''|*[!0-9]*) continue ;; esac

    # Strip trailing slash if present
    entry_path="${entry_path%/}"

    if [ "$entry_path" = "$canon_target" ] || [ "$entry_path" = "$target" ]; then
      total_kb="$size_kb"
    else
      local bname
      bname="$(basename "$entry_path")"
      child_paths[child_count]="$entry_path"
      child_kbs[child_count]="$size_kb"
      child_names[child_count]="$bname"
      child_count=$((child_count + 1))
    fi
  done <<< "$du_out"

  # Simple sorting: bubble sort or selection sort child arrays descending by size
  # (child_count is typically <= 100 entries at depth 1)
  local i j max_idx tmp_kb tmp_path tmp_name
  for ((i = 0; i < child_count - 1; i++)); do
    max_idx=$i
    for ((j = i + 1; j < child_count; j++)); do
      if [ "${child_kbs[j]}" -gt "${child_kbs[max_idx]}" ]; then
        max_idx=$j
      fi
    done
    if [ "$max_idx" -ne "$i" ]; then
      tmp_kb="${child_kbs[i]}"
      tmp_path="${child_paths[i]}"
      tmp_name="${child_names[i]}"

      child_kbs[i]="${child_kbs[max_idx]}"
      child_paths[i]="${child_paths[max_idx]}"
      child_names[i]="${child_names[max_idx]}"

      child_kbs[max_idx]="$tmp_kb"
      child_paths[max_idx]="$tmp_path"
      child_names[max_idx]="$tmp_name"
    fi
  done

  update_spinner_message "Finding largest files in $(basename "$canon_target")..."

  local large_files_kb=()
  local large_files_path=()
  local large_count=0
  local f_kb f_p

  while IFS=$'\t' read -r f_kb f_p; do
    [ -n "$f_kb" ] && [ -n "$f_p" ] || continue
    case "$f_kb" in ''|*[!0-9]*) continue ;; esac
    large_files_kb[large_count]="$f_kb"
    large_files_path[large_count]="$f_p"
    large_count=$((large_count + 1))
  done < <(
    find "$canon_target" -xdev -type f -size +10M -exec du -k {} + 2>/dev/null | sort -rn | head -8 || true
  )

  # Fallback if no files >10M
  if [ "$large_count" -eq 0 ]; then
    while IFS=$'\t' read -r f_kb f_p; do
      [ -n "$f_kb" ] && [ -n "$f_p" ] || continue
      case "$f_kb" in ''|*[!0-9]*) continue ;; esac
      large_files_kb[large_count]="$f_kb"
      large_files_path[large_count]="$f_p"
      large_count=$((large_count + 1))
    done < <(
      find "$canon_target" -xdev -type f -exec du -k {} + 2>/dev/null | sort -rn | head -8 || true
    )
  fi

  stop_spinner

  # JSON mode
  if [ "${JSONL_ENABLED:-0}" = 1 ]; then
    printf '{"type":"storage_analysis","target":"%s","total_kb":%s,"total_human":"%s","children":[' \
      "$(json_escape "$canon_target")" "$total_kb" "$(json_escape "$(analyze_format_kb "$total_kb")")"

    local c_json=""
    for ((i = 0; i < child_count; i++)); do
      local pct
      pct="$(analyze_format_pct "${child_kbs[i]}" "$total_kb")"
      [ -n "$c_json" ] && c_json="$c_json,"
      c_json="$c_json$(printf '{"name":"%s","path":"%s","kb":%s,"human":"%s","percent":%s}' \
        "$(json_escape "${child_names[i]}")" "$(json_escape "${child_paths[i]}")" "${child_kbs[i]}" \
        "$(json_escape "$(analyze_format_kb "${child_kbs[i]}")")" "$pct")"
    done
    printf '%s],"largest_files":[' "$c_json"

    local f_json=""
    for ((i = 0; i < large_count; i++)); do
      [ -n "$f_json" ] && f_json="$f_json,"
      f_json="$f_json$(printf '{"name":"%s","path":"%s","kb":%s,"human":"%s"}' \
        "$(json_escape "$(basename "${large_files_path[i]}")")" "$(json_escape "${large_files_path[i]}")" \
        "${large_files_kb[i]}" "$(json_escape "$(analyze_format_kb "${large_files_kb[i]}")")")"
    done
    printf '%s]}\n' "$f_json"
    return 0
  fi

  # Terminal Output
  printf '\n'
  printf '%s┌─ Storage Analysis: %-47s┐%s\n' "$C_CYAN" "${canon_target:0:47}" "$C_RESET"
  printf '%s│%s  Total Allocated: %-49s %s│%s\n' "$C_CYAN" "$C_RESET" "${C_BOLD}$(analyze_format_kb "$total_kb")${C_RESET}" "$C_CYAN" "$C_RESET"
  printf '%s│%s                                                                    %s│%s\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
  printf '%s│%s  %sTop Direct Folders:%s                                                %s│%s\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_CYAN" "$C_RESET"

  local limit=8
  [ "$child_count" -lt "$limit" ] && limit="$child_count"

  if [ "$limit" -eq 0 ]; then
    printf '%s│%s    (no subdirectories)                                             %s│%s\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
  else
    for ((i = 0; i < limit; i++)); do
      local p_pct p_bar h_sz name_disp
      p_pct="$(analyze_format_pct "${child_kbs[i]}" "$total_kb")"
      p_bar="$(render_health_bar "$p_pct" 14)"
      h_sz="$(analyze_format_kb "${child_kbs[i]}")"
      name_disp="${child_names[i]}/"
      [ "${#name_disp}" -gt 28 ] && name_disp="${name_disp:0:25}..."
      printf '%s│%s   %s %3d%%  %8s  %-28s %s│%s\n' "$C_CYAN" "$C_RESET" "$p_bar" "$p_pct" "$h_sz" "$name_disp" "$C_CYAN" "$C_RESET"
    done
  fi

  if [ "$large_count" -gt 0 ]; then
    printf '%s│%s                                                                    %s│%s\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf '%s│%s  %sLargest Files:%s                                                     %s│%s\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_CYAN" "$C_RESET"
    local f_limit=6
    [ "$large_count" -lt "$f_limit" ] && f_limit="$large_count"
    for ((i = 0; i < f_limit; i++)); do
      local f_sz f_name
      f_sz="$(analyze_format_kb "${large_files_kb[i]}")"
      f_name="$(basename "${large_files_path[i]}")"
      [ "${#f_name}" -gt 46 ] && f_name="${f_name:0:43}..."
      printf '%s│%s   • %-8s %-50s %s│%s\n' "$C_CYAN" "$C_RESET" "$f_sz" "$f_name" "$C_CYAN" "$C_RESET"
    done
  fi

  printf '%s└────────────────────────────────────────────────────────────────────┘%s\n' "$C_CYAN" "$C_RESET"
  printf '\n'

  # Interactive drill-down prompt if connected to terminal
  if [ -t 0 ] && [ "$child_count" -gt 0 ] && [ "${ANALYZE_NO_PROMPT:-0}" != 1 ]; then
    printf '%sExplore folder:%s [1-%d] select  [b] back  [o] open in Finder  [q] quit > ' \
      "$C_DIM" "$C_RESET" "$limit"
    local choice=""
    _tui_read -r choice 2>/dev/null || read -r -p "> " choice </dev/tty 2>/dev/null || choice=""
    case "$choice" in
      [1-9])
        local idx=$((choice - 1))
        if [ "$idx" -lt "$child_count" ]; then
          run_analyze "${child_paths[idx]}"
        fi
        ;;
      b|B)
        local parent
        parent="$(dirname "$canon_target")"
        if [ "$parent" != "$canon_target" ] && [ -d "$parent" ]; then
          run_analyze "$parent"
        fi
        ;;
      o|O)
        command -v open >/dev/null 2>&1 && open "$canon_target" 2>/dev/null || true
        ;;
      q|Q|"") ;;
    esac
  fi

  return 0
}
