# Mirrors the live ZLE edit buffer to Sora so terminal → agent routing reads the
# real line instead of inferring it from keystrokes or the rendered grid.
# Screen scraping cannot work here: PS1 is empty, so nothing on screen marks
# where input begins. Sora consumes this title and never displays it.

_sora_report_line() {
  emulate -L zsh
  local buf=$BUFFER
  buf=${buf//\%/\%25}
  buf=${buf//$'\n'/\%0A}
  buf=${buf//$'\t'/\%09}
  buf=${buf//$'\r'/\%0D}
  buf=${buf//$'\e'/\%1B}
  buf=${buf//$'\a'/\%07}
  local -a words
  words=( ${(z)BUFFER} )
  local known=0
  if (( ${#words} )) && builtin whence -w -- "${(Q)words[1]}" >/dev/null 2>&1; then
    known=1
  fi
  builtin printf '\e]2;%s%d;%d;%s\a' "$_SORA_CURSOR_SENTINEL" "$CURSOR" "$known" "$buf"
}

typeset -g _SORA_CURSOR_SENTINEL=$'\u2400sora-multiline\u2400'
typeset -g _SORA_LINE_SENTINEL=$'\u2400sora-line\u2400'

_sora_report_line_install() {
  emulate -L zsh
  autoload -Uz add-zle-hook-widget 2>/dev/null
  if (( $+functions[add-zle-hook-widget] )); then
    add-zle-hook-widget line-pre-redraw _sora_report_line 2>/dev/null
  fi
}

# Read as data directly into ZLE, never as input to the command parser.
_sora_restore_draft() {
  emulate -L zsh
  if [[ -n "$_SORA_RESTORE_DRAFT" && -r "$_SORA_RESTORE_DRAFT" && -z "$BUFFER" ]]; then
    IFS= read -r -d $'\0' BUFFER < "$_SORA_RESTORE_DRAFT"
    CURSOR=${#BUFFER}
  fi
  unset _SORA_RESTORE_DRAFT
}

_sora_begin_line() {
  _sora_restore_draft
  # A fresh empty ZLE line need not redraw after Control-C. Publish it here
  # so the native input and keyboard routing cannot retain a stale draft.
  _sora_report_line
}

_sora_install_draft_restore() {
  emulate -L zsh
  autoload -Uz add-zle-hook-widget
  add-zle-hook-widget line-init _sora_begin_line
  precmd_functions=(${precmd_functions:#_sora_install_draft_restore})
}
typeset -ag precmd_functions
precmd_functions+=(_sora_install_draft_restore)

# A final ZLE redraw can arrive after Return. Explicitly end prompt mode after
# that redraw so fullscreen clients never inherit shell completion/routing.
_sora_report_command_started() {
  emulate -L zsh
  # Ghostty's ordinary window title strips control characters, including
  # newlines. Preserve the preexec command as encoded data for native history.
  local cmd=$1
  cmd=${cmd//\%/\%25}
  cmd=${cmd//$'\n'/\%0A}
  cmd=${cmd//$'\t'/\%09}
  cmd=${cmd//$'\r'/\%0D}
  cmd=${cmd//$'\e'/\%1B}
  cmd=${cmd//$'\a'/\%07}
  builtin printf '\e]2;%s%s\a' $'\u2400sora-command-started\u2400' "$cmd"
}
typeset -ag preexec_functions
preexec_functions+=(_sora_report_command_started)
