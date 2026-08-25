# Read-only discovery helpers for Codex archived chats.

ALV_CATALOG_TEMP_BASE=
ALV_CATALOG_TEMP_DIRECTORY=
ALV_CATALOG_RESULTS=

alv_catalog_cleanup() {
  [ -n "${ALV_CATALOG_TEMP_DIRECTORY:-}" ] || return 0
  case "$ALV_CATALOG_TEMP_DIRECTORY" in
    "$ALV_CATALOG_TEMP_BASE"/agent-log-vault-catalog.*)
      if [ -e "$ALV_CATALOG_TEMP_DIRECTORY" ]; then
        /bin/rm -rf "$ALV_CATALOG_TEMP_DIRECTORY"
      fi
      ;;
  esac
  ALV_CATALOG_TEMP_DIRECTORY=
  ALV_CATALOG_RESULTS=
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

alv_catalog_validate_positive_integer() {
  case "$2" in
    ''|*[!0-9]*|0) alv_fail "$1 must be a positive integer" ;;
  esac
}

alv_catalog_collect() {
  ALV_CATALOG_COLLECT_HOME=$1
  ALV_CATALOG_COLLECT_BEFORE=$2
  ALV_CATALOG_COLLECT_AFTER=$3
  ALV_CATALOG_COLLECT_PROJECT=$4
  ALV_CATALOG_COLLECT_LARGER=$5
  ALV_CATALOG_COLLECT_SORT=$6
  ALV_CATALOG_COLLECT_LIMIT=$7

  alv_catalog_require_jq
  alv_catalog_resolve_codex_home "$ALV_CATALOG_COLLECT_HOME"

  if [ -n "$ALV_CATALOG_COLLECT_BEFORE" ]; then
    alv_catalog_validate_date "$ALV_CATALOG_COLLECT_BEFORE" "--created-before"
  fi
  if [ -n "$ALV_CATALOG_COLLECT_AFTER" ]; then
    alv_catalog_validate_date "$ALV_CATALOG_COLLECT_AFTER" "--created-after"
  fi
  if [ -n "$ALV_CATALOG_COLLECT_LARGER" ]; then
    alv_catalog_parse_size "$ALV_CATALOG_COLLECT_LARGER"
  else
    ALV_CATALOG_SIZE_BYTES=-1
  fi
  case "$ALV_CATALOG_COLLECT_SORT" in
    name|created|size) ;;
    *) alv_fail "--sort must be name, created, or size" ;;
  esac
  if [ -n "$ALV_CATALOG_COLLECT_LIMIT" ]; then
    alv_catalog_validate_positive_integer --limit "$ALV_CATALOG_COLLECT_LIMIT"
  fi

  alv_catalog_cleanup
  ALV_CATALOG_TEMP_BASE=${TMPDIR:-/tmp}
  ALV_CATALOG_TEMP_BASE=$(alv_canonical_directory "$ALV_CATALOG_TEMP_BASE")
  ALV_CATALOG_TEMP_DIRECTORY=$(mktemp -d \
    "$ALV_CATALOG_TEMP_BASE/agent-log-vault-catalog.XXXXXX") || \
    alv_fail "could not create a temporary catalog directory"
  chmod 700 "$ALV_CATALOG_TEMP_DIRECTORY"
  ALV_CATALOG_RECORDS=$ALV_CATALOG_TEMP_DIRECTORY/records
  ALV_CATALOG_RESULTS=$ALV_CATALOG_TEMP_DIRECTORY/results.json
  alv_catalog_emit_codex_records > "$ALV_CATALOG_RECORDS" || \
    alv_fail "could not read the Codex archive"

  if ! jq -Rsc \
    --arg before "$ALV_CATALOG_COLLECT_BEFORE" \
    --arg after "$ALV_CATALOG_COLLECT_AFTER" \
    --arg project "$ALV_CATALOG_COLLECT_PROJECT" \
    --arg sort "$ALV_CATALOG_COLLECT_SORT" \
    --arg limit "$ALV_CATALOG_COLLECT_LIMIT" \
    --argjson larger "$ALV_CATALOG_SIZE_BYTES" '
      def cwd_name:
        split("/") | map(select(length > 0)) |
        if length == 0 then "" else .[-1] end;
      split("\n") |
      map(select(length > 0) |
        split("\t") as $parts |
        if ($parts | length) < 3 then error("invalid catalog record") else . end |
        ($parts[2:] | join("\t") | fromjson) as $metadata |
        if $metadata.type != "session_meta"
          then error("first JSONL record is not session_meta")
          else {
            name: $parts[0],
            bytes: ($parts[1] | tonumber),
            id: ($metadata.payload.id // ""),
            created: ($metadata.payload.timestamp // $metadata.timestamp // ""),
            cwd: ($metadata.payload.cwd // ""),
            project: (($metadata.payload.cwd // "") | cwd_name)
          }
        end
      ) |
      map(select($before == "" or ((.created | length) >= 10 and .created[0:10] < $before))) |
      map(select($after == "" or ((.created | length) >= 10 and .created[0:10] > $after))) |
      map(select($project == "" or .cwd == $project or .project == $project)) |
      map(select(.bytes > $larger)) |
      if $sort == "size" then sort_by(.bytes, .name) | reverse
      elif $sort == "created" then sort_by(.created, .name) | reverse
      else sort_by(.name)
      end |
      if $limit == "" then . else .[0:($limit | tonumber)] end
    ' "$ALV_CATALOG_RECORDS" > "$ALV_CATALOG_RESULTS"; then
    alv_fail "could not parse Codex session metadata"
  fi
}

alv_catalog_list_codex() {
  ALV_CATALOG_LIST_HOME=$1
  ALV_CATALOG_LIST_LONG=$2
  ALV_CATALOG_LIST_BEFORE=$3
  ALV_CATALOG_LIST_AFTER=$4
  ALV_CATALOG_LIST_PROJECT=$5
  ALV_CATALOG_LIST_LARGER=$6
  ALV_CATALOG_LIST_SORT=$7
  ALV_CATALOG_LIST_LIMIT=$8
  ALV_CATALOG_LIST_JSON=$9

  alv_catalog_collect \
    "$ALV_CATALOG_LIST_HOME" "$ALV_CATALOG_LIST_BEFORE" \
    "$ALV_CATALOG_LIST_AFTER" "$ALV_CATALOG_LIST_PROJECT" \
    "$ALV_CATALOG_LIST_LARGER" "$ALV_CATALOG_LIST_SORT" \
    "$ALV_CATALOG_LIST_LIMIT"

  if [ "$ALV_CATALOG_LIST_JSON" = true ]; then
    jq -c '.' "$ALV_CATALOG_RESULTS"
  elif [ "$ALV_CATALOG_LIST_LONG" = true ]; then
    printf 'CREATED\tBYTES\tCWD\tCHAT\n'
    jq -r '.[] | [.created, (.bytes | tostring), .cwd, .name] | @tsv' \
      "$ALV_CATALOG_RESULTS"
  else
    jq -r '.[].name' "$ALV_CATALOG_RESULTS"
  fi
  alv_catalog_cleanup
}

alv_catalog_disk_bytes() {
  if [ -d "$ALV_CATALOG_ARCHIVED" ]; then
    ALV_CATALOG_DISK_KIB=$(du -sk "$ALV_CATALOG_ARCHIVED" 2>/dev/null | \
      awk 'NR == 1 { print $1 }') || alv_fail "could not measure archive disk usage"
    case "$ALV_CATALOG_DISK_KIB" in
      ''|*[!0-9]*) alv_fail "could not measure archive disk usage" ;;
    esac
    ALV_CATALOG_ON_DISK_BYTES=$((ALV_CATALOG_DISK_KIB * 1024))
    ALV_CATALOG_DISK_TARGET=$ALV_CATALOG_ARCHIVED
  else
    ALV_CATALOG_ON_DISK_BYTES=0
    ALV_CATALOG_DISK_TARGET=$ALV_CATALOG_CODEX_HOME
  fi

  ALV_CATALOG_AVAILABLE_KIB=$(df -k "$ALV_CATALOG_DISK_TARGET" 2>/dev/null | \
    awk 'END { print $4 }') || alv_fail "could not measure available disk space"
  case "$ALV_CATALOG_AVAILABLE_KIB" in
    ''|*[!0-9]*) alv_fail "could not measure available disk space" ;;
  esac
  ALV_CATALOG_AVAILABLE_BYTES=$((ALV_CATALOG_AVAILABLE_KIB * 1024))
}

alv_catalog_stats_codex() {
  ALV_CATALOG_STATS_HOME=$1
  ALV_CATALOG_STATS_TOP=$2
  ALV_CATALOG_STATS_BY_PROJECT=$3
  ALV_CATALOG_STATS_JSON=$4

  if [ -n "$ALV_CATALOG_STATS_TOP" ]; then
    alv_catalog_validate_positive_integer --top "$ALV_CATALOG_STATS_TOP"
  else
    ALV_CATALOG_STATS_TOP=0
  fi
  alv_catalog_collect "$ALV_CATALOG_STATS_HOME" '' '' '' '' name ''
  alv_catalog_disk_bytes
  ALV_CATALOG_STATS_FILE=$ALV_CATALOG_TEMP_DIRECTORY/stats.json
  jq \
    --argjson on_disk "$ALV_CATALOG_ON_DISK_BYTES" \
    --argjson available "$ALV_CATALOG_AVAILABLE_BYTES" \
    --argjson top "$ALV_CATALOG_STATS_TOP" \
    --argjson by_project "$ALV_CATALOG_STATS_BY_PROJECT" '
      def created_epoch:
        if (.created | length) >= 19 then
          try ((.created[0:19] + "Z") | fromdateiso8601) catch null
        else null end;
      . as $threads |
      ($threads | map(. + {created_epoch: created_epoch})) as $dated |
      {
        threads: ($threads | length),
        logical_bytes: (($threads | map(.bytes) | add) // 0),
        on_disk_bytes: $on_disk,
        available_bytes: $available,
        oldest_created: (($threads | map(select(.created != "")) | sort_by(.created) | first | .created) // null),
        newest_created: (($threads | map(select(.created != "")) | sort_by(.created) | last | .created) // null),
        largest: (($threads | sort_by(.bytes, .name) | last) // null),
        age: {
          last_30_days: ($dated | map(select(.created_epoch != null and (now - .created_epoch) <= (30 * 86400))) | length),
          days_31_to_90: ($dated | map(select(.created_epoch != null and (now - .created_epoch) > (30 * 86400) and (now - .created_epoch) <= (90 * 86400))) | length),
          older_than_90_days: ($dated | map(select(.created_epoch != null and (now - .created_epoch) > (90 * 86400))) | length),
          unknown: ($dated | map(select(.created_epoch == null)) | length)
        },
        top: (if $top > 0 then ($threads | sort_by(.bytes, .name) | reverse | .[0:$top]) else [] end),
        projects: (if $by_project then
          ($threads | group_by(.project) |
            map({project: .[0].project, threads: length, logical_bytes: (map(.bytes) | add)}) |
            sort_by(.logical_bytes, .project) | reverse)
          else [] end)
      }
    ' "$ALV_CATALOG_RESULTS" > "$ALV_CATALOG_STATS_FILE"

  if [ "$ALV_CATALOG_STATS_JSON" = true ]; then
    jq -c '.' "$ALV_CATALOG_STATS_FILE"
  else
    jq -r '
      "threads\t\(.threads)",
      "logical_bytes\t\(.logical_bytes)",
      "on_disk_bytes\t\(.on_disk_bytes)",
      "available_bytes\t\(.available_bytes)",
      "oldest_created\t\(.oldest_created // "")",
      "newest_created\t\(.newest_created // "")",
      "largest_chat\t\(.largest.name // "")",
      "largest_bytes\t\(.largest.bytes // 0)",
      "age_last_30_days\t\(.age.last_30_days)",
      "age_days_31_to_90\t\(.age.days_31_to_90)",
      "age_older_than_90_days\t\(.age.older_than_90_days)",
      "age_unknown\t\(.age.unknown)",
      if (.top | length) > 0 then "TOP\tBYTES\tCREATED\tPROJECT\tCHAT", (.top[] | ["top", (.bytes | tostring), .created, .project, .name] | @tsv) else empty end,
      if (.projects | length) > 0 then "PROJECT\tTHREADS\tLOGICAL_BYTES", (.projects[] | [.project, (.threads | tostring), (.logical_bytes | tostring)] | @tsv) else empty end
    ' "$ALV_CATALOG_STATS_FILE"
  fi
  alv_catalog_cleanup
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
