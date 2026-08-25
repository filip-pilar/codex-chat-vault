#!/bin/sh

set -eu

ALV_TEST_ROOT_DIR=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
ALV_TEST_CLI=$ALV_TEST_ROOT_DIR/agent-log-vault
ALV_TEST_TMP_BASE=${TMPDIR:-/tmp}
ALV_TEST_WORK=$(mktemp -d \
  "$ALV_TEST_TMP_BASE/agent-log-vault-rclone-test.XXXXXX")
ALV_TEST_RUNTIME_TMP=$ALV_TEST_WORK/runtime-tmp
mkdir -p "$ALV_TEST_RUNTIME_TMP"
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

command -v rclone >/dev/null 2>&1 || \
  alv_test_fail "rclone is required for this test"
command -v jq >/dev/null 2>&1 || \
  alv_test_fail "jq is required for this test"

trap alv_test_cleanup EXIT HUP INT TERM

unset RCLONE_CONFIG_PASS || true
unset RCLONE_PASSWORD_COMMAND || true
RCLONE_CONFIG=$ALV_TEST_WORK/rclone.conf
export RCLONE_CONFIG

ALV_TEST_ENCRYPTED_BACKEND=$ALV_TEST_WORK/encrypted-backend
mkdir -p "$ALV_TEST_ENCRYPTED_BACKEND"
rclone config create alv-test-plain local nounc true --no-output \
  >"$ALV_TEST_WORK/plain-config.out" 2>&1
rclone config create \
  alv-test-crypt \
  crypt \
  remote "$ALV_TEST_ENCRYPTED_BACKEND" \
  filename_encryption standard \
  directory_name_encryption true \
  password disposable-rclone-test-passphrase \
  password2 disposable-rclone-test-salt \
  --obscure \
  --no-output \
  >"$ALV_TEST_WORK/crypt-config.out" 2>&1
rclone config create \
  alv-test-weak-crypt \
  crypt \
  remote "$ALV_TEST_ENCRYPTED_BACKEND" \
  filename_encryption off \
  password disposable-rclone-test-passphrase \
  password2 disposable-rclone-test-salt \
  --obscure \
  --no-output \
  >"$ALV_TEST_WORK/weak-crypt-config.out" 2>&1

ALV_TEST_SOURCE_HOME="$ALV_TEST_WORK/source codex home"
ALV_TEST_RESTORE_HOME="$ALV_TEST_WORK/restore codex home"
ALV_TEST_BROKEN_RESTORE_HOME="$ALV_TEST_WORK/broken restore home"
mkdir -p \
  "$ALV_TEST_SOURCE_HOME/archived_sessions" \
  "$ALV_TEST_RESTORE_HOME" \
  "$ALV_TEST_BROKEN_RESTORE_HOME"

ALV_TEST_ROLLOUT_A=rollout-2026-02-01T00-00-00-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.jsonl
ALV_TEST_ROLLOUT_B=rollout-2026-02-02T00-00-00-bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb.jsonl
ALV_TEST_ROLLOUT_C=rollout-2026-02-03T00-00-00-cccccccc-cccc-cccc-cccc-cccccccccccc.jsonl
ALV_TEST_ROLLOUT_D=rollout-2026-02-04T00-00-00-dddddddd-dddd-dddd-dddd-dddddddddddd.jsonl

ALV_TEST_SOURCE_A=$ALV_TEST_SOURCE_HOME/archived_sessions/$ALV_TEST_ROLLOUT_A
ALV_TEST_SOURCE_B=$ALV_TEST_SOURCE_HOME/archived_sessions/$ALV_TEST_ROLLOUT_B
ALV_TEST_SOURCE_C=$ALV_TEST_SOURCE_HOME/archived_sessions/$ALV_TEST_ROLLOUT_C
ALV_TEST_SOURCE_D=$ALV_TEST_SOURCE_HOME/archived_sessions/$ALV_TEST_ROLLOUT_D
alv_test_write_rollout \
  "$ALV_TEST_SOURCE_A" \
  aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa \
  2026-02-01T00:00:00.000Z \
  alpha
alv_test_write_rollout \
  "$ALV_TEST_SOURCE_B" \
  bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb \
  2026-02-02T00:00:00.000Z \
  beta
alv_test_write_rollout \
  "$ALV_TEST_SOURCE_C" \
  cccccccc-cccc-cccc-cccc-cccccccccccc \
  2026-02-03T00:00:00.000Z \
  gamma
