#!/bin/sh

set -eu

ALV_TEST_ROOT_DIR=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
ALV_TEST_CLI=$ALV_TEST_ROOT_DIR/agent-log-vault
ALV_TEST_TMP_BASE=${TMPDIR:-/tmp}
ALV_TEST_WORK=$(mktemp -d "$ALV_TEST_TMP_BASE/agent-log-vault-test.XXXXXX")
ALV_TEST_RUNTIME_TMP=$ALV_TEST_WORK/runtime-tmp
mkdir -p "$ALV_TEST_RUNTIME_TMP"
TMPDIR=$ALV_TEST_RUNTIME_TMP
export TMPDIR

alv_test_fail() {
  printf 'test failure: %s\n' "$*" >&2
  exit 1
}

alv_test_cleanup() {
  case "$ALV_TEST_WORK" in
    "$ALV_TEST_TMP_BASE"/agent-log-vault-test.*)
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

alv_test_mode() {
  if ALV_TEST_MODE_VALUE=$(stat -f '%Lp' "$1" 2>/dev/null); then
    printf '%s\n' "$ALV_TEST_MODE_VALUE"
  else
    stat -c '%a' "$1"
  fi
}

alv_test_write_rollout() {
  ALV_TEST_WRITE_PATH=$1
  ALV_TEST_WRITE_ID=$2
  ALV_TEST_WRITE_TIMESTAMP=$3
  ALV_TEST_WRITE_CWD=$4
  ALV_TEST_WRITE_PAYLOAD_SIZE=$5

  jq -cn \
    --arg id "$ALV_TEST_WRITE_ID" \
    --arg timestamp "$ALV_TEST_WRITE_TIMESTAMP" \
    --arg cwd "$ALV_TEST_WRITE_CWD" '
      {
        timestamp: $timestamp,
        type: "session_meta",
        payload: {
          id: $id,
          timestamp: $timestamp,
          cwd: $cwd,
          originator: "agent-log-vault-test",
          cli_version: "0.test",
          model_provider: "test",
          source: "test",
          base_instructions: null
        }
      }
    ' > "$ALV_TEST_WRITE_PATH"

  printf '%s' '{"type":"test","payload":"' >> "$ALV_TEST_WRITE_PATH"
  ALV_TEST_WRITE_INDEX=0
  while [ "$ALV_TEST_WRITE_INDEX" -lt "$ALV_TEST_WRITE_PAYLOAD_SIZE" ]; do
    printf 'x' >> "$ALV_TEST_WRITE_PATH"
    ALV_TEST_WRITE_INDEX=$((ALV_TEST_WRITE_INDEX + 1))
  done
  printf '%s\n' '"}' >> "$ALV_TEST_WRITE_PATH"
}

trap alv_test_cleanup EXIT HUP INT TERM

ALV_TEST_SOURCE_HOME="$ALV_TEST_WORK/source codex home"
ALV_TEST_RESTORE_HOME="$ALV_TEST_WORK/restore codex home"
ALV_TEST_VAULT="$ALV_TEST_WORK/vault root"
ALV_TEST_EMPTY_VAULT="$ALV_TEST_WORK/empty vault"
ALV_TEST_BROKEN_VAULT="$ALV_TEST_WORK/broken vault"
ALV_TEST_MISMATCH_HOME="$ALV_TEST_WORK/mismatch codex home"
ALV_TEST_MISMATCH_VAULT="$ALV_TEST_WORK/mismatch vault"
ALV_TEST_UNSAFE_VAULT="$ALV_TEST_SOURCE_HOME/unsafe vault"
ALV_TEST_SYMLINK_VAULT="$ALV_TEST_WORK/symlink vault"
ALV_TEST_SYMLINK_ESCAPE="$ALV_TEST_WORK/symlink escape"
ALV_TEST_OVERLAP_HOME="$ALV_TEST_VAULT/nested codex home"
ALV_TEST_INVALID_HOME="$ALV_TEST_WORK/invalid codex home"

