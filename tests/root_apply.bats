#!/usr/bin/env bats
#
# root_apply.bats — libexec/mimi-root-apply (P5-T04/T05, option B).
#
# Runs in the tool's test mode: not root, MIMI_ROOT_PREFIX points at a fake
# root inside the fixture, the current user stands in for root in ownership
# checks, and the typed confirmation is read from stdin. launchctl and
# pkgutil are the mocks. Nothing outside the fixture is read or changed.

load 'test_helper'

TOOL="$REPO_ROOT/libexec/mimi-root-apply"

setup_root() {
  R="$TEST_TMPDIR/root"
  mkdir -p "$R/Library/LaunchDaemons" "$R/Library/LaunchAgents" "$R/Library/PrivilegedHelperTools"
  export MIMI_ROOT_TEST=1 MIMI_ROOT_PREFIX="$R"
  export MOCK_CALL_LOG="$TEST_TMPDIR/calls"
  REQ="$TEST_TMPDIR/req"
}

# daemon NAME LABEL PROGRAM [ASSOCIATED_ID...]
daemon() {
  local name="$1" label="$2" prog="$3" assoc="" a
  shift 3
  if [ "$#" -gt 0 ]; then
    assoc="<key>AssociatedBundleIdentifiers</key><array>"
    for a in "$@"; do assoc="$assoc<string>$a</string>"; done
    assoc="$assoc</array>"
  fi
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>Label</key><string>%s</string><key>ProgramArguments</key><array><string>%s</string></array>%s</dict></plist>\n' \
    "$label" "$prog" "$assoc" > "$R/Library/LaunchDaemons/$name.plist"
}

helper() { printf '#!/bin/sh\n' > "$R/Library/PrivilegedHelperTools/$1"; chmod 0755 "$R/Library/PrivilegedHelperTools/$1"; }

acme() {
  daemon com.acme.app.helper com.acme.app.helper "$R/Library/PrivilegedHelperTools/com.acme.app.helper"
  helper com.acme.app.helper
}

candidates() { "$TOOL" --candidates "$1" --tsv; }

# request BUNDLE_ID [ids...] — ids default to every current candidate.
request() {
  local bid="$1" id
  shift
  {
    printf 'mimi-root-request v1\nbundle_id=%s\n' "$bid"
    if [ "$#" -gt 0 ]; then
      for id in "$@"; do printf 'select=%s\n' "$id"; done
    else
      candidates "$bid" | awk -F'\t' '$1 ~ /^sys-/ { print "select=" $1 }'
    fi
  } > "$REQ"
  chmod 0600 "$REQ"
}

apply() { run /bin/bash -c 'printf "%s\n" "$1" | "$2" "$3"' _ "$1" "$TOOL" "$REQ"; }

@test "root: a name-matched daemon that runs a matching helper is attributable, with its helper" {
  setup_root; acme
  run candidates com.acme.app
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | awk -F'\t' '$1 ~ /^sys-/ {print $2 ":" $3}' | sort | tr '\n' ' ')" = \
    "daemon:$R/Library/LaunchDaemons/com.acme.app.helper.plist helper:$R/Library/PrivilegedHelperTools/com.acme.app.helper " ]
}

@test "root: AssociatedBundleIdentifiers is an owner signal (Docker-style names)" {
  setup_root
  daemon com.acme.socket com.acme.socket "$R/Library/PrivilegedHelperTools/com.acme.socket" com.acme.app
  helper com.acme.socket
  run candidates com.acme.app
  echo "$output" | grep -q "^sys-.*	daemon	$R/Library/LaunchDaemons/com.acme.socket.plist"
  echo "$output" | grep -q "^sys-.*	helper	$R/Library/PrivilegedHelperTools/com.acme.socket"
}

