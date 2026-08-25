# Encrypted rclone storage implementation.
#
# Locations use rclone:<crypt-remote>:<optional-root>. The named rclone remote
# must be a configured crypt backend. Provider credentials, crypt passwords,
# and the underlying provider remote remain entirely in rclone's config.

ALV_RCLONE_TEMP_BASE=
ALV_RCLONE_TEMP_DIRECTORY=

alv_rclone_storage_cleanup() {
  [ -n "${ALV_RCLONE_TEMP_DIRECTORY:-}" ] || return 0

  case "$ALV_RCLONE_TEMP_DIRECTORY" in
    "$ALV_RCLONE_TEMP_BASE"/agent-log-vault-rclone.*)
      if [ -e "$ALV_RCLONE_TEMP_DIRECTORY" ]; then
        /bin/rm -rf "$ALV_RCLONE_TEMP_DIRECTORY"
      fi
      ;;
  esac

  ALV_RCLONE_TEMP_DIRECTORY=
}

alv_rclone_storage_make_temp() {
  [ -z "${ALV_RCLONE_TEMP_DIRECTORY:-}" ] || return 0

  ALV_RCLONE_TEMP_BASE=${TMPDIR:-/tmp}
  ALV_RCLONE_TEMP_BASE=$(alv_canonical_directory "$ALV_RCLONE_TEMP_BASE")
  ALV_RCLONE_TEMP_DIRECTORY=$(mktemp -d \
    "$ALV_RCLONE_TEMP_BASE/agent-log-vault-rclone.XXXXXX") || \
    alv_fail "could not create a temporary rclone directory"
  chmod 700 "$ALV_RCLONE_TEMP_DIRECTORY"
}

alv_rclone_storage_validate_root() {
  ALV_RCLONE_VALIDATE_ROOT=$1
  [ -n "$ALV_RCLONE_VALIDATE_ROOT" ] || return 0

  case "$ALV_RCLONE_VALIDATE_ROOT" in
    /*|*/|*//*|*:*|*'
'*|*'	'*|*''*)
      alv_fail "rclone root must be a normalized relative path"
      ;;
  esac

  case "/$ALV_RCLONE_VALIDATE_ROOT/" in
    */./*|*/../*)
      alv_fail "rclone root cannot contain . or .. components"
      ;;
  esac
}

alv_rclone_storage_open() {
  ALV_RCLONE_STORAGE_LOCATION=$1
  ALV_RCLONE_STORAGE_INPUT=${ALV_RCLONE_STORAGE_LOCATION#rclone:}

  command -v rclone >/dev/null 2>&1 || \
    alv_fail "rclone is required for rclone: storage locations"

  case "$ALV_RCLONE_STORAGE_INPUT" in
    *:*) ;;
    *) alv_fail "rclone: location must be rclone:<crypt-remote>:<root>" ;;
  esac

  ALV_RCLONE_STORAGE_REMOTE=${ALV_RCLONE_STORAGE_INPUT%%:*}
  ALV_RCLONE_STORAGE_ROOT=${ALV_RCLONE_STORAGE_INPUT#*:}
  case "$ALV_RCLONE_STORAGE_REMOTE" in
    ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*)
      alv_fail "rclone remote name contains unsupported characters"
      ;;
  esac
  alv_rclone_storage_validate_root "$ALV_RCLONE_STORAGE_ROOT"

  ALV_RCLONE_STORAGE_REDACTED=
  if ! ALV_RCLONE_STORAGE_REDACTED=$(rclone config redacted \
    "$ALV_RCLONE_STORAGE_REMOTE" 2>/dev/null); then
    alv_fail "cannot read rclone remote configuration: $ALV_RCLONE_STORAGE_REMOTE"
  fi
  if ! printf '%s\n' "$ALV_RCLONE_STORAGE_REDACTED" | \
      grep -Eq '^type[[:space:]]*=[[:space:]]*crypt[[:space:]]*$'; then
    alv_fail "rclone remote must be a crypt remote: $ALV_RCLONE_STORAGE_REMOTE"
  fi
  if printf '%s\n' "$ALV_RCLONE_STORAGE_REDACTED" | \
      grep -Eq '^filename_encryption[[:space:]]*=[[:space:]]*(off|obfuscate)[[:space:]]*$'; then
    alv_fail "rclone crypt remote must use standard filename encryption"
  fi
  if printf '%s\n' "$ALV_RCLONE_STORAGE_REDACTED" | \
      grep -Eq '^directory_name_encryption[[:space:]]*=[[:space:]]*false[[:space:]]*$'; then
    alv_fail "rclone crypt remote must encrypt directory names"
  fi
  if printf '%s\n' "$ALV_RCLONE_STORAGE_REDACTED" | \
      grep -Eq '^no_data_encryption[[:space:]]*=[[:space:]]*true[[:space:]]*$'; then
    alv_fail "rclone crypt remote must encrypt file contents"
  fi
  ALV_RCLONE_STORAGE_BACKING=$(printf '%s\n' "$ALV_RCLONE_STORAGE_REDACTED" |
    sed -n 's/^[[:space:]]*remote[[:space:]]*=[[:space:]]*//p' | sed -n '1p')
  [ -n "$ALV_RCLONE_STORAGE_BACKING" ] || \
    alv_fail "rclone crypt remote has no backing target"
  ALV_RCLONE_STORAGE_REDACTED=

  if [ -n "$ALV_RCLONE_STORAGE_ROOT" ]; then
    ALV_RCLONE_STORAGE_ARCHIVED=$ALV_RCLONE_STORAGE_REMOTE:$ALV_RCLONE_STORAGE_ROOT/archived_sessions
  else
    ALV_RCLONE_STORAGE_ARCHIVED=$ALV_RCLONE_STORAGE_REMOTE:archived_sessions
  fi
}

