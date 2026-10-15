#!/usr/bin/env bash
#
# lib/ui/completion.sh — Shell completion installer and generator (Phase 12).
#
# Inspired by Mole's completion engine (mo completion). Generates and configures
# tab completions for zsh and bash, supporting automatic shell detection,
# idempotent profile updates, and dry-run preview.
#
# Sourced by lib/load.sh; never executed on its own.
# Compatible with macOS /bin/bash 3.2+.
#

# Resolve the completions directory inside mimi configuration
mimi_completions_dir() {
  printf '%s' "${CONFIG_DIR:-$HOME_DIR/.config/mimi}/completions"
}

# Find the bundled completion scripts directory
find_bundled_completions_dir() {
  local candidates=(
    "${MIMI_ROOT_DIR:-}/completions"
    "/usr/local/share/mimi/completions"
    "/opt/homebrew/share/mimi/completions"
  )
  local c
  for c in "${candidates[@]}"; do
    if [ -n "$c" ] && [ -d "$c" ]; then
      printf '%s' "$c"
      return 0
    fi
  done
  printf '%s' "${MIMI_ROOT_DIR:-}/completions"
}

# Emit raw completion script to stdout
emit_completion_script() {
  local target_shell="${1:-zsh}"
  local repo_comp_dir
  repo_comp_dir="$(find_bundled_completions_dir)"

  case "$target_shell" in
    zsh)
      if [ -f "$repo_comp_dir/_mimi" ]; then
        cat "$repo_comp_dir/_mimi"
        return 0
      fi
      ;;
    bash)
      if [ -f "$repo_comp_dir/mimi.bash" ]; then
        cat "$repo_comp_dir/mimi.bash"
        return 0
      fi
      ;;
  esac

  err "completion: script for shell '$target_shell' not found in $repo_comp_dir"
  return 1
}

# Detect user's current shell
detect_user_shell() {
  local s="${SHELL:-}"
  case "$s" in
    *zsh*)  printf 'zsh' ;;
    *bash*) printf 'bash' ;;
    *)      printf 'zsh' ;; # Default on modern macOS
  esac
}

# Determine default configuration file for a given shell
get_shell_config_file() {
  local target_shell="$1"
  case "$target_shell" in
    zsh)
      printf '%s' "$HOME_DIR/.zshrc"
      ;;
    bash)
      if [ -f "$HOME_DIR/.bash_profile" ]; then
        printf '%s' "$HOME_DIR/.bash_profile"
      else
        printf '%s' "$HOME_DIR/.bashrc"
      fi
      ;;
    *)
      printf '%s' "$HOME_DIR/.zshrc"
      ;;
  esac
}

# Install or update shell completion
install_shell_completion() {
  local target_shell="${1:-$(detect_user_shell)}"
  local is_dry=0
  [ "${DRY_RUN:-0}" = 1 ] && is_dry=1

  local config_file
  config_file="$(get_shell_config_file "$target_shell")"

  local comp_dir
  comp_dir="$(mimi_completions_dir)"

  local repo_comp_dir
  repo_comp_dir="$(find_bundled_completions_dir)"

  say "${C_BOLD}Mimi Shell Completion Setup${C_RESET}"
  say "Target Shell: ${C_CYAN}$target_shell${C_RESET}"
  say "Config File:  ${C_CYAN}$config_file${C_RESET}"
  say ""

  if [ "$is_dry" = 1 ]; then
    say "${C_GREEN}${ICON_SUCCESS} [DRY RUN] Would install completion files to: $comp_dir${C_RESET}"
    say "${C_GREEN}${ICON_SUCCESS} [DRY RUN] Would update $config_file with shell completion hook.${C_RESET}"
    return 0
  fi

  # Create completion directory
  mkdir -p "$comp_dir" 2>/dev/null || {
    err "Failed to create completions directory: $comp_dir"
    return 1
  }

  local completion_line=""
  if [ "$target_shell" = "zsh" ]; then
    if [ -f "$repo_comp_dir/_mimi" ]; then
      cp -f "$repo_comp_dir/_mimi" "$comp_dir/_mimi"
    fi
    # shellcheck disable=SC2016
    completion_line='fpath=('"$comp_dir"' $fpath); autoload -U compinit; compinit'
  else
    if [ -f "$repo_comp_dir/mimi.bash" ]; then
      cp -f "$repo_comp_dir/mimi.bash" "$comp_dir/mimi.bash"
    fi
    completion_line='[ -f "'"$comp_dir/mimi.bash"'" ] && source "'"$comp_dir/mimi.bash"'"'
  fi

  # Ensure config file exists
  if [ ! -f "$config_file" ]; then
    mkdir -p "${config_file%/*}" 2>/dev/null || true
    touch "$config_file" 2>/dev/null || true
  fi

  # Remove existing mimi completion lines to prevent duplicates
  local temp_file
  temp_file="$(mktemp 2>/dev/null || echo "/tmp/mimi-comp.$$.tmp")"
  if [ -f "$config_file" ]; then
    grep -Ev "(# Mimi shell completion|mimi/completions)" "$config_file" > "$temp_file" 2>/dev/null || true
    mv -f "$temp_file" "$config_file"
  fi

  # Append hook
  {
    printf '\n# Mimi shell completion\n'
    printf '%s\n' "$completion_line"
  } >> "$config_file"

  say "${C_GREEN}${ICON_SUCCESS} Successfully configured $target_shell completion in $config_file${C_RESET}"
  say ""
  say "${C_DIM}To activate immediately in your current terminal session:${C_RESET}"
  say "  ${C_CYAN}source $config_file${C_RESET}"
  return 0
}

# Top-level subcommand runner
run_completion() {
  local action="${1:-}"
  local target="${2:-}"

  case "$action" in
    zsh)
      emit_completion_script zsh
      return $?
      ;;
    bash)
      emit_completion_script bash
      return $?
      ;;
    install|setup)
      local sh="${target:-$(detect_user_shell)}"
      install_shell_completion "$sh"
      return $?
      ;;
    "")
      install_shell_completion "$(detect_user_shell)"
      return $?
      ;;
    *)
      die_usage "unknown completion action: $action (valid: install, zsh, bash)"
      ;;
  esac
}