ALV_TEST_ROLLOUT_A=rollout-2026-01-02T03-04-05-00000000-0000-0000-0000-000000000000.jsonl
ALV_TEST_ROLLOUT_B=rollout-2026-01-03T03-04-05-11111111-1111-1111-1111-111111111111.jsonl
ALV_TEST_ROLLOUT_LINK=rollout-2026-01-04T03-04-05-22222222-2222-2222-2222-222222222222.jsonl

mkdir -p \
  "$ALV_TEST_SOURCE_HOME/archived_sessions" \
  "$ALV_TEST_RESTORE_HOME" \
  "$ALV_TEST_VAULT" \
  "$ALV_TEST_EMPTY_VAULT" \
  "$ALV_TEST_BROKEN_VAULT/archived_sessions" \
  "$ALV_TEST_MISMATCH_HOME/archived_sessions" \
  "$ALV_TEST_MISMATCH_VAULT" \
  "$ALV_TEST_UNSAFE_VAULT" \
  "$ALV_TEST_SYMLINK_VAULT" \
  "$ALV_TEST_SYMLINK_ESCAPE" \
  "$ALV_TEST_OVERLAP_HOME" \
  "$ALV_TEST_INVALID_HOME/archived_sessions"

ln -s "$ALV_TEST_CLI" "$ALV_TEST_WORK/agent-log-vault-link"
"$ALV_TEST_WORK/agent-log-vault-link" --help > "$ALV_TEST_WORK/symlink-help.out"

ALV_TEST_SOURCE_A=$ALV_TEST_SOURCE_HOME/archived_sessions/$ALV_TEST_ROLLOUT_A
ALV_TEST_SOURCE_B=$ALV_TEST_SOURCE_HOME/archived_sessions/$ALV_TEST_ROLLOUT_B
alv_test_write_rollout \
  "$ALV_TEST_SOURCE_A" \
  00000000-0000-0000-0000-000000000000 \
  2026-01-02T03:04:05.000Z \
  '/workspace/project alpha' \
  10
alv_test_write_rollout \
  "$ALV_TEST_SOURCE_B" \
  11111111-1111-1111-1111-111111111111 \
  2026-01-03T03:04:05.000Z \
  '/workspace/project beta' \
  1000

ALV_TEST_EXPECTED_CODEX_LIST=$(printf '%s\n%s' "$ALV_TEST_ROLLOUT_A" "$ALV_TEST_ROLLOUT_B")
ALV_TEST_ACTUAL_CODEX_LIST=$("$ALV_TEST_CLI" list codex --codex-home "$ALV_TEST_SOURCE_HOME")
[ "$ALV_TEST_ACTUAL_CODEX_LIST" = "$ALV_TEST_EXPECTED_CODEX_LIST" ] || \
  alv_test_fail "Codex listing did not return the expected chats"

"$ALV_TEST_CLI" inspect "$ALV_TEST_ROLLOUT_A" \
  --codex-home "$ALV_TEST_SOURCE_HOME" > "$ALV_TEST_WORK/inspect.out"
rg -q "^name[[:space:]]+$ALV_TEST_ROLLOUT_A$" "$ALV_TEST_WORK/inspect.out" || \
  alv_test_fail "inspect did not report the exact chat name"
rg -q '^id[[:space:]]+00000000-0000-0000-0000-000000000000$' \
  "$ALV_TEST_WORK/inspect.out" || alv_test_fail "inspect did not report the thread ID"
rg -q '^project[[:space:]]+project alpha$' "$ALV_TEST_WORK/inspect.out" || \
  alv_test_fail "inspect did not report the project"

"$ALV_TEST_CLI" list codex --long \
  --codex-home "$ALV_TEST_SOURCE_HOME" > "$ALV_TEST_WORK/long-list.out"
rg -q '^CREATED[[:space:]]+BYTES[[:space:]]+CWD[[:space:]]+CHAT$' \
  "$ALV_TEST_WORK/long-list.out" || alv_test_fail "long listing has no header"
rg -q "$ALV_TEST_ROLLOUT_A$" "$ALV_TEST_WORK/long-list.out" || \
  alv_test_fail "long listing omitted the first chat"
rg -q "$ALV_TEST_ROLLOUT_B$" "$ALV_TEST_WORK/long-list.out" || \
  alv_test_fail "long listing omitted the second chat"

