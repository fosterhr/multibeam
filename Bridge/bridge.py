#!/usr/bin/env python3
"""MultiBeam bridge (Linux / anywhere Python 3 runs).

BeamNG only lets mods connect to this PC. This script listens on 127.0.0.1 and relays everything to the
remote MultiBeam server set in config.yml. In the game, add 127.0.0.1:<listen port> as the server.
On each connection it first sends "G|1" so the server can log that the player came in through a bridge.
"""

import os
import socket
import sys
import threading
import time

CONNECT_TIMEOUT = 8  # seconds
HELLO = b"G|1\n"

config_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.yml")
lock = threading.Lock()
active = 0


def log(message):
    print("[%s] %s" % (time.strftime("%H:%M:%S"), message), flush=True)


def fail(message):
    log(message)
    sys.exit(1)


def read_config(path):
    if not os.path.exists(path):
        with open(path, "w") as f:
            f.write(
                "# MultiBeam bridge configuration (YAML)\n"
                "# The remote MultiBeam server this bridge connects you to, as IP:PORT\n"
                "server: \n"
                "# Local port the game connects to. In the game, add 127.0.0.1:<this port> as a server.\n"
                "listen: 30800\n"
            )
    server, listen = "", 30800
    with open(path) as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#") or ":" not in line:
                continue
            key, value = line.split(":", 1)
            key, value = key.strip().lower(), value.strip()
            if value[:1] in ('"', "'"):
                end = value.find(value[0], 1)
                value = value[1:end] if end > 0 else value[1:]
            elif " #" in value:
                value = value.split(" #", 1)[0].strip()
            if key == "server":
                server = value
            elif key == "listen" and value.isdigit() and 0 < int(value) < 65536:
                listen = int(value)
    if not server:
        fail("No server set. Open config.yml and set  server: IP:PORT  (the MultiBeam server to bridge to).")
    host, sep, port = server.rpartition(":")
    if not sep or not host.strip() or not port.isdigit() or not 0 < int(port) < 65536:
        fail('Invalid server "%s" in config.yml. Use the form  server: IP:PORT  (e.g. 203.0.113.5:30814).' % server)
    return host.strip(), int(port), listen


def pump(source, destination):
    """Copy bytes one way until either side closes, then shut both down."""
    try:
        while True:
            data = source.recv(65536)
            if not data:
                break
            destination.sendall(data)
    except OSError:
        pass
    for s in (source, destination):
        try:
            s.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass


def handle(game, server_host, server_port):
    global active
    remote = None
    try:
        game.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        try:
            remote = socket.create_connection((server_host, server_port), timeout=CONNECT_TIMEOUT)
        except OSError as e:
            reason = "no response" if isinstance(e, socket.timeout) else (e.strerror or str(e))
            log("Could not reach %s:%d (%s)" % (server_host, server_port, reason))
            try:
                game.sendall(
                    ("E|Could not reach %s:%d (%s). Check the address and that the port is forwarded.\n"
                     % (server_host, server_port, reason)).encode("utf-8")
                )
            except OSError:
                pass
            return
        remote.settimeout(None)
        remote.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        remote.sendall(HELLO)

        with lock:
            active += 1
            count = active
        log("Game connected, relaying to %s:%d (%d active)" % (server_host, server_port, count))

        up = threading.Thread(target=pump, args=(game, remote), daemon=True)
        up.start()
        pump(remote, game)
        up.join()

        with lock:
            active -= 1
            count = active
        log("Connection closed (%d active)" % count)
    finally:
        game.close()
        if remote is not None:
            remote.close()


def main():
    server_host, server_port, listen_port = read_config(config_path)

    # loopback only: nothing outside this PC can use the bridge
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        listener.bind(("127.0.0.1", listen_port))
    except OSError as e:
        fail("Could not listen on 127.0.0.1:%d (%s). Is another bridge using this port? "
             "Change  listen:  in config.yml." % (listen_port, e.strerror or e))
    listener.listen(16)

    log("Bridge running: 127.0.0.1:%d  ->  %s:%d" % (listen_port, server_host, server_port))
    log("In BeamNG, add the server 127.0.0.1:%d and leave this window open." % listen_port)

    try:
        while True:
            game, _ = listener.accept()
            threading.Thread(target=handle, args=(game, server_host, server_port), daemon=True).start()
    except KeyboardInterrupt:
        log("Bridge stopped.")


if __name__ == "__main__":
    main()
