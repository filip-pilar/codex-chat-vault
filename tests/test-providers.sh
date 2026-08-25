#!/bin/sh

set -eu

ALV_TEST_ROOT_DIR=$(CDPATH='' cd "$(dirname "$0")/.." && pwd -P)
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

alv_test_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

alv_test_assert_setup_removed() {
  ALV_TEST_SETUP_NAME=$1
  ALV_TEST_SETUP_BACKING=$2
  ALV_TEST_SETUP_CRYPT=$3
  [ ! -e "$ALV_CONFIG_HOME/vaults/$ALV_TEST_SETUP_NAME" ] || \
    alv_test_fail "failed setup left profile $ALV_TEST_SETUP_NAME"
  [ ! -e "$ALV_FAKE_RCLONE_STATE/remotes/$ALV_TEST_SETUP_BACKING" ] || \
    alv_test_fail "failed setup left remote $ALV_TEST_SETUP_BACKING"
  [ ! -e "$ALV_FAKE_RCLONE_STATE/remotes/$ALV_TEST_SETUP_CRYPT" ] || \
    alv_test_fail "failed setup left remote $ALV_TEST_SETUP_CRYPT"
}

alv_test_assert_recovery() {
  ALV_TEST_RECOVERY_NAME=$1
  ALV_TEST_RECOVERY_BACKING=$2
  ALV_TEST_RECOVERY_SECRET=$3
  ALV_TEST_RECOVERY_CRYPT=${4:-alv-$ALV_TEST_RECOVERY_NAME-crypt}
  ALV_TEST_RECOVERY_FILE=$ALV_TEST_WORK/recovery-$ALV_TEST_RECOVERY_NAME.conf
  "$ALV_TEST_CLI" vault recovery "$ALV_TEST_RECOVERY_NAME" \
    --output "$ALV_TEST_RECOVERY_FILE" > \
    "$ALV_TEST_WORK/recovery-$ALV_TEST_RECOVERY_NAME.out"
  [ "$(alv_test_mode "$ALV_TEST_RECOVERY_FILE")" = 600 ] || \
    alv_test_fail "recovery export for $ALV_TEST_RECOVERY_NAME is not private"
  rg -Fq "[$ALV_TEST_RECOVERY_BACKING]" "$ALV_TEST_RECOVERY_FILE" || \
    alv_test_fail "recovery export omitted $ALV_TEST_RECOVERY_BACKING"
  rg -Fq "[$ALV_TEST_RECOVERY_CRYPT]" "$ALV_TEST_RECOVERY_FILE" || \
    alv_test_fail "recovery export omitted crypt for $ALV_TEST_RECOVERY_NAME"
  rg -q '^password = .+' "$ALV_TEST_RECOVERY_FILE" || \
    alv_test_fail "recovery export omitted the crypt password"
  rg -q '^password2 = .+' "$ALV_TEST_RECOVERY_FILE" || \
    alv_test_fail "recovery export omitted the crypt salt"
  rg -Fq "$ALV_TEST_RECOVERY_SECRET" "$ALV_TEST_RECOVERY_FILE" || \
    alv_test_fail "recovery export omitted credentials for $ALV_TEST_RECOVERY_NAME"
}

trap alv_test_cleanup EXIT HUP INT TERM
ALV_TEST_REAL_MV=$(command -v mv)
export ALV_TEST_REAL_MV
cp "$ALV_TEST_ROOT_DIR/tests/helpers/fake-rclone" "$ALV_TEST_BIN/rclone"
cp "$ALV_TEST_ROOT_DIR/tests/helpers/fake-mv" "$ALV_TEST_BIN/mv"
chmod 700 "$ALV_TEST_BIN/rclone" "$ALV_TEST_BIN/mv"
PATH=$ALV_TEST_BIN:$PATH
export PATH

ALV_TEST_HELP=$("$ALV_TEST_CLI" --help)
for ALV_TEST_HELP_LINE in \
  'vault add local <name> --path <absolute-directory>' \
  'vault add r2 <name> [options]' \
  'vault add b2 <name> [options]' \
  'vault add dropbox <name>' \
  'vault add onedrive <name>' \
  'vault add rclone <name> --remote <existing-target>' \
  'r2  --account-id <id> --access-key-id <id> --secret-access-key <key>' \
  'b2  --key-id <id> --application-key <key> --bucket <name>' \
  'Do not put secrets in shell'
