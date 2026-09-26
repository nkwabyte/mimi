#!/usr/bin/env bash
#
# lib/ui/tui.sh lib/tui.sh — Interactive terminal UI and menu navigation.
#
# Sourced by lib/load.sh; never executed on its own. Defines functions and
# state helpers for interactive terminal operation.


# ---------------------------------------------------------------------------
# Interactive mode
# ---------------------------------------------------------------------------

compute_code_default_ids() {
  local ids="" id info default
  for id in $ALL_CATEGORY_IDS; do
    info="$(category_info "$id")"
    default="$(printf '%s' "$info" | cut -d'|' -f2)"
    [ "$default" = "1" ] && ids="${ids:+$ids,}$id"
  done
  printf '%s' "$ids"
}

reset_all_include_vars() {
  local id var
  for id in $ALL_CATEGORY_IDS; do
    var="$(category_include_var "$id")"
    [ -n "$var" ] && printf -v "$var" '0'
  done
}

interactive_pause() {
  read -r -p "Press Enter to continue..." _ </dev/tty
}

print_live_category_state() {
  printf '%-16s %-9s %-6s %s\n' "ID" "RISK" "STATE" "DESCRIPTION"
  local i id info risk desc state
  for i in "${!CATEGORY_STATE_IDS[@]}"; do
    id="${CATEGORY_STATE_IDS[$i]}"
    info="$(category_info "$id")"
    risk="$(printf '%s' "$info" | cut -d'|' -f1)"
    desc="$(printf '%s' "$info" | cut -d'|' -f3)"
    [ "${CATEGORY_STATE_ON[$i]}" = "1" ] && state="on" || state="off"
    printf '%-16s %-9s %-6s %s\n' "$id" "$risk" "$state" "$desc"
  done
}

view_last_log() {
  local f
  f="$(ls -t "$LOG_DIR"/clean-*.log 2>/dev/null | head -1)"
  if [ -z "$f" ]; then
    info "no log files yet"
    return
  fi
  say "Showing last 60 lines of: $f"
  say "---"
  tail -60 "$f"
  say "---"
}

# ---------------------------------------------------------------------------
# Keyboard-driven menus
#
# Arrow keys to move, space to toggle, enter to accept. Written against bash
# 3.2 (macOS /bin/bash): no fractional `read -t`, no associative arrays, so
# escape sequences are read as a fixed 2-char follow-up, and the whole picker
# state lives in the parallel CATEGORY_STATE_* arrays.
#
# Everything degrades to the old typed-number menus when stdin is not a real
# terminal, so piping the script or running it under CI still works.
# ---------------------------------------------------------------------------

# bash 4+ accepts `read -t 0.05`; bash 3.2 rejects it with an error on stderr.
# Detected once so a lone Esc keypress can be distinguished from an arrow key
# where the shell supports it.
_READ_FRAC_T=-1
supports_frac_timeout() {
  if [ "$_READ_FRAC_T" = -1 ]; then
    if [ -z "$( { read -t 0.01 _ </dev/null; } 2>&1 )" ]; then
      _READ_FRAC_T=1
    else
      _READ_FRAC_T=0
    fi
  fi
  [ "$_READ_FRAC_T" = 1 ]
}

tui_available() {
  [ -t 0 ] && [ -t 1 ]
}

_CURSOR_HIDDEN=0
tui_begin() {
  tui_available || return 0
  printf '\033[?25l'   # hide cursor
  _CURSOR_HIDDEN=1
  trap '_cleanup_on_exit' EXIT INT TERM
}
tui_end() {
  [ "$_CURSOR_HIDDEN" = 1 ] || return 0
  printf '\033[?25h'   # show cursor
  _CURSOR_HIDDEN=0
}

# Read one keypress and echo a symbolic name for it.
read_key() {
  local k rest
  IFS= read -rsn1 k </dev/tty 2>/dev/null || { printf 'quit'; return; }
  case "$k" in
    '')   printf 'enter'; return ;;
    ' ')  printf 'space'; return ;;
    $'\t') printf 'tab'; return ;;
    $'\177'|$'\b') printf 'backspace'; return ;;
  esac
  if [ "$k" = $'\033' ]; then
    if supports_frac_timeout; then
      IFS= read -rsn2 -t 0.05 rest </dev/tty 2>/dev/null
    else
      # bash 3.2: an arrow key always delivers its two remaining bytes
      # immediately, so a blocking read is safe. A bare Esc needs a second
      # keypress to come back — which is why every menu also accepts `q`.
      IFS= read -rsn2 rest </dev/tty 2>/dev/null
    fi
    case "$rest" in
      '[A'|'OA') printf 'up' ;;
      '[B'|'OB') printf 'down' ;;
      '[C'|'OC') printf 'right' ;;
      '[D'|'OD') printf 'left' ;;
      '[H'|'OH') printf 'home' ;;
      '[F'|'OF') printf 'end' ;;
      '[5') IFS= read -rsn1 _ </dev/tty 2>/dev/null; printf 'pgup' ;;
      '[6') IFS= read -rsn1 _ </dev/tty 2>/dev/null; printf 'pgdn' ;;
      '')   printf 'esc' ;;
      *)    printf 'other' ;;
    esac
    return
  fi
  printf '%s' "$k"
}

