#!/usr/bin/env bats
#
# tests/profiles.bats — Profiles, defaults reclassification, and risk facets (P0-T09).
#

load 'test_helper'

# ---------------------------------------------------------------------------
# Default profile (safe) contents
# ---------------------------------------------------------------------------

@test "defaults: default scan does not run timemachine, device-support, homebrew-old, or broad caches/logs" {
  run_clean --scan --no-log
  [ "$status" -eq 0 ]
  # None of the consequential or broad sweep categories should run by default
  ! echo "$output" | grep -q "Local Time Machine snapshots"
  ! echo "$output" | grep -q "Xcode iOS DeviceSupport"
  ! echo "$output" | grep -q "Homebrew old versions"
  ! echo "$output" | grep -q "== User caches"
  ! echo "$output" | grep -q "== User logs"
}

@test "defaults: default scan runs safe developer and system caches" {
  run_clean --scan --no-log
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "npm cache"
  echo "$output" | grep -q "Yarn cache"
  echo "$output" | grep -q "pip cache"
  echo "$output" | grep -q "Homebrew download cache"
  echo "$output" | grep -q "QuickLook thumbnail cache"
  echo "$output" | grep -q "Diagnostic / crash reports"
}

# ---------------------------------------------------------------------------
# --profile options
# ---------------------------------------------------------------------------

@test "profile: --profile safe matches default behavior" {
  run_clean --scan --no-log --profile safe
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "npm cache"
  echo "$output" | grep -q "Homebrew download cache"
  ! echo "$output" | grep -q "Local Time Machine snapshots"
  ! echo "$output" | grep -q "== User caches"
}

@test "profile: --profile developer includes Xcode and dev build artifacts" {
  run_clean --scan --no-log --profile developer
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "npm cache"
  echo "$output" | grep -q "Xcode iOS DeviceSupport"
  echo "$output" | grep -q "Xcode Archives"
  ! echo "$output" | grep -q "Local Time Machine snapshots"
  ! echo "$output" | grep -q "== User caches"
}

@test "profile: --profile aggressive includes broad caches, logs, and Time Machine" {
  run_clean --scan --no-log --profile aggressive
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "User caches"
  echo "$output" | grep -q "User logs"
  echo "$output" | grep -q "Local Time Machine snapshots"
  echo "$output" | grep -q "Homebrew old versions"
}

@test "profile: --profile list prints available profiles and exits 0" {
  run_clean --profile list
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "safe"
  echo "$output" | grep -q "developer"
  echo "$output" | grep -q "aggressive"
}

@test "profile: --profile=list syntax works too" {
  run_clean --profile=list
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "safe"
}

@test "profile: unknown profile name exits 1 with usage error" {
  run_clean --profile nonexistent
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "unknown profile"
  echo "$output" | grep -q "safe, developer, aggressive"
}

@test "profile: missing profile argument exits 1 with usage error" {
  run_clean --profile
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "requires a value"
}

# ---------------------------------------------------------------------------
# Precedence rules
# ---------------------------------------------------------------------------

@test "precedence: --only overrides --profile" {
  run_clean --scan --no-log --profile aggressive --only pip
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "pip cache"
  ! echo "$output" | grep -q "== User caches"
  ! echo "$output" | grep -q "Local Time Machine snapshots"
}

@test "precedence: --skip excludes from --profile" {
  run_clean --scan --no-log --profile safe --skip npm
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "== npm cache"
  echo "$output" | grep -q "pip cache"
}

@test "precedence: --include-* adds category to active profile" {
  run_clean --scan --no-log --profile safe --include-timemachine
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "npm cache"
  echo "$output" | grep -q "Local Time Machine snapshots"
}

@test "precedence: config PROFILE is respected when no CLI profile is given" {
  write_config "PROFILE=developer"
  run_clean --scan --no-log
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Xcode iOS DeviceSupport"
}

@test "precedence: CLI --profile overrides config PROFILE" {
  write_config "PROFILE=developer"
  run_clean --scan --no-log --profile safe
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "Xcode iOS DeviceSupport"
}

# ---------------------------------------------------------------------------
# Opt-in flags for reclassified categories
# ---------------------------------------------------------------------------

@test "opt-in: --include-caches enables broad cache cleaning" {
  run_clean --scan --no-log --include-caches
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "User caches"
}

@test "opt-in: --include-logs enables broad log cleaning" {
  run_clean --scan --no-log --include-logs
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "User logs"
}

@test "opt-in: --include-timemachine enables Time Machine thinning" {
  run_clean --scan --no-log --include-timemachine
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Local Time Machine snapshots"
}

@test "opt-in: --include-device-support enables DeviceSupport pruning" {
  run_clean --scan --no-log --include-device-support
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Xcode iOS DeviceSupport"
}

@test "opt-in: --include-homebrew-old enables old version and autoremove cleanup" {
  run_clean --scan --no-log --include-homebrew-old
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Homebrew old versions and unused dependencies"
}

# ---------------------------------------------------------------------------
# Risk facets and risk table unification
# ---------------------------------------------------------------------------

