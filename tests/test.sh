#!/bin/sh

set -eu

ALV_TEST_ROOT_DIR=$(CDPATH='' cd "$(dirname "$0")/.." && pwd -P)
ALV_TEST_CLI=$ALV_TEST_ROOT_DIR/alv
ALV_TEST_TMP_BASE=${TMPDIR:-/tmp}
[ "$ALV_TEST_TMP_BASE" = / ] || ALV_TEST_TMP_BASE=${ALV_TEST_TMP_BASE%/}
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
          cli_version: "0.test"
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

command -v jq >/dev/null 2>&1 || alv_test_fail "jq is required for this test"
command -v rg >/dev/null 2>&1 || alv_test_fail "rg is required for this test"
trap alv_test_cleanup EXIT HUP INT TERM

ALV_TEST_CODEX_HOME="$ALV_TEST_WORK/codex home"
ALV_TEST_INVALID_HOME="$ALV_TEST_WORK/invalid codex home"
mkdir -p \
  "$ALV_TEST_CODEX_HOME/archived_sessions" \
  "$ALV_TEST_CODEX_HOME/sessions" \
  "$ALV_TEST_INVALID_HOME/archived_sessions"

ALV_TEST_ROLLOUT_A=rollout-2026-01-02T03-04-05-00000000-0000-0000-0000-000000000000.jsonl
ALV_TEST_ROLLOUT_B=rollout-2026-01-03T03-04-05-11111111-1111-1111-1111-111111111111.jsonl
ALV_TEST_ACTIVE=rollout-2026-01-04T03-04-05-22222222-2222-2222-2222-222222222222.jsonl
ALV_TEST_SOURCE_A=$ALV_TEST_CODEX_HOME/archived_sessions/$ALV_TEST_ROLLOUT_A
ALV_TEST_SOURCE_B=$ALV_TEST_CODEX_HOME/archived_sessions/$ALV_TEST_ROLLOUT_B
ALV_TEST_ACTIVE_SOURCE=$ALV_TEST_CODEX_HOME/sessions/$ALV_TEST_ACTIVE

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
alv_test_write_rollout \
  "$ALV_TEST_ACTIVE_SOURCE" \
  22222222-2222-2222-2222-222222222222 \
  2026-01-04T03:04:05.000Z \
  '/workspace/active project' \
  10

ln -s "$ALV_TEST_CLI" "$ALV_TEST_WORK/alv"
"$ALV_TEST_WORK/alv" --help > "$ALV_TEST_WORK/help.out"
rg -q 'list local' "$ALV_TEST_WORK/help.out" || \
  alv_test_fail "help omitted the local workflow"
rg -q 'offload <thread>' "$ALV_TEST_WORK/help.out" || \
  alv_test_fail "help omitted offload"
rg -q 'stats local' "$ALV_TEST_WORK/help.out" || \
  alv_test_fail "help omitted local stats"
rg -q 'plan offload' "$ALV_TEST_WORK/help.out" || \
  alv_test_fail "help omitted offload planning"
if rg -q 'file:/|^[[:space:]]+alv (put|evict)([[:space:]]|$)' \
  "$ALV_TEST_WORK/help.out"; then
  alv_test_fail "help exposed a removed plaintext or legacy command"
fi

ALV_TEST_EXPECTED_LIST=$(printf '%s\n%s' "$ALV_TEST_ROLLOUT_A" "$ALV_TEST_ROLLOUT_B")
ALV_TEST_ACTUAL_LIST=$("$ALV_TEST_CLI" list local --codex-home "$ALV_TEST_CODEX_HOME")
[ "$ALV_TEST_ACTUAL_LIST" = "$ALV_TEST_EXPECTED_LIST" ] || \
  alv_test_fail "local listing returned unexpected threads"

"$ALV_TEST_CLI" inspect "$ALV_TEST_ROLLOUT_A" \
  --codex-home "$ALV_TEST_CODEX_HOME" > "$ALV_TEST_WORK/inspect.out"
rg -q '^id[[:space:]]+00000000-0000-0000-0000-000000000000$' \
  "$ALV_TEST_WORK/inspect.out" || alv_test_fail "inspect omitted the thread ID"
rg -q '^project[[:space:]]+project alpha$' "$ALV_TEST_WORK/inspect.out" || \
  alv_test_fail "inspect omitted the project"

ALV_TEST_FILTERED=$("$ALV_TEST_CLI" list local \
  --created-before 2026-01-03 \
  --codex-home "$ALV_TEST_CODEX_HOME")
[ "$ALV_TEST_FILTERED" = "$ALV_TEST_ROLLOUT_A" ] || \
  alv_test_fail "created-before selected the wrong thread"
ALV_TEST_FILTERED=$("$ALV_TEST_CLI" list local \
  --project 'project beta' \
  --codex-home "$ALV_TEST_CODEX_HOME")
[ "$ALV_TEST_FILTERED" = "$ALV_TEST_ROLLOUT_B" ] || \
  alv_test_fail "project selected the wrong thread"

ALV_TEST_SORTED=$("$ALV_TEST_CLI" list local \
  --sort size --limit 1 --codex-home "$ALV_TEST_CODEX_HOME")
[ "$ALV_TEST_SORTED" = "$ALV_TEST_ROLLOUT_B" ] || \
  alv_test_fail "size sorting and limiting selected the wrong thread"
ALV_TEST_SORTED=$("$ALV_TEST_CLI" list local \
  --sort created --codex-home "$ALV_TEST_CODEX_HOME")
[ "$(printf '%s\n' "$ALV_TEST_SORTED" | sed -n '1p')" = "$ALV_TEST_ROLLOUT_B" ] || \
  alv_test_fail "created sorting did not return the newest thread first"
