#!/usr/bin/env bats
#
# confirmations.bats — P0-T07: typed confirmations and the force policy.
#
# The defect this file guards against is a single line of shell:
#
#     confirm() { [ "$ASSUME_YES" = 1 ] && return 0; ... }
#
# which made `--yes` — the flag people paste into a cron line once and never
# look at again — the answer to "permanently empty ~/.Trash?" and "delete
# these iPhone backups?" as readily as to "clear this cache?".
#
# Every test below runs with stdin pinned to /dev/null by the harness, which
# is the non-interactive case: no terminal exists to prompt on. That is the
# case that has to fail loudly rather than quietly guess.

load 'test_helper'

source_lib() {
  load_lib
  LOG_FILE="$TEST_TMPDIR/test.log"
  : > "$LOG_FILE"
}

APPSUP() { printf '%s' "$FAKE_HOME/Library/Application Support"; }

write_review() {
  local f="$TEST_TMPDIR/review.txt" line
  {
    printf '# mimi-orphan-review v1\n'
    for line in "$@"; do printf '%s\n' "$line"; done
  } > "$f"
  printf '%s' "$f"
}

MAIL_DIR() {
  printf '%s' "$FAKE_HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
}

# ---------------------------------------------------------------------------
# The classes themselves
# ---------------------------------------------------------------------------

@test "class: every gated action has a class, and only four classes exist" {
  source_lib
  local id class
  for id in $CONFIRM_GATED_IDS; do
    class="$(confirm_class "$id")"
    case "$class" in
      recoverable|risky|irreversible) ;;
      *) echo "unclassified gated action: $id -> '$class'" >&2; return 1 ;;
    esac
  done
}

@test "class: the irreversible actions are the ones with no other copy" {
  source_lib
  [ "$(confirm_class trash)" = irreversible ]
  [ "$(confirm_class ios-backups)" = irreversible ]
  [ "$(confirm_class orphans)" = irreversible ]
}

@test "class: an unknown id is recoverable, never silently un-skippable" {
  # A prompt added later without a classification must not become impossible
  # to answer. It degrades to the weakest class, and the reviewer notices
  # because --force-risky refuses to accept its name.
  source_lib
  [ "$(confirm_class something-nobody-classified)" = recoverable ]
  ! confirm_is_forceable something-nobody-classified
}

@test "class: no terminal is available to the test suite" {
  # The premise of every non-interactive test below. If this ever passes,
  # the suite is running attached to a terminal and the rest of this file is
  # testing something other than what it claims to.
  source_lib
  ! confirm_can_prompt
}

# ---------------------------------------------------------------------------
# --yes cannot authorize risky or irreversible work
# ---------------------------------------------------------------------------

@test "yes: --yes alone does not empty the Trash" {
  printf 'x\n' > "$FAKE_HOME/.Trash/receipt.pdf"

  run_clean --clean --yes --only trash --include-trash
  [ "$status" -eq 5 ]
  [ -f "$FAKE_HOME/.Trash/receipt.pdf" ]
}

@test "yes: --yes alone does not clear the Mail download cache" {
  mkdir -p "$(MAIL_DIR)"
  printf 'x\n' > "$(MAIL_DIR)/attachment.pdf"

  run_clean --clean --yes --only mail --include-mail
  [ "$status" -eq 5 ]
  [ -f "$(MAIL_DIR)/attachment.pdf" ]
}

@test "yes: --yes alone does not remove reviewed orphan remnants" {
  local target
  target="$(APPSUP)/com.example.reviewed"
  mkdir -p "$target"
  printf 'x\n' > "$target/data"
  local f
  f="$(write_review "$target")"

  run_clean --clean --yes --only orphans --remove-orphans-from "$f"
  [ "$status" -eq 5 ]
  [ -f "$target/data" ]
}

@test "yes: --yes alone does not delete local device backups" {
  local b="$FAKE_HOME/Library/Application Support/MobileSync/Backup/abc123"
  mkdir -p "$b"
  printf 'x\n' > "$b/Manifest.db"

  run_clean --clean --yes --only ios-backups --include-ios-backups
  [ "$status" -eq 5 ]
  [ -f "$b/Manifest.db" ]
}

@test "yes: --yes alone does not run a full Docker prune" {
  run_clean --clean --yes --only docker --include-docker
  [ "$status" -eq 5 ]
  echo "$output" | grep -q -- '--force-risky docker'
}

