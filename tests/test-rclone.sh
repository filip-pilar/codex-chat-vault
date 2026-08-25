#!/bin/sh

set -eu

ALV_TEST_ROOT_DIR=$(CDPATH='' cd "$(dirname "$0")/.." && pwd -P)
ALV_TEST_CLI=$ALV_TEST_ROOT_DIR/alv
ALV_TEST_REAL_RCLONE=$(command -v rclone || true)
ALV_TEST_REAL_CP=$(command -v cp || true)
ALV_TEST_TMP_BASE=${TMPDIR:-/tmp}
[ "$ALV_TEST_TMP_BASE" = / ] || ALV_TEST_TMP_BASE=${ALV_TEST_TMP_BASE%/}
ALV_TEST_WORK=$(mktemp -d "$ALV_TEST_TMP_BASE/agent-log-vault-rclone-test.XXXXXX")
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
command -v jq >/dev/null 2>&1 || alv_test_fail "jq is required for this test"
command -v rg >/dev/null 2>&1 || alv_test_fail "rg is required for this test"
trap alv_test_cleanup EXIT HUP INT TERM

cp "$ALV_TEST_ROOT_DIR/tests/helpers/rclone" "$ALV_TEST_WRAPPER_BIN/rclone"
cp "$ALV_TEST_ROOT_DIR/tests/helpers/cp" "$ALV_TEST_WRAPPER_BIN/cp"
chmod 700 "$ALV_TEST_WRAPPER_BIN/rclone" "$ALV_TEST_WRAPPER_BIN/cp"
export ALV_TEST_REAL_RCLONE ALV_TEST_REAL_CP

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
ALV_TEST_ACTIVE_DIRECTORY="$CODEX_HOME/sessions"
mkdir -p \
  "$CODEX_HOME/archived_sessions" \
  "$ALV_TEST_ACTIVE_DIRECTORY" \
  "$ALV_TEST_CLEAN_HOME" \
  "$ALV_TEST_OTHER_HOME/archived_sessions" \
  "$ALV_TEST_UNSAFE_BACKING" \
  "$ALV_TEST_FAILED_VAULT" \
  "$ALV_TEST_VAULT"

ALV_TEST_ROLLOUT_A=rollout-2026-02-01T00-00-00-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.jsonl
ALV_TEST_ROLLOUT_B=rollout-2026-02-02T00-00-00-bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb.jsonl
ALV_TEST_ROLLOUT_C=rollout-2026-02-03T00-00-00-cccccccc-cccc-cccc-cccc-cccccccccccc.jsonl
ALV_TEST_ACTIVE=rollout-2026-02-04T00-00-00-dddddddd-dddd-dddd-dddd-dddddddddddd.jsonl
ALV_TEST_ROLLOUT_OTHER=rollout-2026-02-05T00-00-00-eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee.jsonl
ALV_TEST_SOURCE_A=$CODEX_HOME/archived_sessions/$ALV_TEST_ROLLOUT_A
ALV_TEST_SOURCE_B=$CODEX_HOME/archived_sessions/$ALV_TEST_ROLLOUT_B
ALV_TEST_SOURCE_C=$CODEX_HOME/archived_sessions/$ALV_TEST_ROLLOUT_C
ALV_TEST_ACTIVE_SOURCE=$ALV_TEST_ACTIVE_DIRECTORY/$ALV_TEST_ACTIVE
ALV_TEST_OTHER_SOURCE=$ALV_TEST_OTHER_HOME/archived_sessions/$ALV_TEST_ROLLOUT_OTHER

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
[ ! -e "$ALV_TEST_SOURCE_A" ] || \
  alv_test_fail "interrupted restore created a local thread"
[ "$("$ALV_TEST_CLI" list cold)" = "$ALV_TEST_ROLLOUT_A" ] || \
  alv_test_fail "interrupted restore changed the cold source"

alv_test_expect_failure "interrupted atomic placement reported success" \
  env ALV_TEST_CP_MODE=interrupt-placement \
    PATH="$ALV_TEST_WRAPPER_BIN:$PATH" \
    "$ALV_TEST_CLI" restore "$ALV_TEST_ROLLOUT_A"
[ ! -e "$ALV_TEST_SOURCE_A" ] || \
  alv_test_fail "interrupted placement created a completed local thread"
for ALV_TEST_PARTIAL in "$ALV_TEST_SOURCE_A".partial.*; do
  [ ! -e "$ALV_TEST_PARTIAL" ] || \
    alv_test_fail "interrupted placement left a partial local thread"
done
[ "$("$ALV_TEST_CLI" list cold)" = "$ALV_TEST_ROLLOUT_A" ] || \
  alv_test_fail "interrupted placement changed the cold source"

"$ALV_TEST_CLI" restore "$ALV_TEST_ROLLOUT_A" \
  > "$ALV_TEST_WORK/restore-a.out"
cmp -s "$ALV_TEST_SOURCE_A" "$ALV_TEST_WORK/expected-a.jsonl" || \
  alv_test_fail "restore changed the exact JSONL bytes"
[ "$("$ALV_TEST_CLI" list cold)" = "$ALV_TEST_ROLLOUT_A" ] || \
  alv_test_fail "restore removed the cold copy"
"$ALV_TEST_CLI" verify "$ALV_TEST_ROLLOUT_A" \
  > "$ALV_TEST_WORK/verify-a-both.out"
rg -q 'both' "$ALV_TEST_WORK/verify-a-both.out" || \
  alv_test_fail "verify did not report the both state"

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
[ ! -e "$ALV_TEST_SOURCE_B" ] || \
  alv_test_fail "failed corrupted restore created a local thread"

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
"$ALV_TEST_CLI" vault recovery cold --output "$ALV_TEST_RECOVERY" \
  > "$ALV_TEST_WORK/recovery.out"
[ "$(alv_test_mode "$ALV_TEST_RECOVERY")" = 600 ] || \
  alv_test_fail "recovery export permissions are not 0600"
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

printf 'all encrypted vault tests passed\n'