# Terminal size. `tput lines` is read via a command substitution here, which
# makes its stdout a pipe — ncurses then cannot run TIOCGWINSZ and silently
# falls back to terminfo's default 24, which would make the viewport taller
# than the window and corrupt the redraw. `stty size </dev/tty` asks the
# terminal directly and is correct regardless of where stdout points.
term_rows() {
  local r
  r="$(stty size </dev/tty 2>/dev/null | awk '{print $1}')"
  case "$r" in ''|*[!0-9]*) r="$(tput lines 2>/dev/null)" ;; esac
  case "$r" in ''|*[!0-9]*) r=24 ;; esac
  [ "$r" -lt 10 ] && r=10
  printf '%s' "$r"
}

term_cols() {
  local c
  c="$(stty size </dev/tty 2>/dev/null | awk '{print $2}')"
  case "$c" in ''|*[!0-9]*) c="$(tput cols 2>/dev/null)" ;; esac
  case "$c" in ''|*[!0-9]*) c=80 ;; esac
  [ "$c" -lt 40 ] && c=40
  printf '%s' "$c"
}

# Erase the previous frame: move the cursor back up N lines, then clear
# everything below it. Used when leaving a screen; redraws use tui_paint.
tui_clear_frame() {
  local n="$1"
  [ "${n:-0}" -gt 0 ] || return 0
  printf '\033[%dA\033[J' "$n"
}

# Replace the previous frame (N lines) with FRAME in a single write.
#
# Erasing the old frame and then drawing the new one row by row left the
# screen blank for as long as the draw took, which read as a flash on every
# keypress. Instead the frame is built off-screen, the cursor goes back up,
# each line is overwritten in place and cleared to its end (\033[K), and only
# leftover lines below are erased. The write is wrapped in synchronized-output
# markers (?2026), which iTerm2, kitty, WezTerm, Ghostty and VS Code use to
# paint atomically and other terminals ignore.
#
# FRAME is draw-function output captured with $(...), so its trailing newline
# is gone; one is added back here.
tui_paint() {
  local n="${1:-0}" frame="$2" out
  frame="${frame//$'\n'/$'\033[K\n'}"$'\033[K\n'
  out=$'\033[?2026h'
  [ "$n" -gt 0 ] && out="$out"$'\033['"$n"$'A\r'
  printf '%s' "$out$frame"$'\033[J\033[?2026l'
}

# ---------------------------------------------------------------------------
# Cleaning from the menus
# ---------------------------------------------------------------------------

# Run a clean of ONLY_LIST from the interactive UI without asking anything.
#
# On the command line, --yes answers only recoverable prompts and each risky
# or irreversible action must be named with --force-risky, because a flag in a
# cron line is easy to forget. In the menus the situation is different: the
# user has just looked at every category, with its risk shown, and ticked the
# ones to clean. That selection is the confirmation. So for this one run:
#
#   * the whole-run gate is answered (as --yes would), and
#   * every selected risky/irreversible category is authorized exactly as
#     --force-risky <id> would authorize it — and nothing that was not
#     selected.
#
# The whitelist, the path policy, and every other safety check still apply;
# only the questions are gone. Previous values are restored afterwards so a
# later scan or CLI-style run is unaffected.
tui_run_clean() {
  local saved_yes="$ASSUME_YES" saved_force="$FORCE_RISKY_LIST"
  local saved_src="${FORCE_RISKY_SOURCE:-}" saved_rm="$REMOVE_ORPHANS" id ids="" rc=0

  MODE=clean
  for id in ${ONLY_LIST//,/ }; do
    confirm_is_forceable "$id" && ids="${ids:+$ids,}$id"
  done

  ASSUME_YES=1
  FORCE_RISKY_LIST="$ids"
  # A ticked orphans category means: move the leftovers it finds to quarantine.
  case ",$ONLY_LIST," in *,orphans,*) REMOVE_ORPHANS=1 ;; esac
  FORCE_RISKY_SOURCE="your category selection"
  say "Cleaning the selected categories: ${C_BOLD}${ONLY_LIST//,/, }${C_RESET}"
  say "${C_DIM}No further questions — the selection and the whitelist decide what is removed.${C_RESET}"

  run_selected_categories || rc=$?

  ASSUME_YES="$saved_yes"
  FORCE_RISKY_LIST="$saved_force"
  FORCE_RISKY_SOURCE="$saved_src"
  REMOVE_ORPHANS="$saved_rm"
  return "$rc"
}