ALV_TEST_LIST_JSON=$("$ALV_TEST_CLI" list local \
  --json --project 'project alpha' --codex-home "$ALV_TEST_CODEX_HOME")
[ "$(printf '%s\n' "$ALV_TEST_LIST_JSON" | jq -r 'length')" = 1 ] || \
  alv_test_fail "JSON listing returned the wrong number of threads"
[ "$(printf '%s\n' "$ALV_TEST_LIST_JSON" | jq -r '.[0].name')" = "$ALV_TEST_ROLLOUT_A" ] || \
  alv_test_fail "JSON listing returned the wrong thread"
[ "$(printf '%s\n' "$ALV_TEST_LIST_JSON" | jq -r '.[0].project')" = 'project alpha' ] || \
  alv_test_fail "JSON listing omitted the project"

ALV_TEST_SOURCE_A_SIZE=
if ALV_TEST_STAT_SIZE=$(stat -f '%z' "$ALV_TEST_SOURCE_A" 2>/dev/null); then
  case "$ALV_TEST_STAT_SIZE" in
    ''|*[!0-9]*) ;;
    *) ALV_TEST_SOURCE_A_SIZE=$ALV_TEST_STAT_SIZE ;;
  esac
fi
if [ -z "$ALV_TEST_SOURCE_A_SIZE" ]; then
  ALV_TEST_SOURCE_A_SIZE=$(stat -c '%s' "$ALV_TEST_SOURCE_A")
fi
ALV_TEST_FILTERED=$("$ALV_TEST_CLI" list local \
  --larger-than "$ALV_TEST_SOURCE_A_SIZE" \
  --codex-home "$ALV_TEST_CODEX_HOME")
[ "$ALV_TEST_FILTERED" = "$ALV_TEST_ROLLOUT_B" ] || \
  alv_test_fail "larger-than selected the wrong thread"

ALV_TEST_STATS_JSON=$("$ALV_TEST_CLI" stats local \
  --top 1 --by-project --json --codex-home "$ALV_TEST_CODEX_HOME")
[ "$(printf '%s\n' "$ALV_TEST_STATS_JSON" | jq -r '.threads')" = 2 ] || \
  alv_test_fail "stats counted the wrong number of threads"
[ "$(printf '%s\n' "$ALV_TEST_STATS_JSON" | jq -r '.top[0].name')" = "$ALV_TEST_ROLLOUT_B" ] || \
  alv_test_fail "stats selected the wrong largest thread"
[ "$(printf '%s\n' "$ALV_TEST_STATS_JSON" | jq -r '.projects | length')" = 2 ] || \
  alv_test_fail "stats returned the wrong project groups"
[ "$(printf '%s\n' "$ALV_TEST_STATS_JSON" | jq -r '.logical_bytes > 0 and .on_disk_bytes > 0 and .available_bytes > 0')" = true ] || \
  alv_test_fail "stats omitted size or disk-space totals"
"$ALV_TEST_CLI" stats local --top 1 --codex-home "$ALV_TEST_CODEX_HOME" \
  > "$ALV_TEST_WORK/stats.out"
rg -q '^threads[[:space:]]+2$' "$ALV_TEST_WORK/stats.out" || \
  alv_test_fail "text stats omitted the thread count"

alv_test_expect_failure "invalid discovery date was accepted" \
  "$ALV_TEST_CLI" list local --created-before 2026-13-01 \
    --codex-home "$ALV_TEST_CODEX_HOME"
alv_test_expect_failure "invalid list sort was accepted" \
  "$ALV_TEST_CLI" list local --sort random --codex-home "$ALV_TEST_CODEX_HOME"
alv_test_expect_failure "zero list limit was accepted" \
  "$ALV_TEST_CLI" list local --limit 0 --codex-home "$ALV_TEST_CODEX_HOME"
alv_test_expect_failure "duplicate list sort was accepted" \
  "$ALV_TEST_CLI" list local --sort name --sort size \
    --codex-home "$ALV_TEST_CODEX_HOME"
alv_test_expect_failure "zero stats top count was accepted" \
  "$ALV_TEST_CLI" stats local --top 0 --codex-home "$ALV_TEST_CODEX_HOME"
alv_test_expect_failure "cold listing worked without a configured vault" \
  env ALV_CONFIG_HOME="$ALV_TEST_WORK/empty-config" \
    "$ALV_TEST_CLI" list cold
alv_test_expect_failure "offload plan worked without a configured vault" \
  env ALV_CONFIG_HOME="$ALV_TEST_WORK/empty-config" \
    "$ALV_TEST_CLI" plan offload --codex-home "$ALV_TEST_CODEX_HOME"
alv_test_expect_failure "legacy plaintext location was accepted" \
  "$ALV_TEST_CLI" list "file:$ALV_TEST_WORK/vault"
alv_test_expect_failure "active thread path was accepted for inspection" \
  "$ALV_TEST_CLI" inspect "$ALV_TEST_ACTIVE_SOURCE"

ALV_TEST_INVALID_ROLLOUT=$ALV_TEST_INVALID_HOME/archived_sessions/rollout-2026-01-05T03-04-05-33333333-3333-3333-3333-333333333333.jsonl
printf '%s\n' '{"type":"not-session-meta"}' > "$ALV_TEST_INVALID_ROLLOUT"
alv_test_expect_failure "invalid first metadata record was accepted" \
  "$ALV_TEST_CLI" list local --long --codex-home "$ALV_TEST_INVALID_HOME"

for ALV_TEST_TEMP in "$ALV_TEST_RUNTIME_TMP"/agent-log-vault-catalog.*; do
  [ ! -e "$ALV_TEST_TEMP" ] || \
    alv_test_fail "catalog command left a private temporary directory"
done

printf 'all discovery tests passed\n'
