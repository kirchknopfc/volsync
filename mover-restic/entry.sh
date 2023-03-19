#! /bin/bash
# sleep forever
# sleep 9999999999

#echo "Starting container"

set -e -o pipefail

echo "VolSync restic container version: 0.15.1"
echo  "$@"

declare -a RESTIC
RESTIC=("restic")
if [[ -n "${CUSTOM_CA}" ]]; then
    echo "Using custom CA."
    RESTIC+=(--cacert "${CUSTOM_CA}")
fi

"${RESTIC[@]}" version
# Force the associated backup host name to be "sicherungsoperator"
if [[ -z "${RESTIC_HOST}" ]]; then
    RESTIC_HOST="sicherungsoperator"
fi
echo "Using host ${RESTIC_HOST} "

# Make restic output progress reports every 10s
#export RESTIC_PROGRESS_FPS=0.02
# 0.2 =  5  sec
# 0.1 =  10 sec
# 0.05 = 20 sec

# Print an error message and exit
# error rc "message"
function error {
    echo "ERROR: $2"
    exit "$1"
}

# Error and exit if a variable isn't defined
# check_var_defined "MY_VAR"
function check_var_defined {
    if [[ -z ${!1} ]]; then
        error 1 "$1 must be defined"
    fi
}

function check_contents {
    echo "== Checking directory for content ==="
    DIR_CONTENTS="$(ls -A "${DATA_DIR}")"
    if [ -z "${DIR_CONTENTS}" ]; then
        echo "== Directory is empty skipping backup ==="
        exit 0
    fi
}

# Ensure the repo has been initialized
function ensure_initialized {
    echo "== Initialize Dir ======="
    # Try a restic command and capture the rc & output
    outfile=$(mktemp -q)
    if ! "${RESTIC[@]}" snapshots 2>"$outfile"; then
        output=$(<"$outfile")
        # Match against error string for uninitialized repo
        if [[ $output =~ .*(Is there a repository at the following location).* ]]; then
            "${RESTIC[@]}" init
        else
            cat "$outfile"
            error 3 "failure checking existence of repository"
        fi
    fi
    rm -f "$outfile"
}

function do_backup {
    echo "=== Starting backup ==="
    pushd "${DATA_DIR}"
    # set tag
    TAG=""
    if [[ -n "${RESTIC_TAG}" ]]; then
        echo "Using TAG: ${RESTIC_TAG}."
        TAG="--tag ${RESTIC_TAG}"
    fi
    "${RESTIC[@]}" backup ${TAG} --ignore-inode --exclude=".snapshot/**"  --host "${RESTIC_HOST}" .
    popd
}

function do_forget {
    
    if [[ -n ${FORGET_OPTIONS} ]]; then
        echo "=== Starting forget ==="
        #shellcheck disable=SC2086
        "${RESTIC[@]}" forget --host "${RESTIC_HOST}" ${FORGET_OPTIONS}
    fi
}

function do_prune {
    echo "=== Starting prune ==="
    "${RESTIC[@]}" prune
}

#######################################
# Trims the provided timestamp and
# returns one in the format: YYYY-MM-DD hh:mm:ss
# Globals:
#   None
# Arguments
#   Timestamp in format YYYY-MM-DD HH:mm:ss.ns
#######################################
function trim_timestamp() {
    local trimmed_timestamp
    trimmed_timestamp=$(cut -d'.' -f1 <<<"$1")
    echo "${trimmed_timestamp}"
}

#######################################
# Provides the UNIX Epoch for the given timestamp
# Globals:
#   None
# Arguments:
#   timestamp
#######################################
function get_epoch_from_timestamp() {
    local timestamp="$1"
    local date_as_epoch
    date_as_epoch=$(date --date="${timestamp}" +%s)
    echo "${date_as_epoch}"
}