# ---------------------------------------------------------------------------
# Multi-select category picker
# ---------------------------------------------------------------------------

# Per-row risk and description, looked up once per picker session rather
# than with several subprocesses per row on every redraw.
PICKER_RISKS=()
PICKER_DESCS=()
_picker_cache_rows() {
  local i info
  PICKER_RISKS=()
  PICKER_DESCS=()
  for i in "${!CATEGORY_STATE_IDS[@]}"; do
    info="$(category_info "${CATEGORY_STATE_IDS[$i]}")"
    PICKER_RISKS[$i]="${info%%|*}"
    PICKER_DESCS[$i]="${info#*|*|}"
  done
}

_picker_draw() {
  # $1 = cursor index, $2 = viewport top index, $3 = viewport height,
  # $4 = terminal width (optional; measured when absent)
  local cur="$1" top="$2" vh="$3" cols="${4:-}"
  local i id risk desc mark line count on=0 dw
  count="${#CATEGORY_STATE_IDS[@]}"
  [ -n "$cols" ] || cols="$(term_cols)"
  [ "${#PICKER_RISKS[@]}" -eq "$count" ] || _picker_cache_rows
  # "❯ [x] " + 16 id + 13 risk + spacing = 39 columns before the description.
  # A row that wraps would desync the cursor arithmetic in tui_paint, so
  # descriptions are hard-truncated to what is left.
  dw=$(( cols - 39 ))
  [ "$dw" -lt 10 ] && dw=10

  for i in "${!CATEGORY_STATE_ON[@]}"; do
    [ "${CATEGORY_STATE_ON[$i]}" = "1" ] && on=$((on + 1))
  done

  printf '%s\n' "${C_BOLD}Choose categories${C_RESET}  ${C_DIM}(${on}/${count} selected)${C_RESET}"
  # The hint line must not wrap either — a wrapped header would shift every
  # subsequent frame up by one line. Narrow terminals get the short form.
  if [ "$cols" -ge 92 ]; then
    printf '%s\n' "${C_DIM}  ↑/↓ move   space toggle   enter run scan   c clean   a all   x none   r reset   q back${C_RESET}"
  elif [ "$cols" -ge 66 ]; then
    printf '%s\n' "${C_DIM}  ↑↓ move  space toggle  ⏎ scan  c clean  q back${C_RESET}"
  else
    printf '%s\n' "${C_DIM}  ↑↓ space ⏎scan c q${C_RESET}"
  fi
  printf '%s\n' ""

  local end=$((top + vh))
  [ "$end" -gt "$count" ] && end="$count"
  i="$top"
  while [ "$i" -lt "$end" ]; do
    id="${CATEGORY_STATE_IDS[$i]}"
    risk="${PICKER_RISKS[$i]}"
    desc="${PICKER_DESCS[$i]}"
    if [ "${CATEGORY_STATE_ON[$i]}" = "1" ]; then mark="${C_GREEN}[x]${C_RESET}"; else mark="[ ]"; fi
    # Keep rows inside the window so a wrapped line never breaks the redraw.
    desc="${desc:0:$dw}"
    local rc
    case "$risk" in
      safe)                 rc="$C_GREEN" ;;
      moderate)             rc="$C_YELLOW" ;;
      risky|irreversible)   rc="$C_RED" ;;
      *)                    rc="" ;;
    esac
    printf -v line '%s %-16s %s%-13s%s %s' "$mark" "$id" "$rc" "$risk" "$C_RESET" "$desc"
    if [ "$i" = "$cur" ]; then
      printf '%s\n' "${C_BOLD}${C_CYAN}❯ ${C_RESET}${C_BOLD}${line}${C_RESET}"
    else
      printf '  %s\n' "$line"
    fi
    i=$((i + 1))
  done

  # Scroll hint, so a long list never looks truncated.
  if [ "$count" -gt "$vh" ]; then
    printf '%s\n' "${C_DIM}  — showing $((top + 1))-$end of $count —${C_RESET}"
  else
    printf '\n'
  fi
  return 0
}

