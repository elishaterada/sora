#!/usr/bin/env python3
"""Exercise optional Bash hooks in a disposable PTY, without a terminal UI.

Uses Python's standard library and the requested Bash binary only. No startup
files, user history, credentials, or network settings are read or changed.
"""
import argparse
import os
from pathlib import Path
import pty
import re
import select
import signal
import time
import tempfile
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parent.parent


def read_output(fd, timeout=3):
    data = b""
    deadline = time.monotonic() + timeout
    quiet = None
    while time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.05)
        if ready:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            data += chunk
            quiet = time.monotonic()
        elif quiet and time.monotonic() - quiet >= 0.2:
            break
    return data


def command_reports(output):
    parts = []
    reports = []
    for raw in re.findall(rb"\x1b\]2;(.*?)\x07", output):
        value = raw.decode("utf-8")
        if value.startswith("sora-chunk;"):
            _, index, total, part = value.split(";", 3)
            if int(index) == 0:
                parts = []
            assert int(index) == len(parts), "Broken title chunk order"
            parts.append(part)
            if len(parts) != int(total):
                continue
            value = "".join(parts)
        if value.startswith("sora-command;1;"):
            reports.append(unquote(value[len("sora-command;1;"):]))
    return reports


def verify(shell):
    archive = tempfile.TemporaryDirectory(prefix="sora-shell-archive-")
    archive_path = Path(archive.name) / "history.txt"
    archive_text = "SORA_ARCHIVE_DISPLAY_ONLY $(printf NEVER_EVALUATE)"
    archive_path.write_text(archive_text + "\n")
    pid, fd = pty.fork()
    if pid == 0:
        os.environ.update(TERM="xterm-256color", PS1="SORA_TEST> ", PS2="CONT> ",
                          HISTFILE="/dev/null", INPUTRC="/dev/null", SORA_RESTORE_HISTORY=str(archive_path),
                          BASH_SILENCE_DEPRECATION_WARNING="1",
                          GHOSTTY_RESOURCES_DIR=str(ROOT / "Vendor/ghostty/zig-out/share/ghostty"),
                          GHOSTTY_SHELL_FEATURES="title", LC_ALL="en_US.UTF-8")
        for name in ("PROMPT_COMMAND", "BASH_ENV", "ENV", "GHOSTTY_BASH_INJECT", "SHELLOPTS", "HISTCONTROL", "HISTIGNORE"):
            os.environ.pop(name, None)
        os.execv(shell, [shell, "--noprofile", "--norc", "-i"])
    try:
        read_output(fd)

        def send(command):
            os.write(fd, (command + "\n").encode())
            return read_output(fd)

        source = "source '" + str(ROOT / "Sora/Resources/shell-integration/sora.bash").replace("'", "'\\''") + "'"
        output = send(source)
        assert b"sora-context;1;bash;local;" in output
        assert archive_text.encode() in output, "Archive was not replayed as literal display data"
        assert archive_text.encode() not in send(source), "Archive replayed twice"
        command = "printf 'SORA_TARGET_日本語\\n'"
        output = send(command)
        assert command_reports(output) == [command], repr(command_reports(output))
        assert "SORA_TARGET_日本語\r\n".encode() in output
        output = send("false")
        assert command_reports(output) == ["false"]
        assert re.search(rb"\x1b\]133;D;1;", output), "Failure status was lost"
        command = "printf 'first\\nsecond\\n'"
        assert command_reports(send(command)) == [command]
        send("HISTCONTROL=ignorespace")
        assert command_reports(send(" printf 'IGNORED_HISTORY\\n'")) == [""]
        send("set +o history")
        assert command_reports(send("printf 'DISABLED_HISTORY\\n'")) == [""]
        send("exit")
    finally:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        os.close(fd)
        os.waitpid(pid, 0)
        archive.cleanup()
    print(f"PASS {shell}: setup, Unicode, command identity, exit status, history exclusions, and literal archive replay")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("shell", nargs="?", default="/bin/bash")
    verify(parser.parse_args().shell)
