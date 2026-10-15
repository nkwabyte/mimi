#!/usr/bin/env bash
#
# lib/ui/health.sh — Live System Health & Resource Diagnostics.
#
# Sourced by lib/load.sh; never executed on its own.
# Provides system resource inspections (CPU, Memory, Swap, Disk, Battery, Security)
# formatted in Mole-inspired visual cards or machine-readable JSON.

_format_gb() {
  local bytes="${1:-0}"
  awk -v b="$bytes" 'BEGIN { printf "%.2f", b / (1024 * 1024 * 1024) }' 2>/dev/null || echo "0.00"
}

_format_disk_gb() {
  local bytes="${1:-0}"
  # macOS standard storage calculation uses decimal gigabytes (1 GB = 10^9 bytes)
  awk -v b="$bytes" 'BEGIN { printf "%.2f", b / (1000 * 1000 * 1000) }' 2>/dev/null || echo "0.00"
}

_format_mb() {
  local bytes="${1:-0}"
  awk -v b="$bytes" 'BEGIN { printf "%.1f", b / (1024 * 1024) }' 2>/dev/null || echo "0.0"
}

render_health_bar() {
  local pct="${1:-0}" width="${2:-16}"
  local fill empty filled_str="" empty_str="" i

  # Sanitize pct
  case "$pct" in
    ''|*[!0-9]*) pct=0 ;;
  esac
  [ "$pct" -gt 100 ] && pct=100
  [ "$pct" -lt 0 ] && pct=0

  fill=$(( (pct * width) / 100 ))
  empty=$(( width - fill ))

  for ((i = 0; i < fill; i++)); do filled_str="${filled_str}█"; done
  for ((i = 0; i < empty; i++)); do empty_str="${empty_str}░"; done

  local color="$C_GREEN"
  if [ "$pct" -ge 85 ]; then
    color="$C_RED"
  elif [ "$pct" -ge 70 ]; then
    color="$C_YELLOW"
  fi

  printf '%s[%s%s%s%s]%s' "$C_DIM" "$color" "$filled_str" "$C_DIM" "$empty_str" "$C_RESET"
}