@test "root: one signal alone, a Label mismatch, a symlink, or several owners are never selectable" {
  setup_root
  # Name only: runs something unrelated.
  daemon com.acme.app.lonely com.acme.app.lonely /usr/libexec/something
  # Label differs from the file name.
  daemon com.acme.app.mislabel com.other.label "$R/Library/PrivilegedHelperTools/com.acme.app.mislabel"
  helper com.acme.app.mislabel
  # Symlinked plist.
  printf 'x\n' > "$TEST_TMPDIR/elsewhere.plist"
  ln -s "$TEST_TMPDIR/elsewhere.plist" "$R/Library/LaunchDaemons/com.acme.app.link.plist"
  # Associated with another app too.
  daemon com.acme.shared com.acme.shared "$R/Library/PrivilegedHelperTools/com.acme.shared" com.acme.app com.acme.other
  helper com.acme.shared
  # Same vendor, no owner signal.
  daemon com.acme.vmnet com.acme.vmnet "$R/Library/PrivilegedHelperTools/com.acme.vmnet"

  run candidates com.acme.app
  [ "$(echo "$output" | grep -c '^sys-')" = 0 ]
  echo "$output" | grep -q "near	-	$R/Library/LaunchDaemons/com.acme.app.lonely.plist	-	only one signal"
  echo "$output" | grep -q "com.acme.app.mislabel.plist	-	Label"
  echo "$output" | grep -q "com.acme.app.link.plist	-	not a regular file"
  echo "$output" | grep -q "com.acme.shared.plist	-	also associated with other apps"
  echo "$output" | grep -q "com.acme.vmnet.plist	-	same vendor"
}

@test "root: an item several installed packages own is never selectable" {
  setup_root; acme
  printf '%s|com.acme.pkg.one\n%s|com.acme.pkg.two\n' \
    "$R/Library/LaunchDaemons/com.acme.app.helper.plist" "$R/Library/LaunchDaemons/com.acme.app.helper.plist" > "$TEST_TMPDIR/pkgs"
  export MOCK_PKG_INDEX="$TEST_TMPDIR/pkgs"
  run candidates com.acme.app
  echo "$output" | grep -q "owned by several packages: com.acme.pkg.one,com.acme.pkg.two"
  ! echo "$output" | grep -q "^sys-.*	daemon"
}

@test "root: Apple and malformed bundle ids are refused" {
  setup_root
  run "$TOOL" --candidates com.apple.Safari
  [ "$status" -ne 0 ]
  run "$TOOL" --candidates '../../etc'
  [ "$status" -ne 0 ]
  run "$TOOL" --candidates 'nodots'
  [ "$status" -ne 0 ]
}

@test "root: apply stops the job, quarantines daemon then helper, and records a manifest" {
  setup_root; acme
  request com.acme.app
  apply com.acme.app
  [ "$status" -eq 0 ]
  [ ! -e "$R/Library/LaunchDaemons/com.acme.app.helper.plist" ]
  [ ! -e "$R/Library/PrivilegedHelperTools/com.acme.app.helper" ]
  grep -q "launchctl bootout system/com.acme.app.helper" "$MOCK_CALL_LOG"
  local run_dir
  run_dir="$(ls -d "$R/Library/Application Support/mimi/quarantine"/sys-*)"
  [ "$(stat -f '%Lp' "$run_dir")" = "700" ]
  [ "$(wc -l < "$run_dir/manifest.tsv" | tr -d ' ')" = 2 ]
  [ "$(head -1 "$run_dir/manifest.tsv" | cut -f1)" = daemon ]
}

@test "root: a wrong typed confirmation changes nothing" {
  setup_root; acme
  request com.acme.app
  apply yes
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "not confirmed"
  [ -f "$R/Library/LaunchDaemons/com.acme.app.helper.plist" ]
}

@test "root: a forged selection makes the whole request fail" {
  setup_root; acme
  local good
  good="$(candidates com.acme.app | awk -F'\t' '$1 ~ /^sys-/ {print $1; exit}')"
  request com.acme.app "$good" sys-0000000000000000
  apply com.acme.app
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "does not match anything attributable"
  [ -f "$R/Library/LaunchDaemons/com.acme.app.helper.plist" ]
}

@test "root: a request cannot reach a path, even one inside the scanned folders" {
  setup_root; acme
  { printf 'mimi-root-request v1\nbundle_id=com.acme.app\nselect=/etc/passwd\n'; } > "$REQ"
  chmod 0600 "$REQ"
  apply com.acme.app
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "malformed selection"
}