interactive_choose_categories() {
  tui_available || { interactive_choose_categories_numeric; return; }

  local count cur=0 top=0 vh rows cols drawn key i frame
  count="${#CATEGORY_STATE_IDS[@]}"
  _picker_cache_rows

  tui_begin
  drawn=0
  while true; do
    rows="$(term_rows)"
    cols="$(term_cols)"
    vh=$((rows - 6))
    [ "$vh" -lt 5 ] && vh=5
    [ "$vh" -gt "$count" ] && vh="$count"

    # Keep the cursor inside the viewport.
    [ "$cur" -lt "$top" ] && top="$cur"
    [ "$cur" -ge $((top + vh)) ] && top=$((cur - vh + 1))
    [ "$top" -lt 0 ] && top=0

    frame="$(_picker_draw "$cur" "$top" "$vh" "$cols")"
    tui_paint "$drawn" "$frame"
    drawn=$((vh + 4))

    key="$(read_key)"
    case "$key" in
      up|k)    cur=$((cur - 1)); [ "$cur" -lt 0 ] && cur=$((count - 1)) ;;
      down|j)  cur=$((cur + 1)); [ "$cur" -ge "$count" ] && cur=0 ;;
      pgup)    cur=$((cur - vh)); [ "$cur" -lt 0 ] && cur=0 ;;
      pgdn)    cur=$((cur + vh)); [ "$cur" -ge "$count" ] && cur=$((count - 1)) ;;
      home|g)  cur=0 ;;
      end|G)   cur=$((count - 1)) ;;
      space|right)
        toggle_category_state "${CATEGORY_STATE_IDS[$cur]}" ;;
      a|A)
        for i in "${!CATEGORY_STATE_IDS[@]}"; do
          CATEGORY_STATE_ON[$i]=1
          sync_include_var "${CATEGORY_STATE_IDS[$i]}" 1
        done ;;
      x|X|n|N)
        for i in "${!CATEGORY_STATE_IDS[@]}"; do
          CATEGORY_STATE_ON[$i]=0
          sync_include_var "${CATEGORY_STATE_IDS[$i]}" 0
        done ;;
      r|R) build_category_state ;;
      s|S|enter)
        tui_end
        say ""
        MODE=scan
        ONLY_LIST="$(only_list_from_category_state)"
        SKIP_LIST=""
        if [ -z "$ONLY_LIST" ]; then
          warn "nothing selected"
        else
          run_selected_categories
        fi
        interactive_pause
        tui_begin
        drawn=0
        ;;
      c|C)
        tui_end
        say ""
        ONLY_LIST="$(only_list_from_category_state)"
        SKIP_LIST=""
        if [ -z "$ONLY_LIST" ]; then
          warn "nothing selected"
        else
          tui_run_clean
        fi
        interactive_pause
        tui_begin
        drawn=0
        ;;
      q|Q|b|B|esc|quit)
        tui_clear_frame "$drawn"
        tui_end
        return 0 ;;
      *) ;;
    esac
  done
}

# Fallback used when stdin/stdout is not a terminal (pipes, CI, `script`).
interactive_choose_categories_numeric() {
  local i id state marker info risk desc sel idx
  while true; do
    say ""
    say "${C_BOLD}Choose categories${C_RESET} (number=toggle, s=all, n=none, r=reset, w=scan, c=clean, b=back)"
    for i in "${!CATEGORY_STATE_IDS[@]}"; do
      id="${CATEGORY_STATE_IDS[$i]}"
      info="$(category_info "$id")"
      risk="$(printf '%s' "$info" | cut -d'|' -f1)"
      desc="$(printf '%s' "$info" | cut -d'|' -f3)"
      if [ "${CATEGORY_STATE_ON[$i]}" = "1" ]; then marker="[x]"; else marker="[ ]"; fi
      printf '  %2d) %s %-16s %-13s %s\n' "$((i + 1))" "$marker" "$id" "$risk" "$desc"
    done
    read -r -p "> " sel </dev/tty
    case "$sel" in
      s|S) for i in "${!CATEGORY_STATE_IDS[@]}"; do CATEGORY_STATE_ON[$i]=1; sync_include_var "${CATEGORY_STATE_IDS[$i]}" 1; done ;;
      n|N) for i in "${!CATEGORY_STATE_IDS[@]}"; do CATEGORY_STATE_ON[$i]=0; sync_include_var "${CATEGORY_STATE_IDS[$i]}" 0; done ;;
      r|R) build_category_state ;;
      w|W) MODE=scan;  ONLY_LIST="$(only_list_from_category_state)"; SKIP_LIST=""; run_selected_categories; interactive_pause ;;
      c|C)
        ONLY_LIST="$(only_list_from_category_state)"; SKIP_LIST=""
        if [ -z "$ONLY_LIST" ]; then warn "nothing selected"; else tui_run_clean; fi
        interactive_pause ;;
      b|B) return ;;
      [0-9]*)
        idx=$((sel - 1))
        if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#CATEGORY_STATE_IDS[@]}" ]; then
          toggle_category_state "${CATEGORY_STATE_IDS[$idx]}"
        else
          warn "no such category number: $sel"
        fi ;;
      *) warn "unrecognized option: $sel" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Single-select menu (used for the main menu)
#
# MENU_LABELS is filled by the caller; the chosen index lands in MENU_CHOICE.
# ---------------------------------------------------------------------------

