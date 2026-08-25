#!/bin/sh

set -eu

ALV_TEST_ROOT_DIR=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
ALV_TEST_CLI=$ALV_TEST_ROOT_DIR/alv
ALV_TEST_TMP_BASE=${TMPDIR:-/tmp}
[ "$ALV_TEST_TMP_BASE" = / ] || ALV_TEST_TMP_BASE=${ALV_TEST_TMP_BASE%/}
ALV_TEST_WORK=$(mktemp -d "$ALV_TEST_TMP_BASE/agent-log-vault-provider-test.XXXXXX")
ALV_TEST_BIN=$ALV_TEST_WORK/bin
ALV_FAKE_RCLONE_STATE=$ALV_TEST_WORK/fake-rclone
ALV_FAKE_RCLONE_LOG=$ALV_TEST_WORK/rclone.log
ALV_CONFIG_HOME=$ALV_TEST_WORK/config
CODEX_HOME=$ALV_TEST_WORK/codex
TMPDIR=$ALV_TEST_WORK/runtime-tmp
export ALV_FAKE_RCLONE_STATE ALV_FAKE_RCLONE_LOG ALV_CONFIG_HOME CODEX_HOME TMPDIR
mkdir -p "$ALV_TEST_BIN" "$CODEX_HOME/archived_sessions" "$TMPDIR"

alv_test_fail() {
  printf 'provider test failure: %s\n' "$*" >&2
  exit 1
}

alv_test_cleanup() {
  case "$ALV_TEST_WORK" in
    "$ALV_TEST_TMP_BASE"/agent-log-vault-provider-test.*)
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

trap alv_test_cleanup EXIT HUP INT TERM
cp "$ALV_TEST_ROOT_DIR/tests/helpers/fake-rclone" "$ALV_TEST_BIN/rclone"
chmod 700 "$ALV_TEST_BIN/rclone"
PATH=$ALV_TEST_BIN:$PATH
export PATH

"$ALV_TEST_CLI" vault add r2 cloud \
  --account-id 0123456789abcdef0123456789abcdef \
  --access-key-id R2ACCESSKEY \
  --secret-access-key R2SECRETKEY \
  --bucket alv-r2-test > "$ALV_TEST_WORK/r2.out"

ALV_TEST_R2=$ALV_FAKE_RCLONE_STATE/remotes/alv-cloud-r2
ALV_TEST_R2_CRYPT=$ALV_FAKE_RCLONE_STATE/remotes/alv-cloud-crypt
rg -q '^type = s3$' "$ALV_TEST_R2" || alv_test_fail "R2 did not use the S3 backend"
rg -q '^provider = Cloudflare$' "$ALV_TEST_R2" || \
  alv_test_fail "R2 did not use the Cloudflare provider preset"
rg -q '^region = auto$' "$ALV_TEST_R2" || alv_test_fail "R2 region is not auto"
rg -q '^endpoint = https://0123456789abcdef0123456789abcdef\.r2\.cloudflarestorage\.com$' \
  "$ALV_TEST_R2" || alv_test_fail "R2 endpoint is incorrect"
rg -q '^no_check_bucket = true$' "$ALV_TEST_R2" || \
  alv_test_fail "R2 does not support bucket-scoped credentials"
rg -q '^remote = alv-cloud-r2:alv-r2-test/agent-log-vault/cloud$' \
  "$ALV_TEST_R2_CRYPT" || alv_test_fail "R2 crypt target is incorrect"

"$ALV_TEST_CLI" vault add b2 backblaze \
  --key-id B2APPLICATIONKEYID \
  --application-key B2APPLICATIONKEY \
  --bucket alv-b2-test > "$ALV_TEST_WORK/b2.out"
ALV_TEST_B2=$ALV_FAKE_RCLONE_STATE/remotes/alv-backblaze-b2
ALV_TEST_B2_CRYPT=$ALV_FAKE_RCLONE_STATE/remotes/alv-backblaze-crypt
rg -q '^type = b2$' "$ALV_TEST_B2" || alv_test_fail "B2 did not use its backend"
rg -q '^account = B2APPLICATIONKEYID$' "$ALV_TEST_B2" || \
  alv_test_fail "B2 key ID was not configured"
rg -q '^hard_delete = false$' "$ALV_TEST_B2" || \
  alv_test_fail "B2 hard deletion was not disabled"
rg -q '^remote = alv-backblaze-b2:alv-b2-test/agent-log-vault/backblaze$' \
  "$ALV_TEST_B2_CRYPT" || alv_test_fail "B2 crypt target is incorrect"

"$ALV_TEST_CLI" vault add drive google > "$ALV_TEST_WORK/drive.out" 2>&1
ALV_TEST_DRIVE=$ALV_FAKE_RCLONE_STATE/remotes/alv-google-drive
ALV_TEST_DRIVE_CRYPT=$ALV_FAKE_RCLONE_STATE/remotes/alv-google-crypt
rg -q '^type = drive$' "$ALV_TEST_DRIVE" || \
  alv_test_fail "Drive did not use the drive backend"
