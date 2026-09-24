#!/usr/bin/env bash
#
# lib/cleaners/categories.sh lib/categories.sh — Category implementations for mimi.
#
# Sourced by lib/load.sh; never executed on its own. Defines functions only.

# ---------------------------------------------------------------------------
# Category implementations
# ---------------------------------------------------------------------------

cat_caches() {
  section "User caches"
  local base="$HOME_DIR/Library/Caches"
  [ -d "$base" ] || { info "no caches dir found"; return; }
  # Entries here are usually per-app directories, but loose files turn up too
  # (stray plists, single-file caches). clear_dir_contents only handles
  # directories, so a bare file would otherwise be skipped silently and never
  # counted in the estimate either.
  local sub
  for sub in "$base"/*; do
    [ -e "$sub" ] || continue
    if [ -d "$sub" ]; then
      clear_dir_contents "$sub"
    else
      remove_path "$sub"
    fi
  done
}

cat_logs() {
  section "User logs"
  local base="$HOME_DIR/Library/Logs"
  [ -d "$base" ] || { info "no logs dir found"; return; }
  local sub
  for sub in "$base"/*; do
    [ -e "$sub" ] || continue
    # DiagnosticReports handled by its own category so it can be toggled separately
    [ "$(basename "$sub")" = "DiagnosticReports" ] && continue
    # Never our own log directory: this runs mid-run, so clearing it would
    # delete the transcript currently being written and any orphan review
    # file the user has not acted on yet. It is size-capped by KEEP_LOGS.
    [ "$sub" = "$LOG_DIR" ] && { verbose "skipping own log dir: $sub"; continue; }
    # Same as caches: ~/Library/Logs holds loose .log files as well as
    # per-app directories, and clear_dir_contents ignores non-directories.
    if [ -d "$sub" ]; then
      clear_dir_contents "$sub"
    else
      remove_path "$sub"
    fi
  done
}

cat_diagnostics() {
  section "Diagnostic / crash reports"
  clear_dir_contents "$HOME_DIR/Library/Logs/DiagnosticReports"
}

cat_dsstore() {
  section ".DS_Store files"
  # This used to count every file it *found* as reclaimed, whether or not the
  # rm succeeded — .DS_Store files turn up in places the user cannot write, so
  # the count and the freed total were routinely wrong.
  local found=0 found_kb=0 removed=0 removed_kb=0 f size canon
  while IFS= read -r -d '' f; do
    if interrupted; then
      verbose "interrupted, stopping .DS_Store scan"
      break
    fi
    size="$(dir_size_kb "$f")"
    found=$((found + 1))
    found_kb=$((found_kb + size))

    [ "$MODE" = "clean" ] || continue

    if ! canon="$(path_authorize "$f")"; then
      record_action skipped
      verbose "refused ($PATH_DENY_REASON), kept: $f"
      continue
    fi
    if is_whitelisted "$canon"; then
      record_action skipped
      verbose "whitelisted, kept: $f"
      continue
    fi
    verbose "removing: $f"
    if ! fs_remove "$canon"; then
      report_action "$f"
      continue
    fi
    record_action ok
    removed=$((removed + 1))
    removed_kb=$((removed_kb + size))
  done < <(find "$HOME_DIR" -xdev -name '.DS_Store' -not -path '*/.Trash/*' -print0 2>/dev/null)

  TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + found_kb))
  if [ "$MODE" = "scan" ]; then
    info "found $found .DS_Store files ($(human_kb "$found_kb"))"
    return 0
  fi

  TOTAL_RECLAIMED_KB=$((TOTAL_RECLAIMED_KB + removed_kb))
  if [ "$removed" -eq "$found" ]; then
    ok "removed $removed .DS_Store files (freed $(human_kb "$removed_kb"))"
    return 0
  fi
  warn "removed $removed of $found .DS_Store files (freed $(human_kb "$removed_kb"))"
  return 1
}

cat_quicklook() {
  section "QuickLook thumbnail cache"
  if [ "$MODE" = "scan" ]; then
    info "would reset QuickLook thumbnail cache (qlmanage -r cache)"
    return
  fi
  if command -v qlmanage > /dev/null 2>&1; then
    # This used to run twice in a row. There is no second-pass effect to gain;
    # it was a copy-paste, and it doubled the time the category takes.
    tool_cleanup "QuickLook thumbnail cache reset" "" qlmanage -r cache
  else
    warn "qlmanage not found, skipped"
  fi
}

cat_xcode_derived() {
  section "Xcode DerivedData"
  clear_dir_contents "$HOME_DIR/Library/Developer/Xcode/DerivedData"
}

cat_xcode_archives() {
  section "Xcode Archives (old builds)"
  local base="$HOME_DIR/Library/Developer/Xcode/Archives"
  [ -d "$base" ] || { info "no archives dir found"; return; }
  if [ "$AGGRESSIVE" != 1 ]; then
    warn "skipped (enable with --aggressive; archives may be needed for dSYM/App Store re-submission)"
    return
  fi
  local sub
  for sub in "$base"/*; do
    [ -e "$sub" ] || continue
    remove_path "$sub"
  done
}

cat_sim_caches() {
  section "iOS Simulator caches"
  clear_dir_contents "$HOME_DIR/Library/Developer/CoreSimulator/Caches"
}

cat_sim_unavailable() {
  section "Unavailable iOS Simulator devices"
  if ! command -v xcrun >/dev/null 2>&1; then
    warn "xcrun not found, skipped"
    return
  fi
  local sim_root="$HOME_DIR/Library/Developer/CoreSimulator/Devices"
  if is_whitelisted "$sim_root"; then
    info "whitelisted, skipped: $sim_root"
    return
  fi
  local before after reclaimed
  before="$(dir_size_kb "$sim_root")"
  if [ "$MODE" = "scan" ]; then
    info "would run: xcrun simctl delete unavailable (devices dir currently: $(human_kb "$before"))"
    return
  fi
  tool_cleanup "deleted unavailable simulator devices" "$sim_root" \
    xcrun simctl delete unavailable
}

cat_device_support() {
  section "Xcode iOS DeviceSupport (old OS symbol sets)"
  local base="$HOME_DIR/Library/Developer/Xcode/iOS DeviceSupport"
  [ -d "$base" ] || { info "no DeviceSupport dir found"; return; }
  if is_whitelisted "$base"; then
    info "whitelisted, skipped: $base"
    return
  fi

  local keep="$KEEP_DEVICE_SUPPORT"
  [ "$AGGRESSIVE" = 1 ] && keep=1

  # Sort by modification time, newest first; keep the newest $keep, remove the rest.
  local -a dirs=()
  while IFS= read -r d; do
    dirs+=("$d")
  done < <(find "$base" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null \
            | xargs -0 stat -f '%m %N' 2>/dev/null | sort -rn | cut -d' ' -f2-)

  local total="${#dirs[@]}"
  if [ "$total" -le "$keep" ]; then
    info "only $total version(s) present, nothing to prune (keeping $keep)"
    return
  fi

  info "found $total version(s), keeping the $keep most recently used"
  local i=0 d
  for d in "${dirs[@]}"; do
    i=$((i + 1))
    [ "$i" -le "$keep" ] && { verbose "keeping: $d"; continue; }
    remove_path "$d"
  done
}

cat_homebrew() {
  section "Homebrew download cache"
  if ! command -v brew >/dev/null 2>&1; then
    info "Homebrew not installed, skipped"
    return
  fi
  local cache_dir
  cache_dir="$(brew --cache 2>/dev/null)"
  local before=0
  [ -n "$cache_dir" ] && before="$(dir_size_kb "$cache_dir")"

  if [ "$MODE" = "scan" ]; then
    info "would run: brew cleanup -s --prune=all  (cache: $(human_kb "$before") at $cache_dir)"
    TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + before))
    return
  fi

  if is_whitelisted "$cache_dir"; then
    info "whitelisted, skipped: $cache_dir"
    return
  fi

  tool_cleanup "brew cleanup" "$cache_dir" brew cleanup -s --prune=all
}

cat_homebrew_old() {
  section "Homebrew old versions and unused dependencies"
  if ! command -v brew >/dev/null 2>&1; then
    info "Homebrew not installed, skipped"
    return
  fi
  local cellar_dir cellar_before=0
  cellar_dir="$(brew --cellar 2>/dev/null)"
  [ -n "$cellar_dir" ] && [ -d "$cellar_dir" ] && cellar_before="$(dir_size_kb "$cellar_dir")"

  if [ "$MODE" = "scan" ]; then
    info "would run: brew autoremove   (unused dependencies, listed below)"
    local line orphan_count=0
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      case "$line" in
        ==\>*|Warning:*|"Would remove"*) continue ;;
      esac
      orphan_count=$((orphan_count + 1))
      info "    unused dependency: $line"
    done < <(brew autoremove --dry-run 2>/dev/null | tr ' ' '\n')
    [ "$orphan_count" = 0 ] && info "    (none — no unused dependencies)"
    info "would run: brew cleanup --prune=all  (old versions in Cellar/Caskroom)"
    TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + cellar_before))
    return
  fi

  if tool_cleanup "brew autoremove" "$cellar_dir" brew autoremove; then
    if [ "$TOOL_CLEANUP_RECLAIMED_KB" -eq 0 ]; then
      info "brew autoremove: no unused dependencies"
    fi
  fi

  tool_cleanup "brew cleanup old versions" "$cellar_dir" brew cleanup --prune=all
}

cat_npm() {
  section "npm cache"
  command -v npm >/dev/null 2>&1 || { info "npm not installed, skipped"; return; }
  local cache_dir
  cache_dir="$(npm config get cache 2>/dev/null)"
  [ -d "$cache_dir" ] || { info "no npm cache dir found"; return; }
  if is_whitelisted "$cache_dir"; then
    info "whitelisted, skipped: $cache_dir"
    return
  fi
  local before after reclaimed
  before="$(dir_size_kb "$cache_dir")"
  if [ "$MODE" = "scan" ]; then
    info "would run: npm cache clean --force ($(human_kb "$before") at $cache_dir)"
    TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + before))
    return
  fi
  tool_cleanup "npm cache cleaned" "$cache_dir" npm cache clean --force
}

cat_yarn() {
  section "Yarn cache"
  command -v yarn >/dev/null 2>&1 || { info "yarn not installed, skipped"; return; }
  # Yarn Classic (1.x) answers `yarn cache dir`. Yarn Berry (2/3/4) does not
  # have that command at all — it keeps a global cache at ~/.yarn/berry/cache
  # and `yarn cache clean` only works from inside a project, so Berry's cache
  # is cleared directly. Everything in it is re-fetched from the registry.
  local cache_dir
  cache_dir="$(yarn cache dir 2>/dev/null)"
  case "$cache_dir" in
    /*) ;;
    *) cache_dir="" ;;     # Berry prints usage/error text, not a path
  esac
  if [ -z "$cache_dir" ] || [ ! -d "$cache_dir" ]; then
    if [ -d "$HOME_DIR/.yarn/berry/cache" ]; then
      info "Yarn Berry detected (v$(yarn --version 2>/dev/null)) — clearing its global cache"
      clear_dir_contents "$HOME_DIR/.yarn/berry/cache"
      return
    fi
    info "no yarn cache dir found"
    return
  fi
  if is_whitelisted "$cache_dir"; then
    info "whitelisted, skipped: $cache_dir"
    return
  fi
  local before after reclaimed
  before="$(dir_size_kb "$cache_dir")"
  if [ "$MODE" = "scan" ]; then
    info "would run: yarn cache clean ($(human_kb "$before") at $cache_dir)"
    TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + before))
    return
  fi
  tool_cleanup "yarn cache cleaned" "$cache_dir" yarn cache clean
  [ -d "$HOME_DIR/.yarn/berry/cache" ] && clear_dir_contents "$HOME_DIR/.yarn/berry/cache"
  return 0
}

cat_pnpm() {
  section "pnpm store"
  command -v pnpm >/dev/null 2>&1 || { info "pnpm not installed, skipped"; return; }
  local store_dir
  store_dir="$(pnpm store path 2>/dev/null)"
  [ -d "$store_dir" ] || { info "no pnpm store found"; return; }
  if is_whitelisted "$store_dir"; then
    info "whitelisted, skipped: $store_dir"
    return
  fi
  local before after reclaimed
  before="$(dir_size_kb "$store_dir")"
  if [ "$MODE" = "scan" ]; then
    info "would run: pnpm store prune ($(human_kb "$before") at $store_dir)"
    TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + before))
    return
  fi
  tool_cleanup "pnpm store pruned" "$store_dir" pnpm store prune
}

cat_cocoapods() {
  section "CocoaPods cache"
  local cache_dir="$HOME_DIR/Library/Caches/CocoaPods"
  [ -d "$cache_dir" ] || { info "no CocoaPods cache found"; return; }
  clear_dir_contents "$cache_dir"
}

cat_gradle() {
  section "Gradle caches"
  clear_dir_contents "$HOME_DIR/.gradle/caches"
}

cat_pip() {
  section "pip cache"
  command -v pip3 >/dev/null 2>&1 || command -v pip >/dev/null 2>&1 || { info "pip not installed, skipped"; return; }
  local pipbin="pip3"
  command -v pip3 >/dev/null 2>&1 || pipbin="pip"
  local cache_dir
  cache_dir="$("$pipbin" cache dir 2>/dev/null)"
  [ -d "$cache_dir" ] || { info "no pip cache found"; return; }
  if is_whitelisted "$cache_dir"; then
    info "whitelisted, skipped: $cache_dir"
    return
  fi
  local before after reclaimed
  before="$(dir_size_kb "$cache_dir")"
  if [ "$MODE" = "scan" ]; then
    info "would run: $pipbin cache purge ($(human_kb "$before") at $cache_dir)"
    TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + before))
    return
  fi
  "$pipbin" cache purge >>"$LOG_FILE" 2>&1
  after="$(dir_size_kb "$cache_dir")"
  reclaimed=$((before - after))
  [ "$reclaimed" -lt 0 ] && reclaimed=0
  TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + before))
  TOTAL_RECLAIMED_KB=$((TOTAL_RECLAIMED_KB + reclaimed))
  ok "pip cache purged (freed $(human_kb "$reclaimed"))"
}

cat_timemachine() {
  section "Local Time Machine snapshots"
  if ! command -v tmutil >/dev/null 2>&1; then
    info "tmutil not found, skipped"
    return
  fi
  local snapshots
  snapshots="$(tmutil listlocalsnapshots / 2>/dev/null | grep 'com.apple.TimeMachine' || true)"
  if [ -z "$snapshots" ]; then
    info "no local snapshots found"
    return
  fi
  local count
  count="$(printf '%s\n' "$snapshots" | wc -l | tr -d ' ')"
  if [ "$MODE" = "scan" ]; then
    info "found $count local snapshot(s) (thinning reclaims purgeable space, not shown in du totals)"
    return
  fi
  info "thinning local snapshots (this only affects local disk space, not your Time Machine backup drive)"
  # 4 = urgency level "as much as possible while keeping at least one recent snapshot"
  # No directory shrinks measurably here — thinning frees purgeable space that
  # du never counted — so this reports success or failure and no byte figure.
  tool_cleanup "requested thinning of $count local snapshot(s)" "" \
    tmutil thinlocalsnapshots / 999999999999 4
}

cat_docker() {
  section "Docker (unused images/containers/volumes)"
  if [ "$INCLUDE_DOCKER" != 1 ]; then
    warn "skipped (opt-in only, pass --include-docker)"
    return
  fi
  if ! command -v docker >/dev/null 2>&1; then
    info "docker not installed, skipped"
    return
  fi
  if ! docker_daemon_ready; then
    warn "Docker daemon not responding (not running, or still starting) — skipped"
    return
  fi
  if [ "$MODE" = "scan" ]; then
    info "would run: docker system prune -af --volumes"
    return
  fi
  if ! confirm_action_ok docker \
    "This removes ALL unused Docker images, containers, and volumes, including named volumes holding database data."; then
    return
  fi
  tool_cleanup "docker system prune complete (see log for reclaimed space)" "" \
    docker system prune -af --volumes
}

cat_docker_cache() {
  section "Docker build cache & unused images (safe prune)"
  if [ "$INCLUDE_DOCKER_CACHE" != 1 ]; then
    warn "skipped (opt-in only, pass --include-docker-cache)"
    return
  fi
  if ! command -v docker >/dev/null 2>&1; then
    info "docker not installed, skipped"
    return
  fi
  if ! docker_daemon_ready; then
    warn "Docker daemon not responding (not running, or still starting) — skipped"
    return
  fi

  # Unlike the `docker` category (-af --volumes, wipes everything unused),
  # this only removes dangling build cache and untagged images — nothing
  # currently tagged, running, or in a named volume is ever touched.
  local raw_disk="$HOME_DIR/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"
  local before=0
  [ -e "$raw_disk" ] && before="$(dir_size_kb "$raw_disk")"

  if [ "$MODE" = "scan" ]; then
    info "would run: docker builder prune -f && docker image prune -f (dangling only)"
    local line
    run_with_timeout 15 docker system df 2>/dev/null | while IFS= read -r line; do info "  $line"; done
    return
  fi

  # Both prunes are attempted even if the first fails: they clean different
  # things, and a builder-cache failure is no reason to skip dangling images.
  local prune_failed=0
  tool_cleanup "docker builder prune" "" docker builder prune -f || prune_failed=1
  tool_cleanup "docker image prune (dangling)" "" docker image prune -f || prune_failed=1

  # Docker.raw is sparse: du reports blocks actually allocated, which is the
  # figure that matches what the volume gets back. Note that Docker only
  # returns those blocks to the filesystem when it decides to compact the
  # image, so a successful prune can legitimately shrink it by nothing.
  local after=0
  [ -e "$raw_disk" ] && after="$(dir_size_kb "$raw_disk")"
  local reclaimed=$((before - after))
  [ "$reclaimed" -lt 0 ] && reclaimed=0
  TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + before))
  TOTAL_RECLAIMED_KB=$((TOTAL_RECLAIMED_KB + reclaimed))
  if [ "$prune_failed" = 1 ]; then
    warn "Docker.raw allocated size changed by $(human_kb "$reclaimed") despite the failure above"
  elif [ "$reclaimed" -eq 0 ]; then
    ok "docker build cache + unused images pruned (Docker.raw has not released its blocks yet)"
  else
    ok "docker build cache + unused images pruned (Docker.raw shrank by $(human_kb "$reclaimed"))"
  fi
}

cat_mail() {
  section "Mail.app download cache"
  if [ "$INCLUDE_MAIL" != 1 ]; then
    warn "skipped (opt-in only, pass --include-mail)"
    return
  fi
  # An IMAP attachment re-downloads; a POP one, or one whose message has since
  # been deleted on the server, does not. That is why this is gated at all.
  if [ "$MODE" = "clean" ] && ! confirm_action_ok mail \
    "Clear Mail.app's downloaded attachment cache? Attachments whose message is gone from the server are not re-downloadable."; then
    return
  fi
  clear_dir_contents "$HOME_DIR/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
}

# This category is report-only, under every flag, in every mode.
#
# It works by absence: an entry is listed because no installed application
# claimed its name. That is a guess, not ownership — an app can rename itself,
# ship helpers under its own prefix, live on a volume that is not mounted, or
# simply not be in Spotlight's index yet. Acting on a guess is what makes an
# "orphan cleaner" dangerous, so the only way anything here can be deleted is
# to read the generated file, decide for yourself, and pass it back with
# --remove-orphans-from, which revalidates every line (see P0-T04).
cat_orphans() {
  section "Possible application leftovers (report only)"
  if [ "$INCLUDE_ORPHANS" != 1 ]; then
    warn "skipped (opt-in only, pass --include-orphans; try --only orphans --include-orphans --scan first to preview)"
    return
  fi

  info "indexing installed applications (Spotlight + standard app folders)..."
  build_installed_identifiers

  if [ "$ORPHAN_INDEX_COMPLETE" != 1 ]; then
    warn "the installed-application index is INCOMPLETE: $ORPHAN_INDEX_NOTE"
    warn "this scan decides a leftover is unclaimed by not finding an app for it, so an"
    warn "incomplete index makes every result unreliable. Nothing below is evidence that"
    warn "an application was uninstalled — check each one yourself."
  fi

  collect_orphan_candidates

  local n="${#ORPHAN_CANDIDATE_PATHS[@]}"
  if [ "$n" -eq 0 ]; then
    info "no unclaimed leftovers found"
    return
  fi

  local i size total_kb=0 strong_count=0 weak_count=0
  for ((i = 0; i < n; i++)); do
    size="$(dir_size_kb "${ORPHAN_CANDIDATE_PATHS[$i]}")"
    total_kb=$((total_kb + size))
    if [ "${ORPHAN_CANDIDATE_TIERS[$i]}" = "strong" ]; then
      strong_count=$((strong_count + 1))
      info "  [strong] [${ORPHAN_CANDIDATE_TOKENS[$i]}] ${ORPHAN_CANDIDATE_PATHS[$i]}  ($(human_kb "$size"))"
    else
      weak_count=$((weak_count + 1))
      info "  [weak]   [${ORPHAN_CANDIDATE_TOKENS[$i]}] ${ORPHAN_CANDIDATE_PATHS[$i]}  ($(human_kb "$size"))"
    fi
  done

  say ""
  info "[strong] = the folder is named by bundle id and no installed app claims that id."
  info "[weak]   = the name is a guess (bare words, OS service names, UUIDs, or the"
  info "           app index was incomplete). A [weak] entry is NOT evidence that any"
  info "           application was uninstalled."
  warn "Both tiers are heuristic. Neither is removed by this scan."

  local review_file="$LOG_DIR/orphans-review-$TIMESTAMP.txt"
  write_orphans_review_file "$review_file"
  say ""
  info "$n candidate(s), $(human_kb "$total_kb") in total, written to:"
  info "  $review_file"
  if [ "$ORPHAN_REVIEW_SKIPPED" -gt 0 ]; then
    warn "$ORPHAN_REVIEW_SKIPPED candidate(s) contain a newline in their name and could not be"
    warn "listed in a line-based file; remove those by hand."
  fi
  info "Nothing here is deleted by --clean. To remove some of it, open that file,"
  info "delete or comment out every line you want to KEEP, then run:"
  info "  ./$SCRIPT_NAME --clean --remove-orphans-from \"$review_file\""

  # Deliberately NOT added to TOTAL_BEFORE_KB: that figure answers "how much
  # would --clean free", and --clean frees none of this.
  return 0
}

process_orphans_review_file() {
  local file="$REMOVE_ORPHANS_FILE"
  if [ ! -f "$file" ]; then
    err "orphans review file not found: $file"
    return 1
  fi

  section "Removing items from reviewed file: $file"

  # The marker is what separates "a list this tool produced and a human pruned"
  # from "an arbitrary list of paths". Without it, --remove-orphans-from would
  # be a general-purpose delete-these-paths flag.
  local first=""
  IFS= read -r first < "$file" || first=""
  case "$first" in
    "# $ORPHAN_REVIEW_FORMAT"*) ;;
    "# $ORPHAN_REVIEW_FORMAT_LEGACY"*) ;;
    *)
      err "not a $SCRIPT_NAME orphan review file — first line is not '# $ORPHAN_REVIEW_FORMAT'"
      err "regenerate it with: ./$SCRIPT_NAME --scan --only orphans --include-orphans"
      return 1
      ;;
  esac

  local -a to_remove=() to_remove_ident=()
  local raw line path trimmed ident lineno=0 rejected=0
  while IFS= read -r raw || [ -n "$raw" ]; do
    lineno=$((lineno + 1))

    # Leading whitespace is always an editor artifact: every path this tool
    # writes is absolute. Trailing whitespace is NOT stripped up front,
    # because a trailing space is a legal filename character.
    line="${raw#"${raw%%[![:space:]]*}"}"
    [ -z "$line" ] && continue
    # A comment is a "#" in the first column only. Anywhere else it is part of
    # the filename — the old `${raw%%#*}` truncated "Foo#1" to "Foo" and then
    # went looking for a directory that had never existed.
    case "$line" in '#'*) continue ;; esac

    path="$line"
    # Only strip trailing whitespace when doing so is what makes the path
    # resolve, so "cache dir " and "cache dir" can both be represented.
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
      trimmed="${path%"${path##*[![:space:]]}"}"
      if [ "$trimmed" != "$path" ] && { [ -e "$trimmed" ] || [ -L "$trimmed" ]; }; then
        path="$trimmed"
      fi
    fi

    if ! validate_orphan_target "$path"; then
      case "$ORPHAN_DENY_REASON" in
        missing)
          warn "line $lineno [missing]: no longer exists, skipped: $path"
          ;;
        whitelisted)
          info "line $lineno [whitelisted]: skipped: $path"
          ;;
        *)
          warn "line $lineno [$ORPHAN_DENY_REASON]: refused ($(orphan_deny_message)): $path"
          rejected=$((rejected + 1))
          ;;
      esac
      continue
    fi

    # Pin the object, not just the name, so a swap between here and the
    # removal below is caught rather than followed.
    ident="$(path_identity "$ORPHAN_CANONICAL")" || ident=""
    to_remove+=("$ORPHAN_CANONICAL")
    to_remove_ident+=("$ident")
  done < "$file"

  [ "$rejected" -gt 0 ] && warn "$rejected line(s) were refused and will not be touched"

  local n="${#to_remove[@]}"
  if [ "$n" -eq 0 ]; then
    info "nothing to remove from review file"
    return
  fi

  info "$n item(s) from the review file are queued for removal:"
  local i p
  for p in "${to_remove[@]}"; do
    info "  $p  ($(human_kb "$(dir_size_kb "$p")"))"
  done

  if [ "$MODE" != "clean" ]; then
    info "(scan mode — nothing deleted; re-run with --clean to actually remove these)"
    return
  fi

  if ! confirm_action_ok orphans \
    "Remove these $n reviewed item(s)? This is not heuristic — you already reviewed the file."; then
    return
  fi

  for ((i = 0; i < n; i++)); do
    p="${to_remove[$i]}"
    # Revalidate everything immediately before acting. The confirmation above
    # is an unbounded pause, and the whitelist, the allowed roots and the
    # object itself all have to still hold at the moment of the action.
    if ! validate_orphan_target "$p"; then
      warn "[$ORPHAN_DENY_REASON]: changed since it was checked, skipped: $p"
      continue
    fi
    ident="$(path_identity "$ORPHAN_CANONICAL")" || ident=""
    if [ -z "$ident" ] || [ "$ident" != "${to_remove_ident[$i]}" ]; then
      warn "[identity-changed]: replaced since it was checked, skipped: $p"
      continue
    fi
    if [[ "$ORPHAN_CANONICAL" == *"/LaunchAgents/"* ]]; then
      unload_launch_agent "$ORPHAN_CANONICAL"
    fi
    remove_path "$ORPHAN_CANONICAL"
  done
}

cat_whatsapp() {
  section "WhatsApp expired Status/Stories media cache"
  if [ "$INCLUDE_WHATSAPP" != 1 ]; then
    warn "skipped (opt-in only, pass --include-whatsapp)"
    return
  fi

  local base="$HOME_DIR/Library/Group Containers/group.net.whatsapp.WhatsApp.shared"
  if [ ! -d "$base" ]; then
    info "WhatsApp data not found, skipped"
    return
  fi

  # Only ever targets Message/Media/<id>.status folders (WhatsApp's own naming
  # for cached Status/Stories views, which expire after 24h on WhatsApp's
  # servers anyway) plus generic Cache/Logs. Actual conversation media
  # (Message/Media/<id> without .status) and every database (ChatStorage.sqlite,
  # Axolotl.sqlite, etc.) at the container root are never touched.
  local media_dir="$base/Message/Media"
  if [ -d "$media_dir" ]; then
    local d
    for d in "$media_dir"/*.status; do
      [ -e "$d" ] || continue
      remove_path "$d"
    done
  else
    info "no Message/Media directory found"
  fi

  clear_dir_contents "$base/Library/Caches"
  clear_dir_contents "$base/Logs"
}

cat_sim_stale() {
  section "Long-unused iOS Simulator devices"
  if [ "$INCLUDE_SIM_STALE" != 1 ]; then
    warn "skipped (opt-in only, pass --include-sim-stale; tune with --sim-stale-days N, default $SIM_STALE_DAYS)"
    return
  fi
  if ! command -v xcrun >/dev/null 2>&1; then
    info "xcrun not found, skipped"
    return
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 not found (needed to read simulator metadata), skipped"
    return
  fi
  local devices_root="$HOME_DIR/Library/Developer/CoreSimulator/Devices"
  if is_whitelisted "$devices_root"; then
    info "whitelisted, skipped: $devices_root"
    return
  fi

  local list
  list="$(xcrun simctl list devices -j 2>/dev/null | python3 -c '
import json, sys, datetime
d = json.load(sys.stdin)
now = datetime.datetime.now(datetime.timezone.utc)
for runtime, devs in d["devices"].items():
    for dev in devs:
        udid = dev["udid"]; name = dev["name"]; state = dev["state"]
        size_kb = int(dev.get("dataPathSize", 0)) // 1024
        lb = dev.get("lastBootedAt")
        days = -1
        if lb:
            try:
                dt = datetime.datetime.strptime(lb, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
                days = (now - dt).days
            except Exception:
                days = -1
        print(f"{udid}\t{name}\t{state}\t{size_kb}\t{days}")
' 2>/dev/null)"

  if [ -z "$list" ]; then
    info "no simulator devices found"
    return
  fi

  local udid name state size_kb days
  local -a del_udids=() del_labels=() del_sizes=()
  local total_kb=0
  while IFS=$'\t' read -r udid name state size_kb days; do
    [ -z "$udid" ] && continue
    [ "$state" = "Booted" ] && continue
    [ "$days" = "-1" ] && continue   # never booted -> a fresh default device, leave it
    [ "$days" -lt "$SIM_STALE_DAYS" ] && continue
    del_udids+=("$udid")
    del_labels+=("$name — last booted $days days ago ($(human_kb "$size_kb"))")
    del_sizes+=("$size_kb")
    total_kb=$((total_kb + size_kb))
  done <<< "$list"

  local n="${#del_udids[@]}"
  if [ "$n" -eq 0 ]; then
    info "no devices unused for $SIM_STALE_DAYS+ days (currently-booted and never-booted devices are always left alone)"
    return
  fi

  info "found $n device(s) unused for $SIM_STALE_DAYS+ days:"
  local i
  for ((i = 0; i < n; i++)); do
    info "  ${del_labels[$i]}"
  done

  if [ "$MODE" = "scan" ]; then
    TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + total_kb))
    return
  fi

  if ! confirm_action_ok sim-stale \
    "Delete these $n unused simulator device(s)? (Xcode recreates default devices on demand; custom ones are gone for good)"; then
    return
  fi

  for ((i = 0; i < n; i++)); do
    udid="${del_udids[$i]}"
    if xcrun simctl delete "$udid" >>"$LOG_FILE" 2>&1; then
      TOTAL_RECLAIMED_KB=$((TOTAL_RECLAIMED_KB + del_sizes[i]))
      ok "deleted: ${del_labels[$i]}"
    else
      err "failed to delete device $udid (see log)"
    fi
  done
  TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + total_kb))
}

cat_claude_cache() {
  section "Claude desktop app cache"
  if [ "$INCLUDE_CLAUDE_CACHE" != 1 ]; then
    warn "skipped (opt-in only, pass --include-claude-cache)"
    return
  fi

  local base="$HOME_DIR/Library/Application Support/Claude"
  if [ ! -d "$base" ]; then
    info "Claude app data not found, skipped"
    return
  fi

  # Only standard Electron/Chromium browser-cache directories — never touches
  # conversation/session state (Local Storage, IndexedDB, Session Storage,
  # Preferences, Partitions) or vm_bundles (the local agent-mode VM image,
  # reported separately below since it's not a cache and re-downloading it
  # is expensive).
  local sub
  for sub in Cache "Code Cache" GPUCache DawnGraphiteCache DawnWebGPUCache Crashpad "Shared Dictionary"; do
    [ -e "$base/$sub" ] && clear_dir_contents "$base/$sub"
  done

  if [ -d "$base/vm_bundles" ]; then
    local vm_size
    vm_size="$(dir_size_kb "$base/vm_bundles")"
    warn "not touched: $base/vm_bundles ($(human_kb "$vm_size")) — this is the local agent-mode VM image, not a cache; review manually if you don't use Claude's local/agent code execution features"
  fi
}

cat_android() {
  section "Android SDK: unreferenced system images + long-unused AVDs"
  if [ "$INCLUDE_ANDROID" != 1 ]; then
    warn "skipped (opt-in only, pass --include-android; tune with --android-stale-days N, default $ANDROID_STALE_DAYS)"
    return
  fi

  local sdk_images="$HOME_DIR/Library/Android/sdk/system-images"
  # ANDROID_AVD_HOME relocates the AVD directory, and Android Studio sets it
  # for anyone who moved their AVDs off the boot volume. Reading only
  # ~/.android/avd on such a machine finds no AVDs at all, which used to mean
  # "nothing references any image" — and every system image was deleted.
  local avd_root="${ANDROID_AVD_HOME:-$HOME_DIR/.android/avd}"

  if [ -d "$sdk_images" ] && ! is_whitelisted "$sdk_images"; then
    # Each leaf 3-level dir under system-images (api/tag/abi) is one image.
    # An AVD references one via its config.ini's image.sysdir.N value, e.g.
    # "system-images/android-34/google_apis/arm64-v8a/".
    #
    # Deleting an image because no AVD was found referencing it is an argument
    # from absence, and it is only worth anything if the evidence is sound. So
    # every reference is format-checked, and anything that does not parse
    # cleanly disables deletion for the whole category rather than being
    # skipped quietly.
    local -a referenced=()
    local evidence_ok=1 ini_count=0 bad_refs=0

    if [ ! -d "$avd_root" ]; then
      evidence_ok=0
      warn "no AVD directory at $avd_root — cannot tell which system images are in use"
    else
      local ini key val
      for ini in "$avd_root"/*.avd/config.ini; do
        [ -e "$ini" ] || continue
        if [ ! -r "$ini" ]; then
          evidence_ok=0
          warn "unreadable: $ini"
          continue
        fi
        ini_count=$((ini_count + 1))
        while IFS='=' read -r key val; do
          # config.ini is written by a cross-platform tool and turns up with
          # CRLF endings. A trailing \r made the reference match nothing, so a
          # referenced image looked unused.
          key="${key%$'\r'}"
          val="${val%$'\r'}"
          case "$key" in
            image.sysdir.*)
              val="${val%/}"
              case "$val" in
                system-images/*/*/*)
                  # Exactly three components after the prefix, no traversal.
                  case "$val" in
                    */../* | */..) bad_refs=$((bad_refs + 1)) ;;
                    system-images/*/*/*/*) bad_refs=$((bad_refs + 1)) ;;
                    *) referenced+=("$val") ;;
                  esac
                  ;;
                "")
                  bad_refs=$((bad_refs + 1))
                  ;;
                *)
                  bad_refs=$((bad_refs + 1))
                  ;;
              esac
              ;;
          esac
        done < "$ini"
      done

      if [ "$bad_refs" -gt 0 ]; then
        evidence_ok=0
        warn "$bad_refs image reference(s) in $avd_root did not match the expected"
        warn "system-images/<api>/<tag>/<abi> form; not deleting anything"
      fi
      if [ "$ini_count" -eq 0 ]; then
        evidence_ok=0
        warn "no readable AVD config.ini under $avd_root — cannot tell which images are in use"
      fi
    fi

    local api_dir tag_dir abi_dir leaf rel found
    for api_dir in "$sdk_images"/*/; do
      [ -d "$api_dir" ] || continue
      for tag_dir in "$api_dir"*/; do
        [ -d "$tag_dir" ] || continue
        for abi_dir in "$tag_dir"*/; do
          [ -d "$abi_dir" ] || continue
          leaf="${abi_dir%/}"
          rel="system-images/${leaf#"$sdk_images"/}"
          found=0
          local r
          for r in "${referenced[@]:-}"; do
            [ "$r" = "$rel" ] && { found=1; break; }
          done
          [ "$found" -eq 1 ] && continue

          if [ "$evidence_ok" != 1 ]; then
            # Report-only: the image may well be unused, but nothing here
            # establishes that, and re-downloading is cheaper than guessing.
            info "possibly unused (NOT removed — see the warning above): $rel  ($(human_kb "$(dir_size_kb "$leaf")"))"
            continue
          fi
          info "unreferenced by any AVD:"
          remove_path "$leaf"
        done
      done
    done
  else
    info "no Android system-images directory found"
  fi

  if [ -d "$avd_root" ] && ! is_whitelisted "$avd_root"; then
    local ini name avd_dir mtime_src last_epoch now_epoch days size_kb
    now_epoch="$(date +%s)"
    for ini in "$avd_root"/*.ini; do
      [ -e "$ini" ] || continue
      name="$(basename "$ini" .ini)"
      avd_dir="$avd_root/$name.avd"
      [ -d "$avd_dir" ] || continue

      mtime_src="$avd_dir/userdata-qemu.img"
      [ -e "$mtime_src" ] || mtime_src="$avd_dir"
      last_epoch="$(stat -f '%m' "$mtime_src" 2>/dev/null || echo 0)"
      days=$(( (now_epoch - last_epoch) / 86400 ))
      size_kb="$(dir_size_kb "$avd_dir")"

      if [ "$days" -lt "$ANDROID_STALE_DAYS" ]; then
        verbose "keeping AVD (used $days days ago): $name"
        continue
      fi

      info "unused for $days days: $name ($(human_kb "$size_kb"))"
      if [ "$MODE" = "scan" ]; then
        TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + size_kb))
        continue
      fi
      if ! confirm_action_ok android \
        "Delete AVD '$name' (unused $days days, $(human_kb "$size_kb"))? Recreatable, but any app data inside it is lost."; then
        continue
      fi
      if command -v avdmanager > /dev/null 2>&1; then
        # If this fails the AVD stays registered in Android Studio's Device
        # Manager while its files go away, which looks like a broken entry
        # rather than a deleted one. Say so instead of hiding it.
        if ! tool_cleanup "deregistered AVD '$name'" "" \
          avdmanager delete avd -n "$name"; then
          warn "'$name' may still be listed in Device Manager; remove it there"
        fi
      fi
      remove_path "$avd_dir"
      remove_path "$ini"
    done
  else
    info "no Android AVDs directory found"
  fi
}

# ---------------------------------------------------------------------------
# Full Disk Access (TCC) preflight
#
# Since macOS Mojave, ~/Library/Application Support/{Google/Chrome,Firefox,
# BraveSoftware,Microsoft Edge}, ~/Library/Safari, ~/Library/Mail and friends
# are TCC-protected: a terminal without Full Disk Access gets "Operation not
# permitted" and — crucially — `du`/`rm` silently report those trees as 0 B.
# That is why browser junk survives every clean and keeps showing up as
# "System Data" in Settings > General > Storage.
# ---------------------------------------------------------------------------

FDA_OK=-1   # -1 unknown, 1 granted, 0 denied

# Probe a handful of TCC-protected paths that exist on essentially every Mac.
# If at least one is readable we have Full Disk Access.
check_full_disk_access() {
  [ "$FDA_OK" != -1 ] && return 0
  local probe found=0 blocked=0
  for probe in \
    "$HOME_DIR/Library/Safari" \
    "$HOME_DIR/Library/Application Support/Google/Chrome" \
    "$HOME_DIR/Library/Application Support/Firefox" \
    "$HOME_DIR/Library/Messages" \
    "$HOME_DIR/Library/Cookies"
  do
    [ -d "$probe" ] || continue
    if ls "$probe" >/dev/null 2>&1; then found=1; else blocked=1; fi
  done
  if [ "$found" = 1 ] || [ "$blocked" = 0 ]; then FDA_OK=1; else FDA_OK=0; fi
  return 0
}

# Print a loud, actionable warning once if we are running without FDA.
warn_if_no_full_disk_access() {
  check_full_disk_access
  [ "$FDA_OK" = 1 ] && return 0
  local term="your terminal app"
  case "${TERM_PROGRAM:-}" in
    Apple_Terminal) term="Terminal" ;;
    iTerm.app) term="iTerm" ;;
    vscode) term="Visual Studio Code" ;;
    WarpTerminal) term="Warp" ;;
    ghostty) term="Ghostty" ;;
    WezTerm) term="WezTerm" ;;
  esac
  say ""
  say "${C_BOLD}${C_YELLOW}!! Full Disk Access is NOT granted to $term${C_RESET}"
  warn "macOS is blocking reads of Chrome/Brave/Edge/Firefox/Safari/Mail data."
  warn "Those folders will scan as 0 B and cannot be cleaned — this is usually"
  warn "the single biggest chunk of unexplained \"System Data\" on a dev Mac."
  warn ""
  warn "Fix: System Settings > Privacy & Security > Full Disk Access >"
  warn "     add and enable $term, then quit and reopen it and re-run this script."
  say ""
}

# True if a path is unreadable because of TCC rather than because it is absent.
path_blocked_by_tcc() {
  local p="$1"
  [ -d "$p" ] || return 1
  ls "$p" >/dev/null 2>&1 && return 1
  return 0
}

# Warn (once per path) that a directory exists but cannot be read.
note_tcc_block() {
  local p="$1"
  warn "no permission to read: $p  (grant Full Disk Access — see top of this run)"
}

# ---------------------------------------------------------------------------
# Running-app guard
#
# Chromium wipes are pointless (and occasionally confusing) while the browser
# is live: it holds the cache files open, immediately re-creates them, and the
# freed space does not show up until it quits. We never kill anything — we
# just tell the truth about it.
# ---------------------------------------------------------------------------

app_is_running() {
  # $1 = .app bundle name without extension, e.g. "Google Chrome"
  pgrep -f "/${1}.app/Contents/MacOS/" >/dev/null 2>&1
}

RUNNING_APPS_SEEN=""
note_if_running() {
  local app="$1"
  app_is_running "$app" || return 1
  case ",$RUNNING_APPS_SEEN," in
    *",$app,"*) ;;
    *)
      RUNNING_APPS_SEEN="${RUNNING_APPS_SEEN:+$RUNNING_APPS_SEEN,}$app"
      warn "$app is running — quit it first or it will just rewrite these caches"
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Chromium engine cleaner (shared by browsers + Electron apps)
#
# Only ever touches directories Chromium itself treats as a disposable cache.
# Explicitly NEVER touched: Login Data, Cookies, History, Bookmarks, Web Data,
# Preferences, Secure Preferences, Local Storage, Session Storage, IndexedDB,
# Sessions, Extensions, Local Extension Settings, Sync Data.
# ---------------------------------------------------------------------------

# Disposable caches that live inside a single profile directory.
CHROMIUM_PROFILE_CACHES=(
  "Cache"
  "Code Cache"
  "GPUCache"
  "DawnCache"
  "DawnGraphiteCache"
  "DawnWebGPUCache"
  "GraphiteDawnCache"
  "ShaderCache"
  "GrShaderCache"
  "Media Cache"
  "Application Cache"
  "PnaclTranslationCache"
  "blob_storage"
  "Service Worker/CacheStorage"
  "Service Worker/ScriptCache"
  "Shared Dictionary/cache"
  "Storage/ext/.cache"
  "optimization_guide_prediction_model_downloads"
  "extensions_crx_cache"
  "component_crx_cache"
)

# Disposable caches that live at the browser's user-data root (shared by all
# profiles), not inside a profile.
CHROMIUM_ROOT_CACHES=(
  "GrShaderCache"
  "ShaderCache"
  "GraphiteDawnCache"
  "component_crx_cache"
  "extensions_crx_cache"
  "optimization_guide_model_store"
  "Crashpad/completed"
  "Crashpad/pending"
  "SwReporter"
  "Webstore Downloads"
)

# Extra root-level dirs only cleared with --aggressive: they are still pure
# cache, but they cost a fresh multi-hundred-MB download to rebuild.
CHROMIUM_ROOT_CACHES_AGGRESSIVE=(
  "Safe Browsing"
  "Snapshots"
  "OnDeviceHeadSuggestModel"
  "SafetyTips"
  "Subresource Filter"
  "FileTypePolicies"
  "MEIPreload"
)

# clean_chromium_profile <profile-dir>
clean_chromium_profile() {
  local prof="$1" sub
  [ -d "$prof" ] || return 0
  for sub in "${CHROMIUM_PROFILE_CACHES[@]}"; do
    [ -d "$prof/$sub" ] && clear_dir_contents "$prof/$sub"
  done
  # Note: "Network Action Predictor" and "Visited Links" are deliberately left
  # alone. They are small, and wiping them degrades omnibox suggestions.
  return 0
}

# clean_chromium_root <user-data-dir> — clears shared caches, then every profile.
clean_chromium_root() {
  local root="$1" sub prof
  [ -d "$root" ] || return 0

  if path_blocked_by_tcc "$root"; then
    note_tcc_block "$root"
    return 0
  fi

  for sub in "${CHROMIUM_ROOT_CACHES[@]}"; do
    [ -d "$root/$sub" ] && clear_dir_contents "$root/$sub"
  done
  if [ "$AGGRESSIVE" = 1 ]; then
    for sub in "${CHROMIUM_ROOT_CACHES_AGGRESSIVE[@]}"; do
      [ -d "$root/$sub" ] && clear_dir_contents "$root/$sub"
    done
  fi

  # Every profile: Default, Profile 1..N, Guest Profile, System Profile, and
  # any other directory that carries a profile's tell-tale Preferences file.
  for prof in "$root"/*/; do
    prof="${prof%/}"
    [ -d "$prof" ] || continue
    case "$(basename "$prof")" in
      Default|Profile*|"Guest Profile"|"System Profile") ;;
      *) [ -f "$prof/Preferences" ] || continue ;;
    esac
    clean_chromium_profile "$prof"
  done

  # Opera and a few others keep the profile at the root itself.
  [ -f "$root/Preferences" ] && clean_chromium_profile "$root"
  return 0
}