alv_test_write_rollout \
  "$ALV_TEST_SOURCE_D" \
  dddddddd-dddd-dddd-dddd-dddddddddddd \
  2026-02-04T00:00:00.000Z \
  delta
cp "$ALV_TEST_SOURCE_B" "$ALV_TEST_WORK/expected-b.jsonl"

ALV_TEST_LOCATION='rclone:alv-test-crypt:vault root'
ALV_TEST_REMOTE_ROOT='alv-test-crypt:vault root/archived_sessions'

alv_test_expect_failure "a non-crypt rclone remote was accepted" \
  "$ALV_TEST_CLI" list rclone:alv-test-plain:unused
alv_test_expect_failure "a crypt remote with plaintext filenames was accepted" \
  "$ALV_TEST_CLI" list rclone:alv-test-weak-crypt:unused
alv_test_expect_failure "a malformed rclone location was accepted" \
  "$ALV_TEST_CLI" list rclone:alv-test-crypt
alv_test_expect_failure "rclone root traversal was accepted" \
  "$ALV_TEST_CLI" list rclone:alv-test-crypt:../escape

"$ALV_TEST_CLI" list "$ALV_TEST_LOCATION" > "$ALV_TEST_WORK/empty-list.out"
[ ! -s "$ALV_TEST_WORK/empty-list.out" ] || \
  alv_test_fail "empty encrypted storage listing was not empty"

"$ALV_TEST_CLI" put "$ALV_TEST_ROLLOUT_A" \
  --codex-home "$ALV_TEST_SOURCE_HOME" \
  --to "$ALV_TEST_LOCATION" > "$ALV_TEST_WORK/put-a.out"
[ -f "$ALV_TEST_SOURCE_A" ] || alv_test_fail "rclone put removed its source"

ALV_TEST_LIST=$($ALV_TEST_CLI list "$ALV_TEST_LOCATION")
[ "$ALV_TEST_LIST" = "$ALV_TEST_ROLLOUT_A" ] || \
  alv_test_fail "encrypted storage listing did not return the completed chat"
"$ALV_TEST_CLI" verify "$ALV_TEST_ROLLOUT_A" \
  --at "$ALV_TEST_LOCATION" > "$ALV_TEST_WORK/verify-a.out"

if find "$ALV_TEST_ENCRYPTED_BACKEND" -type f -name '*rollout*' -print | \
    grep -q .; then
  alv_test_fail "raw rclone storage exposed a rollout filename"
fi
if rg -a -F "$ALV_TEST_ROLLOUT_A" "$ALV_TEST_ENCRYPTED_BACKEND" \
    >/dev/null 2>&1; then
  alv_test_fail "raw rclone storage exposed the plaintext chat name"
fi
if rg -a -F 'session_meta' "$ALV_TEST_ENCRYPTED_BACKEND" \
    >/dev/null 2>&1; then
  alv_test_fail "raw rclone storage exposed plaintext chat contents"
fi

alv_test_expect_failure "rclone put overwrote a completed chat" \
  "$ALV_TEST_CLI" put "$ALV_TEST_ROLLOUT_A" \
    --codex-home "$ALV_TEST_SOURCE_HOME" \
    --to "$ALV_TEST_LOCATION"

"$ALV_TEST_CLI" restore "$ALV_TEST_ROLLOUT_A" \
  --from "$ALV_TEST_LOCATION" \
  --codex-home "$ALV_TEST_RESTORE_HOME" > "$ALV_TEST_WORK/restore-a.out"
ALV_TEST_RESTORED_A=$ALV_TEST_RESTORE_HOME/archived_sessions/$ALV_TEST_ROLLOUT_A
cmp -s "$ALV_TEST_SOURCE_A" "$ALV_TEST_RESTORED_A" || \
  alv_test_fail "rclone restore changed the original bytes"
ALV_TEST_LIST=$($ALV_TEST_CLI list "$ALV_TEST_LOCATION")
[ "$ALV_TEST_LIST" = "$ALV_TEST_ROLLOUT_A" ] || \
  alv_test_fail "rclone restore removed the stored copy"

"$ALV_TEST_CLI" put "$ALV_TEST_ROLLOUT_B" \
  --codex-home "$ALV_TEST_SOURCE_HOME" \
  --to "$ALV_TEST_LOCATION" > "$ALV_TEST_WORK/put-b.out"
