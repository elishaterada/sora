Sora shell integration

Copy this entire folder to your server. From an interactive shell in the copied
folder, run one of:
  source ./sora.bash
  source ./sora.zsh

This enables command boundaries, block navigation/search and explicit remote
folder display. Bash keeps Readline input and completion in the terminal grid.
zsh can mirror its editable input in Sora's footer. Remote Tab completion always
stays in the remote shell. Local filesystem suggestions and Agent execution are
unavailable in a remote tab. Remote output remains in that tab's saved terminal
history; it is not mixed into the local command-recall database.

Setup applies only to this shell. For future connections, add a source line
with the folder's absolute path to your .bashrc or .zshrc after your theme setup.
Sora never edits startup files or SSH configuration automatically. Start a fresh
shell to undo session-only setup; remove a source line you added to undo it
permanently. A nested shell needs its own source line.

When the server has no xterm-ghostty terminfo, connect from your local shell with:
  TERM=xterm-256color ssh your-host

Use normal SSH authentication. This folder contains no credentials. No Sora or
Ghostty executable, account, daemon, or network service is required on the host.
Use a UTF-8 locale in the remote shell before it starts to enter Unicode paths.
Sora preserves the host's locale settings. In Bash, commands excluded by your
history settings are not added to Sora's command-recall index.
For a Bash login shell, source sora.bash in its interactive startup file to
replay saved output at launch. Editable draft restoration requires Sora's zsh
integration; remote drafts are never replayed into a local shell.

Existing terminal multiplexers may intercept shell escape sequences; if rich
features are unavailable, ordinary terminal input remains usable. Relaunching
Sora starts fresh local shells with saved output, never an automatic SSH login.

Third-party source and licenses

The ghostty/ directory contains unmodified scripts from ghostty-org/ghostty,
commit c81f0b26871c7fbbe2fc35549fdad1f64ed29094:
https://github.com/ghostty-org/ghostty/tree/c81f0b26871c7fbbe2fc35549fdad1f64ed29094/src/shell-integration
The zsh and Bash integration scripts are GPLv3-or-later; their original notices
are preserved and COPYING-GPL-3.0.txt accompanies this source distribution.
Ghostty's bash-preexec.sh is version 0.7.0, MIT licensed, copyright 2017 Ryan
Caloras and contributors. Its full notice is in bash-preexec-LICENSE.txt:
https://github.com/rcaloras/bash-preexec/tree/0.7.0
Sora's adapter scripts are separate from those unmodified third-party sources.