# ---------------------------------------------------------------------------
# Category: browsers
# ---------------------------------------------------------------------------

# label :: app-bundle-name :: path relative to ~/Library/Application Support
CHROMIUM_BROWSERS=(
  "Google Chrome::Google Chrome::Google/Chrome"
  "Google Chrome Beta::Google Chrome Beta::Google/Chrome Beta"
  "Google Chrome Canary::Google Chrome Canary::Google/Chrome Canary"
  "Chrome for Testing::Google Chrome for Testing::Google/Chrome for Testing"
  "Chromium::Chromium::Chromium"
  "Brave::Brave Browser::BraveSoftware/Brave-Browser"
  "Brave Beta::Brave Browser Beta::BraveSoftware/Brave-Browser-Beta"
  "Microsoft Edge::Microsoft Edge::Microsoft Edge"
  "Vivaldi::Vivaldi::Vivaldi"
  "Opera::Opera::com.operasoftware.Opera"
  "Opera GX::Opera GX::com.operasoftware.OperaGX"
  "Arc::Arc::Arc/User Data"
  "Dia::Dia::Dia/User Data"
  "Yandex::Yandex::Yandex/YandexBrowser"
  "Comet::Comet::Perplexity/Comet"
)

cat_browsers() {
  section "Browser caches (Chromium family + Firefox)"
  check_full_disk_access
  local base="$HOME_DIR/Library/Application Support"
  local entry label app rel root found=0

  for entry in "${CHROMIUM_BROWSERS[@]}"; do
    label="${entry%%::*}"
    app="${entry#*::}"; app="${app%%::*}"
    rel="${entry##*::}"
    root="$base/$rel"
    [ -d "$root" ] || continue
    found=1
    info "-- $label"
    note_if_running "$app"
    clean_chromium_root "$root"
  done

  # Chromium's on-disk HTTP cache actually lives under ~/Library/Caches on
  # macOS, keyed by bundle id. The generic `caches` category covers these too,
  # but browsers is also useful standalone (--only browsers).
  local c
  if ! should_run_category caches; then
  for c in "$HOME_DIR/Library/Caches/Google/Chrome" \
           "$HOME_DIR/Library/Caches/com.google.Chrome" \
           "$HOME_DIR/Library/Caches/com.google.Chrome.canary" \
           "$HOME_DIR/Library/Caches/BraveSoftware" \
           "$HOME_DIR/Library/Caches/com.brave.Browser" \
           "$HOME_DIR/Library/Caches/Microsoft Edge" \
           "$HOME_DIR/Library/Caches/com.microsoft.edgemac" \
           "$HOME_DIR/Library/Caches/Chromium" \
           "$HOME_DIR/Library/Caches/company.thebrowser.Browser" \
           "$HOME_DIR/Library/Caches/com.operasoftware.Opera" \
           "$HOME_DIR/Library/Caches/Vivaldi"
  do
    [ -d "$c" ] && { found=1; clear_dir_contents "$c"; }
  done
  fi

  # Firefox: different engine, different layout.
  local ff="$base/Firefox/Profiles"
  if [ -d "$ff" ]; then
    found=1
    info "-- Firefox"
    note_if_running "Firefox"
    if path_blocked_by_tcc "$base/Firefox"; then
      note_tcc_block "$base/Firefox"
    else
      local p s
      for p in "$ff"/*/; do
        p="${p%/}"
        [ -d "$p" ] || continue
        for s in startupCache shader-cache "storage/default/http+++.cache"; do
          [ -d "$p/$s" ] && clear_dir_contents "$p/$s"
        done
      done
    fi
  fi
  if ! should_run_category caches; then
    [ -d "$HOME_DIR/Library/Caches/Firefox" ] && { found=1; clear_dir_contents "$HOME_DIR/Library/Caches/Firefox"; }
  fi

  # Safari is fully TCC-protected and its cache is managed by the OS; we only
  # report it so the number is not silently missing from the total.
  if [ -d "$HOME_DIR/Library/Containers/com.apple.Safari/Data/Library/Caches" ]; then
    local sk
    sk="$(dir_size_kb "$HOME_DIR/Library/Containers/com.apple.Safari/Data/Library/Caches")"
    [ "${sk:-0}" -gt 0 ] && info "Safari cache: $(human_kb "$sk") — clear via Safari > Settings > Advanced > Develop > Empty Caches"
  fi

  [ "$found" = 0 ] && info "no Chromium/Firefox browser data found"
  return 0
}

# ---------------------------------------------------------------------------
# Category: electron
#
# Every Electron app ships the same Chromium cache layout, usually at
# ~/Library/Application Support/<App>/ and ~/Library/Application Support/<App>/
# Partitions/<partition>/. On a working dev Mac this is routinely several GB
# (Notion, Slack, Postman, Obsidian, Discord, VS Code forks, ...) and nothing
# in macOS ever reclaims it.
# ---------------------------------------------------------------------------

# App-root caches, on top of the per-profile list above. These are the dirs
# Electron/VS Code-family apps put directly in the app support folder.
ELECTRON_APP_CACHES=(
  "Cache"
  "Code Cache"
  "GPUCache"
  "DawnCache"
  "DawnGraphiteCache"
  "DawnWebGPUCache"
  "GraphiteDawnCache"
  "ShaderCache"
  "GrShaderCache"
  "blob_storage"
  "Crashpad/completed"
  "Crashpad/pending"
  "Shared Dictionary/cache"
  "Service Worker/CacheStorage"
  "Service Worker/ScriptCache"
  "component_crx_cache"
  "CachedData"
  "CachedExtensionVSIXs"
  "CachedProfilesData"
  "Cache Storage"
  "logs"
)

# Apps whose data we deliberately leave to their own dedicated category or
# leave alone entirely.
ELECTRON_SKIP=(
  "Google"          # handled by browsers/ide-stale
  "Firefox"
  "Chromium"
  "BraveSoftware"
  "Microsoft Edge"
  "Vivaldi"
  "Arc"
  "MobileSync"
)

electron_is_skipped() {
  local name="$1" s
  for s in "${ELECTRON_SKIP[@]}"; do
    [ "$name" = "$s" ] && return 0
  done
  return 1
}

cat_electron() {
  section "Electron app caches (Notion, Slack, VS Code, Postman, ...)"
  local base="$HOME_DIR/Library/Application Support"
  [ -d "$base" ] || { info "no Application Support dir"; return; }

  local app name sub part found=0
  for app in "$base"/*/; do
    app="${app%/}"
    name="$(basename "$app")"
    electron_is_skipped "$name" && continue

    # Electron fingerprint: at least one of these must exist, otherwise it is
    # just an ordinary app support folder and we do not go near it.
    if [ ! -d "$app/Cache" ] && [ ! -d "$app/Code Cache" ] && \
       [ ! -d "$app/GPUCache" ] && [ ! -d "$app/Partitions" ] && \
       [ ! -d "$app/Service Worker" ]; then
      continue
    fi

    found=1
    info "-- $name"
    note_if_running "$name"

    for sub in "${ELECTRON_APP_CACHES[@]}"; do
      [ -d "$app/$sub" ] && clear_dir_contents "$app/$sub"
    done

    # Partitions/<name>/ are full Chromium profiles — this is where Notion and
    # friends hide the multi-GB Service Worker CacheStorage.
    if [ -d "$app/Partitions" ]; then
      for part in "$app/Partitions"/*/; do
        part="${part%/}"
        [ -d "$part" ] || continue
        clean_chromium_profile "$part"
      done
    fi
  done

  [ "$found" = 0 ] && info "no Electron app caches found"
  return 0
}

# ---------------------------------------------------------------------------
# Category: dev-caches
#
# Language/toolchain caches that are pure download or build cache: every one
# of these is re-fetched or re-built on demand. Package *stores* that hold the
# only copy of a dependency (pub-cache, .m2, cargo registry/src) are left
# alone on purpose.
# ---------------------------------------------------------------------------

cat_dev_caches() {
  section "Developer tool caches"

  # Tools that own their own cache-clearing command get to use it.
  # `uv cache prune` only drops entries no installed environment references,
  # so its yield is a fraction of the directory size — we do NOT count the
  # whole directory as reclaimable. `--aggressive` switches to `uv cache
  # clean`, which does wipe the lot (everything is re-downloadable).
  if command -v uv >/dev/null 2>&1 && [ -d "$HOME_DIR/.cache/uv" ]; then
    local uv_before uv_cmd
    uv_before="$(dir_size_kb "$HOME_DIR/.cache/uv")"
    if [ "$AGGRESSIVE" = 1 ]; then uv_cmd="clean"; else uv_cmd="prune"; fi
    if [ "$MODE" = "scan" ]; then
      info "would run: uv cache $uv_cmd  (~/.cache/uv is $(human_kb "$uv_before"))"
      if [ "$uv_cmd" = "clean" ]; then
        TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + uv_before))
      else
        info "  (prune only drops unreferenced entries — pass --aggressive to wipe all $(human_kb "$uv_before"))"
      fi
    elif is_whitelisted "$HOME_DIR/.cache/uv"; then
      info "whitelisted, skipped: ~/.cache/uv"
    else
      tool_cleanup "uv cache $uv_cmd done" "$HOME_DIR/.cache/uv" \
        uv cache "$uv_cmd"
    fi
  fi

  if command -v go >/dev/null 2>&1; then
    local go_cache
    go_cache="$(go env GOCACHE 2>/dev/null)"
    if [ -n "$go_cache" ] && [ -d "$go_cache" ]; then
      # `go env GOCACHE` is authoritative for where Go's cache lives and it is
      # not predictable from $HOME, so it is registered as an explicit allowed
      # root rather than being exempted from authorization.
      path_register_allowed_root "$go_cache"
      if [ "$MODE" = "scan" ]; then
        info "would run: go clean -cache  ($(human_kb "$(dir_size_kb "$go_cache")") at $go_cache)"
        TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + $(dir_size_kb "$go_cache")))
      else
        clear_dir_contents "$go_cache"
      fi
    fi
  fi

  # Plain directory caches. Each one is regenerated automatically.
  local d
  for d in \
    "$HOME_DIR/.cache/trivy" \
    "$HOME_DIR/.cache/github-copilot" \
    "$HOME_DIR/.cache/giget" \
    "$HOME_DIR/.cache/gh" \
    "$HOME_DIR/.cache/gem" \
    "$HOME_DIR/.cache/firebase" \
    "$HOME_DIR/.cache/vscode-ripgrep" \
    "$HOME_DIR/.cache/mesa_shader_cache" \
    "$HOME_DIR/.cache/node-gyp" \
    "$HOME_DIR/.cache/puppeteer/.cache" \
    "$HOME_DIR/.cache/ms-playwright" \
    "$HOME_DIR/.cache/deno" \
    "$HOME_DIR/.cache/bazel" \
    "$HOME_DIR/.cache/sccache" \
    "$HOME_DIR/.cargo/registry/cache" \
    "$HOME_DIR/.dotnet/optimizationdata" \
    "$HOME_DIR/.nuget/packages/.tools" \
    "$HOME_DIR/.m2/repository/.cache" \
    "$HOME_DIR/.cache/go-build" \
    "$HOME_DIR/.cache/codex-runtimes" \
    "$HOME_DIR/.cache/pkg" \
    "$HOME_DIR/.cache/wine" \
    "$HOME_DIR/.gradle/.tmp" \
    "$HOME_DIR/.gradle/daemon" \
    "$HOME_DIR/.gradle/native" \
    "$HOME_DIR/.npm/_cacache" \
    "$HOME_DIR/.nuget/v3-cache" \
    "$HOME_DIR/.local/share/NuGet/v3-cache" \
    "$HOME_DIR/.local/share/NuGet/plugins-cache"
  do
    [ -d "$d" ] && clear_dir_contents "$d"
  done

  # These live under ~/Library/Caches, which the `caches` category already
  # wipes wholesale. Doing them here too would double-count them in the scan
  # estimate, so only run them when `caches` is not part of this run (i.e.
  # someone asked for --only dev-caches).
  if ! should_run_category caches; then
    for d in \
      "$HOME_DIR/Library/Caches/deno" \
      "$HOME_DIR/Library/Caches/ms-playwright" \
      "$HOME_DIR/Library/Caches/typescript" \
      "$HOME_DIR/Library/Caches/electron" \
      "$HOME_DIR/Library/Caches/electron-builder" \
      "$HOME_DIR/Library/Caches/Yarn" \
      "$HOME_DIR/Library/Caches/org.swift.swiftpm" \
      "$HOME_DIR/Library/Caches/com.apple.dt.Xcode" \
      "$HOME_DIR/Library/Caches/JetBrains" \
      "$HOME_DIR/Library/Caches/Homebrew"
    do
      [ -d "$d" ] && clear_dir_contents "$d"
    done
  fi

  # Flutter/Dart build leftovers that are not the package store itself.
  [ -d "$HOME_DIR/.pub-cache/.tmp" ] && clear_dir_contents "$HOME_DIR/.pub-cache/.tmp"
  [ -d "$HOME_DIR/.dartServer" ] && clear_dir_contents "$HOME_DIR/.dartServer"
  return 0
}

# ---------------------------------------------------------------------------
# Category: ide-stale (opt-in)
#
# JetBrains and Android Studio never delete the config/plugin/cache folders of
# the version you upgraded away from — each one is 300-500 MB and they stack up
# release after release. We keep the newest of each product family.
# ---------------------------------------------------------------------------

cat_ide_stale() {
  section "Superseded JetBrains / Android Studio version folders"
  if [ "$INCLUDE_IDE_STALE" != 1 ]; then
    warn "skipped (opt-in only, pass --include-ide-stale)"
    return
  fi

  local roots=(
    "$HOME_DIR/Library/Application Support/JetBrains"
    "$HOME_DIR/Library/Application Support/Google"
    "$HOME_DIR/Library/Caches/JetBrains"
    "$HOME_DIR/Library/Caches/Google"
    "$HOME_DIR/Library/Logs/JetBrains"
  )

  local root dir name family newest
  for root in "${roots[@]}"; do
    [ -d "$root" ] || continue

    # Group "<Product><Year>.<n>.<n>" dirs by product, keep the newest.
    local families=""
    for dir in "$root"/*/; do
      dir="${dir%/}"
      name="$(basename "$dir")"
      # Must look like ProductName + version, e.g. AndroidStudio2026.1.3
      case "$name" in
        *[0-9][0-9][0-9][0-9].[0-9]*) ;;
        *) continue ;;
      esac
      family="$(printf '%s' "$name" | sed -E 's/[0-9]{4}\.[0-9].*$//')"
      [ -z "$family" ] && continue
      case " $families " in
        *" $family "*) ;;
        *) families="$families $family" ;;
      esac
    done

    for family in $families; do
      # Version sort; the last entry is the newest and is always kept.
      newest="$(ls -1d "$root/$family"*/ 2>/dev/null | sed 's:/$::' | sort -V | tail -1)"
      [ -n "$newest" ] || continue
      for dir in "$root/$family"*/; do
        dir="${dir%/}"
        [ -d "$dir" ] || continue
        [ "$dir" = "$newest" ] && { verbose "keeping newest: $dir"; continue; }
        remove_path "$dir"
      done
      info "kept newest $family: $(basename "$newest")"
    done
  done
  return 0
}

