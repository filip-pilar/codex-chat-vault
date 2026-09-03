#!/bin/sh

set -eu

ALV_TEST_ROOT_DIR=$(CDPATH='' cd "$(dirname "$0")/.." && pwd -P)
ALV_TEST_CLI=$ALV_TEST_ROOT_DIR/alv
ALV_TEST_REAL_RCLONE=$(command -v rclone || true)
ALV_TEST_REAL_CP=$(command -v cp || true)
ALV_TEST_REAL_LINK=$(command -v link || true)
ALV_TEST_TMP_BASE=${TMPDIR:-/tmp}
[ "$ALV_TEST_TMP_BASE" = / ] || ALV_TEST_TMP_BASE=${ALV_TEST_TMP_BASE%/}
ALV_TEST_WORK=$(mktemp -d "$ALV_TEST_TMP_BASE/agent-log-vault-rclone-test.XXXXXX")
ALV_TEST_CANONICAL_WORK=$(CDPATH='' cd -P "$ALV_TEST_WORK" && pwd -P)
ALV_TEST_RUNTIME_TMP=$ALV_TEST_WORK/runtime-tmp
ALV_TEST_WRAPPER_BIN=$ALV_TEST_WORK/wrapper-bin
mkdir -p "$ALV_TEST_RUNTIME_TMP" "$ALV_TEST_WRAPPER_BIN"
TMPDIR=$ALV_TEST_RUNTIME_TMP
export TMPDIR

alv_test_fail() {
  printf 'rclone test failure: %s\n' "$*" >&2
  exit 1
}

alv_test_cleanup() {
  case "$ALV_TEST_WORK" in
    "$ALV_TEST_TMP_BASE"/agent-log-vault-rclone-test.*)
      /bin/rm -rf "$ALV_TEST_WORK"
      ;;
    *) alv_test_fail "refusing to clean unexpected test path: $ALV_TEST_WORK" ;;
  esac
}

alv_test_expect_failure() {
  ALV_TEST_FAILURE_LABEL=$1
  shift
  if "$@" >"$ALV_TEST_WORK/last-command.out" 2>&1; then
    alv_test_fail "$ALV_TEST_FAILURE_LABEL"
  fi
}

alv_test_expect_status() {
  ALV_TEST_EXPECTED_STATUS=$1
  ALV_TEST_STATUS_LABEL=$2
  shift 2
  if "$@" >"$ALV_TEST_WORK/last-command.out" 2>&1; then
    ALV_TEST_ACTUAL_STATUS=0
  else
    ALV_TEST_ACTUAL_STATUS=$?
  fi
  [ "$ALV_TEST_ACTUAL_STATUS" -eq "$ALV_TEST_EXPECTED_STATUS" ] || \
    alv_test_fail "$ALV_TEST_STATUS_LABEL (expected $ALV_TEST_EXPECTED_STATUS, got $ALV_TEST_ACTUAL_STATUS)"
}

alv_test_mode() {
  if ALV_TEST_MODE_VALUE=$(stat -f '%Lp' "$1" 2>/dev/null); then
    printf '%s\n' "$ALV_TEST_MODE_VALUE"
  else
    stat -c '%a' "$1"
  fi
}

alv_test_inode() {
  if ALV_TEST_INODE_VALUE=$(stat -f '%i' "$1" 2>/dev/null); then
    printf '%s\n' "$ALV_TEST_INODE_VALUE"
  else
    stat -c '%i' "$1"
  fi
}

alv_test_sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    alv_test_fail "neither shasum nor sha256sum is available"
  fi
}

alv_test_assert_absent() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    alv_test_fail "$2"
  fi
}

alv_test_assert_no_stage() {
  ALV_TEST_STAGE_DESTINATION=$1
  ALV_TEST_STAGE_LABEL=$2
  for ALV_TEST_PARTIAL in "$ALV_TEST_STAGE_DESTINATION".partial.*; do
    if [ -e "$ALV_TEST_PARTIAL" ] || [ -L "$ALV_TEST_PARTIAL" ]; then
      alv_test_fail "$ALV_TEST_STAGE_LABEL"
    fi
  done
}

alv_test_assert_link_marker() {
  ALV_TEST_LINK_MARKER_EXPECTED=${3:-link-wrapper-ran}
  [ -f "$1" ] && [ ! -L "$1" ] || alv_test_fail "$2"
  ALV_TEST_LINK_MARKER_SIZE=$(wc -c < "$1")
  ALV_TEST_LINK_MARKER_EXPECTED_SIZE=$(printf '%s\n' \
    "$ALV_TEST_LINK_MARKER_EXPECTED" | wc -c)
  [ "$ALV_TEST_LINK_MARKER_SIZE" -eq \
    "$ALV_TEST_LINK_MARKER_EXPECTED_SIZE" ] 2>/dev/null && \
    grep -Fxq "$ALV_TEST_LINK_MARKER_EXPECTED" "$1" || \
    alv_test_fail "$2"
}

alv_test_assert_link_fixture_absent() {
  alv_test_assert_absent "$1" "$3 destination was not initially absent"
  alv_test_assert_absent "$2" "$3 marker was not initially absent"
}

alv_test_assert_failure_diagnostic() {
  rg -Fq "$1" "$ALV_TEST_WORK/last-command.out" || alv_test_fail "$2"
}

