#!/usr/bin/env bash
#
# Created on Fri Sep 23 2022
#
# Copyright (C) 1983-2023 Advantech Co., Ltd.
# Author: Hong.Guo, hong.guo@advantech.com.cn
#

# A script to monitor modem state and auto restore by reset modem
#

# VSCode plugin shellcheck options
# shellcheck disable=SC2182
# shellcheck disable=SC2181
# shellcheck disable=SC2269

set -o pipefail
trap 'main_shell_leave' EXIT

# parse env file
# but prefer to use env variables
parse_env() {
    local env_file="$1"
    if [ -z "$env_file" ] || [ ! -f "$env_file" ]; then
        return 0
    fi
    echo "parse env file: $env_file"
    local key value
    while IFS= read -r line || [ -n "$line" ]; do
        key=$(sed -En 's/^([0-9A-Z_]+)=.*$/\1/p' <<<"$line")
        value=$(sed -En 's/^[0-9A-Z_]+=(.*)$/\1/p' <<<"$line")
        if [ -z "${!key}" ]; then
            eval "$key=$value"
        fi
    done < <(grep -E '^[0-9A-Z_]+=.*$' "$env_file")
}

#  ---------- global variables begin ------------
declare -rg CG_BASE_DATA_DIR="${CG_BASE_DATA_DIR:-/mnt/data/cellular_guard}"
declare -rg STATUS_FILE_PATH="${CG_BASE_DATA_DIR}/status"
declare -rg LOG_FILE_PATH="${CG_BASE_DATA_DIR}/cellular_guard.log"
declare -rg STATE_JSON_PATH="${CG_BASE_DATA_DIR}/state.json"
declare -rg HARD_RESET_REQUIRED_FILE="${CG_BASE_DATA_DIR}/hard_reset_required"
declare -rg LOG_FLUSH_FLAG='^^^^^^FLUSH^^^^^^'

######### environment variables #########
# file path to load env
CG_ENV_FILE=${CG_ENV_FILE:-cellular_guard.env}

parse_env "$CG_ENV_FILE"

# Log to file
PERSISTENT_LOGGING=${PERSISTENT_LOGGING:-y}
# Max log file size, unit KiB
MAX_LOG_SIZE=${MAX_LOG_SIZE:-3072}

# Used for delay time of "main program module" loop
CHECK_INTERVAL=${CHECK_INTERVAL:-1h}

# The interval of ping error is: 60x(4-1)=3 minutes, 600x(4-1)=30 minutes, 600x(4-1)=30 minutes, 3600x(4-1)=3 hours
# Ping gradient interval time
PING_INTERVALS=${PING_INTERVALS:-'60 600 600 3600'}
IFS=" " read -r -a PING_INTERVALS_ARRAY <<<"$PING_INTERVALS"
# Used for Record the number of network check failures in "frequency maintenance module"
MAX_PING_ERROR_COUNT=${MAX_PING_ERROR_COUNT:-'4 4 4 4'}
IFS=" " read -r -a MAX_PING_ERROR_COUNT_ARRAY <<<"$MAX_PING_ERROR_COUNT"

PING_INTERVAL_NORMAL=${PING_INTERVAL_NORMAL:-10m}

# Minimum value of 4G module frequency clearing of "frequency maintenance module"
MAX_FREQUENCY_ERROR_COUNT_MIN=${MAX_FREQUENCY_ERROR_COUNT_MIN:-3}

# Max value of 4G module frequency clearing of "frequency maintenance module"
MAX_FREQUENCY_ERROR_COUNT_MAX=${MAX_FREQUENCY_ERROR_COUNT_MAX:-5}

# Used for trigger 4G module frequency clearing of "SIM card maintenance module"
MAX_SIM_ERROR_COUNT=${MAX_SIM_ERROR_COUNT:-4}

# volatile state.json for export
VOLATILE_STATE_FILE_PATH="${VOLATILE_STATE_FILE_PATH}"

###################################################

# Corrent num of modem manager
MODEM_INDEX=0
# Count of 4G frequency clearing of "frequency maintenance module"
CURRENT_MAX_FREQUENCY_ERROR_COUNT=${MAX_FREQUENCY_ERROR_COUNT_MIN}

declare -Arg NETWORK_STATUS=(
    ["OK"]="ok"
    ["SIM_ERROR10"]="sim_error10"
    ["SIM_ERROR"]="sim_error"
    ["NETWORK_ERROR"]="network_error"
    ["NETWORK_ERROR_NO_IP"]="network_error_no_ip"
    ["NETWORK_ERROR_LOW_SIGNAL"]="network_error_low_signal"
    ["MODEM_BRICKED"]="modem_bricked"
    ["MODEM_UNKNOWN"]="modem_unknown"
    ["MODEM_MANAGER_ERR"]="modem_manager_err"
)

declare -Ag ERROR_COUNTS=(
    ["SIM_ERROR10"]=0
    ["SIM_ERROR"]=0
    ["NETWORK_ERROR"]=0
    ["NETWORK_ERROR_NO_IP"]=0
    ["NETWORK_ERROR_LOW_SIGNAL"]=0
    ["MODEM_MANAGER_ERR"]=0
    ["MODEM_FREQUENCY_CLEAR"]=0
    ["MODEM_FREQUENCY_CLEAR_SUCCESS"]=0
    ["MM_RESTART"]=0
    ["MM_RESTART_SUCCESS"]=0
    ["MODEM_AIRPLANE_MODE_SWITCH"]=0
    ["MODEM_AIRPLANE_MODE_SWITCH_SUCCESS"]=0
    ["MODEM_SOFT_RESET"]=0
    ["MODEM_SOFT_RESET_SUCCESS"]=0
    ["MODEM_HARD_RESET"]=0
    ["MODEM_HARD_RESET_SUCCESS"]=0
    ["MM_NO_INDEX"]=0
)

declare -Ag ERROR_TIMES=(
    ["MM_RESTART_LAST_TIME"]=""
    ["MM_RESTART_LAST_TIME_SUCCESS"]=""
    ["MODEM_AIRPLANE_MODE_SWITCH_LAST_TIME"]=""
    ["MODEM_AIRPLANE_MODE_SWITCH_LAST_TIME_SUCCESS"]=""
    ["MODEM_SOFT_RESET_LAST_TIME"]=""
    ["MODEM_SOFT_RESET_LAST_TIME_SUCCESS"]=""
    ["MODEM_HARD_RESET_LAST_TIME"]=""
    ["MODEM_HARD_RESET_LAST_TIME_SUCCESS"]=""
    ["SIM_ERROR10_LAST_TIME"]=""
    ["SIM_ERROR_LAST_TIME"]=""
    ["NETWORK_ERROR_NO_IP_LAST_TIME"]=""
    ["NETWORK_ERROR_LAST_TIME"]=""
    ["NETWORK_ERROR_LOW_SIGNAL_LAST_TIME"]=""
    ["MODEM_MANAGER_ERR_LAST_TIME"]=""
    ["MODEM_FREQUENCY_CLEAR_LAST_TIME"]=""
    ["MODEM_FREQUENCY_CLEAR_LAST_TIME_SUCCESS"]=""
    ["MM_NO_INDEX_LAST_TIME"]=""
)

# Current cellular network status, initial to ok
CURRENT_STATUS=
# ICCID record
# ICCID will initialed from state.json and obtained by check_sim_ccid
ICCID=
# Version record, get from VERSION file at script beginning
VERSION=
# Tempary global variable
# Use global variable to avoid subshell can't not modify global variable
GLOBAL_VAR=
# Dirty tag of state.json
STATE_DIRTY=false

# To reduce the number of logs with the same content
# Log content of last time
LAST_LOG_CONTENT=
# The most recent time of the same log
LAST_LOG_TIME=
# The number of the same log
LAST_SAME_LOG_COUNT=0
# The max number of the same log
MAX_SUPRESSED_LOGS_NUM=10
# raw at command usb device path
RAW_USB_DEV='/dev/ttyUSB2'

# from script parameters, for debug only
JUMP=
SOURCE_MODE=false
DEBUG=
#  ---------- global variables end ------------

