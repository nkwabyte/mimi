#!/usr/bin/env bash
#
# lib/ui/report.sh lib/report.sh — System Data breakdown and disk space reporting.
#

SYSTEM_DATA_MAP=(
  "$HOME_DIR/Library/Containers/com.docker.docker::1::Docker VM disk (Docker.raw)::--only docker-cache --include-docker-cache (start Docker first)"
  "$HOME_DIR/.cache/huggingface::1::Hugging Face model cache::--only ml-caches --include-ml-caches"
  "$HOME_DIR/Library/Android::1::Android SDK images/NDK::--only android --include-android"
  "$HOME_DIR/.konan::1::Kotlin/Native toolchains::--only toolchains --include-toolchains"
  "$HOME_DIR/.gradle::1::Gradle wrapper dists + JDKs::--only toolchains --include-toolchains"
  "$HOME_DIR/.yarn::1::Yarn Berry global cache::--only yarn"
  "$HOME_DIR/.cache::1::Tool caches (uv, trivy, copilot...)::--only dev-caches"
  "$HOME_DIR/Library/Developer/Xcode/iOS DeviceSupport::1::Xcode device symbol sets::--only device-support --keep-device-support 1"
  "$HOME_DIR/Library/Developer/CoreSimulator::1::iOS Simulator devices::--only sim-stale --include-sim-stale"
  "$HOME_DIR/Library/Application Support/MobileSync::1::iPhone/iPad backups::--only ios-backups --include-ios-backups"
  "$HOME_DIR/Library/Application Support/Claude/vm_bundles::2::Claude local-agent VM image::delete by hand if you do not use local agent mode"
  "$HOME_DIR/.lmstudio::2::LM Studio models::remove individual models inside LM Studio"
  "$HOME_DIR/.ollama::2::Ollama models::ollama rm <model>"
  "$HOME_DIR/.android/avd::2::Android emulator AVDs::delete unused AVDs in Android Studio's Device Manager"
  "$HOME_DIR/.vscode::2::VS Code extensions::uninstall extensions you no longer use"
  "$HOME_DIR/.pub-cache::2::Dart/Flutter package store::dart pub cache clean (re-downloads everything)"
  "$HOME_DIR/.local::2::pipx/uv managed installs::uv python list / pipx list, then uninstall"
  "/Applications::3::Installed apps (shown as Applications, not System Data)::uninstall what you do not use"
  "/opt/homebrew::3::Homebrew prefix::brew autoremove (the homebrew category runs this)"
  "/System/Volumes/Data/System::3::macOS system files::leave alone"
  "/Library::3::System-wide app support::leave alone"
  "/usr::3::Unix tooling::leave alone"
  "/private/var/db::3::OS databases (Spotlight, TCC, receipts)::leave alone"
  "/private/var/vm::3::Swap file::leave alone, macOS sizes it"
)