# ---------------------------------------------------------------------------
# Category: ml-caches (opt-in)
#
# Hugging Face / PyTorch / Ollama / LM Studio model blobs. Trivially the
# largest thing in a lot of home directories, but re-downloading a model is
# expensive (and sometimes gated), so this is opt-in and never silent.
# ---------------------------------------------------------------------------

cat_ml_caches() {
  section "ML model caches (Hugging Face, torch, Ollama, LM Studio)"
  if [ "$INCLUDE_ML_CACHES" != 1 ]; then
    # Still report the sizes: knowing it is there is the whole point.
    local d sz any=0
    for d in "$HOME_DIR/.cache/huggingface" "$HOME_DIR/.cache/torch" \
             "$HOME_DIR/.ollama/models" "$HOME_DIR/.lmstudio/models"; do
      [ -d "$d" ] || continue
      sz="$(dir_size_kb "$d")"
      [ "${sz:-0}" -gt 0 ] || continue
      any=1
      info "$d — $(human_kb "$sz")"
    done
    [ "$any" = 1 ] && warn "not removed (opt-in: pass --include-ml-caches)" \
                   || info "no ML model caches found"
    return
  fi

  # Hugging Face: prefer its own GC so refs/symlinks stay consistent.
  if [ -d "$HOME_DIR/.cache/huggingface" ]; then
    if [ "$MODE" = "clean" ] && ! confirm_action_ok ml-caches \
      "Delete the Hugging Face model cache? Models will be re-downloaded on next use."; then
      :
    else
      clear_dir_contents "$HOME_DIR/.cache/huggingface/hub"
      clear_dir_contents "$HOME_DIR/.cache/huggingface/datasets"
      clear_dir_contents "$HOME_DIR/.cache/huggingface/xet"
    fi
  fi
  [ -d "$HOME_DIR/.cache/torch" ] && clear_dir_contents "$HOME_DIR/.cache/torch"

  # Ollama / LM Studio are reported only: these are usually deliberately
  # downloaded models, and both apps have their own uninstall UI.
  local d sz
  for d in "$HOME_DIR/.ollama/models" "$HOME_DIR/.lmstudio/models"; do
    [ -d "$d" ] || continue
    sz="$(dir_size_kb "$d")"
    [ "${sz:-0}" -gt 0 ] && warn "not touched: $d ($(human_kb "$sz")) — remove individual models from the app instead"
  done
  return 0
}

