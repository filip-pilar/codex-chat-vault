# agent-log-vault

`agent-log-vault` (`alv`) safely moves Codex archived chats between
`archived_sessions` and an encrypted cold vault.

```text
Codex archived_sessions <-> encrypted cold vault
```

Cold storage always uses rclone `crypt`, whether its backing storage is a
folder, mounted drive, Cloudflare R2, Backblaze B2, or Google Drive.

## Setup

The CLI requires `rclone` and either `shasum` or `sha256sum`. Creating a vault
also requires `openssl`. `jq` enables filtered listings, inspection, and
recovery export.

Create a local encrypted vault in an existing directory:

```sh
mkdir -p /absolute/path/to/cold-vault
./alv vault add local cold --path /absolute/path/to/cold-vault
```

Or configure a cloud vault. R2 expects bucket-scoped Object Read & Write
credentials; B2 expects a Read and Write application key for an existing
bucket. Drive hands browser authorization to rclone.

```sh
./alv vault add r2 cold
./alv vault add b2 cold
./alv vault add drive cold
```

Advanced users can wrap any existing rclone target. If the target is already a
secure `crypt` remote, it is used directly.

```sh
./alv vault add rclone cold --remote existing-remote:optional/path
```

Setup creates the encryption configuration in rclone, performs a disposable
upload/read-back check, and saves the named vault only if validation succeeds.
The first vault is the default. Use `./alv vault list`,
`./alv vault use <name>`, or `--vault <name>` when more than one is configured.

## Everyday use

```sh
./alv list local
./alv list cold
./alv offload rollout-EXAMPLE.jsonl
./alv restore rollout-EXAMPLE.jsonl
./alv verify rollout-EXAMPLE.jsonl
```

The state transitions are:

```text
local only --offload--> cold only
cold only  --restore--> both
both       --offload--> cold only
```

Restore retains the cold copy. Offloading a restored chat verifies the existing
cold bytes and removes the local copy without uploading it again.

`list local` accepts `--long`, `--created-before YYYY-MM-DD`, `--created-after
YYYY-MM-DD`, `--project <cwd-or-name>`, and `--larger-than <bytes-or-K/M/G/T>`.
`inspect <thread>` shows identifying metadata. `CODEX_HOME` and
`--codex-home <directory>` are supported for disposable environments and
non-default Codex homes.

## Safety and recovery

- Only `rollout-*.jsonl` files directly inside `archived_sessions` can be
  offloaded.
- Offload uploads, reads back, SHA-256 verifies, rechecks the source, and only
  then removes the local file.
- Restore downloads to private temporary storage, verifies, and atomically
  places the exact bytes in `archived_sessions`.
- Different existing files are never overwritten, and failed operations retain
  their source.
- Restore never removes the cold copy.

Quit Codex Desktop and any Codex CLI process before offloading or restoring so
the archive is stable during the operation.

Rclone owns provider credentials, OAuth tokens, and encryption secrets. Back up
the recovery export securely; it is sensitive and is required to decrypt the
vault on another machine.

```sh
./alv vault recovery cold --output /secure/location/cold-recovery.conf
```

Use that file as `RCLONE_CONFIG` on the recovery machine, verify the printed
rclone target, then pass the printed encrypted target to
`alv vault add rclone` to recreate the named profile.

## Validation

```sh
./tests/test.sh
./tests/test-rclone.sh
./tests/test-providers.sh
```

The tests use disposable Codex homes, local storage, rclone configurations, and
provider mocks. They do not access the normal rclone configuration, cloud
accounts, or the real `~/.codex`.