@test "root: a file replaced after the request no longer matches" {
  setup_root; acme
  request com.acme.app
  rm "$R/Library/PrivilegedHelperTools/com.acme.app.helper"
  helper com.acme.app.helper
  apply com.acme.app
  [ "$status" -ne 0 ]
  [ -f "$R/Library/LaunchDaemons/com.acme.app.helper.plist" ]
}

@test "root: requests that are writable by others, stale, or not mimi's are refused" {
  setup_root; acme
  request com.acme.app
  chmod 0666 "$REQ"
  apply com.acme.app
  [ "$status" -ne 0 ]; echo "$output" | grep -q "writable by others"

  request com.acme.app
  touch -t 202001010000 "$REQ"
  apply com.acme.app
  [ "$status" -ne 0 ]; echo "$output" | grep -q "older than"

  printf 'hello\nbundle_id=com.acme.app\n' > "$REQ"; chmod 0600 "$REQ"
  apply com.acme.app
  [ "$status" -ne 0 ]; echo "$output" | grep -q "not a mimi request"
  [ -f "$R/Library/LaunchDaemons/com.acme.app.helper.plist" ]
}

@test "root: restore puts everything back, is safe to repeat, and never overwrites" {
  setup_root; acme
  request com.acme.app
  apply com.acme.app
  local run_id
  run_id="$(basename "$(ls -d "$R/Library/Application Support/mimi/quarantine"/sys-*)")"

  run "$TOOL" --restore "$run_id"
  [ "$status" -eq 0 ]
  [ -f "$R/Library/LaunchDaemons/com.acme.app.helper.plist" ]
  [ -f "$R/Library/PrivilegedHelperTools/com.acme.app.helper" ]
  echo "$output" | grep -q "launchctl bootstrap system"

  run "$TOOL" --restore "$run_id"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "already restored"
}

@test "root: restore refuses an occupied path and keeps the quarantined copy" {
  setup_root; acme
  request com.acme.app
  apply com.acme.app
  local run_id
  run_id="$(basename "$(ls -d "$R/Library/Application Support/mimi/quarantine"/sys-*)")"
  helper com.acme.app.helper   # reinstalled
  run "$TOOL" --restore "$run_id"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "something already exists"
  ls "$R/Library/Application Support/mimi/quarantine/$run_id" | grep -q "com.acme.app.helper__"
}

@test "root: purge needs its own typed word, and run ids cannot escape the quarantine" {
  setup_root; acme
  request com.acme.app
  apply com.acme.app
  local run_id
  run_id="$(basename "$(ls -d "$R/Library/Application Support/mimi/quarantine"/sys-*)")"

  run /bin/bash -c 'printf "yes\n" | "$1" --purge "$2"' _ "$TOOL" "$run_id"
  [ "$status" -ne 0 ]
  [ -d "$R/Library/Application Support/mimi/quarantine/$run_id" ]

  run "$TOOL" --purge "../../../etc"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "not a run id"

  run /bin/bash -c 'printf "purge\n" | "$1" --purge "$2"' _ "$TOOL" "$run_id"
  [ "$status" -eq 0 ]
  [ ! -e "$R/Library/Application Support/mimi/quarantine/$run_id" ]
}

@test "root: without test mode and without root it refuses to apply" {
  setup_root; acme
  request com.acme.app
  run env -u MIMI_ROOT_TEST "$TOOL" "$REQ"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "needs root"
}

# ---------------------------------------------------------------------------
# mimi app uninstall --system (writes the request; never runs as root)
# ---------------------------------------------------------------------------

