#!/usr/bin/env bash
#
# lib/globals.sh — Global state: every variable the rest of the tool reads.
#
# Sourced by lib/load.sh; never executed on its own. Defines functions and
# global state only, so load order matters solely for the few assignments that
# interpolate $HOME_DIR (set in globals.sh, loaded first).

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------

# "--" so a $0 that begins with a dash cannot be read as a basename(1) option.
SCRIPT_NAME="$(basename -- "$0")"
HOME_DIR="$HOME"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$HOME_DIR/Library/Logs/cleanmymac"
# /dev/null until log_init() opens the real transcript. Anything printed before
# then — every usage error, for one — used to be appended to a path inside a
# directory that did not exist yet, so each one came with a raw shell
# redirection error on stderr underneath it.
LOG_FILE="/dev/null"

MODE="scan"        # scan (dry-run, default) | clean
ASSUME_YES=0
VERBOSE=0
AGGRESSIVE=0
KEEP_DEVICE_SUPPORT=3
KEEP_SIM_LOGS_DAYS=7

INCLUDE_TRASH=0
INCLUDE_MAIL=0
INCLUDE_DOCKER=0
INCLUDE_DOCKER_CACHE=0
INCLUDE_ORPHANS=0
INCLUDE_WHATSAPP=0
INCLUDE_SIM_STALE=0
INCLUDE_CLAUDE_CACHE=0
INCLUDE_ANDROID=0
INCLUDE_IDE_STALE=0
INCLUDE_ML_CACHES=0
INCLUDE_IOS_BACKUPS=0
INCLUDE_TOOLCHAINS=0
REPORT_ONLY=0
NO_LOG=0
KEEP_LOGS=5
TMP_STALE_DAYS=3
KEEP_TOOLCHAINS=1

SIM_STALE_DAYS=60
ANDROID_STALE_DAYS=60

CONFIG_DIR="$HOME_DIR/.config/cleanmymac"
CONFIG_FILE="$CONFIG_DIR/config.conf"
CONFIG_SELECTED_CATEGORIES=""
INTERACTIVE=0

INSTALLED_IDS_NORM=()
INSTALLED_NAMES_NORM=()
_INSTALLED_BUILT=0

# Whether the installed-application index can be trusted to be complete.
# It matters because this scan works by *absence*: an entry is a candidate
# because no installed app claimed it. If the index is incomplete, absence
# proves nothing, and every candidate has to be treated as a weak guess.
ORPHAN_INDEX_COMPLETE=1
ORPHAN_INDEX_NOTE=""
ORPHAN_SPOTLIGHT_APPS=0
ORPHAN_WALKED_APPS=0

# Application locations walked directly, as a backstop for Spotlight. Anything
# installed somewhere else is invisible to the walk, which is exactly why a
# disagreement between this and Spotlight is treated as an incomplete index
# rather than as proof that something was uninstalled.
ORPHAN_APP_WALK_ROOTS=(
  "/Applications"
  "/Applications/Utilities"
  "$HOME_DIR/Applications"
  "/System/Applications"
  "/System/Applications/Utilities"
)

# Plain-English shared/vendor folder names that must never be auto-flagged as
# orphans even if no exact app match is found (substring match, e.g. "Adobe"
# also denylists "Adobe Common" if that ever showed up).
ORPHAN_DENYLIST=(adobe google microsoft mozilla dropbox 1password icloud
  clouddocs syncservices mobilesync crashreporter addressbook callhistory
  knowledge identityservices fileprovider cloudkit)

# Bare (non "com.apple.") system daemon/service names macOS itself owns.
# Discovered by scanning ~/Library/Preferences on a real machine: plenty of
# OS-level services (pasteboard server, login window, printing, spotlight
# helpers...) keep prefs here with no reverse-DNS prefix at all, so the
# com.apple.* check alone does not catch them.
ORPHAN_SYSTEM_DENYLIST=(loginwindow pbs mbuseragent scopedbookmarkagent
  sharedfilelistd corespotlightd diagnostics_agent contextstoreagent
  tokenbucketratelimiter askpermissiond locationaccessstored mobilemeaccounts
  org.cups.printingprefs org.sparkle-project.sparkle.autoupdate jbdeviceservice)

# root path :: token-normalization kind :: naming policy, scanned for possible
# application leftovers. The policy describes how much the *location itself*
# tells us about who owns an entry — it is a statement about evidence, not a
# permission to delete. Nothing found by this scan is ever removed by it; see
# cat_orphans.
#
#   bundle-id-named      -> macOS itself names these entries by bundle id, so
#                           the name is strong evidence of ownership
#                           (Containers, WebKit, HTTPStorages, Cookies,
#                           Saved Application State)
#   bundle-id-if-dotted  -> the name is only bundle-id evidence when it
#                           actually looks like a reverse-DNS id (>=2 dots).
#                           Apps name their Application Support folder
#                           anything they like, so a bare word such as
#                           "Caches" or "Qt" carries almost no evidence
#   name-guess           -> the location is full of bare OS-service names
#                           (Preferences, ByHost, LaunchAgents, Application
#                           Scripts); a name match here is a guess
#
# Group Containers are deliberately excluded entirely: they are shared across
# every app from the same vendor/group, so attribution to a single app is not
# reliable at all.
ORPHAN_ROOTS=(
  "$HOME_DIR/Library/Application Support::plain::bundle-id-if-dotted"
  "$HOME_DIR/Library/Containers::plain::bundle-id-named"
  "$HOME_DIR/Library/Preferences::plist::name-guess"
  "$HOME_DIR/Library/Preferences/ByHost::plist-byhost::name-guess"
  "$HOME_DIR/Library/Saved Application State::savedstate::bundle-id-named"
  "$HOME_DIR/Library/WebKit::plain::bundle-id-named"
  "$HOME_DIR/Library/HTTPStorages::plain::bundle-id-named"
  "$HOME_DIR/Library/Cookies::binarycookies::bundle-id-named"
  "$HOME_DIR/Library/Application Scripts::plain::name-guess"
  "$HOME_DIR/Library/LaunchAgents::plist::name-guess"
)

REMOVE_ORPHANS_FILE=""

ONLY_LIST=""
SKIP_LIST=""
WHITELIST=()

TOTAL_BEFORE_KB=0
TOTAL_RECLAIMED_KB=0
RAN_ANY=0

# Colors (disabled if not a tty)
if [ -t 1 ]; then
  C_RESET="$(tput sgr0)"; C_BOLD="$(tput bold)"; C_DIM="$(tput dim)"
  C_RED="$(tput setaf 1)"; C_GREEN="$(tput setaf 2)"; C_YELLOW="$(tput setaf 3)"
  C_BLUE="$(tput setaf 4)"; C_CYAN="$(tput setaf 6)"
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi
