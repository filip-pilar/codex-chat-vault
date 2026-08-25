# agent-log-vault

`agent-log-vault` (`alv`) safely moves Codex archived chats between
`archived_sessions` and an encrypted cold vault.

```text
Codex archived_sessions <-> encrypted cold vault
```

Cold storage always uses rclone `crypt`, whether its backing storage is a
folder, mounted drive, Cloudflare R2, Backblaze B2, Dropbox, OneDrive Personal,
or another rclone target.

## Use with an agent

Repository-aware agents should read `AGENTS.md` before acting. Claude Code uses
the `CLAUDE.md` bridge to load the same instructions. A useful starting request
is: “Read `AGENTS.md`, inspect my setup read-only, explain the exact proposed
actions, and ask before changing real Codex or cloud state.”

An agent may safely begin with `./alv --help`, `./alv vault list`, and
`./alv list local`. A general request to use the repository should not be
treated as permission to offload or restore histories.

## Setup

There is no build or installation step. Run `./alv` from the cloned repository
and keep the launcher, main executable, and `lib/agent-log-vault/` together.

The CLI requires `rclone` and either `shasum` or `sha256sum`. Creating a vault
also requires `openssl`. `jq` enables filtered listings, inspection, and
recovery export. When available, `sqlite3` adds Codex's stored title, archive
time, and Git branch to inspection output.

Create a local encrypted vault in an existing directory:

```sh
mkdir -p /absolute/path/to/cold-vault
./alv vault add local cold --path /absolute/path/to/cold-vault
```

Or configure a cloud vault. R2 expects bucket-scoped Object Read & Write
credentials. B2 expects a bucket-scoped Read and Write application key for the
existing bucket. Dropbox and OneDrive hand browser authorization to rclone.

```sh
./alv vault add r2 cold
./alv vault add b2 cold
./alv vault add dropbox cold
./alv vault add onedrive cold
```

Run R2 and B2 setup without secret flags when possible and answer the private
prompts yourself. `./alv --help` documents every non-interactive option, but
command-line secrets can be exposed through shell history or agent logs.

The OneDrive helper accepts Personal accounts only. Configure OneDrive
Business, SharePoint, or Google Drive directly in rclone, then use the advanced
command below.

Advanced users can wrap any existing rclone target. If the target is already a
secure `crypt` remote, it is used directly.

```sh
./alv vault add rclone cold --remote existing-remote:optional/path
```

Setup creates the encryption configuration in rclone, performs a disposable
upload/read-back check, and saves the named vault only if validation succeeds.
The first vault is the default. Use `./alv vault list`,
`./alv vault use <name>`, or `--vault <name>` when more than one is configured.

ALV profiles default to `${XDG_CONFIG_HOME:-$HOME/.config}/agent-log-vault` and
contain no credentials. `ALV_CONFIG_HOME` overrides that location. Codex data
defaults to `${CODEX_HOME:-$HOME/.codex}`; rclone owns provider credentials and
encryption secrets.

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

Offload uploads and reads back the full JSONL. Verify and restore also download
the full JSONL, so large threads require corresponding network transfer and
temporary free space.

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

The test suite also requires `rg` (ripgrep). It runs ShellCheck when available;
CI requires it.

```sh
./tests/run.sh
```

The tests use disposable Codex homes, local storage, rclone configurations, and
provider mocks. They do not access the normal rclone configuration, cloud
accounts, browser OAuth, or the real `~/.codex`.

Separately approved macOS live tests have passed for local storage, Cloudflare
R2, Backblaze B2, and Dropbox, including encrypted offload, read-back
verification, restoration, and exact-byte comparison. OneDrive Personal has
only isolated mock coverage so far.
