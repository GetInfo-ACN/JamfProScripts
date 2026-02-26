#!/bin/bash
#
# AddCurrentUserToAdmin.sh
# Purpose: Add the currently logged-in user to the admin group if not already an admin
# Author: Huseyin Usta - GetInfo ACN
# Created: 2025
# Description:
#   - Detects the active console user
#   - Exits if system users or no user is logged in
#   - Adds the user to the admin group if needed
#   - Logs all actions for audit trail
# Version: v1.1
#
################################################################################

Version="1.1"
FullScriptName=$(basename "$0")
ShowVersion="$FullScriptName $Version"
logFile="/private/var/log/admin.promote.log"

# Log function
log() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local message="$timestamp - $1"
    echo "$message" | tee -a "$logFile"
    logger -t "JamfAdminScript" "$message"
}

log "********* Running $ShowVersion *********"

RunAsRoot() {
    if [[ "${USER}" != "root" ]]; then
        log "***  This application must be run as root.  Please authenticate below.  ***"
        sudo "$1" && exit 0
    fi
}

RunAsRoot "$0"

# Get the active user
currentUser=$(stat -f%Su /dev/console)

# Exit if no user or system user
if [[ -z "$currentUser" || "$currentUser" == "root" || "$currentUser" == "_mbsetupuser" ]]; then
    log "No user logged in or setup user active, exiting."
    exit 0
fi

log "Current logged in user: $currentUser"

# Check if the user is already an admin
if /usr/sbin/dseditgroup -o checkmember -m "$currentUser" admin &>/dev/null; then
    log "$currentUser is already an admin. Nothing to do."
else
    log "Adding $currentUser to admin group..."
    if /usr/sbin/dseditgroup -o edit -a "$currentUser" -t user admin; then
        log "Successfully added $currentUser to admin group."
    else
        log "Failed to add $currentUser to admin group."
        exit 1
    fi
fi

exit 0