@test "facets: every category defines four valid risk facets" {
  load_lib
  local id facets rec loss cost impact
  for id in $ALL_CATEGORY_IDS; do
    facets="$(category_risk_facets "$id")"
    rec="$(echo "$facets" | cut -d'|' -f1)"
    loss="$(echo "$facets" | cut -d'|' -f2)"
    cost="$(echo "$facets" | cut -d'|' -f3)"
    impact="$(echo "$facets" | cut -d'|' -f4)"

    [[ "$rec" =~ ^(auto|re-fetch|rebuild|manual|none)$ ]] || {
      echo "invalid recoverability for $id: $rec" >&2
      return 1
    }
    [[ "$loss" =~ ^(none|low|medium|high)$ ]] || {
      echo "invalid data_loss_risk for $id: $loss" >&2
      return 1
    }
    [[ "$cost" =~ ^(none|low|medium|high)$ ]] || {
      echo "invalid rebuild_cost for $id: $cost" >&2
      return 1
    }
    [[ "$impact" =~ ^(none|low|medium|high)$ ]] || {
      echo "invalid system_impact for $id: $impact" >&2
      return 1
    }
  done
}

@test "risk-table: confirm_class and category_info agree on irreversible categories" {
  load_lib
  local id risk cclass
  for id in trash ios-backups orphans; do
    risk="$(category_info "$id" | cut -d'|' -f1)"
    cclass="$(confirm_class "$id")"
    [ "$risk" = "irreversible" ]
    [ "$cclass" = "irreversible" ]
  done
}

@test "risk-table: confirm_class and category_info agree on risky categories" {
  load_lib
  local id risk cclass
  for id in docker mail sim-stale android; do
    risk="$(category_info "$id" | cut -d'|' -f1)"
    cclass="$(confirm_class "$id")"
    [ "$risk" = "risky" ]
    [ "$cclass" = "risky" ]
  done
}

# ---------------------------------------------------------------------------
# Golden test: snapshot of category table from --list
# ---------------------------------------------------------------------------

@test "golden: --list contains all 36 categories with expected risk and default status" {
  run_clean --list
  [ "$status" -eq 0 ]

  # All 36 categories must be present
  echo "$output" | grep -q "^browsers "
  echo "$output" | grep -q "^electron "
  echo "$output" | grep -q "^dev-caches "
  echo "$output" | grep -q "^caches "
  echo "$output" | grep -q "^tmp "
  echo "$output" | grep -q "^logs "
  echo "$output" | grep -q "^diagnostics "
  echo "$output" | grep -q "^dsstore "
  echo "$output" | grep -q "^quicklook "
  echo "$output" | grep -q "^xcode-derived "
  echo "$output" | grep -q "^xcode-archives "
  echo "$output" | grep -q "^sim-caches "
  echo "$output" | grep -q "^sim-unavailable "
  echo "$output" | grep -q "^device-support "
  echo "$output" | grep -q "^homebrew "
  echo "$output" | grep -q "^homebrew-old "
  echo "$output" | grep -q "^npm "
  echo "$output" | grep -q "^yarn "
  echo "$output" | grep -q "^pnpm "
  echo "$output" | grep -q "^cocoapods "
  echo "$output" | grep -q "^gradle "
  echo "$output" | grep -q "^pip "
  echo "$output" | grep -q "^timemachine "
  echo "$output" | grep -q "^docker "
  echo "$output" | grep -q "^docker-cache "
  echo "$output" | grep -q "^mail "
  echo "$output" | grep -q "^trash "
  echo "$output" | grep -q "^orphans "
  echo "$output" | grep -q "^whatsapp "
  echo "$output" | grep -q "^sim-stale "
  echo "$output" | grep -q "^claude-cache "
  echo "$output" | grep -q "^android "
  echo "$output" | grep -q "^ide-stale "
  echo "$output" | grep -q "^ml-caches "
  echo "$output" | grep -q "^ios-backups "
  echo "$output" | grep -q "^toolchains "

  # Verify reclassified defaults
  echo "$output" | grep "^timemachine " | grep -q "off"
  echo "$output" | grep "^device-support " | grep -q "off"
  echo "$output" | grep "^homebrew-old " | grep -q "off"
  echo "$output" | grep "^caches " | grep -q "off"
  echo "$output" | grep "^logs " | grep -q "off"

  # Verify safe default categories
  echo "$output" | grep "^npm " | grep -q "on"
  echo "$output" | grep "^homebrew " | grep -q "on"
  echo "$output" | grep "^quicklook " | grep -q "on"
}

# ---------------------------------------------------------------------------
# Registry integrity and lifecycle
# ---------------------------------------------------------------------------

@test "registry: no duplicate category IDs exist in ALL_CATEGORY_IDS" {
  load_lib
  local -a ids=($ALL_CATEGORY_IDS)
  local total="${#ids[@]}"
  local unique
  unique="$(printf '%s\n' "${ids[@]}" | sort -u | wc -l | tr -d ' ')"
  [ "$total" -eq "$unique" ]
  [ "$total" -eq 36 ]
}

@test "registry: every category has a defined and callable handler" {
  load_lib
  local id handler
  for id in $ALL_CATEGORY_IDS; do
    handler="$(category_handler "$id")"
    [ -n "$handler" ]
    declare -f "$handler" > /dev/null || {
      echo "Category $id has missing handler function: $handler" >&2
      return 1
    }
  done
}

@test "registry: capability checks return boolean status" {
  load_lib
  local id
  for id in $ALL_CATEGORY_IDS; do
    if category_capability "$id"; then
      true
    else
      [ "$?" -eq 1 ]
    fi
  done
}

@test "registry: unknown category returns empty info and unknown risk facets" {
  load_lib
  [ -z "$(category_info "nosuchcategory")" ]
  [ "$(category_risk_facets "nosuchcategory")" = "unknown|unknown|unknown|unknown" ]
  [ -z "$(category_handler "nosuchcategory")" ]
}
