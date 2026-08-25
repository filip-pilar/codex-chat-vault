# Storage boundary. The sole implementation is encrypted rclone; provider
# helpers only configure rclone.

alv_storage_open() {
  ALV_STORAGE_LOCATION=$1

  case "$ALV_STORAGE_LOCATION" in
    rclone:*) ;;
    file:*) alv_fail "plaintext file: vaults are not supported" ;;
    *) alv_fail "vault profile has an unsupported storage location" ;;
  esac
  alv_rclone_storage_open "$ALV_STORAGE_LOCATION"
}

alv_storage_put() {
  alv_rclone_storage_put "$1" "$2"
}

alv_storage_verify() {
  alv_rclone_storage_verify "$1"
}

alv_storage_get() {
  alv_rclone_storage_get "$1" "$2"
}

alv_storage_list() {
  alv_rclone_storage_list
}

alv_storage_inventory() {
  alv_rclone_storage_inventory
}

alv_storage_has() {
  alv_rclone_storage_has "$1"
}

alv_storage_assert_external_to() {
  alv_rclone_storage_assert_external_to "$1"
}