@test "yes: --yes still answers ordinary prompts, so safe categories still clean" {
  mkdir -p "$FAKE_HOME/Library/Caches/app"
  printf 'x\n' > "$FAKE_HOME/Library/Caches/app/blob"

  run_clean --clean --yes --only caches
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE_HOME/Library/Caches/app/blob" ]
}

# ---------------------------------------------------------------------------
# Failing before anything is removed, not halfway through
# ---------------------------------------------------------------------------

@test "preflight: an unauthorized risky action stops the run before safe work happens" {
  # The safe category here would ordinarily be cleaned. It must survive,
  # because the run is refused up front rather than part-way down the list —
  # a half-done run is the state that is hardest to reason about afterwards.
  mkdir -p "$FAKE_HOME/Library/Caches/app"
  printf 'x\n' > "$FAKE_HOME/Library/Caches/app/blob"
  printf 'x\n' > "$FAKE_HOME/.Trash/receipt.pdf"

  run_clean --clean --yes --only caches,trash --include-trash
  [ "$status" -eq 5 ]
  [ -f "$FAKE_HOME/Library/Caches/app/blob" ]
  [ -f "$FAKE_HOME/.Trash/receipt.pdf" ]
  echo "$output" | grep -q 'Nothing was removed'
}

@test "preflight: the message names the action, its class and the exact flag" {
  printf 'x\n' > "$FAKE_HOME/.Trash/receipt.pdf"

  run_clean --clean --yes --only trash --include-trash
  echo "$output" | grep -q 'trash  (irreversible)'
  echo "$output" | grep -q -- '--force-risky trash'
}

@test "preflight: every unauthorized action is listed, not just the first" {
  printf 'x\n' > "$FAKE_HOME/.Trash/receipt.pdf"
  mkdir -p "$(MAIL_DIR)"

  run_clean --clean --yes --only trash,mail --include-trash --include-mail
  [ "$status" -eq 5 ]
  echo "$output" | grep -q -- '--force-risky trash'
  echo "$output" | grep -q -- '--force-risky mail'
}

@test "preflight: authorizing one risky action does not authorize another" {
  printf 'x\n' > "$FAKE_HOME/.Trash/receipt.pdf"
  mkdir -p "$(MAIL_DIR)"
  printf 'x\n' > "$(MAIL_DIR)/attachment.pdf"

  run_clean --clean --yes --only trash,mail --include-trash --include-mail \
    --force-risky trash
  [ "$status" -eq 5 ]
  [ -f "$FAKE_HOME/.Trash/receipt.pdf" ]
  [ -f "$(MAIL_DIR)/attachment.pdf" ]
  echo "$output" | grep -q -- '--force-risky mail'
  ! echo "$output" | grep -q -- '--force-risky trash'
}

@test "preflight: a risky category excluded by --skip is not demanded" {
  # --skip wins over everything, so the category never runs and asking the
  # user to authorize it would be noise. (--include-trash on its own *is* a
  # request to run trash, which is why it has to be skipped explicitly here.)
  mkdir -p "$FAKE_HOME/Library/Caches/app"
  printf 'x\n' > "$FAKE_HOME/Library/Caches/app/blob"
  printf 'x\n' > "$FAKE_HOME/.Trash/receipt.pdf"

  run_clean --clean --yes --only caches --include-trash --skip trash
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE_HOME/Library/Caches/app/blob" ]
  [ -f "$FAKE_HOME/.Trash/receipt.pdf" ]
}

@test "preflight: --include-<risky> is itself a selection, so it is demanded" {
  # The counterpart of the test above, spelled out because it is the surprising
  # half: --include-trash adds trash to the run even when --only did not.
  printf 'x\n' > "$FAKE_HOME/.Trash/receipt.pdf"

  run_clean --clean --yes --only caches --include-trash
  [ "$status" -eq 5 ]
  [ -f "$FAKE_HOME/.Trash/receipt.pdf" ]
}

@test "preflight: scan mode is read-only, so it never demands authorization" {
  printf 'x\n' > "$FAKE_HOME/.Trash/receipt.pdf"

  run_clean --scan --only trash --include-trash
  [ "$status" -eq 0 ]
  [ -f "$FAKE_HOME/.Trash/receipt.pdf" ]
}

