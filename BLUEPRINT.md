# agent-log-vault blueprint

`agent-log-vault` is a safe shuttle between Codex archived chats and an
encrypted cold vault.

```text
Codex archived_sessions <-> encrypted cold vault
```

The everyday workflow is:

```text
alv list local
alv list cold
alv stats local
alv plan offload [filters]
alv offload <thread>
alv restore <thread>
alv verify <thread>
```

## State model

```text
local only --offload--> cold only
cold only  --restore--> both
both       --offload--> cold only
```

`restore` retains the cold copy. If a matching cold copy already exists,
`offload` verifies it and removes only the local copy without uploading again.

`stats local` summarizes archive size, age, projects, and largest tasks.
Enriched local listings support filters, sorting, limits, and JSON.
`plan offload` previews selection, reclaimable bytes, uploads, existing cold
pairs, and conflicts without changing either side. Cold presence in a plan is
never presented as content verification.

## Safety

- Only files directly inside Codex's `archived_sessions` are accepted.
- The original `rollout-*.jsonl` bytes are never rewritten.
- Cold storage is always encrypted, including folders and mounted drives.
- Offload is copy, encrypted read-back, SHA-256 verification, then local
  removal.
- Restore is encrypted download to a private temporary file, SHA-256
  verification, then atomic placement in `archived_sessions` when the
  destination filesystem supports same-directory hard links.
- Atomic no-clobber publication for restore and recovery exports requires
  same-directory hard-link support. Without it, the operation fails without
  creating or replacing the destination or removing its source.
- A different existing file is never overwritten.
- Failed or interrupted operations leave their source intact.
- A verified cold copy is never removed by restore or offload.

Each completed cold thread consists of the encrypted JSONL and its encrypted
SHA-256 sidecar. The sidecar is written last and marks the transfer complete.

## Vaults

A named vault profile points to an rclone `crypt` remote. Rclone is the single
storage and transfer engine for local folders, Cloudflare R2, Backblaze B2,
Dropbox, OneDrive Personal, and advanced user-configured targets.

```text
alv vault add local <name> --path <path>
alv vault add r2 <name>
alv vault add b2 <name>
alv vault add dropbox <name>
alv vault add onedrive <name>
alv vault add rclone <name> --remote <existing-target>
```

Provider helpers let rclone own credentials and OAuth tokens, create the crypt
layer with content and filename encryption, perform a disposable upload and
read-back check, and save the profile only after validation succeeds. The first
vault becomes the default; `alv vault use <name>` changes it.

The OneDrive helper is Personal-only. Google Drive, OneDrive Business, and
SharePoint remain available through a manually configured rclone target and
`vault add rclone`.

Profiles contain only the vault name, provider, and crypt remote. Recovery
export writes the selected rclone configuration to a user-chosen private file
and prints reconstruction instructions.