alv_rclone_storage_refresh_listing() {
  ALV_RCLONE_STORAGE_LISTING=
  if ALV_RCLONE_STORAGE_LISTING=$(rclone lsf \
    "$ALV_RCLONE_STORAGE_ARCHIVED" \
    --files-only \
    --max-depth 1 \
    --quiet 2>/dev/null); then
    return 0
  else
    ALV_RCLONE_STORAGE_LIST_STATUS=$?
  fi

  case "$ALV_RCLONE_STORAGE_LIST_STATUS" in
    3) ALV_RCLONE_STORAGE_LISTING= ;;
    *) alv_fail "could not list rclone location: $ALV_RCLONE_STORAGE_LOCATION" ;;
  esac
}

alv_rclone_storage_listing_has() {
  printf '%s\n' "$ALV_RCLONE_STORAGE_LISTING" | grep -Fqx "$1"
}

alv_rclone_storage_copyto() {
  ALV_RCLONE_COPY_SOURCE=$1
  ALV_RCLONE_COPY_DESTINATION=$2
  ALV_RCLONE_COPY_DESCRIPTION=$3

  if ! rclone copyto \
    "$ALV_RCLONE_COPY_SOURCE" \
    "$ALV_RCLONE_COPY_DESTINATION" \
    --immutable \
    --quiet; then
    alv_fail "$ALV_RCLONE_COPY_DESCRIPTION"
  fi
}

alv_rclone_storage_validate_download() {
  ALV_RCLONE_VALIDATE_NAME=$1
  ALV_RCLONE_VALIDATE_FILE=$2
  ALV_RCLONE_VALIDATE_SUM=$3

  alv_require_regular_file "$ALV_RCLONE_VALIDATE_FILE"
  alv_require_regular_file "$ALV_RCLONE_VALIDATE_SUM"
  if ! IFS=' ' read -r \
      ALV_RCLONE_EXPECTED_HASH \
      ALV_RCLONE_RECORDED_NAME < "$ALV_RCLONE_VALIDATE_SUM"; then
    alv_fail "could not read downloaded checksum sidecar"
  fi

  [ "${#ALV_RCLONE_EXPECTED_HASH}" -eq 64 ] || \
    alv_fail "downloaded sidecar contains an invalid SHA-256 value"
  case "$ALV_RCLONE_EXPECTED_HASH" in
    *[!0-9A-Fa-f]*)
      alv_fail "downloaded sidecar contains an invalid SHA-256 value"
      ;;
  esac
  [ "$ALV_RCLONE_RECORDED_NAME" = "$ALV_RCLONE_VALIDATE_NAME" ] || \
    alv_fail "downloaded checksum sidecar names a different chat"

  ALV_RCLONE_EXPECTED_HASH=$(printf '%s' "$ALV_RCLONE_EXPECTED_HASH" | \
    tr 'A-F' 'a-f')
  ALV_RCLONE_ACTUAL_HASH=$(alv_sha256_file "$ALV_RCLONE_VALIDATE_FILE")
  [ "$ALV_RCLONE_EXPECTED_HASH" = "$ALV_RCLONE_ACTUAL_HASH" ] || \
    alv_fail "downloaded rclone bytes do not match their checksum"

  ALV_STORAGE_HASH=$ALV_RCLONE_ACTUAL_HASH
  ALV_STORAGE_SIZE=$(alv_file_size "$ALV_RCLONE_VALIDATE_FILE")
  ALV_RCLONE_VERIFIED_FILE=$ALV_RCLONE_VALIDATE_FILE
}