@test "preflight: the orphan report is read-only, so it needs no authorization" {
  run_clean --clean --yes --only orphans --include-orphans
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# --force-risky authorizes, and only what it names
# ---------------------------------------------------------------------------

@test "force: --force-risky trash plus --yes empties the Trash" {
  printf 'x\n' > "$FAKE_HOME/.Trash/receipt.pdf"

  run_clean --clean --yes --only trash --include-trash --force-risky trash
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE_HOME/.Trash/receipt.pdf" ]
  echo "$output" | grep -q 'authorized by --force-risky'
}

@test "force: --force-risky mail plus --yes clears the Mail download cache" {
  mkdir -p "$(MAIL_DIR)"
  printf 'x\n' > "$(MAIL_DIR)/attachment.pdf"

  run_clean --clean --yes --only mail --include-mail --force-risky mail
  [ "$status" -eq 0 ]
  [ ! -e "$(MAIL_DIR)/attachment.pdf" ]
}

@test "force: --force-risky orphans plus --yes removes reviewed remnants" {
  local target
  target="$(APPSUP)/com.example.reviewed"
  mkdir -p "$target"
  printf 'x\n' > "$target/data"
  local f
  f="$(write_review "$target")"

  run_clean --clean --yes --force-risky orphans --only orphans \
    --remove-orphans-from "$f"
  [ "$status" -eq 0 ]
  [ ! -e "$target" ]
}

@test "force: --force-risky does not select the category by itself" {
  # It authorizes; --include-trash selects. Without the include flag the
  # category is skipped, and the Trash survives.
  printf 'x\n' > "$FAKE_HOME/.Trash/receipt.pdf"

  run_clean --clean --yes --only trash --force-risky trash
  [ "$status" -eq 0 ]
  [ -f "$FAKE_HOME/.Trash/receipt.pdf" ]
}

@test "force: --force-risky without --yes still cannot answer the run gate" {
  # Authorizing the dangerous action does not authorize the run itself. In a
  # non-interactive run both are needed, and the error says which is missing.
  printf 'x\n' > "$FAKE_HOME/.Trash/receipt.pdf"

  run_clean --clean --only trash --include-trash --force-risky trash
  [ "$status" -eq 5 ]
  [ -f "$FAKE_HOME/.Trash/receipt.pdf" ]
  echo "$output" | grep -q -- 'pass --yes'
}

@test "force: several actions can be authorized in one comma-separated value" {
  printf 'x\n' > "$FAKE_HOME/.Trash/receipt.pdf"
  mkdir -p "$(MAIL_DIR)"
  printf 'x\n' > "$(MAIL_DIR)/attachment.pdf"

  run_clean --clean --yes --only trash,mail --include-trash --include-mail \
    --force-risky trash,mail
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE_HOME/.Trash/receipt.pdf" ]
  [ ! -e "$(MAIL_DIR)/attachment.pdf" ]
}

@test "force: the --force-risky=value spelling works too" {
  printf 'x\n' > "$FAKE_HOME/.Trash/receipt.pdf"

  run_clean --clean --yes --only trash --include-trash --force-risky=trash
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE_HOME/.Trash/receipt.pdf" ]
}

# ---------------------------------------------------------------------------
# What --force-risky refuses to accept
# ---------------------------------------------------------------------------

@test "force: there is no --force-risky all" {
  run_clean --clean --yes --force-risky all
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "there is no 'all'"
}

@test "force: a plain category name is not a risky action" {
  run_clean --clean --yes --force-risky caches
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'not a risky action'
}

@test "force: a recoverable gated action is refused, and says --yes covers it" {
  run_clean --clean --yes --force-risky ml-caches
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- '--yes already covers it'
}

@test "force: an unknown name is refused" {
  run_clean --clean --yes --force-risky not-a-thing
  [ "$status" -eq 1 ]
}

@test "force: --force-risky requires a value" {
  run_clean --clean --yes --force-risky
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'requires a value'
}

@test "force: --force-risky does not swallow the next flag as its value" {
  run_clean --clean --yes --force-risky --only caches
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'requires a value'
}

@test "force: an empty list is refused rather than read as 'nothing needed'" {
  run_clean --clean --yes --force-risky ""
  [ "$status" -eq 1 ]
}

@test "force: a repeated name is accepted once, not treated as an error" {
  printf 'x\n' > "$FAKE_HOME/.Trash/receipt.pdf"

  run_clean --clean --yes --only trash --include-trash --force-risky trash,trash
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE_HOME/.Trash/receipt.pdf" ]
}

@test "force: the rejection message lists the names that would work" {
  run_clean --clean --yes --force-risky caches
  echo "$output" | grep -q 'trash'
  echo "$output" | grep -q 'ios-backups'
}

# ---------------------------------------------------------------------------
# Authorization is per-invocation and never persisted
# ---------------------------------------------------------------------------

@test "persistence: a saved config cannot grant --force-risky" {
  # The whole value of naming each action is lost if the name can be written
  # once into a file and then forgotten about.
  printf 'x\n' > "$FAKE_HOME/.Trash/receipt.pdf"
  write_config "FORCE_RISKY_LIST=trash
SELECTED_CATEGORIES=trash"

  run_clean --clean --yes --include-trash
  [ "$status" -eq 5 ]
  [ -f "$FAKE_HOME/.Trash/receipt.pdf" ]
}

@test "persistence: saving settings never writes an authorization into the config" {
  source_lib
  FORCE_RISKY_LIST="trash,mail"
  build_category_state
  run save_config
  [ "$status" -eq 0 ]
  ! grep -q 'FORCE_RISKY' "$FAKE_HOME/.config/mimi/config.conf"
  ! grep -q 'force-risky' "$FAKE_HOME/.config/mimi/config.conf"
}

# ---------------------------------------------------------------------------
# The cancelled exit code
# ---------------------------------------------------------------------------

@test "exit: a clean with no way to confirm exits 5, not 1 and not 0" {
  # 1 is a usage error and 3 is work that ran and failed. Neither describes
  # a run that was refused authorization, and a script has to tell them apart.
  mkdir -p "$FAKE_HOME/Library/Caches/app"
  printf 'x\n' > "$FAKE_HOME/Library/Caches/app/blob"

  run_clean --clean --only caches
  [ "$status" -eq 5 ]
  [ -f "$FAKE_HOME/Library/Caches/app/blob" ]
}

@test "exit: the run gate says which flag was missing" {
  run_clean --clean --only caches
  echo "$output" | grep -q 'no terminal to confirm on'
  echo "$output" | grep -q -- '--yes'
  echo "$output" | grep -q 'Nothing was removed'
}

@test "exit: a usage error is still 1, not the cancelled code" {
  run_clean --clean --only not-a-category
  [ "$status" -eq 1 ]
}

@test "exit: 5 is distinct from every other documented exit code" {
  source_lib
  [ "$EXIT_CANCELLED" -eq 5 ]
  [ "$EXIT_CANCELLED" -ne "$EXIT_OK" ]
  [ "$EXIT_CANCELLED" -ne "$EXIT_USAGE" ]
  [ "$EXIT_CANCELLED" -ne "$EXIT_PARTIAL" ]
  [ "$EXIT_CANCELLED" -ne "$EXIT_INTERRUPTED" ]
}

# ---------------------------------------------------------------------------
# Documentation parity — the help text is part of the contract
# ---------------------------------------------------------------------------

@test "docs: --help documents --force-risky" {
  run_clean --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- '--force-risky'
}

@test "docs: --help names all four confirmation classes" {
  run_clean --help
  echo "$output" | grep -q 'read-only'
  echo "$output" | grep -q 'recoverable'
  echo "$output" | grep -q 'risky'
  echo "$output" | grep -q 'irreversible'
}

@test "docs: --help states that --yes cannot authorize risky work" {
  run_clean --help
  echo "$output" | grep -q 'never authorizes a risky or irreversible action'
}

@test "docs: --help documents the cancelled exit code" {
  run_clean --help
  echo "$output" | grep -qE '^  5 '
}

@test "docs: --help no longer claims --yes skips confirmation before deleting" {
  # The exact sentence that used to be true and is now the defect.
  run_clean --help
  ! echo "$output" | grep -q 'Do not prompt for confirmation before deleting'
}

@test "docs: every --force-risky name the help lists is actually accepted" {
  source_lib
  local id
  for id in $(confirm_forceable_ids | tr -d ' ' | tr ',' ' '); do
    run_clean --help
    echo "$output" | grep -q "$id"
  done
}