do
  printf '%s\n' "$ALV_TEST_HELP" | rg -Fq "$ALV_TEST_HELP_LINE" || \
    alv_test_fail "help omitted $ALV_TEST_HELP_LINE"
done
if printf '%s\n' "$ALV_TEST_HELP" | rg -Fq 'vault add drive <name>'; then
  alv_test_fail "help still exposes the removed Google Drive helper"
fi

alv_test_expect_failure "R2 accepted the B2 account flag" \
  "$ALV_TEST_CLI" vault add r2 wrong-r2-account \
    --key-id 0123456789abcdef0123456789abcdef \
    --access-key-id access \
    --secret-access-key secret \
    --bucket valid-bucket
rg -Fq 'R2 vault accepts --account-id, not --key-id' \
  "$ALV_TEST_WORK/last-command.out" || \
  alv_test_fail "R2 did not explain its account flag"
alv_test_assert_setup_removed \
  wrong-r2-account alv-wrong-r2-account-r2 alv-wrong-r2-account-crypt

alv_test_expect_failure "R2 accepted the B2 secret flag" \
  "$ALV_TEST_CLI" vault add r2 wrong-r2-secret \
    --account-id 0123456789abcdef0123456789abcdef \
    --access-key-id access \
    --application-key secret \
    --bucket valid-bucket
rg -Fq 'R2 vault accepts --secret-access-key, not --application-key' \
  "$ALV_TEST_WORK/last-command.out" || \
  alv_test_fail "R2 did not explain its secret flag"
alv_test_assert_setup_removed \
  wrong-r2-secret alv-wrong-r2-secret-r2 alv-wrong-r2-secret-crypt

alv_test_expect_failure "B2 accepted the R2 account flag" \
  "$ALV_TEST_CLI" vault add b2 wrong-b2-account \
    --account-id account \
    --application-key secret \
    --bucket valid-bucket
rg -Fq 'B2 vault accepts --key-id, not --account-id' \
  "$ALV_TEST_WORK/last-command.out" || \
  alv_test_fail "B2 did not explain its account flag"
alv_test_assert_setup_removed \
  wrong-b2-account alv-wrong-b2-account-b2 alv-wrong-b2-account-crypt

alv_test_expect_failure "B2 accepted the R2 secret flag" \
  "$ALV_TEST_CLI" vault add b2 wrong-b2-secret \
    --key-id account \
    --secret-access-key secret \
    --bucket valid-bucket
rg -Fq 'B2 vault accepts --application-key, not --secret-access-key' \
  "$ALV_TEST_WORK/last-command.out" || \
  alv_test_fail "B2 did not explain its secret flag"
alv_test_assert_setup_removed \
  wrong-b2-secret alv-wrong-b2-secret-b2 alv-wrong-b2-secret-crypt

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
rg -q '^description = agent-log-vault-managed-[0-9a-f]{64}$' \
  "$ALV_TEST_R2" || alv_test_fail "R2 remote lacks a setup ownership marker"

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
rg -q '^deletefile[[:space:]]+alv-backblaze-crypt:.*[[:space:]]+--b2-hard-delete[[:space:]]+--quiet$' \
  "$ALV_FAKE_RCLONE_LOG" || \
  alv_test_fail "B2 setup probe was not permanently deleted"

"$ALV_TEST_CLI" vault add dropbox files > "$ALV_TEST_WORK/dropbox.out" 2>&1
ALV_TEST_DROPBOX=$ALV_FAKE_RCLONE_STATE/remotes/alv-files-dropbox
ALV_TEST_DROPBOX_CRYPT=$ALV_FAKE_RCLONE_STATE/remotes/alv-files-crypt
rg -q '^type = dropbox$' "$ALV_TEST_DROPBOX" || \
  alv_test_fail "Dropbox did not use its backend"
rg -q '^config_is_local = true$' "$ALV_TEST_DROPBOX" || \
  alv_test_fail "Dropbox did not request local browser OAuth"
rg -q '^token = ' "$ALV_TEST_DROPBOX" || \
  alv_test_fail "Dropbox OAuth did not produce a token"
rg -q '^remote = alv-files-dropbox:agent-log-vault/files$' \
  "$ALV_TEST_DROPBOX_CRYPT" || alv_test_fail "Dropbox crypt target is incorrect"
