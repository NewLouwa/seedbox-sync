# seedbox-sync

One-way media sync from a remote seedbox via SFTP (lftp), with recursive SSH-based search. Replaces Syncthing for this specific use case: large immutable binary files, no need for bidirectional sync or delta-transfer.

## Table of contents

- [Overview](#overview)
- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Customizing mappings](#customizing-mappings)
- [How it works](#how-it-works)
- [Troubleshooting](#troubleshooting)
- [Security](#security)

## Overview

The script runs on a cron schedule (every 30 minutes by default) and mirrors a set of remote folders to local storage, one at a time, only re-transferring what has changed (size/modification date). A command-line interface (`control.sh`, aliased `sbs`) lets you control everything without touching the cron job: trigger an immediate sync, target a specific title, pause, stop a running sync, test the connection, or search for a file without downloading it.

Four main files:

| File | Role | Contains secrets? | Tracked in git? |
|---|---|---|---|
| `control.sh` | User interface - every command goes through it (aliased `sbs`) | No | Yes |
| `scripts/sync.sh` | Transfer logic - called by cron or by `control.sh start` | No | Yes |
| `config.sh` | Behavior settings: mappings, paths, defaults | No, but reveals your folder layout | **No** (gitignored - copy from `config.sh.example`) |
| `/etc/seedbox-sync.env` | Credentials only | **Yes** | No |

## Features

- Incremental sync (size + modification date, no unnecessary re-transfer)
- Atomic writes - a file being transferred never appears under its final name before completion (avoids exposing partial/broken files)
- Recursive search over SSH (`find -iname`), no depth limit
- Targeted prioritization: sync an entire category or a specific title first, then resume the normal full sync
- Concurrency lock (prevents two simultaneous executions)
- Leveled logging (DEBUG/INFO/WARN/ERROR), colored in an interactive terminal, plain text in the log file
- Pause/resume/stop without touching the cron job
- Automatic log rotation (logrotate)

## Requirements

- `bash` 4+ (associative arrays)
- `lftp`
- `ssh` (client) - for recursive search
- `sshpass` - optional, only needed if no SSH key is configured
- `root` (or sudo) access for system configuration (`/etc`, cron, logrotate)

## Installation

### 1. Deploy the scripts

```bash
mkdir -p /opt/scripts/seedbox-sync/scripts
# copy control.sh and scripts/sync.sh to these locations
chmod +x /opt/scripts/seedbox-sync/control.sh /opt/scripts/seedbox-sync/scripts/sync.sh
```

### 2. Credentials

Credentials live **outside the repo**, in `/etc/seedbox-sync.env`, with restrictive permissions - nothing else goes in this file:

```bash
cat > /etc/seedbox-sync.env << 'EOF'
REMOTE_USER=your_user
REMOTE_HOST=your_host.example.com
REMOTE_PASS='password_in_single_quotes'

# Optional - SSH-based search (see How it works)
#SSH_KEY=/root/.ssh/seedbox_ed25519
#SSH_PORT=22
EOF

chmod 600 /etc/seedbox-sync.env
chown root:root /etc/seedbox-sync.env
```

The password must be wrapped in single quotes to prevent bash from interpreting any special characters it might contain (`$`, `` ` ``, spaces, etc).

### 3. Settings

Everything else - mappings, paths, defaults - lives in `config.sh`, next to the scripts. It's gitignored (it reveals your real folder layout), so start from the tracked example:

```bash
cd /opt/scripts/seedbox-sync
cp config.sh.example config.sh
nano config.sh   # fill in your MAPPINGS at minimum
```

`config.sh` is split into two clearly marked sections: values meant to be adapted per deployment (mappings, `LOCAL_BASE`, `LOG_LEVEL`, `DELETE_AFTER_IMPORT`, `LOCK_TTL_SECONDS`), and internal paths you normally shouldn't touch (`PAUSE_FLAG`, `LOCK_DIR`, `PID_FILE`, `MONITOR_PID_FILE`, `LOG_FILE`) since they're referenced elsewhere (logrotate config, this same pair of scripts) and changing them without updating everything else breaks consistency.

`DELETE_AFTER_IMPORT=1` adds `--Remove-source-files` to every `mirror` call: once a file is confirmed fully transferred, it's deleted from the remote seedbox. Useful for freeing up seedbox storage automatically, but **irreversible** - a failed or partial transfer is never deleted (lftp only removes after a confirmed successful transfer), but anything that does complete is gone from the remote immediately. Leave this at `0` unless you specifically want that behavior.

### 4. Cron

A single entry, under `root` only (avoids duplicates if the script ends up running under multiple accounts at once):

```bash
sudo crontab -e -u root
```

Add:

```
*/30 * * * * /opt/scripts/seedbox-sync/scripts/sync.sh >> /var/log/cron-sync.log 2>&1
```

### 5. Global alias

```bash
ln -sf /opt/scripts/seedbox-sync/control.sh /usr/local/bin/sbs
```

Makes the `sbs` command available everywhere, for every user, without typing the full path.

### 6. Log rotation

```bash
sbs install-logrotate
```

Generates `/etc/logrotate.d/ass-sync` directly from `LOG_FILE`, `LOG_ROTATE_FREQUENCY`, and `LOG_ROTATE_COUNT` in `config.sh` - stays consistent automatically if you ever change `LOG_FILE`, instead of drifting from a manually-written logrotate file. Re-run it any time those values change. Requires root.

### 7. SSH-based search (optional but recommended)

See [How it works](#recursive-search) for details. In short, generate a dedicated key pair:

```bash
ssh-keygen -t ed25519 -f /root/.ssh/seedbox_ed25519 -N ""
ssh-copy-id -i /root/.ssh/seedbox_ed25519.pub -p 22 your_user@your_host.example.com
```

Then uncomment `SSH_KEY=` and `SSH_PORT=` in `/etc/seedbox-sync.env`.

Without a configured key, the script automatically falls back to `sshpass` (install with `apt install -y sshpass`), reusing `REMOTE_PASS`. Functional but less clean (password visible in the process list during the call).

## Usage

Every command goes through `sbs` (once the alias is set up) or directly through `/opt/scripts/seedbox-sync/control.sh`.

### `sbs watch`

Live-tails the log file with color coding matching the log levels (green INFO, yellow WARN, red ERROR, cyan DEBUG). The log file itself stays plain text (so it's always `grep`-able); coloring happens only at display time.

```
$ sbs watch
Following /var/log/ass-sync.log live (Ctrl+C to quit)...
[2026-08-16 05:32:23] [INFO]   Transferring file `Another.E03.mkv'
```

### `sbs test`

Checks the connection and SFTP authentication without setting a lock or downloading anything.

```
$ sbs test
Testing connection to your_host.example.com...
OK - connection and auth valid
```

### `sbs find <name>`

Recursive search (SSH) across the entire remote tree, without downloading anything. Case-insensitive, partial match.

```
$ sbs find "dragon"
Recursive search for 'dragon'...
  media/TV Shows/House of the Dragon
```

### `sbs start [filter]`

Triggers a sync immediately, in the background, without waiting for the next cron run.

- No argument: full sync, normal order.
- Argument = a category name (mapping): that category is processed first, then the rest follows normally.
- Argument = a specific title (matches no category): recursive search, syncs only what matches, then resumes the normal full cycle.

```
$ sbs start "House of the Dragon"
Manual launch (priority: House of the Dragon)...
Launched in background, PID 48213
Follow: tail -f /var/log/ass-sync.log
```

### `sbs pause` / `sbs resume`

`pause` prevents the **next** cron triggers from doing anything (they exit immediately). A run already in progress when `pause` is called keeps going until it finishes normally - this is not an immediate stop.

```
$ sbs pause
Sync PAUSED (blocks next launches, does not stop a running sync)
$ sbs resume
Sync RESUMED
```

### `sbs stop`

Stops a running sync (SIGTERM, then SIGKILL after 2 seconds if needed), kills the associated `lftp` process, cleans up the lock.

```
$ sbs stop
Stopping sync.sh (PID 48213)...
Active lftp process killed
Lock and PID cleaned up
```

### `sbs status`

```
$ sbs status
Sync ACTIVE (no pause applied)
No run in progress
```

## Customizing mappings

Remote-folder to local-folder mappings live in `config.sh`, next to the scripts (see [Settings](#3-settings)). Since both `sync.sh` and `control.sh` `source` this file directly (not through a subprocess environment), a plain `declare -A` block works exactly as if it were written inline:

```bash
declare -A MAPPINGS=(
    ['remote/path/CategoryA']='local-folder-name-a'
    ['remote/path/CategoryB']='local/sub/path-b'
)
```

- **Key**: path relative to the SFTP account's home directory on the seedbox.
- **Value**: path relative to `LOCAL_BASE` (also set in `config.sh`).
- As many entries as needed; each entry triggers a full recursive mirror.

To add, rename, or remove a category: edit this block in `config.sh` only - one file, no duplication between scripts.

## How it works

### Incremental sync

`mirror --only-newer --continue` compares size and modification date between remote and local on every run - no checksums, no saved state between runs. An identical file (same size, local date >= remote date) is skipped; otherwise it's fully re-transferred.

### Atomic writes

`xfer:use-temp-file` forces lftp to write to a hidden name (`.*.lftp-tmp`) during the transfer, then rename to the final name once complete. A file being downloaded never appears under its real name in the target folder - prevents a reader (or a user doing cleanup) from encountering a truncated file and mistaking it for junk.

### Recursive search

`find`/the title mode of `start` use `ssh <host> "find media -iname '*pattern*'"` on the remote side - recursive, no depth limit, unlike a plain `lftp cls` listing which only sees the first level of a folder. Two authentication methods, automatic fallback in this order:

1. **SSH key** (recommended) - used if `SSH_KEY` is defined in `.env` and the file exists.
2. **sshpass** (fallback) - used if `sshpass` is installed and no key is configured.

The actual transfer (the real mirror) always stays on lftp/SFTP with `REMOTE_PASS` - the SSH key is only used for search, never for the transfer itself.

### Locking

An atomic lock (`mkdir /tmp/ass.lock.d` - atomic because `mkdir` fails if the directory already exists, unlike a plain `test -f` + `touch` which would leave a race-condition window) prevents two simultaneous executions. 1-hour TTL: a lock older than that is considered stale and force-cleaned (protects against an orphaned lock after a crash). The active run's PID is tracked in `/tmp/ass-sync.pid`, which lets `sbs stop` target the right process.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Permission denied` on `/etc/seedbox-sync.env` | The script is running under a user without read access (file is `600 root:root`) | Check which user the cron runs as (`crontab -l -u <user>`), align it with `root` |
| `Login incorrect` | Wrong password in `.env`, or special characters not properly escaped | Double-check the password is in single quotes, test manually with `lftp -u user,'pass' sftp://host -e "ls; bye"` |
| `Connection refused` / long timeout | Temporary softban on the seedbox side (too many failed auth attempts), or server under maintenance | Wait, check the provider's panel, avoid retrying in a loop |
| No results from `find` even though the file exists | `SSH_KEY`/`sshpass` not configured, silent fallback | Check `command -v sshpass` or that the key file exists, test `ssh -i key user@host true` manually |
| Log goes silent for several minutes | Normal on a large category - transfer in progress without any single file having finished yet | Check with `ps aux \| grep lftp` and watch the local folder's size |
| Syntax error after an edit | Always validate before deploying | `bash -n scripts/sync.sh && bash -n control.sh` |

## Security

- `.env` must never end up in this repo, nor in plain text in a ticket/chat/paste.
- Change the seedbox password immediately if it's ever exposed, even accidentally.
- Always wrap the password in single quotes in `.env` to neutralize shell special characters.
- `xfer:use-temp-file` is enabled by default - see [Atomic writes](#atomic-writes).
- Prefer a dedicated SSH key (not reused elsewhere) over `sshpass`, which exposes the password in the process list during execution.
