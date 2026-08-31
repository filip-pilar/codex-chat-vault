# Vault setup and recovery. Rclone owns provider credentials, OAuth tokens, and
# crypt configuration; agent-log-vault stores only named profile references.

ALV_VAULT_CREATED_REMOTES=
ALV_VAULT_SETUP_MARKER=
ALV_VAULT_PROBE_TARGET=
ALV_VAULT_PROBE_DELETE_FLAG=
ALV_VAULT_TEMP_BASE=
ALV_VAULT_TEMP_DIRECTORY=
ALV_VAULT_STTY_ECHO_DISABLED=false
ALV_VAULT_PENDING_PROFILE=
ALV_VAULT_PENDING_DEFAULT=false
ALV_VAULT_PRESERVE_CREATED_REMOTES=false

alv_vault_delete_probe() {
  [ -n "$ALV_VAULT_PROBE_TARGET" ] || return 0
  if [ -n "$ALV_VAULT_PROBE_DELETE_FLAG" ]; then
    rclone deletefile \
      "$ALV_VAULT_PROBE_TARGET" \
      "$ALV_VAULT_PROBE_DELETE_FLAG" \
      --quiet
  else
    rclone deletefile "$ALV_VAULT_PROBE_TARGET" --quiet
  fi
}

alv_vault_probe_cleanup() {
  if [ "$ALV_VAULT_STTY_ECHO_DISABLED" = true ]; then
    stty echo 2>/dev/null || true
    ALV_VAULT_STTY_ECHO_DISABLED=false
    printf '\n' >&2
  fi

  if [ -n "$ALV_VAULT_PROBE_TARGET" ]; then
    alv_vault_delete_probe >/dev/null 2>&1 || true
    ALV_VAULT_PROBE_TARGET=
  fi
  ALV_VAULT_PROBE_DELETE_FLAG=

  if [ -n "$ALV_VAULT_TEMP_DIRECTORY" ]; then
    case "$ALV_VAULT_TEMP_DIRECTORY" in
      "$ALV_VAULT_TEMP_BASE"/agent-log-vault-setup.*)
        if [ -d "$ALV_VAULT_TEMP_DIRECTORY" ]; then
          /bin/rm -rf "$ALV_VAULT_TEMP_DIRECTORY"
        fi
        ;;
    esac
    ALV_VAULT_TEMP_DIRECTORY=
  fi
}

# The setup marker remains in a newly placed profile until its default-vault
# update succeeds. Removing the marker is the durable setup commit point.
alv_vault_pending_profile_cleanup() {
  ALV_VAULT_PRESERVE_CREATED_REMOTES=false
  [ -n "$ALV_VAULT_PENDING_PROFILE" ] || return 0
  [ -n "$ALV_VAULT_SETUP_MARKER" ] || return 0

  alv_profiles_resolve_home
  ALV_VAULT_PENDING_DIRECTORY=$ALV_PROFILE_VAULTS/$ALV_VAULT_PENDING_PROFILE
  ALV_VAULT_PENDING_MARKER=$ALV_VAULT_PENDING_DIRECTORY/.setup-marker
  if [ ! -e "$ALV_VAULT_PENDING_DIRECTORY" ] && \
     [ ! -L "$ALV_VAULT_PENDING_DIRECTORY" ]; then
    ALV_VAULT_PENDING_PROFILE=
    ALV_VAULT_PENDING_DEFAULT=false
    return 0
  fi
  if [ ! -d "$ALV_VAULT_PENDING_DIRECTORY" ] || \
     [ -L "$ALV_VAULT_PENDING_DIRECTORY" ]; then
    ALV_VAULT_PRESERVE_CREATED_REMOTES=true
    ALV_VAULT_PENDING_PROFILE=
    ALV_VAULT_PENDING_DEFAULT=false
    return 0
  fi

  if [ ! -e "$ALV_VAULT_PENDING_MARKER" ] && \
     [ ! -L "$ALV_VAULT_PENDING_MARKER" ]; then
    ALV_VAULT_PRESERVE_CREATED_REMOTES=true
    ALV_VAULT_PENDING_PROFILE=
    ALV_VAULT_PENDING_DEFAULT=false
    return 0
  fi

  ALV_VAULT_PENDING_COUNT=$(find "$ALV_VAULT_PENDING_DIRECTORY" \
    -mindepth 1 -maxdepth 1 -print 2>/dev/null | wc -l | tr -d '[:space:]')
  if [ "$ALV_VAULT_PENDING_COUNT" != 3 ] || \
     [ ! -f "$ALV_VAULT_PENDING_DIRECTORY/provider" ] || \
     [ -L "$ALV_VAULT_PENDING_DIRECTORY/provider" ] || \
     [ ! -f "$ALV_VAULT_PENDING_DIRECTORY/location" ] || \
     [ -L "$ALV_VAULT_PENDING_DIRECTORY/location" ] || \
     [ ! -f "$ALV_VAULT_PENDING_MARKER" ] || \
     [ -L "$ALV_VAULT_PENDING_MARKER" ]; then
    ALV_VAULT_PRESERVE_CREATED_REMOTES=true
    ALV_VAULT_PENDING_PROFILE=
    ALV_VAULT_PENDING_DEFAULT=false
    return 0
  fi

  ALV_VAULT_PENDING_MARKER_VALUE=
  IFS= read -r ALV_VAULT_PENDING_MARKER_VALUE < \
    "$ALV_VAULT_PENDING_MARKER" || true
  if [ "$ALV_VAULT_PENDING_MARKER_VALUE" != "$ALV_VAULT_SETUP_MARKER" ]; then
    ALV_VAULT_PRESERVE_CREATED_REMOTES=true
    ALV_VAULT_PENDING_PROFILE=
    ALV_VAULT_PENDING_DEFAULT=false
    return 0
  fi

  if [ "$ALV_VAULT_PENDING_DEFAULT" = true ] && \
     [ -f "$ALV_PROFILE_DEFAULT_FILE" ] && \
     [ ! -L "$ALV_PROFILE_DEFAULT_FILE" ]; then
    ALV_VAULT_PENDING_DEFAULT_VALUE=
    IFS= read -r ALV_VAULT_PENDING_DEFAULT_VALUE < \
      "$ALV_PROFILE_DEFAULT_FILE" || true
    if [ "$ALV_VAULT_PENDING_DEFAULT_VALUE" = \
         "$ALV_VAULT_PENDING_PROFILE" ]; then
      if ! unlink "$ALV_PROFILE_DEFAULT_FILE"; then
        ALV_VAULT_PRESERVE_CREATED_REMOTES=true
        ALV_VAULT_PENDING_PROFILE=
        ALV_VAULT_PENDING_DEFAULT=false
        return 0
      fi
    fi
  fi

  if ! unlink "$ALV_VAULT_PENDING_MARKER" || \
     ! unlink "$ALV_VAULT_PENDING_DIRECTORY/provider" || \
     ! unlink "$ALV_VAULT_PENDING_DIRECTORY/location" || \
     ! rmdir "$ALV_VAULT_PENDING_DIRECTORY"; then
    ALV_VAULT_PRESERVE_CREATED_REMOTES=true
  fi
  ALV_VAULT_PENDING_PROFILE=
  ALV_VAULT_PENDING_DEFAULT=false
}

