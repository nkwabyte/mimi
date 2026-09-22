#!/usr/bin/env bash
#
# install.sh — put `mimi` on your PATH.
#
#   ./install.sh                 # install
#   ./install.sh --prefix DIR    # install into a specific bin directory
#   ./install.sh --uninstall     # remove the link
#
# This creates a *symlink* rather than copying anything, so `git pull` in this
# checkout updates the installed command too. bin/mimi resolves lib/ by
# following its own symlink back here, which is why a link is enough.

set -uo pipefail

REPO_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" > /dev/null 2>&1 && pwd)"
SOURCE="$REPO_DIR/bin/mimi"
PREFIX=""
UNINSTALL=0

die() {
  printf 'install.sh: error: %s\n' "$*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)
      [ $# -ge 2 ] || die "--prefix requires a directory"
      PREFIX="$2"
      shift 2
      ;;
    --prefix=*)
      PREFIX="${1#*=}"
      shift
      ;;
    --uninstall)
      UNINSTALL=1
      shift
      ;;
    -h | --help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -f "$SOURCE" ] || die "bin/mimi not found in $REPO_DIR"

# Pick a target. /usr/local/bin and Homebrew's bin are already on PATH on a
# normal macOS setup; ~/.local/bin usually is not, which is why it is last and
# why the PATH check below exists at all.
if [ -z "$PREFIX" ]; then
  for candidate in /usr/local/bin /opt/homebrew/bin "$HOME/.local/bin"; do
    if [ -d "$candidate" ] && [ -w "$candidate" ]; then
      PREFIX="$candidate"
      break
    fi
  done
  [ -n "$PREFIX" ] || PREFIX="$HOME/.local/bin"
fi

TARGET="$PREFIX/mimi"

if [ "$UNINSTALL" = 1 ]; then
  if [ -L "$TARGET" ]; then
    rm -f "$TARGET" || die "could not remove $TARGET"
    printf 'removed %s\n' "$TARGET"
  elif [ -e "$TARGET" ]; then
    die "$TARGET is not a symlink this script created; remove it by hand"
  else
    printf 'nothing to remove at %s\n' "$TARGET"
  fi
  exit 0
fi

mkdir -p "$PREFIX" || die "could not create $PREFIX"
[ -w "$PREFIX" ] || die "$PREFIX is not writable (try: sudo ./install.sh --prefix $PREFIX)"

if [ -e "$TARGET" ] && [ ! -L "$TARGET" ]; then
  die "$TARGET already exists and is not a symlink; move it aside first"
fi

ln -sfn "$SOURCE" "$TARGET" || die "could not link $TARGET -> $SOURCE"
chmod +x "$SOURCE"
printf 'linked %s -> %s\n' "$TARGET" "$SOURCE"

# Being on PATH is the whole point, so say plainly when it is not.
case ":$PATH:" in
  *":$PREFIX:"*)
    printf '\n%s is on your PATH. Try:\n\n    mimi --help\n    mimi --cleaner\n\n' "$PREFIX"
    ;;
  *)
    printf '\n%s is NOT on your PATH yet. Add this to your shell profile:\n\n' "$PREFIX"
    case "${SHELL##*/}" in
      zsh) printf '    echo '\''export PATH="%s:$PATH"'\'' >> ~/.zshrc && exec zsh\n\n' "$PREFIX" ;;
      bash) printf '    echo '\''export PATH="%s:$PATH"'\'' >> ~/.bash_profile && exec bash -l\n\n' "$PREFIX" ;;
      *) printf '    export PATH="%s:$PATH"\n\n' "$PREFIX" ;;
    esac
    ;;
esac