@test "mimi: --system writes a 0600 request selecting every candidate and does not sudo the bundled tool" {
  setup_root; acme
  run /bin/bash "$MIMI_BIN" app uninstall com.acme.app --system
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "No sudo command was printed"
  echo "$output" | grep -q "sudo \".*libexec/mimi-root-apply\" --install"
  # The request path must not appear on a sudo line.
  ! echo "$output" | grep -q "sudo \".*\" \".*system-requests/.*\.request\""
  local req
  req="$(ls "$FAKE_HOME/.config/mimi/system-requests"/*.request)"
  [ "$(stat -f '%Lp' "$req")" = 600 ]
  [ "$(head -1 "$req")" = "mimi-root-request v1" ]
  grep -q '^bundle_id=com.acme.app$' "$req"
  [ "$(grep -c '^select=sys-' "$req")" = 2 ]
  # Nothing was touched by mimi itself.
  [ -f "$R/Library/LaunchDaemons/com.acme.app.helper.plist" ]
  ! grep -q "sudo" "$MOCK_CALL_LOG" 2>/dev/null

  # The request is exactly what the root tool accepts.
  cp "$req" "$REQ"
  apply com.acme.app
  [ "$status" -eq 0 ]
  [ ! -e "$R/Library/LaunchDaemons/com.acme.app.helper.plist" ]
}

@test "mimi: --system with nothing attributable writes no request" {
  setup_root
  run /bin/bash "$MIMI_BIN" app uninstall com.nothing.here --system
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "no request written"
  [ ! -d "$FAKE_HOME/.config/mimi/system-requests" ] || [ -z "$(ls "$FAKE_HOME/.config/mimi/system-requests")" ]
}

# ---------------------------------------------------------------------------
# Package payload (P5-T05 slice 2) and receipts at purge time
# ---------------------------------------------------------------------------

# receipt ID LOCATION FILE... (paths relative to the fake root's LOCATION)
receipt() {
  local id="$1" loc="$2" f
  shift 2
  export MOCK_PKG_DIR="$TEST_TMPDIR/receipts"
  mkdir -p "$MOCK_PKG_DIR"
  printf 'volume: /\nlocation: %s\n' "$loc" > "$MOCK_PKG_DIR/$id.info"
  : > "$MOCK_PKG_DIR/$id.files"
  for f in "$@"; do printf '%s\n' "$f" >> "$MOCK_PKG_DIR/$id.files"; done
}

# A package-installed Acme app with its own support folder, a file shared
# with a sibling package, and a tool outside the allowed roots.
acme_pkg() {
  mkdir -p "$R/Applications/Acme.app/Contents" "$R/Library/Application Support/Acme/Core" \
           "$R/Library/Application Support/Acme/Shared" "$R/usr/bin"
  printf '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.acme.app</string></dict></plist>\n' \
    > "$R/Applications/Acme.app/Contents/Info.plist"
  printf 'x\n' > "$R/Library/Application Support/Acme/Core/lib.dylib"
  printf 'x\n' > "$R/Library/Application Support/Acme/Shared/license.dat"
  printf 'x\n' > "$R/usr/bin/acmectl"
  receipt com.acme.installer "" \
    "Applications/Acme.app" "Applications/Acme.app/Contents/Info.plist" \
    "Library/Application Support/Acme/Core/lib.dylib" \
    "Library/Application Support/Acme/Shared/license.dat" \
    "usr/bin/acmectl"
  receipt com.acme.extras "" "Library/Application Support/Acme/Shared/license.dat"
}

@test "payload: exclusive items of the app's package are selectable; shared and forbidden ones are not" {
  setup_root; acme_pkg
  run candidates com.acme.app
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | awk -F'\t' '$2 == "payload" {print $3}' | sort | tr '\n' '|')" = \
    "$R/Applications/Acme.app|$R/Library/Application Support/Acme/Core|" ]
  echo "$output" | grep -q "near	-	$R/Library/Application Support/Acme/Shared/license.dat	-	also installed by: com.acme.extras"
  echo "$output" | grep -q "near	-	$R/usr/bin/acmectl	-	outside the roots mimi may change"
}

@test "payload: a package whose app is gone is still attributed by its package id" {
  setup_root
  mkdir -p "$R/Library/Application Support/Gone"
  receipt com.gone.app.pkg "" "Library/Application Support/Gone/data"
  printf 'x\n' > "$R/Library/Application Support/Gone/data"
  run candidates com.gone.app
  echo "$output" | grep -q "	payload	$R/Library/Application Support/Gone	com.gone.app.pkg	"
}

@test "payload: another app's package is never attributed" {
  setup_root; acme_pkg
  run candidates com.other.app
  ! echo "$output" | grep -q "	payload	"
}

