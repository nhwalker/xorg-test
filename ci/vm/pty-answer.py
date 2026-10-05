#!/usr/bin/env python3
"""Run a command at a terminal and answer its yes/no questions the way a
maintainer at that terminal would: y.

  pty-answer.py COMMAND        COMMAND runs under sh -c on a pseudo-terminal;
                               every "[y/N]:" or "[Y/n]:" it prints is
                               answered "y"; the transcript (prompts,
                               answers echoed) goes to stdout; the exit
                               status is the command's

A documented command is meant for a person at a terminal, and some commands
behave differently without one. dnf asks before it installs, and again
before it trusts a repository key it has not seen; with its standard input
not a terminal it refuses that second question outright ("Refusing to
automatically import keys when running unattended"), so `yes | dnf install`
is not what a maintainer runs. This is.
"""
import os
import pty
import re
import select
import signal
import sys

QUESTION = re.compile(rb"\[(y/N|Y/n)\]: ?$")
QUIET_LIMIT = 900           # seconds without output before the command is given up on


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp("sh", ["sh", "-c", sys.argv[1]])
    tail, answered = b"", 0
    while True:
        r, _, _ = select.select([fd], [], [], QUIET_LIMIT)
        if not r:
            sys.stdout.write(f"\n[pty-answer: no output for {QUIET_LIMIT} s; stopping the command]\n")
            os.kill(pid, signal.SIGTERM)
            break
        try:
            data = os.read(fd, 4096)
        except OSError:             # EIO: the command closed the terminal
            break
        if not data:
            break
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
        tail = (tail + data)[-256:]
        if QUESTION.search(tail):
            os.write(fd, b"y\n")
            answered += 1
            tail = b""
    _, status = os.waitpid(pid, 0)
    rc = os.waitstatus_to_exitcode(status)
    sys.stdout.write(f"\n[pty-answer: {answered} question(s) answered y; exit {rc}]\n")
    return rc if rc >= 0 else 128 - rc


if __name__ == "__main__":
    sys.exit(main())