# ---------------------------------------------------------------------------
# Category: ios-backups (opt-in)
# ---------------------------------------------------------------------------

cat_ios_backups() {
  section "iPhone/iPad backups (MobileSync)"
  local base="$HOME_DIR/Library/Application Support/MobileSync/Backup"
  if [ ! -d "$base" ]; then
    info "no local device backups found"
    return
  fi
  if path_blocked_by_tcc "$base"; then
    note_tcc_block "$base"
    return
  fi

  local b sz
  if [ "$INCLUDE_IOS_BACKUPS" != 1 ]; then
    for b in "$base"/*/; do
      b="${b%/}"; [ -d "$b" ] || continue
      sz="$(dir_size_kb "$b")"
      info "$(basename "$b") — $(human_kb "$sz")  (last modified $(date -r "$b" '+%Y-%m-%d' 2>/dev/null))"
    done
    warn "not removed (opt-in: pass --include-ios-backups). These are full device"
    warn "backups — deleting one is irreversible if you have no iCloud backup."
    return
  fi

  for b in "$base"/*/; do
    b="${b%/}"; [ -d "$b" ] || continue
    sz="$(dir_size_kb "$b")"
    if [ "$MODE" = "clean" ]; then
      confirm_action_ok ios-backups \
        "Delete backup $(basename "$b") ($(human_kb "$sz"), $(date -r "$b" '+%Y-%m-%d' 2>/dev/null))?" \
        || continue
    fi
    remove_path "$b"
  done
  return 0
}

