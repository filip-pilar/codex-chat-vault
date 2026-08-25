# Storage adapter dispatcher.
#
# Each adapter implements open, put, verify, get, list, and an overlap check.
# Operations communicate their result through ALV_STORAGE_HASH and
# ALV_STORAGE_SIZE so the CLI core remains independent of storage details.

alv_storage_open() {
  ALV_STORAGE_LOCATION=$1
  ALV_STORAGE_MODE=$2

  case "$ALV_STORAGE_LOCATION" in
    file:*)
      ALV_STORAGE_ADAPTER=file
      alv_file_storage_open "$ALV_STORAGE_LOCATION" "$ALV_STORAGE_MODE"
      ;;
    rclone:*)
      ALV_STORAGE_ADAPTER=rclone
      alv_rclone_storage_open "$ALV_STORAGE_LOCATION" "$ALV_STORAGE_MODE"
      ;;
    *) alv_fail "unsupported storage location: $ALV_STORAGE_LOCATION" ;;
  esac
}

alv_storage_put() {
  case "$ALV_STORAGE_ADAPTER" in
    file) alv_file_storage_put "$1" "$2" ;;
    rclone) alv_rclone_storage_put "$1" "$2" ;;
    *) alv_fail "storage adapter does not implement put: $ALV_STORAGE_ADAPTER" ;;
  esac
}

alv_storage_verify() {
  case "$ALV_STORAGE_ADAPTER" in
    file) alv_file_storage_verify "$1" ;;
    rclone) alv_rclone_storage_verify "$1" ;;
    *) alv_fail "storage adapter does not implement verify: $ALV_STORAGE_ADAPTER" ;;
  esac
}

alv_storage_get() {
  case "$ALV_STORAGE_ADAPTER" in
    file) alv_file_storage_get "$1" "$2" ;;
    rclone) alv_rclone_storage_get "$1" "$2" ;;
    *) alv_fail "storage adapter does not implement get: $ALV_STORAGE_ADAPTER" ;;
  esac
}

alv_storage_list() {
  case "$ALV_STORAGE_ADAPTER" in
    file) alv_file_storage_list ;;
    rclone) alv_rclone_storage_list ;;
    *) alv_fail "storage adapter does not implement list: $ALV_STORAGE_ADAPTER" ;;
  esac
}

alv_storage_assert_external_to() {
  case "$ALV_STORAGE_ADAPTER" in
    file) alv_file_storage_assert_external_to "$1" ;;
    rclone) alv_rclone_storage_assert_external_to "$1" ;;
    *) alv_fail "storage adapter cannot validate location overlap: $ALV_STORAGE_ADAPTER" ;;
  esac
}