alv_rclone_storage_download_verified() {
  ALV_RCLONE_DOWNLOAD_NAME=$(alv_rollout_name "$1")
  alv_rclone_storage_refresh_listing
  alv_rclone_storage_listing_has "$ALV_RCLONE_DOWNLOAD_NAME" || \
    alv_fail "stored rclone chat does not exist: $ALV_RCLONE_DOWNLOAD_NAME"
  alv_rclone_storage_listing_has "$ALV_RCLONE_DOWNLOAD_NAME.sha256" || \
    alv_fail "stored rclone chat has no checksum: $ALV_RCLONE_DOWNLOAD_NAME"

  alv_rclone_storage_make_temp
  ALV_RCLONE_DOWNLOAD_FILE=$ALV_RCLONE_TEMP_DIRECTORY/$ALV_RCLONE_DOWNLOAD_NAME
  ALV_RCLONE_DOWNLOAD_SUM=${ALV_RCLONE_DOWNLOAD_FILE}.sha256
  ALV_RCLONE_DOWNLOAD_REMOTE=$ALV_RCLONE_STORAGE_ARCHIVED/$ALV_RCLONE_DOWNLOAD_NAME

  alv_rclone_storage_copyto \
    "$ALV_RCLONE_DOWNLOAD_REMOTE" \
    "$ALV_RCLONE_DOWNLOAD_FILE" \
    "could not download rclone chat: $ALV_RCLONE_DOWNLOAD_NAME"
  alv_rclone_storage_copyto \
    "$ALV_RCLONE_DOWNLOAD_REMOTE.sha256" \
    "$ALV_RCLONE_DOWNLOAD_SUM" \
    "could not download rclone checksum: $ALV_RCLONE_DOWNLOAD_NAME"
  alv_rclone_storage_validate_download \
    "$ALV_RCLONE_DOWNLOAD_NAME" \
    "$ALV_RCLONE_DOWNLOAD_FILE" \
    "$ALV_RCLONE_DOWNLOAD_SUM"
}