ALV_TEST_FILTERED=$("$ALV_TEST_CLI" list codex \
  --created-before 2026-01-03 \
  --codex-home "$ALV_TEST_SOURCE_HOME")
[ "$ALV_TEST_FILTERED" = "$ALV_TEST_ROLLOUT_A" ] || \
  alv_test_fail "created-before selected the wrong chats"

ALV_TEST_FILTERED=$("$ALV_TEST_CLI" list codex \
  --created-after 2026-01-02 \
  --codex-home "$ALV_TEST_SOURCE_HOME")
[ "$ALV_TEST_FILTERED" = "$ALV_TEST_ROLLOUT_B" ] || \
  alv_test_fail "created-after selected the wrong chats"

ALV_TEST_FILTERED=$("$ALV_TEST_CLI" list codex \
  --project 'project alpha' \
  --codex-home "$ALV_TEST_SOURCE_HOME")
[ "$ALV_TEST_FILTERED" = "$ALV_TEST_ROLLOUT_A" ] || \
  alv_test_fail "project basename selected the wrong chats"

ALV_TEST_FILTERED=$("$ALV_TEST_CLI" list codex \
  --project '/workspace/project beta' \
  --codex-home "$ALV_TEST_SOURCE_HOME")
[ "$ALV_TEST_FILTERED" = "$ALV_TEST_ROLLOUT_B" ] || \
  alv_test_fail "exact cwd selected the wrong chats"

ALV_TEST_SOURCE_A_SIZE=$(stat -f '%z' "$ALV_TEST_SOURCE_A" 2>/dev/null || \
  stat -c '%s' "$ALV_TEST_SOURCE_A")
ALV_TEST_FILTERED=$("$ALV_TEST_CLI" list codex \
  --larger-than "$ALV_TEST_SOURCE_A_SIZE" \
  --codex-home "$ALV_TEST_SOURCE_HOME")
[ "$ALV_TEST_FILTERED" = "$ALV_TEST_ROLLOUT_B" ] || \
  alv_test_fail "larger-than selected the wrong chats"

alv_test_expect_failure "invalid discovery date was accepted" \
  "$ALV_TEST_CLI" list codex --created-before 2026-13-01 \
    --codex-home "$ALV_TEST_SOURCE_HOME"
alv_test_expect_failure "invalid discovery size was accepted" \
  "$ALV_TEST_CLI" list codex --larger-than 10MB \
    --codex-home "$ALV_TEST_SOURCE_HOME"

ALV_TEST_INVALID_ROLLOUT=$ALV_TEST_INVALID_HOME/archived_sessions/rollout-2026-01-05T03-04-05-33333333-3333-3333-3333-333333333333.jsonl
printf '%s\n' '{"type":"not-session-meta"}' > "$ALV_TEST_INVALID_ROLLOUT"
alv_test_expect_failure "invalid first metadata record was accepted" \
  "$ALV_TEST_CLI" list codex --long --codex-home "$ALV_TEST_INVALID_HOME"

for ALV_TEST_CATALOG_TEMP in "$ALV_TEST_RUNTIME_TMP"/agent-log-vault-catalog.*; do
  [ ! -e "$ALV_TEST_CATALOG_TEMP" ] || \
    alv_test_fail "catalog left a temporary FIFO directory"
done

"$ALV_TEST_CLI" list "file:$ALV_TEST_EMPTY_VAULT" > "$ALV_TEST_WORK/empty-list.out"
[ ! -s "$ALV_TEST_WORK/empty-list.out" ] || alv_test_fail "empty vault listing was not empty"

"$ALV_TEST_CLI" put "$ALV_TEST_ROLLOUT_A" \
  --to "file:$ALV_TEST_VAULT" \
  --codex-home "$ALV_TEST_SOURCE_HOME" > "$ALV_TEST_WORK/put.out"

ALV_TEST_VAULTED_A=$ALV_TEST_VAULT/archived_sessions/$ALV_TEST_ROLLOUT_A
[ -f "$ALV_TEST_VAULTED_A" ] || alv_test_fail "put did not create the stored chat"
[ -f "$ALV_TEST_VAULTED_A.sha256" ] || alv_test_fail "put did not create the checksum"
[ "$(alv_test_mode "$ALV_TEST_VAULTED_A")" = 600 ] || \
  alv_test_fail "stored chat permissions are not 0600"
