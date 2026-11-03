# Deluge Auto Reannounce — Feral Rootless Edition

[![CI](https://github.com/race-in/Deluge-Auto-Reannounce/actions/workflows/ci.yml/badge.svg)](https://github.com/race-in/Deluge-Auto-Reannounce/actions/workflows/ci.yml)

A per-user, rootless helper for **Feral Hosting shared slots** running **Deluge 1.3.15**. It watches only a newly added torrent and uses a torrent-specific **Pause → Resume** cycle to trigger a fresh tracker announce. It repeats the cycle at the configured interval until at least one tracker reports `Announce OK` or the configured time limit is reached.

> This edition is designed around Feral-style shared-slot constraints: no root, no sudo, no system package installation, no systemd unit, no global Python/Deluge package modification, and no daemon restart. Project files, config and logs stay under the slot user's home directory.

## What it does

1. Deluge's Execute plugin fires the **Torrent Added** event.
2. The wrapper receives the torrent hash, name and download path.
3. The runner queries `deluge-console` for that torrent's state and tracker status.
4. It stops immediately if any tracker reports `Announce OK`.
5. It polls tracker status every `CHECK_INTERVAL` seconds. While `Announce Sent` is reported, it gives the in-flight announce `SENT_TIMEOUT` seconds to complete before retrying; it does not interrupt a pending response.
6. For a failed announce, it issues `pause HASH`, then `resume HASH` for that exact torrent; attempts are rate-limited by `REANNOUNCE_INTERVAL`.
7. It does not change a torrent that was already paused, and it defers torrents in queued/checking/other non-active states.
8. If a resume command fails or its result is ambiguous, recovery takes priority and the runner keeps retrying resume until Deluge confirms the torrent is no longer paused.
9. It exits on success or after `MAX_RUNTIME` (except that it will not abandon an unresolved resume and leave the torrent paused).

It never selects `*`, never loops over the whole torrent list, and does not alter tracker URLs, torrent data, Deluge preferences or libtorrent settings. A per-torrent lock prevents duplicate runners for the same hash in the same instance.

## Target environment

| Item | Target |
|---|---|
| Hosting | Feral Hosting rootless/shared slot |
| Deluge | 1.3.15 (primary target) |
| Python | Deluge's own Python environment; RPC helper supports Python 2/3 syntax |
| Privileges | Ordinary slot user; do not run as root |

The automatic runner uses Deluge's torrent-specific `pause` and `resume` console commands; it does not invoke the global torrent list or edit tracker URLs. No Deluge package directory is modified.

Feral slot layouts and Python environments can differ. The installer detects `deluge-console` in PATH and common user bin paths. It prefers the interpreter in the console's shebang; set `DELUGE_PYTHON` to override this when needed. Deluge 1.3 config files contain a concatenated header and settings object, so the installer extracts `daemon_port` directly rather than parsing the full file as JSON.

## Installation

Clone the repository as the Feral slot user:

```bash
git clone https://github.com/race-in/Deluge-Auto-Reannounce.git
cd Deluge-Auto-Reannounce
bash install.sh
```

Do **not** use `sudo`. The installer refuses to run as root.


### Multiple Deluge instances on one slot

Each instance must use its own `DELUGE_INSTANCE` name, console, Python interpreter, config directory and daemon port. The default install keeps the original paths. Named instances use isolated data/config/state directories and their own manual shortcut.

Install the Standard instance:

```bash
bash install.sh
```

Install Jerry separately (using the paths confirmed on your slot):

```bash
DELUGE_INSTANCE=jerry \\
DELUGE_CONSOLE="$HOME/.local/opt/deluge-1.3.15-jerry/bin/deluge-console" \\
DELUGE_PYTHON="$HOME/.local/opt/deluge-1.3.15-jerry/bin/python2.7" \\
DELUGE_CONFIG_DIR="$HOME/.config/deluge-jerry" \\
DELUGE_PORT=28602 \\
bash install.sh
```

The Jerry instance uses `deluge-auto-reannounce-jerry` data/config/state directories and `~/.local/bin/deluge-reannounce-jerry`. The runner and manual command always pass that instance's `-c` config directory to `deluge-console`; RPC registration reads `localclient` credentials from that same directory. This prevents accidentally using Standard Deluge's auth/config. Re-run with the same `DELUGE_INSTANCE` and overrides to upgrade that instance. Remove only Jerry with `DELUGE_INSTANCE=jerry bash uninstall.sh`.

### Optional overrides

```bash
DELUGE_CONSOLE="$HOME/bin/deluge-console" \
DELUGE_PYTHON="$HOME/.local/venv/deluge/bin/python" \
DELUGE_CONFIG_DIR="$HOME/.config/deluge" \
DELUGE_PORT=58846 \
bash install.sh
```

The installer stores files in:

```text
~/.local/share/deluge-auto-reannounce/
  execute-reannounce.sh
  reannounce-new.sh

~/.config/deluge-auto-reannounce/
  reannounce.conf         # mode 0600

~/.local/state/deluge-auto-reannounce/
  reannounce.log

~/.local/bin/
  deluge-reannounce       # manual one-torrent shortcut
```

Re-running the installer backs up the previous config and preserves timing preferences.

## Execute plugin setup

The installer attempts to register the event through Deluge Execute RPC when the selected Python can import Deluge and Twisted. It does not edit `execute.conf` behind a running daemon's back and does not restart or toggle the plugin.

If automatic registration is unavailable, configure it manually in the Deluge WebUI:

```text
Preferences → Execute → Add
Event: Torrent Added
Command: /home/FERAL_USER/.local/share/deluge-auto-reannounce/execute-reannounce.sh
```

Use the actual home path printed by the installer. Add the command exactly as shown; Deluge supplies the torrent hash, name and download path. Do not append a manual hash or `*`. The Execute plugin must already be installed/enabled in the Feral Deluge build.

## Default settings

| Setting | Default | Meaning |
|---|---:|---|
| `DELUGE_HOST` | `127.0.0.1` | Local daemon address |
| `DELUGE_PORT` | detected / `58846` | Deluge daemon port |
| `INITIAL_DELAY` | `0.5` | Delay after torrent-added event |
| `CHECK_INTERVAL` | `1` | Tracker status poll interval (seconds) |
| `REANNOUNCE_INTERVAL` | `15` | Minimum seconds between reannounce requests after no successful response |
| `SENT_TIMEOUT` | `20` | Wait for an in-flight announce response before retrying |
| `CONSOLE_TIMEOUT` | `20` | Maximum seconds for one Deluge Console RPC command when GNU `timeout` is available |
| `MAX_RUNTIME` | `900` | Maximum run time (15 minutes); `0` disables the runtime limit |

Edit:

```bash
nano ~/.config/deluge-auto-reannounce/reannounce.conf
```

Changes apply to subsequent torrents; no Deluge restart is needed. The defaults allow up to 15 minutes for slower trackers, check status every 2 seconds, wait up to 20 seconds for an in-flight response, and retry a non-successful announce every 15 seconds. Tracker announce rules still apply: use a shorter retry interval only where the tracker permits it.

## Status decisions

| Observed status | Action |
|---|---|
| Any `Announce OK` | Stop successfully; do not send more requests |
| `Announce Sent` | Wait for `SENT_TIMEOUT` for the pending response; retry only if it remains unresolved |
| Empty / unavailable status or RPC error | Do not alter torrent state; retry the status query until timeout |
| Tracker error / non-success status | Pause then resume that active torrent when the retry interval allows |
| Torrent already paused | Stop and preserve the user's paused state |
| Queued / checking / other non-active state | Wait without changing torrent state |
| Resume failed / ambiguous | Retry resume and verify state before any further announce attempt |
| Runtime reached | Stop with timeout exit status |

A torrent may have several trackers. Any reported `Announce OK` is treated as success. The runner checks the Deluge state before acting; only active `Downloading` or `Seeding` torrents are eligible for a Pause → Resume attempt.

## Manual commands and logs

Run the Pause → Resume retry workflow for one torrent:

```bash
~/.local/bin/deluge-reannounce TORRENT_HASH
```

The manual shortcut uses the same runner as the Torrent Added event; it does not call Deluge's direct `reannounce` command.

Test the event wrapper (the hash must be 40 hexadecimal characters):

```bash
~/.local/share/deluge-auto-reannounce/execute-reannounce.sh \
  TORRENT_HASH "Manual Test" "/path/to/download"
```

Watch the log:

```bash
tail -f ~/.local/state/deluge-auto-reannounce/reannounce.log
```

## Uninstall

```bash
bash uninstall.sh
```

The uninstaller removes this project's runner, wrapper and manual shortcut. It asks before deleting config and logs. It does not remove Deluge, plugins, torrents or data. If the Execute event remains, remove that entry manually in Deluge Preferences → Execute.

## Troubleshooting

- **Console not found:** set `DELUGE_CONSOLE=/absolute/path/to/deluge-console` when running the installer.
- **No event log:** ensure Execute is enabled and the Torrent Added event points to the installed wrapper. Confirm the event entry is loaded by the running daemon; editing `execute.conf` while the daemon is running does not register a new handler until the plugin reloads.
- **Torrent unexpectedly paused:** inspect `RESUME_FAILED`, `RESUME_RETRY_FAILED` and `RESUME_VERIFY_PENDING` log entries. The runner prioritizes resume recovery over announce timeout to avoid intentionally abandoning a torrent after a pause attempt.
- **Duplicate event:** the per-hash lock logs `DUPLICATE` and prevents a second runner from operating on the same torrent.
- **RPC registration fails:** use the WebUI manual Execute setup above. Ensure `DELUGE_PYTHON` points to the Python environment with Deluge and Twisted modules.
- **Wrong daemon port:** check `daemon_port` in `~/.config/deluge/core.conf` and set `DELUGE_PORT` in the project config.
- **Torrent ID rejected:** Execute must pass Deluge's full 40-character info-hash as argument 1.

## Development and tests

```bash
bash -n install.sh uninstall.sh scripts/reannounce-new.sh tests/test-runner.sh tests/test-installer.sh
python -m py_compile scripts/configure-execute.py
bash tests/test-runner.sh
bash tests/test-installer.sh
```

GitHub Actions runs ShellCheck, Bash syntax, Python syntax and mocked runner/installer tests. Mocks do not replace integration against a real Feral Deluge daemon. Verify the console path, RPC port and Execute plugin behavior in your slot before relying on it in production.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