@test "payload: a launchd plist in a package still needs the two-signal rule" {
  setup_root
  daemon com.acme.app.lonely com.acme.app.lonely /usr/libexec/unrelated
  receipt com.acme.app.pkg "" "Library/LaunchDaemons/com.acme.app.lonely.plist"
  run candidates com.acme.app
  ! echo "$output" | grep -q "^sys-"
}

@test "payload: apply moves exclusive payload after the jobs; purge forgets the receipt only when all of it is gone" {
  setup_root; acme; acme_pkg
  export MOCK_PKG_ALLOW_FORGET=1
  request com.acme.app
  apply com.acme.app
  [ "$status" -eq 0 ]
  [ ! -e "$R/Applications/Acme.app" ]
  [ ! -e "$R/Library/Application Support/Acme/Core" ]
  [ -f "$R/Library/Application Support/Acme/Shared/license.dat" ]
  local run_dir run_id
  run_dir="$(ls -d "$R/Library/Application Support/mimi/quarantine"/sys-*)"
  run_id="$(basename "$run_dir")"
  [ "$(tail -1 "$run_dir/manifest.tsv" | cut -f1)" = payload ]
  grep -q "^pkg	com.acme.installer$" "$run_dir/info.tsv"

  # The shared license file and acmectl are still installed: receipt kept.
  run /bin/bash -c 'printf "purge\n" | "$1" --purge "$2"' _ "$TOOL" "$run_id"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "kept receipt com.acme.installer: 2 of its items are still installed"
  [ -f "$MOCK_PKG_DIR/com.acme.installer.files" ]
}

@test "payload: purge forgets a receipt whose every item is gone" {
  setup_root
  mkdir -p "$R/Library/Application Support/Solo"
  printf 'x\n' > "$R/Library/Application Support/Solo/data"
  receipt com.solo.app "" "Library/Application Support/Solo/data"
  export MOCK_PKG_ALLOW_FORGET=1
  request com.solo.app
  apply com.solo.app
  [ "$status" -eq 0 ]
  local run_id
  run_id="$(basename "$(ls -d "$R/Library/Application Support/mimi/quarantine"/sys-*)")"
  # Not forgotten while the files are only in quarantine.
  [ -f "$MOCK_PKG_DIR/com.solo.app.files" ]
  run /bin/bash -c 'printf "purge\n" | "$1" --purge "$2"' _ "$TOOL" "$run_id"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "forgot receipt com.solo.app"
  [ ! -e "$MOCK_PKG_DIR/com.solo.app.files" ]
}

@test "payload: restore brings a payload directory back" {
  setup_root; acme_pkg
  request com.acme.app
  apply com.acme.app
  local run_id
  run_id="$(basename "$(ls -d "$R/Library/Application Support/mimi/quarantine"/sys-*)")"
  run "$TOOL" --restore "$run_id"
  [ "$status" -eq 0 ]
  [ -f "$R/Applications/Acme.app/Contents/Info.plist" ]
  [ -f "$R/Library/Application Support/Acme/Core/lib.dylib" ]
}

# ---------------------------------------------------------------------------
# The hardened (root-owned) copy
# ---------------------------------------------------------------------------

@test "hardened copy: --install puts an identical copy in place and --uninstall-tool removes it" {
  setup_root
  run "$TOOL" --install
  [ "$status" -eq 0 ]
  local h="$R/usr/local/libexec/mimi/mimi-root-apply"
  cmp -s "$TOOL" "$h"
  [ "$(stat -f '%Lp' "$h")" = 755 ]

  run "$TOOL" --uninstall-tool
  [ "$status" -eq 0 ]
  [ ! -e "$h" ]
}

@test "hardened copy: uninstalling it keeps quarantine runs and says where they are" {
  setup_root; acme
  "$TOOL" --install > /dev/null
  request com.acme.app
  apply com.acme.app
  run "$TOOL" --uninstall-tool
  echo "$output" | grep -q "Quarantine runs are kept"
  ls -d "$R/Library/Application Support/mimi/quarantine"/sys-* > /dev/null
}