initial_state() {
    if [ -e "$STATUS_FILE_PATH" ]; then
        CURRENT_STATUS="$(cat "$STATUS_FILE_PATH")"
    else
        CURRENT_STATUS="${NETWORK_STATUS["OK"]}"
    fi
    if [ -e "$STATE_JSON_PATH" ]; then
        local state_init_script
        state_init_script="$(jq -r '.ICCID as $iccid | .version as $version | .extra | @sh "
            # extra mm_restart
            ERROR_COUNTS[\"MM_RESTART\"]=\(.mm_restart.count // "0")
            ERROR_COUNTS[\"MM_RESTART_SUCCESS\"]=\(.mm_restart.count_success // "0")
            ERROR_TIMES[\"MM_RESTART_LAST_TIME\"]=\(.mm_restart.last_time // "")
            ERROR_TIMES[\"MM_RESTART_LAST_TIME_SUCCESS\"]=\(.mm_restart.last_time // "")

            # extra modem_airplane_mode_switch
            ERROR_COUNTS[\"MODEM_AIRPLANE_MODE_SWITCH\"]=\(.modem_airplane_mode_switch.count // "0")
            ERROR_COUNTS[\"MODEM_AIRPLANE_MODE_SWITCH_SUCCESS\"]=\(.modem_airplane_mode_switch.count_success // "0")
            ERROR_TIMES[\"MODEM_AIRPLANE_MODE_SWITCH_LAST_TIME\"]=\(.modem_airplane_mode_switch.last_time // "")
            ERROR_TIMES[\"MODEM_AIRPLANE_MODE_SWITCH_LAST_TIME_SUCCESS\"]=\(.modem_airplane_mode_switch.last_time_success // "")

            # extra modem_soft_reset
            ERROR_COUNTS[\"MODEM_SOFT_RESET\"]=\(.modem_soft_reset.count // "0")
            ERROR_COUNTS[\"MODEM_SOFT_RESET_SUCCESS\"]=\(.modem_soft_reset.count_success // "0")
            ERROR_TIMES[\"MODEM_SOFT_RESET_LAST_TIME\"]=\(.modem_soft_reset.last_time // "")
            ERROR_TIMES[\"MODEM_SOFT_RESET_LAST_TIME_SUCCESS\"]=\(.modem_soft_reset.last_time_success // "")

            # extra modem_hard_reset
            ERROR_COUNTS[\"MODEM_HARD_RESET\"]=\(.modem_hard_reset.count // "0")
            ERROR_COUNTS[\"MODEM_HARD_RESET_SUCCESS\"]=\(.modem_hard_reset.count_success // "0")
            ERROR_TIMES[\"MODEM_HARD_RESET_LAST_TIME\"]=\(.modem_hard_reset.last_time // "")
            ERROR_TIMES[\"MODEM_HARD_RESET_LAST_TIME_SUCCESS\"]=\(.modem_hard_reset.last_time_success // "")

            # extra sim_error10
            ERROR_COUNTS[\"SIM_ERROR10\"]=\(.sim_error10.count // "0")
            ERROR_TIMES[\"SIM_ERROR10_LAST_TIME\"]=\(.sim_error10.last_time // "")

            # extra sim_error
            ERROR_COUNTS[\"SIM_ERROR\"]=\(.sim_error.count // "0")
            ERROR_TIMES[\"SIM_ERROR_LAST_TIME\"]=\(.sim_error.last_time // "")

            # extra network_error_no_ip
            ERROR_COUNTS[\"NETWORK_ERROR_NO_IP\"]=\(.network_error_no_ip.count // "0")
            ERROR_TIMES[\"NETWORK_ERROR_NO_IP_LAST_TIME\"]=\(.network_error_no_ip.last_time // "")

            # extra network_error
            ERROR_COUNTS[\"NETWORK_ERROR\"]=\(.network_error.count // "0")
            ERROR_TIMES[\"NETWORK_ERROR_LAST_TIME\"]=\(.network_error.last_time // "")

            # extra network_error_low_signal
            ERROR_COUNTS[\"NETWORK_ERROR_LOW_SIGNAL\"]=\(.network_error_low_signal.count // "0")
            ERROR_TIMES[\"NETWORK_ERROR_LOW_SIGNAL_LAST_TIME\"]=\(.network_error_low_signal.last_time // "")

            # extra modem_manager_err
            ERROR_COUNTS[\"MODEM_MANAGER_ERR\"]=\(.modem_manager_err.count // "0")
            ERROR_TIMES[\"MODEM_MANAGER_ERR_LAST_TIME\"]=\(.modem_manager_err.last_time // "")

            # extra modem_frequency_clear
            ERROR_COUNTS[\"MODEM_FREQUENCY_CLEAR\"]=\(.modem_frequency_clear.count // "0")
            ERROR_COUNTS[\"MODEM_FREQUENCY_CLEAR_SUCCESS\"]=\(.modem_frequency_clear.count_success // "0")
            ERROR_TIMES[\"MODEM_FREQUENCY_CLEAR_LAST_TIME\"]=\(.modem_frequency_clear.last_time // "")
            ERROR_TIMES[\"MODEM_FREQUENCY_CLEAR_LAST_TIME_SUCCESS\"]=\(.modem_frequency_clear.last_time_success // "")

            # extra mm_no_index
            ERROR_COUNTS[\"MM_NO_INDEX\"]=\(.mm_no_index.count // "0")
            ERROR_TIMES[\"MM_NO_INDEX_LAST_TIME\"]=\(.mm_no_index.last_time // "")

            # cached ICCID as initial value
            ICCID=\($iccid // "")
            
            # cached VERSION as initial value
            VERSION=\($version // "")
         "' "$STATE_JSON_PATH" 2>&1)" || {
            echo "jq parse state.json error: $state_init_script"
            return 1
        }
        eval "$state_init_script" || {
            echo -e "eval init script error: \n$(sed 's/^[ \t]*//;s/[ \t]*$//;/^$/d' <<<"$state_init_script")"
            return 1
        }
        debug "state init from state.json, initial content: \n$(sed 's/^[ \t]*//;s/[ \t]*$//;/^$/d' <<<"$state_init_script")"
    fi
}

get_utc_date() {
    date -u "+%Y-%m-%dT%H:%M:%SZ"
}

# check state changes and save it to state.json
save_state() {
    if ! $STATE_DIRTY && [ -f "$STATE_JSON_PATH" ]; then
        if [ -n "$VOLATILE_STATE_FILE_PATH" ]; then
            if [ -f "$VOLATILE_STATE_FILE_PATH" ]; then
                local volatile_time json_time
                volatile_time=$(stat -c '%Y' "$VOLATILE_STATE_FILE_PATH")
                json_time=$(stat -c '%Y' "$STATE_JSON_PATH")
                if [ "$volatile_time" -ne "$json_time" ]; then
                    cp -T -p "$STATE_JSON_PATH" "$VOLATILE_STATE_FILE_PATH"
                fi
            else
                mkdir -p "$(dirname "$VOLATILE_STATE_FILE_PATH")"
                cp -T -p "$STATE_JSON_PATH" "$VOLATILE_STATE_FILE_PATH"
            fi
        fi
        return
    fi
    local save="$STATE_JSON_PATH.save"
    mkdir -p "$(dirname "$save")"
    cat >"$save" <<EOF
{
  "timestamp": "$(get_utc_date)",
  "balena_uuid": "$BALENA_DEVICE_UUID",
  "ICCID": "$ICCID",
  "name": "CellularGuard",
  "version": "$VERSION",
  "result": "cg.$CURRENT_STATUS",
  "extra": {
    "mm_restart": {
      "count": "${ERROR_COUNTS["MM_RESTART"]}",
      "count_success": "${ERROR_COUNTS["MM_RESTART_SUCCESS"]}",
      "last_time": "${ERROR_TIMES["MM_RESTART_LAST_TIME"]}",
      "last_time_success": "${ERROR_TIMES["MM_RESTART_LAST_TIME_SUCCESS"]}"
    },
    "modem_airplane_mode_switch": {
      "count": "${ERROR_COUNTS["MODEM_AIRPLANE_MODE_SWITCH"]}",
      "count_success": "${ERROR_COUNTS["MODEM_AIRPLANE_MODE_SWITCH_SUCCESS"]}",
      "last_time": "${ERROR_TIMES["MODEM_AIRPLANE_MODE_SWITCH_LAST_TIME"]}",
      "last_time_success": "${ERROR_TIMES["MODEM_AIRPLANE_MODE_SWITCH_LAST_TIME_SUCCESS"]}"
    },
    "modem_soft_reset": {
      "count": "${ERROR_COUNTS["MODEM_SOFT_RESET"]}",
      "count_success": "${ERROR_COUNTS["MODEM_SOFT_RESET_SUCCESS"]}",
      "last_time": "${ERROR_TIMES["MODEM_SOFT_RESET_LAST_TIME"]}",
      "last_time_success": "${ERROR_TIMES["MODEM_SOFT_RESET_LAST_TIME_SUCCESS"]}"
    },
    "modem_hard_reset": {
      "count": "${ERROR_COUNTS["MODEM_HARD_RESET"]}",
      "count_success": "${ERROR_COUNTS["MODEM_HARD_RESET_SUCCESS"]}",
      "last_time": "${ERROR_TIMES["MODEM_HARD_RESET_LAST_TIME"]}",
      "last_time_success": "${ERROR_TIMES["MODEM_HARD_RESET_LAST_TIME_SUCCESS"]}"
    },
    "sim_error10": {
      "count": "${ERROR_COUNTS["SIM_ERROR10"]}",
      "last_time": "${ERROR_TIMES["SIM_ERROR10_LAST_TIME"]}"
    },
    "sim_error": {
      "count": "${ERROR_COUNTS["SIM_ERROR"]}",
      "last_time": "${ERROR_TIMES["SIM_ERROR_LAST_TIME"]}"
    },
    "network_error_no_ip": {
      "count": "${ERROR_COUNTS["NETWORK_ERROR_NO_IP"]}",
      "last_time": "${ERROR_TIMES["NETWORK_ERROR_NO_IP_LAST_TIME"]}"
    },
    "network_error_low_signal": {
      "count": "${ERROR_COUNTS["NETWORK_ERROR_LOW_SIGNAL"]}",
      "last_time": "${ERROR_TIMES["NETWORK_ERROR_LOW_SIGNAL_LAST_TIME"]}"
    },
    "network_error": {
      "count": "${ERROR_COUNTS["NETWORK_ERROR"]}",
      "last_time": "${ERROR_TIMES["NETWORK_ERROR_LAST_TIME"]}"
    },
    "modem_manager_err": {
      "count": "${ERROR_COUNTS["MODEM_MANAGER_ERR"]}",
      "last_time": "${ERROR_TIMES["MODEM_MANAGER_ERR_LAST_TIME"]}"
    },
    "modem_frequency_clear": {
      "count": "${ERROR_COUNTS["MODEM_FREQUENCY_CLEAR"]}",
      "count_success": "${ERROR_COUNTS["MODEM_FREQUENCY_CLEAR_SUCCESS"]}",
      "last_time": "${ERROR_TIMES["MODEM_FREQUENCY_CLEAR_LAST_TIME"]}",
      "last_time_success": "${ERROR_TIMES["MODEM_FREQUENCY_CLEAR_LAST_TIME_SUCCESS"]}"
    },
    "mm_no_index": {
      "count": "${ERROR_COUNTS["MM_NO_INDEX"]}",
      "last_time": "${ERROR_TIMES["MM_NO_INDEX_LAST_TIME"]}"
    }
  }
}
EOF
    sync "$save"
    mv "$save" "$STATE_JSON_PATH"
    if [ -n "$VOLATILE_STATE_FILE_PATH" ]; then
        mkdir -p "$(dirname "$VOLATILE_STATE_FILE_PATH")"
        cp -T -p "$STATE_JSON_PATH" "$VOLATILE_STATE_FILE_PATH"
    fi
    STATE_DIRTY=false
}

# plus count of error type with last time
# $1: error type
# $2: success or not
record_error() {
    local error_type="$1"
    local success="$2"

    if [ -n "$success" ] && $success; then
        ERROR_COUNTS["$error_type"_SUCCESS]=$((ERROR_COUNTS["$error_type"_SUCCESS] + 1))
        ERROR_TIMES["$error_type"_LAST_TIME_SUCCESS]=${ERROR_TIMES["$error_type"_LAST_TIME]}
    else
        ERROR_COUNTS["$error_type"]=$((ERROR_COUNTS["$error_type"] + 1))
        ERROR_TIMES["$error_type"_LAST_TIME]="$(get_utc_date)"
    fi
    STATE_DIRTY=true
}

# $1: interval to check
# $2: timeout of wait
# $*: command of wait
# return 0 if success, 1 if timeout
wait_for() {
    if [ $# -lt 3 ]; then
        echo "wait_for: missing arguments"
        return 1
    fi
    local interval="$1"
    local timeout="$2"
    shift 2
    local count=0
    while [ $count -lt "$timeout" ]; do
        if "$@"; then
            return 0
        fi
        sleep "$interval"
        count=$((count + interval))
    done
    return 1
}

# Args:
#   time: timeout seconds
#   command: remain as commands
# Output:
#   None
timeout() {
    if [ $# -lt 2 ]; then
        echo 'Wrong usage of timeout'
        return 1
    fi
    local time="$1"
    shift
    local pid current=0
    time=$((time * 10))
    # background running
    "$@" &
    pid=$!
    while kill -0 $pid &>/dev/null; do
        if [ "$current" -gt "$time" ]; then
            kill $pid &>/dev/null || true
            echo "Command '$*' timeout with $time seconds"
            return 127
        fi
        sleep 0.1
        ((current++))
    done
    wait $pid
}

# log message to file with date prefix
log_to_file() {
    if [ "$PERSISTENT_LOGGING" != y ]; then
        return
    fi
    if [ -z "$MAX_LOG_SIZE" ] || [ "$MAX_LOG_SIZE" -eq 0 ]; then
        return
    fi
    # return if no permission
    touch "$LOG_FILE_PATH" &>/dev/null || return

    # reduce the number of logs with the same content
    if [ "$*" = "$LAST_LOG_CONTENT" ]; then
        if [ "$LAST_SAME_LOG_COUNT" -lt "$MAX_SUPRESSED_LOGS_NUM" ]; then
            ((LAST_SAME_LOG_COUNT++))
            LAST_LOG_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
            return
        else
            echo -e "Suppressed $LAST_SAME_LOG_COUNT identical logs: '$LAST_LOG_CONTENT', most recent at $LAST_LOG_TIME" >>"$LOG_FILE_PATH"
            LAST_SAME_LOG_COUNT=0
            return
        fi
    elif [ "$LAST_SAME_LOG_COUNT" -gt 0 ]; then
        echo -e "Suppressed $LAST_SAME_LOG_COUNT identical logs: '$LAST_LOG_CONTENT', most recent at $LAST_LOG_TIME" >>"$LOG_FILE_PATH"
        LAST_SAME_LOG_COUNT=0
    fi

    # not log flush flag
    if [ "$*" = "$LOG_FLUSH_FLAG" ]; then
        return
    fi

    LAST_LOG_CONTENT="$*"
    echo -e "$(date '+%Y-%m-%d %H:%M:%S'): $LAST_LOG_CONTENT" >>"$LOG_FILE_PATH"
}

# both output message to console and file
tee_log() {
    trap 'log_shell_leave' EXIT

    while IFS='' read -r line; do
        if [ -n "$DEBUG" ]; then
            echo -e "$line"
        fi

        log_to_file "$line"
    done
}

# if --debug 0, print debug info to console
# else log debug info to log file
debug() {
    if [ "$DEBUG" = '0' ]; then
        # redirect to stderr to avoid capture of subshell output
        echo -e "$*" >&2
    else
        log_to_file "$*"
    fi
}

# Log of exit
main_shell_leave() {
    save_state
    log_to_file "$LOG_FLUSH_FLAG"
    truncate_log
    log_to_file "cellular guard exited, exit code: $?"
    sync "$LOG_FILE_PATH"
}

log_shell_leave() {
    log_to_file "$LOG_FLUSH_FLAG"
}

update_status() {
    local status="$1"
    if [ ! -f "$STATUS_FILE_PATH" ] || [ "$status" != "$CURRENT_STATUS" ]; then
        echo "status changed from $CURRENT_STATUS to $status"
        CURRENT_STATUS="$status"
        STATE_DIRTY=true
    else
        return 0
    fi
    if [ "$PERSISTENT_LOGGING" != y ]; then
        return 0
    fi
    mkdir -p "$(dirname "$STATUS_FILE_PATH")" || return
    local save="$STATUS_FILE_PATH.save"
    echo -n "$*" >"$save"
    sync "$save"
    mv "$save" "$STATUS_FILE_PATH"
}

# if the log exceeds the max size, halve it
truncate_log() {
    local log_size
    if [ -f "$LOG_FILE_PATH" ]; then
        if [ -z "$MAX_LOG_SIZE" ] || [ "$MAX_LOG_SIZE" -eq 0 ]; then
            return 0
        fi
        sync "${LOG_FILE_PATH}"
        log_size=$(du -Lks "${LOG_FILE_PATH}" | awk '{print $1}')
        if [ "$log_size" -gt "$MAX_LOG_SIZE" ]; then
            local line_num
            line_num=$(wc -l <"$LOG_FILE_PATH")
            tail -n $((line_num / 2)) "${LOG_FILE_PATH}" >"${LOG_FILE_PATH}.save"
            sync "${LOG_FILE_PATH}.save"
            mv "${LOG_FILE_PATH}.save" "${LOG_FILE_PATH}"
            log_size=$(du -Lks "${LOG_FILE_PATH}" | awk '{print $1}')
            log_to_file "truncate log to $((line_num / 2)) lines, ${log_size}KB"
        fi
    fi
}

# run AT command directly to modem, log output to file
# not dbus-send to avoid potential problems with the ModemManager
at_log_through_usb() {
    local log_pid
    if [ ! -e $RAW_USB_DEV ]; then
        echo "can not find $RAW_USB_DEV, maybe modem is bricked or is hard reseting"
        return 1
    fi
    log_to_file "now start to log raw AT command result"
    cat $RAW_USB_DEV >>"${LOG_FILE_PATH}" &
    log_pid=$!

    # sim card status
    echo -en "AT+CPIN?\r\n" >$RAW_USB_DEV
    echo -en "AT+CCID\r\n" >$RAW_USB_DEV
    echo -en "ATI\r\n" >$RAW_USB_DEV

    # registration status
    echo -en "AT+CEREG?\r\n" >$RAW_USB_DEV
    echo -en "AT+QENG=\"SERVINGCELL\"\r\n" >$RAW_USB_DEV

    # data connection
    echo -en "AT+CGACT?\r\n" >$RAW_USB_DEV

    # frequancy info
    echo -en "AT+QNWINFO\r\n" >$RAW_USB_DEV
    # signal strength
    echo -en "AT+CSQ\r\n" >$RAW_USB_DEV

    sleep 10
    sync "${LOG_FILE_PATH}"
    kill $log_pid
    log_to_file "raw AT command result end"
}

# check whether 4G module usb bus is ready
is_modem_usb_ready() {
    lsusb | grep -q -i -e 'Quectel.*EC21'
}

# hardware reset 4G module
hard_reset_and_record() {
    timeout 15 at_log_through_usb

    if [ -e /sys/bus/platform/devices/misc-adv-gpio/minipcie_reset ]; then
        record_error MODEM_HARD_RESET
        echo 1 >/sys/bus/platform/devices/misc-adv-gpio/minipcie_reset
        sleep 0.5
        # wait for modem usb available
        if wait_for 5 300 is_modem_usb_ready; then
            record_error MODEM_HARD_RESET true
        else
            echo "find modem usb timeout after hard reset"
            # modem module is gone, could not restore
            return 1
        fi
    else
        record_error MODEM_HARD_RESET
        # Valid time: 150ms -- 460 ms, If it is greater than 460ms, the module will enter the second reset
        ./gpio 1 0
        # sleep 200ms
        sleep 0.2
        ./gpio 1 1
        sleep 0.5
        # wait for modem usb available
        if wait_for 5 300 is_modem_usb_ready; then
            record_error MODEM_HARD_RESET true
        else
            echo "find modem usb timeout after hard reset"
            # modem module is gone, could not restore
            return 1
        fi
    fi

}

# Call dbus stop a systemd service
stop_service() {
    local service_name="$1"
    if ! [[ $service_name =~ \.service$ ]]; then
        service_name="$service_name.service"
    fi
    dbus-send --print-reply --type=method_call --system --dest=org.freedesktop.systemd1 \
        /org/freedesktop/systemd1 org.freedesktop.systemd1.Manager.StopUnit \
        string:"$service_name" string:"replace"
}

# Call dbus start a systemd service
start_service() {
    local service_name="$1"
    if ! [[ $service_name =~ \.service$ ]]; then
        service_name="$service_name.service"
    fi
    dbus-send --print-reply --type=method_call --system --dest=org.freedesktop.systemd1 \
        /org/freedesktop/systemd1 org.freedesktop.systemd1.Manager.StartUnit \
        string:"$service_name" string:"replace"
}

# Call dbus restart a systemd service
# Reference: https://dbus.freedesktop.org/doc/dbus-send.1.html
# https://www.balena.io/docs/learn/develop/runtime/#d-bus-communication-with-host-os
restart_service() {
    local service_name="$1"
    if ! [[ $service_name =~ \.service$ ]]; then
        service_name="$service_name.service"
    fi
    dbus-send --print-reply --type=method_call --system --dest=org.freedesktop.systemd1 \
        /org/freedesktop/systemd1 org.freedesktop.systemd1.Manager.RestartUnit \
        string:"$service_name" string:"replace" || {
        return 1
    }
}

# check whether ModemManager service is active state
is_modemmanager_active() {
    dbus-send --print-reply --type=method_call --system --dest=org.freedesktop.systemd1 \
        /org/freedesktop/systemd1/unit/ModemManager_2eservice org.freedesktop.DBus.Properties.Get \
        string:"org.freedesktop.systemd1.Unit" string:"ActiveState" | grep -q 'active'
}

is_modemmanager_index_ready() {
    local index
    index=$(
        dbus-send --print-reply=literal --type=method_call --system --dest=org.freedesktop.ModemManager1 \
            /org/freedesktop/ModemManager1 org.freedesktop.DBus.ObjectManager.GetManagedObjects |
            grep -Eo '/org/freedesktop/ModemManager1/Modem/[0-9]+' |
            sed -En 's|/org/freedesktop/ModemManager1/Modem/([0-9]+)|\1|p' 2>/dev/null | head -1
    )
    if [ $? -ne 0 ] || [ -z "$index" ]; then
        return 1
    fi
}

# do not run this in a subshell $() or backticks ``
# because the modification of MODEM_INDEX will not be effective
get_modem_index() {
    local index code
    # whether ModemManager is restarting
    local restart_pending=false

    # max wait time 30*5=150 seconds
    # worst wait time when dbus-send timeout: 30*(5+5)=300 seconds
    for check_count in {1..30}; do
        if $restart_pending; then
            if is_modemmanager_active; then
                restart_pending=false
                debug "ModemManager restart success"
                record_error MM_RESTART true
            fi
        fi
        index=$(
            dbus-send --reply-timeout=5000 --print-reply=literal --type=method_call --system --dest=org.freedesktop.ModemManager1 \
                /org/freedesktop/ModemManager1 org.freedesktop.DBus.ObjectManager.GetManagedObjects |
                grep -Eo '/org/freedesktop/ModemManager1/Modem/[0-9]+' |
                sed -En 's|/org/freedesktop/ModemManager1/Modem/([0-9]+)|\1|p' | head -1
        )
        code=$?
        # retry if modem manager is not start or modem is not ready
        if [ $code -ne 0 ] || [ -z "$index" ]; then
            # every 12 times(1 minute) restart ModemManager
            if ((check_count % 12 == 0)); then
                echo "get modem index timeout, will restart ModemManager"
                # do some log by raw AT command
                timeout 15 at_log_through_usb

                if $restart_pending; then
                    debug "ModemManager restart failed"
                else
                    restart_service ModemManager && {
                        restart_pending=true
                        record_error MM_RESTART
                    }
                fi
            fi
            sleep 5
        else
            if [ "$MODEM_INDEX" != "$index" ]; then
                debug "modem index changed from '$MODEM_INDEX' to '$index'"
                MODEM_INDEX="$index"
            fi
            return 0
        fi
    done
    if [ $code -ne 0 ] || $restart_pending; then
        record_error MODEM_MANAGER_ERR
        update_status "${NETWORK_STATUS["MODEM_MANAGER_ERR"]}"
    else # index is empty, get moden index timeout but ModemManager is running normally
        record_error MM_NO_INDEX
    fi

    # force hard reset because get index timeout
    touch "$HARD_RESET_REQUIRED_FILE"

    # Possibilities include:
    # 1. ModemManager restart fail
    # 2. Dbus error
    # 3. Can't not get a valid modem index
    return 1
}

# Send AT command to modem and output result
# Return 0 if send successfully
# Timeout is (probably) 2 seconds
# Attension: In most cases, get_modem_index should be run before calling this function.
# Also see https://www.freedesktop.org/software/ModemManager/api/latest/gdbus-org.freedesktop.ModemManager1.Modem.html#gdbus-method-org-freedesktop-ModemManager1-Modem.Command
# Use ModemManager api but echo to /dev/ttyUSB2 directly to avoid device occupancy conflicts
AT_send() {
    local at_command="$1"
    local at_result

    # dbus-send:
    # if send: AT+QENG="SERVINGCELL"
    # output:  +QENG: "servingcell","NOCONN","LTE","FDD",262,01,25A5507,212,500,1,5,5,67BD,-93,-7,-65,15,28
    at_result=$(
        dbus-send --reply-timeout=5000 --print-reply=literal --type=method_call --system --dest=org.freedesktop.ModemManager1 \
            /org/freedesktop/ModemManager1/Modem/"$MODEM_INDEX" org.freedesktop.ModemManager1.Modem.Command \
            string:"$at_command" uint32:2000 2>&1 | sed -e 's|^[[:space:]]*||'
    )

    if [ $? -ne 0 ]; then
        debug "AT command '$at_command' failed: $at_result"
        # When the ModemManager log shows a large number of "[modem0] couldn't enable interface: 'Invalid transition'".
        if grep -q -i 'operation not permitted' <<<"$at_result"; then
            touch "$HARD_RESET_REQUIRED_FILE"
        fi
        return 1
    fi

    # will return like: "servingcell","NOCONN","LTE","FDD",262,01,25A5507,212,500,1,5,5,67BD,-93,-7,-65,15,28
    cut -d: -f2- <<<"$at_result" | sed -e 's|^[[:space:]]*||'
}

# Get property of ModemManager
get_property() {
    get_modem_index || return 1
    dbus-send --system --print-reply --type=method_call --dest=org.freedesktop.ModemManager1 \
        /org/freedesktop/ModemManager1/Modem/"$MODEM_INDEX" \
        org.freedesktop.DBus.Properties.Get string:"org.freedesktop.ModemManager1.Modem" string:"$1"
}

# AT+QMBNCFG="AutoSel"
# MBNCFG="AutoSel",1
check_mbn() {
    local result
    get_modem_index || return 1
    if ! result=$(AT_send 'AT+QMBNCFG="AutoSel"'); then
        return 1
    fi
    debug "AT+QMBNCFG=\"AutoSel\" result:$result"
    echo "$result" | grep -Eq '1$'
}

# AT+QMBNCFG="AutoSel",1
set_mbn() {
    get_modem_index || return 1
    local at_result
    at_result=$(AT_send 'AT+QMBNCFG="AutoSel",1' 2>&1) || {
        debug "AT+QMBNCFG=\"AutoSel\",1 failed: $at_result"
        return 1
    }
}

# check sim card in ERROR: 13 state
# dbus will simple return SIM is not inserted, so here must use raw AT command
raw_at_check_error_13() {
    local log_pid log_file
    log_file=$(mktemp)
    if [ ! -e $RAW_USB_DEV ]; then
        echo "can not find $RAW_USB_DEV, maybe modem is bricked or is hard reseting"
        return 1
    fi
    debug "use raw AT 'AT+CPIN?' command to check sim card status"
    cat $RAW_USB_DEV >>"${log_file}" &
    log_pid=$!

    # sim card status
    echo -en "AT+CPIN?\r\n" >$RAW_USB_DEV
    sleep 10

    kill $log_pid &>/dev/null || true
    sync "$log_file"
    debug "raw AT command result:"
    debug "$(cat "$log_file")"
    grep -q 'ERROR: 13' "$log_file"
}

# AT+CPIN?
# READY found
# return:
#    0: sim card ready
#    1: sim card not ready, and other unknown error(like dbus error and AT timeout)
#    10: sim card not found(by dbus messgae: SIM not inserted or ERROR: 10)
#    13: sim card error 13
check_sim_status() {
    local result code
    get_modem_index || return 1
    result=$(AT_send 'AT+CPIN?')
    code=$?
    debug "AT+CPIN? result:$result"
    if [ "$code" -ne 0 ]; then
        timeout 15 raw_at_check_error_13
        code=$?
        if [ "$code" -eq 0 ]; then
            return 13
        elif [ "$code" -eq 1 ]; then
            # Not Error: 13 found, but here is dbus error
            # so it will be SIM not inserted message
            return 10
        else # timeout
            return 1
        fi
    fi
    
    # ERROR: 13: sim error
    # ERROR: 10: no sim
    if echo "$result" | grep -Eq 'ERROR: 10'; then
        return 10
    fi

    echo "$result" | grep -q 'READY'
}

# AT+CCID
check_sim_ccid() {
    local result
    get_modem_index || return 1
    if ! result=$(AT_send 'AT+CCID'); then
        return 2
    fi
    debug "AT+CCID result:$result"

    # ERROR: 13: sim error
    if ! echo "$result" | grep -Eq '^[0-9]+$'; then
        return 1
    fi

    iccid="$(echo "$result" | tail -1 | cut -d' ' -f2 | tr -d '\n')"
    if [ "$ICCID" != "$iccid" ]; then
        # cache iccid for state report
        ICCID="$iccid"
        STATE_DIRTY=true
    fi
}

# AT+CSQ
# Assign signal quality to GLOBAL_VAR if success
get_signal_quality() {
    local result signal_quality
    get_modem_index || return 1
    if ! result=$(AT_send 'AT+CSQ'); then
        return 1
    fi
    debug "AT+CSQ result:$result"
    signal_quality="$(echo "$result" | tail -1 | cut -d, -f1)"
    # not all numbers, wrong quality
    if [[ ! "$signal_quality" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    GLOBAL_VAR="$signal_quality"
}

# Get modem firmware revision like: EC21EUXGAR08A04M1G
# Assign to GLOBAL_VAR if success
get_modem_firmware_revision() {
    get_modem_index || return 1
    local result
    if ! result=$(AT_send 'ATI'); then
        return 1
    fi
    debug "ATI result:$result"
    GLOBAL_VAR=$(echo "$result" | tail -1 | cut -d' ' -f2 | tr -d '\n')
}

# Network resident of 4G module
check_registration() {
    local result
    get_modem_index || return 1
    # this will return empty string if no error
    # see https://github.com/freedesktop/ModemManager/blob/eae2e28577c53e8deaa25d46d6032d5132be6b58/src/mm-modem-helpers.c#L818
    if ! result=$(AT_send 'AT+CEREG?'); then
        return 2
    fi
    debug "AT+CEREG? result:$result, it's normal if is empty."

    # not empty return 1
    [ -z "$result" ] || return 1

    # result like: "servingcell","NOCONN","LTE","FDD",262,01,25A5507,212,500,1,5,5,67BD,-93,-7,-65,15,28
    if ! result=$(AT_send 'AT+QENG="servingcell"'); then
        return 2
    fi

    debug "AT+QENG=\"servingcell\" result:$result"

    # SEARCH, LIMSRV, NOCONN, CONNECT
    if ! echo "$result" | grep -q 'NOCONN'; then
        return 1
    fi
}

# AT+CGACT?
# Check data connection
check_data_connection() {
    get_modem_index || return 1
    local result
    if ! result=$(AT_send 'AT+CGACT?'); then
        return 1
    fi
    debug "AT+CGACT? result:$result"
}

# check modem type by lsusb
# return 0 if Quectel EC21
detect_modem_type() {
    if lsusb | grep -q -i -e 'Quectel.*EC21'; then
        return 0
    elif [ "$(lsusb | grep -c -e 'Bus 002')" -eq 1 ] ||
        lsusb | grep -q -i -e 'Qualcomm.*QHSUSB'; then
        # bus 002 only has a controller, no other node, or Qualcomm.*QHSUSB found, mean modem is bricked
        update_status "${NETWORK_STATUS["MODEM_BRICKED"]}"
        return 1
    else # bus 002 has 2 devices but is not Quectel and not Qualcomm QHSUSB
        update_status "${NETWORK_STATUS["MODEM_UNKNOWN"]}"
        return 1
    fi
}

# AT command restart 4G module
at_restart_module() {
    get_modem_index || return 1
    record_error MODEM_SOFT_RESET
    local at_result
    at_result=$(AT_send 'AT+CFUN=1,1' 2>&1) || {
        debug "AT+CFUN=1,1 failed: $at_result"
        return 1
    }
}

# Restart 4G module and record error
# Will wait for modem ready
at_restart_module_and_record() {
    at_restart_module || return 1

    # wait for modem ready
    if wait_for 5 300 is_modemmanager_index_ready; then
        record_error MODEM_SOFT_RESET true
    else
        return 1
    fi
}

# ModemManager dbus api reset 4G module
restart_module() {
    get_modem_index || return 1

    record_error MODEM_SOFT_RESET

    dbus-send --print-reply=literal --type=method_call --system --dest=org.freedesktop.ModemManager1 \
        /org/freedesktop/ModemManager1/Modem/"$MODEM_INDEX" org.freedesktop.ModemManager1.Modem.Reset
}

# Restart 4G module and record error
# Will wait for modem ready
restart_module_and_record() {
    restart_module || return 1

    # wait for modem ready
    if wait_for 5 300 is_modemmanager_index_ready; then
        record_error MODEM_SOFT_RESET true
    else
        return 1
    fi
}

# Airplane mode switch
# cfun0 disables the RF component and transceiver unit，while cfun1 does the opposite
# The big difference between the AT+CFUN=0 state and AT+CFUN=1,1 state is that
# in the AT+CFUN=1,1 one the module is completely off, including the AT interface.
# In AT+CFUN=0 you still can communicate with the module.
# WARNING: Do not use this function, will cause ModemManager stuck
at_cfun01() {
    get_modem_index || return 1
    record_error MODEM_AIRPLANE_MODE_SWITCH

    local at_result
    at_result=$(AT_send 'AT+CFUN=0' 2>&1) || {
        debug "AT+CFUN=0 failed: $at_result"
        return 1
    }

    sleep 3
    # wait for modem ready
    get_modem_index || return 1

    # FIXME: ModemManager will automatically enable modem after AT+CFUN=0,
    # will cause "org.freedesktop.ModemManager1.Error.Core.Cancelled: AT command was cancelled" when do AT+CFUN=1
    # and MODEM_INDEX will plus 2
    at_result=$(AT_send 'AT+CFUN=1' 2>&1) || {
        debug "AT+CFUN=1 failed: $at_result"
        return 1
    }
}

at_cfun01_and_record() {
    at_cfun01 || return 1

    # wait for modem ready
    if wait_for 5 300 is_modemmanager_index_ready; then
        record_error MODEM_AIRPLANE_MODE_SWITCH true
    else
        return 1
    fi
}

# dbus api for airplane mode switch
# Airplane mode switch by dbus
# some steps not work for EC21
cfun01() {
    get_modem_index || return 1

    record_error MODEM_AIRPLANE_MODE_SWITCH

    # NetworkManager will re-enable modem is have connection set
    dbus-send --print-reply=literal --type=method_call --system --dest=org.freedesktop.ModemManager1 \
        /org/freedesktop/ModemManager1/Modem/"$MODEM_INDEX" org.freedesktop.ModemManager1.Modem.Enable \
        boolean:false || return 1

    # set power state to MM_MODEM_POWER_STATE_OFF
    # FIXME: EC21 not supported set power state
    # dbus-send --print-reply=literal --type=method_call --system --dest=org.freedesktop.ModemManager1 \
    #     /org/freedesktop/ModemManager1/Modem/"$MODEM_INDEX" org.freedesktop.ModemManager1.Modem.SetPowerState \
    #     uint32:1
    #
    sleep 5

    # restore to MM_MODEM_POWER_STATE_ON
    # dbus-send --print-reply=literal --type=method_call --system --dest=org.freedesktop.ModemManager1 \
    #     /org/freedesktop/ModemManager1/Modem/"$MODEM_INDEX" org.freedesktop.ModemManager1.Modem.SetPowerState \
    #     uint32:3

    dbus-send --print-reply=literal --type=method_call --system --dest=org.freedesktop.ModemManager1 \
        /org/freedesktop/ModemManager1/Modem/"$MODEM_INDEX" org.freedesktop.ModemManager1.Modem.Enable \
        boolean:true || return 1
    sleep 5
}

cfun01_and_record() {
    cfun01 || return 1
    # no need to wait, ModemManager will automatically do it
    record_error MODEM_AIRPLANE_MODE_SWITCH true
}

# Frequency clearing
frequency_clear() {
    get_modem_index || return 1
    record_error MODEM_FREQUENCY_CLEAR

    local at_result
    # clear 4G frequency
    at_result=$(AT_send 'AT+QNVFD="/nv/reg_files/modem/lte/rrc/csp/acq_db"' 2>&1) || {
        debug "AT+QNVFD=\"/nv/reg_files/modem/lte/rrc/csp/acq_db\" failed: $at_result"
        return 1
    }
    # clear 2G frequency
    at_result=$(AT_send 'AT+QCFG="nwoptmz/acq",0' 2>&1) || {
        debug "AT+QCFG=\"nwoptmz/acq\",0 failed: $at_result"
        return 1
    }
}

# Frequency clearing and record error
frequency_clear_and_record() {
    frequency_clear || return 1
    record_error MODEM_FREQUENCY_CLEAR true
}

# Check nerwork by ping internet, once, timeout 5s
ping_network() {
    # ping return 0 if success
    # return 1 if packet loose
    # return 2 if error
    ping -I wwan0 -c1 -W 5 8.8.8.8 &>/dev/null || {
        # try again to avoid the network fluctuation factor
        sleep 1
        ping -I wwan0 -c1 -W 5 8.8.8.8 &>/dev/null
    }
}

# Check if is Advantech board and Quectel EC21 firmware
# Return 0 if match
check_board() {
    local board_name
    if [ -e /proc/board ]; then
        board_name=$(cat /proc/board)
        if ! get_modem_firmware_revision; then
            echo "can't get modem firmware revision"
            return 2
        fi
        revision=$GLOBAL_VAR
        debug "board name: $board_name, revision: $revision"
        if [[ "$board_name" =~ ^(EBC-RS08|EBC-RS10) ]]; then
            # current list:
            # EC21EUXGAR08A06M1G EC21EUXGAR08A07M1G EC21EUXGAR08A04M1G
            if [[ "$revision" =~ ^EC21EU ]]; then
                return 0
            else
                echo "modem revision not match, current is '$revision'"
            fi
        else
            echo "board name not match, current is '$board_name'"
        fi
    fi
    return 1
}

detect_modem_type_loop() {
    local code
    for _ in {1..5}; do
        if detect_modem_type; then
            return 0
        fi
        sleep 10
    done
    return 1
}

check_board_loop() {
    for i in {1..5}; do
        check_board
        code=$?
        if [ $code -eq 0 ]; then
            return 0
        elif [ $code -eq 1 ]; then
            # not match, do nothing
            return 1
        elif [ "$i" -ge 3 ]; then # get firmware revision failed third time
            restart_module_and_record || {
                echo "restart module at check board loop failed"
                return 1
            }
            sleep 30
        fi
    done
    return 1
}

# Entry of "mbn module"
mbn_loop() {
    for _ in {1..5}; do
        if ! check_mbn; then
            echo "mbn not set, set it"
            set_mbn || {
                echo "set mbn failed"
                return 1
            }
            restart_module_and_record || {
                echo "restart module at mbn loop failed"
                return 1
            }
            save_state
            sleep 25
        else
            echo 'mbn check complete'
            return 0
        fi
    done
    return 1
}

# Entry of "SIM card maintenance module"
sim_status_loop() {
    # Current SIM card checking error times
    local current_sim_error_count=0
    # Current SIM clear frequency count
    local current_sim_frequency_clear_count=0
    local last_code

    while true; do
        check_sim_status
        last_code=$?
        # 10 means no sim
        # 2 means dbus error, SIM not inserted
        if [ "$last_code" -eq 10 ]; then
            echo "sim card communication exception"
            update_status "${NETWORK_STATUS["SIM_ERROR10"]}"
            record_error SIM_ERROR10
            restart_module_and_record
            return 1
        fi

        if ! check_sim_ccid; then
            update_status "${NETWORK_STATUS["SIM_ERROR"]}"
            record_error SIM_ERROR
            if [ "$current_sim_frequency_clear_count" -ge 1 ]; then
                echo "fatal error: sim card status is abnormal even after clearing frequancy data"
                return 1
            else
                if [ "$current_sim_error_count" -ge "$MAX_SIM_ERROR_COUNT" ]; then
                    echo "sim error count exceed $MAX_SIM_ERROR_COUNT, clear modem frequency data"
                    frequency_clear_and_record || {
                        echo "clear modem frequency data at sim status loop failed"
                        return 1
                    }
                    ((current_sim_frequency_clear_count++))
                else
                    ((current_sim_error_count++))
                fi

                # hard reset 4G module when can't connect network after 2th At reset 4G module.
                if [ "$current_sim_error_count" -ge 3 ]; then
                    echo "hard reset modem module due to sim card failed larger than 3 times"
                    hard_reset_and_record || {
                        echo "hard reset modem at sim status loop failed"
                        return 1
                    }
                else
                    echo "restart modem module due to sim card problem"
                    restart_module_and_record || {
                        echo "restart module at sim status loop failed"
                        return 1
                    }
                fi
            fi
        else
            echo "sim status no problem"
            return 0
        fi
        truncate_log
        save_state
    done
}

# Ignore number if is zero
# Remove 's' suffix if is plural
humanize_unit() {
    local number=$1
    local unit=$2
    if [ "$number" -eq 0 ]; then
        return
    elif [ "$number" -eq 1 ]; then
        echo " $number ${unit%s}"
    else
        echo " $number $unit"
    fi
}

# format seconds number to human friendly unit
# like 3661 -> 1 hour 1 minute 1 second
# 7322 -> 2 hours 2 minutes 1 seconds
humanize_interval() {
    local seconds=$1
    if [ -z "$seconds" ]; then
        return
    fi
    if ! grep -q -E '^[0-9]+$' <<<"$seconds"; then
        echo " $seconds"
        return
    fi
    if [ "$seconds" -ge 3600 ]; then
        echo -n "$(humanize_unit $((seconds / 3600)) hours)"
        echo -n "$(humanize_unit $(((seconds % 3600) / 60)) minutes)"
        echo -n "$(humanize_unit $((seconds % 60)) seconds)"
    elif [ "$seconds" -ge 60 ]; then
        echo -n "$(humanize_unit $((seconds / 60)) minutes)"
        echo -n "$(humanize_unit $((seconds % 60)) seconds)"
    else
        humanize_unit "$((seconds % 60))" seconds
    fi
}

# Update status for ping fail
record_ping_fail_status() {
    local signal_quality

    get_signal_quality || return 1
    signal_quality=$GLOBAL_VAR

    if ! ip address show dev wwan0 | grep -E -q 'inet [0-9]{1,3}(\.[0-9]{1,3}){3}'; then
        update_status "${NETWORK_STATUS["NETWORK_ERROR_NO_IP"]}"
        record_error NETWORK_ERROR_NO_IP
        echo "ping network error, no ip obtained"
    elif [ "$signal_quality" = 99 ] || [ "$signal_quality" -lt 15 ]; then # signal quality is 99, means no signal, or less than 15, means signal is too weak
        update_status "${NETWORK_STATUS["NETWORK_ERROR_LOW_SIGNAL"]}"
        record_error NETWORK_ERROR_LOW_SIGNAL
        echo "ping network error, low signal quality: $signal_quality"
    else
        update_status "${NETWORK_STATUS["NETWORK_ERROR"]}"
        record_error NETWORK_ERROR
        echo "ping network error, ip obtained"
    fi
}

# Log modem info for network error
log_modem_info_for_network_error() {
    check_registration
    check_data_connection
    debug "$(ip address show dev wwan0)"
}

# Entry of "network check module"
network_check_loop() {
    # Current ping check error times
    local current_ping_error_count=0
    # Current frequency point check error times
    local current_frequancy_error_count=0
    # Current frequency clearing times
    local current_frequancy_clear_count=0
    # current interval index,
    # current ping interval is ${PING_INTERVALS_ARRAY[$current_interval_index]}
    # current max ping error count is ${MAX_PING_ERROR_COUNT_ARRAY[$current_interval_index]}
    local current_interval_index=0
    local current_sleep_interval

    while true; do
        if ! ping_network; then
            record_ping_fail_status

            if [ "$current_frequancy_clear_count" -ge 1 ]; then
                # Frequency point fault is greater than or equal to 1, abnormal end
                # Then enter next 8h loop
                echo "fatal error: can't access network after clearing frequancy data"
                return 1
            else
                ((current_ping_error_count++))
                if [ "$current_ping_error_count" -ge "${MAX_PING_ERROR_COUNT_ARRAY[$current_interval_index]}" ]; then

                    ((current_frequancy_error_count++))
                    if [ "$current_frequancy_error_count" -ge "$CURRENT_MAX_FREQUENCY_ERROR_COUNT" ]; then

                        if [ "$CURRENT_STATUS" = "${NETWORK_STATUS["NETWORK_ERROR_LOW_SIGNAL"]}" ]; then
                            echo "skip modem frequancy data clear due to low signal quality"
                        else
                            echo "restart module count reach max:$CURRENT_MAX_FREQUENCY_ERROR_COUNT, clear modem frequancy data"
                            frequency_clear_and_record || {
                                echo "frequency clear failed"
                                return 1
                            }
                        fi

                        ((current_frequancy_clear_count++))
                        ((CURRENT_MAX_FREQUENCY_ERROR_COUNT++))

                        if [ "$CURRENT_MAX_FREQUENCY_ERROR_COUNT" -gt "$MAX_FREQUENCY_ERROR_COUNT_MAX" ]; then
                            CURRENT_MAX_FREQUENCY_ERROR_COUNT=$MAX_FREQUENCY_ERROR_COUNT_MAX
                        fi
                    fi

                    if [ "$CURRENT_STATUS" = "${NETWORK_STATUS["NETWORK_ERROR_LOW_SIGNAL"]}" ]; then
                        echo "skip restart module due to low signal quality"
                    else
                        echo "can't access network via cellular reach max:${MAX_PING_ERROR_COUNT_ARRAY[$current_interval_index]}, restart modem module"
                        log_modem_info_for_network_error
                        restart_module_and_record || {
                            echo "restart module failed"
                            return 1
                        }
                    fi
                    current_ping_error_count=0

                    ((current_interval_index++))
                    if (("$current_interval_index" >= "${#PING_INTERVALS_ARRAY[@]}")); then
                        current_interval_index=$(("${#PING_INTERVALS_ARRAY[@]}" - 1))
                    fi
                    current_sleep_interval=${PING_INTERVALS_ARRAY[$current_interval_index]}
                    echo "will ping again in$(humanize_interval "$current_sleep_interval")"
                else
                    # do cfun01(airplane mode switch) start from second time
                    if [ "$current_ping_error_count" -ge 2 ]; then
                        echo "do airplane mode switch"
                        cfun01_and_record || {
                            echo "airplane mode switch failed"
                            return 1
                        }
                    fi
                    current_sleep_interval=${PING_INTERVALS_ARRAY[$current_interval_index]}
                    echo "can't access network via cellular $current_ping_error_count times," \
                        "will ping again in$(humanize_interval "$current_sleep_interval")"
                fi
            fi
        else
            current_interval_index=0
            current_ping_error_count=0
            current_frequancy_error_count=0
            CURRENT_MAX_FREQUENCY_ERROR_COUNT=${MAX_FREQUENCY_ERROR_COUNT_MIN}
            update_status "${NETWORK_STATUS["OK"]}"
            # use normal interval
            current_sleep_interval=${PING_INTERVAL_NORMAL}
            echo "ok, will ping again in$(humanize_interval "$current_sleep_interval")"
        fi
        truncate_log
        save_state
        sleep "$current_sleep_interval"
    done
}

# Used for tested respective modules
jump_run() {
    local current_step=$1
    shift
    if [ -n "$JUMP" ] && [ "$JUMP" -eq "$current_step" ]; then
        echo "jump to ${*}"
    fi
    if [ -z "$JUMP" ] || [ "$current_step" -ge "$JUMP" ]; then
        debug "run ${*}"
        if "$@"; then
            debug "success: ${*} done"
        else
            echo "error: ${*} failed"
            return 1
        fi
    fi
}

# Process of switching between four modules
loop_once() {
    jump_run 0 detect_modem_type_loop || return 1
    jump_run 1 get_modem_index || return 1
    jump_run 2 check_board_loop || return 1
    jump_run 3 mbn_loop || return 1
    jump_run 4 sim_status_loop || return 1
    jump_run 5 network_check_loop || return 1
}

# Entry of "main program module"
main_loop() {

    debug 'loop start'
    while true; do
        loop_once
        save_state

        if [ -n "$JUMP" ]; then
            echo "stop loop because of step jump"
            break
        fi

        if [ -e "$HARD_RESET_REQUIRED_FILE" ]; then
            rm "$HARD_RESET_REQUIRED_FILE"
            echo "Due to the above error, a hard reset is required, and the hard reset will now begin"
            hard_reset_and_record || {
                echo "hard reset failed, maybe modem is gone"
            }
            continue
        fi

        echo "sleep $CHECK_INTERVAL for next loop"
        sleep "$CHECK_INTERVAL"
        truncate_log
    done
}

# check path exists and do source
# $1: path to be sourced
extern_source() {
    local path="$1"
    if [ -n "$path" ] && [ -f "$path" ]; then
        # shellcheck disable=SC1090
        if source "$path"; then
            echo "file '$path' sourced"
        else
            echo "source '$path' failed"
        fi
    fi
}

update_version() {
    local version
    version=$(tail -1 "$OWN_DIR/VERSION")
    if [ "$VERSION" != "$version" ]; then
        if [ -n "$VERSION" ]; then
            echo "Cellular Guard updated to '$version'"
        else
            echo "Cellular Guard: $version"
        fi
        VERSION="$version"
        STATE_DIRTY=true
    else
        echo "Cellular Guard: $VERSION"
    fi
}

# Setting print
print_time_settings() {
    local ping_intervals_array_length=${#PING_INTERVALS_ARRAY[@]}
    local max_ping_error_count_array_length=${#MAX_PING_ERROR_COUNT_ARRAY[@]}

    if [ "$ping_intervals_array_length" -ne "$max_ping_error_count_array_length" ]; then
        echo "PING_INTERVALS length:$ping_intervals_array_length" \
            "and MAX_PING_ERROR_COUNT length:$max_ping_error_count_array_length must be same "
        return 1
    fi

    local check_interval_num check_interval_unit \
        max_frequancy_clear_interval_min max_frequancy_clear_interval_max \
        num ping_interval ping_count i=0

    check_interval_num=${CHECK_INTERVAL%[smhd]}
    check_interval_unit=${CHECK_INTERVAL#"$check_interval_num"}

    while ((i < MAX_FREQUENCY_ERROR_COUNT_MAX)); do
        if ((i >= ping_intervals_array_length)); then
            ping_interval="${PING_INTERVALS_ARRAY[$ping_intervals_array_length - 1]}"
            ping_count="${MAX_PING_ERROR_COUNT_ARRAY[$ping_intervals_array_length - 1]}"
        else
            ping_interval="${PING_INTERVALS_ARRAY[$i]}"
            ping_count="${MAX_PING_ERROR_COUNT_ARRAY[$i]}"
        fi
        ((num += ping_interval * (ping_count - 1)))
        if ((i == MAX_FREQUENCY_ERROR_COUNT_MIN - 1)); then
            max_frequancy_clear_interval_min=$num
        fi
        ((i++))
    done
    max_frequancy_clear_interval_max=$num

    echo "Environments:
    PERSISTENT_LOGGING: ${PERSISTENT_LOGGING}.
    CHECK_INTERVAL: ${CHECK_INTERVAL}.
    MAX_SIM_ERROR_COUNT: ${MAX_SIM_ERROR_COUNT}.
    PING_INTERVALS: ${PING_INTERVALS_ARRAY[*]}.
    PING_INTERVAL_NORMAL: ${PING_INTERVAL_NORMAL}.
    MAX_PING_ERROR_COUNT: ${MAX_PING_ERROR_COUNT_ARRAY[*]}.
    MAX_FREQUENCY_ERROR_COUNT_MIN: ${MAX_FREQUENCY_ERROR_COUNT_MIN}.
    MAX_FREQUENCY_ERROR_COUNT_MAX: ${MAX_FREQUENCY_ERROR_COUNT_MAX}.

    Frequancy clear interval in sim status check: $(((MAX_SIM_ERROR_COUNT - 1) * check_interval_num))${check_interval_unit}.
    Min frequancy clear interval in ping network check: $(humanize_interval $max_frequancy_clear_interval_min).
    Max frequancy clear interval in ping network check: $(humanize_interval $max_frequancy_clear_interval_max).
"
    # Block for some time to flush the log file
    sleep 0.5
}

usage() {
    echo "Cellular guard script
    Usage: $0 [OPTIONS]

OPTIONS:
    * -h,--help: Print this.
    * -x,--debug [0|1]: 0: output more details to console, 1: set -x, output all script steps to console.
    * -j,--jump <step>: Jumps to the specified step and exits after completing a loop. 
        0: detect modem type;
        1: get modem index;
        2: check board;
        3: mbn check; 
        4: sim status check; 
        5: network ping check.
    * --at <command>: Send AT command, get output and exit.
    * --source: I only need sourcing functions, don't run main loop
    * --hack <path>: extra script to do source hack.
"
}

while [[ $# -gt 0 ]]; do
    case $1 in
    -j | --jump)
        JUMP=$2
        if [[ ! $JUMP =~ ^[0-5]$ ]]; then
            echo "error usage of jump."
            usage
            exit 1
        fi
        shift
        ;;
    -x | --debug)
        DEBUG=$2
        if [[ ! $DEBUG =~ ^[0-1]$ ]]; then
            echo "error usage of debug."
            usage
            exit 1
        fi
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    --at)
        AT_send "$2"
        exit $?
        ;;
    --source)
        SOURCE_MODE=true
        ;;
    --hack)
        if [ -f "$2" ]; then
            extern_source "$2"
        else
            echo "hack script not found: $2"
        fi
        shift
        ;;
    *)
        echo "Unknown option: $1"
        ;;
    esac
    shift
done

if [ "$DEBUG" = '1' ]; then
    set -x
fi

if [[ $0 != "${BASH_SOURCE[0]}" ]]; then
    OWN_DIR="$(readlink -f "$(dirname "${BASH_SOURCE[0]}")")"
else
    OWN_DIR="$(readlink -f "$(dirname "$0")")"
fi

if ! $SOURCE_MODE; then
    if [ "$PERSISTENT_LOGGING" = y ]; then
        # redirect log to file
        if mkdir -p "$(dirname "$LOG_FILE_PATH")"; then
            if [ "$DEBUG" = '1' ]; then
                echo "no log to file in debug=1 mode"
            else
                echo "log to $LOG_FILE_PATH"
                exec &> >(tee_log)
            fi
        else
            echo "can't create log file path $(dirname "$LOG_FILE_PATH"), no output"
            exec &>/dev/null
        fi
    else
        # silence output
        exec &>/dev/null
    fi
fi

initial_state
update_version
save_state

if ! $SOURCE_MODE; then

    # Check if cellular guard is enabled through env variable.
    # If not, sleep for an hour (container does not exit that way)
    # This is mainly used so it does not run on mistake on wrong hardware
    # and needs to be enabled per device.
    while [ "$ENABLE_CELLULAR_GUARD" = n ]; do
        echo 'ENABLE_CELLULAR_GUARD is set to "n". Sleeping for an hour and doing nothing.'
        sleep 3600
    done

    print_time_settings || exit 1
    if [ -z "$JUMP" ]; then
        echo "main loop will start after 10 minites"
        sleep 10m
    else
        echo "jump to $JUMP, skip the first waiting"
    fi

    echo "main loop start"
    main_loop
fi