alv_test_assert_empty_directory() {
  ALV_TEST_EMPTY_DIRECTORY=$1
  ALV_TEST_EMPTY_LABEL=$2
  for ALV_TEST_EMPTY_ENTRY in \
    "$ALV_TEST_EMPTY_DIRECTORY"/* \
    "$ALV_TEST_EMPTY_DIRECTORY"/.[!.]* \
    "$ALV_TEST_EMPTY_DIRECTORY"/..?*; do
    if [ -e "$ALV_TEST_EMPTY_ENTRY" ] || [ -L "$ALV_TEST_EMPTY_ENTRY" ]; then
      alv_test_fail "$ALV_TEST_EMPTY_LABEL"
    fi
  done
}

alv_test_assert_cold_thread() {
  if ! "$ALV_TEST_CLI" list cold | grep -Fqx "$1"; then
    alv_test_fail "$2"
  fi
}

alv_test_write_rollout() {
  ALV_TEST_WRITE_PATH=$1
  ALV_TEST_WRITE_ID=$2
  ALV_TEST_WRITE_TIMESTAMP=$3
  ALV_TEST_WRITE_PAYLOAD=$4

  jq -cn \
    --arg id "$ALV_TEST_WRITE_ID" \
    --arg timestamp "$ALV_TEST_WRITE_TIMESTAMP" '
      {
        timestamp: $timestamp,
        type: "session_meta",
        payload: {
          id: $id,
          timestamp: $timestamp,
          cwd: "/workspace/rclone-test",
          originator: "agent-log-vault-rclone-test",
          cli_version: "0.test"
        }
      }
    ' > "$ALV_TEST_WRITE_PATH"
  printf '{"type":"test","payload":"%s"}\n' \
    "$ALV_TEST_WRITE_PAYLOAD" >> "$ALV_TEST_WRITE_PATH"
}

[ -n "$ALV_TEST_REAL_RCLONE" ] || alv_test_fail "rclone is required for this test"
[ -n "$ALV_TEST_REAL_CP" ] || alv_test_fail "cp is required for this test"
[ -n "$ALV_TEST_REAL_LINK" ] || alv_test_fail "link is required for this test"
command -v jq >/dev/null 2>&1 || alv_test_fail "jq is required for this test"
command -v rg >/dev/null 2>&1 || alv_test_fail "rg is required for this test"
trap alv_test_cleanup EXIT HUP INT TERM

cp "$ALV_TEST_ROOT_DIR/tests/helpers/rclone" "$ALV_TEST_WRAPPER_BIN/rclone"
cp "$ALV_TEST_ROOT_DIR/tests/helpers/cp" "$ALV_TEST_WRAPPER_BIN/cp"
cp "$ALV_TEST_ROOT_DIR/tests/helpers/link" "$ALV_TEST_WRAPPER_BIN/link"
chmod 700 \
  "$ALV_TEST_WRAPPER_BIN/rclone" \
  "$ALV_TEST_WRAPPER_BIN/cp" \
  "$ALV_TEST_WRAPPER_BIN/link"
export ALV_TEST_REAL_RCLONE ALV_TEST_REAL_CP ALV_TEST_REAL_LINK

unset RCLONE_CONFIG_PASS || true
unset RCLONE_PASSWORD_COMMAND || true
RCLONE_CONFIG=$ALV_TEST_WORK/rclone.conf
ALV_CONFIG_HOME=$ALV_TEST_WORK/config
CODEX_HOME="$ALV_TEST_WORK/codex home"
export RCLONE_CONFIG ALV_CONFIG_HOME CODEX_HOME

ALV_TEST_VAULT="$ALV_TEST_WORK/encrypted vault"
ALV_TEST_FAILED_VAULT="$ALV_TEST_WORK/failed encrypted vault"
ALV_TEST_CLEAN_HOME="$ALV_TEST_WORK/clean codex home"
ALV_TEST_UNSAFE_BACKING="$ALV_TEST_WORK/unsafe crypt backing"
ALV_TEST_OTHER_HOME="$ALV_TEST_WORK/other codex home"
ALV_TEST_SYMLINK_HOME="$ALV_TEST_WORK/symlink codex home"
ALV_TEST_EXTERNAL_ARCHIVE="$ALV_TEST_WORK/external synthetic archive"
ALV_TEST_ACTIVE_DIRECTORY="$CODEX_HOME/sessions"
mkdir -p \
  "$CODEX_HOME/archived_sessions" \
  "$ALV_TEST_ACTIVE_DIRECTORY" \
  "$ALV_TEST_CLEAN_HOME" \
  "$ALV_TEST_OTHER_HOME/archived_sessions" \
  "$ALV_TEST_SYMLINK_HOME" \
  "$ALV_TEST_EXTERNAL_ARCHIVE" \
  "$ALV_TEST_UNSAFE_BACKING" \
  "$ALV_TEST_FAILED_VAULT" \
  "$ALV_TEST_VAULT"

ALV_TEST_ROLLOUT_A=rollout-2026-02-01T00-00-00-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.jsonl
ALV_TEST_ROLLOUT_B=rollout-2026-02-02T00-00-00-bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb.jsonl
ALV_TEST_ROLLOUT_C=rollout-2026-02-03T00-00-00-cccccccc-cccc-cccc-cccc-cccccccccccc.jsonl
ALV_TEST_ACTIVE=rollout-2026-02-04T00-00-00-dddddddd-dddd-dddd-dddd-dddddddddddd.jsonl
ALV_TEST_ROLLOUT_OTHER=rollout-2026-02-05T00-00-00-eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee.jsonl
ALV_TEST_ROLLOUT_SYMLINK=rollout-2026-02-06T00-00-00-ffffffff-ffff-ffff-ffff-ffffffffffff.jsonl
ALV_TEST_SOURCE_A=$CODEX_HOME/archived_sessions/$ALV_TEST_ROLLOUT_A
ALV_TEST_SOURCE_B=$CODEX_HOME/archived_sessions/$ALV_TEST_ROLLOUT_B
ALV_TEST_SOURCE_C=$CODEX_HOME/archived_sessions/$ALV_TEST_ROLLOUT_C
ALV_TEST_ACTIVE_SOURCE=$ALV_TEST_ACTIVE_DIRECTORY/$ALV_TEST_ACTIVE
ALV_TEST_OTHER_SOURCE=$ALV_TEST_OTHER_HOME/archived_sessions/$ALV_TEST_ROLLOUT_OTHER
ALV_TEST_EXTERNAL_SOURCE=$ALV_TEST_EXTERNAL_ARCHIVE/$ALV_TEST_ROLLOUT_SYMLINK
ALV_TEST_CANONICAL_ARCHIVED=$(CDPATH='' cd -P \
  "$CODEX_HOME/archived_sessions" && pwd -P)
ALV_TEST_CANONICAL_SOURCE_A=$ALV_TEST_CANONICAL_ARCHIVED/$ALV_TEST_ROLLOUT_A
ALV_TEST_CANONICAL_SOURCE_B=$ALV_TEST_CANONICAL_ARCHIVED/$ALV_TEST_ROLLOUT_B

alv_test_write_rollout "$ALV_TEST_SOURCE_A" \
  aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa 2026-02-01T00:00:00.000Z alpha
alv_test_write_rollout "$ALV_TEST_SOURCE_B" \
  bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb 2026-02-02T00:00:00.000Z beta
alv_test_write_rollout "$ALV_TEST_SOURCE_C" \
  cccccccc-cccc-cccc-cccc-cccccccccccc 2026-02-03T00:00:00.000Z gamma
alv_test_write_rollout "$ALV_TEST_ACTIVE_SOURCE" \
  dddddddd-dddd-dddd-dddd-dddddddddddd 2026-02-04T00:00:00.000Z active
alv_test_write_rollout "$ALV_TEST_OTHER_SOURCE" \
  eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee 2026-02-05T00:00:00.000Z other
alv_test_write_rollout "$ALV_TEST_EXTERNAL_SOURCE" \
  ffffffff-ffff-ffff-ffff-ffffffffffff 2026-02-06T00:00:00.000Z external
ln -s "$ALV_TEST_EXTERNAL_ARCHIVE" "$ALV_TEST_SYMLINK_HOME/archived_sessions"
cp "$ALV_TEST_SOURCE_A" "$ALV_TEST_WORK/expected-a.jsonl"
cp "$ALV_TEST_SOURCE_B" "$ALV_TEST_WORK/expected-b.jsonl"
cp "$ALV_TEST_SOURCE_C" "$ALV_TEST_WORK/expected-c.jsonl"

"$ALV_TEST_CLI" vault add local cold --path "$ALV_TEST_VAULT" \
  > "$ALV_TEST_WORK/add-local.out"
ALV_TEST_PROFILE_LIST=$("$ALV_TEST_CLI" vault list)
[ "$ALV_TEST_PROFILE_LIST" = '* cold	local' ] || \
  alv_test_fail "the first local vault was not saved as default"

alv_test_expect_failure "failed local setup saved a profile" \
  env ALV_TEST_RCLONE_MODE=reject-setup-probe \
    PATH="$ALV_TEST_WRAPPER_BIN:$PATH" \
    "$ALV_TEST_CLI" vault add local broken-local \
      --path "$ALV_TEST_FAILED_VAULT"
[ ! -e "$ALV_CONFIG_HOME/vaults/broken-local" ] || \
  alv_test_fail "failed local setup left a named profile"
if rclone listremotes | rg -Fxq 'alv-broken-local-crypt:'; then
  alv_test_fail "failed local setup left its rclone remote"
fi

ALV_TEST_CRYPT_CONFIG=$(rclone config redacted alv-cold-crypt)
printf '%s\n' "$ALV_TEST_CRYPT_CONFIG" | \
  rg -q '^type = crypt$' || alv_test_fail "local vault is not crypt"
printf '%s\n' "$ALV_TEST_CRYPT_CONFIG" | \
  rg -q '^filename_encryption = standard$' || \
  alv_test_fail "local vault does not encrypt filenames"
printf '%s\n' "$ALV_TEST_CRYPT_CONFIG" | \
  rg -q '^directory_name_encryption = true$' || \
  alv_test_fail "local vault does not encrypt directory names"
printf '%s\n' "$ALV_TEST_CRYPT_CONFIG" | \
  rg -q '^no_data_encryption = false$' || \
  alv_test_fail "local vault does not encrypt data"

alv_test_expect_failure "rclone listing failure was not reported clearly" \
  env ALV_TEST_RCLONE_MODE=reject-list \
    PATH="$ALV_TEST_WRAPPER_BIN:$PATH" \
    "$ALV_TEST_CLI" list cold
rg -Fq 'could not list rclone location: rclone:alv-cold-crypt:' \
  "$ALV_TEST_WORK/last-command.out" || \
  alv_test_fail "rclone listing failure omitted the vault location"

[ -z "$("$ALV_TEST_CLI" list cold)" ] || \
  alv_test_fail "new cold vault was not empty"

ALV_TEST_EXTERNAL_INODE=$(alv_test_inode "$ALV_TEST_EXTERNAL_SOURCE")
ALV_TEST_EXTERNAL_HASH=$(alv_test_sha256_file "$ALV_TEST_EXTERNAL_SOURCE")
ALV_TEST_OFFLOAD_POISON_MARKER=$ALV_TEST_CANONICAL_WORK/offload-symlink-rclone.marker
alv_test_assert_absent \
  "$ALV_TEST_OFFLOAD_POISON_MARKER" \
  "offload poison marker was not initially absent"
alv_test_expect_failure "bare-name offload followed a symlinked archived_sessions" \
  env \
    ALV_TEST_RCLONE_MODE=reject-any-command \
    ALV_TEST_RCLONE_ROOT="$ALV_TEST_CANONICAL_WORK" \
    ALV_TEST_RCLONE_MARKER="$ALV_TEST_OFFLOAD_POISON_MARKER" \
    PATH="$ALV_TEST_WRAPPER_BIN:$PATH" \
    "$ALV_TEST_CLI" offload "$ALV_TEST_ROLLOUT_SYMLINK" \
      --codex-home "$ALV_TEST_SYMLINK_HOME"
alv_test_assert_absent \
  "$ALV_TEST_OFFLOAD_POISON_MARKER" \
  "bare-name offload reached rclone before rejecting the symlink boundary"
rg -Fq 'Codex archived_sessions path is a symbolic link' \
  "$ALV_TEST_WORK/last-command.out" || \
  alv_test_fail "bare-name offload omitted the symlink-boundary diagnostic"
[ -L "$ALV_TEST_SYMLINK_HOME/archived_sessions" ] && \
  [ "$(readlink "$ALV_TEST_SYMLINK_HOME/archived_sessions")" = \
    "$ALV_TEST_EXTERNAL_ARCHIVE" ] || \
  alv_test_fail "bare-name offload changed the archived_sessions symlink"
[ "$ALV_TEST_EXTERNAL_INODE" = \
  "$(alv_test_inode "$ALV_TEST_EXTERNAL_SOURCE")" ] && \
  [ "$ALV_TEST_EXTERNAL_HASH" = \
  "$(alv_test_sha256_file "$ALV_TEST_EXTERNAL_SOURCE")" ] || \
  alv_test_fail "bare-name offload changed the external synthetic rollout"
if "$ALV_TEST_CLI" list cold | grep -Fqx "$ALV_TEST_ROLLOUT_SYMLINK"; then
  alv_test_fail "rejected symlink-boundary offload created a cold pair"
fi

"$ALV_TEST_CLI" offload "$ALV_TEST_ROLLOUT_A" \
  > "$ALV_TEST_WORK/offload-a.out"
[ ! -e "$ALV_TEST_SOURCE_A" ] || alv_test_fail "offload retained local-only source"
[ "$("$ALV_TEST_CLI" list cold)" = "$ALV_TEST_ROLLOUT_A" ] || \
  alv_test_fail "offloaded thread was not listed cold"
"$ALV_TEST_CLI" verify "$ALV_TEST_ROLLOUT_A" \
  > "$ALV_TEST_WORK/verify-a-cold-only.out"
rg -q 'cold-only' "$ALV_TEST_WORK/verify-a-cold-only.out" || \
  alv_test_fail "verify did not report the cold-only state"
env CODEX_HOME="$ALV_TEST_WORK/missing codex home" \
  "$ALV_TEST_CLI" verify "$ALV_TEST_ROLLOUT_A" \
  > "$ALV_TEST_WORK/verify-a-without-home.out"
rg -q 'cold-only' "$ALV_TEST_WORK/verify-a-without-home.out" || \
  alv_test_fail "verify required a local Codex home for a cold-only thread"

if find "$ALV_TEST_VAULT" -type f -name '*rollout*' -print | grep -q .; then
  alv_test_fail "raw vault exposed a rollout filename"
fi
if rg -a -F 'session_meta' "$ALV_TEST_VAULT" >/dev/null 2>&1; then
  alv_test_fail "raw vault exposed plaintext thread content"
fi

alv_test_expect_failure "interrupted restore reported success" \
  env ALV_TEST_RCLONE_MODE=interrupt-download \
    PATH="$ALV_TEST_WRAPPER_BIN:$PATH" \
    "$ALV_TEST_CLI" restore "$ALV_TEST_ROLLOUT_A"
alv_test_assert_absent \
  "$ALV_TEST_SOURCE_A" \
  "interrupted restore created a local thread"
alv_test_assert_no_stage \
  "$ALV_TEST_CANONICAL_SOURCE_A" \
  "interrupted restore left a partial local thread"
[ "$("$ALV_TEST_CLI" list cold)" = "$ALV_TEST_ROLLOUT_A" ] || \
  alv_test_fail "interrupted restore changed the cold source"

alv_test_expect_failure "interrupted atomic placement reported success" \
  env ALV_TEST_CP_MODE=interrupt-placement \
    PATH="$ALV_TEST_WRAPPER_BIN:$PATH" \
    "$ALV_TEST_CLI" restore "$ALV_TEST_ROLLOUT_A"
alv_test_assert_absent \
  "$ALV_TEST_SOURCE_A" \
  "interrupted placement created a completed local thread"
alv_test_assert_no_stage \
  "$ALV_TEST_CANONICAL_SOURCE_A" \
  "interrupted placement left a partial local thread"
[ "$("$ALV_TEST_CLI" list cold)" = "$ALV_TEST_ROLLOUT_A" ] || \
  alv_test_fail "interrupted placement changed the cold source"

ALV_TEST_RESTORE_REGULAR_MARKER=$ALV_TEST_CANONICAL_WORK/restore-late-regular.marker
ALV_TEST_LATE_REGULAR_EXPECTED=$ALV_TEST_WORK/late-regular.expected
printf '%s\n' 'late-regular-target' > "$ALV_TEST_LATE_REGULAR_EXPECTED"
alv_test_assert_link_fixture_absent \
  "$ALV_TEST_CANONICAL_SOURCE_A" \
  "$ALV_TEST_RESTORE_REGULAR_MARKER" \
  "late-regular restore"
alv_test_expect_failure "restore accepted a regular late publication target" \
  env \
    ALV_TEST_LINK_MODE=late-regular \
    ALV_TEST_LINK_ROOT="$ALV_TEST_CANONICAL_WORK" \
    ALV_TEST_LINK_EXPECTED_DESTINATION="$ALV_TEST_CANONICAL_SOURCE_A" \
    ALV_TEST_LINK_MARKER="$ALV_TEST_RESTORE_REGULAR_MARKER" \
    PATH="$ALV_TEST_WRAPPER_BIN:$PATH" \
    "$ALV_TEST_CLI" restore "$ALV_TEST_ROLLOUT_A"
alv_test_assert_link_marker \
  "$ALV_TEST_RESTORE_REGULAR_MARKER" \
  "late-regular restore did not run the link wrapper"
alv_test_assert_failure_diagnostic \
  'refusing to overwrite a destination that appeared during publication' \
  "late-regular restore omitted the no-clobber diagnostic"
[ -f "$ALV_TEST_SOURCE_A" ] && [ ! -L "$ALV_TEST_SOURCE_A" ] && \
  cmp -s "$ALV_TEST_SOURCE_A" "$ALV_TEST_LATE_REGULAR_EXPECTED" || \
  alv_test_fail "restore changed the regular late publication target"
alv_test_assert_no_stage \
  "$ALV_TEST_CANONICAL_SOURCE_A" \
  "late-regular restore left a sibling publication stage"
alv_test_assert_cold_thread \
  "$ALV_TEST_ROLLOUT_A" \
  "late-regular restore changed the cold source"
unlink "$ALV_TEST_SOURCE_A"

ALV_TEST_RESTORE_DIRECTORY_MARKER=$ALV_TEST_CANONICAL_WORK/restore-late-directory.marker
alv_test_assert_link_fixture_absent \
  "$ALV_TEST_CANONICAL_SOURCE_A" \
  "$ALV_TEST_RESTORE_DIRECTORY_MARKER" \
  "late-directory restore"
alv_test_expect_failure "restore accepted a directory late publication target" \
  env \
    ALV_TEST_LINK_MODE=late-directory \
    ALV_TEST_LINK_ROOT="$ALV_TEST_CANONICAL_WORK" \
    ALV_TEST_LINK_EXPECTED_DESTINATION="$ALV_TEST_CANONICAL_SOURCE_A" \
    ALV_TEST_LINK_MARKER="$ALV_TEST_RESTORE_DIRECTORY_MARKER" \
    PATH="$ALV_TEST_WRAPPER_BIN:$PATH" \
    "$ALV_TEST_CLI" restore "$ALV_TEST_ROLLOUT_A"
alv_test_assert_link_marker \
  "$ALV_TEST_RESTORE_DIRECTORY_MARKER" \
  "late-directory restore did not run the link wrapper"
alv_test_assert_failure_diagnostic \
  'refusing to overwrite a destination that appeared during publication' \
  "late-directory restore omitted the no-clobber diagnostic"
[ -d "$ALV_TEST_SOURCE_A" ] && [ ! -L "$ALV_TEST_SOURCE_A" ] || \
  alv_test_fail "restore changed the directory late publication target"
alv_test_assert_empty_directory \
  "$ALV_TEST_SOURCE_A" \
  "restore redirected a stage into the late directory"
alv_test_assert_no_stage \
  "$ALV_TEST_CANONICAL_SOURCE_A" \
  "late-directory restore left a sibling publication stage"
alv_test_assert_cold_thread \
  "$ALV_TEST_ROLLOUT_A" \
  "late-directory restore changed the cold source"
rmdir "$ALV_TEST_SOURCE_A"

ALV_TEST_RESTORE_SYMLINK_MARKER=$ALV_TEST_CANONICAL_WORK/restore-late-symlink.marker
ALV_TEST_RESTORE_SYMLINK_DIRECTORY=$ALV_TEST_CANONICAL_WORK/restore-late-symlink-target
alv_test_assert_link_fixture_absent \
  "$ALV_TEST_CANONICAL_SOURCE_A" \
  "$ALV_TEST_RESTORE_SYMLINK_MARKER" \
  "late-symlink restore"
alv_test_assert_absent \
  "$ALV_TEST_RESTORE_SYMLINK_DIRECTORY" \
  "late-symlink restore target directory was not initially absent"
alv_test_expect_failure "restore accepted a symlink late publication target" \
  env \
    ALV_TEST_LINK_MODE=late-symlink-directory \
    ALV_TEST_LINK_ROOT="$ALV_TEST_CANONICAL_WORK" \
    ALV_TEST_LINK_EXPECTED_DESTINATION="$ALV_TEST_CANONICAL_SOURCE_A" \
    ALV_TEST_LINK_MARKER="$ALV_TEST_RESTORE_SYMLINK_MARKER" \
    ALV_TEST_LINK_SYMLINK_DIRECTORY="$ALV_TEST_RESTORE_SYMLINK_DIRECTORY" \
    PATH="$ALV_TEST_WRAPPER_BIN:$PATH" \
    "$ALV_TEST_CLI" restore "$ALV_TEST_ROLLOUT_A"
alv_test_assert_link_marker \
  "$ALV_TEST_RESTORE_SYMLINK_MARKER" \
  "late-symlink restore did not run the link wrapper"
alv_test_assert_failure_diagnostic \
  'refusing to overwrite a destination that appeared during publication' \
  "late-symlink restore omitted the no-clobber diagnostic"
[ -L "$ALV_TEST_SOURCE_A" ] && \
  [ "$(readlink "$ALV_TEST_SOURCE_A")" = \
    "$ALV_TEST_RESTORE_SYMLINK_DIRECTORY" ] || \
  alv_test_fail "restore changed the symlink late publication target"
alv_test_assert_empty_directory \
  "$ALV_TEST_RESTORE_SYMLINK_DIRECTORY" \
  "restore redirected a stage through the late symlink"
alv_test_assert_no_stage \
  "$ALV_TEST_CANONICAL_SOURCE_A" \
  "late-symlink restore left a sibling publication stage"
alv_test_assert_cold_thread \
  "$ALV_TEST_ROLLOUT_A" \
  "late-symlink restore changed the cold source"
unlink "$ALV_TEST_SOURCE_A"
rmdir "$ALV_TEST_RESTORE_SYMLINK_DIRECTORY"

ALV_TEST_RESTORE_REJECT_MARKER=$ALV_TEST_CANONICAL_WORK/restore-reject-link.marker
alv_test_assert_link_fixture_absent \
  "$ALV_TEST_CANONICAL_SOURCE_A" \
  "$ALV_TEST_RESTORE_REJECT_MARKER" \
  "rejected-link restore"
alv_test_expect_failure "restore fell back after exact link rejection" \
  env \
    ALV_TEST_LINK_MODE=reject-link \
    ALV_TEST_LINK_ROOT="$ALV_TEST_CANONICAL_WORK" \
    ALV_TEST_LINK_EXPECTED_DESTINATION="$ALV_TEST_CANONICAL_SOURCE_A" \
    ALV_TEST_LINK_MARKER="$ALV_TEST_RESTORE_REJECT_MARKER" \
    PATH="$ALV_TEST_WRAPPER_BIN:$PATH" \
    "$ALV_TEST_CLI" restore "$ALV_TEST_ROLLOUT_A"
alv_test_assert_link_marker \
  "$ALV_TEST_RESTORE_REJECT_MARKER" \
  "rejected-link restore did not run the link wrapper"
alv_test_assert_failure_diagnostic \
  'same-directory hard-link support is required' \
  "rejected-link restore omitted the exact-publication diagnostic"
alv_test_assert_absent \
  "$ALV_TEST_SOURCE_A" \
  "rejected-link restore created a destination"
alv_test_assert_no_stage \
  "$ALV_TEST_CANONICAL_SOURCE_A" \
  "rejected-link restore left a sibling publication stage"
alv_test_assert_cold_thread \
  "$ALV_TEST_ROLLOUT_A" \
  "rejected-link restore changed the cold source"

ALV_TEST_RESTORE_INTERRUPT_MARKER=$ALV_TEST_CANONICAL_WORK/restore-interrupt-link.marker
alv_test_assert_link_fixture_absent \
  "$ALV_TEST_CANONICAL_SOURCE_A" \
  "$ALV_TEST_RESTORE_INTERRUPT_MARKER" \
  "post-link interrupted restore"
alv_test_expect_status 143 \
  "post-link interrupted restore returned the wrong status" \
  env \
    ALV_TEST_LINK_MODE=interrupt-after-link \
    ALV_TEST_LINK_ROOT="$ALV_TEST_CANONICAL_WORK" \
    ALV_TEST_LINK_EXPECTED_DESTINATION="$ALV_TEST_CANONICAL_SOURCE_A" \
    ALV_TEST_LINK_MARKER="$ALV_TEST_RESTORE_INTERRUPT_MARKER" \
    PATH="$ALV_TEST_WRAPPER_BIN:$PATH" \
    "$ALV_TEST_CLI" restore "$ALV_TEST_ROLLOUT_A"
alv_test_assert_link_marker \
  "$ALV_TEST_RESTORE_INTERRUPT_MARKER" \
  "post-link interrupted restore did not deliver TERM" \
  link-wrapper-signal-sent
[ -f "$ALV_TEST_SOURCE_A" ] && [ ! -L "$ALV_TEST_SOURCE_A" ] && \
  cmp -s "$ALV_TEST_SOURCE_A" "$ALV_TEST_WORK/expected-a.jsonl" || \
  alv_test_fail "post-link interruption left an incomplete destination"
[ "$(alv_test_mode "$ALV_TEST_SOURCE_A")" = 600 ] || \
  alv_test_fail "post-link interrupted restore destination is not 0600"
alv_test_assert_no_stage \
  "$ALV_TEST_CANONICAL_SOURCE_A" \
  "post-link interrupted restore left a sibling publication stage"
alv_test_assert_cold_thread \
  "$ALV_TEST_ROLLOUT_A" \
  "post-link interrupted restore changed the cold source"
unlink "$ALV_TEST_SOURCE_A"

ALV_TEST_RESTORE_LEGACY_REDIRECT=$ALV_TEST_WORK/legacy-restore-redirected.jsonl
ALV_TEST_RESTORE_LEGACY_RECORD=$ALV_TEST_WORK/legacy-restore-stage.path
alv_test_assert_absent \
  "$ALV_TEST_SOURCE_A" \
  "legacy-symlink restore destination was not initially absent"
alv_test_assert_absent \
  "$ALV_TEST_RESTORE_LEGACY_REDIRECT" \
  "legacy-symlink restore redirect was not initially absent"
if ! sh -c '
  ALV_TEST_CHILD_DESTINATION=$1
  ALV_TEST_CHILD_REDIRECT=$2
  ALV_TEST_CHILD_RECORD=$3
  ALV_TEST_CHILD_CLI=$4
  ALV_TEST_CHILD_NAME=$5
  ALV_TEST_CHILD_STAGE=$ALV_TEST_CHILD_DESTINATION.partial.$$
  ln -s "$ALV_TEST_CHILD_REDIRECT" "$ALV_TEST_CHILD_STAGE"
  printf "%s\n" "$ALV_TEST_CHILD_STAGE" > "$ALV_TEST_CHILD_RECORD"
  exec "$ALV_TEST_CHILD_CLI" restore "$ALV_TEST_CHILD_NAME"
' alv-legacy-restore \
  "$ALV_TEST_SOURCE_A" \
  "$ALV_TEST_RESTORE_LEGACY_REDIRECT" \
  "$ALV_TEST_RESTORE_LEGACY_RECORD" \
  "$ALV_TEST_CLI" \
  "$ALV_TEST_ROLLOUT_A" \
  > "$ALV_TEST_WORK/restore-a.out" 2>&1; then
  alv_test_fail "restore failed with an unrelated legacy partial symlink"
fi
ALV_TEST_RESTORE_LEGACY_STAGE=$(sed -n '1p' \
  "$ALV_TEST_RESTORE_LEGACY_RECORD")
case "$ALV_TEST_RESTORE_LEGACY_STAGE" in
  "$ALV_TEST_SOURCE_A".partial.*) ;;
  *) alv_test_fail "legacy restore fixture recorded an unexpected stage path" ;;
esac
[ -L "$ALV_TEST_RESTORE_LEGACY_STAGE" ] && \
  [ "$(readlink "$ALV_TEST_RESTORE_LEGACY_STAGE")" = \
    "$ALV_TEST_RESTORE_LEGACY_REDIRECT" ] || \
  alv_test_fail "restore adopted the planted legacy partial symlink"
alv_test_assert_absent \
  "$ALV_TEST_RESTORE_LEGACY_REDIRECT" \
  "restore wrote through the planted legacy partial symlink"
[ -f "$ALV_TEST_SOURCE_A" ] && [ ! -L "$ALV_TEST_SOURCE_A" ] && \
  cmp -s "$ALV_TEST_SOURCE_A" "$ALV_TEST_WORK/expected-a.jsonl" || \
  alv_test_fail "legacy-symlink restore changed the exact JSONL bytes"
[ "$(alv_test_mode "$ALV_TEST_SOURCE_A")" = 600 ] || \
  alv_test_fail "legacy-symlink restore destination is not 0600"
unlink "$ALV_TEST_RESTORE_LEGACY_STAGE"
alv_test_assert_no_stage \
  "$ALV_TEST_CANONICAL_SOURCE_A" \
  "legacy-symlink restore left an additional publication stage"
cmp -s "$ALV_TEST_SOURCE_A" "$ALV_TEST_WORK/expected-a.jsonl" || \
  alv_test_fail "restore changed the exact JSONL bytes"
[ "$("$ALV_TEST_CLI" list cold)" = "$ALV_TEST_ROLLOUT_A" ] || \
  alv_test_fail "restore removed the cold copy"
"$ALV_TEST_CLI" verify "$ALV_TEST_ROLLOUT_A" \
  > "$ALV_TEST_WORK/verify-a-both.out"
rg -q 'both' "$ALV_TEST_WORK/verify-a-both.out" || \
  alv_test_fail "verify did not report the both state"

ALV_TEST_PLAN_JSON=$("$ALV_TEST_CLI" plan offload --json --vault cold)
[ "$(printf '%s\n' "$ALV_TEST_PLAN_JSON" | jq -r '.selected_threads')" = 3 ] || \
  alv_test_fail "offload plan counted the wrong local threads"
[ "$(printf '%s\n' "$ALV_TEST_PLAN_JSON" | jq -r '.cold_present_threads')" = 1 ] || \
  alv_test_fail "offload plan missed the existing cold copy"
[ "$(printf '%s\n' "$ALV_TEST_PLAN_JSON" | jq -r '.upload_required_threads')" = 2 ] || \
  alv_test_fail "offload plan counted upload candidates incorrectly"
[ "$(printf '%s\n' "$ALV_TEST_PLAN_JSON" | jq -r --arg name "$ALV_TEST_ROLLOUT_A" '.candidates[] | select(.name == $name) | .status')" = cold_present_unverified ] || \
  alv_test_fail "offload plan overstated cold verification"
[ -f "$ALV_TEST_SOURCE_A" ] && [ -f "$ALV_TEST_SOURCE_B" ] && \
  [ -f "$ALV_TEST_SOURCE_C" ] || \
  alv_test_fail "read-only offload plan changed a local source"

ALV_TEST_RCLONE_MODE=reject-upload PATH="$ALV_TEST_WRAPPER_BIN:$PATH" \
  "$ALV_TEST_CLI" offload "$ALV_TEST_ROLLOUT_A" \
  > "$ALV_TEST_WORK/repeat-offload-a.out"
[ ! -e "$ALV_TEST_SOURCE_A" ] || \
  alv_test_fail "repeat offload retained the matching local copy"

"$ALV_TEST_CLI" restore "$ALV_TEST_ROLLOUT_A" \
  > "$ALV_TEST_WORK/repeat-restore-a.out"
printf '%s\n' 'different local bytes' > "$ALV_TEST_SOURCE_A"
alv_test_expect_failure "restore overwrote a different local thread" \
  "$ALV_TEST_CLI" restore "$ALV_TEST_ROLLOUT_A"
[ "$(sed -n '1p' "$ALV_TEST_SOURCE_A")" = 'different local bytes' ] || \
  alv_test_fail "failed restore changed the different local file"
alv_test_assert_no_stage \
  "$ALV_TEST_CANONICAL_SOURCE_A" \
  "conflicting restore left a sibling publication stage"
alv_test_expect_failure "offload removed a local thread that differed from cold" \
  "$ALV_TEST_CLI" offload "$ALV_TEST_ROLLOUT_A"
[ "$(sed -n '1p' "$ALV_TEST_SOURCE_A")" = 'different local bytes' ] || \
  alv_test_fail "failed conflicting offload changed the local file"
cp "$ALV_TEST_WORK/expected-a.jsonl" "$ALV_TEST_SOURCE_A"

"$ALV_TEST_CLI" offload "$ALV_TEST_ROLLOUT_B" \
  > "$ALV_TEST_WORK/offload-b.out"
printf '%s\n' 'corrupted but valid encrypted replacement' > "$ALV_TEST_WORK/corruption.jsonl"
rclone copyto \
  "$ALV_TEST_WORK/corruption.jsonl" \
  "alv-cold-crypt:archived_sessions/$ALV_TEST_ROLLOUT_B" \
  --no-check-dest \
  --quiet
alv_test_expect_failure "verify accepted corrupted cold bytes" \
  "$ALV_TEST_CLI" verify "$ALV_TEST_ROLLOUT_B"
alv_test_expect_failure "restore accepted corrupted cold bytes" \
  "$ALV_TEST_CLI" restore "$ALV_TEST_ROLLOUT_B"
alv_test_assert_absent \
  "$ALV_TEST_SOURCE_B" \
  "failed corrupted restore created a local thread"
alv_test_assert_no_stage \
  "$ALV_TEST_CANONICAL_SOURCE_B" \
  "failed corrupted restore left a sibling publication stage"

alv_test_expect_failure "interrupted upload reported success" \
  env ALV_TEST_RCLONE_MODE=interrupt-upload \
    PATH="$ALV_TEST_WRAPPER_BIN:$PATH" \
    "$ALV_TEST_CLI" offload "$ALV_TEST_ROLLOUT_C"
[ -f "$ALV_TEST_SOURCE_C" ] || \
  alv_test_fail "interrupted offload removed its source"
if "$ALV_TEST_CLI" list cold | grep -Fqx "$ALV_TEST_ROLLOUT_C"; then
  alv_test_fail "interrupted upload appeared as a completed cold thread"
fi

rclone copyto \
  "$ALV_TEST_SOURCE_C" \
  "alv-cold-crypt:archived_sessions/$ALV_TEST_ROLLOUT_C" \
  --immutable \
  --quiet
if "$ALV_TEST_CLI" list cold | grep -Fqx "$ALV_TEST_ROLLOUT_C"; then
  alv_test_fail "data without a checksum appeared complete"
fi
ALV_TEST_PLAN_JSON=$("$ALV_TEST_CLI" plan offload \
  --json --project rclone-test --vault cold)
[ "$(printf '%s\n' "$ALV_TEST_PLAN_JSON" | jq -r --arg name "$ALV_TEST_ROLLOUT_C" '.candidates[] | select(.name == $name) | .status')" = conflict_incomplete_data ] || \
  alv_test_fail "offload plan missed an incomplete cold object"
[ "$(printf '%s\n' "$ALV_TEST_PLAN_JSON" | jq -r '.conflict_threads')" -ge 1 ] || \
  alv_test_fail "offload plan omitted its conflict count"
[ -f "$ALV_TEST_SOURCE_C" ] || \
  alv_test_fail "conflict planning changed the local source"
"$ALV_TEST_CLI" offload "$ALV_TEST_ROLLOUT_C" \
  > "$ALV_TEST_WORK/resume-offload-c.out"
[ ! -e "$ALV_TEST_SOURCE_C" ] || \
  alv_test_fail "resumed offload retained its source"

alv_test_expect_failure "active thread path was accepted by offload" \
  "$ALV_TEST_CLI" offload "$ALV_TEST_ACTIVE_SOURCE"
[ -f "$ALV_TEST_ACTIVE_SOURCE" ] || \
  alv_test_fail "active thread rejection changed the active source"
alv_test_expect_failure "a different archived_sessions tree was accepted implicitly" \
  "$ALV_TEST_CLI" offload "$ALV_TEST_OTHER_SOURCE"
[ -f "$ALV_TEST_OTHER_SOURCE" ] || \
  alv_test_fail "rejected alternate Codex source was changed"

rclone config create unsafe-crypt crypt \
  remote "$ALV_TEST_UNSAFE_BACKING" \
  filename_encryption standard \
  directory_name_encryption true \
  no_data_encryption true \
  password disposable-secret \
  password2 disposable-salt \
  --obscure \
  --no-output
alv_test_expect_failure "unencrypted crypt remote was accepted" \
  "$ALV_TEST_CLI" vault add rclone unsafe --remote unsafe-crypt:
[ ! -e "$ALV_CONFIG_HOME/vaults/unsafe" ] || \
  alv_test_fail "rejected crypt remote left a vault profile"

ALV_TEST_RECOVERY=$ALV_TEST_WORK/recovery.conf
ALV_TEST_CANONICAL_RECOVERY=$ALV_TEST_CANONICAL_WORK/recovery.conf
ALV_TEST_RCLONE_CONFIG_SNAPSHOT=$ALV_TEST_WORK/rclone-before-recovery.conf
cp "$RCLONE_CONFIG" "$ALV_TEST_RCLONE_CONFIG_SNAPSHOT"

ALV_TEST_RECOVERY_REGULAR_MARKER=$ALV_TEST_CANONICAL_WORK/recovery-late-regular.marker
ALV_TEST_RECOVERY_REGULAR_EXPECTED=$ALV_TEST_WORK/recovery-late-regular.expected
printf '%s\n' 'late-regular-target' > "$ALV_TEST_RECOVERY_REGULAR_EXPECTED"
alv_test_assert_link_fixture_absent \
  "$ALV_TEST_CANONICAL_RECOVERY" \
  "$ALV_TEST_RECOVERY_REGULAR_MARKER" \
  "late-regular recovery"
alv_test_expect_failure "recovery accepted a regular late publication target" \
  env \
    ALV_TEST_LINK_MODE=late-regular \
    ALV_TEST_LINK_ROOT="$ALV_TEST_CANONICAL_WORK" \
    ALV_TEST_LINK_EXPECTED_DESTINATION="$ALV_TEST_CANONICAL_RECOVERY" \
    ALV_TEST_LINK_MARKER="$ALV_TEST_RECOVERY_REGULAR_MARKER" \
    PATH="$ALV_TEST_WRAPPER_BIN:$PATH" \
    "$ALV_TEST_CLI" vault recovery cold --output "$ALV_TEST_RECOVERY"
alv_test_assert_link_marker \
  "$ALV_TEST_RECOVERY_REGULAR_MARKER" \
  "late-regular recovery did not run the link wrapper"
alv_test_assert_failure_diagnostic \
  'refusing to overwrite a destination that appeared during publication' \
  "late-regular recovery omitted the no-clobber diagnostic"
[ -f "$ALV_TEST_RECOVERY" ] && [ ! -L "$ALV_TEST_RECOVERY" ] && \
  cmp -s "$ALV_TEST_RECOVERY" "$ALV_TEST_RECOVERY_REGULAR_EXPECTED" || \
  alv_test_fail "recovery changed the regular late publication target"
alv_test_assert_no_stage \
  "$ALV_TEST_CANONICAL_RECOVERY" \
  "late-regular recovery left a sibling publication stage"
cmp -s "$RCLONE_CONFIG" "$ALV_TEST_RCLONE_CONFIG_SNAPSHOT" || \
  alv_test_fail "late-regular recovery changed the source rclone config"
unlink "$ALV_TEST_RECOVERY"

ALV_TEST_RECOVERY_DIRECTORY_MARKER=$ALV_TEST_CANONICAL_WORK/recovery-late-directory.marker
alv_test_assert_link_fixture_absent \
  "$ALV_TEST_CANONICAL_RECOVERY" \
  "$ALV_TEST_RECOVERY_DIRECTORY_MARKER" \
  "late-directory recovery"
alv_test_expect_failure "recovery accepted a directory late publication target" \
  env \
    ALV_TEST_LINK_MODE=late-directory \
    ALV_TEST_LINK_ROOT="$ALV_TEST_CANONICAL_WORK" \
    ALV_TEST_LINK_EXPECTED_DESTINATION="$ALV_TEST_CANONICAL_RECOVERY" \
    ALV_TEST_LINK_MARKER="$ALV_TEST_RECOVERY_DIRECTORY_MARKER" \
    PATH="$ALV_TEST_WRAPPER_BIN:$PATH" \
    "$ALV_TEST_CLI" vault recovery cold --output "$ALV_TEST_RECOVERY"
alv_test_assert_link_marker \
  "$ALV_TEST_RECOVERY_DIRECTORY_MARKER" \
  "late-directory recovery did not run the link wrapper"
alv_test_assert_failure_diagnostic \
  'refusing to overwrite a destination that appeared during publication' \
  "late-directory recovery omitted the no-clobber diagnostic"
[ -d "$ALV_TEST_RECOVERY" ] && [ ! -L "$ALV_TEST_RECOVERY" ] || \
  alv_test_fail "recovery changed the directory late publication target"
alv_test_assert_empty_directory \
  "$ALV_TEST_RECOVERY" \
  "recovery redirected a stage into the late directory"
alv_test_assert_no_stage \
  "$ALV_TEST_CANONICAL_RECOVERY" \
  "late-directory recovery left a sibling publication stage"
cmp -s "$RCLONE_CONFIG" "$ALV_TEST_RCLONE_CONFIG_SNAPSHOT" || \
  alv_test_fail "late-directory recovery changed the source rclone config"
rmdir "$ALV_TEST_RECOVERY"

ALV_TEST_RECOVERY_SYMLINK_MARKER=$ALV_TEST_CANONICAL_WORK/recovery-late-symlink.marker
ALV_TEST_RECOVERY_SYMLINK_DIRECTORY=$ALV_TEST_CANONICAL_WORK/recovery-late-symlink-target
alv_test_assert_link_fixture_absent \
  "$ALV_TEST_CANONICAL_RECOVERY" \
  "$ALV_TEST_RECOVERY_SYMLINK_MARKER" \
  "late-symlink recovery"
alv_test_assert_absent \
  "$ALV_TEST_RECOVERY_SYMLINK_DIRECTORY" \
  "late-symlink recovery target directory was not initially absent"
alv_test_expect_failure "recovery accepted a symlink late publication target" \
  env \
    ALV_TEST_LINK_MODE=late-symlink-directory \
    ALV_TEST_LINK_ROOT="$ALV_TEST_CANONICAL_WORK" \
    ALV_TEST_LINK_EXPECTED_DESTINATION="$ALV_TEST_CANONICAL_RECOVERY" \
    ALV_TEST_LINK_MARKER="$ALV_TEST_RECOVERY_SYMLINK_MARKER" \
    ALV_TEST_LINK_SYMLINK_DIRECTORY="$ALV_TEST_RECOVERY_SYMLINK_DIRECTORY" \
    PATH="$ALV_TEST_WRAPPER_BIN:$PATH" \
    "$ALV_TEST_CLI" vault recovery cold --output "$ALV_TEST_RECOVERY"
alv_test_assert_link_marker \
  "$ALV_TEST_RECOVERY_SYMLINK_MARKER" \
  "late-symlink recovery did not run the link wrapper"
alv_test_assert_failure_diagnostic \
  'refusing to overwrite a destination that appeared during publication' \
  "late-symlink recovery omitted the no-clobber diagnostic"
[ -L "$ALV_TEST_RECOVERY" ] && \
  [ "$(readlink "$ALV_TEST_RECOVERY")" = \
    "$ALV_TEST_RECOVERY_SYMLINK_DIRECTORY" ] || \
  alv_test_fail "recovery changed the symlink late publication target"
alv_test_assert_empty_directory \
  "$ALV_TEST_RECOVERY_SYMLINK_DIRECTORY" \
  "recovery redirected a stage through the late symlink"
alv_test_assert_no_stage \
  "$ALV_TEST_CANONICAL_RECOVERY" \
  "late-symlink recovery left a sibling publication stage"
cmp -s "$RCLONE_CONFIG" "$ALV_TEST_RCLONE_CONFIG_SNAPSHOT" || \
  alv_test_fail "late-symlink recovery changed the source rclone config"
unlink "$ALV_TEST_RECOVERY"
rmdir "$ALV_TEST_RECOVERY_SYMLINK_DIRECTORY"

ALV_TEST_RECOVERY_REJECT=$ALV_TEST_WORK/recovery-reject.conf
ALV_TEST_CANONICAL_RECOVERY_REJECT=$ALV_TEST_CANONICAL_WORK/recovery-reject.conf
ALV_TEST_RECOVERY_REJECT_MARKER=$ALV_TEST_CANONICAL_WORK/recovery-reject-link.marker
alv_test_assert_link_fixture_absent \
  "$ALV_TEST_CANONICAL_RECOVERY_REJECT" \
  "$ALV_TEST_RECOVERY_REJECT_MARKER" \
  "rejected-link recovery"
alv_test_expect_failure "recovery fell back after exact link rejection" \
  env \
    ALV_TEST_LINK_MODE=reject-link \
    ALV_TEST_LINK_ROOT="$ALV_TEST_CANONICAL_WORK" \
    ALV_TEST_LINK_EXPECTED_DESTINATION="$ALV_TEST_CANONICAL_RECOVERY_REJECT" \
    ALV_TEST_LINK_MARKER="$ALV_TEST_RECOVERY_REJECT_MARKER" \
    PATH="$ALV_TEST_WRAPPER_BIN:$PATH" \
    "$ALV_TEST_CLI" vault recovery cold --output "$ALV_TEST_RECOVERY_REJECT"
alv_test_assert_link_marker \
  "$ALV_TEST_RECOVERY_REJECT_MARKER" \
  "rejected-link recovery did not run the link wrapper"
alv_test_assert_failure_diagnostic \
  'same-directory hard-link support is required' \
  "rejected-link recovery omitted the exact-publication diagnostic"
alv_test_assert_absent \
  "$ALV_TEST_RECOVERY_REJECT" \
  "rejected-link recovery created an output"
alv_test_assert_no_stage \
  "$ALV_TEST_CANONICAL_RECOVERY_REJECT" \
  "rejected-link recovery left a sibling publication stage"
cmp -s "$RCLONE_CONFIG" "$ALV_TEST_RCLONE_CONFIG_SNAPSHOT" || \
  alv_test_fail "rejected-link recovery changed the source rclone config"

ALV_TEST_RECOVERY_LEGACY_REDIRECT=$ALV_TEST_WORK/legacy-recovery-redirected.conf
ALV_TEST_RECOVERY_LEGACY_RECORD=$ALV_TEST_WORK/legacy-recovery-stage.path
alv_test_assert_absent \
  "$ALV_TEST_RECOVERY" \
  "legacy-symlink recovery output was not initially absent"
alv_test_assert_absent \
  "$ALV_TEST_RECOVERY_LEGACY_REDIRECT" \
  "legacy-symlink recovery redirect was not initially absent"
if ! sh -c '
  ALV_TEST_CHILD_OUTPUT=$1
  ALV_TEST_CHILD_REDIRECT=$2
  ALV_TEST_CHILD_RECORD=$3
  ALV_TEST_CHILD_CLI=$4
  ALV_TEST_CHILD_STAGE=$ALV_TEST_CHILD_OUTPUT.partial.$$
  ln -s "$ALV_TEST_CHILD_REDIRECT" "$ALV_TEST_CHILD_STAGE"
  printf "%s\n" "$ALV_TEST_CHILD_STAGE" > "$ALV_TEST_CHILD_RECORD"
  exec "$ALV_TEST_CHILD_CLI" vault recovery cold --output "$ALV_TEST_CHILD_OUTPUT"
' alv-legacy-recovery \
  "$ALV_TEST_RECOVERY" \
  "$ALV_TEST_RECOVERY_LEGACY_REDIRECT" \
  "$ALV_TEST_RECOVERY_LEGACY_RECORD" \
  "$ALV_TEST_CLI" \
  > "$ALV_TEST_WORK/recovery.out" 2>&1; then
  alv_test_fail "recovery failed with an unrelated legacy partial symlink"
fi
ALV_TEST_RECOVERY_LEGACY_STAGE=$(sed -n '1p' \
  "$ALV_TEST_RECOVERY_LEGACY_RECORD")
case "$ALV_TEST_RECOVERY_LEGACY_STAGE" in
  "$ALV_TEST_RECOVERY".partial.*) ;;
  *) alv_test_fail "legacy recovery fixture recorded an unexpected stage path" ;;
esac
[ -L "$ALV_TEST_RECOVERY_LEGACY_STAGE" ] && \
  [ "$(readlink "$ALV_TEST_RECOVERY_LEGACY_STAGE")" = \
    "$ALV_TEST_RECOVERY_LEGACY_REDIRECT" ] || \
  alv_test_fail "recovery adopted the planted legacy partial symlink"
alv_test_assert_absent \
  "$ALV_TEST_RECOVERY_LEGACY_REDIRECT" \
  "recovery wrote through the planted legacy partial symlink"
[ -f "$ALV_TEST_RECOVERY" ] && [ ! -L "$ALV_TEST_RECOVERY" ] || \
  alv_test_fail "legacy-symlink recovery did not publish a regular output"
cmp -s "$RCLONE_CONFIG" "$ALV_TEST_RCLONE_CONFIG_SNAPSHOT" || \
  alv_test_fail "legacy-symlink recovery changed the source rclone config"
[ "$(alv_test_mode "$ALV_TEST_RECOVERY")" = 600 ] || \
  alv_test_fail "recovery export permissions are not 0600"
unlink "$ALV_TEST_RECOVERY_LEGACY_STAGE"
alv_test_assert_no_stage \
  "$ALV_TEST_CANONICAL_RECOVERY" \
  "legacy-symlink recovery left an additional publication stage"
mv "$RCLONE_CONFIG" "$ALV_TEST_WORK/original-rclone.conf.unavailable"

RCLONE_CONFIG=$ALV_TEST_RECOVERY
ALV_CONFIG_HOME=$ALV_TEST_WORK/clean-config
CODEX_HOME=$ALV_TEST_CLEAN_HOME
export RCLONE_CONFIG ALV_CONFIG_HOME CODEX_HOME
"$ALV_TEST_CLI" vault add rclone recovered --remote alv-cold-crypt: \
  > "$ALV_TEST_WORK/recover-profile.out"
"$ALV_TEST_CLI" restore "$ALV_TEST_ROLLOUT_A" \
  > "$ALV_TEST_WORK/clean-restore-a.out"
cmp -s \
  "$ALV_TEST_CLEAN_HOME/archived_sessions/$ALV_TEST_ROLLOUT_A" \
  "$ALV_TEST_WORK/expected-a.jsonl" || \
  alv_test_fail "clean-room recovery changed the original bytes"

for ALV_TEST_TEMP in "$ALV_TEST_RUNTIME_TMP"/agent-log-vault-rclone.*; do
  [ ! -e "$ALV_TEST_TEMP" ] || \
    alv_test_fail "rclone left a plaintext temporary directory"
done
for ALV_TEST_TEMP in "$ALV_TEST_RUNTIME_TMP"/agent-log-vault-setup.*; do
  [ ! -e "$ALV_TEST_TEMP" ] || \
    alv_test_fail "vault setup left a temporary directory"
done
for ALV_TEST_TEMP in "$ALV_TEST_RUNTIME_TMP"/agent-log-vault-catalog.*; do
  [ ! -e "$ALV_TEST_TEMP" ] || \
    alv_test_fail "planning left a private temporary directory"
done

printf 'all encrypted vault tests passed\n'