collect_system_health() {
  # Hardware & OS
  HEALTH_OS_PROD="macOS"
  HEALTH_OS_BUILD=""
  if command -v sw_vers >/dev/null 2>&1; then
    HEALTH_OS_PROD="$(sw_vers -productVersion 2>/dev/null || echo "macOS")"
    HEALTH_OS_BUILD="$(sw_vers -buildVersion 2>/dev/null || echo "")"
  fi
  HEALTH_ARCH="$(uname -m 2>/dev/null || echo "arm64")"
  HEALTH_KERNEL="$(uname -r 2>/dev/null || echo "")"

  HEALTH_CPU_MODEL="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "")"
  if [ -z "$HEALTH_CPU_MODEL" ]; then
    if [ "$HEALTH_ARCH" = "arm64" ]; then
      HEALTH_CPU_MODEL="Apple Silicon"
    else
      HEALTH_CPU_MODEL="Intel"
    fi
  fi
  HEALTH_CPU_CORES="$(sysctl -n hw.ncpu 2>/dev/null || echo "1")"

  # Uptime & Load
  local boottime now
  boottime="$(sysctl -n kern.boottime 2>/dev/null | awk -F 'sec = |, usec' '{print $2}' || echo "")"
  now="$(date +%s 2>/dev/null || echo "0")"
  if [ -n "$boottime" ] && [ "$boottime" -gt 0 ] 2>/dev/null && [ "$now" -ge "$boottime" ] 2>/dev/null; then
    local diff=$(( now - boottime ))
    local days=$(( diff / 86400 ))
    local hours=$(( (diff % 86400) / 3600 ))
    local mins=$(( (diff % 3600) / 60 ))
    if [ "$days" -gt 0 ]; then
      HEALTH_UPTIME="${days}d ${hours}h ${mins}m"
    elif [ "$hours" -gt 0 ]; then
      HEALTH_UPTIME="${hours}h ${mins}m"
    else
      HEALTH_UPTIME="${mins}m"
    fi
  else
    HEALTH_UPTIME="$(uptime 2>/dev/null | sed 's/.*up \([^,]*\), .*/\1/' || echo "Unknown")"
  fi

  HEALTH_LOAD_AVG="$(uptime 2>/dev/null | sed 's/.*load averages*: //' || echo "0.00 0.00 0.00")"

  # Memory (vm_stat & sysctl)
  local total_mem_bytes page_size vm_out
  total_mem_bytes="$(sysctl -n hw.memsize 2>/dev/null || echo "0")"
  HEALTH_MEM_TOTAL_BYTES="$total_mem_bytes"
  HEALTH_MEM_TOTAL_GB="$(_format_gb "$total_mem_bytes")"

  vm_out="$(vm_stat 2>/dev/null || echo "")"
  page_size="$(printf '%s\n' "$vm_out" | sed -n 's/.*page size of \([0-9][0-9]*\) bytes.*/\1/p' | head -1)"
  case "$page_size" in
    ''|*[!0-9]*) page_size="$(sysctl -n hw.pagesize 2>/dev/null || echo "4096")" ;;
  esac
  case "$page_size" in
    ''|*[!0-9]*) page_size=4096 ;;
  esac

  local p_active p_wired p_comp p_free p_spec
  p_active="$(printf '%s\n' "$vm_out" | awk '/Pages active:/ {print $NF}' | tr -d '.\n' || echo "0")"
  p_wired="$(printf '%s\n' "$vm_out" | awk '/Pages wired down:/ {print $NF}' | tr -d '.\n' || echo "0")"
  p_comp="$(printf '%s\n' "$vm_out" | awk '/Pages occupied by compressor:/ {print $NF}' | tr -d '.\n' || echo "0")"
  p_free="$(printf '%s\n' "$vm_out" | awk '/Pages free:/ {print $NF}' | tr -d '.\n' || echo "0")"
  p_spec="$(printf '%s\n' "$vm_out" | awk '/Pages speculative:/ {print $NF}' | tr -d '.\n' || echo "0")"

  case "$p_active" in ''|*[!0-9]*) p_active=0 ;; esac
  case "$p_wired" in ''|*[!0-9]*) p_wired=0 ;; esac
  case "$p_comp" in ''|*[!0-9]*) p_comp=0 ;; esac
  case "$p_free" in ''|*[!0-9]*) p_free=0 ;; esac
  case "$p_spec" in ''|*[!0-9]*) p_spec=0 ;; esac

  local used_mem_bytes=$(( (p_active + p_wired + p_comp) * page_size ))
  HEALTH_MEM_USED_BYTES="$used_mem_bytes"
  HEALTH_MEM_USED_GB="$(_format_gb "$used_mem_bytes")"
  HEALTH_MEM_ACTIVE_GB="$(_format_gb "$(( p_active * page_size ))")"
  HEALTH_MEM_WIRED_GB="$(_format_gb "$(( p_wired * page_size ))")"
  HEALTH_MEM_COMP_GB="$(_format_gb "$(( p_comp * page_size ))")"
  HEALTH_MEM_FREE_GB="$(_format_gb "$(( (p_free + p_spec) * page_size ))")"

  if [ "$total_mem_bytes" -gt 0 ]; then
    HEALTH_MEM_PCT="$(awk -v u="$used_mem_bytes" -v t="$total_mem_bytes" 'BEGIN { printf "%d", (u / t) * 100 }' 2>/dev/null || echo "0")"
  else
    HEALTH_MEM_PCT=0
  fi

  # Swap
  local swap_out
  swap_out="$(sysctl -n vm.swapusage 2>/dev/null || echo "")"
  HEALTH_SWAP_TOTAL_MB="$(printf '%s\n' "$swap_out" | sed -n 's/.*total = \([0-9.]*\)M.*/\1/p' || echo "0")"
  HEALTH_SWAP_USED_MB="$(printf '%s\n' "$swap_out" | sed -n 's/.*used = \([0-9.]*\)M.*/\1/p' || echo "0")"
  [ -z "$HEALTH_SWAP_TOTAL_MB" ] && HEALTH_SWAP_TOTAL_MB="0"
  [ -z "$HEALTH_SWAP_USED_MB" ] && HEALTH_SWAP_USED_MB="0"
  HEALTH_SWAP_PCT="$(awk -v u="$HEALTH_SWAP_USED_MB" -v t="$HEALTH_SWAP_TOTAL_MB" 'BEGIN { if (t > 0) printf "%d", (u / t) * 100; else print 0 }' 2>/dev/null || echo "0")"

  # Disk Space
  # On modern macOS APFS, / is a read-only sealed system snapshot (~13 GB),
  # while user data, applications, and caches reside on /System/Volumes/Data.
  # Both share the APFS container. We inspect the Data volume to reflect
  # actual available container space and overall disk usage accurately.
  local df_line=""
  if [ -d "/System/Volumes/Data" ]; then
    df_line="$(df -k /System/Volumes/Data 2>/dev/null | tail -1)"
  fi
  if [ -z "$df_line" ] && [ -n "$HOME" ]; then
    df_line="$(df -k "$HOME" 2>/dev/null | tail -1)"
  fi
  if [ -z "$df_line" ]; then
    df_line="$(df -k / 2>/dev/null | tail -1)"
  fi

  local total_kb avail_kb used_kb pct_raw
  total_kb="$(printf '%s\n' "$df_line" | awk '{print $2}' || echo "0")"
  avail_kb="$(printf '%s\n' "$df_line" | awk '{print $4}' || echo "0")"
  case "$total_kb" in ''|*[!0-9]*) total_kb=0 ;; esac
  case "$avail_kb" in ''|*[!0-9]*) avail_kb=0 ;; esac

  if [ "$total_kb" -gt 0 ]; then
    if [ "$total_kb" -ge "$avail_kb" ]; then
      used_kb=$(( total_kb - avail_kb ))
    else
      used_kb="$(printf '%s\n' "$df_line" | awk '{print $3}' || echo "0")"
    fi
  else
    used_kb=0
  fi
  case "$used_kb" in ''|*[!0-9]*) used_kb=0 ;; esac

  local total_disk_bytes=$(( total_kb * 1024 ))
  local avail_disk_bytes=$(( avail_kb * 1024 ))
  local used_disk_bytes=$(( used_kb * 1024 ))

  HEALTH_DISK_TOTAL_GB="$(_format_disk_gb "$total_disk_bytes")"
  HEALTH_DISK_USED_GB="$(_format_disk_gb "$used_disk_bytes")"
  HEALTH_DISK_FREE_GB="$(_format_disk_gb "$avail_disk_bytes")"

  pct_raw="$(printf '%s\n' "$df_line" | awk '{print $5}' | tr -d '%' || echo "")"
  case "$pct_raw" in
    ''|*[!0-9]*)
      if [ "$total_kb" -gt 0 ]; then
        HEALTH_DISK_PCT="$(awk -v u="$used_kb" -v t="$total_kb" 'BEGIN { printf "%d", (u / t) * 100 }' 2>/dev/null || echo "0")"
      else
        HEALTH_DISK_PCT=0
      fi
      ;;
    *)
      HEALTH_DISK_PCT="$pct_raw"
      ;;
  esac

  # Battery / Power
  HEALTH_POWER_SOURCE="AC"
  HEALTH_BATT_PCT=""
  HEALTH_BATT_STATUS="Normal"
  local batt_out
  batt_out="$(pmset -g batt 2>/dev/null || echo "")"
  if printf '%s\n' "$batt_out" | grep -qi "Battery Power"; then
    HEALTH_POWER_SOURCE="Battery"
  fi
  HEALTH_BATT_PCT="$(printf '%s\n' "$batt_out" | grep -o '[0-9]\{1,3\}%' | head -1 | tr -d '%' || echo "")"

  # Security & Permissions
  if command -v csrutil >/dev/null 2>&1; then
    local raw_sip
    raw_sip="$(csrutil status 2>/dev/null | grep -o 'enabled\|disabled' || echo 'Unknown')"
    case "$raw_sip" in
      enabled)  HEALTH_SIP="Enabled" ;;
      disabled) HEALTH_SIP="Disabled" ;;
      *)        HEALTH_SIP="Unknown" ;;
    esac
  else
    HEALTH_SIP="Unknown"
  fi

  check_full_disk_access 2>/dev/null || true
  if [ "${FDA_OK:-0}" = 1 ]; then
    HEALTH_FDA="Granted"
  else
    HEALTH_FDA="Not Granted"
  fi
}

