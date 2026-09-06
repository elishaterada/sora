# After each command, print a muted full-width rule and the elapsed time so
# command+output blocks are easy to scan (Warp-style separators, Sora-owned).
# Sourced from zshenv after Ghostty's shell integration.

builtin zmodload zsh/datetime 2>/dev/null || return 0

typeset -gF _sora_block_start=0
typeset -gi _sora_block_armed=0

_sora_format_duration() {
  # $1 = elapsed seconds (float). Prints a compact human label.
  builtin emulate -L zsh
  local -F elapsed=$1
  if (( elapsed < 0 )); then
    elapsed=0
  fi
  if (( elapsed < 0.001 )); then
    builtin print -rn -- "<1ms"
  elif (( elapsed < 1 )); then
    builtin printf '%dms' $(( elapsed * 1000 + 0.5 ))
  elif (( elapsed < 10 )); then
    builtin printf '%.2fs' elapsed
  elif (( elapsed < 60 )); then
    builtin printf '%.1fs' elapsed
  else
    local -i mins=$(( elapsed / 60 ))
    local -F secs=$(( elapsed - mins * 60 ))
    builtin printf '%dm%02.0fs' mins secs
  fi
}

# Full-width rule closing a block, with a right-aligned label. `$2` is an
# optional prompt color for the label; the rule itself is always muted.
_sora_block_rule() {
  builtin emulate -L zsh
  local suffix=$1 color=$2

  local cols=${COLUMNS:-0}
  (( cols > 0 )) || cols=80
  # Visible width of the suffix (ASCII-only labels).
  local -i fill=$(( cols - ${#suffix} ))
  (( fill < 4 )) && fill=4

  local rule
  builtin printf -v rule '%*s' "$fill" ''
  rule=${rule// /─}

  if [[ -n $color ]]; then
    builtin print -P -- "%F{240}${rule}%f%F{${color}}${suffix}%f"
  else
    builtin print -P -- "%F{240}${rule}${suffix}%f"
  fi
}

_sora_block_preexec() {
  builtin emulate -L zsh
  _sora_block_start=$EPOCHREALTIME
  _sora_block_armed=1
}

_sora_block_precmd() {
  # Capture exit status before any other work.
  local -i _sora_exit=$?
  builtin emulate -L zsh

  if (( _sora_block_agent )); then
    _sora_block_agent=0
    _sora_block_armed=0
    _sora_block_rule ' (agent)' '#19f9d8'
    return 0
  fi

  (( _sora_block_armed )) || return 0
  _sora_block_armed=0

  local -F elapsed=$(( EPOCHREALTIME - _sora_block_start ))
  _sora_block_start=0

  local dur
  dur="$(_sora_format_duration $elapsed)"

  if (( _sora_exit != 0 )); then
    _sora_block_rule " (${dur} · exit ${_sora_exit})" "#ff2c6d"
  else
    _sora_block_rule " (${dur})"
  fi
}

# ASCII RS (0x1E). Sora delivers this as Ctrl+6 via ghostty_surface_key —
# Ghostty's ctrlSeq maps that to RS. Bare codepoints and ghostty_surface_text
# (paste) both fail: the former writes nothing, the latter inserts into BUFFER
# without running widgets (a private-use glyph used to appear as a diamond).
typeset -g _SORA_AGENT_HANDOFF_KEY=$'\x1e'

# Close the block for a line that went to the agent. Without this the terminal
# shows the abandoned line with no rule, so scrollback gives no hint where one
# entry ended and the next began.
#
# The rule is printed from precmd rather than here: output from inside a widget
# leaves ZLE's row bookkeeping one line off, and its redraw then erases the rule
# it just printed. `send-break` discards the line, leaves it on screen, and
# starts a fresh prompt cycle, which is the path that already draws every other
# block.
typeset -gi _sora_block_agent=0

_sora_agent_handoff() {
  builtin emulate -L zsh
  _sora_block_agent=1
  zle send-break
}

typeset -ag preexec_functions precmd_functions
preexec_functions+=(_sora_block_preexec)
precmd_functions+=(_sora_block_precmd)

if [[ -o interactive ]]; then
  zle -N _sora_agent_handoff
  bindkey -- "$_SORA_AGENT_HANDOFF_KEY" _sora_agent_handoff
fi
