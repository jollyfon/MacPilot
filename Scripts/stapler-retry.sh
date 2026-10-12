#!/bin/zsh

# Keep ticket validation mandatory. The caller decides whether to staple or
# validate an app/DMG; neither operation may be treated as successful on error.
macpilot_stapler() {
    local stapler_output stapler_exit stapler_attempt stapler_delay
    for stapler_attempt in 1 2 3; do
        if stapler_output="$(xcrun stapler "$@" 2>&1)"; then
            print -r -- "$stapler_output"
            return 0
        else
            stapler_exit=$?
        fi
        print -r -- "$stapler_output" >&2

        # Error 68 has other causes. Only the observed CloudKit connection
        # loss is transient; ticket/signature failures remain fatal.
        if (( stapler_exit != 68 || stapler_attempt == 3 )) ||
            [[ ! "$stapler_output" =~ 'NSURLErrorDomain[[:space:]]+Code=-1005([^0-9]|$)' ]]; then
            return "$stapler_exit"
        fi
        if (( stapler_attempt == 1 )); then
            stapler_delay=10
        else
            stapler_delay=30
        fi
        print -r -- "Apple ticket connection lost; retrying stapler in ${stapler_delay}s (${stapler_attempt}/3)." >&2
        sleep "$stapler_delay"
    done
}