alv_rclone_storage_put() {
  ALV_RCLONE_PUT_SOURCE=$1
  ALV_RCLONE_PUT_NAME=$(alv_rollout_name "$2")
  ALV_RCLONE_PUT_REMOTE=$ALV_RCLONE_STORAGE_ARCHIVED/$ALV_RCLONE_PUT_NAME
  ALV_RCLONE_PUT_SUM_REMOTE=${ALV_RCLONE_PUT_REMOTE}.sha256
  ALV_RCLONE_PUT_HASH=$(alv_sha256_file "$ALV_RCLONE_PUT_SOURCE")

  alv_rclone_storage_refresh_listing
  ALV_RCLONE_PUT_DATA_EXISTS=false
  ALV_RCLONE_PUT_SUM_EXISTS=false
  if alv_rclone_storage_listing_has "$ALV_RCLONE_PUT_NAME"; then
    ALV_RCLONE_PUT_DATA_EXISTS=true
  fi
  if alv_rclone_storage_listing_has "$ALV_RCLONE_PUT_NAME.sha256"; then
    ALV_RCLONE_PUT_SUM_EXISTS=true
  fi

  if [ "$ALV_RCLONE_PUT_DATA_EXISTS" = true ] && \
     [ "$ALV_RCLONE_PUT_SUM_EXISTS" = true ]; then
    alv_fail "refusing to overwrite completed rclone chat: $ALV_RCLONE_PUT_NAME"
  fi
  if [ "$ALV_RCLONE_PUT_DATA_EXISTS" = false ] && \
     [ "$ALV_RCLONE_PUT_SUM_EXISTS" = true ]; then
    alv_fail "rclone checksum exists without its chat: $ALV_RCLONE_PUT_NAME"
  fi

  if [ "$ALV_RCLONE_PUT_DATA_EXISTS" = true ]; then
    alv_rclone_storage_make_temp
    ALV_RCLONE_PUT_ORPHAN=$ALV_RCLONE_TEMP_DIRECTORY/orphan.jsonl
    alv_rclone_storage_copyto \
      "$ALV_RCLONE_PUT_REMOTE" \
      "$ALV_RCLONE_PUT_ORPHAN" \
      "could not inspect incomplete rclone chat: $ALV_RCLONE_PUT_NAME"
    ALV_RCLONE_PUT_ORPHAN_HASH=$(alv_sha256_file "$ALV_RCLONE_PUT_ORPHAN")
    [ "$ALV_RCLONE_PUT_ORPHAN_HASH" = "$ALV_RCLONE_PUT_HASH" ] || \
      alv_fail "incomplete rclone chat does not match the Codex source"
  else
    alv_rclone_storage_copyto \
      "$ALV_RCLONE_PUT_SOURCE" \
      "$ALV_RCLONE_PUT_REMOTE" \
      "could not upload rclone chat: $ALV_RCLONE_PUT_NAME"
  fi

  ALV_RCLONE_PUT_SOURCE_HASH_AFTER=$(alv_sha256_file "$ALV_RCLONE_PUT_SOURCE")
  [ "$ALV_RCLONE_PUT_HASH" = "$ALV_RCLONE_PUT_SOURCE_HASH_AFTER" ] || \
    alv_fail "source changed while it was being uploaded"

  alv_rclone_storage_refresh_listing
  alv_rclone_storage_listing_has "$ALV_RCLONE_PUT_NAME" || \
    alv_fail "uploaded rclone chat could not be rediscovered"
  if alv_rclone_storage_listing_has "$ALV_RCLONE_PUT_NAME.sha256"; then
    alv_fail "checksum appeared while the rclone chat was being uploaded"
  fi

  alv_rclone_storage_make_temp
  ALV_RCLONE_PUT_SUM=$ALV_RCLONE_TEMP_DIRECTORY/$ALV_RCLONE_PUT_NAME.sha256
  printf '%s  %s\n' "$ALV_RCLONE_PUT_HASH" "$ALV_RCLONE_PUT_NAME" > \
    "$ALV_RCLONE_PUT_SUM"
  chmod 600 "$ALV_RCLONE_PUT_SUM"
  alv_rclone_storage_copyto \
    "$ALV_RCLONE_PUT_SUM" \
    "$ALV_RCLONE_PUT_SUM_REMOTE" \
    "could not upload rclone checksum: $ALV_RCLONE_PUT_NAME"
  alv_rclone_storage_cleanup

  alv_rclone_storage_download_verified "$ALV_RCLONE_PUT_NAME"
  [ "$ALV_STORAGE_HASH" = "$ALV_RCLONE_PUT_HASH" ] || \
    alv_fail "verified rclone chat does not match the Codex source"
  ALV_RCLONE_PUT_SOURCE_HASH_FINAL=$(alv_sha256_file "$ALV_RCLONE_PUT_SOURCE")
  [ "$ALV_RCLONE_PUT_HASH" = "$ALV_RCLONE_PUT_SOURCE_HASH_FINAL" ] || \
    alv_fail "source changed while the remote copy was being verified"
  alv_rclone_storage_cleanup
}

alv_rclone_storage_verify() {
  ALV_RCLONE_VERIFY_NAME=$(alv_rollout_name "$1")
  alv_rclone_storage_download_verified "$ALV_RCLONE_VERIFY_NAME"
  alv_rclone_storage_cleanup
}