# ---------------------------------------------------------------------------
# Disk report: where the space actually went
#
# Everything above only removes things that are safe to remove automatically.
# A dev Mac's "System Data" is mostly stuff no cleaner should delete for you
# (SDKs, VM disks, model weights, node_modules). This prints it so you can
# make the call yourself.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# "System Data" accounting
#
# Settings > General > Storage shows one grey number and no way to drill into
# it. It is not a folder — it is whatever Finder could not file under
# Applications/Documents/Photos/Music/Mail/Developer. On a dev Mac that is
# overwhelmingly ~/Library, the dot-directories in $HOME, and the OS trees
# outside $HOME.
#
# This maps that number back onto real paths and says, for each one, whether
# this script can clean it, whether it is your call, or whether it should be
# left alone.
# ---------------------------------------------------------------------------

# path :: tier :: label :: how to deal with it
#   tier 1 = a category cleans it
#   tier 2 = real data, your call, never removed automatically
#   tier 3 = OS or installed software, leave alone
# ---------------------------------------------------------------------------
# Category: tmp
#
# $TMPDIR (/private/var/folders/<x>/<y>/T) and the matching per-user cache
# directory (.../C). macOS only sweeps these on boot, and only for files past
# a few days old, so a machine that stays awake for weeks accumulates
# gigabytes of abandoned test scratch, build temp and installer payloads here.
#
# Age-gated by default because $TMPDIR is live: a running process may well be
# using a file created minutes ago. Anything newer than --tmp-stale-days is
# reported but left alone.
# ---------------------------------------------------------------------------