MENU_LABELS=()
MENU_CHOICE=-1

menu_select() {
  # $1 = title, $2 = starting index
  local title="$1" cur="${2:-0}" count drawn=0 key i rows vh top=0
  count="${#MENU_LABELS[@]}"
  [ "$count" -gt 0 ] || { MENU_CHOICE=-1; return 1; }
  [ "$cur" -ge "$count" ] && cur=0

  if ! tui_available; then
    for i in "${!MENU_LABELS[@]}"; do
      printf '  %2d) %s\n' "$((i + 1))" "${MENU_LABELS[$i]}"
    done
    local sel
    read -r -p "> " sel </dev/tty
    case "$sel" in
      ''|*[!0-9]*) MENU_CHOICE=-1; return 1 ;;
    esac
    MENU_CHOICE=$((sel - 1))
    [ "$MENU_CHOICE" -ge 0 ] && [ "$MENU_CHOICE" -lt "$count" ] && return 0
    MENU_CHOICE=-1
    return 1
  fi

  tui_begin
  while true; do
    rows="$(term_rows)"
    vh=$((rows - 5))
    [ "$vh" -lt 4 ] && vh=4
    [ "$vh" -gt "$count" ] && vh="$count"
    [ "$cur" -lt "$top" ] && top="$cur"
    [ "$cur" -ge $((top + vh)) ] && top=$((cur - vh + 1))
    [ "$top" -lt 0 ] && top=0

    local end=$((top + vh)) mw frame label
    [ "$end" -gt "$count" ] && end="$count"
    mw=$(( $(term_cols) - 3 ))
    [ "$mw" -lt 10 ] && mw=10
    frame="$(
      printf '%s\n' "${C_BOLD}${title}${C_RESET}"
      printf '%s\n' "${C_DIM}  ↑/↓ move   enter select   q quit${C_RESET}"
      i="$top"
      while [ "$i" -lt "$end" ]; do
        label="${MENU_LABELS[$i]:0:$mw}"
        if [ "$i" = "$cur" ]; then
          printf '%s\n' "${C_BOLD}${C_CYAN}❯ ${label}${C_RESET}"
        else
          printf '  %s\n' "$label"
        fi
        i=$((i + 1))
      done
    )"
    tui_paint "$drawn" "$frame"
    drawn=$((vh + 2))

    key="$(read_key)"
    case "$key" in
      up|k)   cur=$((cur - 1)); [ "$cur" -lt 0 ] && cur=$((count - 1)) ;;
      down|j) cur=$((cur + 1)); [ "$cur" -ge "$count" ] && cur=0 ;;
      home|g) cur=0 ;;
      end|G)  cur=$((count - 1)) ;;
      enter|space|right)
        tui_clear_frame "$drawn"
        tui_end
        MENU_CHOICE="$cur"
        return 0 ;;
      q|Q|esc|quit)
        tui_clear_frame "$drawn"
        tui_end
        MENU_CHOICE=-1
        return 1 ;;
      [0-9])
        i=$((key - 1))
        if [ "$i" -ge 0 ] && [ "$i" -lt "$count" ]; then
          tui_clear_frame "$drawn"
          tui_end
          MENU_CHOICE="$i"
          return 0
        fi ;;
      *) ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Whitelist manager (arrow keys)
#
# The list itself is the cursor target: highlight an entry and press space or
# d to drop it. Adding and applying presets need text, so they briefly hand
# the terminal back (cursor visible, normal line editing) and then resume.
# ---------------------------------------------------------------------------

# Prompt for a line of text from inside a TUI screen without wrecking the
# frame: stop owning the cursor, read normally, then take it back.
tui_prompt() {
  # $1 = prompt, $2 = variable name to store into
  local __p="$1" __var="$2" __val
  tui_end
  printf '\n'
  read -r -p "$__p" __val </dev/tty
  printf -v "$__var" '%s' "$__val"
  tui_begin
}

WHITELIST_PRESET_NAMES="xcode-simulator xcode-derived node browsers ml"

_whitelist_draw() {
  local cur="$1" top="$2" vh="$3" count="$4"
  local i end w
  printf '%s\n' "${C_BOLD}Whitelist${C_RESET}  ${C_DIM}(${count} entr$( [ "$count" = 1 ] && echo y || echo ies))${C_RESET}"
  if [ "$(term_cols)" -ge 80 ]; then
    printf '%s\n' "${C_DIM}  ↑/↓ move   space/d remove   a add   p preset   q back${C_RESET}"
  else
    printf '%s\n' "${C_DIM}  ↑↓ move  space del  a add  p preset  q back${C_RESET}"
  fi
  printf '\n'
  if [ "$count" -eq 0 ]; then
    printf '%s\n' "  ${C_DIM}(empty — nothing is being protected)${C_RESET}"
    return 0
  fi
  end=$((top + vh)); [ "$end" -gt "$count" ] && end="$count"
  i="$top"
  while [ "$i" -lt "$end" ]; do
    w="$(printf "%.$(( $(term_cols) - 4 ))s" "${WHITELIST[$i]}")"
    if [ "$i" = "$cur" ]; then
      printf '%s\n' "${C_BOLD}${C_CYAN}❯ ${w}${C_RESET}"
    else
      printf '  %s\n' "$w"
    fi
    i=$((i + 1))
  done
  return 0
}

