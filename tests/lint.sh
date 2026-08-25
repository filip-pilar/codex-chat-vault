#!/bin/sh

set -eu

ALV_LINT_ROOT=$(CDPATH='' cd "$(dirname "$0")/.." && pwd -P)
cd "$ALV_LINT_ROOT"

command -v rg >/dev/null 2>&1 || {
  printf 'lint: rg is required\n' >&2
  exit 1
}
command -v shellcheck >/dev/null 2>&1 || {
  printf 'lint: shellcheck is required\n' >&2
  exit 1
}

rg -l '^#!/bin/sh$' agent-log-vault alv lib tests |
  while IFS= read -r ALV_LINT_SCRIPT; do
    shellcheck --shell=sh "$ALV_LINT_SCRIPT"
  done

printf 'all shell static checks passed\n'
