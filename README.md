# agent-log-vault

`agent-log-vault` is a CLI for storing old Codex archived chats outside
Codex-managed storage and restoring them later without changing their bytes.

Storage locations can be an absolute local directory or an existing encrypted
rclone remote:

```text
file:/absolute/path
rclone:<crypt-remote>:<optional/root>
```

## Commands

```text
agent-log-vault list codex [filters] [--codex-home <directory>]
agent-log-vault list <location>
agent-log-vault inspect <chat-or-path> [--codex-home <directory>]
agent-log-vault put <chat-or-path> --to <location> [--codex-home <directory>]
agent-log-vault verify <chat> --at <location>
agent-log-vault restore <chat> --from <location> [--codex-home <directory>]
agent-log-vault evict <chat-or-path> --verified-at <location> [--codex-home <directory>] --yes
```

A chat can be its `rollout-*.jsonl` filename or, for `put` and `evict`, its
full path inside an `archived_sessions` directory. `CODEX_HOME` is honored;
otherwise the default is `$HOME/.codex`.

Filtered Codex listings read only the first `session_meta` record from each
rollout. They require `jq` and support:

```text
--long
--created-before YYYY-MM-DD
--created-after YYYY-MM-DD
--project <exact-cwd-or-directory-name>
--larger-than <bytes-or-K/M/G/T>
```

`--long` shows creation time, byte size, `cwd`, and the exact rollout filename.
Filters can be combined. `inspect` shows identifying metadata for one chat and,
when available, its title and archive time from the read-only Codex state
database. Discovery commands never copy, restore, or remove files.

## Example

```sh
mkdir -m 700 /Volumes/MyVault/agent-log-vault

./agent-log-vault list codex

./agent-log-vault list codex \
  --created-before 2026-06-01 \
  --project my-project \
  --larger-than 100M \
  --long

./agent-log-vault inspect rollout-EXAMPLE.jsonl

./agent-log-vault put rollout-EXAMPLE.jsonl \
  --to file:/Volumes/MyVault/agent-log-vault

./agent-log-vault verify rollout-EXAMPLE.jsonl \
  --at file:/Volumes/MyVault/agent-log-vault

./agent-log-vault evict rollout-EXAMPLE.jsonl \
  --verified-at file:/Volumes/MyVault/agent-log-vault \
  --yes

./agent-log-vault restore rollout-EXAMPLE.jsonl \
  --from file:/Volumes/MyVault/agent-log-vault
```

The same commands work with a configured rclone crypt remote:

```sh
./agent-log-vault put rollout-EXAMPLE.jsonl \
  --to 'rclone:my-vault-crypt:agent-log-vault'

./agent-log-vault verify rollout-EXAMPLE.jsonl \
  --at 'rclone:my-vault-crypt:agent-log-vault'

./agent-log-vault restore rollout-EXAMPLE.jsonl \
  --from 'rclone:my-vault-crypt:agent-log-vault'
```

`put` copies and verifies but does not remove the Codex source. `evict` is the
only destructive command: it verifies that the stored bytes match the Codex
copy immediately before removing that copy. `restore` leaves the stored copy
intact.

Stored chats live under `<vault>/archived_sessions` with SHA-256 sidecars.
Completed files are never overwritten, symbolic links are rejected, and copy
operations use temporary files before finalizing.

Stop Codex before putting, evicting, or restoring a chat so its files remain
stable during the operation.

Codex chats may contain source code, credentials, tool output, images, and
local paths. The filesystem adapter stores raw files and does not encrypt them;
use a destination whose access and encryption you trust.

## Storage adapters

The CLI core calls the storage dispatcher in `lib/agent-log-vault/storage.sh`.
The filesystem implementation is in
`lib/agent-log-vault/adapters/file.sh`. The encrypted rclone implementation is
in `lib/agent-log-vault/adapters/rclone.sh`. Keep the executable and `lib`
directory together when running the CLI.

The rclone adapter requires an existing remote whose rclone type is `crypt`,
with standard filename encryption and directory-name encryption enabled. The
CLI does not create the remote or read, store, or print its credentials and
encryption passwords. Back up the rclone configuration and crypt passwords:
without them, encrypted filenames and contents cannot be recovered.

Remote verification downloads and decrypts the complete chat and checksum,
then computes SHA-256 locally. This works without provider-specific checksum
support, but it consumes download time and any egress charged by the provider.
An interrupted upload without its checksum is omitted from `list`; retrying
`put` completes it only when its bytes exactly match the selected Codex chat.

Run the filesystem and encrypted-rclone synthetic test suites with:

```sh
./tests/test.sh
./tests/test-rclone.sh
```

The rclone test uses only a disposable local crypt remote and a temporary
rclone configuration. It does not access the normal rclone config, a cloud
provider, or the real Codex home.