interactive_whitelist() {
  tui_available || { interactive_whitelist_numeric; return; }

  local cur=0 top=0 vh rows drawn=0 key count newval i pname
  tui_begin
  while true; do
    # Drop any holes left by earlier removals so indices stay contiguous.
    WHITELIST=("${WHITELIST[@]:-}")
    local compact=()
    for i in "${!WHITELIST[@]}"; do
      [ -n "${WHITELIST[$i]}" ] && compact+=("${WHITELIST[$i]}")
    done
    WHITELIST=("${compact[@]:-}")
    count="${#WHITELIST[@]}"
    [ "${WHITELIST[0]:-}" = "" ] && [ "$count" = 1 ] && count=0

    rows="$(term_rows)"
    vh=$((rows - 5)); [ "$vh" -lt 3 ] && vh=3
    [ "$vh" -gt "$count" ] && vh="$count"
    [ "$cur" -ge "$count" ] && cur=$((count - 1))
    [ "$cur" -lt 0 ] && cur=0
    [ "$cur" -lt "$top" ] && top="$cur"
    [ "$vh" -gt 0 ] && [ "$cur" -ge $((top + vh)) ] && top=$((cur - vh + 1))
    [ "$top" -lt 0 ] && top=0

    tui_paint "$drawn" "$(_whitelist_draw "$cur" "$top" "$vh" "$count")"
    if [ "$count" -eq 0 ]; then drawn=4; else drawn=$((vh + 3)); fi

    key="$(read_key)"
    case "$key" in
      up|k)   [ "$count" -gt 0 ] && { cur=$((cur - 1)); [ "$cur" -lt 0 ] && cur=$((count - 1)); } ;;
      down|j) [ "$count" -gt 0 ] && { cur=$((cur + 1)); [ "$cur" -ge "$count" ] && cur=0; } ;;
      space|d|D|backspace)
        if [ "$count" -gt 0 ]; then
          unset "WHITELIST[$cur]"
          WHITELIST=("${WHITELIST[@]}")
          drawn=0
        fi ;;
      a|A)
        tui_prompt "Entry to whitelist (path, ~/path, or glob like com.vendor.*): " newval
        [ -n "$newval" ] && WHITELIST+=("$newval")
        drawn=0 ;;
      p|P)
        tui_end
        MENU_LABELS=()
        for pname in $WHITELIST_PRESET_NAMES; do MENU_LABELS+=("$pname"); done
        if menu_select "Apply which preset?" 0; then
          i=0
          for pname in $WHITELIST_PRESET_NAMES; do
            [ "$i" = "$MENU_CHOICE" ] && apply_whitelist_preset "$pname"
            i=$((i + 1))
          done
        fi
        tui_begin
        drawn=0 ;;
      q|Q|b|B|esc|quit|enter)
        tui_clear_frame "$drawn"
        tui_end
        return 0 ;;
      *) ;;
    esac
  done
}

interactive_whitelist_numeric() {
  local sel i w num newval pname
  while true; do
    say ""
    say "${C_BOLD}Whitelist${C_RESET}"
    i=0
    for w in "${WHITELIST[@]:-}"; do
      [ -z "$w" ] && continue
      i=$((i + 1))
      say "  $i) $w"
    done
    [ "$i" -eq 0 ] && say "  (empty)"
    say "  a) Add entry (path, ~/path, or glob like com.vendor.*)"
    say "  d) Remove entry by number"
    say "  p) Apply preset ($WHITELIST_PRESET_NAMES)"
    say "  b) Back"
    read -r -p "> " sel </dev/tty
    case "$sel" in
      a|A) read -r -p "Entry to whitelist: " newval </dev/tty; [ -n "$newval" ] && WHITELIST+=("$newval") ;;
      d|D)
        read -r -p "Number to remove: " num </dev/tty
        if [ -n "$num" ] && [ -z "${num//[0-9]/}" ] && [ "$num" -ge 1 ] && [ "$num" -le "${#WHITELIST[@]}" ]; then
          unset "WHITELIST[$((num - 1))]"
          WHITELIST=("${WHITELIST[@]}")
        else
          warn "invalid number"
        fi ;;
      p|P) read -r -p "Preset name: " pname </dev/tty; apply_whitelist_preset "$pname" ;;
      b|B) return ;;
      *) warn "unrecognized option: $sel" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Settings (arrow keys)