cat_tmp() {
  section "Temporary files (\$TMPDIR + per-user cache)"

  local tdir cdir
  tdir="${TMPDIR:-}"
  tdir="${tdir%/}"
  if [ -z "$tdir" ] || [ ! -d "$tdir" ]; then
    info "no \$TMPDIR found, skipped"
    return
  fi
  # .../T and .../C are siblings under the same per-user folder.
  cdir="$(dirname "$tdir")/C"

  local days="$TMP_STALE_DAYS"
  [ "$AGGRESSIVE" = 1 ] && days=0

  local root entry kept_kb=0 kept_n=0 sz
  for root in "$tdir" "$cdir"; do
    [ -d "$root" ] || continue
    info "-- $root ($(human_kb "$(dir_size_kb "$root")"))"

    # -mindepth/-maxdepth 1: only whole top-level entries, never a file from
    # inside a directory some process is mid-write on.
    while IFS= read -r entry; do
      [ -e "$entry" ] || continue
      case "$(basename "$entry")" in
        # Apple's own live IPC/staging dirs — removing these while the OS is
        # running causes visible breakage rather than reclaiming anything.
        com.apple.*|TemporaryItems|.keystone_install*|Cleanup\ At\ Startup) continue ;;
      esac
      remove_path "$entry"
    done < <(find "$root" -mindepth 1 -maxdepth 1 -mtime +"$days" 2>/dev/null)

    # Report what the age gate spared, so a multi-GB fresh scratch dir is
    # still visible rather than silently skipped.
    while IFS= read -r entry; do
      [ -e "$entry" ] || continue
      sz="$(dir_size_kb "$entry")"
      [ "${sz:-0}" -gt 102400 ] || continue    # only flag entries over 100 MB
      kept_n=$((kept_n + 1))
      kept_kb=$((kept_kb + sz))
      warn "left alone (modified in the last $days day(s)): $entry ($(human_kb "$sz"))"
    done < <(find "$root" -mindepth 1 -maxdepth 1 -mtime -"$((days + 1))" 2>/dev/null)
  done

  if [ "$kept_n" -gt 0 ]; then
    info "$kept_n recent item(s) totalling $(human_kb "$kept_kb") were skipped as too new."
    info "Quit the app that owns them and re-run, or use --aggressive to take them anyway."
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Category: toolchains (opt-in)
#
# SDK/compiler toolchains that each pin their own version and never clean up
# after an upgrade: Kotlin/Native prebuilts, Gradle wrapper distributions,
# Gradle's auto-provisioned JDKs, SDKMAN candidates. All are re-downloaded on
# demand, but a project pinned to an old version will re-fetch it, so this is
# opt-in and always keeps the newest.
# ---------------------------------------------------------------------------

# Keep the newest N entries matching a glob, remove the rest. Version-sorted.
# $1 = human label, $2 = keep count, $3.. = candidate dirs
_keep_newest_versions() {
  local label="$1" keep="$2"; shift 2
  local total=$# dir i=0 sorted
  [ "$total" -gt 0 ] || return 0
  if [ "$total" -le "$keep" ]; then
    info "$label: $total installed, keeping all (limit $keep)"
    return 0
  fi
  sorted="$(printf '%s\n' "$@" | sort -V)"
  local drop=$((total - keep))
  while IFS= read -r dir; do
    i=$((i + 1))
    [ "$i" -gt "$drop" ] && break
    remove_path "$dir"
  done <<EOF
$sorted
EOF
  info "$label: kept the newest $keep of $total"
  return 0
}

cat_toolchains() {
  section "Superseded SDK/compiler toolchains"
  if [ "$INCLUDE_TOOLCHAINS" != 1 ]; then
    local d sz any=0
    for d in "$HOME_DIR/.konan" "$HOME_DIR/.gradle/wrapper/dists" \
             "$HOME_DIR/.gradle/jdks" "$HOME_DIR/.sdkman/candidates"; do
      [ -d "$d" ] || continue
      sz="$(dir_size_kb "$d")"
      [ "${sz:-0}" -gt 0 ] || continue
      any=1
      info "$d — $(human_kb "$sz")"
    done
    [ "$any" = 1 ] && warn "not removed (opt-in: pass --include-toolchains)" \
                   || info "no versioned toolchains found"
    return
  fi

  # Kotlin/Native prebuilt compilers — ~1.7 GB each.
  if [ -d "$HOME_DIR/.konan" ]; then
    local konan=()
    local d
    for d in "$HOME_DIR"/.konan/kotlin-native-prebuilt-*/; do
      d="${d%/}"; [ -d "$d" ] && konan+=("$d")
    done
    [ "${#konan[@]}" -gt 0 ] && _keep_newest_versions "Kotlin/Native prebuilts" "$KEEP_TOOLCHAINS" "${konan[@]}"
  fi

  # Gradle wrapper distributions — one per Gradle version any project used.
  if [ -d "$HOME_DIR/.gradle/wrapper/dists" ]; then
    local dists=()
    for d in "$HOME_DIR"/.gradle/wrapper/dists/gradle-*/; do
      d="${d%/}"; [ -d "$d" ] && dists+=("$d")
    done
    [ "${#dists[@]}" -gt 0 ] && _keep_newest_versions "Gradle distributions" "$KEEP_TOOLCHAINS" "${dists[@]}"
  fi

  # JDKs Gradle auto-provisioned for toolchain resolution — always re-fetched.
  if [ -d "$HOME_DIR/.gradle/jdks" ]; then
    info "Gradle auto-provisioned JDKs (re-downloaded on next build):"
    clear_dir_contents "$HOME_DIR/.gradle/jdks"
  fi

  # SDKMAN: every candidate except the one `current` points at.
  if [ -d "$HOME_DIR/.sdkman/candidates" ]; then
    local cand ver current_target
    for cand in "$HOME_DIR"/.sdkman/candidates/*/; do
      cand="${cand%/}"
      [ -d "$cand" ] || continue
      current_target=""
      [ -L "$cand/current" ] && current_target="$(basename "$(readlink "$cand/current")" 2>/dev/null)"
      for ver in "$cand"/*/; do
        ver="${ver%/}"
        case "$(basename "$ver")" in
          current) continue ;;
          "$current_target") verbose "keeping active: $ver"; continue ;;
        esac
        remove_path "$ver"
      done
    done
  fi
  return 0
}

cat_trash() {
  section "Trash"
  if [ "$INCLUDE_TRASH" != 1 ]; then
    warn "skipped (opt-in only, pass --include-trash)"
    return
  fi
  if [ "$MODE" = "clean" ] && ! confirm_action_ok trash \
    "Permanently empty ~/.Trash."; then
    return
  fi
  clear_dir_contents "$HOME_DIR/.Trash"
}