report_system_data() {
  section "What is in that \"System Data\" number"

  local entry path tier label advice kb
  local sum1=0 sum2=0 sum3=0

  local t
  for t in 1 2 3; do
    case "$t" in
      1) say ""; info "${C_BOLD}REDUCIBLE${C_RESET} — a category targets these (the size shown is the whole tree, not what you would free):" ;;
      2) say ""; info "${C_BOLD}YOUR CALL${C_RESET} — real data, never removed automatically:" ;;
      3) say ""; info "${C_BOLD}LEAVE ALONE${C_RESET} — the OS and your installed software:" ;;
    esac
    for entry in "${SYSTEM_DATA_MAP[@]}"; do
      path="${entry%%::*}"
      tier="${entry#*::}"; tier="${tier%%::*}"
      [ "$tier" = "$t" ] || continue
      [ -e "$path" ] || continue
      label="${entry#*::*::}"; label="${label%%::*}"
      advice="${entry##*::}"
      kb="$(dir_size_kb "$path")"
      # Subtract any other mapped path that lives inside this one, so a parent
      # row does not also count its child's bytes (~/.cache vs
      # ~/.cache/huggingface). Each byte lands in exactly one row.
      local other opath okb
      for other in "${SYSTEM_DATA_MAP[@]}"; do
        opath="${other%%::*}"
        [ "$opath" = "$path" ] && continue
        case "$opath" in
          "$path"/*) ;;
          *) continue ;;
        esac
        [ -e "$opath" ] || continue
        okb="$(dir_size_kb "$opath")"
        kb=$((kb - ${okb:-0}))
      done
      [ "$kb" -lt 0 ] && kb=0
      [ "${kb:-0}" -gt 51200 ] || continue     # skip anything under 50 MB
      case "$t" in
        1) sum1=$((sum1 + kb)) ;;
        2) sum2=$((sum2 + kb)) ;;
        3) sum3=$((sum3 + kb)) ;;
      esac
      printf '  %9s  %-40s %s\n' "$(human_kb "$kb")" "$label" "${C_DIM}$advice${C_RESET}" | tee -a "$LOG_FILE"
      # A VM disk image is sparse: Finder shows what it claims to be, this
      # column shows what it occupies. Saying both stops the report looking
      # like it is under-counting by tens of gigabytes.
      if [ -f "$path" ] && is_sparse_file "$path"; then
        printf '  %9s  %-40s %s\n' "" "" \
          "${C_DIM}sparse: appears as $(human_kb "$(path_logical_kb "$path")"), occupies the $(human_kb "$kb") above${C_RESET}" \
          | tee -a "$LOG_FILE"
      fi
    done
  done

  say ""
  info "Reducible with a flag:  $(human_kb "$sum1")   (upper bound — each category keeps what is still in use)"
  info "Your call:              $(human_kb "$sum2")"
  info "Leave alone:            $(human_kb "$sum3")"

  check_full_disk_access
  if [ "$FDA_OK" = 0 ]; then
    say ""
    warn "Browser data is NOT in the numbers above — Full Disk Access is still"
    warn "not granted, so Chrome/Brave/Edge/Firefox read as 0 B. Granting it and"
    warn "re-running is likely worth another 10+ GB on this machine."
  fi
  return 0
}

# ---------------------------------------------------------------------------
# P6-T05: largest individual files (report only)
# ---------------------------------------------------------------------------
#
# Single files, not folders: the VM disk, the dataset, the .ipa, the video
# export. Sizes are allocated bytes (what deleting would free); a sparse file
# also shows what it claims to be. Nothing here is ever removed by mimi —
# a large file is as likely to be precious as forgotten.
report_large_files() {
  local min_mb="${1:-$REPORT_LARGE_FILE_MB}" f kb shown=0 total=0 extra
  say ""
  info "Largest individual files under \$HOME (${min_mb} MB and larger on disk; report only):"
  while IFS=$'\t' read -r kb f; do
    [ -n "$f" ] || continue
    shown=$((shown + 1))
    total=$((total + kb))
    extra=""
    if is_sparse_file "$f"; then
      extra="  (sparse file; claims $(human_kb "$(path_logical_kb "$f")"))"
    fi
    printf '  %10s  %s%s\n' "$(human_kb "$kb")" "$f" "$extra" | tee -a "$LOG_FILE"
  done < <(
    find "$HOME_DIR" -xdev -type f -size +"${min_mb}"M -print0 2>/dev/null \
      | while IFS= read -r -d '' f; do
          # Rank by what is on disk. An iCloud file evicted to the cloud, or a
          # sparse file that is mostly holes, can claim gigabytes and occupy
          # almost nothing; deleting it would free almost nothing.
          kb="$(du -k "$f" 2>/dev/null | awk '{print $1}')"
          [ "${kb:-0}" -ge $((min_mb * 1024)) ] || continue
          printf '%s\t%s\n' "$kb" "$f"
        done | sort -rn | head -"${REPORT_LARGE_FILE_LIMIT:-25}"
  )
  if [ "$shown" -eq 0 ]; then
    info "  (none)"
  else
    info "  $shown file(s), $(human_kb "$total") in total. mimi never removes these; check"
    info "  each one before deleting it yourself."
  fi
  return 0
}

# ---------------------------------------------------------------------------
# P6-T07: stale downloads (report only)
# ---------------------------------------------------------------------------
#
# "Stale" means not OPENED for N days. The signal is Spotlight's
# kMDItemLastUsedDate (updated when a file is opened); a file never opened
# falls back to kMDItemDateAdded (when it arrived in Downloads). Modification
# time is deliberately not used: copying, unzipping, or syncing rewrites it
# and says nothing about use. Items Spotlight has no dates for are counted
# but not judged.

# Epoch seconds of a Spotlight date attribute, or nothing when unset.
_md_date_epoch() {
  local p="$1" attr="$2" v
  command -v mdls > /dev/null 2>&1 || return 1
  v="$(mdls -raw -name "$attr" "$p" 2>/dev/null)" || return 1
  case "$v" in
    ''|'(null)') return 1 ;;
  esac
  date -j -f '%Y-%m-%d %H:%M:%S %z' "$v" +%s 2>/dev/null
}

report_stale_downloads() {
  local days="${1:-$DOWNLOADS_STALE_DAYS}" dir="$HOME_DIR/Downloads"
  [ -d "$dir" ] || return 0
  say ""
  info "Downloads not opened in ${days}+ days (report only):"

  local now cutoff e b last src kb unknown=0
  now="$(date +%s)"
  cutoff=$((now - days * 86400))
  local -a rows=()
  for e in "$dir"/* "$dir"/.[!.]*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    b="$(basename "$e")"
    case "$b" in .DS_Store|.localized) continue ;; esac
    src="last opened"
    last="$(_md_date_epoch "$e" kMDItemLastUsedDate || true)"
    if [ -z "$last" ]; then
      src="added, never opened"
      last="$(_md_date_epoch "$e" kMDItemDateAdded || true)"
    fi
    if [ -z "$last" ]; then
      unknown=$((unknown + 1))
      continue
    fi
    [ "$last" -lt "$cutoff" ] || continue
    kb="$(dir_size_kb "$e")"
    rows+=("$kb"$'\t'"$(date -r "$last" '+%Y-%m-%d')"$'\t'"$src"$'\t'"$e")
  done

  local total=0 n=0 line d s p
  if [ "${#rows[@]}" -gt 0 ]; then
    while IFS=$'\t' read -r kb d s p; do
      n=$((n + 1))
      total=$((total + kb))
      printf '  %10s  %s  (%s %s)\n' "$(human_kb "$kb")" "$p" "$s" "$d" | tee -a "$LOG_FILE"
    done < <(printf '%s\n' "${rows[@]}" | sort -rn)
  fi
  if [ "$n" -eq 0 ]; then
    info "  (none)"
  else
    info "  $n item(s), $(human_kb "$total") in total. mimi never removes downloads."
  fi
  if [ "$unknown" -gt 0 ]; then
    info "  $unknown item(s) have no Spotlight dates and were not judged."
  fi
  return 0
}

report_top_offenders() {
  section "Where your disk space actually is"
  check_full_disk_access
  [ "$FDA_OK" = 0 ] && warn "running without Full Disk Access — browser/mail sizes below will read as 0"

  local targets=(
    "$HOME_DIR/Library/Application Support"
    "$HOME_DIR/Library/Containers"
    "$HOME_DIR/Library/Caches"
    "$HOME_DIR/Library/Developer"
    "$HOME_DIR/Library/Android"
    "$HOME_DIR/Library/Group Containers"
    "$HOME_DIR/.cache"
    "$HOME_DIR/.gradle"
    "$HOME_DIR/.npm"
    "$HOME_DIR/.yarn"
    "$HOME_DIR/.pub-cache"
    "$HOME_DIR/.konan"
    "$HOME_DIR/.android"
    "$HOME_DIR/.docker"
    "$HOME_DIR/.lmstudio"
    "$HOME_DIR/.ollama"
    "$HOME_DIR/Downloads"
    "$HOME_DIR/Documents"
    "$HOME_DIR/Desktop"
    "$HOME_DIR/Movies"
    "$HOME_DIR/Music"
    "$HOME_DIR/Pictures"
    "$HOME_DIR/.Trash"
    "/Applications"
    "/opt/homebrew"
    "/usr/local"
    "/Library/Developer"
    "/private/var/folders"
  )

  info "Top directories by size — a full home-directory walk, expect a few minutes..."
  local t
  {
    for t in "${targets[@]}"; do
      [ -e "$t" ] || continue
      du -sxk "$t" 2>/dev/null | tail -1
    done
  } | sort -rn | head -20 | while IFS=$'\t' read -r kb path; do
    printf '  %10s  %s\n' "$(human_kb "$kb")" "$path" | tee -a "$LOG_FILE"
  done

  # Big single directories anywhere under home, which is how you find the
  # 12 GB node_modules / dataset / VM image you forgot about.
  say ""
  info "Largest individual folders under \$HOME (depth 4, >1 GB):"
  du -xk -d4 "$HOME_DIR" 2>/dev/null \
    | awk '$1 > 1048576' | sort -rn | head -25 \
    | while IFS=$'\t' read -r kb path; do
        printf '  %10s  %s\n' "$(human_kb "$kb")" "$path" | tee -a "$LOG_FILE"
      done

  # Stale node_modules — nothing deletes these for you and they are pure build
  # artefact that `npm install` regenerates.
  #
  # Only *project* node_modules count. A node_modules shipped inside an
  # installed VS Code / Claude / Copilot extension is part of that extension
  # and deleting it breaks the extension, so anything under a dot-directory,
  # ~/Library, or an extensions/ folder is filtered out. The parent must also
  # have a package.json, which is what makes `npm install` able to rebuild it.
  say ""
  info "Stale project node_modules (untouched 90+ days, rebuilt by \`npm install\`):"
  local nm_total=0 nm_kb nm parent
  while IFS= read -r nm; do
    [ -d "$nm" ] || continue
    case "$nm" in
      */.*/*|"$HOME_DIR/Library/"*|*/extensions/*|*/node_modules/*/node_modules) continue ;;
    esac
    parent="$(dirname "$nm")"
    [ -f "$parent/package.json" ] || continue
    nm_kb="$(du -sxk "$nm" 2>/dev/null | awk '{print $1}')"
    nm_total=$((nm_total + ${nm_kb:-0}))
    printf '%s\t%s\n' "${nm_kb:-0}" "$nm"
  done < <(find "$HOME_DIR" -maxdepth 7 -type d -name node_modules -mtime +90 -prune 2>/dev/null) \
    | sort -rn | head -25 \
    | while IFS=$'\t' read -r nm_kb nm; do
        printf '  %10s  %s\n' "$(human_kb "$nm_kb")" "$nm" | tee -a "$LOG_FILE"
      done
  info "Delete one with: rm -rf <path>   (then \`npm install\` when you next need it)"

  report_large_files
  report_stale_downloads

  # Purgeable space / snapshots: the other half of the "System Data" mystery.
  say ""
  info "Volume accounting:"
  df -h / /System/Volumes/Data 2>/dev/null | while IFS= read -r l; do printf '  %s\n' "$l" | tee -a "$LOG_FILE"; done
  local snaps
  snaps="$(tmutil listlocalsnapshots / 2>/dev/null | grep -c 'com.apple.TimeMachine' || true)"
  info "Local Time Machine snapshots: ${snaps:-0} (these count as 'System Data' and are purgeable)"
  say ""
  info "Note: 'System Data' in Settings > Storage is a leftover bucket, not a real folder."
  info "It is mostly the items above that Finder cannot categorise — VM disks, SDKs,"
  info "caches, snapshots and purgeable space. Clearing the categories in this script"
  info "and then rebooting is what makes the number move."
  return 0
}

