#!/usr/bin/env python
"""Register a Deluge Execute event through the Deluge RPC API (Py2/Py3)."""
from __future__ import print_function
import os
import sys

try:
    from twisted.internet import defer, reactor
    from deluge.ui.client import client
except Exception as exc:
    print("Deluge RPC imports unavailable: %s" % exc, file=sys.stderr)
    sys.exit(2)

port = int(sys.argv[1])
command = sys.argv[2]
host = os.environ.get("DELUGE_HOST", "127.0.0.1")


def credentials():
    # Deluge 1.3 installations can coexist under separate config directories.
    # Always prefer the explicitly selected instance auth file; the default
    # Deluge config manager may otherwise return credentials for another daemon.
    config_dir = os.environ.get("DELUGE_CONFIG_DIR",
                               os.path.expanduser("~/.config/deluge"))
    auth_path = os.path.join(config_dir, "auth")
    try:
        with open(auth_path, "r") as stream:
            for line in stream:
                fields = line.strip().split(":")
                if len(fields) >= 2 and fields[0] == "localclient":
                    return fields[0], fields[1]
    except IOError:
        pass
    raise RuntimeError("localclient credentials not found in selected Deluge auth file: %s" % auth_path)

def stop():
    if reactor.running:
        reactor.stop()


@defer.inlineCallbacks
def main():
    try:
        username, password = credentials()
        yield client.connect(host, port, username, password)
        commands = yield client.execute.get_commands()
        found = False
        for item in commands:
            # Deluge 1.3 Execute entries are [id, event, command].
            if len(item) >= 3 and item[1] == "added" and item[2] == command:
                found = True
                break
        if not found:
            yield client.execute.add_command("added", command)
        print("Execute Torrent Added event %s" % ("already registered" if found else "registered"))
        sys.exit_code = 0
    except Exception as exc:
        print("Execute event registration failed: %s" % exc, file=sys.stderr)
        sys.exit_code = 1
    finally:
        try:
            client.disconnect()
        except Exception:
            pass
        reactor.callLater(0, stop)


sys.exit_code = 1
reactor.callWhenRunning(main)
reactor.callLater(25, lambda: (print("Deluge RPC timeout", file=sys.stderr), stop()))
reactor.run()