@test "hardened copy: mimi prints sudo only for a trusted identical copy" {
  setup_root; acme
  chmod 0755 "$R"
  run /bin/bash "$MIMI_BIN" app uninstall com.acme.app --system
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "No sudo command was printed"
  echo "$output" | grep -q "No trusted root-owned copy is installed"
  ! echo "$output" | grep -q "sudo \".*\" \".*system-requests/"

  "$TOOL" --install > /dev/null
  chmod 0755 "$R" "$R/usr" "$R/usr/local" "$R/usr/local/libexec" "$R/usr/local/libexec/mimi"
  run /bin/bash "$MIMI_BIN" app uninstall com.acme.app --system
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "sudo \"$R/usr/local/libexec/mimi/mimi-root-apply\" \".*system-requests/.*\.request\""
  ! echo "$output" | grep -q "No sudo command was printed"

  # A same-user edit of the hardened copy must not stay on the sudo line.
  printf '# older version\n' >> "$R/usr/local/libexec/mimi/mimi-root-apply"
  run /bin/bash "$MIMI_BIN" app uninstall com.acme.app --system
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "out of date"
  ! echo "$output" | grep -q "sudo \".*\" \".*system-requests/"

  # Identical again, but group-writable: still not trusted.
  cp "$TOOL" "$R/usr/local/libexec/mimi/mimi-root-apply"
  chmod 0775 "$R/usr/local/libexec/mimi/mimi-root-apply"
  run /bin/bash "$MIMI_BIN" app uninstall com.acme.app --system
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "not a trusted root-owned file"
  ! echo "$output" | grep -q "sudo \".*\" \".*system-requests/"
}

@test "require_root: a group-writable copy is refused when trust is enforced" {
  setup_root
  local copy="$R/bin/mimi-root-apply"
  mkdir -p "$R/bin"
  cp "$TOOL" "$copy"
  chmod 0755 "$R" "$R/bin"
  chmod 0777 "$copy"
  run env MIMI_ROOT_CHECK_TRUST=1 "$copy" --runs
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "not a trusted root-owned tool"

  chmod 0755 "$copy"
  run env MIMI_ROOT_CHECK_TRUST=1 "$copy" --runs
  [ "$status" -eq 0 ]
}

@test "payload: an item listed by two of the app's own packages is one candidate" {
  setup_root
  mkdir -p "$R/Library/Application Support/Dup/data"
  receipt com.dup.app.core "" "Library/Application Support/Dup/data/a"
  receipt com.dup.app.extra "" "Library/Application Support/Dup/data/b"
  printf 'x\n' > "$R/Library/Application Support/Dup/data/a"
  printf 'x\n' > "$R/Library/Application Support/Dup/data/b"
  run candidates com.dup.app
  [ "$(echo "$output" | awk -F'\t' '$1 ~ /^sys-/' | wc -l | tr -d ' ')" = 1 ]
  echo "$output" | grep -q "	payload	$R/Library/Application Support/Dup	"
}

@test "root: works with a plutil that prints its errors to stdout (macOS 14)" {
  setup_root; acme
  daemon com.acme.socket com.acme.socket "$R/Library/PrivilegedHelperTools/com.acme.socket" com.acme.app
  helper com.acme.socket
  # Wrap the real plutil the way macOS 14 behaves: a missing key prints the
  # error on stdout and exits 1.
  mkdir -p "$TEST_TMPDIR/oldbin"
  cat > "$TEST_TMPDIR/oldbin/plutil" <<'SH'
#!/bin/sh
out="$(/usr/bin/plutil "$@" 2>&1)"; rc=$?
[ "$rc" = 0 ] || { echo "Could not extract value, error: No value at that key path or invalid key path"; exit "$rc"; }
printf '%s\n' "$out"
SH
  chmod +x "$TEST_TMPDIR/oldbin/plutil"
  PATH="$TEST_TMPDIR/oldbin:$PATH" run candidates com.acme.app
  [ "$(echo "$output" | awk -F'\t' '$1 ~ /^sys-/ {print $2}' | sort | tr '\n' ' ')" = "daemon daemon helper helper " ]
}
