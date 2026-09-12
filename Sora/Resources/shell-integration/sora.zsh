# Optional manual setup for a nested or remote interactive zsh. Source after
# startup/theme configuration. No startup file is written by this script.
[[ -o interactive ]] || return 0
(( $+functions[_sora_report_context] )) && { _sora_report_context; return 0; }
_sora_root=${${(%):-%x}:A:h}
_sora_ghostty=${GHOSTTY_RESOURCES_DIR:+${GHOSTTY_RESOURCES_DIR}/shell-integration}
[[ -r $_sora_root/ghostty/zsh/ghostty-integration ]] && _sora_ghostty=$_sora_root/ghostty
if [[ ! -r $_sora_ghostty/zsh/ghostty-integration ]]; then
  builtin print -u2 -r -- 'Sora: Ghostty shell integration was not found. zsh remains available.'
  unset _sora_root _sora_ghostty
  return 1
fi
if (( ! $+functions[_ghostty_precmd] )); then
  builtin source "$_sora_ghostty/zsh/ghostty-integration"
fi
builtin source "$_sora_root/zsh/prompt-line.zsh"
builtin source "$_sora_root/zsh/highlight.zsh"
builtin source "$_sora_root/zsh/command-blocks.zsh"
# Sourcing after startup must install the redraw hook explicitly.
_sora_report_line_install
_sora_report_context
unset _sora_root _sora_ghostty