alv_vault_setup_cleanup() {
  alv_vault_probe_cleanup
  alv_vault_pending_profile_cleanup
  if [ -n "$ALV_VAULT_CREATED_REMOTES" ] && \
     [ -n "$ALV_VAULT_SETUP_MARKER" ] && \
     [ "$ALV_VAULT_PRESERVE_CREATED_REMOTES" != true ]; then
    printf '%s\n' "$ALV_VAULT_CREATED_REMOTES" |
      while IFS= read -r ALV_VAULT_CLEANUP_REMOTE; do
        [ -n "$ALV_VAULT_CLEANUP_REMOTE" ] || continue
        ALV_VAULT_CLEANUP_CONFIG=$(rclone config redacted \
          "$ALV_VAULT_CLEANUP_REMOTE" 2>/dev/null) || continue
        printf '%s\n' "$ALV_VAULT_CLEANUP_CONFIG" | grep -Fqx \
          "description = $ALV_VAULT_SETUP_MARKER" || continue
        rclone config delete "$ALV_VAULT_CLEANUP_REMOTE" >/dev/null 2>&1 || true
      done
  fi
  ALV_VAULT_CREATED_REMOTES=
  ALV_VAULT_SETUP_MARKER=
  ALV_VAULT_PRESERVE_CREATED_REMOTES=false
}

alv_vault_require_rclone() {
  command -v rclone >/dev/null 2>&1 || \
    alv_fail "rclone is required for encrypted vaults"
}

alv_vault_require_new_profile() {
  alv_profile_validate_name "$1"
  if alv_profile_exists "$1"; then
    alv_fail "vault already exists: $1"
  fi
}

alv_vault_require_new_remote() {
  ALV_VAULT_REMOTE_LIST=$(rclone listremotes --quiet 2>/dev/null) || \
    alv_fail "could not list existing rclone remotes"
  if printf '%s\n' "$ALV_VAULT_REMOTE_LIST" | grep -Fqx "$1:"; then
    alv_fail "rclone remote already exists: $1"
  fi
}

alv_vault_plan_remote() {
  alv_vault_require_new_remote "$1"
  if [ -z "$ALV_VAULT_SETUP_MARKER" ]; then
    ALV_VAULT_SETUP_MARKER=agent-log-vault-managed-$(alv_vault_generate_secret)
  fi
  if [ -n "$ALV_VAULT_CREATED_REMOTES" ]; then
    ALV_VAULT_CREATED_REMOTES=$1'
'$ALV_VAULT_CREATED_REMOTES
  else
    ALV_VAULT_CREATED_REMOTES=$1
  fi
}

alv_vault_generate_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    alv_fail "openssl is required to generate vault encryption secrets"
  fi
}

alv_vault_create_crypt() {
  ALV_VAULT_CRYPT_REMOTE=$1
  ALV_VAULT_CRYPT_TARGET=$2
  alv_vault_plan_remote "$ALV_VAULT_CRYPT_REMOTE"

  ALV_VAULT_CRYPT_PASSWORD=$(alv_vault_generate_secret)
  ALV_VAULT_CRYPT_PASSWORD2=$(alv_vault_generate_secret)
  if ! rclone config create \
    "$ALV_VAULT_CRYPT_REMOTE" \
    crypt \
    remote "$ALV_VAULT_CRYPT_TARGET" \
    filename_encryption standard \
    directory_name_encryption true \
    no_data_encryption false \
    password "$ALV_VAULT_CRYPT_PASSWORD" \
    password2 "$ALV_VAULT_CRYPT_PASSWORD2" \
    description "$ALV_VAULT_SETUP_MARKER" \
    --obscure \
    --no-output >/dev/null 2>&1; then
    alv_fail "could not create encrypted rclone remote"
  fi
  ALV_VAULT_CRYPT_PASSWORD=
  ALV_VAULT_CRYPT_PASSWORD2=
}

