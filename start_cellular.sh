#!/bin/bash
# 
# This script is for testing cellular guard in BalenaOS.

cellular_guard="balena run --rm -it --privileged --network host \
-v /run/dbus:/host/run/dbus -v /sys:/sys -v /proc:/proc -v /mnt/data:/mnt/data \
-e DBUS_SYSTEM_BUS_ADDRESS=unix:path=/host/run/dbus/system_bus_socket \
cellular_guard"

$cellular_guard -x 0 "$@"