alv_rclone_storage_get() {
  ALV_RCLONE_GET_NAME=$(alv_rollout_name "$1")
  ALV_RCLONE_GET_DESTINATION=$2
  alv_rclone_storage_download_verified "$ALV_RCLONE_GET_NAME"
  ALV_RCLONE_GET_HASH=$ALV_STORAGE_HASH

  alv_copy_verified "$ALV_RCLONE_VERIFIED_FILE" "$ALV_RCLONE_GET_DESTINATION"
  [ "$ALV_COPY_HASH" = "$ALV_RCLONE_GET_HASH" ] || \
    alv_fail "restored bytes do not match the rclone checksum"

  ALV_STORAGE_HASH=$ALV_COPY_HASH
  # Consumed by command workflows in the main executable.
  # shellcheck disable=SC2034
  ALV_STORAGE_SIZE=$(alv_file_size "$ALV_RCLONE_GET_DESTINATION")
  alv_rclone_storage_cleanup
}

alv_rclone_storage_list() {
  alv_rclone_storage_refresh_listing
  printf '%s\n' "$ALV_RCLONE_STORAGE_LISTING" |
    while IFS= read -r ALV_RCLONE_LIST_NAME; do
      case "$ALV_RCLONE_LIST_NAME" in
        rollout-*.jsonl)
          case "$ALV_RCLONE_LIST_NAME" in
            *[!A-Za-z0-9._-]*) continue ;;
          esac
          if alv_rclone_storage_listing_has "$ALV_RCLONE_LIST_NAME.sha256"; then
            printf '%s\n' "$ALV_RCLONE_LIST_NAME"
          fi
          ;;
      esac
    done
}

alv_rclone_storage_inventory() {
  alv_rclone_storage_refresh_listing
  printf '%s\n' "$ALV_RCLONE_STORAGE_LISTING" |
    while IFS= read -r ALV_RCLONE_INVENTORY_NAME; do
      case "$ALV_RCLONE_INVENTORY_NAME" in
        rollout-*.jsonl|rollout-*.jsonl.sha256)
          case "$ALV_RCLONE_INVENTORY_NAME" in
            *[!A-Za-z0-9._-]*) continue ;;
          esac
          printf '%s\n' "$ALV_RCLONE_INVENTORY_NAME"
          ;;
      esac
    done
}

alv_rclone_storage_has() {
  ALV_RCLONE_HAS_NAME=$(alv_rollout_name "$1")
  alv_rclone_storage_refresh_listing
  ALV_STORAGE_PRESENT=false
  if alv_rclone_storage_listing_has "$ALV_RCLONE_HAS_NAME" && \
     alv_rclone_storage_listing_has "$ALV_RCLONE_HAS_NAME.sha256"; then
    # Consumed by command workflows in the main executable.
    # shellcheck disable=SC2034
    ALV_STORAGE_PRESENT=true
  fi
}

alv_rclone_storage_assert_external_to() {
  ALV_RCLONE_EXTERNAL_CODEX_HOME=$(alv_canonical_directory "$1")
  case "$ALV_RCLONE_STORAGE_BACKING" in
    /*)
      [ -d "$ALV_RCLONE_STORAGE_BACKING" ] || \
        alv_fail "local vault backing directory does not exist"
      ALV_RCLONE_EXTERNAL_BACKING=$(alv_canonical_directory \
        "$ALV_RCLONE_STORAGE_BACKING")
      case "$ALV_RCLONE_EXTERNAL_BACKING" in
        "$ALV_RCLONE_EXTERNAL_CODEX_HOME"|"$ALV_RCLONE_EXTERNAL_CODEX_HOME"/*)
          alv_fail "vault must be outside the Codex home"
          ;;
      esac
      case "$ALV_RCLONE_EXTERNAL_CODEX_HOME" in
        "$ALV_RCLONE_EXTERNAL_BACKING"|"$ALV_RCLONE_EXTERNAL_BACKING"/*)
          alv_fail "vault and Codex home must not contain one another"
          ;;
      esac
      ;;
  esac
}
