#!/usr/bin/env bats
#
# defects.bats — P0-T10: contained correctness defects.
#
# Each of these was a place where the tool said something that was not true, or
# acted on evidence it did not have.

load 'test_helper'

source_lib() {
  load_lib
  LOG_FILE="$TEST_TMPDIR/test.log"
  : > "$LOG_FILE"
  MODE="clean"
}

SDK() { printf '%s' "$FAKE_HOME/Library/Android/sdk/system-images"; }

# Create a system image leaf and put a file in it.
make_image() {
  mkdir -p "$(SDK)/$1"
  printf 'x\n' > "$(SDK)/$1/payload"
}

# Write an AVD config.ini. $1 = avd root, $2 = name, $3 = sysdir value,
# $4 = "crlf" to use Windows line endings.
make_avd() {
  local root="$1" name="$2" sysdir="$3" eol="${4:-lf}"
  mkdir -p "$root/$name.avd"
  if [ "$eol" = "crlf" ]; then
    printf 'AvdId=%s\r\nimage.sysdir.1=%s\r\n' "$name" "$sysdir" > "$root/$name.avd/config.ini"
  else
    printf 'AvdId=%s\nimage.sysdir.1=%s\n' "$name" "$sysdir" > "$root/$name.avd/config.ini"
  fi
}

# ---------------------------------------------------------------------------
# QuickLook: the reset ran twice
# ---------------------------------------------------------------------------

@test "quicklook: the cache reset is invoked exactly once" {
  export MOCK_CALL_LOG="$TEST_TMPDIR/calls"
  : > "$MOCK_CALL_LOG"
  run_clean --clean --yes --only quicklook
  [ "$(grep -c '^qlmanage ' "$MOCK_CALL_LOG")" -eq 1 ]
}

@test "quicklook: a failing qlmanage is reported, not called a success" {
  export MOCK_FAIL_CMDS="qlmanage*"
  run_clean --clean --yes --only quicklook
  [ "$status" -eq 3 ]
  ! echo "$output" | grep -q 'QuickLook thumbnail cache reset (freed'
  echo "$output" | grep -q 'failed (exit 7)'
}

# ---------------------------------------------------------------------------
# Delegated commands: the exit status was discarded everywhere
# ---------------------------------------------------------------------------

@test "delegated: a failing npm cache clean is not reported as cleaned" {
  mkdir -p "$FAKE_HOME/.npm/_cacache"
  printf 'x\n' > "$FAKE_HOME/.npm/_cacache/data"
  # Only the cleanup call fails; `npm config get cache` still answers, which is
  # what a real npm failure looks like.
  export MOCK_FAIL_CMDS="npm cache clean*"

  run_clean --clean --yes --only npm
  [ "$status" -eq 3 ]
  ! echo "$output" | grep -q 'npm cache cleaned'
  echo "$output" | grep -q 'failed (exit 7)'
}

@test "delegated: a failing tool counts as a failed action, not a skipped one" {
  mkdir -p "$FAKE_HOME/.npm/_cacache"
  export MOCK_FAIL_CMDS="npm cache clean*"
  run_clean --clean --yes --only npm
  echo "$output" | grep -qE 'Actions: [0-9]+ succeeded, [0-9]+ skipped, [0-9]+ permission-denied, [1-9][0-9]* failed'
}

@test "delegated: a succeeding tool still reports success" {
  mkdir -p "$FAKE_HOME/.npm/_cacache"
  run_clean --clean --yes --only npm
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'npm cache cleaned'
}

@test "delegated: a failing yarn cache clean is surfaced" {
  # The yarn mock reports $TMPDIR/yarn-cache-mock as its cache directory.
  mkdir -p "$TMPDIR/yarn-cache-mock"
  printf 'x\n' > "$TMPDIR/yarn-cache-mock/data"
  export MOCK_FAIL_CMDS="yarn cache clean*"
  run_clean --clean --yes --only yarn
  [ "$status" -eq 3 ]
  ! echo "$output" | grep -q 'yarn cache cleaned ('
}

@test "delegated: a failing pnpm store prune is surfaced" {
  mkdir -p "$FAKE_HOME/Library/pnpm/store"
  printf 'x\n' > "$FAKE_HOME/Library/pnpm/store/data"
  export MOCK_FAIL_CMDS="pnpm store prune*"
  run_clean --clean --yes --only pnpm
  [ "$status" -eq 3 ]
  ! echo "$output" | grep -q 'pnpm store pruned ('
}

@test "delegated: a failing brew cleanup is surfaced" {
  export MOCK_FAIL_CMDS="brew cleanup*"
  run_clean --clean --yes --only homebrew
  [ "$status" -eq 3 ]
  ! echo "$output" | grep -q 'brew cleanup (freed'
}

@test "delegated: a tool with no measurable directory reports without a byte figure" {
  # tmutil thinning frees purgeable space that du never saw; inventing a
  # number for it would be worse than printing none.
  run_clean --clean --yes --only timemachine
  ! echo "$output" | grep -q 'thinning.*freed'
}

