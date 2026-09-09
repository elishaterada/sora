#!/usr/bin/env python3
"""Reproducible optimized component and shell-PTY input benchmarks (macOS).

Run from any directory. --ref COMMIT benchmarks committed source for comparison.
These measure CPU work and shell echo, NOT display/input-to-photon latency.
Only temporary files and an isolated zsh -dfi are used; no shell command typed by
this benchmark is submitted. No dependencies beyond Xcode and Python 3.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import tempfile
import termios
import time

ROOT = Path(__file__).resolve().parents[1]


def percentile(values, fraction):
    return sorted(values)[min(len(values)-1, int(len(values)*fraction))]


def shell_latency(root):
    pid, fd = pty.fork()
    if pid == 0:
        os.environ['TERM'] = 'xterm-256color'
        os.execv('/bin/zsh', ['zsh', '-dfi'])
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
    pending = b''

    def receive(marker, timeout=5):
        nonlocal pending
        end = time.monotonic() + timeout
        while marker not in pending:
            remaining = end - time.monotonic()
            if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
                raise TimeoutError('Shell did not finish redraw: ' + repr(pending[-2000:]))
            pending += os.read(fd, 65536)
        _, pending = pending.split(marker, 1)

    try:
        # A marker after the complete highlighter measures each key through ZLE.
        setup = (
            f"source '{root}/Sora/Resources/zsh/prompt-line.zsh'; "
            f"source '{root}/Sora/Resources/zsh/highlight.zsh'; "
            "precmd_functions=(); PS1=''; "
            "_bench_redraw() { _sora_highlight_redraw; printf '\\e]99;done:%s\\a' $CURSOR; }; "
            "zle -N zle-line-pre-redraw _bench_redraw; printf '\\e]99;ready\\a'\n"
        )
        os.write(fd, setup.encode())
        receive(b'\x1b]99;ready\x07')
        receive(b'\x1b[?2004h')
        samples = []
        text = 'echo ' + 'hello-world-' * 16
        for trial in range(3):
            for cursor, byte in enumerate(text.encode(), 1):
                start = time.perf_counter_ns()
                os.write(fd, bytes([byte]))
                receive(f'\x1b]99;done:{cursor}\x07'.encode())
                samples.append((time.perf_counter_ns() - start) / 1e6)
            os.write(fd, b'\x15')  # Ctrl-U: discard input, never execute it.
            receive(b'\x1b]99;done:0\x07')
        return {'samples': len(samples), 'median_ms': percentile(samples, .5),
                'p95_ms': percentile(samples, .95), 'max_ms': max(samples)}
    finally:
        os.close(fd)
        os.kill(pid, signal.SIGTERM)
        os.waitpid(pid, 0)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ref', help='Committed source to benchmark instead of working tree')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='sora-input-bench-') as temp:
        temp = Path(temp)
        source = ROOT
        files = ['Sora/Completion/StickyPromptBarModel.swift', 'Sora/Completion/PathCompleter.swift',
                 'Sora/Resources/zsh/highlight.zsh', 'Sora/Resources/zsh/prompt-line.zsh']
        if args.ref:
            source = temp / 'source'
            for name in files:
                target = source / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(subprocess.check_output(['git', 'show', f'{args.ref}:{name}'], cwd=ROOT))
        executable = temp / 'bench'
        subprocess.run(['swiftc', '-O', str(source/files[0]), str(source/files[1]),
                        str(ROOT/'Scripts/Performance/main.swift'), '-o', str(executable)], check=True)
        subprocess.run([str(executable), str(temp/'files')], check=True)
        print('shell-pty:', json.dumps(shell_latency(source)), flush=True)


if __name__ == '__main__':
    main()
