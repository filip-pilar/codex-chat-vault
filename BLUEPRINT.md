# agent-log-vault blueprint

`agent-log-vault` is a CLI for moving old Codex chats out of
`archived_sessions` and restoring them when needed.

## Model

```text
Codex archived chats <-> transfer engine <-> storage destination
                                             |- filesystem adapter
                                             `- cloud adapter
```

A stored chat consists of its original `rollout-*.jsonl` file and a SHA-256
checksum. The JSONL is treated as opaque data: its bytes are never parsed,
normalized, or rewritten.

Discovery reads only the first `session_meta` record. Chats can be narrowed by
creation date, recorded working directory, or size, then selected by their
exact rollout filename. Inspecting and filtering never perform a transfer or
removal.

The transfer engine supports a Codex endpoint and storage locations:

- The Codex endpoint finds and restores chats in `archived_sessions`.
- `file:` stores chats in a local directory or mounted volume.
- Cloud adapters make providers such as Cloudflare R2, Backblaze B2, and Google
  Drive easy to configure and use.

Storage backends provide the same basic operations: put, get, list, and verify.
The filesystem backend is built into the CLI. Cloud adapters may use rclone for
provider access while keeping credentials and provider details out of the core.

## Transfers

Putting a chat into the vault copies it and verifies the destination. It does
not remove the Codex copy.

Removing a chat from Codex is a separate, explicit action allowed only after a
vaulted copy has been verified. Internally, offloading is always
copy -> verify -> remove, never a direct move.

Restoring retrieves and verifies the original bytes before placing the JSONL
in Codex's `archived_sessions` directory. Restoration leaves the vaulted copy
intact.

Existing completed files are never overwritten. Transfers use temporary
destinations and finalize only after verification succeeds.

## Encryption

Encryption belongs to the storage destination rather than the Codex format.
Local destinations store the raw JSONL and checksum. Cloud destinations encrypt
filenames and contents locally while uploading and decrypt them while
downloading.

The CLI works only with the original Codex bytes. Cloud tooling owns provider
credentials and encryption configuration; `agent-log-vault` stores neither.