rg -q '^scope = drive\.file$' "$ALV_TEST_DRIVE" || \
  alv_test_fail "Drive did not use the limited drive.file scope"
rg -q '^config_is_local = true$' "$ALV_TEST_DRIVE" || \
  alv_test_fail "Drive did not request local browser OAuth"
rg -q '^remote = alv-google-drive:agent-log-vault/google$' \
  "$ALV_TEST_DRIVE_CRYPT" || alv_test_fail "Drive crypt target is incorrect"

rclone config create external local --no-output
"$ALV_TEST_CLI" vault add rclone advanced --remote external:archive \
  > "$ALV_TEST_WORK/advanced.out"
rg -q '^remote = external:archive$' \
  "$ALV_FAKE_RCLONE_STATE/remotes/alv-advanced-crypt" || \
  alv_test_fail "advanced target was not wrapped in crypt"

rclone config create ready crypt \
  remote external:ready \
  filename_encryption standard \
  directory_name_encryption true \
  no_data_encryption false \
  password disposable \
  password2 disposable --no-output
"$ALV_TEST_CLI" vault add rclone imported --remote ready:root \
  > "$ALV_TEST_WORK/imported.out"
[ "$(sed -n '1p' "$ALV_CONFIG_HOME/vaults/imported/location")" = 'rclone:ready:root' ] || \
  alv_test_fail "existing crypt remote was not imported directly"

alv_test_expect_failure "failed R2 validation saved a profile" \
  env ALV_FAKE_RCLONE_FAIL_PROBE=1 \
    "$ALV_TEST_CLI" vault add r2 broken \
      --account-id 0123456789abcdef0123456789abcdef \
      --access-key-id BROKENACCESS \
      --secret-access-key BROKENSECRET \
      --bucket broken-bucket
[ ! -e "$ALV_CONFIG_HOME/vaults/broken" ] || \
  alv_test_fail "failed validation left a named profile"
[ ! -e "$ALV_FAKE_RCLONE_STATE/remotes/alv-broken-r2" ] || \
  alv_test_fail "failed validation left its R2 remote"
[ ! -e "$ALV_FAKE_RCLONE_STATE/remotes/alv-broken-crypt" ] || \
  alv_test_fail "failed validation left its crypt remote"

rclone config create alv-protected-r2 s3 --no-output
alv_test_expect_failure "rclone listing failure was treated as an unused name" \
  env ALV_FAKE_RCLONE_FAIL_LIST=1 \
    "$ALV_TEST_CLI" vault add r2 protected \
      --account-id 0123456789abcdef0123456789abcdef \
      --access-key-id PROTECTEDACCESS \
      --secret-access-key PROTECTEDSECRET \
      --bucket protected-bucket
[ -e "$ALV_FAKE_RCLONE_STATE/remotes/alv-protected-r2" ] || \
  alv_test_fail "listing failure removed an existing rclone remote"
[ ! -e "$ALV_CONFIG_HOME/vaults/protected" ] || \
  alv_test_fail "listing failure left a named profile"

alv_test_expect_failure "unsafe R2 endpoint was accepted" \
  "$ALV_TEST_CLI" vault add r2 unsafe \
    --account-id 0123456789abcdef0123456789abcdef \
    --access-key-id access \
    --secret-access-key secret \
    --bucket valid-bucket \
    --endpoint http://insecure.example

alv_test_expect_failure "invalid R2 account ID was accepted" \
  "$ALV_TEST_CLI" vault add r2 invalid-account \
    --account-id not-an-account-id \
    --access-key-id access \
    --secret-access-key secret \
    --bucket valid-bucket
alv_test_expect_failure "invalid R2 bucket name was accepted" \
  "$ALV_TEST_CLI" vault add r2 invalid-bucket \
    --account-id 0123456789abcdef0123456789abcdef \
    --access-key-id access \
    --secret-access-key secret \
    --bucket Invalid_Bucket

mkdir -p "$CODEX_HOME/unsafe vault"
alv_test_expect_failure "advanced local target inside Codex was accepted" \
  "$ALV_TEST_CLI" vault add rclone nested \
    --remote "$CODEX_HOME/unsafe vault"
[ ! -e "$ALV_CONFIG_HOME/vaults/nested" ] || \
  alv_test_fail "unsafe advanced target left a named profile"

"$ALV_TEST_CLI" vault use google > "$ALV_TEST_WORK/use.out"
ALV_TEST_LIST=$("$ALV_TEST_CLI" vault list)
printf '%s\n' "$ALV_TEST_LIST" | rg -q '^\* google[[:space:]]+drive$' || \
  alv_test_fail "vault use did not change the default"

printf 'all provider setup tests passed\n'
