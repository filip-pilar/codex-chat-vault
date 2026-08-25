# Named vault profiles. Profile files contain no credentials or crypt secrets;
# those remain in rclone's configuration.

ALV_PROFILE_HOME=
ALV_PROFILE_VAULTS=
ALV_PROFILE_DEFAULT_FILE=
ALV_PROFILE_TEMP_DIRECTORY=
ALV_PROFILE_DEFAULT_TEMP=

alv_profiles_cleanup() {
  if [ -n "${ALV_PROFILE_TEMP_DIRECTORY:-}" ]; then
    case "$ALV_PROFILE_TEMP_DIRECTORY" in
      "$ALV_PROFILE_VAULTS"/.partial.*)
        if [ -d "$ALV_PROFILE_TEMP_DIRECTORY" ]; then
          /bin/rm -rf "$ALV_PROFILE_TEMP_DIRECTORY"
        fi
        ;;
    esac
    ALV_PROFILE_TEMP_DIRECTORY=
  fi

  if [ -n "${ALV_PROFILE_DEFAULT_TEMP:-}" ]; then
    case "$ALV_PROFILE_DEFAULT_TEMP" in
      "$ALV_PROFILE_HOME"/.default-vault.partial.*)
        if [ -e "$ALV_PROFILE_DEFAULT_TEMP" ]; then
          unlink "$ALV_PROFILE_DEFAULT_TEMP" 2>/dev/null || true
        fi
        ;;
    esac
    ALV_PROFILE_DEFAULT_TEMP=
  fi
}

