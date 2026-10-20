#!/bin/zsh

# Keep ticket validation mandatory. The caller decides whether to staple or
# validate an app/DMG; neither operation may be treated as successful on error.
macpilot_stapler() {
    local stapler_output stapler_exit stapler_delay
    local -a stapler_delays=(10 30 60 120 180)
    local -i stapler_attempt=0

    # Observed CloudKit connection losses last minutes, not seconds, and one
    # architecture staples cleanly while the other keeps failing within the same
    # run. Outlasting the outage beats burning a release tag on it.
    while true; do
        (( stapler_attempt += 1 ))
        if stapler_output="$(xcrun stapler "$@" 2>&1)"; then
            print -r -- "$stapler_output"
            return 0
        else
            stapler_exit=$?
        fi
        print -r -- "$stapler_output" >&2

        # Error 68 has other causes. Only the observed CloudKit connection
        # loss is transient; ticket/signature failures remain fatal.
        if (( stapler_exit != 68 )) ||
            (( stapler_attempt > ${#stapler_delays} )) ||
            [[ ! "$stapler_output" =~ 'NSURLErrorDomain[[:space:]]+Code=-1005([^0-9]|$)' ]]; then
            return "$stapler_exit"
        fi
        stapler_delay=$stapler_delays[$stapler_attempt]
        print -r -- "Apple ticket connection lost; retrying stapler in ${stapler_delay}s (${stapler_attempt}/$(( ${#stapler_delays} + 1 )))." >&2
        sleep "$stapler_delay"
    done
}
