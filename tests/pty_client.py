#!/usr/bin/env python3
"""Run a command on a pseudo-terminal and feed it keystrokes from a FIFO.

The end-to-end tests attach a real tmux client this way, so popups, prompts
and key bindings run exactly as they do for a person at a terminal. Everything
the terminal shows is appended to LOG.

usage: pty_client.py FIFO LOG COLS ROWS -- COMMAND...
"""
import fcntl
import os
import pty
import select
import struct
import sys
import termios


def main():
    fifo, log, cols, rows = sys.argv[1:5]
    command = sys.argv[sys.argv.index("--") + 1:]
    pid, master = pty.fork()
    if pid == 0:
        os.execvp(command[0], command)
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", int(rows), int(cols), 0, 0))
    keys = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
    with open(log, "ab", buffering=0) as out:
        while True:
            ready, _, _ = select.select([master, keys], [], [], 0.5)
            if master in ready:
                try:
                    data = os.read(master, 65536)
                except OSError:
                    break
                if not data:
                    break
                out.write(data)
            if keys in ready:
                data = os.read(keys, 65536)
                if data:
                    os.write(master, data)
            done, _ = os.waitpid(pid, os.WNOHANG)
            if done:
                break


if __name__ == "__main__":
    main()