rg -q '^config\tcreate\talv-files-dropbox\tdropbox\t.*\t--no-output$' \
  "$ALV_FAKE_RCLONE_LOG" || \
  alv_test_fail "Dropbox setup did not suppress rclone's credential output"
if rg -Fq 'fake-dropbox-token' "$ALV_TEST_WORK/dropbox.out"; then
  alv_test_fail "Dropbox setup printed its OAuth token"
fi

ALV_FAKE_RCLONE_ONEDRIVE_TYPE=personal \
  "$ALV_TEST_CLI" vault add onedrive personal > \
  "$ALV_TEST_WORK/onedrive.out" 2>&1
ALV_TEST_ONEDRIVE=$ALV_FAKE_RCLONE_STATE/remotes/alv-personal-onedrive
ALV_TEST_ONEDRIVE_CRYPT=$ALV_FAKE_RCLONE_STATE/remotes/alv-personal-crypt
rg -q '^type = onedrive$' "$ALV_TEST_ONEDRIVE" || \
  alv_test_fail "OneDrive did not use its backend"
rg -q '^config_is_local = true$' "$ALV_TEST_ONEDRIVE" || \
  alv_test_fail "OneDrive did not request local browser OAuth"
rg -q '^config_type = onedrive$' "$ALV_TEST_ONEDRIVE" || \
  alv_test_fail "OneDrive did not select the OneDrive account flow"
rg -q '^disable_site_permission = true$' "$ALV_TEST_ONEDRIVE" || \
  alv_test_fail "OneDrive did not exclude SharePoint Sites permission"
rg -q '^drive_type = personal$' "$ALV_TEST_ONEDRIVE" || \
  alv_test_fail "OneDrive Personal was not confirmed"
rg -q '^remote = alv-personal-onedrive:agent-log-vault/personal$' \
  "$ALV_TEST_ONEDRIVE_CRYPT" || \
  alv_test_fail "OneDrive crypt target is incorrect"
rg -q '^config\tcreate\talv-personal-onedrive\tonedrive\t.*\t--no-output$' \
  "$ALV_FAKE_RCLONE_LOG" || \
  alv_test_fail "OneDrive setup did not suppress rclone's credential output"
if rg -Fq 'fake-onedrive-token' "$ALV_TEST_WORK/onedrive.out"; then
  alv_test_fail "OneDrive setup printed its OAuth token"
fi

alv_test_expect_failure "removed Google Drive helper was accepted" \
  "$ALV_TEST_CLI" vault add drive google
rg -Fq 'unsupported vault provider: drive' "$ALV_TEST_WORK/last-command.out" || \
  alv_test_fail "removed Google Drive helper did not fail clearly"
alv_test_assert_setup_removed google alv-google-drive alv-google-crypt

alv_test_expect_failure "OneDrive Business was accepted" \
  env ALV_FAKE_RCLONE_ONEDRIVE_TYPE=business \
    "$ALV_TEST_CLI" vault add onedrive business
rg -Fq 'OneDrive setup supports Personal only' \
  "$ALV_TEST_WORK/last-command.out" || \
  alv_test_fail "OneDrive Business did not explain the Personal limitation"
rg -Fq "vault add rclone" "$ALV_TEST_WORK/last-command.out" || \
  alv_test_fail "OneDrive Business did not give the manual rclone path"
alv_test_assert_setup_removed \
  business alv-business-onedrive alv-business-crypt

alv_test_expect_failure "SharePoint document library was accepted" \
  env ALV_FAKE_RCLONE_ONEDRIVE_TYPE=documentLibrary \
    "$ALV_TEST_CLI" vault add onedrive sharepoint
rg -Fq 'OneDrive setup supports Personal only' \
  "$ALV_TEST_WORK/last-command.out" || \
  alv_test_fail "SharePoint rejection did not explain the Personal limitation"
alv_test_assert_setup_removed \
  sharepoint alv-sharepoint-onedrive alv-sharepoint-crypt

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
alv_test_assert_setup_removed broken alv-broken-r2 alv-broken-crypt

alv_test_expect_failure "failed Dropbox OAuth saved a profile" \
  env ALV_FAKE_RCLONE_FAIL_CREATE_AFTER_WRITE=alv-oauth-failure-dropbox \
    "$ALV_TEST_CLI" vault add dropbox oauth-failure