#######################################
# Reverses the elements within an array,
# inspired by: https://unix.stackexchange.com/a/412870
# Globals:
#   None
# Arguments:
#   Name of array
#######################################
function reverse_array() {
    local -n _arr=$1

    # set indices
    local -i left=0
    local -i right=$((${#_arr[@]} - 1))

    while ((left < right)); do
        # triangle swap
        local -i temp="${_arr[$left]}"
        _arr[$left]="${_arr[$right]}"
        _arr[$right]="$temp"

        # increment indices
        ((left++))
        ((right--))
    done
}

################################################################
# Selects the first restic snapshot available for the 
# given constraints. If RESTORE_AS_OF is defined, then 
# only snapshots that were created prior to it are considered.
# If SELECT_PREVIOUS is defined, then the n-th snapshot 
# is selected under the matching criteria. 
# If a snapshot satisfying the conditions is found, then its ID 
# is returned.
# 
# Globals:
#   SELECT_PREVIOUS
#   RESTORE_AS_OF
# Arguments:
#   None
################################################################
function select_restic_snapshot_to_restore() {
    # list of epochs
    declare -a epochs
    # create an associative array that maps numeric epoch to the restic snapshot IDs
    declare -A epochs_to_snapshots

    # declare vars to be used in the loop
    local snapshot_id
    local snapshot_ts
    local trimmed_timestamp
    local snapshot_epoch 

    # go through the timestamps received from restic
    IFS=$'\n'
    for line in $("${RESTIC[@]}" -r "${RESTIC_REPOSITORY}" snapshots | grep /data | awk '{print $1 "\t" $2 " " $3}'); do
        # extract the proper variables
        snapshot_id=$(echo -e "${line}" | cut -d$'\t' -f1)
        snapshot_ts=$(echo -e "${line}" | cut -d$'\t' -f2)
        trimmed_timestamp=$(trim_timestamp "${snapshot_ts}")
        snapshot_epoch=$(get_epoch_from_timestamp "${trimmed_timestamp}")
        epochs+=("${snapshot_epoch}")
        epochs_to_snapshots[${snapshot_epoch}]="${snapshot_id}"
    done

    # reverse sorted epochs so the most recent epoch is first 
    reverse_array epochs

    local -i offset=0
    local target_epoch
    if [[ -n ${RESTORE_AS_OF} ]]; then
        # move to the position of the satisfying epoch
        target_epoch=$(get_epoch_from_timestamp "${RESTORE_AS_OF}")
        while ((offset < ${#epochs[@]})); do 
            if ((${epochs[${offset}]} <= target_epoch)); then
                break
            fi
            ((offset++))
        done
    fi

    # offset the epoch selection if SELECT_PREVIOUS is defined
    local -i select_offset=${SELECT_PREVIOUS-0}
    ((offset+=select_offset))

    # if there is a snapshot matching the provided parameters
    if (( offset < ${#epochs[@]} )); then
        local selected_epoch=${epochs[${offset}]}
        local selected_id=${epochs_to_snapshots[${selected_epoch}]}
        echo "${selected_id}"
    fi
}


#######################################
# Restores from a selected snapshot if 
# RESTORE_AS_OF is provided, otherwise
# restores from the latest restic snapshot
# Globals:
#   RESTORE_AS_OF
#   DATA_DIR
#   RESTIC_HOST
# Arguments:
#   None
#######################################
function do_restore {
    echo "=== Starting restore ==="
    # restore from specific snapshot specified by timestamp, or latest
    local snapshot_id
    snapshot_id=$(select_restic_snapshot_to_restore)
    if [[ -z ${snapshot_id} ]]; then 
        echo "No eligible snapshots found"
    else
    pushd "${DATA_DIR}"
        echo "Selected restic snapshot with id: ${snapshot_id}"
        "${RESTIC[@]}" restore -t . --host "${RESTIC_HOST}" "${snapshot_id}"
        popd
    fi
}

echo "Testing mandatory env variables"
# Check the mandatory env variables
for var in PRIVILEGED_MOVER \
           RESTIC_CACHE_DIR \
           RESTIC_PASSWORD \
           RESTIC_REPOSITORY \
           DATA_DIR \
           ; do
    check_var_defined $var
done
START_TIME=$SECONDS
for op in "$@"; do
    case $op in
        "backup")
            check_contents
            ensure_initialized
            do_backup
            do_forget
            ;;
        "prune")
            do_prune
            ;;
        "restore")
            do_restore
            ;;
        *)
            error 2 "unknown operation: $op"
            ;;
    esac
done
echo "Restic completed in $(( SECONDS - START_TIME ))s"
sync
echo "=== Done ==="
# sleep forever so that the containers logs can be inspected
# sleep 9999999