[ "$(alv_test_mode "$ALV_TEST_VAULTED_A.sha256")" = 600 ] || \
  alv_test_fail "stored checksum permissions are not 0600"
cmp -s "$ALV_TEST_SOURCE_A" "$ALV_TEST_VAULTED_A" || \
  alv_test_fail "stored bytes differ from the Codex source"

ALV_TEST_VAULT_LIST=$("$ALV_TEST_CLI" list "file:$ALV_TEST_VAULT")
[ "$ALV_TEST_VAULT_LIST" = "$ALV_TEST_ROLLOUT_A" ] || \
  alv_test_fail "vault listing did not return the stored chat"

"$ALV_TEST_CLI" verify "$ALV_TEST_ROLLOUT_A" \
  --at "file:$ALV_TEST_VAULT" > "$ALV_TEST_WORK/verify.out"

alv_test_expect_failure "put overwrote an existing chat" \
  "$ALV_TEST_CLI" put "$ALV_TEST_SOURCE_A" --to "file:$ALV_TEST_VAULT"

alv_test_expect_failure "relative file location was accepted" \
  "$ALV_TEST_CLI" list file:relative/path

alv_test_expect_failure "unknown storage adapter was accepted" \
  "$ALV_TEST_CLI" list r2:example

alv_test_expect_failure "vault inside Codex home was accepted" \
  "$ALV_TEST_CLI" put "$ALV_TEST_SOURCE_B" --to "file:$ALV_TEST_UNSAFE_VAULT"
[ ! -e "$ALV_TEST_UNSAFE_VAULT/archived_sessions" ] || \
  alv_test_fail "rejected unsafe vault was modified"

ALV_TEST_BROKEN_A=$ALV_TEST_BROKEN_VAULT/archived_sessions/$ALV_TEST_ROLLOUT_A
cp "$ALV_TEST_VAULTED_A" "$ALV_TEST_BROKEN_A"
cp "$ALV_TEST_VAULTED_A.sha256" "$ALV_TEST_BROKEN_A.sha256"
printf '%s\n' 'corruption' >> "$ALV_TEST_BROKEN_A"

alv_test_expect_failure "verify accepted corrupted stored bytes" \
  "$ALV_TEST_CLI" verify "$ALV_TEST_ROLLOUT_A" --at "file:$ALV_TEST_BROKEN_VAULT"

alv_test_expect_failure "evict accepted corrupted storage" \
  "$ALV_TEST_CLI" evict "$ALV_TEST_ROLLOUT_A" \
    --codex-home "$ALV_TEST_SOURCE_HOME" \
    --verified-at "file:$ALV_TEST_BROKEN_VAULT" \
    --yes
[ -f "$ALV_TEST_SOURCE_A" ] || alv_test_fail "failed eviction removed the Codex source"

ALV_TEST_MISMATCH_A=$ALV_TEST_MISMATCH_HOME/archived_sessions/$ALV_TEST_ROLLOUT_A
alv_test_write_rollout \
  "$ALV_TEST_MISMATCH_A" \
  00000000-0000-0000-0000-000000000000 \
  2026-01-02T03:04:05.000Z \
  '/workspace/different project' \
  20
"$ALV_TEST_CLI" put "$ALV_TEST_MISMATCH_A" \
  --to "file:$ALV_TEST_MISMATCH_VAULT" > "$ALV_TEST_WORK/mismatch-put.out"

alv_test_expect_failure "evict accepted a different valid stored chat" \
  "$ALV_TEST_CLI" evict "$ALV_TEST_ROLLOUT_A" \
    --codex-home "$ALV_TEST_SOURCE_HOME" \
    --verified-at "file:$ALV_TEST_MISMATCH_VAULT" \
    --yes
[ -f "$ALV_TEST_SOURCE_A" ] || alv_test_fail "mismatch eviction removed the Codex source"

"$ALV_TEST_CLI" restore "$ALV_TEST_ROLLOUT_A" \
  --from "file:$ALV_TEST_VAULT" \
  --codex-home "$ALV_TEST_RESTORE_HOME" > "$ALV_TEST_WORK/restore.out"

