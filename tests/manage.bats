#!/usr/bin/env bats
#
# manage.bats — Tests for Shell Completion and Self-Update Engine (Phase 12)
#

load 'test_helper'

@test "completion: emit zsh completion script" {
  run "$MIMI_BIN" completion zsh
  [ "$status" -eq 0 ]
  [[ "$output" == *"#compdef mimi"* ]]
}

@test "completion: emit bash completion script" {
  run "$MIMI_BIN" completion bash
  [ "$status" -eq 0 ]
  [[ "$output" == *"# bash completion for mimi"* ]]
}

@test "completion: --dry-run previews installation without modifying shell config" {
  export SHELL="/bin/zsh"
  run "$MIMI_BIN" completion --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY RUN]"* ]]
  [ ! -f "$FAKE_HOME/.zshrc" ] || [ ! -s "$FAKE_HOME/.zshrc" ]
}

@test "completion: install configures zshrc idempotently" {
  export SHELL="/bin/zsh"
  run "$MIMI_BIN" completion install
  [ "$status" -eq 0 ]
  [ -f "$FAKE_HOME/.config/mimi/completions/_mimi" ]
  [ -f "$FAKE_HOME/.zshrc" ]
  grep -q "Mimi shell completion" "$FAKE_HOME/.zshrc"

  # Run a second time to ensure no duplicate hooks
  run "$MIMI_BIN" completion install
  [ "$status" -eq 0 ]
  [ "$(grep -c "Mimi shell completion" "$FAKE_HOME/.zshrc")" -eq 1 ]
}

@test "completion: install configures bash config" {
  export SHELL="/bin/bash"
  run "$MIMI_BIN" completion install
  [ "$status" -eq 0 ]
  [ -f "$FAKE_HOME/.config/mimi/completions/mimi.bash" ]
  grep -q "Mimi shell completion" "$FAKE_HOME/.bashrc" || grep -q "Mimi shell completion" "$FAKE_HOME/.bash_profile"
}

@test "update: detects when mimi is already up to date" {
  MIMI_MOCK_LATEST_VERSION="0.4.0" run "$MIMI_BIN" update --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"already up to date"* ]]
}

@test "update: detects when a new release is available" {
  MIMI_MOCK_LATEST_VERSION="0.5.0" run "$MIMI_BIN" update --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"A new version of Mimi is available: v0.5.0"* ]]
}

@test "update: emits JSON telemetry with update availability" {
  MIMI_MOCK_LATEST_VERSION="0.5.0" run "$MIMI_BIN" update --check --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"type":"update_check"'* ]]
  [[ "$output" == *'"latest_version":"0.5.0"'* ]]
  [[ "$output" == *'"update_available":true'* ]]
}

@test "update: semver comparison handles major, minor, patch, and identical versions" {
  load_lib
  is_newer_semver "0.5.0" "0.4.0"
  ! is_newer_semver "0.4.0" "0.4.0"
  ! is_newer_semver "0.3.9" "0.4.0"
  is_newer_semver "1.0.0" "0.4.0"
  is_newer_semver "0.4.1" "0.4.0"
  is_newer_semver "v0.5.0" "0.4.0"
}
