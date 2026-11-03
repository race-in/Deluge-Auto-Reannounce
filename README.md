# Deluge Auto Reannounce — Feral Rootless Edition

[![CI](https://github.com/race-in/Deluge-Auto-Reannounce/actions/workflows/ci.yml/badge.svg)](https://github.com/race-in/Deluge-Auto-Reannounce/actions/workflows/ci.yml)

A per-user, rootless helper for **Feral Hosting shared slots** running **Deluge 1.3.15**. It watches only a newly added torrent and asks Deluge to force-reannounce that torrent until at least one tracker reports `Announce OK` or the configured time limit is reached.

> This edition is designed around Feral-style shared-slot constraints: no root, no sudo, no system package installation, no systemd unit, no global Python/Deluge package modification, and no daemon restart. Project files, config and logs stay under the slot user's home directory.

## What it does

1. Deluge's Execute plugin fires the **Torrent Added** event.
2. The wrapper receives the torrent hash, name and download path.
3. The runner queries `deluge-console` for that torrent's tracker status.
4. It stops immediately if any tracker reports `Announce OK`.
5. It waits while `Announce Sent` is in flight, then retries only after the response timeout.
6. For missing/error/non-success status it force-reannounces only that torrent, rate-limited by `REANNOUNCE_INTERVAL`.
7. It exits on success or after `MAX_RUNTIME`.

It never selects `*`, never loops over the whole torrent list, and does not alter tracker URLs, torrent data, Deluge preferences or libtorrent settings.

## Target environment

| Item | Target |
|---|---|
| Hosting | Feral Hosting rootless/shared slot |
| Deluge | 1.3.15 (primary target) |
| Python | Deluge's own Python environment; RPC helper supports Python 2/3 syntax |
| Privileges | Ordinary slot user; do not run as root |

Deluge Console provides `reannounce` as an alias for `update_tracker`; the runner uses that existing command directly. No Deluge package directory is modified.

Feral slot layouts and Python environments can differ. The installer detects `deluge-console` in PATH and common user bin paths. It prefers the interpreter in the console's shebang; set `DELUGE_PYTHON` to override this when needed. Deluge 1.3 config files contain a concatenated header and settings object, so the installer extracts `daemon_port` directly rather than parsing the full file as JSON.

## Installation

Clone the repository as the Feral slot user:

```bash
git clone https://github.com/race-in/Deluge-Auto-Reannounce.git
cd Deluge-Auto-Reannounce
bash install.sh
```

Do **not** use `sudo`. The installer refuses to run as root.

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
| `CHECK_INTERVAL` | `2` | Tracker status poll interval (seconds) |
| `REANNOUNCE_INTERVAL` | `30` | Minimum seconds between reannounce requests |
| `SENT_TIMEOUT` | `15` | Wait for in-flight announce response |
| `MAX_RUNTIME` | `300` | Maximum run time (seconds) |

Edit:

```bash
nano ~/.config/deluge-auto-reannounce/reannounce.conf
```

Changes apply to subsequent torrents; no Deluge restart is needed. Keep retry intervals respectful of tracker announce rules. The default is 30 seconds; do not lower it unless you have verified the tracker's policy.

## Status decisions

| Observed status | Action |
|---|---|
| Any `Announce OK` | Stop successfully; do not send more requests |
| `Announce Sent` | Wait for `SENT_TIMEOUT`; do not reset the wait window on every poll |
| Empty / no status / error / other failure | Reannounce if first attempt or retry interval has elapsed |
| Runtime reached | Stop with timeout exit status |

A torrent may have several trackers. Any reported `Announce OK` is treated as success.

## Manual commands and logs

Reannounce one torrent:

```bash
~/.local/bin/deluge-reannounce TORRENT_HASH
```

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
- **No event log:** ensure Execute is enabled and the Torrent Added event points to the installed wrapper.
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
