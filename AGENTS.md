# agent-log-vault agent instructions

## Purpose

`agent-log-vault` (`alv`) is a POSIX shell CLI that shuttles Codex archived
JSONL threads between Codex `archived_sessions` and encrypted cold storage.
Rclone is the only transfer engine, and every vault is an rclone `crypt`
remote. Read `README.md` for public usage and `BLUEPRINT.md` for the settled
product model.

There is no build step. Run `./alv` from the repository, and keep `alv`,
`agent-log-vault`, and `lib/agent-log-vault/` together.

## Operating the CLI

Treat the user's Codex history, rclone configuration, cloud accounts, and
recovery exports as sensitive external state.

- Read-only discovery commands are `./alv list local`, `./alv list cold`,
  `./alv inspect <thread>`, `./alv verify <thread>`, and `./alv vault list`.
- Do not run `vault add`, `vault use`, `vault recovery`, `offload`, or `restore`
  against real user state without authorization for the exact action and
  target. A general request to “use this repo” authorizes discovery, not
  mutation.
- `offload` removes the local archived JSONL only after the encrypted copy has
  been read back and verified. `restore` adds a local archived JSONL and keeps
  the cold copy.
- Before a real `offload` or `restore`, have the user quit Codex Desktop and
  Codex CLI processes so the archive is stable.
- `offload` uploads and downloads the full JSONL for verification; `verify` and
  `restore` also download it. For large threads, confirm network expectations
  and that `TMPDIR` has room for at least one complete JSONL.
- Never inspect or print raw JSONL contents, rclone configuration, recovery
  exports, provider credentials, or OAuth tokens unless the user explicitly
  requests it and it is necessary. Histories can contain source code,
  credentials, images, paths, and tool output.
- Never ask the user to paste provider secrets into chat or place them in an
  agent-visible command. Have the user complete credential prompts or browser
  OAuth privately in their terminal.
- Never place a recovery export in the repository. It contains everything
  needed to decrypt the vault.

Default state locations:

- Codex: `${CODEX_HOME:-$HOME/.codex}`
- ALV profiles: `$ALV_CONFIG_HOME`, otherwise
  `${XDG_CONFIG_HOME:-$HOME/.config}/agent-log-vault`
- Provider credentials and crypt secrets: rclone's own configuration

For experiments, set disposable absolute `CODEX_HOME`, `ALV_CONFIG_HOME`,
`RCLONE_CONFIG`, and `TMPDIR` paths. Never point tests at the user's normal
configuration or `~/.codex`.

## Product invariants

- Only `rollout-*.jsonl` files directly inside `archived_sessions` are valid
  sources or restore targets. Never touch active `sessions`.
- Preserve the exact JSONL bytes. Do not parse and rewrite histories.
- Cold storage is always encrypted, including ordinary folders and mounted
  drives.
- Offload order is upload, encrypted read-back, SHA-256 verification, source
  recheck, then local removal.
- Restore order is download to private temporary storage, verification, then
  atomic placement.
- Never overwrite a different file, delete the last verified copy, or remove
  the cold copy during restore.
- Any failed or interrupted operation must leave its source intact.
- Provider helpers configure rclone; they are not runtime adapters. Do not add
  a database, manifest, custom storage format, credential store, or plugin
  system without an explicit architecture decision.

## Repository map

- `agent-log-vault`: CLI parsing, shared safety helpers, and command workflows.
- `alv`: symlink-aware short launcher.
- `lib/agent-log-vault/catalog.sh`: read-only Codex archive discovery.
- `lib/agent-log-vault/profiles.sh`: named vault profiles without secrets.
- `lib/agent-log-vault/storage.sh`: small storage boundary.
- `lib/agent-log-vault/rclone-storage.sh`: encrypted storage implementation.
- `lib/agent-log-vault/vaults.sh`: provider setup, validation, and recovery.
- `tests/test.sh`: discovery and source-boundary tests.
- `tests/test-rclone.sh`: disposable real local rclone-crypt tests.
- `tests/test-providers.sh`: mocked provider setup and transaction tests.
- `tests/lint.sh`: ShellCheck over every POSIX shell entrypoint.

## Changing the repository

- Preserve POSIX `/bin/sh` compatibility and `set -eu`; do not introduce Bash
  syntax. Keep macOS and Linux behavior aligned.
- Preserve private permissions, cleanup traps, symlink rejection, normalized
  path checks, immutable transfers, and atomic placement.
- Treat filenames, paths, provider values, and JSONL data as hostile input.
- Keep credentials and crypt secrets in rclone. ALV profiles may contain only
  non-secret provider and encrypted-remote references.
- Keep CLI help, `README.md`, `BLUEPRINT.md`, and tests synchronized with any
  public behavior change.
- Add focused regression coverage for behavior changes. Provider tests must
  use mocks unless the user explicitly approves a live account test.
- Preserve unrelated worktree changes. Commit or push only when requested.

## Validation

Run the complete isolated validation from the repository root:

```sh
./tests/run.sh
```

The suite requires `rclone`, `jq`, `rg`, `openssl`, and either `shasum` or
`sha256sum`. It runs ShellCheck when installed; CI installs and requires it. The
suite must not access cloud accounts, browser OAuth, the normal rclone
configuration, or the real `~/.codex`.

Current separately approved macOS live validation has passed for local
storage, Cloudflare R2, Backblaze B2, and Dropbox. OneDrive Personal has only
isolated mock coverage. Do not infer live validation for a provider beyond
this explicit record.
