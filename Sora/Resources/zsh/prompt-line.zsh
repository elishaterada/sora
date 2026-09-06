# Mirrors the live ZLE edit buffer to Sora so terminal → agent routing reads the
# real line instead of inferring it from keystrokes or the rendered grid.
# Screen scraping cannot work here: PS1 is empty, so nothing on screen marks
# where the prompt begins. Sora consumes this title and never displays it.

_sora_report_line() {
  emulate -L zsh
  local buf=$BUFFER
  buf=${buf//$'\n'/ }
  buf=${buf//$'\r'/ }
  buf=${buf//$'\e'/}
  buf=${buf//$'\a'/}
  (( ${#buf} > 2048 )) && buf=${buf[1,2048]}
  builtin printf '\e]2;%s%s\a' "$_SORA_LINE_SENTINEL" "$buf"
}

typeset -g _SORA_LINE_SENTINEL=$'\u2400sora-line\u2400'

_sora_report_line_install() {
  emulate -L zsh
  autoload -Uz add-zle-hook-widget 2>/dev/null
  if (( $+functions[add-zle-hook-widget] )); then
    add-zle-hook-widget line-pre-redraw _sora_report_line 2>/dev/null
  fi
}