alv_vault_make_temp() {
  [ -z "$ALV_VAULT_TEMP_DIRECTORY" ] || return 0
  ALV_VAULT_TEMP_BASE=${TMPDIR:-/tmp}
  ALV_VAULT_TEMP_BASE=$(alv_canonical_directory "$ALV_VAULT_TEMP_BASE")
  ALV_VAULT_TEMP_DIRECTORY=$(mktemp -d \
    "$ALV_VAULT_TEMP_BASE/agent-log-vault-setup.XXXXXX") || \
    alv_fail "could not create a vault setup directory"
  chmod 700 "$ALV_VAULT_TEMP_DIRECTORY"
}

alv_vault_probe_location() {
  ALV_VAULT_PROBE_LOCATION=$1
  alv_rclone_storage_open "$ALV_VAULT_PROBE_LOCATION"
  alv_vault_make_temp

  ALV_VAULT_PROBE_ID=$$-${ALV_VAULT_TEMP_DIRECTORY##*.}
  ALV_VAULT_PROBE_SOURCE=$ALV_VAULT_TEMP_DIRECTORY/probe-source
  ALV_VAULT_PROBE_RESULT=$ALV_VAULT_TEMP_DIRECTORY/probe-result
  printf 'agent-log-vault setup probe %s\n' "$ALV_VAULT_PROBE_ID" > \
    "$ALV_VAULT_PROBE_SOURCE"
  chmod 600 "$ALV_VAULT_PROBE_SOURCE"

  if [ -n "$ALV_RCLONE_STORAGE_ROOT" ]; then
    ALV_VAULT_PROBE_CANDIDATE=$ALV_RCLONE_STORAGE_REMOTE:$ALV_RCLONE_STORAGE_ROOT/.alv-setup-$ALV_VAULT_PROBE_ID
  else
    ALV_VAULT_PROBE_CANDIDATE=$ALV_RCLONE_STORAGE_REMOTE:.alv-setup-$ALV_VAULT_PROBE_ID
  fi

  if ! rclone copyto \
    "$ALV_VAULT_PROBE_SOURCE" \
    "$ALV_VAULT_PROBE_CANDIDATE" \
    --immutable \
    --quiet; then
    alv_fail "vault setup upload failed"
  fi
  ALV_VAULT_PROBE_TARGET=$ALV_VAULT_PROBE_CANDIDATE
  if ! rclone copyto \
    "$ALV_VAULT_PROBE_TARGET" \
    "$ALV_VAULT_PROBE_RESULT" \
    --immutable \
    --quiet; then
    alv_fail "vault setup read-back failed"
  fi
  cmp -s "$ALV_VAULT_PROBE_SOURCE" "$ALV_VAULT_PROBE_RESULT" || \
    alv_fail "vault setup read-back did not match the uploaded bytes"
  if ! alv_vault_delete_probe; then
    alv_fail "vault setup probe could not be removed"
  fi
  ALV_VAULT_PROBE_TARGET=
  alv_vault_probe_cleanup
}

alv_vault_save_validated() {
  ALV_VAULT_SAVE_NAME=$1
  ALV_VAULT_SAVE_PROVIDER=$2
  ALV_VAULT_SAVE_LOCATION=$3
  ALV_VAULT_PROBE_DELETE_FLAG=${4:-}
  alv_vault_probe_location "$ALV_VAULT_SAVE_LOCATION"
  if [ -z "$ALV_VAULT_SETUP_MARKER" ]; then
    ALV_VAULT_SETUP_MARKER=agent-log-vault-managed-$(alv_vault_generate_secret)
  fi
  alv_profiles_resolve_home
  if [ ! -e "$ALV_PROFILE_DEFAULT_FILE" ] && \
     [ ! -L "$ALV_PROFILE_DEFAULT_FILE" ]; then
    ALV_VAULT_PENDING_DEFAULT=true
  else
    ALV_VAULT_PENDING_DEFAULT=false
  fi
  ALV_VAULT_PENDING_PROFILE=$ALV_VAULT_SAVE_NAME
  alv_profile_save \
    "$ALV_VAULT_SAVE_NAME" \
    "$ALV_VAULT_SAVE_PROVIDER" \
    "$ALV_VAULT_SAVE_LOCATION" \
    "$ALV_VAULT_SETUP_MARKER"
  alv_profile_directory "$ALV_VAULT_SAVE_NAME"
  ALV_VAULT_PROFILE_MARKER=$ALV_PROFILE_DIRECTORY/.setup-marker
  [ -f "$ALV_VAULT_PROFILE_MARKER" ] && \
    [ ! -L "$ALV_VAULT_PROFILE_MARKER" ] || \
    alv_fail "vault profile setup marker is missing"
  ALV_VAULT_PROFILE_MARKER_VALUE=
  IFS= read -r ALV_VAULT_PROFILE_MARKER_VALUE < \
    "$ALV_VAULT_PROFILE_MARKER" || true
  [ "$ALV_VAULT_PROFILE_MARKER_VALUE" = "$ALV_VAULT_SETUP_MARKER" ] || \
    alv_fail "vault profile setup marker changed"
  if ! unlink "$ALV_VAULT_PROFILE_MARKER"; then
    alv_fail "could not finalize the vault profile"
  fi
  ALV_VAULT_PENDING_PROFILE=
  ALV_VAULT_PENDING_DEFAULT=false
  ALV_VAULT_CREATED_REMOTES=
  ALV_VAULT_SETUP_MARKER=
}

alv_vault_local_assert_external() {
  ALV_VAULT_LOCAL_PATH=$1
  ALV_VAULT_LOCAL_CODEX_RAW=$(alv_default_codex_home)
  if [ -d "$ALV_VAULT_LOCAL_CODEX_RAW" ]; then
    ALV_VAULT_LOCAL_CODEX=$(alv_canonical_directory "$ALV_VAULT_LOCAL_CODEX_RAW")
    case "$ALV_VAULT_LOCAL_PATH" in
      "$ALV_VAULT_LOCAL_CODEX"|"$ALV_VAULT_LOCAL_CODEX"/*)
        alv_fail "vault must be outside the Codex home"
        ;;
    esac
    case "$ALV_VAULT_LOCAL_CODEX" in
      "$ALV_VAULT_LOCAL_PATH"|"$ALV_VAULT_LOCAL_PATH"/*)
        alv_fail "vault and Codex home must not contain one another"
        ;;
    esac
  fi
}

alv_vault_add_local() {
  ALV_VAULT_LOCAL_NAME=$1
  ALV_VAULT_LOCAL_INPUT=$2
  alv_vault_require_rclone
  alv_vault_require_new_profile "$ALV_VAULT_LOCAL_NAME"
  case "$ALV_VAULT_LOCAL_INPUT" in
    /*) ;;
    *) alv_fail "local vault path must be absolute" ;;
  esac
  ALV_VAULT_LOCAL_PATH=$(alv_canonical_directory "$ALV_VAULT_LOCAL_INPUT")
  [ "$ALV_VAULT_LOCAL_PATH" != / ] || \
    alv_fail "filesystem root cannot be used as a vault"
  alv_vault_local_assert_external "$ALV_VAULT_LOCAL_PATH"

  ALV_VAULT_LOCAL_CRYPT=alv-$ALV_VAULT_LOCAL_NAME-crypt
  alv_vault_create_crypt "$ALV_VAULT_LOCAL_CRYPT" "$ALV_VAULT_LOCAL_PATH"
  alv_vault_save_validated \
    "$ALV_VAULT_LOCAL_NAME" local "rclone:$ALV_VAULT_LOCAL_CRYPT:"
}

alv_vault_prompt() {
  ALV_VAULT_PROMPT_LABEL=$1
  [ -t 0 ] || alv_fail "$ALV_VAULT_PROMPT_LABEL is required"
  printf '%s: ' "$ALV_VAULT_PROMPT_LABEL" >&2
  IFS= read -r ALV_VAULT_PROMPT_VALUE || \
    alv_fail "could not read $ALV_VAULT_PROMPT_LABEL"
  [ -n "$ALV_VAULT_PROMPT_VALUE" ] || \
    alv_fail "$ALV_VAULT_PROMPT_LABEL is required"
}

alv_vault_prompt_secret() {
  ALV_VAULT_PROMPT_SECRET_LABEL=$1
  [ -t 0 ] || alv_fail "$ALV_VAULT_PROMPT_SECRET_LABEL is required"
  printf '%s: ' "$ALV_VAULT_PROMPT_SECRET_LABEL" >&2
  stty -echo
  ALV_VAULT_STTY_ECHO_DISABLED=true
  IFS= read -r ALV_VAULT_PROMPT_VALUE || {
    stty echo
    ALV_VAULT_STTY_ECHO_DISABLED=false
    printf '\n' >&2
    alv_fail "could not read $ALV_VAULT_PROMPT_SECRET_LABEL"
  }
  stty echo
  ALV_VAULT_STTY_ECHO_DISABLED=false
  printf '\n' >&2
  [ -n "$ALV_VAULT_PROMPT_VALUE" ] || \
    alv_fail "$ALV_VAULT_PROMPT_SECRET_LABEL is required"
}

alv_vault_value_or_prompt() {
  ALV_VAULT_OPTION_VALUE=$1
  ALV_VAULT_OPTION_LABEL=$2
  if [ -n "$ALV_VAULT_OPTION_VALUE" ]; then
    ALV_VAULT_RESOLVED_VALUE=$ALV_VAULT_OPTION_VALUE
  else
    alv_vault_prompt "$ALV_VAULT_OPTION_LABEL"
    ALV_VAULT_RESOLVED_VALUE=$ALV_VAULT_PROMPT_VALUE
  fi
}

alv_vault_secret_or_prompt() {
  ALV_VAULT_OPTION_VALUE=$1
  ALV_VAULT_OPTION_LABEL=$2
  if [ -n "$ALV_VAULT_OPTION_VALUE" ]; then
    ALV_VAULT_RESOLVED_VALUE=$ALV_VAULT_OPTION_VALUE
  else
    alv_vault_prompt_secret "$ALV_VAULT_OPTION_LABEL"
    ALV_VAULT_RESOLVED_VALUE=$ALV_VAULT_PROMPT_VALUE
  fi
}

alv_vault_validate_provider_value() {
  alv_profile_validate_value "$1" "$2"
  case "$1" in
    *'	'*) alv_fail "$2 cannot contain a tab" ;;
  esac
}

alv_vault_validate_bucket() {
  alv_vault_validate_provider_value "$1" "bucket name"
  case "$1" in
    [!A-Za-z0-9]*|*[!A-Za-z0-9._-]*|*.)
      alv_fail "bucket name contains unsupported characters"
      ;;
  esac
}

alv_vault_validate_r2_account() {
  alv_vault_validate_provider_value "$1" "Cloudflare account ID"
  [ "${#1}" -eq 32 ] || \
    alv_fail "Cloudflare account ID must be 32 hexadecimal characters"
  case "$1" in
    *[!0-9A-Fa-f]*)
      alv_fail "Cloudflare account ID must be 32 hexadecimal characters"
      ;;
  esac
}

alv_vault_validate_r2_bucket() {
  alv_vault_validate_provider_value "$1" "R2 bucket name"
  [ "${#1}" -ge 3 ] && [ "${#1}" -le 63 ] || \
    alv_fail "R2 bucket name must be between 3 and 63 characters"
  case "$1" in
    -*|*-|*[!a-z0-9-]*)
      alv_fail "R2 bucket name must use lowercase letters, numbers, and hyphens"
      ;;
  esac
}

alv_vault_validate_endpoint() {
  alv_vault_validate_provider_value "$1" endpoint
  case "$1" in
    https://*) ;;
    *) alv_fail "provider endpoint must use https://" ;;
  esac
  case "$1" in
    *' '*|*'	'*) alv_fail "provider endpoint cannot contain whitespace" ;;
  esac
}

alv_vault_add_r2() {
  ALV_VAULT_R2_NAME=$1
  ALV_VAULT_R2_ACCOUNT_INPUT=$2
  ALV_VAULT_R2_ACCESS_INPUT=$3
  ALV_VAULT_R2_SECRET_INPUT=$4
  ALV_VAULT_R2_BUCKET_INPUT=$5
  ALV_VAULT_R2_ENDPOINT_INPUT=$6

  alv_vault_require_rclone
  alv_vault_require_new_profile "$ALV_VAULT_R2_NAME"
  printf 'Use bucket-scoped R2 Object Read & Write credentials.\n' >&2
  alv_vault_value_or_prompt "$ALV_VAULT_R2_ACCOUNT_INPUT" "Cloudflare account ID"
  ALV_VAULT_R2_ACCOUNT=$ALV_VAULT_RESOLVED_VALUE
  alv_vault_value_or_prompt "$ALV_VAULT_R2_ACCESS_INPUT" "R2 access key ID"
  ALV_VAULT_R2_ACCESS=$ALV_VAULT_RESOLVED_VALUE
  alv_vault_secret_or_prompt "$ALV_VAULT_R2_SECRET_INPUT" "R2 secret access key"
  ALV_VAULT_R2_SECRET=$ALV_VAULT_RESOLVED_VALUE
  alv_vault_value_or_prompt "$ALV_VAULT_R2_BUCKET_INPUT" "Existing R2 bucket"
  ALV_VAULT_R2_BUCKET=$ALV_VAULT_RESOLVED_VALUE
  if [ -n "$ALV_VAULT_R2_ENDPOINT_INPUT" ]; then
    ALV_VAULT_R2_ENDPOINT=$ALV_VAULT_R2_ENDPOINT_INPUT
  else
    ALV_VAULT_R2_ENDPOINT=https://$ALV_VAULT_R2_ACCOUNT.r2.cloudflarestorage.com
  fi
  alv_vault_validate_r2_account "$ALV_VAULT_R2_ACCOUNT"
  alv_vault_validate_provider_value "$ALV_VAULT_R2_ACCESS" "R2 access key ID"
  alv_vault_validate_provider_value "$ALV_VAULT_R2_SECRET" "R2 secret access key"
  alv_vault_validate_r2_bucket "$ALV_VAULT_R2_BUCKET"
  alv_vault_validate_endpoint "$ALV_VAULT_R2_ENDPOINT"

  ALV_VAULT_R2_BACKING=alv-$ALV_VAULT_R2_NAME-r2
  ALV_VAULT_R2_CRYPT=alv-$ALV_VAULT_R2_NAME-crypt
  alv_vault_plan_remote "$ALV_VAULT_R2_BACKING"
  if ! rclone config create \
    "$ALV_VAULT_R2_BACKING" \
    s3 \
    provider Cloudflare \
    env_auth false \
    access_key_id "$ALV_VAULT_R2_ACCESS" \
    secret_access_key "$ALV_VAULT_R2_SECRET" \
    region auto \
    endpoint "$ALV_VAULT_R2_ENDPOINT" \
    acl private \
    no_check_bucket true \
    description "$ALV_VAULT_SETUP_MARKER" \
    --obscure \
    --no-output >/dev/null 2>&1; then
    alv_fail "could not create the R2 rclone remote"
  fi
  ALV_VAULT_R2_SECRET=
  alv_vault_create_crypt \
    "$ALV_VAULT_R2_CRYPT" \
    "$ALV_VAULT_R2_BACKING:$ALV_VAULT_R2_BUCKET/agent-log-vault/$ALV_VAULT_R2_NAME"
  alv_vault_save_validated \
    "$ALV_VAULT_R2_NAME" r2 "rclone:$ALV_VAULT_R2_CRYPT:"
}

alv_vault_add_b2() {
  ALV_VAULT_B2_NAME=$1
  ALV_VAULT_B2_ACCOUNT_INPUT=$2
  ALV_VAULT_B2_KEY_INPUT=$3
  ALV_VAULT_B2_BUCKET_INPUT=$4
  ALV_VAULT_B2_ENDPOINT_INPUT=$5

  alv_vault_require_rclone
  alv_vault_require_new_profile "$ALV_VAULT_B2_NAME"
  printf '%s\n' \
    'Use a bucket-scoped B2 Read and Write application key for the existing bucket.' >&2
  alv_vault_value_or_prompt "$ALV_VAULT_B2_ACCOUNT_INPUT" "B2 application key ID"
  ALV_VAULT_B2_ACCOUNT=$ALV_VAULT_RESOLVED_VALUE
  alv_vault_secret_or_prompt "$ALV_VAULT_B2_KEY_INPUT" "B2 application key"
  ALV_VAULT_B2_KEY=$ALV_VAULT_RESOLVED_VALUE
  alv_vault_value_or_prompt "$ALV_VAULT_B2_BUCKET_INPUT" "Existing B2 bucket"
  ALV_VAULT_B2_BUCKET=$ALV_VAULT_RESOLVED_VALUE
  alv_vault_validate_provider_value "$ALV_VAULT_B2_ACCOUNT" "B2 application key ID"
  alv_vault_validate_provider_value "$ALV_VAULT_B2_KEY" "B2 application key"
  alv_vault_validate_bucket "$ALV_VAULT_B2_BUCKET"
  if [ -n "$ALV_VAULT_B2_ENDPOINT_INPUT" ]; then
    alv_vault_validate_endpoint "$ALV_VAULT_B2_ENDPOINT_INPUT"
  fi

  ALV_VAULT_B2_BACKING=alv-$ALV_VAULT_B2_NAME-b2
  ALV_VAULT_B2_CRYPT=alv-$ALV_VAULT_B2_NAME-crypt
  alv_vault_plan_remote "$ALV_VAULT_B2_BACKING"
  if [ -n "$ALV_VAULT_B2_ENDPOINT_INPUT" ]; then
    if ! rclone config create \
      "$ALV_VAULT_B2_BACKING" \
      b2 \
      account "$ALV_VAULT_B2_ACCOUNT" \
      key "$ALV_VAULT_B2_KEY" \
      endpoint "$ALV_VAULT_B2_ENDPOINT_INPUT" \
      hard_delete false \
      description "$ALV_VAULT_SETUP_MARKER" \
      --obscure \
      --no-output >/dev/null 2>&1; then
      alv_fail "could not create the B2 rclone remote"
    fi
  else
    if ! rclone config create \
      "$ALV_VAULT_B2_BACKING" \
      b2 \
      account "$ALV_VAULT_B2_ACCOUNT" \
      key "$ALV_VAULT_B2_KEY" \
      hard_delete false \
      description "$ALV_VAULT_SETUP_MARKER" \
      --obscure \
      --no-output >/dev/null 2>&1; then
      alv_fail "could not create the B2 rclone remote"
    fi
  fi
  ALV_VAULT_B2_KEY=
  alv_vault_create_crypt \
    "$ALV_VAULT_B2_CRYPT" \
    "$ALV_VAULT_B2_BACKING:$ALV_VAULT_B2_BUCKET/agent-log-vault/$ALV_VAULT_B2_NAME"
  alv_vault_save_validated \
    "$ALV_VAULT_B2_NAME" b2 "rclone:$ALV_VAULT_B2_CRYPT:" \
    --b2-hard-delete
}

alv_vault_add_dropbox() {
  ALV_VAULT_DROPBOX_NAME=$1
  alv_vault_require_rclone
  alv_vault_require_new_profile "$ALV_VAULT_DROPBOX_NAME"
  ALV_VAULT_DROPBOX_BACKING=alv-$ALV_VAULT_DROPBOX_NAME-dropbox
  ALV_VAULT_DROPBOX_CRYPT=alv-$ALV_VAULT_DROPBOX_NAME-crypt
  alv_vault_plan_remote "$ALV_VAULT_DROPBOX_BACKING"

  printf 'rclone will open Dropbox authorization in your browser.\n' >&2
  if ! rclone config create \
    "$ALV_VAULT_DROPBOX_BACKING" \
    dropbox \
    config_is_local true \
    description "$ALV_VAULT_SETUP_MARKER" \
    --no-output; then
    alv_fail "Dropbox authorization failed"
  fi
  alv_vault_create_crypt \
    "$ALV_VAULT_DROPBOX_CRYPT" \
    "$ALV_VAULT_DROPBOX_BACKING:agent-log-vault/$ALV_VAULT_DROPBOX_NAME"
  alv_vault_save_validated \
    "$ALV_VAULT_DROPBOX_NAME" dropbox "rclone:$ALV_VAULT_DROPBOX_CRYPT:"
}

alv_vault_add_onedrive() {
  ALV_VAULT_ONEDRIVE_NAME=$1
  alv_vault_require_rclone
  alv_vault_require_new_profile "$ALV_VAULT_ONEDRIVE_NAME"
  ALV_VAULT_ONEDRIVE_BACKING=alv-$ALV_VAULT_ONEDRIVE_NAME-onedrive
  ALV_VAULT_ONEDRIVE_CRYPT=alv-$ALV_VAULT_ONEDRIVE_NAME-crypt
  alv_vault_plan_remote "$ALV_VAULT_ONEDRIVE_BACKING"

  printf 'rclone will open OneDrive authorization in your browser.\n' >&2
  if ! rclone config create \
    "$ALV_VAULT_ONEDRIVE_BACKING" \
    onedrive \
    config_is_local true \
    config_type onedrive \
    disable_site_permission true \
    description "$ALV_VAULT_SETUP_MARKER" \
    --no-output; then
    alv_fail "OneDrive authorization failed"
  fi

  ALV_VAULT_ONEDRIVE_CONFIG=$(rclone config redacted \
    "$ALV_VAULT_ONEDRIVE_BACKING" 2>/dev/null) || \
    alv_fail "could not inspect the OneDrive rclone remote"
  ALV_VAULT_ONEDRIVE_TYPE=$(printf '%s\n' "$ALV_VAULT_ONEDRIVE_CONFIG" | \
    sed -n 's/^drive_type[[:space:]]*=[[:space:]]*//p' | sed -n '1p')
  case "$ALV_VAULT_ONEDRIVE_TYPE" in
    personal) ;;
    business|documentLibrary)
      alv_fail "OneDrive setup supports Personal only; configure this target manually with rclone and use 'vault add rclone'"
      ;;
    *)
      alv_fail "could not confirm a OneDrive Personal target; configure it manually with rclone and use 'vault add rclone'"
      ;;
  esac

  alv_vault_create_crypt \
    "$ALV_VAULT_ONEDRIVE_CRYPT" \
    "$ALV_VAULT_ONEDRIVE_BACKING:agent-log-vault/$ALV_VAULT_ONEDRIVE_NAME"
  alv_vault_save_validated \
    "$ALV_VAULT_ONEDRIVE_NAME" onedrive "rclone:$ALV_VAULT_ONEDRIVE_CRYPT:"
}

