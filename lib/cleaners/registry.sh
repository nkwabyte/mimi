#!/usr/bin/env bash
#
# lib/cleaners/registry.sh lib/registry.sh — category registry, risk facets, and lifecycle definitions.
#

in_list() {
  # in_list "needle" "comma,separated,list"
  local needle="$1" list="$2" item
  [ -z "$list" ] && return 1
  IFS=',' read -r -a arr <<< "$list"
  for item in "${arr[@]}"; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

# Maps an opt-in category id to the global flag variable that gates it, so
# that passing --include-X is by itself enough to run it (see the ONLY_LIST
# fixup below) — add one line here for any new opt-in category.
category_include_var() {
  case "$1" in
    docker) printf '%s' "INCLUDE_DOCKER" ;;
    docker-cache) printf '%s' "INCLUDE_DOCKER_CACHE" ;;
    mail) printf '%s' "INCLUDE_MAIL" ;;
    trash) printf '%s' "INCLUDE_TRASH" ;;
    orphans) printf '%s' "INCLUDE_ORPHANS" ;;
    whatsapp) printf '%s' "INCLUDE_WHATSAPP" ;;
    sim-stale) printf '%s' "INCLUDE_SIM_STALE" ;;
    claude-cache) printf '%s' "INCLUDE_CLAUDE_CACHE" ;;
    android) printf '%s' "INCLUDE_ANDROID" ;;
    ide-stale) printf '%s' "INCLUDE_IDE_STALE" ;;
    ml-caches) printf '%s' "INCLUDE_ML_CACHES" ;;
    ios-backups) printf '%s' "INCLUDE_IOS_BACKUPS" ;;
    toolchains) printf '%s' "INCLUDE_TOOLCHAINS" ;;
    timemachine) printf '%s' "INCLUDE_TIMEMACHINE" ;;
    device-support) printf '%s' "INCLUDE_DEVICE_SUPPORT" ;;
    homebrew-old) printf '%s' "INCLUDE_HOMEBREW_OLD" ;;
    caches) printf '%s' "INCLUDE_CACHES" ;;
    logs) printf '%s' "INCLUDE_LOGS" ;;
    *) printf '%s' "" ;;
  esac
}

