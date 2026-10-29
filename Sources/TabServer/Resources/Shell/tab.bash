# Source explicitly from your interactive Bash startup file. Bash startup is not redirected.
[[ $- == *i* && ${TAB_SHELL_INTEGRATION-} == 1 ]] || return
[[ ${_tab_installed-} == 1 ]] && return
_tab_installed=1
_tab_running=0
_tab_in_prompt=0
_tab_debug_checked=0
_tab_prompt=''
_tab_user_prompt=''

_tab_directory() {
    local LC_ALL=C encoded='' char hex i
    for (( i=0; i<${#PWD}; i++ )); do
        char=${PWD:i:1}
        case $char in
            [a-zA-Z0-9/._~-]) encoded+=$char ;;
            *) printf -v hex '%%%02X' "'$char"; encoded+=$hex ;;
        esac
    done
    printf '\e]7;file://%s\a' "$encoded"
}

_tab_precmd() {
    local result=$?
    if (( _tab_running )); then
        printf '\e]133;D;%d\a' "$result"
    fi
    _tab_running=0
    _tab_in_prompt=1
    _tab_status=$result
    return "$result"
}

_tab_prompt_end() {
    _tab_directory
    [[ $PS1 != "$_tab_prompt" ]] && _tab_user_prompt=$PS1
    _tab_prompt=$'\[\e]133;A\a\]'"$_tab_user_prompt"$'\[\e]133;B\a\]'
    PS1=$_tab_prompt
    _tab_in_prompt=0
    return "$_tab_status"
}

_tab_prompt_status() {
    return "$_tab_status"
}

# Bash 5 hides the caller's DEBUG trap while sourcing. Inspect it afterward,
# directly in PROMPT_COMMAND, without replacing a user's trap.
read -r -d '' _tab_debug_setup <<'TAB_DEBUG_SETUP' || :
if [[ ${_tab_debug_checked-0} == 0 ]]; then
    _tab_debug_checked=1
    if [[ -z $(trap -p DEBUG) ]]; then
        trap 'if [[ $_tab_running == 0 && $_tab_in_prompt == 0 && $BASH_COMMAND != _tab_* && $BASH_COMMAND != "$PROMPT_COMMAND" ]]; then _tab_running=1; printf "\e]133;C\a"; fi' DEBUG
    fi
fi
_tab_prompt_status
TAB_DEBUG_SETUP
if (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1) )); then
    PROMPT_COMMAND=(_tab_precmd "$_tab_debug_setup" "${PROMPT_COMMAND[@]}" _tab_prompt_end)
else
    PROMPT_COMMAND=$'_tab_precmd\n'"$_tab_debug_setup"$'\n'"${PROMPT_COMMAND-}"$'\n_tab_prompt_end'
fi

_tab_bind_keys() {
    local keymap sequence bindings
    for keymap in emacs-standard vi-insert vi-command; do
        bindings=$(bind -m "$keymap" -p; bind -m "$keymap" -s)
        for sequence in '\e[1;3A' '\e[1;3B'; do
            if [[ $bindings != *"\"$sequence\":"* ]]; then
                bind -m "$keymap" "\"$sequence\": \"\""
            fi
        done
    done
}
_tab_bind_keys
unset -f _tab_bind_keys