alv_profiles_resolve_home() {
  [ -z "$ALV_PROFILE_HOME" ] || return 0

  if [ -n "${ALV_CONFIG_HOME:-}" ]; then
    ALV_PROFILE_HOME=$ALV_CONFIG_HOME
  elif [ -n "${XDG_CONFIG_HOME:-}" ]; then
    ALV_PROFILE_HOME=$XDG_CONFIG_HOME/agent-log-vault
  elif [ -n "${HOME:-}" ]; then
    ALV_PROFILE_HOME=$HOME/.config/agent-log-vault
  else
    alv_fail "cannot determine configuration directory; set ALV_CONFIG_HOME"
  fi

  case "$ALV_PROFILE_HOME" in
    /*) ;;
    *) alv_fail "agent-log-vault configuration directory must be absolute" ;;
  esac
  case "$ALV_PROFILE_HOME/" in
    *'//'*|*/./*|*/../*|*'
'*|*'	'*|*''*)
      alv_fail "agent-log-vault configuration directory is not normalized"
      ;;
  esac

  ALV_PROFILE_VAULTS=$ALV_PROFILE_HOME/vaults
  ALV_PROFILE_DEFAULT_FILE=$ALV_PROFILE_HOME/default-vault
}

alv_profiles_prepare() {
  alv_profiles_resolve_home
  [ ! -L "$ALV_PROFILE_HOME" ] || \
    alv_fail "configuration directory cannot be a symbolic link"
  mkdir -p "$ALV_PROFILE_VAULTS"
  chmod 700 "$ALV_PROFILE_HOME" "$ALV_PROFILE_VAULTS"
  [ ! -L "$ALV_PROFILE_VAULTS" ] || \
    alv_fail "vault profile directory cannot be a symbolic link"
}

alv_profile_validate_name() {
  ALV_PROFILE_VALIDATE_NAME=$1
  case "$ALV_PROFILE_VALIDATE_NAME" in
    ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*)
      alv_fail "vault name must use letters, numbers, dots, underscores, or hyphens"
      ;;
  esac
  [ "${#ALV_PROFILE_VALIDATE_NAME}" -le 48 ] || \
    alv_fail "vault name must be 48 characters or fewer"
}

alv_profile_validate_value() {
  ALV_PROFILE_VALIDATE_VALUE=$1
  ALV_PROFILE_VALIDATE_LABEL=$2
  [ -n "$ALV_PROFILE_VALIDATE_VALUE" ] || \
    alv_fail "$ALV_PROFILE_VALIDATE_LABEL cannot be empty"
  case "$ALV_PROFILE_VALIDATE_VALUE" in
    *'
'*|*''*) alv_fail "$ALV_PROFILE_VALIDATE_LABEL cannot contain a newline" ;;
  esac
}

alv_profile_directory() {
  alv_profile_validate_name "$1"
  alv_profiles_resolve_home
  ALV_PROFILE_DIRECTORY=$ALV_PROFILE_VAULTS/$1
}

alv_profile_exists() {
  alv_profile_directory "$1"
  [ -d "$ALV_PROFILE_DIRECTORY" ] && [ ! -L "$ALV_PROFILE_DIRECTORY" ]
}

alv_profile_read_file() {
  ALV_PROFILE_READ_PATH=$1
  ALV_PROFILE_READ_LABEL=$2
  [ -f "$ALV_PROFILE_READ_PATH" ] && [ ! -L "$ALV_PROFILE_READ_PATH" ] || \
    alv_fail "vault profile has no valid $ALV_PROFILE_READ_LABEL"
  ALV_PROFILE_READ_VALUE=
  IFS= read -r ALV_PROFILE_READ_VALUE < "$ALV_PROFILE_READ_PATH" || \
    [ -n "$ALV_PROFILE_READ_VALUE" ] || \
    alv_fail "could not read vault profile $ALV_PROFILE_READ_LABEL"
  alv_profile_validate_value "$ALV_PROFILE_READ_VALUE" "$ALV_PROFILE_READ_LABEL"
}

alv_profile_load() {
  ALV_PROFILE_LOAD_NAME=$1
  alv_profile_directory "$ALV_PROFILE_LOAD_NAME"
  [ -d "$ALV_PROFILE_DIRECTORY" ] && [ ! -L "$ALV_PROFILE_DIRECTORY" ] || \
    alv_fail "vault does not exist: $ALV_PROFILE_LOAD_NAME"

  alv_profile_read_file "$ALV_PROFILE_DIRECTORY/provider" provider
  ALV_PROFILE_PROVIDER=$ALV_PROFILE_READ_VALUE
  alv_profile_read_file "$ALV_PROFILE_DIRECTORY/location" location
  ALV_PROFILE_LOCATION=$ALV_PROFILE_READ_VALUE
  case "$ALV_PROFILE_LOCATION" in
    rclone:*) ;;
    *) alv_fail "vault profile does not reference encrypted rclone storage" ;;
  esac
  ALV_PROFILE_NAME=$ALV_PROFILE_LOAD_NAME
}

alv_profile_default_name() {
  alv_profiles_resolve_home
  [ -f "$ALV_PROFILE_DEFAULT_FILE" ] && [ ! -L "$ALV_PROFILE_DEFAULT_FILE" ] || \
    alv_fail "no default vault is configured; run 'vault add' first"
  ALV_PROFILE_DEFAULT_NAME=
  IFS= read -r ALV_PROFILE_DEFAULT_NAME < "$ALV_PROFILE_DEFAULT_FILE" || \
    [ -n "$ALV_PROFILE_DEFAULT_NAME" ] || \
    alv_fail "could not read the default vault"
  alv_profile_validate_name "$ALV_PROFILE_DEFAULT_NAME"
}

alv_profile_load_selected() {
  ALV_PROFILE_SELECTED=$1
  if [ -z "$ALV_PROFILE_SELECTED" ]; then
    alv_profile_default_name
    ALV_PROFILE_SELECTED=$ALV_PROFILE_DEFAULT_NAME
  fi
  alv_profile_load "$ALV_PROFILE_SELECTED"
}

alv_profile_save() {
  ALV_PROFILE_SAVE_NAME=$1
  ALV_PROFILE_SAVE_PROVIDER=$2
  ALV_PROFILE_SAVE_LOCATION=$3

  alv_profile_validate_name "$ALV_PROFILE_SAVE_NAME"
  alv_profile_validate_value "$ALV_PROFILE_SAVE_PROVIDER" provider
  alv_profile_validate_value "$ALV_PROFILE_SAVE_LOCATION" location
  alv_profiles_prepare
  alv_profile_directory "$ALV_PROFILE_SAVE_NAME"
  [ ! -e "$ALV_PROFILE_DIRECTORY" ] && [ ! -L "$ALV_PROFILE_DIRECTORY" ] || \
    alv_fail "vault already exists: $ALV_PROFILE_SAVE_NAME"

  ALV_PROFILE_TEMP_DIRECTORY=$ALV_PROFILE_VAULTS/.partial.$ALV_PROFILE_SAVE_NAME.$$
  [ ! -e "$ALV_PROFILE_TEMP_DIRECTORY" ] || \
    alv_fail "temporary vault profile already exists"
  mkdir "$ALV_PROFILE_TEMP_DIRECTORY"
  chmod 700 "$ALV_PROFILE_TEMP_DIRECTORY"
  printf '%s\n' "$ALV_PROFILE_SAVE_PROVIDER" > "$ALV_PROFILE_TEMP_DIRECTORY/provider"
  printf '%s\n' "$ALV_PROFILE_SAVE_LOCATION" > "$ALV_PROFILE_TEMP_DIRECTORY/location"
  chmod 600 \
    "$ALV_PROFILE_TEMP_DIRECTORY/provider" \
    "$ALV_PROFILE_TEMP_DIRECTORY/location"
  mv "$ALV_PROFILE_TEMP_DIRECTORY" "$ALV_PROFILE_DIRECTORY"
  ALV_PROFILE_TEMP_DIRECTORY=

  if [ ! -e "$ALV_PROFILE_DEFAULT_FILE" ]; then
    alv_profile_use "$ALV_PROFILE_SAVE_NAME"
  fi
}

alv_profile_use() {
  ALV_PROFILE_USE_NAME=$1
  alv_profile_load "$ALV_PROFILE_USE_NAME"
  alv_profiles_prepare
  ALV_PROFILE_DEFAULT_TEMP=$ALV_PROFILE_HOME/.default-vault.partial.$$
  [ ! -e "$ALV_PROFILE_DEFAULT_TEMP" ] || \
    alv_fail "temporary default-vault file already exists"
  printf '%s\n' "$ALV_PROFILE_USE_NAME" > "$ALV_PROFILE_DEFAULT_TEMP"
  chmod 600 "$ALV_PROFILE_DEFAULT_TEMP"
  mv "$ALV_PROFILE_DEFAULT_TEMP" "$ALV_PROFILE_DEFAULT_FILE"
  ALV_PROFILE_DEFAULT_TEMP=
}

alv_profile_list() {
  alv_profiles_resolve_home
  [ -d "$ALV_PROFILE_VAULTS" ] || return 0

  ALV_PROFILE_LIST_DEFAULT=
  if [ -f "$ALV_PROFILE_DEFAULT_FILE" ] && [ ! -L "$ALV_PROFILE_DEFAULT_FILE" ]; then
    IFS= read -r ALV_PROFILE_LIST_DEFAULT < "$ALV_PROFILE_DEFAULT_FILE" || true
  fi

  for ALV_PROFILE_LIST_DIRECTORY in "$ALV_PROFILE_VAULTS"/*; do
    [ -d "$ALV_PROFILE_LIST_DIRECTORY" ] || continue
    [ ! -L "$ALV_PROFILE_LIST_DIRECTORY" ] || continue
    ALV_PROFILE_LIST_NAME=${ALV_PROFILE_LIST_DIRECTORY##*/}
    alv_profile_load "$ALV_PROFILE_LIST_NAME"
    if [ "$ALV_PROFILE_LIST_NAME" = "$ALV_PROFILE_LIST_DEFAULT" ]; then
      ALV_PROFILE_LIST_MARK='*'
    else
      ALV_PROFILE_LIST_MARK=' '
    fi
    printf '%s %s\t%s\n' \
      "$ALV_PROFILE_LIST_MARK" "$ALV_PROFILE_LIST_NAME" "$ALV_PROFILE_PROVIDER"
  done
}