should_run_category() {
  local id="$1"
  # --skip always wins, even over an explicit --only or the default set.
  if [ -n "$SKIP_LIST" ] && in_list "$id" "$SKIP_LIST"; then
    return 1
  fi
  if [ -n "$ONLY_LIST" ]; then
    in_list "$id" "$ONLY_LIST" && return 0 || return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Category registry: id | risk | default-on | description
#   default-on only matters when --only/--profile is not used; --skip always wins.
#   Risk levels: safe | moderate | risky | irreversible
# ---------------------------------------------------------------------------

category_info() {
  case "$1" in
    caches)            echo "safe|0|User app caches (~/Library/Caches/*, opt-in)" ;;
    logs)              echo "safe|0|User log files (~/Library/Logs/*, opt-in)" ;;
    diagnostics)       echo "safe|1|Old crash/diagnostic reports" ;;
    dsstore)           echo "safe|1|.DS_Store files under home directory" ;;
    quicklook)         echo "safe|1|QuickLook thumbnail cache" ;;
    xcode-derived)     echo "safe|1|Xcode DerivedData (build artifacts, safe to delete)" ;;
    xcode-archives)    echo "moderate|0|Old Xcode .xcarchive builds (kept unless --aggressive)" ;;
    sim-caches)        echo "safe|1|iOS Simulator cache files" ;;
    sim-unavailable)   echo "safe|1|Deleted/unavailable iOS Simulator devices" ;;
    device-support)    echo "moderate|0|Old Xcode iOS DeviceSupport symbol sets (opt-in)" ;;
    homebrew)          echo "safe|1|Homebrew download cache (brew cleanup -s)" ;;
    homebrew-old)      echo "moderate|0|Old installed Homebrew versions and unused dependencies (opt-in)" ;;
    npm)               echo "safe|1|npm cache" ;;
    yarn)              echo "safe|1|Yarn cache" ;;
    pnpm)              echo "safe|1|pnpm store (prune unreferenced packages)" ;;
    cocoapods)         echo "safe|1|CocoaPods cache" ;;
    gradle)            echo "safe|1|Gradle caches (Android/Kotlin builds)" ;;
    pip)               echo "safe|1|pip download cache" ;;
    timemachine)       echo "moderate|0|Local Time Machine snapshots (thinned, not your backups, opt-in)" ;;
    docker)            echo "risky|0|Docker ALL unused images/containers/volumes -af --volumes (opt-in)" ;;
    docker-cache)      echo "safe|0|Docker dangling build cache + untagged images only, shrinks Docker.raw (opt-in)" ;;
    mail)              echo "risky|0|Mail.app local download cache (opt-in)" ;;
    trash)             echo "irreversible|0|Empty ~/.Trash (irreversible, opt-in)" ;;
    orphans)           echo "irreversible|0|Report unclaimed config/support/cache leftovers (opt-in, heuristic, never deletes)" ;;
    whatsapp)          echo "moderate|0|WhatsApp expired Status/Stories media cache, real chat media untouched (opt-in)" ;;
    sim-stale)         echo "risky|0|iOS Simulator devices unused for a long time (opt-in, keeps recently-booted ones)" ;;
    claude-cache)      echo "safe|0|Claude desktop app's browser-style cache dirs only (opt-in)" ;;
    android)           echo "risky|0|Unreferenced Android system images + long-unused AVDs (opt-in)" ;;
    browsers)          echo "safe|1|Chrome/Brave/Edge/Arc/Vivaldi/Opera/Firefox caches, every profile" ;;
    electron)          echo "safe|1|Electron app caches (Notion, Slack, VS Code, Postman...) incl. Partitions" ;;
    dev-caches)        echo "safe|1|Language/tool caches (uv, go, cargo, trivy, gh, JetBrains, SwiftPM...)" ;;
    ide-stale)         echo "moderate|0|Config/plugin folders of superseded JetBrains + Android Studio versions (opt-in)" ;;
    ml-caches)         echo "moderate|0|Hugging Face / torch model caches; reports Ollama + LM Studio (opt-in)" ;;
    ios-backups)       echo "irreversible|0|Local iPhone/iPad backups in MobileSync (opt-in, irreversible)" ;;
    tmp)               echo "safe|1|\$TMPDIR + per-user cache, entries older than --tmp-stale-days" ;;
    toolchains)        echo "moderate|0|Superseded Kotlin/Native, Gradle dists, Gradle JDKs, SDKMAN versions (opt-in)" ;;
    *) echo "" ;;
  esac
}

# ---------------------------------------------------------------------------
# Risk facets: recoverability | data_loss_risk | rebuild_cost | system_impact
#
#   recoverability: auto | re-fetch | rebuild | manual | none
#   data_loss_risk: none | low | medium | high
#   rebuild_cost:   none | low | medium | high
#   system_impact:  none | low | medium | high
# ---------------------------------------------------------------------------

