#!/bin/sh

set -eu

ALV_TEST_ROOT=$(CDPATH='' cd "$(dirname "$0")/.." && pwd -P)
cd "$ALV_TEST_ROOT"

command -v rg >/dev/null 2>&1 || {
  printf 'test runner: rg is required\n' >&2
  exit 1
}

rg -l '^#!/bin/sh$' agent-log-vault alv lib tests |
  while IFS= read -r ALV_TEST_SCRIPT; do
    sh -n "$ALV_TEST_SCRIPT"
  done

if command -v shellcheck >/dev/null 2>&1; then
  ./tests/lint.sh
else
  printf 'test runner: shellcheck not installed; static analysis skipped\n' >&2
fi

./tests/test.sh
./tests/test-rclone.sh
./tests/test-providers.sh

printf 'all isolated tests passed\n'
