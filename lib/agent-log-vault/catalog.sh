# Read-only discovery helpers for Codex archived chats.

ALV_CATALOG_FIFO_DIRECTORY=
ALV_CATALOG_FIFO=

alv_catalog_cleanup() {
  if [ -n "$ALV_CATALOG_FIFO" ] && [ -p "$ALV_CATALOG_FIFO" ]; then
    unlink "$ALV_CATALOG_FIFO" 2>/dev/null || true
  fi
  if [ -n "$ALV_CATALOG_FIFO_DIRECTORY" ] && \
     [ -d "$ALV_CATALOG_FIFO_DIRECTORY" ]; then
    rmdir "$ALV_CATALOG_FIFO_DIRECTORY" 2>/dev/null || true
  fi
  ALV_CATALOG_FIFO=
  ALV_CATALOG_FIFO_DIRECTORY=
}

alv_catalog_require_jq() {
  command -v jq >/dev/null 2>&1 || \
    alv_fail "metadata inspection and filtering require jq"
}

alv_catalog_resolve_codex_home() {
  ALV_CATALOG_HOME_INPUT=$1
  if [ -z "$ALV_CATALOG_HOME_INPUT" ]; then
    ALV_CATALOG_HOME_INPUT=$(alv_default_codex_home)
  fi

  ALV_CATALOG_CODEX_HOME=$(alv_canonical_directory "$ALV_CATALOG_HOME_INPUT")
  ALV_CATALOG_ARCHIVED=$ALV_CATALOG_CODEX_HOME/archived_sessions
  [ ! -L "$ALV_CATALOG_ARCHIVED" ] || \
    alv_fail "Codex archived_sessions path is a symbolic link"
}

alv_catalog_validate_date() {
  ALV_CATALOG_DATE=$1
  ALV_CATALOG_DATE_LABEL=$2

  case "$ALV_CATALOG_DATE" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) alv_fail "$ALV_CATALOG_DATE_LABEL must use YYYY-MM-DD" ;;
  esac

  ALV_CATALOG_DATE_REST=${ALV_CATALOG_DATE#????-}
  ALV_CATALOG_DATE_MONTH=${ALV_CATALOG_DATE_REST%%-*}
  ALV_CATALOG_DATE_DAY=${ALV_CATALOG_DATE_REST#*-}
  [ "$ALV_CATALOG_DATE_MONTH" -ge 1 ] 2>/dev/null && \
    [ "$ALV_CATALOG_DATE_MONTH" -le 12 ] 2>/dev/null && \
    [ "$ALV_CATALOG_DATE_DAY" -ge 1 ] 2>/dev/null && \
    [ "$ALV_CATALOG_DATE_DAY" -le 31 ] 2>/dev/null || \
    alv_fail "$ALV_CATALOG_DATE_LABEL is not a valid calendar date"
}

alv_catalog_parse_size() {
  ALV_CATALOG_SIZE_INPUT=$1
  ALV_CATALOG_SIZE_MULTIPLIER=1

  case "$ALV_CATALOG_SIZE_INPUT" in
    *[Kk])
      ALV_CATALOG_SIZE_NUMBER=${ALV_CATALOG_SIZE_INPUT%?}
      ALV_CATALOG_SIZE_MULTIPLIER=1024
      ;;
    *[Mm])
      ALV_CATALOG_SIZE_NUMBER=${ALV_CATALOG_SIZE_INPUT%?}
      ALV_CATALOG_SIZE_MULTIPLIER=1048576
      ;;
    *[Gg])
      ALV_CATALOG_SIZE_NUMBER=${ALV_CATALOG_SIZE_INPUT%?}
      ALV_CATALOG_SIZE_MULTIPLIER=1073741824
      ;;
    *[Tt])
      ALV_CATALOG_SIZE_NUMBER=${ALV_CATALOG_SIZE_INPUT%?}
      ALV_CATALOG_SIZE_MULTIPLIER=1099511627776
      ;;
    *) ALV_CATALOG_SIZE_NUMBER=$ALV_CATALOG_SIZE_INPUT ;;
  esac

  case "$ALV_CATALOG_SIZE_NUMBER" in
    ''|*[!0-9]*) alv_fail "--larger-than must be bytes or use K, M, G, or T" ;;
  esac

  while [ "${ALV_CATALOG_SIZE_NUMBER#0}" != "$ALV_CATALOG_SIZE_NUMBER" ]; do
    ALV_CATALOG_SIZE_NUMBER=${ALV_CATALOG_SIZE_NUMBER#0}
  done
  [ -n "$ALV_CATALOG_SIZE_NUMBER" ] || ALV_CATALOG_SIZE_NUMBER=0
  ALV_CATALOG_SIZE_BYTES=$((ALV_CATALOG_SIZE_NUMBER * ALV_CATALOG_SIZE_MULTIPLIER))
  [ "$ALV_CATALOG_SIZE_BYTES" -ge 0 ] 2>/dev/null || \
    alv_fail "--larger-than is too large"
}