category_risk_facets() {
  case "$1" in
    dsstore)          echo "auto|none|none|none" ;;
    diagnostics)      echo "none|low|none|none" ;;
    quicklook)        echo "auto|none|none|low" ;;
    tmp)              echo "auto|none|none|low" ;;
    browsers)         echo "re-fetch|none|low|none" ;;
    electron)         echo "re-fetch|none|low|none" ;;
    dev-caches)       echo "re-fetch|none|low|none" ;;
    caches)           echo "auto|none|low|none" ;;
    logs)             echo "auto|low|none|none" ;;
    xcode-derived)    echo "rebuild|none|medium|none" ;;
    sim-caches)       echo "auto|none|low|none" ;;
    sim-unavailable)  echo "auto|none|none|low" ;;
    homebrew)         echo "re-fetch|none|low|none" ;;
    homebrew-old)     echo "re-fetch|low|medium|medium" ;;
    npm)              echo "re-fetch|none|low|none" ;;
    yarn)             echo "re-fetch|none|low|none" ;;
    pnpm)             echo "re-fetch|none|low|none" ;;
    cocoapods)        echo "re-fetch|none|low|none" ;;
    gradle)           echo "re-fetch|none|low|none" ;;
    pip)              echo "re-fetch|none|low|none" ;;
    claude-cache)     echo "re-fetch|none|low|none" ;;
    docker-cache)     echo "rebuild|none|medium|low" ;;
    xcode-archives)   echo "manual|medium|high|none" ;;
    device-support)   echo "manual|none|high|low" ;;
    timemachine)      echo "manual|medium|high|high" ;;
    whatsapp)         echo "re-fetch|low|low|none" ;;
    ide-stale)        echo "manual|low|low|none" ;;
    ml-caches)        echo "re-fetch|low|medium|none" ;;
    toolchains)       echo "re-fetch|low|medium|none" ;;
    sim-stale)        echo "rebuild|medium|medium|low" ;;
    android)          echo "re-fetch|medium|medium|low" ;;
    docker)           echo "rebuild|medium|medium|high" ;;
    mail)             echo "re-fetch|medium|medium|none" ;;
    trash)            echo "none|high|none|none" ;;
    orphans)          echo "none|high|none|none" ;;
    ios-backups)      echo "none|high|high|none" ;;
    *) echo "unknown|unknown|unknown|unknown" ;;
  esac
}

# ---------------------------------------------------------------------------
# Category Lifecycle & Handler Mapping
# ---------------------------------------------------------------------------

category_handler() {
  case "$1" in
    browsers)        echo "cat_browsers" ;;
    electron)        echo "cat_electron" ;;
    dev-caches)      echo "cat_dev_caches" ;;
    caches)          echo "cat_caches" ;;
    tmp)             echo "cat_tmp" ;;
    logs)            echo "cat_logs" ;;
    diagnostics)     echo "cat_diagnostics" ;;
    dsstore)         echo "cat_dsstore" ;;
    quicklook)       echo "cat_quicklook" ;;
    xcode-derived)   echo "cat_xcode_derived" ;;
    xcode-archives)  echo "cat_xcode_archives" ;;
    sim-caches)      echo "cat_sim_caches" ;;
    sim-unavailable) echo "cat_sim_unavailable" ;;
    device-support)  echo "cat_device_support" ;;
    homebrew)        echo "cat_homebrew" ;;
    homebrew-old)    echo "cat_homebrew_old" ;;
    npm)             echo "cat_npm" ;;
    yarn)            echo "cat_yarn" ;;
    pnpm)            echo "cat_pnpm" ;;
    cocoapods)       echo "cat_cocoapods" ;;
    gradle)          echo "cat_gradle" ;;
    pip)             echo "cat_pip" ;;
    timemachine)     echo "cat_timemachine" ;;
    docker)          echo "cat_docker" ;;
    docker-cache)    echo "cat_docker_cache" ;;
    mail)            echo "cat_mail" ;;
    trash)           echo "cat_trash" ;;
    orphans)         echo "cat_orphans" ;;
    whatsapp)        echo "cat_whatsapp" ;;
    sim-stale)       echo "cat_sim_stale" ;;
    claude-cache)    echo "cat_claude_cache" ;;
    android)         echo "cat_android" ;;
    ide-stale)       echo "cat_ide_stale" ;;
    ml-caches)       echo "cat_ml_caches" ;;
    ios-backups)     echo "cat_ios_backups" ;;
    toolchains)      echo "cat_toolchains" ;;
    *) echo "" ;;
  esac
}

category_capability() {
  case "$1" in
    homebrew|homebrew-old) command -v brew >/dev/null 2>&1 ;;
    docker|docker-cache)   docker_daemon_ready ;;
    quicklook)             command -v qlmanage >/dev/null 2>&1 ;;
    timemachine)           command -v tmutil >/dev/null 2>&1 ;;
    *)                     return 0 ;;
  esac
}

