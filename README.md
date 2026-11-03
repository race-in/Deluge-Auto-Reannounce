# Deluge Auto Reannounce — Feral Rootless Edition

A per-user automation for Feral Hosting shared slots running Deluge 1.3.15. It handles only the torrent passed by Deluge's Execute **Torrent Added** event, and force-reannounces it until a tracker reports `Announce OK` or the configured runtime expires.

## Feral compatibility goals

- No root, sudo, systemd, system package installation, or global Python/Deluge package modification.
- All project files, configuration and logs stay under the slot user's home directory.
- Existing Deluge daemon and torrents are not restarted or modified.
- No wildcard/all-torrent reannounce is used.

Deluge 1.3.15 is the primary target. Feral slot layouts vary; the installer detects a console executable in common user bin paths or `PATH`, reads `daemon_port` from `~/.config/deluge/core.conf`, and supports `DELUGE_CONSOLE`, `DELUGE_CONFIG_DIR`, and `DELUGE_PORT` overrides.

## Install

Run as the Feral slot user (never root):

```bash
git clone https://github.com/race-in/Deluge-Auto-Reannounce.git
cd Deluge-Auto-Reannounce
bash install.sh
```

The installer installs into `~/.local/share/deluge-auto-reannounce`, configuration into `~/.config/deluge-auto-reannounce/reannounce.conf`, logs into `~/.local/state/deluge-auto-reannounce/`, and a manual helper into `~/.local/bin/deluge-reannounce`. Re-running the installer backs up and preserves existing timing configuration.

If necessary:

```bash
DELUGE_CONSOLE="$HOME/bin/deluge-console" DELUGE_PORT=58846 bash install.sh
```

## Execute plugin

The installer attempts to register the event through Deluge Execute RPC when the active Python can import Deluge and Twisted. If this is unavailable, configure it manually in the Deluge WebUI:

`Preferences → Execute → Add`

- Event: `Torrent Added`
- Command: `/home/FERAL_USER/.local/share/deluge-auto-reannounce/execute-reannounce.sh`

Use the actual home path printed by the installer. Do not append a hash or `*`; Deluge supplies the torrent hash, name and download path. The installer does not edit `execute.conf` behind a running daemon's back and does not restart/toggle the plugin.

## How it works

1. The Execute event invokes the wrapper with the new torrent's info-hash.
2. The runner queries `deluge-console` for that torrent only.
3. Any `Announce OK` means success and stops the loop immediately.
4. `Announce Sent` is treated as an in-flight announce; the wait window is not reset on every poll.
5. Missing/error/other unsuccessful status triggers a rate-limited reannounce.
6. The runner exits on success or `MAX_RUNTIME`.

| Setting | Default | Purpose |
|---|---:|---|
| `INITIAL_DELAY` | `0.5` | Delay after added event |
| `CHECK_INTERVAL` | `2` | Tracker status poll interval (seconds) |
| `REANNOUNCE_INTERVAL` | `30` | Minimum seconds between force reannounces |
| `SENT_TIMEOUT` | `15` | Wait for an in-flight announce |
| `MAX_RUNTIME` | `300` | Maximum run time (seconds) |
| `DELUGE_HOST` | `127.0.0.1` | Daemon address |
| `DELUGE_PORT` | detected / `58846` | Daemon port |

Edit the config with `nano ~/.config/deluge-auto-reannounce/reannounce.conf`. Changes apply to subsequent added torrents; no Deluge restart is needed. Keep retry intervals respectful of tracker announce rules.

## Manual use and logs

```bash
~/.local/bin/deluge-reannounce TORRENT_HASH
~/.local/share/deluge-auto-reannounce/execute-reannounce.sh TORRENT_HASH "Manual Test" "/path/to/download"
tail -f ~/.local/state/deluge-auto-reannounce/reannounce.log
```

The info-hash must be exactly 40 hexadecimal characters. Only that torrent is passed to `reannounce`.

## Uninstall

```bash
bash uninstall.sh
```

The uninstaller removes this project's runner, wrapper and helper. It asks before deleting config and logs. If the Execute event remains, remove that one entry in Deluge Preferences → Execute. Deluge, plugins, torrents and data are untouched.

## Troubleshooting

- **Console not found:** use `DELUGE_CONSOLE=/absolute/path/to/deluge-console bash install.sh`.
- **No event log:** ensure Execute is enabled and the Torrent Added event points to the installed wrapper.
- **RPC registration skipped:** add the event manually in the WebUI as above.
- **Wrong daemon port:** set `DELUGE_PORT` in the project config to the `daemon_port` from the Deluge core config.

## Tests

```bash
bash -n install.sh uninstall.sh scripts/reannounce-new.sh tests/test-runner.sh
python -m py_compile scripts/update-tracker.py scripts/configure-execute.py
bash tests/test-runner.sh
```

GitHub Actions also runs ShellCheck, Bash syntax, Python syntax and mocked runner tests. Mock tests do not replace an integration test against a real Feral Deluge 1.3.15 daemon; verify your slot's console path, RPC credentials and Execute plugin behavior before relying on it in production.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