# ---------------------------------------------------------------------------
# Android SDK images: deletion on absent evidence
# ---------------------------------------------------------------------------

@test "android: with no AVD directory at all, nothing is deleted" {
  # The old code read an empty reference list as "no image is in use" and
  # removed every one of them.
  make_image "android-34/google_apis/arm64-v8a"
  rm -rf "$FAKE_HOME/.android/avd"

  run_clean --clean --yes --only android --include-android
  [ -f "$(SDK)/android-34/google_apis/arm64-v8a/payload" ]
  echo "$output" | grep -q 'cannot tell which system images are in use'
  echo "$output" | grep -q 'NOT removed'
}

@test "android: a CRLF config.ini still protects the image it references" {
  # config.ini is written by a cross-platform tool. A trailing \r made the
  # reference match nothing, so a referenced image looked unused.
  make_image "android-34/google_apis/arm64-v8a"
  make_avd "$FAKE_HOME/.android/avd" "Pixel" \
    "system-images/android-34/google_apis/arm64-v8a/" crlf

  # Also assert the reference parsed *cleanly*. Without the \r stripping the
  # image survives anyway — but only because the reference is then rejected as
  # malformed, which disables the whole category. Surviving is not enough;
  # the reference has to be understood.
  make_image "android-29/default/x86"

  run_clean --clean --yes --only android --include-android
  [ -f "$(SDK)/android-34/google_apis/arm64-v8a/payload" ]
  ! echo "$output" | grep -q 'did not match the expected'
  # Proof the category was not merely disabled: the unreferenced image went.
  [ ! -e "$(SDK)/android-29/default/x86" ]
}

@test "android: a malformed reference disables deletion entirely" {
  make_image "android-34/google_apis/arm64-v8a"
  make_avd "$FAKE_HOME/.android/avd" "Pixel" "/absolute/elsewhere/img"

  run_clean --clean --yes --only android --include-android
  [ -f "$(SDK)/android-34/google_apis/arm64-v8a/payload" ]
  echo "$output" | grep -q 'did not match the expected'
}

@test "android: a traversal in a reference disables deletion entirely" {
  make_image "android-34/google_apis/arm64-v8a"
  make_avd "$FAKE_HOME/.android/avd" "Pixel" "system-images/../../../etc/x"

  run_clean --clean --yes --only android --include-android
  [ -f "$(SDK)/android-34/google_apis/arm64-v8a/payload" ]
  echo "$output" | grep -q 'did not match the expected'
}

@test "android: ANDROID_AVD_HOME is honoured" {
  make_image "android-34/google_apis/arm64-v8a"
  local alt="$FAKE_HOME/elsewhere/avd"
  make_avd "$alt" "Pixel" "system-images/android-34/google_apis/arm64-v8a/"
  rm -rf "$FAKE_HOME/.android/avd"

  ANDROID_AVD_HOME="$alt" run_clean --clean --yes --only android --include-android
  [ -f "$(SDK)/android-34/google_apis/arm64-v8a/payload" ]
}

@test "android: with sound evidence an unreferenced image is still removed" {
  # The safety work must not turn the category into a no-op.
  make_image "android-34/google_apis/arm64-v8a"
  make_image "android-29/default/x86"
  make_avd "$FAKE_HOME/.android/avd" "Pixel" \
    "system-images/android-34/google_apis/arm64-v8a/"

  run_clean --clean --yes --only android --include-android
  [ -f "$(SDK)/android-34/google_apis/arm64-v8a/payload" ]
  [ ! -e "$(SDK)/android-29/default/x86" ]
}

@test "android: an unreadable config.ini disables deletion" {
  make_image "android-29/default/x86"
  make_avd "$FAKE_HOME/.android/avd" "Pixel" \
    "system-images/android-34/google_apis/arm64-v8a/"
  chmod 000 "$FAKE_HOME/.android/avd/Pixel.avd/config.ini"

  run_clean --clean --yes --only android --include-android
  chmod 644 "$FAKE_HOME/.android/avd/Pixel.avd/config.ini"
  [ -d "$(SDK)/android-29/default/x86" ]
}

# ---------------------------------------------------------------------------
# LaunchAgents
# ---------------------------------------------------------------------------

@test "launchagent: the label is read from the plist" {
  source_lib
  mkdir -p "$FAKE_HOME/Library/LaunchAgents"
  local plist="$FAKE_HOME/Library/LaunchAgents/com.vendor.agent.plist"
  cat > "$plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.vendor.agent</string>
</dict></plist>
PLIST
  # Not loaded, so this is the ordinary leftover case and must succeed quietly.
  run unload_launch_agent "$plist"
  [ "$status" -eq 0 ]
}

@test "launchagent: a plist with no Label says so instead of failing silently" {
  source_lib
  mkdir -p "$FAKE_HOME/Library/LaunchAgents"
  local plist="$FAKE_HOME/Library/LaunchAgents/broken.plist"
  printf 'not a plist\n' > "$plist"

  run unload_launch_agent "$plist"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'no Label'
}