#
# Numeric settings adjust in place with ←/→ so the common case (nudge a
# threshold) needs no typing at all; enter still opens a prompt for an exact
# value. Booleans toggle with space or enter.
# ---------------------------------------------------------------------------

# id :: kind (num|bool) :: variable :: minimum :: label
SETTINGS_ROWS=(
  "keep-device-support::num::KEEP_DEVICE_SUPPORT::1::Xcode DeviceSupport versions to keep"
  "sim-stale-days::num::SIM_STALE_DAYS::1::Simulator staleness threshold (days)"
  "android-stale-days::num::ANDROID_STALE_DAYS::1::Android AVD staleness threshold (days)"
  "tmp-stale-days::num::TMP_STALE_DAYS::0::Temp file age threshold (days)"
  "keep-toolchains::num::KEEP_TOOLCHAINS::1::Toolchain versions to keep (Kotlin, Gradle)"
  "keep-logs::num::KEEP_LOGS::0::Run logs to keep (0 = keep none)"
  "aggressive::bool::AGGRESSIVE::0::Aggressive mode (prunes harder)"
  "verbose::bool::VERBOSE::0::Verbose output"
  "assume-yes::bool::ASSUME_YES::0::Assume yes (ordinary prompts only, never risky ones)"
)

_settings_draw() {
  local cur="$1"
  local i row kind var label val shown lw
  printf '%s\n' "${C_BOLD}Settings${C_RESET}"
  if [ "$(term_cols)" -ge 84 ]; then
    printf '%s\n' "${C_DIM}  ↑/↓ move   ←/→ adjust   enter edit or toggle   q back${C_RESET}"
  else
    printf '%s\n' "${C_DIM}  ↑↓ move  ←→ adjust  ⏎ edit  q back${C_RESET}"
  fi
  printf '\n'
  lw=$(( $(term_cols) - 12 ))
  [ "$lw" -lt 20 ] && lw=20
  [ "$lw" -gt 52 ] && lw=52
  for i in "${!SETTINGS_ROWS[@]}"; do
    row="${SETTINGS_ROWS[$i]}"
    kind="${row#*::}"; kind="${kind%%::*}"
    var="${row#*::*::}"; var="${var%%::*}"
    label="${row##*::}"
    val="$(eval printf '%s' "\"\${$var}\"")"
    if [ "$kind" = bool ]; then
      [ "$val" = 1 ] && shown="${C_GREEN}on${C_RESET}" || shown="${C_DIM}off${C_RESET}"
    else
      shown="${C_BOLD}$val${C_RESET}"
    fi
    label="$(printf "%.${lw}s" "$label")"
    if [ "$i" = "$cur" ]; then
      printf "${C_BOLD}${C_CYAN}❯ ${C_RESET}${C_BOLD}%-${lw}s${C_RESET}  %s\n" "$label" "$shown"
    else
      printf "  %-${lw}s  %s\n" "$label" "$shown"
    fi
  done
  return 0
}

interactive_settings() {
  tui_available || { interactive_settings_numeric; return; }

  local cur=0 drawn=0 key count row kind var min val newval
  count="${#SETTINGS_ROWS[@]}"
  tui_begin
  while true; do
    tui_paint "$drawn" "$(_settings_draw "$cur")"
    drawn=$((count + 3))

    row="${SETTINGS_ROWS[$cur]}"
    kind="${row#*::}"; kind="${kind%%::*}"
    var="${row#*::*::}"; var="${var%%::*}"
    min="${row#*::*::*::}"; min="${min%%::*}"

    key="$(read_key)"
    case "$key" in
      up|k)   cur=$((cur - 1)); [ "$cur" -lt 0 ] && cur=$((count - 1)) ;;
      down|j) cur=$((cur + 1)); [ "$cur" -ge "$count" ] && cur=0 ;;
      left|h)
        if [ "$kind" = bool ]; then
          printf -v "$var" '0'
        else
          val="$(eval printf '%s' "\"\${$var}\"")"
          val=$((val - 1)); [ "$val" -lt "$min" ] && val="$min"
          printf -v "$var" '%s' "$val"
        fi ;;
      right|l)
        if [ "$kind" = bool ]; then
          printf -v "$var" '1'
        else
          val="$(eval printf '%s' "\"\${$var}\"")"
          printf -v "$var" '%s' "$((val + 1))"
        fi ;;
      space|enter)
        if [ "$kind" = bool ]; then
          val="$(eval printf '%s' "\"\${$var}\"")"
          [ "$val" = 1 ] && printf -v "$var" '0' || printf -v "$var" '1'
        else
          val="$(eval printf '%s' "\"\${$var}\"")"
          tui_prompt "New value [$val]: " newval
          case "$newval" in
            ''|*[!0-9]*) [ -n "$newval" ] && warn "not a number, keeping $val" ;;
            *) [ "$newval" -lt "$min" ] && newval="$min"; printf -v "$var" '%s' "$newval" ;;
          esac
          drawn=0
        fi ;;
      q|Q|b|B|esc|quit)
        tui_clear_frame "$drawn"
        tui_end
        return 0 ;;
      *) ;;
    esac
  done
}