alv_test_assert_setup_removed \
  oauth-failure alv-oauth-failure-dropbox alv-oauth-failure-crypt

alv_test_expect_failure "interrupted OneDrive OAuth saved a profile" \
  env ALV_FAKE_RCLONE_INTERRUPT_CREATE=alv-interrupted-onedrive \
    "$ALV_TEST_CLI" vault add onedrive interrupted
alv_test_assert_setup_removed \
  interrupted alv-interrupted-onedrive alv-interrupted-crypt

ALV_TEST_INTERRUPTED_CONFIG=$ALV_TEST_WORK/interrupted-config
alv_test_expect_failure "interrupted profile commit left a profile" \
  env ALV_CONFIG_HOME="$ALV_TEST_INTERRUPTED_CONFIG" \
    ALV_FAKE_MV_INTERRUPT_DEFAULT=1 \
    "$ALV_TEST_CLI" vault add dropbox profile-interrupted
[ ! -e "$ALV_TEST_INTERRUPTED_CONFIG/vaults/profile-interrupted" ] || \
  alv_test_fail "interrupted profile commit left its named profile"
[ ! -e "$ALV_TEST_INTERRUPTED_CONFIG/default-vault" ] || \
  alv_test_fail "interrupted profile commit left its default selection"
[ -z "$(find "$ALV_TEST_INTERRUPTED_CONFIG" -type f -print)" ] || \
  alv_test_fail "interrupted profile commit left partial profile data"
[ ! -e "$ALV_FAKE_RCLONE_STATE/remotes/alv-profile-interrupted-dropbox" ] || \
  alv_test_fail "interrupted profile commit left its Dropbox remote"
[ ! -e "$ALV_FAKE_RCLONE_STATE/remotes/alv-profile-interrupted-crypt" ] || \
  alv_test_fail "interrupted profile commit left its crypt remote"

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

for ALV_TEST_SECRET in \
  R2ACCESSKEY R2SECRETKEY \
  B2APPLICATIONKEYID B2APPLICATIONKEY \
  fake-dropbox-token fake-onedrive-token
do
  if rg -Fq "$ALV_TEST_SECRET" "$ALV_CONFIG_HOME"; then
    alv_test_fail "ALV profile storage contains provider secret $ALV_TEST_SECRET"
  fi
done
for ALV_TEST_PROFILE in "$ALV_CONFIG_HOME"/vaults/*; do
  [ -d "$ALV_TEST_PROFILE" ] || continue
  [ "$(find "$ALV_TEST_PROFILE" -type f | wc -l | tr -d '[:space:]')" = 2 ] || \
    alv_test_fail "vault profile contains data beyond provider and location"
done

alv_test_assert_recovery cloud alv-cloud-r2 R2SECRETKEY
alv_test_assert_recovery backblaze alv-backblaze-b2 B2APPLICATIONKEY
alv_test_assert_recovery files alv-files-dropbox fake-dropbox-token
alv_test_assert_recovery personal alv-personal-onedrive fake-onedrive-token
alv_test_assert_recovery advanced external 'type = local'
alv_test_assert_recovery imported external 'type = local' ready

"$ALV_TEST_CLI" vault use personal > "$ALV_TEST_WORK/use.out"
ALV_TEST_LIST=$("$ALV_TEST_CLI" vault list)
printf '%s\n' "$ALV_TEST_LIST" | rg -q '^\* personal[[:space:]]+onedrive$' || \
  alv_test_fail "vault use did not change the default"
for ALV_TEST_LIST_ENTRY in \
  'advanced[[:space:]]+rclone' \
  'backblaze[[:space:]]+b2' \
  'cloud[[:space:]]+r2' \
  'files[[:space:]]+dropbox' \
  'imported[[:space:]]+rclone'
do
  printf '%s\n' "$ALV_TEST_LIST" | rg -q "$ALV_TEST_LIST_ENTRY" || \
    alv_test_fail "vault list omitted $ALV_TEST_LIST_ENTRY"
done
[ "$(printf '%s\n' "$ALV_TEST_LIST" | wc -l | tr -d '[:space:]')" = 6 ] || \
  alv_test_fail "vault list contains an unexpected provider profile"

[ -z "$(find "$ALV_FAKE_RCLONE_STATE/objects" -type f -print)" ] || \
  alv_test_fail "provider setup left a disposable probe object"

printf 'all provider setup tests passed\n'
