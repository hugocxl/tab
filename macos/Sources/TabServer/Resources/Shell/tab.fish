# Older fish versions permit return only inside a function.
function __tab_setup
    status is-interactive; or return
    if test "$TAB_SHELL_INTEGRATION" != 1; or set -q __tab_installed
        return
    end
    set -g __tab_installed 1

    function __tab_directory --on-event fish_prompt
        printf '\e]7;file://%s\a' (string escape --style=url -- $PWD | string replace -a '%2F' '/')
    end

    # Fish 4 emits its own prompt marks. Do not wrap or duplicate them.
    if status test-feature mark-prompt 2>/dev/null
        return
    end

    function __tab_preexec --on-event fish_preexec
        printf '\e]133;C\a'
    end

    function __tab_postexec --on-event fish_postexec
        set -l result $status
        printf '\e]133;D;%d\a' $result
    end

    function __tab_status
        return $argv[1]
    end

    # Wrap after the user's configuration has defined fish_prompt.
    function __tab_install --on-event fish_prompt
        functions --copy fish_prompt __tab_user_prompt
        function fish_prompt
            set -l result $status
            printf '\e]133;A\a'
            __tab_status $result
            __tab_user_prompt
            printf '\e]133;B\a'
        end
        functions --erase __tab_install
    end
end

__tab_setup
functions --erase __tab_setup