alv_catalog_emit_codex_records() {
  [ -d "$ALV_CATALOG_ARCHIVED" ] || return 0

  for ALV_CATALOG_FILE in "$ALV_CATALOG_ARCHIVED"/rollout-*.jsonl; do
    [ -e "$ALV_CATALOG_FILE" ] || continue
    alv_require_regular_file "$ALV_CATALOG_FILE"
    ALV_CATALOG_NAME=$(alv_rollout_name "$ALV_CATALOG_FILE")
    ALV_CATALOG_BYTES=$(alv_file_size "$ALV_CATALOG_FILE")
    ALV_CATALOG_FIRST_LINE=
    if IFS= read -r ALV_CATALOG_FIRST_LINE < "$ALV_CATALOG_FILE"; then
      :
    elif [ -z "$ALV_CATALOG_FIRST_LINE" ]; then
      alv_fail "chat is empty: $ALV_CATALOG_FILE"
    fi
    printf '%s\t%s\t%s\n' \
      "$ALV_CATALOG_NAME" "$ALV_CATALOG_BYTES" "$ALV_CATALOG_FIRST_LINE"
  done
}

alv_catalog_list_codex() {
  ALV_CATALOG_LIST_HOME=$1
  ALV_CATALOG_LIST_LONG=$2
  ALV_CATALOG_LIST_BEFORE=$3
  ALV_CATALOG_LIST_AFTER=$4
  ALV_CATALOG_LIST_PROJECT=$5
  ALV_CATALOG_LIST_LARGER=$6

  alv_catalog_require_jq
  alv_catalog_resolve_codex_home "$ALV_CATALOG_LIST_HOME"

  if [ -n "$ALV_CATALOG_LIST_BEFORE" ]; then
    alv_catalog_validate_date "$ALV_CATALOG_LIST_BEFORE" "--created-before"
  fi
  if [ -n "$ALV_CATALOG_LIST_AFTER" ]; then
    alv_catalog_validate_date "$ALV_CATALOG_LIST_AFTER" "--created-after"
  fi
  if [ -n "$ALV_CATALOG_LIST_LARGER" ]; then
    alv_catalog_parse_size "$ALV_CATALOG_LIST_LARGER"
  else
    ALV_CATALOG_SIZE_BYTES=-1
  fi

  ALV_CATALOG_TMP_BASE=${TMPDIR:-/tmp}
  ALV_CATALOG_TMP_BASE=$(alv_canonical_directory "$ALV_CATALOG_TMP_BASE")
  ALV_CATALOG_FIFO_DIRECTORY=$(mktemp -d "$ALV_CATALOG_TMP_BASE/agent-log-vault-catalog.XXXXXX")
  ALV_CATALOG_FIFO=$ALV_CATALOG_FIFO_DIRECTORY/records
  mkfifo "$ALV_CATALOG_FIFO"

  alv_catalog_emit_codex_records > "$ALV_CATALOG_FIFO" &
  ALV_CATALOG_PRODUCER_PID=$!

  if [ "$ALV_CATALOG_LIST_LONG" = true ]; then
    printf 'CREATED\tBYTES\tCWD\tCHAT\n'
  fi

  ALV_CATALOG_JQ_OK=true
  if ! jq -Rr \
    --arg before "$ALV_CATALOG_LIST_BEFORE" \
    --arg after "$ALV_CATALOG_LIST_AFTER" \
    --arg project "$ALV_CATALOG_LIST_PROJECT" \
    --arg long "$ALV_CATALOG_LIST_LONG" \
    --argjson larger "$ALV_CATALOG_SIZE_BYTES" '
      def cwd_name:
        split("/") | map(select(length > 0)) |
        if length == 0 then "" else .[-1] end;

      split("\t") as $parts |
      if ($parts | length) < 3 then error("invalid catalog record") else . end |
      ($parts[2:] | join("\t") | fromjson) as $metadata |
      if $metadata.type != "session_meta"
        then error("first JSONL record is not session_meta")
        else .
      end |
      {
        name: $parts[0],
        bytes: ($parts[1] | tonumber),
        id: ($metadata.payload.id // ""),
        created: ($metadata.payload.timestamp // $metadata.timestamp // ""),
        cwd: ($metadata.payload.cwd // "")
      } |
      select($before == "" or ((.created | length) >= 10 and .created[0:10] < $before)) |
      select($after == "" or ((.created | length) >= 10 and .created[0:10] > $after)) |
      select($project == "" or .cwd == $project or (.cwd | cwd_name) == $project) |
      select(.bytes > $larger) |
      if $long == "true"
        then [.created, (.bytes | tostring), .cwd, .name] | @tsv
        else .name
      end
    ' < "$ALV_CATALOG_FIFO"; then
    ALV_CATALOG_JQ_OK=false
  fi

  ALV_CATALOG_PRODUCER_OK=true
  if ! wait "$ALV_CATALOG_PRODUCER_PID"; then
    ALV_CATALOG_PRODUCER_OK=false
  fi
  alv_catalog_cleanup

  [ "$ALV_CATALOG_JQ_OK" = true ] || alv_fail "could not parse Codex session metadata"
  [ "$ALV_CATALOG_PRODUCER_OK" = true ] || alv_fail "could not read the Codex archive"
}

alv_catalog_state_database() {
  ALV_CATALOG_STATE_DATABASE=
  if [ -f "$1/state_5.sqlite" ]; then
    ALV_CATALOG_STATE_DATABASE=$1/state_5.sqlite
  elif [ -f "$1/sqlite/state_5.sqlite" ]; then
    ALV_CATALOG_STATE_DATABASE=$1/sqlite/state_5.sqlite
  fi
}

alv_catalog_inspect() {
  ALV_CATALOG_INSPECT_FILE=$1
  ALV_CATALOG_INSPECT_NAME=$2
  ALV_CATALOG_INSPECT_HOME=$3

  alv_catalog_require_jq
  ALV_CATALOG_INSPECT_FIRST=
  if IFS= read -r ALV_CATALOG_INSPECT_FIRST < "$ALV_CATALOG_INSPECT_FILE"; then
    :
  elif [ -z "$ALV_CATALOG_INSPECT_FIRST" ]; then
    alv_fail "chat is empty: $ALV_CATALOG_INSPECT_FILE"
  fi

  ALV_CATALOG_INSPECT_JSON=$(printf '%s\n' "$ALV_CATALOG_INSPECT_FIRST" | jq -ce '
    if .type != "session_meta" then error("first JSONL record is not session_meta") else . end |
    {
      id: (.payload.id // ""),
      created: (.payload.timestamp // .timestamp // ""),
      cwd: (.payload.cwd // ""),
      originator: (.payload.originator // ""),
      cli_version: (.payload.cli_version // "")
    }
  ') || alv_fail "could not parse Codex session metadata"

  ALV_CATALOG_INSPECT_ID=$(printf '%s\n' "$ALV_CATALOG_INSPECT_JSON" | jq -r '.id')
  case "$ALV_CATALOG_INSPECT_ID" in
    *[!0-9A-Fa-f-]*) alv_fail "session metadata contains an invalid thread ID" ;;
  esac
  [ "${#ALV_CATALOG_INSPECT_ID}" -eq 36 ] || \
    alv_fail "session metadata contains an invalid thread ID"

  printf 'name\t%s\n' "$ALV_CATALOG_INSPECT_NAME"
  printf 'bytes\t%s\n' "$(alv_file_size "$ALV_CATALOG_INSPECT_FILE")"
  printf '%s\n' "$ALV_CATALOG_INSPECT_JSON" | jq -r '
    def cwd_name:
      .cwd | split("/") | map(select(length > 0)) |
      if length == 0 then "" else .[-1] end;
    "id\t" + .id,
    "created\t" + .created,
    "project\t" + cwd_name,
    "cwd\t" + (.cwd | @json),
    "originator\t" + .originator,
    "cli_version\t" + .cli_version
  '

  alv_catalog_state_database "$ALV_CATALOG_INSPECT_HOME"
  if [ -n "$ALV_CATALOG_STATE_DATABASE" ] && command -v sqlite3 >/dev/null 2>&1; then
    ALV_CATALOG_DB_JSON=
    if ALV_CATALOG_DB_JSON=$(sqlite3 -readonly "$ALV_CATALOG_STATE_DATABASE" "
      SELECT json_object(
        'title', title,
        'archived_at', CASE
          WHEN archived_at IS NULL THEN NULL
          ELSE strftime('%Y-%m-%dT%H:%M:%SZ', archived_at, 'unixepoch')
        END,
        'git_branch', git_branch
      )
      FROM threads
      WHERE id = '$ALV_CATALOG_INSPECT_ID'
      LIMIT 1;
    " 2>/dev/null) && [ -n "$ALV_CATALOG_DB_JSON" ]; then
      printf '%s\n' "$ALV_CATALOG_DB_JSON" | jq -r '
        "title\t" + (.title | @json),
        if .archived_at != null then "archived\t" + .archived_at else empty end,
        if .git_branch != null then "git_branch\t" + (.git_branch | @json) else empty end
      '
    fi
  fi
}
