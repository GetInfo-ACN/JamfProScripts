#!/bin/bash
#
# DemoteCurrentUserFromAdmin.sh
# Purpose: Remove the currently logged-in user from the admin group if they are an admin
# Author: Huseyin Usta - GetInfo ACN
# Created: 2025
# Description:
#   - Detects the active console user
#   - Exits if system users or no user is logged in
#   - Removes the user from the admin group if they are currently an admin
#   - Logs actions to Jamf/system logs with distinct tags
# Version: v1.0
#
################################################################################

export PATH=/usr/bin:/bin:/usr/sbin:/sbin

# Get the active user
currentUser=$(stat -f%Su /dev/console)

# Exit if no user or system user
if [[ -z "$currentUser" || "$currentUser" == "root" || "$currentUser" == "_mbsetupuser" ]]; then
    echo "No user logged in or setup user active, exiting."
    exit 0
fi

echo "Current logged in user: $currentUser"

# Check if the user is an admin
if dseditgroup -o checkmember -m "$currentUser" admin &>/dev/null; then
    echo "$currentUser is an admin. Removing from admin group..."
    if dseditgroup -o edit -d "$currentUser" -t user admin; then
        echo "Successfully removed $currentUser from admin group."
        # Use distinct log tag for demote script
        logger -t "JamfDemoteScript" "$(date): Successfully removed $currentUser from admin group"
    else
        echo "Failed to remove $currentUser from admin group."
        logger -t "JamfDemoteScript" "$(date): Failed to remove $currentUser from admin group"
        exit 1
    fi
else
    echo "$currentUser is not an admin. Nothing to do."
fi