ALV_TEST_RESTORED_A=$ALV_TEST_RESTORE_HOME/archived_sessions/$ALV_TEST_ROLLOUT_A
[ -f "$ALV_TEST_RESTORED_A" ] || alv_test_fail "restore did not create the Codex chat"
cmp -s "$ALV_TEST_SOURCE_A" "$ALV_TEST_RESTORED_A" || \
  alv_test_fail "restored bytes differ from the original"
[ -f "$ALV_TEST_VAULTED_A" ] || alv_test_fail "restore removed the vaulted copy"

alv_test_expect_failure "restore overwrote an existing Codex chat" \
  "$ALV_TEST_CLI" restore "$ALV_TEST_ROLLOUT_A" \
    --from "file:$ALV_TEST_VAULT" \
    --codex-home "$ALV_TEST_RESTORE_HOME"

alv_test_expect_failure "restore accepted a Codex home inside the vault" \
  "$ALV_TEST_CLI" restore "$ALV_TEST_ROLLOUT_A" \
    --from "file:$ALV_TEST_VAULT" \
    --codex-home "$ALV_TEST_OVERLAP_HOME"
[ ! -e "$ALV_TEST_OVERLAP_HOME/archived_sessions" ] || \
  alv_test_fail "rejected overlapping Codex home was modified"

alv_test_expect_failure "evict ran without explicit confirmation" \
  "$ALV_TEST_CLI" evict "$ALV_TEST_ROLLOUT_A" \
    --codex-home "$ALV_TEST_SOURCE_HOME" \
    --verified-at "file:$ALV_TEST_VAULT"
[ -f "$ALV_TEST_SOURCE_A" ] || alv_test_fail "unconfirmed eviction removed the Codex source"

"$ALV_TEST_CLI" evict "$ALV_TEST_ROLLOUT_A" \
  --codex-home "$ALV_TEST_SOURCE_HOME" \
  --verified-at "file:$ALV_TEST_VAULT" \
  --yes > "$ALV_TEST_WORK/evict.out"

[ ! -e "$ALV_TEST_SOURCE_A" ] || alv_test_fail "verified eviction left the Codex source"
[ -f "$ALV_TEST_VAULTED_A" ] || alv_test_fail "eviction removed the vaulted copy"
[ -f "$ALV_TEST_SOURCE_B" ] || alv_test_fail "eviction removed an unrelated Codex chat"

ALV_TEST_AFTER_EVICT_LIST=$("$ALV_TEST_CLI" list codex --codex-home "$ALV_TEST_SOURCE_HOME")
[ "$ALV_TEST_AFTER_EVICT_LIST" = "$ALV_TEST_ROLLOUT_B" ] || \
  alv_test_fail "Codex listing was incorrect after eviction"

"$ALV_TEST_CLI" restore "$ALV_TEST_ROLLOUT_A" \
  --from "file:$ALV_TEST_VAULT" \
  --codex-home "$ALV_TEST_SOURCE_HOME" > "$ALV_TEST_WORK/roundtrip-restore.out"
cmp -s "$ALV_TEST_SOURCE_A" "$ALV_TEST_VAULTED_A" || \
  alv_test_fail "evicted chat did not round-trip back into Codex"

ln -s "$ALV_TEST_SOURCE_A" "$ALV_TEST_SOURCE_HOME/archived_sessions/$ALV_TEST_ROLLOUT_LINK"
alv_test_expect_failure "symbolic-link Codex source was accepted" \
  "$ALV_TEST_CLI" put "$ALV_TEST_ROLLOUT_LINK" \
    --codex-home "$ALV_TEST_SOURCE_HOME" \
    --to "file:$ALV_TEST_EMPTY_VAULT"

ln -s "$ALV_TEST_SYMLINK_ESCAPE" "$ALV_TEST_SYMLINK_VAULT/archived_sessions"
alv_test_expect_failure "symbolic-link vault directory was accepted" \
  "$ALV_TEST_CLI" put "$ALV_TEST_SOURCE_B" --to "file:$ALV_TEST_SYMLINK_VAULT"

printf 'all tests passed\n'
