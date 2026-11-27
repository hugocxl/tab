[[ -o interactive && ${TAB_SHELL_INTEGRATION-} == 1 ]] || return
(( ${+_tab_installed} )) && return
typeset -g _tab_installed=1 _tab_running=0 _tab_prompt='' _tab_user_prompt=''

_tab_directory() {
    emulate -L zsh
    local LC_ALL=C encoded='' char hex
    local -i i
    for (( i=1; i<=${#PWD}; i++ )); do
        char=$PWD[i]
        if [[ $char == [a-zA-Z0-9/._~-] ]]; then
            encoded+=$char
        else
            printf -v hex '%%%02X' "'$char"
            encoded+=$hex
        fi
    done
    printf '\e]7;file://%s\a' "$encoded"
}

_tab_precmd() {
    local result=$?
    if (( _tab_running )); then
        printf '\e]133;D;%d\a' "$result"
    fi
    _tab_running=0
    _tab_directory
    [[ $PS1 != $_tab_prompt ]] && _tab_user_prompt=$PS1
    _tab_prompt=$'%{\e]133;A\a%}'"$_tab_user_prompt"$'%{\e]133;B\a%}'
    PS1=$_tab_prompt
    return "$result"
}

_tab_preexec() {
    _tab_running=1
    printf '\e]133;C\a'
}

_tab_unbound_alt() { return 0 }

# Defer until user startup files and prompt frameworks have loaded.
_tab_install() {
    local result=$?
    precmd_functions=(${precmd_functions:#_tab_install} _tab_precmd)
    preexec_functions+=(_tab_preexec)
    # Consume complete unbound Alt arrows so ZLE cannot insert a CSI suffix.
    # Keep bindings installed by the user's startup files and prompt framework.
    zle -N _tab_unbound_alt
    local keymap sequence binding
    for keymap in emacs viins vicmd; do
        for sequence in $'\e[1;3A' $'\e[1;3B'; do
            binding=$(bindkey -M "$keymap" "$sequence")
            if [[ ${binding##* } == undefined-key ]]; then
                bindkey -M "$keymap" "$sequence" _tab_unbound_alt
            fi
        done
    done
    _tab_precmd
    return "$result"
}
precmd_functions+=(_tab_install)