@test "launchagent: the deprecated unload interface is gone" {
  ! grep -qr 'launchctl unload' "$MIMI_LIB"
  grep -qr 'launchctl bootout' "$MIMI_LIB"
}

# ---------------------------------------------------------------------------
# Config writes
# ---------------------------------------------------------------------------

@test "config: save_config writes atomically and round-trips" {
  source_lib
  CONFIG_DIR="$FAKE_HOME/.config/mimi"
  CONFIG_FILE="$CONFIG_DIR/config.conf"
  KEEP_LOGS=9
  TMP_STALE_DAYS=11
  WHITELIST=("$FAKE_HOME/Library/Caches/keep")
  CATEGORY_STATE_IDS=(caches); CATEGORY_STATE_ON=(1)

  save_config
  grep -q '^KEEP_LOGS=9$' "$CONFIG_FILE"
  grep -q '^TMP_STALE_DAYS=11$' "$CONFIG_FILE"

  KEEP_LOGS=0; TMP_STALE_DAYS=0
  load_config
  [ "$KEEP_LOGS" = "9" ]
  [ "$TMP_STALE_DAYS" = "11" ]
}

@test "config: the saved file is not world- or group-readable" {
  source_lib
  CONFIG_DIR="$FAKE_HOME/.config/mimi"
  CONFIG_FILE="$CONFIG_DIR/config.conf"
  CATEGORY_STATE_IDS=(caches); CATEGORY_STATE_ON=(1)

  save_config
  [ "$(stat -f '%Lp' "$CONFIG_FILE")" = "600" ]
}

@test "config: a failed save leaves the previous file untouched" {
  source_lib
  CONFIG_DIR="$FAKE_HOME/.config/mimi"
  CONFIG_FILE="$CONFIG_DIR/config.conf"
  CATEGORY_STATE_IDS=(caches); CATEGORY_STATE_ON=(1)

  KEEP_LOGS=5
  save_config
  local original
  original="$(cat "$CONFIG_FILE")"

  # No temporary file can be created, so the write must abort before the
  # rename rather than truncating the target.
  chmod 500 "$CONFIG_DIR"
  KEEP_LOGS=99
  run save_config
  chmod 700 "$CONFIG_DIR"

  [ "$status" -ne 0 ]
  [ "$(cat "$CONFIG_FILE")" = "$original" ]
}

@test "config: no temporary files are left behind by a successful save" {
  source_lib
  CONFIG_DIR="$FAKE_HOME/.config/mimi"
  CONFIG_FILE="$CONFIG_DIR/config.conf"
  CATEGORY_STATE_IDS=(caches); CATEGORY_STATE_ON=(1)

  save_config
  [ -z "$(find "$CONFIG_DIR" -name '.config.conf.*')" ]
}

# ---------------------------------------------------------------------------
# Logging before log_init
# ---------------------------------------------------------------------------

@test "logging: a usage error produces no shell redirection noise" {
  # Every message emitted before log_init used to be appended to a log path
  # inside a directory that did not exist yet.
  run_clean --only nosuchcategory
  [ "$status" -eq 1 ]
  ! echo "$output" | grep -q 'No such file or directory'
}

@test "logging: an unknown option produces no shell redirection noise" {
  run_clean --bogus-flag
  [ "$status" -eq 1 ]
  ! echo "$output" | grep -q 'No such file or directory'
}

@test "logging: no log directory is created just by failing to parse arguments" {
  run_clean --only nosuchcategory
  [ ! -d "$FAKE_HOME/Library/Logs/mimi" ]
}

# ---------------------------------------------------------------------------
# Allocated vs logical bytes
# ---------------------------------------------------------------------------

@test "sparse: logical size is reported separately from allocated size" {
  source_lib
  local f="$FAKE_HOME/sparse.img"
  # 64 MB apparent, one block allocated.
  dd if=/dev/zero of="$f" bs=1 count=1 seek=67108863 2>/dev/null

  local logical allocated
  logical="$(path_logical_kb "$f")"
  allocated="$(dir_size_kb "$f")"
  [ "$logical" -gt 65000 ]
  [ "$allocated" -lt "$logical" ]
  is_sparse_file "$f"
}

@test "sparse: a dense file is not called sparse" {
  source_lib
  local f="$FAKE_HOME/dense.bin"
  dd if=/dev/zero of="$f" bs=1024 count=512 2>/dev/null
  ! is_sparse_file "$f"
}

@test "sparse: logical size is never used as a reclaimed figure" {
  source_lib
  local f="$FAKE_HOME/Library/Caches/sparse.img"
  dd if=/dev/zero of="$f" bs=1 count=1 seek=67108863 2>/dev/null
  local allocated
  allocated="$(dir_size_kb "$f")"

  TOTAL_RECLAIMED_KB=0
  remove_path "$f"
  [ "$TOTAL_RECLAIMED_KB" -eq "$allocated" ]
  [ "$TOTAL_RECLAIMED_KB" -lt 65000 ]
}

@test "sparse: path_logical_kb refuses directories" {
  source_lib
  [ "$(path_logical_kb "$FAKE_HOME/Library/Caches")" = "0" ]
}