"$ALV_TEST_CLI" evict "$ALV_TEST_ROLLOUT_B" \
  --codex-home "$ALV_TEST_SOURCE_HOME" \
  --verified-at "$ALV_TEST_LOCATION" \
  --yes > "$ALV_TEST_WORK/evict-b.out"
[ ! -e "$ALV_TEST_SOURCE_B" ] || \
  alv_test_fail "verified rclone eviction left the disposable source"
"$ALV_TEST_CLI" restore "$ALV_TEST_ROLLOUT_B" \
  --from "$ALV_TEST_LOCATION" \
  --codex-home "$ALV_TEST_SOURCE_HOME" > "$ALV_TEST_WORK/restore-b.out"
cmp -s "$ALV_TEST_WORK/expected-b.jsonl" "$ALV_TEST_SOURCE_B" || \
  alv_test_fail "evicted rclone chat did not round-trip exactly"

rclone copyto \
  "$ALV_TEST_SOURCE_C" \
  "$ALV_TEST_REMOTE_ROOT/$ALV_TEST_ROLLOUT_C" \
  --immutable \
  --quiet
if "$ALV_TEST_CLI" list "$ALV_TEST_LOCATION" | \
    grep -Fqx "$ALV_TEST_ROLLOUT_C"; then
  alv_test_fail "an incomplete rclone upload was listed as complete"
fi
"$ALV_TEST_CLI" put "$ALV_TEST_ROLLOUT_C" \
  --codex-home "$ALV_TEST_SOURCE_HOME" \
  --to "$ALV_TEST_LOCATION" > "$ALV_TEST_WORK/complete-c.out"
"$ALV_TEST_CLI" verify "$ALV_TEST_ROLLOUT_C" \
  --at "$ALV_TEST_LOCATION" > "$ALV_TEST_WORK/verify-c.out"

rclone copyto \
  "$ALV_TEST_SOURCE_A" \
  "$ALV_TEST_REMOTE_ROOT/$ALV_TEST_ROLLOUT_D" \
  --immutable \
  --quiet
alv_test_expect_failure "a mismatched incomplete upload was completed" \
  "$ALV_TEST_CLI" put "$ALV_TEST_ROLLOUT_D" \
    --codex-home "$ALV_TEST_SOURCE_HOME" \
    --to "$ALV_TEST_LOCATION"
if "$ALV_TEST_CLI" list "$ALV_TEST_LOCATION" | \
    grep -Fqx "$ALV_TEST_ROLLOUT_D"; then
  alv_test_fail "a mismatched incomplete upload was listed as complete"
fi

ALV_TEST_BROKEN_LOCATION='rclone:alv-test-crypt:broken vault'
ALV_TEST_BROKEN_REMOTE='alv-test-crypt:broken vault/archived_sessions'
"$ALV_TEST_CLI" put "$ALV_TEST_ROLLOUT_A" \
  --codex-home "$ALV_TEST_SOURCE_HOME" \
  --to "$ALV_TEST_BROKEN_LOCATION" > "$ALV_TEST_WORK/put-broken.out"
printf '%s\n' 'corrupted remote bytes' > "$ALV_TEST_WORK/corruption.jsonl"
rclone copyto \
  "$ALV_TEST_WORK/corruption.jsonl" \
  "$ALV_TEST_BROKEN_REMOTE/$ALV_TEST_ROLLOUT_A" \
  --no-check-dest \
  --quiet
alv_test_expect_failure "rclone verification accepted corrupted bytes" \
  "$ALV_TEST_CLI" verify "$ALV_TEST_ROLLOUT_A" \
    --at "$ALV_TEST_BROKEN_LOCATION"
alv_test_expect_failure "rclone restore accepted corrupted bytes" \
  "$ALV_TEST_CLI" restore "$ALV_TEST_ROLLOUT_A" \
    --from "$ALV_TEST_BROKEN_LOCATION" \
    --codex-home "$ALV_TEST_BROKEN_RESTORE_HOME"
[ ! -e "$ALV_TEST_BROKEN_RESTORE_HOME/archived_sessions/$ALV_TEST_ROLLOUT_A" ] || \
  alv_test_fail "failed rclone restore created a completed Codex chat"

for ALV_TEST_TEMP in "$ALV_TEST_RUNTIME_TMP"/agent-log-vault-rclone.*; do
  [ ! -e "$ALV_TEST_TEMP" ] || \
    alv_test_fail "rclone adapter left a plaintext temporary directory"
done

printf 'all encrypted rclone tests passed\n'
