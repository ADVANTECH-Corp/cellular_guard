#!/usr/bin/env bash
# 
# This script is designed to test cellular guard, using the --hack cg_hack.sh.
# 

CG_START_TIMESTAMP=$(date +%s)

# copy funtion with name $1 to $1_ and eval it
copy_function(){
    eval "$(echo "${1}_()"; declare -f $1 | tail -n +2)"
}


########### hack modem manager ##########
# how many second after MM will detect as inactive
MM_STOP_AFTER=60
copy_function is_modemmanager_active
is_modemmanager_active(){
    if [ "$(date +%s)" -gt "$((CG_START_TIMESTAMP + MM_STOP_AFTER))" ]; then
        return 1
    else
        is_modemmanager_active_
    fi
}

MM_INDEX_GONE_AFTER=60
copy_function is_modemmanager_index_ready
is_modemmanager_index_ready(){
    if [ "$(date +%s)" -gt "$((CG_START_TIMESTAMP + MM_INDEX_GONE_AFTER))" ]; then
        return 1
    else
        is_modemmanager_index_ready_
    fi
}

# copy a get_modem_index_
copy_function get_modem_index
get_modem_index(){
    if [ "$(date +%s)" -gt "$((CG_START_TIMESTAMP + MM_INDEX_GONE_AFTER))" ]; then
        return 1
    else
        # use original function
        get_modem_index_
    fi
}
##################################


########### hack detect modem ##########

MODEM_GONE_AFTER=60
copy_function is_modem_usb_ready
is_modem_usb_ready(){
    if [ "$(date +%s)" -gt "$((CG_START_TIMESTAMP + MODEM_GONE_AFTER))" ]; then
        return 1
    else
        is_modem_usb_ready_
    fi
}
##########################################


########## hack ping #############
# how many times to fail ping before restoring
PING_FAIL_COUNT=10
# current ping count
CURRENT_PING_COUNT=0


# hack ping
ping_network() {
    if [ $CURRENT_PING_COUNT -lt $PING_FAIL_COUNT ]; then
        ((CURRENT_PING_COUNT++))
        return 1
    else
        return 0
    fi
}
################################