alv_vault_target_parts() {
  ALV_VAULT_TARGET=$1
  alv_vault_validate_provider_value "$ALV_VAULT_TARGET" "existing rclone target"
  case "$ALV_VAULT_TARGET" in
    /*)
      [ "$ALV_VAULT_TARGET" != / ] || \
        alv_fail "filesystem root cannot be used as a vault"
      ALV_VAULT_TARGET_REMOTE=
      ALV_VAULT_TARGET_ROOT=$ALV_VAULT_TARGET
      ;;
    *:*)
      ALV_VAULT_TARGET_REMOTE=${ALV_VAULT_TARGET%%:*}
      ALV_VAULT_TARGET_ROOT=${ALV_VAULT_TARGET#*:}
      case "$ALV_VAULT_TARGET_REMOTE" in
        ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*)
          alv_fail "existing rclone target has an invalid remote name"
          ;;
      esac
      alv_rclone_storage_validate_root "$ALV_VAULT_TARGET_ROOT"
      ;;
    *) alv_fail "existing target must be an rclone remote or absolute path" ;;
  esac
}

alv_vault_add_rclone() {
  ALV_VAULT_EXISTING_NAME=$1
  ALV_VAULT_EXISTING_TARGET=$2
  alv_vault_require_rclone
  alv_vault_require_new_profile "$ALV_VAULT_EXISTING_NAME"
  alv_vault_target_parts "$ALV_VAULT_EXISTING_TARGET"

  if [ -z "$ALV_VAULT_TARGET_REMOTE" ]; then
    ALV_VAULT_TARGET_ROOT=$(alv_canonical_directory "$ALV_VAULT_TARGET_ROOT")
    alv_vault_local_assert_external "$ALV_VAULT_TARGET_ROOT"
    ALV_VAULT_EXISTING_TARGET=$ALV_VAULT_TARGET_ROOT
  fi

  if [ -n "$ALV_VAULT_TARGET_REMOTE" ]; then
    ALV_VAULT_EXISTING_CONFIG=$(rclone config redacted \
      "$ALV_VAULT_TARGET_REMOTE" 2>/dev/null) || \
      alv_fail "cannot read existing rclone target: $ALV_VAULT_TARGET_REMOTE"
    if printf '%s\n' "$ALV_VAULT_EXISTING_CONFIG" | \
        grep -Eq '^type[[:space:]]*=[[:space:]]*crypt[[:space:]]*$'; then
      alv_vault_save_validated \
        "$ALV_VAULT_EXISTING_NAME" \
        rclone \
        "rclone:$ALV_VAULT_TARGET_REMOTE:$ALV_VAULT_TARGET_ROOT"
      return 0
    fi
  fi

  ALV_VAULT_EXISTING_CRYPT=alv-$ALV_VAULT_EXISTING_NAME-crypt
  alv_vault_create_crypt "$ALV_VAULT_EXISTING_CRYPT" "$ALV_VAULT_EXISTING_TARGET"
  alv_vault_save_validated \
    "$ALV_VAULT_EXISTING_NAME" rclone "rclone:$ALV_VAULT_EXISTING_CRYPT:"
}

alv_vault_export_recovery() {
  ALV_VAULT_RECOVERY_NAME=$1
  ALV_VAULT_RECOVERY_OUTPUT=$2
  alv_profile_load "$ALV_VAULT_RECOVERY_NAME"
  alv_rclone_storage_open "$ALV_PROFILE_LOCATION"

  [ ! -e "$ALV_VAULT_RECOVERY_OUTPUT" ] && [ ! -L "$ALV_VAULT_RECOVERY_OUTPUT" ] || \
    alv_fail "refusing to overwrite recovery export: $ALV_VAULT_RECOVERY_OUTPUT"
  ALV_VAULT_RECOVERY_DIRECTORY=${ALV_VAULT_RECOVERY_OUTPUT%/*}
  if [ "$ALV_VAULT_RECOVERY_DIRECTORY" = "$ALV_VAULT_RECOVERY_OUTPUT" ]; then
    ALV_VAULT_RECOVERY_DIRECTORY=.
  elif [ -z "$ALV_VAULT_RECOVERY_DIRECTORY" ]; then
    ALV_VAULT_RECOVERY_DIRECTORY=/
  fi
  ALV_VAULT_RECOVERY_DIRECTORY=$(alv_canonical_directory "$ALV_VAULT_RECOVERY_DIRECTORY")
  ALV_VAULT_RECOVERY_OUTPUT=$ALV_VAULT_RECOVERY_DIRECTORY/${ALV_VAULT_RECOVERY_OUTPUT##*/}
  alv_local_publication_prepare "$ALV_VAULT_RECOVERY_OUTPUT"
  ALV_VAULT_RECOVERY_OUTPUT=$ALV_LOCAL_PUBLICATION_DESTINATION

  command -v jq >/dev/null 2>&1 || \
    alv_fail "vault recovery export requires jq"
  ALV_VAULT_RECOVERY_DUMP=$(rclone config dump 2>/dev/null) || \
    alv_fail "could not export rclone configuration"
  if ! printf '%s\n' "$ALV_VAULT_RECOVERY_DUMP" | jq -e \
      --arg remote "$ALV_RCLONE_STORAGE_REMOTE" \
      '.[$remote] != null' >/dev/null; then
    alv_fail "encrypted rclone configuration is missing from the export"
  fi
  ALV_VAULT_RECOVERY_TARGET=$(printf '%s\n' "$ALV_VAULT_RECOVERY_DUMP" | jq -r \
    --arg remote "$ALV_RCLONE_STORAGE_REMOTE" \
    '.[$remote].remote // empty')
  [ -n "$ALV_VAULT_RECOVERY_TARGET" ] || \
    alv_fail "encrypted rclone configuration has no backing target"

  ALV_VAULT_RECOVERY_BACKING_NAME=
  case "$ALV_VAULT_RECOVERY_TARGET" in
    /*) ;;
    *:*)
      ALV_VAULT_RECOVERY_BACKING_NAME=${ALV_VAULT_RECOVERY_TARGET%%:*}
      if ! printf '%s\n' "$ALV_VAULT_RECOVERY_DUMP" | jq -e \
          --arg remote "$ALV_VAULT_RECOVERY_BACKING_NAME" \
          '.[$remote] != null' >/dev/null; then
        alv_fail "backing rclone configuration is missing from the export"
      fi
      ;;
  esac

  [ -f "$ALV_LOCAL_PUBLICATION_STAGE" ] && \
    [ ! -L "$ALV_LOCAL_PUBLICATION_STAGE" ] || \
    alv_fail "recovery publication stage changed unexpectedly"
  ALV_VAULT_RECOVERY_MODE=$(alv_file_mode "$ALV_LOCAL_PUBLICATION_STAGE")
  [ "$ALV_VAULT_RECOVERY_MODE" = 600 ] || \
    alv_fail "recovery publication stage permissions are not 0600"
  {
    printf '# agent-log-vault recovery config\n'
    printf '# vault: %s\n' "$ALV_VAULT_RECOVERY_NAME"
    printf '# logical root: %s\n' "$ALV_RCLONE_STORAGE_ROOT"
    printf '# Sensitive: contains provider credentials and crypt secrets.\n\n'
    if [ -n "$ALV_VAULT_RECOVERY_BACKING_NAME" ]; then
      printf '[%s]\n' "$ALV_VAULT_RECOVERY_BACKING_NAME"
      printf '%s\n' "$ALV_VAULT_RECOVERY_DUMP" | jq -r \
        --arg remote "$ALV_VAULT_RECOVERY_BACKING_NAME" \
        '.[$remote] | to_entries[] | "\(.key) = \(.value | tostring)"'
      printf '\n'
    fi
    printf '[%s]\n' "$ALV_RCLONE_STORAGE_REMOTE"
    printf '%s\n' "$ALV_VAULT_RECOVERY_DUMP" | jq -r \
      --arg remote "$ALV_RCLONE_STORAGE_REMOTE" \
      '.[$remote] | to_entries[] | "\(.key) = \(.value | tostring)"'
  } > "$ALV_LOCAL_PUBLICATION_STAGE"
  chmod 600 "$ALV_LOCAL_PUBLICATION_STAGE" || \
    alv_fail "could not secure the recovery publication stage"
  [ -f "$ALV_LOCAL_PUBLICATION_STAGE" ] && \
    [ ! -L "$ALV_LOCAL_PUBLICATION_STAGE" ] || \
    alv_fail "recovery publication stage changed unexpectedly"
  ALV_VAULT_RECOVERY_MODE=$(alv_file_mode "$ALV_LOCAL_PUBLICATION_STAGE")
  [ "$ALV_VAULT_RECOVERY_MODE" = 600 ] || \
    alv_fail "recovery publication stage permissions are not 0600"
  ALV_VAULT_RECOVERY_HASH=$(alv_sha256_file "$ALV_LOCAL_PUBLICATION_STAGE")
  alv_local_publication_publish \
    "$ALV_VAULT_RECOVERY_OUTPUT" "$ALV_VAULT_RECOVERY_HASH"

  alv_require_regular_file "$ALV_VAULT_RECOVERY_OUTPUT"
  ALV_VAULT_RECOVERY_MODE=$(alv_file_mode "$ALV_VAULT_RECOVERY_OUTPUT")
  [ "$ALV_VAULT_RECOVERY_MODE" = 600 ] || \
    alv_fail "recovery export permissions are not 0600"

  printf 'wrote sensitive recovery config to %s\n' "$ALV_VAULT_RECOVERY_OUTPUT"
  if [ -n "$ALV_RCLONE_STORAGE_ROOT" ]; then
    ALV_VAULT_RECOVERY_LIST_TARGET=$ALV_RCLONE_STORAGE_REMOTE:$ALV_RCLONE_STORAGE_ROOT/archived_sessions
  else
    ALV_VAULT_RECOVERY_LIST_TARGET=$ALV_RCLONE_STORAGE_REMOTE:archived_sessions
  fi
  printf 'use this file as RCLONE_CONFIG and verify target: %s\n' \
    "$ALV_VAULT_RECOVERY_LIST_TARGET"
  printf 'recreate vault profile %s from encrypted target: %s:%s\n' \
    "$ALV_VAULT_RECOVERY_NAME" "$ALV_RCLONE_STORAGE_REMOTE" \
    "$ALV_RCLONE_STORAGE_ROOT"
}
