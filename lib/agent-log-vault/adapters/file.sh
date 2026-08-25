# Filesystem storage adapter for directories and mounted filesystems.

alv_file_storage_open() {
  ALV_FILE_STORAGE_LOCATION=$1
  ALV_FILE_STORAGE_MODE=$2
  ALV_FILE_STORAGE_INPUT=${ALV_FILE_STORAGE_LOCATION#file:}

  [ -n "$ALV_FILE_STORAGE_INPUT" ] || \
    alv_fail "file: location requires an absolute directory path"
  case "$ALV_FILE_STORAGE_INPUT" in
    /*) ;;
    *) alv_fail "file: location must use an absolute directory path" ;;
  esac

  ALV_FILE_STORAGE_ROOT=$(alv_canonical_directory "$ALV_FILE_STORAGE_INPUT")
  [ "$ALV_FILE_STORAGE_ROOT" != / ] || \
    alv_fail "filesystem root cannot be used as a vault"

  ALV_FILE_STORAGE_ARCHIVED=$ALV_FILE_STORAGE_ROOT/archived_sessions
  [ ! -L "$ALV_FILE_STORAGE_ARCHIVED" ] || \
    alv_fail "vault archived_sessions path is a symbolic link"

  if [ -d "$ALV_FILE_STORAGE_ARCHIVED" ]; then
    ALV_FILE_STORAGE_ARCHIVED=$(alv_canonical_directory "$ALV_FILE_STORAGE_ARCHIVED")
    case "$ALV_FILE_STORAGE_ARCHIVED" in
      "$ALV_FILE_STORAGE_ROOT"/*) ;;
      *) alv_fail "vault archived_sessions directory escapes the vault root" ;;
    esac
  fi
}

alv_file_storage_prepare_archived() {
  [ ! -L "$ALV_FILE_STORAGE_ARCHIVED" ] || \
    alv_fail "vault archived_sessions path is a symbolic link"
  mkdir -p "$ALV_FILE_STORAGE_ARCHIVED"
  ALV_FILE_STORAGE_ARCHIVED=$(alv_canonical_directory "$ALV_FILE_STORAGE_ARCHIVED")
  case "$ALV_FILE_STORAGE_ARCHIVED" in
    "$ALV_FILE_STORAGE_ROOT"/*) ;;
    *) alv_fail "vault archived_sessions directory escapes the vault root" ;;
  esac
}

alv_file_storage_require_archived() {
  [ -d "$ALV_FILE_STORAGE_ARCHIVED" ] || \
    alv_fail "vault has no archived_sessions directory: $ALV_FILE_STORAGE_ROOT"
  [ ! -L "$ALV_FILE_STORAGE_ARCHIVED" ] || \
    alv_fail "vault archived_sessions path is a symbolic link"
}

alv_file_storage_assert_external_to() {
  ALV_FILE_STORAGE_CODEX_HOME=$(alv_canonical_directory "$1")

  case "$ALV_FILE_STORAGE_ROOT" in
    "$ALV_FILE_STORAGE_CODEX_HOME"|"$ALV_FILE_STORAGE_CODEX_HOME"/*)
      alv_fail "vault must be outside the Codex home"
      ;;
  esac
  case "$ALV_FILE_STORAGE_CODEX_HOME" in
    "$ALV_FILE_STORAGE_ROOT"|"$ALV_FILE_STORAGE_ROOT"/*)
      alv_fail "vault and Codex home must not contain one another"
      ;;
  esac
}

alv_file_storage_put() {
  ALV_FILE_STORAGE_SOURCE=$1
  ALV_FILE_STORAGE_NAME=$(alv_rollout_name "$2")
  alv_file_storage_prepare_archived
  alv_file_storage_require_archived

  ALV_FILE_STORAGE_DESTINATION=$ALV_FILE_STORAGE_ARCHIVED/$ALV_FILE_STORAGE_NAME
  ALV_FILE_STORAGE_CHECKSUM=${ALV_FILE_STORAGE_DESTINATION}.sha256

  [ ! -e "$ALV_FILE_STORAGE_CHECKSUM" ] || \
    alv_fail "refusing to overwrite: $ALV_FILE_STORAGE_CHECKSUM"
  [ ! -L "$ALV_FILE_STORAGE_CHECKSUM" ] || \
    alv_fail "refusing to overwrite symbolic link: $ALV_FILE_STORAGE_CHECKSUM"

  alv_copy_verified "$ALV_FILE_STORAGE_SOURCE" "$ALV_FILE_STORAGE_DESTINATION"

  ALV_TEMP_SUM=${ALV_FILE_STORAGE_CHECKSUM}.partial.$$
  [ ! -e "$ALV_TEMP_SUM" ] || \
    alv_fail "temporary path already exists: $ALV_TEMP_SUM"
  printf '%s  %s\n' "$ALV_COPY_HASH" "$ALV_FILE_STORAGE_NAME" > "$ALV_TEMP_SUM"
  chmod 600 "$ALV_TEMP_SUM"
  [ ! -e "$ALV_FILE_STORAGE_CHECKSUM" ] || \
    alv_fail "checksum destination appeared while copying"
  mv "$ALV_TEMP_SUM" "$ALV_FILE_STORAGE_CHECKSUM"
  ALV_TEMP_SUM=

  ALV_STORAGE_HASH=$ALV_COPY_HASH
  ALV_STORAGE_SIZE=$(alv_file_size "$ALV_FILE_STORAGE_DESTINATION")
}

alv_file_storage_verify() {
  ALV_FILE_STORAGE_NAME=$(alv_rollout_name "$1")
  alv_file_storage_require_archived

  ALV_FILE_STORAGE_FILE=$ALV_FILE_STORAGE_ARCHIVED/$ALV_FILE_STORAGE_NAME
  ALV_FILE_STORAGE_CHECKSUM=${ALV_FILE_STORAGE_FILE}.sha256
  alv_require_regular_file "$ALV_FILE_STORAGE_FILE"
  alv_require_regular_file "$ALV_FILE_STORAGE_CHECKSUM"

  if ! IFS=' ' read -r ALV_EXPECTED_HASH ALV_RECORDED_NAME < "$ALV_FILE_STORAGE_CHECKSUM"; then
    alv_fail "could not read checksum sidecar: $ALV_FILE_STORAGE_CHECKSUM"
  fi

  [ "${#ALV_EXPECTED_HASH}" -eq 64 ] || \
    alv_fail "invalid SHA-256 value in: $ALV_FILE_STORAGE_CHECKSUM"
  case "$ALV_EXPECTED_HASH" in
    *[!0-9A-Fa-f]*) alv_fail "invalid SHA-256 value in: $ALV_FILE_STORAGE_CHECKSUM" ;;
  esac
  [ "$ALV_RECORDED_NAME" = "$ALV_FILE_STORAGE_NAME" ] || \
    alv_fail "checksum sidecar names a different chat"

  ALV_EXPECTED_HASH=$(printf '%s' "$ALV_EXPECTED_HASH" | tr 'A-F' 'a-f')
  ALV_ACTUAL_HASH=$(alv_sha256_file "$ALV_FILE_STORAGE_FILE")
  [ "$ALV_EXPECTED_HASH" = "$ALV_ACTUAL_HASH" ] || \
    alv_fail "checksum mismatch: $ALV_FILE_STORAGE_FILE"

  ALV_STORAGE_HASH=$ALV_ACTUAL_HASH
  ALV_STORAGE_SIZE=$(alv_file_size "$ALV_FILE_STORAGE_FILE")
  ALV_FILE_STORAGE_VERIFIED_FILE=$ALV_FILE_STORAGE_FILE
}

alv_file_storage_get() {
  ALV_FILE_STORAGE_GET_NAME=$(alv_rollout_name "$1")
  ALV_FILE_STORAGE_GET_DESTINATION=$2

  alv_file_storage_verify "$ALV_FILE_STORAGE_GET_NAME"
  ALV_FILE_STORAGE_GET_HASH=$ALV_STORAGE_HASH
  alv_copy_verified "$ALV_FILE_STORAGE_VERIFIED_FILE" "$ALV_FILE_STORAGE_GET_DESTINATION"
  [ "$ALV_COPY_HASH" = "$ALV_FILE_STORAGE_GET_HASH" ] || \
    alv_fail "restored bytes do not match the vaulted checksum"

  ALV_STORAGE_HASH=$ALV_COPY_HASH
  ALV_STORAGE_SIZE=$(alv_file_size "$ALV_FILE_STORAGE_GET_DESTINATION")
}

alv_file_storage_list() {
  [ -d "$ALV_FILE_STORAGE_ARCHIVED" ] || return 0
  alv_file_storage_require_archived

  for ALV_FILE_STORAGE_LIST_FILE in "$ALV_FILE_STORAGE_ARCHIVED"/rollout-*.jsonl; do
    [ -e "$ALV_FILE_STORAGE_LIST_FILE" ] || continue
    alv_require_regular_file "$ALV_FILE_STORAGE_LIST_FILE"
    ALV_FILE_STORAGE_LIST_NAME=$(alv_rollout_name "$ALV_FILE_STORAGE_LIST_FILE")
    ALV_FILE_STORAGE_LIST_SUM=${ALV_FILE_STORAGE_LIST_FILE}.sha256
    [ -f "$ALV_FILE_STORAGE_LIST_SUM" ] || continue
    [ ! -L "$ALV_FILE_STORAGE_LIST_SUM" ] || \
      alv_fail "symbolic links are not accepted: $ALV_FILE_STORAGE_LIST_SUM"
    printf '%s\n' "$ALV_FILE_STORAGE_LIST_NAME"
  done
}
