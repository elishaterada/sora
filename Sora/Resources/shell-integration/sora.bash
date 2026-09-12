# Sora's optional Bash adapter. Source after your interactive startup files.
# Command boundaries come from the bundled, unmodified Ghostty integration.
# This adapter adds explicit local/remote context and lossless command titles.
[[ $- == *i* ]] || return 0
[[ ${_SORA_BASH_LOADED_PID:-} == $$ ]] && return 0

# Archives are display data, never shell input. Bash users who source this
# adapter in their startup file can restore saved output before the first prompt.
if [[ -n ${SORA_RESTORE_HISTORY:-} && -r $SORA_RESTORE_HISTORY ]]; then
  /bin/cat -- "$SORA_RESTORE_HISTORY"
  builtin printf '\n── Previous session ended · New shell ──\n'
fi
unset SORA_RESTORE_HISTORY

_sora_root=$(builtin cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && builtin pwd)
_sora_ghostty=${GHOSTTY_RESOURCES_DIR:+${GHOSTTY_RESOURCES_DIR}/shell-integration}
[[ -r $_sora_root/ghostty/bash/ghostty.bash ]] && _sora_ghostty=$_sora_root/ghostty
if [[ ! -r $_sora_ghostty/bash/ghostty.bash ]]; then
  builtin printf 'Sora: Ghostty shell integration was not found. Bash remains available.\n' >&2
  unset _sora_root _sora_ghostty
  return 1
fi
# Avoid loading a second copy when libghostty injected Bash automatically.
if ! builtin declare -F __ghostty_precmd >/dev/null; then
  builtin source "$_sora_ghostty/bash/ghostty.bash"
fi
_SORA_BASH_LOADED_PID=$$
unset _sora_root _sora_ghostty

# ASCII-only transport, including UTF-8 bytes. Chunk boundaries cannot split a
# terminal UTF-8 sequence. Decoding is data-only in the native application.
_sora_bash_encode() {
  local LC_ALL=C value=$1 char hex number i
  _sora_encoded=
  for ((i=0; i<${#value}; i++)); do
    char=${value:i:1}
    case "$char" in
      [a-zA-Z0-9/._~\ -]) _sora_encoded=$_sora_encoded$char ;;
      *) builtin printf -v number '%d' "'$char"; builtin printf -v hex '%02X' "$((number & 255))"; _sora_encoded=$_sora_encoded%$hex ;;
    esac
  done
}
_sora_bash_title() {
  local LC_ALL=C payload=$1 start index total
  total=$(( (${#payload} + 79) / 80 ))
  for ((start=0,index=0; index<total; start+=80,index++)); do
    builtin printf '\e]2;sora-chunk;%d;%d;%s\a' "$index" "$total" "${payload:start:80}"
  done
}
_sora_bash_context() {
  local status=$? location=local host path
  _sora_bash_exit=$status
  _sora_bash_last_entry=$(HISTTIMEFORMAT= builtin history 1)
  [[ -n ${SSH_CONNECTION:-}${SSH_TTY:-} ]] && location=remote
  _sora_bash_encode "${HOSTNAME:-localhost}"; host=$_sora_encoded
  _sora_bash_encode "$PWD"; path=$_sora_encoded
  _sora_bash_title "sora-context;1;bash;$location;$host;$path"
  return "$status"
}
_sora_bash_command() {
  local status=$? command=${1:-} entry
  entry=$(HISTTIMEFORMAT= builtin history 1)
  # HISTCONTROL/HISTIGNORE and disabled history can leave the old command in
  # the history slot. Never label it as the command that just ran.
  if [[ ! -o history || $entry == "${_sora_bash_last_entry:-}" ]]; then
    command=
  elif [[ -z $command && $entry =~ ^[[:space:]]*[0-9]+[[:space:]][[:space:]] ]]; then
    command=${entry:${#BASH_REMATCH[0]}}
  fi
  _sora_bash_encode "$command"
  _sora_bash_title "sora-command;1;$_sora_encoded"
  return "$status"
}

if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
  # PS0 runs after Readline accepts a whole command. Do not install a DEBUG
  # trap or replace the user's existing PS0/PROMPT_COMMAND.
  # The pinned Ghostty hook captures status in a local declaration before
  # calling __ghostty_precmd, which loses failures on modern Bash. Call the
  # same public hook with the captured status restored, without editing it.
  _sora_bash_return_status() { return "$1"; }
  _sora_bash_prompt() {
    _sora_bash_return_status "${_sora_bash_exit:-0}"
    __ghostty_precmd
  }
  _sora_original_hook='__ghostty_hook 2>/dev/null'
  if [[ $(builtin declare -p PROMPT_COMMAND 2>/dev/null) == 'declare -a '* ]]; then
    for _sora_i in "${!PROMPT_COMMAND[@]}"; do
      PROMPT_COMMAND[$_sora_i]=${PROMPT_COMMAND[$_sora_i]//"$_sora_original_hook"/_sora_bash_prompt}
    done
  else
    PROMPT_COMMAND=${PROMPT_COMMAND//"$_sora_original_hook"/_sora_bash_prompt}
  fi
  unset _sora_original_hook _sora_i
  [[ $PS0 == *'__ghostty_preexec_hook'* ]] || PS0+='$( __ghostty_preexec_hook >/dev/tty )'
  PS0+='$( _sora_bash_command )'
  if [[ $(builtin declare -p PROMPT_COMMAND 2>/dev/null) == 'declare -a '* ]]; then
    PROMPT_COMMAND=(_sora_bash_context "${PROMPT_COMMAND[@]}")
  else
    PROMPT_COMMAND="_sora_bash_context${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
  fi
else
  # Older Bash uses Ghostty's existing bash-preexec hook arrays.
  preexec_functions+=(_sora_bash_command)
  precmd_functions=(_sora_bash_context "${precmd_functions[@]}")
fi
_sora_bash_context
