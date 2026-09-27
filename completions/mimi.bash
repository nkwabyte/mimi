# bash completion for mimi                                  -*- shell-script -*-
#
# Installed by the Homebrew formula; from a source checkout, add to ~/.bashrc:
#   source /path/to/mimi/completions/mimi.bash
# Works with the stock macOS Bash 3.2 and with bash-completion 2.

_mimi_categories="browsers electron dev-caches caches tmp logs diagnostics dsstore quicklook xcode-derived xcode-archives sim-caches sim-unavailable device-support homebrew homebrew-old npm yarn pnpm cocoapods gradle pip timemachine docker docker-cache mail trash orphans whatsapp sim-stale claude-cache android ide-stale ml-caches ios-backups toolchains"
_mimi_options="--aggressive --android-stale-days --app-root --app-target --apply --cask --clean --cleaner --downloads-stale-days --force-risky --help --include-android --include-caches --include-claude-cache --include-device-support --include-docker --include-docker-cache --include-homebrew-old --include-ide-stale --include-ios-backups --include-logs --include-mail --include-ml-caches --include-orphans --include-sim-stale --include-timemachine --include-toolchains --include-trash --include-whatsapp --interactive --json --jsonl --keep-data --keep-device-support --keep-logs --keep-toolchains --large-file-mb --limit --list --no-color --no-log --no-prompt --only --plan --plan-only --plan-out --profile --purge --purge-data --remove-orphans --remove-orphans-from --report --request-id --restore --scan --sim-stale-days --skip --source --system --tmp-stale-days --vendor-uninstaller --verbose --version --whitelist --whitelist-preset --yes --zap"
_mimi_subcommands="scan clean plan apply restore purge history apps app"

_mimi_runs() {
  local d
  for d in "${HOME}/.config/mimi/quarantine"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    printf '%s\n' "${d##*/}"
  done
}

_mimi() {
  local cur prev
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  COMPREPLY=()

  case "$prev" in
    --only|--skip)
      # Comma-separated: complete the part after the last comma.
      local head="" last="$cur"
      case "$cur" in *,*) head="${cur%,*},"; last="${cur##*,}" ;; esac
      local c
      for c in $(compgen -W "$_mimi_categories" -- "$last"); do COMPREPLY+=("$head$c"); done
      return 0 ;;
    --profile) COMPREPLY=($(compgen -W "safe developer aggressive list" -- "$cur")); return 0 ;;
    --whitelist-preset) COMPREPLY=($(compgen -W "xcode-simulator xcode-derived node browsers ml" -- "$cur")); return 0 ;;
    --force-risky) COMPREPLY=($(compgen -W "docker mail trash orphans sim-stale android ios-backups app-terminate vendor-uninstaller" -- "$cur")); return 0 ;;
    --source) COMPREPLY=($(compgen -W "all app cask mas pkg system" -- "$cur")); return 0 ;;
    --app-root) COMPREPLY=($(compgen -d -- "$cur")); return 0 ;;
    apply|--apply|--remove-orphans-from|--plan-out|--whitelist) COMPREPLY=($(compgen -f -- "$cur")); return 0 ;;
    restore|--restore|purge|--purge) COMPREPLY=($(compgen -W "$(_mimi_runs)" -- "$cur")); return 0 ;;
    app) COMPREPLY=($(compgen -W "inspect uninstall list" -- "$cur")); return 0 ;;
    apps) COMPREPLY=($(compgen -W "list" -- "$cur")); return 0 ;;
    --keep-device-support|--sim-stale-days|--android-stale-days|--tmp-stale-days|--keep-toolchains|--keep-logs|--downloads-stale-days|--large-file-mb|--limit|--request-id)
      return 0 ;;
  esac

  if [ "$COMP_CWORD" -eq 1 ] && [ "${cur#-}" = "$cur" ]; then
    COMPREPLY=($(compgen -W "$_mimi_subcommands" -- "$cur"))
    return 0
  fi
  if [ "${cur#-}" != "$cur" ]; then
    COMPREPLY=($(compgen -W "$_mimi_options -h -V -i -v -y" -- "$cur"))
    return 0
  fi
  # app inspect|uninstall <target>: application bundles.
  COMPREPLY=($(compgen -f -- "$cur"))
}

complete -o default -F _mimi mimi
