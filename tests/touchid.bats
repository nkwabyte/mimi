#!/usr/bin/env bats
#
# touchid.bats — Tests for Touch ID PAM configuration and status (Phase 9)
#

load 'test_helper'

init_pam_fixture() {
  export PAM_FIXTURE_DIR="$TEST_TMPDIR/pam.d"
  mkdir -p "$PAM_FIXTURE_DIR"
  export MIMI_PAM_SUDO_FILE="$PAM_FIXTURE_DIR/sudo"
  export MIMI_PAM_SUDO_LOCAL_FILE="$PAM_FIXTURE_DIR/sudo_local"
  export MIMI_TEST_PAM_NO_ROOT=1

  cat > "$MIMI_PAM_SUDO_FILE" <<'EOF'
# sudo: auth account password session
auth       required       pam_opendirectory.so
account    required       pam_permit.so
EOF
}

@test "touchid: supports_touchid respects mock environment variable" {
  load_lib
  MIMI_MOCK_TOUCHID_SUPPORT=1 run supports_touchid
  [ "$status" -eq 0 ]

  MIMI_MOCK_TOUCHID_SUPPORT=0 run supports_touchid
  [ "$status" -eq 1 ]
}

@test "touchid: detects unconfigured PAM state" {
  init_pam_fixture
  load_lib
  run is_touchid_configured
  [ "$status" -eq 1 ]

  run "$MIMI_BIN" touchid
  [ "$status" -eq 0 ]
  [[ "$output" == *"Touch ID is not configured"* ]]
}

@test "touchid: --json outputs valid structured status document" {
  init_pam_fixture
  run "$MIMI_BIN" touchid --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"type":"touchid_status"'* ]]
  [[ "$output" == *'"configured":false'* ]]
  [[ "$output" == *'"supported":'* ]]
}

@test "touchid: enable --dry-run previews changes without writing" {
  init_pam_fixture
  run "$MIMI_BIN" touchid enable --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY RUN]"* ]]
  [ ! -f "$MIMI_PAM_SUDO_LOCAL_FILE" ]
}

@test "touchid: enable successfully installs pam_tid in sudo_local" {
  init_pam_fixture
  run "$MIMI_BIN" touchid enable
  [ "$status" -eq 0 ]
  [[ "$output" == *"Touch ID enabled for sudo"* ]]
  [ -f "$MIMI_PAM_SUDO_LOCAL_FILE" ]
  grep -q "pam_tid.so" "$MIMI_PAM_SUDO_LOCAL_FILE"

  # Verify is_touchid_configured now detects it
  run "$MIMI_BIN" touchid --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"configured":true'* ]]
}

@test "touchid: disable removes pam_tid from sudo_local" {
  init_pam_fixture
  cat > "$MIMI_PAM_SUDO_LOCAL_FILE" <<'EOF'
# sudo_local: local customizations
auth       sufficient     pam_tid.so
EOF

  run "$MIMI_BIN" touchid disable
  [ "$status" -eq 0 ]
  [[ "$output" == *"Touch ID disabled for sudo"* ]]
  ! grep -q "pam_tid.so" "$MIMI_PAM_SUDO_LOCAL_FILE"

  run "$MIMI_BIN" touchid --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"configured":false'* ]]
}

@test "touchid: toggle flips state between enabled and disabled" {
  init_pam_fixture
  # Initially disabled
  run "$MIMI_BIN" touchid toggle
  [ "$status" -eq 0 ]
  [[ "$output" == *"Touch ID enabled"* ]]
  grep -q "pam_tid.so" "$MIMI_PAM_SUDO_LOCAL_FILE"

  # Now toggle again to disable
  run "$MIMI_BIN" touchid toggle
  [ "$status" -eq 0 ]
  [[ "$output" == *"Touch ID disabled"* ]]
  ! grep -q "pam_tid.so" "$MIMI_PAM_SUDO_LOCAL_FILE"
}