interactive_settings_numeric() {
  local sel v
  while true; do
    say ""
    say "${C_BOLD}Settings${C_RESET}"
    say "  1) Xcode DeviceSupport versions to keep   = $KEEP_DEVICE_SUPPORT"
    say "  2) Simulator staleness threshold (days)    = $SIM_STALE_DAYS"
    say "  3) Android AVD staleness threshold (days)  = $ANDROID_STALE_DAYS"
    say "  4) Temp file age threshold (days)          = $TMP_STALE_DAYS"
    say "  5) Toolchain versions to keep              = $KEEP_TOOLCHAINS"
    say "  9) Run logs to keep                        = $KEEP_LOGS"
    say "  6) Aggressive mode                         = $( [ "$AGGRESSIVE" = 1 ] && echo on || echo off )"
    say "  7) Verbose output                          = $( [ "$VERBOSE" = 1 ] && echo on || echo off )"
    say "  8) Assume yes (ordinary prompts only)      = $( [ "$ASSUME_YES" = 1 ] && echo on || echo off )"
    say "  b) Back"
    read -r -p "> " sel </dev/tty
    case "$sel" in
      1) read -r -p "New value [$KEEP_DEVICE_SUPPORT]: " v </dev/tty; [ -n "$v" ] && KEEP_DEVICE_SUPPORT="$v" ;;
      2) read -r -p "New value [$SIM_STALE_DAYS]: " v </dev/tty; [ -n "$v" ] && SIM_STALE_DAYS="$v" ;;
      3) read -r -p "New value [$ANDROID_STALE_DAYS]: " v </dev/tty; [ -n "$v" ] && ANDROID_STALE_DAYS="$v" ;;
      4) read -r -p "New value [$TMP_STALE_DAYS]: " v </dev/tty; [ -n "$v" ] && TMP_STALE_DAYS="$v" ;;
      5) read -r -p "New value [$KEEP_TOOLCHAINS]: " v </dev/tty; [ -n "$v" ] && KEEP_TOOLCHAINS="$v" ;;
      9) read -r -p "New value [$KEEP_LOGS]: " v </dev/tty; [ -n "$v" ] && KEEP_LOGS="$v" ;;
      6) [ "$AGGRESSIVE" = 1 ] && AGGRESSIVE=0 || AGGRESSIVE=1 ;;
      7) [ "$VERBOSE" = 1 ] && VERBOSE=0 || VERBOSE=1 ;;
      8) [ "$ASSUME_YES" = 1 ] && ASSUME_YES=0 || ASSUME_YES=1 ;;
      b|B) return ;;
      *) warn "unrecognized option: $sel" ;;
    esac
  done
}

interactive_main() {
  log_init
  build_category_state
  local last=0
  say "${C_BOLD}${SCRIPT_NAME} — interactive mode${C_RESET}  (config: $CONFIG_FILE)"
  if tui_available; then
    say "${C_DIM}Arrow keys to move, enter to select. Number keys still work.${C_RESET}"
  fi
  while true; do
    MENU_LABELS=(
      "Quick scan    — code-default safe categories, changes nothing"
      "Quick clean   — code-default safe categories"
      "Choose categories & run"
      "Disk report   — where your space actually went"
      "Manage whitelist"
      "Settings"
      "View category list (current selection)"
      "View most recent log"
      "Save current selection + settings as default"
      "Quit"
    )
    if ! menu_select "Main menu" "$last"; then
      exit 0
    fi
    last="$MENU_CHOICE"
    case "$MENU_CHOICE" in
      0)
        MODE=scan
        reset_all_include_vars
        ONLY_LIST="$(compute_code_default_ids)"
        SKIP_LIST=""
        run_selected_categories
        interactive_pause
        ;;
      1)
        reset_all_include_vars
        ONLY_LIST="$(compute_code_default_ids)"
        SKIP_LIST=""
        tui_run_clean
        interactive_pause
        ;;
      2) interactive_choose_categories ;;
      3) log_init; report_system_data; report_top_offenders; interactive_pause ;;
      4) interactive_whitelist ;;
      5) interactive_settings ;;
      6) print_live_category_state; interactive_pause ;;
      7) view_last_log; interactive_pause ;;
      8) save_config; interactive_pause ;;
      9) exit 0 ;;
    esac
  done
}
