# Original Sora highlighter. Colors the ZLE buffer with region_highlight.
# Not derived from zsh-syntax-highlighting. Skips install if that plugin is present.

# Cmd+V and completion accept insert through ghostty_surface_text, which zsh
# treats as a paste. The default paste:standout style paints spaces as opaque
# blocks in Ghostty; keep paste regions unstyled and let this highlighter run.
zle_highlight=(${zle_highlight:#paste:*} paste:none)

_sora_is_space() {
  [[ $1 == ' ' || $1 == $'\t' || $1 == $'\n' ]]
}

_sora_command_exists() {
  emulate -L zsh
  local w=$1 kind
  [[ -n $w ]] || return 1
  kind=$(whence -w -- "$w")
  kind=${kind##*: }
  [[ $kind != none && -n $kind ]]
}

_sora_highlight_apply() {
  emulate -L zsh
  setopt noksharrays
  region_highlight=()
  local buf=$BUFFER
  local -i len=${#buf} i=1 cmdpos=1 start end
  local ch word style quote

  while (( i <= len )); do
    ch=$buf[i]

    if _sora_is_space "$ch"; then
      (( i++ ))
      continue
    fi

    if [[ $ch == '|' ]]; then
      if [[ $buf[i+1] == '|' ]]; then
        region_highlight+=("$((i-1)) $((i+1)) fg=yellow")
        (( i += 2 ))
      else
        region_highlight+=("$((i-1)) $i fg=yellow")
        (( i++ ))
      fi
      cmdpos=1
      continue
    fi

    if [[ $ch == '&' ]]; then
      if [[ $buf[i+1] == '&' ]]; then
        region_highlight+=("$((i-1)) $((i+1)) fg=yellow")
        (( i += 2 ))
      else
        region_highlight+=("$((i-1)) $i fg=yellow")
        (( i++ ))
      fi
      cmdpos=1
      continue
    fi

    if [[ $ch == ';' ]]; then
      region_highlight+=("$((i-1)) $i fg=yellow")
      (( i++ ))
      cmdpos=1
      continue
    fi

    if [[ $ch == '<' || $ch == '>' ]]; then
      local -i opend=i
      (( i++ ))
      if [[ $buf[i] == $ch ]]; then
        (( i++ ))
      fi
      if [[ $buf[i] == '&' ]]; then
        (( i++ ))
      fi
      region_highlight+=("$((opend-1)) $((i-1)) fg=yellow")
      continue
    fi

    start=$i
    quote=
    while (( i <= len )); do
      ch=$buf[i]
      if [[ -n $quote ]]; then
        if [[ $quote == '"' && $ch == '\' ]]; then
          (( i += 2 ))
          continue
        fi
        if [[ $ch == $quote ]]; then
          quote=
        fi
        (( i++ ))
        continue
      fi
      if [[ $ch == '\' ]]; then
        (( i += 2 ))
        continue
      fi
      if _sora_is_space "$ch" || [[ $ch == '|' || $ch == '&' || $ch == ';' || $ch == '<' || $ch == '>' ]]; then
        break
      fi
      if [[ $ch == \' || $ch == '"' || $ch == '`' ]]; then
        quote=$ch
      fi
      (( i++ ))
    done
    end=$i
    (( end > start )) || continue
    word=$buf[start,end-1]

    if (( cmdpos )); then
      if _sora_command_exists "$word"; then
        style='fg=green'
      else
        style='fg=red'
      fi
      cmdpos=0
      case $word in
        sudo|doas|command|builtin|time|nice|nohup|then|else|elif|do) cmdpos=1 ;;
      esac
    elif [[ $word == \'* || $word == \"* || $word == \`* ]]; then
      style='fg=yellow'
    elif [[ $word == -* ]]; then
      style='fg=magenta'
    elif [[ $word == /* || $word == ~* || $word == .* || $word == */* || $word == \$* ]]; then
      style='fg=cyan'
    else
      style='fg=blue'
    fi
    region_highlight+=("$((start-1)) $((end-1)) $style")
  done
}

_sora_highlight_redraw() {
  # This widget owns zle-line-pre-redraw, so report the edit buffer here too;
  # installing a second widget for the same hook would replace this one.
  (( $+functions[_sora_report_line] )) && _sora_report_line
  _sora_highlight_apply
}

_sora_highlight_install() {
  emulate -L zsh
  if (( $+functions[_zsh_highlight] )); then
    # Another highlighter owns the widget; keep line reporting alive on its own.
    (( $+functions[_sora_report_line_install] )) && _sora_report_line_install
    precmd_functions=(${precmd_functions:#_sora_highlight_install})
    return
  fi
  zle -N zle-line-pre-redraw _sora_highlight_redraw
  precmd_functions=(${precmd_functions:#_sora_highlight_install})
}

typeset -ag precmd_functions
precmd_functions+=(_sora_highlight_install)
