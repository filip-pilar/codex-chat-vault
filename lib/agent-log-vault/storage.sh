# Tiny storage dispatcher. V1 has one implementation: an encrypted rclone
# remote. Provider helpers configure rclone rather than adding runtime adapters.

alv_storage_open() {
  ALV_STORAGE_LOCATION=$1
  ALV_STORAGE_MODE=$2

  case "$ALV_STORAGE_LOCATION" in
    rclone:*) ;;
    file:*) alv_fail "plaintext file: vaults are not supported" ;;
    *) alv_fail "vault profile has an unsupported storage location" ;;
  esac
  ALV_STORAGE_ADAPTER=rclone
  alv_rclone_storage_open "$ALV_STORAGE_LOCATION" "$ALV_STORAGE_MODE"
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

alv_storage_has() {
  alv_rclone_storage_has "$1"
}

alv_storage_assert_external_to() {
  alv_rclone_storage_assert_external_to "$1"
}