run_status() {
  collect_system_health

  if [ "${JSONL_ENABLED:-0}" = 1 ]; then
    printf '{"status":"ok","type":"system_health","timestamp":"%s","os":{"product":"%s","version":"%s","build":"%s","arch":"%s","kernel":"%s"},"hardware":{"cpu":"%s","cores":%s},"uptime":"%s","load_average":"%s","memory":{"total_gb":%s,"used_gb":%s,"free_gb":%s,"wired_gb":%s,"active_gb":%s,"compressed_gb":%s,"percent":%s},"swap":{"total_mb":%s,"used_mb":%s,"percent":%s},"disk":{"total_gb":%s,"used_gb":%s,"free_gb":%s,"percent":%s},"power":{"source":"%s","battery_percent":"%s"},"security":{"sip":"%s","full_disk_access":"%s"}}\n' \
      "$(json_now_iso 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")" \
      "$(json_escape "$HEALTH_OS_PROD")" \
      "$(json_escape "$HEALTH_OS_PROD")" \
      "$(json_escape "$HEALTH_OS_BUILD")" \
      "$(json_escape "$HEALTH_ARCH")" \
      "$(json_escape "$HEALTH_KERNEL")" \
      "$(json_escape "$HEALTH_CPU_MODEL")" \
      "${HEALTH_CPU_CORES:-1}" \
      "$(json_escape "$HEALTH_UPTIME")" \
      "$(json_escape "$HEALTH_LOAD_AVG")" \
      "${HEALTH_MEM_TOTAL_GB:-0}" \
      "${HEALTH_MEM_USED_GB:-0}" \
      "${HEALTH_MEM_FREE_GB:-0}" \
      "${HEALTH_MEM_WIRED_GB:-0}" \
      "${HEALTH_MEM_ACTIVE_GB:-0}" \
      "${HEALTH_MEM_COMP_GB:-0}" \
      "${HEALTH_MEM_PCT:-0}" \
      "${HEALTH_SWAP_TOTAL_MB:-0}" \
      "${HEALTH_SWAP_USED_MB:-0}" \
      "${HEALTH_SWAP_PCT:-0}" \
      "${HEALTH_DISK_TOTAL_GB:-0}" \
      "${HEALTH_DISK_USED_GB:-0}" \
      "${HEALTH_DISK_FREE_GB:-0}" \
      "${HEALTH_DISK_PCT:-0}" \
      "$(json_escape "$HEALTH_POWER_SOURCE")" \
      "$(json_escape "$HEALTH_BATT_PCT")" \
      "$(json_escape "$HEALTH_SIP")" \
      "$(json_escape "$HEALTH_FDA")"
    return 0
  fi

  local os_full="$HEALTH_OS_PROD"
  [ -n "$HEALTH_OS_BUILD" ] && os_full="$os_full ($HEALTH_OS_BUILD)"

  local mem_bar swap_bar disk_bar
  mem_bar="$(render_health_bar "$HEALTH_MEM_PCT" 16)"
  swap_bar="$(render_health_bar "$HEALTH_SWAP_PCT" 16)"
  disk_bar="$(render_health_bar "$HEALTH_DISK_PCT" 16)"

  local sip_colored fda_colored
  if [ "$HEALTH_SIP" = "Enabled" ]; then
    sip_colored="${C_GREEN}Enabled${C_RESET}"
  else
    sip_colored="${C_YELLOW}${HEALTH_SIP}${C_RESET}"
  fi

  if [ "$HEALTH_FDA" = "Granted" ]; then
    fda_colored="${C_GREEN}Granted${C_RESET}"
  else
    fda_colored="${C_YELLOW}Not Granted${C_RESET}"
  fi

  local power_str="$HEALTH_POWER_SOURCE"
  if [ -n "$HEALTH_BATT_PCT" ]; then
    power_str="$power_str (${HEALTH_BATT_PCT}%)"
  fi

  printf '\n'
  printf '%s┌─ System Health & Status ───────────────────────────────────────────┐%s\n' "$C_CYAN" "$C_RESET"
  printf '%s│%s                                                                    %s│%s\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
  printf '%s│%s  %sSystem:%s   %-56s %s│%s\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET" "$os_full • $HEALTH_ARCH" "$C_CYAN" "$C_RESET"
  printf '%s│%s  %sCPU:%s      %-56s %s│%s\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET" "$HEALTH_CPU_MODEL ($HEALTH_CPU_CORES cores)" "$C_CYAN" "$C_RESET"
  printf '%s│%s  %sUptime:%s   %-56s %s│%s\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET" "$HEALTH_UPTIME • Load: $HEALTH_LOAD_AVG" "$C_CYAN" "$C_RESET"
  printf '%s│%s  %sPower:%s    %-56s %s│%s\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET" "$power_str" "$C_CYAN" "$C_RESET"
  printf '%s│%s                                                                    %s│%s\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
  printf '%s│%s  %sMemory%s    %s  %3d%%   %6s GB / %-6s GB                 %s│%s\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET" "$mem_bar" "$HEALTH_MEM_PCT" "$HEALTH_MEM_USED_GB" "$HEALTH_MEM_TOTAL_GB" "$C_CYAN" "$C_RESET"
  printf '%s│%s            %sWired:%s %-6s GB  %sActive:%s %-6s GB  %sComp:%s %-6s GB   %s│%s\n' "$C_CYAN" "$C_RESET" "$C_DIM" "$C_RESET" "$HEALTH_MEM_WIRED_GB" "$C_DIM" "$C_RESET" "$HEALTH_MEM_ACTIVE_GB" "$C_DIM" "$C_RESET" "$HEALTH_MEM_COMP_GB" "$C_CYAN" "$C_RESET"
  printf '%s│%s                                                                    %s│%s\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
  printf '%s│%s  %sSwap%s      %s  %3d%%   %6s MB / %-6s MB                 %s│%s\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET" "$swap_bar" "$HEALTH_SWAP_PCT" "$HEALTH_SWAP_USED_MB" "$HEALTH_SWAP_TOTAL_MB" "$C_CYAN" "$C_RESET"
  printf '%s│%s                                                                    %s│%s\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
  printf '%s│%s  %sDisk%s      %s  %3d%%   %6s GB / %-6s GB (%s GB free)     %s│%s\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET" "$disk_bar" "$HEALTH_DISK_PCT" "$HEALTH_DISK_USED_GB" "$HEALTH_DISK_TOTAL_GB" "$HEALTH_DISK_FREE_GB" "$C_CYAN" "$C_RESET"
  printf '%s│%s                                                                    %s│%s\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
  printf '%s│%s  %sSecurity:%s SIP: %s • Full Disk Access: %s                  %s│%s\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET" "$sip_colored" "$fda_colored" "$C_CYAN" "$C_RESET"
  printf '%s└────────────────────────────────────────────────────────────────────┘%s\n' "$C_CYAN" "$C_RESET"
  printf '\n'
  return 0
}