print_profile_list() {
  printf '%-12s %s\n' "PROFILE" "CATEGORIES"
  printf '%-12s %s\n' "safe" "$(profile_category_list safe)"
  printf '%-12s %s\n' "developer" "$(profile_category_list developer)"
  printf '%-12s %s\n' "aggressive" "$(profile_category_list aggressive)"
}

ALL_CATEGORY_IDS="browsers electron dev-caches caches tmp logs diagnostics dsstore quicklook xcode-derived xcode-archives sim-caches sim-unavailable device-support homebrew homebrew-old npm yarn pnpm cocoapods gradle pip timemachine docker docker-cache mail trash orphans whatsapp sim-stale claude-cache android ide-stale ml-caches ios-backups toolchains"

# Live on/off state for the interactive menu, parallel arrays keyed by index
# (bash 3.2 has no associative arrays). Seeded from category_info() defaults,
# then CONFIG_SELECTED_CATEGORIES (from the config file) if present.
CATEGORY_STATE_IDS=()
CATEGORY_STATE_ON=()

sync_include_var() {
  local id="$1" val="$2" varname
  varname="$(category_include_var "$id")"
  # Most categories have no --include-* gate at all; that is the ordinary case
  # and must not be reported as a failure, or the caller's loop looks like it
  # died on the first default-on category.
  [ -n "$varname" ] && printf -v "$varname" '%s' "$val"
  return 0
}

build_category_state() {
  CATEGORY_STATE_IDS=()
  CATEGORY_STATE_ON=()
  local id info default
  for id in $ALL_CATEGORY_IDS; do
    info="$(category_info "$id")"
    default="$(printf '%s' "$info" | cut -d'|' -f2)"
    CATEGORY_STATE_IDS+=("$id")
    CATEGORY_STATE_ON+=("$default")
  done
  if [ -n "$CONFIG_SELECTED_CATEGORIES" ]; then
    local i
    for i in "${!CATEGORY_STATE_IDS[@]}"; do
      case ",$CONFIG_SELECTED_CATEGORIES," in
        *",${CATEGORY_STATE_IDS[$i]},"*) CATEGORY_STATE_ON[$i]=1 ;;
        *) CATEGORY_STATE_ON[$i]=0 ;;
      esac
    done
  fi
  local i
  for i in "${!CATEGORY_STATE_IDS[@]}"; do
    sync_include_var "${CATEGORY_STATE_IDS[$i]}" "${CATEGORY_STATE_ON[$i]}"
  done
}

category_state_index() {
  local i
  for i in "${!CATEGORY_STATE_IDS[@]}"; do
    if [ "${CATEGORY_STATE_IDS[$i]}" = "$1" ]; then
      printf '%s' "$i"
      return 0
    fi
  done
  return 1
}

toggle_category_state() {
  local idx
  idx="$(category_state_index "$1")" || return 1
  if [ "${CATEGORY_STATE_ON[$idx]}" = "1" ]; then
    CATEGORY_STATE_ON[$idx]=0
  else
    CATEGORY_STATE_ON[$idx]=1
  fi
  sync_include_var "$1" "${CATEGORY_STATE_ON[$idx]}"
}

only_list_from_category_state() {
  local joined="" i
  for i in "${!CATEGORY_STATE_IDS[@]}"; do
    [ "${CATEGORY_STATE_ON[$i]}" = "1" ] && joined="${joined:+$joined,}${CATEGORY_STATE_IDS[$i]}"
  done
  printf '%s' "$joined"
}

print_category_list() {
  printf '%-16s %-13s %-8s %s\n' "ID" "RISK" "DEFAULT" "DESCRIPTION"
  local id info_line risk default desc
  for id in $ALL_CATEGORY_IDS; do
    info_line="$(category_info "$id")"
    risk="$(echo "$info_line" | cut -d'|' -f1)"
    default="$(echo "$info_line" | cut -d'|' -f2)"
    desc="$(echo "$info_line" | cut -d'|' -f3)"
    [ "$default" = "1" ] && default="on" || default="off"
    printf '%-16s %-13s %-8s %s\n' "$id" "$risk" "$default" "$desc"
  done
}
